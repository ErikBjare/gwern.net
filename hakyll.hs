#!/usr/bin/env runhaskell
{-# LANGUAGE OverloadedStrings #-}

{- Debian dependencies:
$ sudo apt-get install libghc-hakyll-dev libghc-pandoc-dev libghc-filestore-dev libghc-feed-dev libghc-tagsoup-dev imagemagick s3cmd git
(ImageMagick, s3cmd, & git are runtime dependencies used to help optimize images and upload to hosting/Github respectively)

$ cd ~/wiki/ && ghc -rtsopts -threaded -O2 -fforce-recomp -optl-s --make hakyll.hs &&
  ./hakyll rebuild +RTS -N3 -RTS && echo -n -e '\a' && emacs -nw _site/Modafinil &&
  s3cmd -v -v --human-readable-sizes --reduced-redundancy --guess-mime-type --default-mime-type=text/html
        --add-header="Cache-Control: max-age=604800, public" --delete-removed sync _site/ s3://www.gwern.net/ &&
  s3cmd --reduced-redundancy --mime-type=text/css --add-header="Cache-Control: max-age=604800, public" put ./_site/static/css/default.css s3://www.gwern.net/static/css/ &&
  rm -rf ~/wiki/_cache/ ~/wiki/_site/ && rm ./hakyll *.o *.hi ;
  git push; echo -n -e '\a'

Explanations:

- we could run Hakyll with a command like `./hakyll.hs build` but this would run much slower than if we compile an optimized parallelized binary & run it with multiple threads; this comes at the cost of considerable extra complexity in the invocation, though, since we need to compile it with fancy options, run it with other options, and then at the end clean up by deleting the compiled binary & intermediates (GHC cannot take care of them on its own: https://ghc.haskell.org/trac/ghc/ticket/4114 )
- `rebuild` instead of 'build' because IIRC there was some problem where Hakyll didn't like extension-less files so incremental syncs/builds don't work; this tells Hakyll
 to throw everything away without even trying to check
- Emacs: I manually edit the ads on the Modafinil page away from the default to the current sponsor; I should probably figure out how to do this automatically with the templating system but meh, I don't sync gwern.net *that* often
- s3cmd:

    - `--reduced-redundancy` saves a bit of money; no need for high-durability since everything is backed up locally in the git repo, after all
    - s3cmd's MIME type detection has been unreliable in the past, so we need to force a default, especially for the extension-less (HTML) files
    - the second, apparently redundant, CSS upload is an example of the MIME flakiness: for some reason, s3cmd sometimes uploads `*.css` files as the default MIME type!
      Of curse, browsers ignore any CSS served as text/HTML or the further default of octetstream, so gwern.net then breaks.
      By forcing an upload with a hardwired CSS MIME, we can avoid this being an issue ever again.
- after that, we clean up after ourselves and sync with the Github mirror as well
- the 'echo' calls are there to ring the terminal bell and notify the user that he needs to edit the Modafinil file or that the whole thing is done
-}

import Codec.Binary.UTF8.String (encode)
import Control.Exception (onException)
import Data.ByteString.Lazy.Char8 (unpack)
import Data.Char (isAlphaNum, isAscii)
import Data.List (isInfixOf, nub, sort)
import Data.Monoid ((<>))
import Data.Set (filter)
import Network.HTTP (urlEncode)
import Network.URI (unEscapeString)
import System.Directory (createDirectoryIfMissing)
import System.IO.Unsafe (unsafePerformIO)
import Text.Printf (printf)
import qualified Data.Map as M (fromList, lookup, Map)

import Data.FileStore (gitFileStore)
import Data.FileStore.Utils (runShellCommand)
import Feed (filestoreToXmlFeed, FeedConfig(..))
import Hakyll ((.&&.), applyTemplateList, buildTags, compile, complement, compressCssCompiler, constField,
               copyFileCompiler, dateField, defaultContext, defaultHakyllReaderOptions,
               defaultHakyllWriterOptions, fromCapture, getRoute, hakyll, idRoute, itemIdentifier,
               loadAll, loadAndApplyTemplate, loadBody, makeItem, match, modificationTimeField,
               pandocCompilerWithTransform, preprocess, relativizeUrls, route, setExtension,
               tagsField, tagsRules, templateCompiler, Compiler, Context, Item, Pattern, Tags)
import System.Exit (ExitCode(ExitFailure))
import Text.HTML.TagSoup (renderTagsOptions,parseTags,renderOptions, optMinimize, Tag(TagOpen))
import Text.Pandoc (bottomUp, Extension(Ext_markdown_in_html_blocks), HTMLMathMethod(MathML), Inline(..),
                    ObfuscationMethod(NoObfuscation), Pandoc(..), ReaderOptions(..), WriterOptions(..))

main :: IO ()
main = hakyll $ do
             preprocess $ do rss <- filestoreToXmlFeed rssConfig (gitFileStore "./")  Nothing
                             createDirectoryIfMissing False "_site"
                             writeFile "_site/atom.xml" rss

             -- handle the simple static non-.page files
             let static = route idRoute >> compile copyFileCompiler
             mapM_ (`match` static) [ -- WARNING: match everything *except* Markdown
                                      -- since rules are mutually-exclusive!
                                     complement "docs/**.page" .&&. "docs/**",
                                     "haskell/**.hs",
                                     "images/**",
                                     "**.hs",
                                     "**.sh",
                                     "static/*",
                                     "static/img/**",
                                     "static/js/**"]
             match "**.css" $ route idRoute >> compile compressCssCompiler
             match "static/templates/*.html" $ compile templateCompiler

             tags <- buildTags "**.page" (fromCapture "tags/*")

             match "**.page" $ do
                 route $ setExtension "" -- cool URLs
                 -- https://groups.google.com/forum/#!topic/pandoc-discuss/HVHY7-IOLSs
                 let readerOptions = defaultHakyllReaderOptions { readerExtensions = Data.Set.filter (/=Ext_markdown_in_html_blocks) $ readerExtensions defaultHakyllReaderOptions }
                 compile $ pandocCompilerWithTransform readerOptions woptions pandocTransform
                     >>= loadAndApplyTemplate "static/templates/default.html" (postCtx tags)
                     >>= imgUrls
                     >>= relativizeUrls

             tagsRules tags $ \tag pattern -> do
                 let title = "Tag: " ++ tag
                 route idRoute
                 compile $ tagPage tags title pattern

woptions :: WriterOptions
woptions = defaultHakyllWriterOptions{ writerSectionDivs = True,
                                       writerStandalone = True,
                                       writerTableOfContents = True,
                                       writerColumns = 120,
                                       writerTemplate = "<div id=\"TOC\">$toc$</div>\n$body$",
                                       writerHtml5 = True,
                                       writerHTMLMathMethod = Text.Pandoc.MathML Nothing,
                                       writerEmailObfuscation = NoObfuscation }


rssConfig :: FeedConfig
rssConfig = FeedConfig { fcTitle = "Gwern", fcBaseUrl  = "http://www.gwern.net", fcFeedDays = 30 }

postList :: Tags -> Pattern -> ([Item String] -> Compiler [Item String]) -> Compiler String
postList tags pattern preprocess' = do
    postItemTemplate <- loadBody "static/templates/postitem.html"
    posts' <- loadAll pattern
    posts <- preprocess' posts'
    applyTemplateList postItemTemplate (postCtx tags) posts
tagPage :: Tags -> String -> Pattern -> Compiler (Item String)
tagPage tags title pattern = do
    list <- postList tags pattern (return . id)
    makeItem ""
        >>= loadAndApplyTemplate "static/templates/tags.html"
                (constField "posts" list <> constField "title" title <>
                    defaultContext)
        >>= relativizeUrls

imgUrls :: Item String -> Compiler (Item String)
imgUrls item = do
    rte <- getRoute $ itemIdentifier item
    return $ case rte of
        Nothing -> item
        Just _  -> fmap (unsafePerformIO . addImgDimensions) item

postCtx :: Tags -> Context String
postCtx tags =
    tagsField "tags" tags <>
    defaultContext <>
    dateField "created" "%d %b %Y" <>
    modificationTimeField "modified" "%d %b %Y" <>
    constField "author" "gwern" <>
    constField "status" "N/A" <>
    constField "belief" "N/A" <>
    constField "description" "N/A"

pandocTransform :: Pandoc -> Pandoc
pandocTransform = bottomUp (map (convertInterwikiLinks . convertHakyllLinks . addAmazonAffiliate))

-- For Amazon links, there are two scenarios: there are parameters (denoted by a
-- '?' in the URL), or there are not. In the former, we need to append the tag as
-- another item ('&tag='), while in the latter, we need to set up our own
-- parameter ('?tag='). The transform may be run many times since
-- they are supposed to be pure, so we
-- need to also check a tag hasn't already been appended.
--
-- For non-Amazon links, we just return them unchanged.
addAmazonAffiliate :: Inline -> Inline
addAmazonAffiliate x@(Link r (l, t)) = if (("amazon.com/" `isInfixOf` l) && not ("tag=gwernnet-20" `isInfixOf` l)) then
                                        if ("?" `isInfixOf` l) then Link r (l++"&tag=gwernnet-20", t) else Link r (l++"?tag=gwernnet-20", t)
                                       else x
addAmazonAffiliate x = x

-- GITIT -> HAKYLL LINKS PLUGIN
-- | Convert links with no URL to wikilinks.
convertHakyllLinks :: Inline -> Inline
convertHakyllLinks (Link ref ("", "")) = let ref' = inlinesToURL ref in Link ref (ref', "Go to wiki page: " ++ ref')
convertHakyllLinks x = x

-- FASTER HTML RENDERING BY STATICLY SPECIFYING ALL IMAGE DIMENSIONS
-- read HTML string with TagSoup, process `<img>` tags to read the file's dimensions, and hardwire them
-- this optimizes HTML rendering since browsers know before downloading the image how to layout the page
addImgDimensions :: String -> IO String
addImgDimensions = fmap (renderTagsOptions renderOptions{optMinimize=whitelist}) . mapM staticImg . parseTags
                 where whitelist s = s /= "div" && s /= "script"
{- example illustration:
 TagOpen "img" [("src","/images/201201-201207-traffic-history.png")
                ("alt","Plot of page-hits (y-axis) versus date (x-axis)")],
 TagOpen "figcaption" [],TagText "Plot of page-hits (y-axis) versus date (x-axis)",
 TagClose "figcaption",TagText "\n",TagClose "figure" -}
staticImg :: Tag String -> IO (Tag String)
staticImg x@(TagOpen "img" xs) = do let optimized = lookup "height" xs
                                    case optimized of
                                      Just _ -> return x
                                      Nothing -> do let path = lookup "src" xs
                                                    case path of
                                                          Nothing -> return x
                                                          Just p -> do let p' = if head p == '/' then tail p else p
                                                                       (height,width) <- imageMagick p' `onException` (putStrLn p)
                                                                       -- body max-width is 1100 px, sidebar is 150px, so any image wider than 900px
                                                                       -- will wind up being reflowed by the 'img { max-width: 100%; }' responsive-image CSS declaration;
                                                                       -- let's avoid that specific case by lying about its width, although this doesn't fix all the reflowing.
                                                                       -- No images should be more than a screen in height either, so we'll set a maximum of 900
                                                                       let width' =  show ((read width::Int) `min` 900)
                                                                       let height' = show ((read height::Int) `min` 900)
                                                                       return (TagOpen "img" (uniq ([("height", height'), ("width", width')]++xs)))
            where uniq = nub . sort
staticImg x = return x
-- | Use FileStore util to run imageMagick's 'identify', & extract the dimensions
-- Note that for animated GIFs, 'identify' returns width/height for each frame of the GIF, which in
-- most cases will all be the same, so we take the first line of whatever dimensions 'identify' returns.
imageMagick :: FilePath -> IO (String,String)
imageMagick f = do (status,_,bs) <- runShellCommand "./" Nothing "identify" ["-format", "%h %w\n", f]
                   case status of
                     ExitFailure _ -> error f
                     _ -> do let [height, width] = words $ head $ lines $ (unpack bs)
                             return (height, width)


-- INTERWIKI PLUGIN
-- | Derives a URL from a list of Pandoc Inline elements.
inlinesToURL :: [Inline] -> String
inlinesToURL x = let x' = inlinesToString x
                     (a,b) = break (=='%') x'
                 in escape a ++ b
-- copied from "XMonad.Actions.Search"
escape :: String -> String
escape = concatMap escapeURIChar
         where escapeURIChar :: Char -> String
               escapeURIChar c | isAscii c && isAlphaNum c = [c]
                               | otherwise                 = concatMap (printf "%%%02X") $ encode [c]

-- | Convert a list of inlines into a string.
inlinesToString :: [Inline] -> String
inlinesToString = concatMap go
  where go x = case x of
               Str s    -> s
               Code _ s -> s
               _        -> " "
convertInterwikiLinks :: Inline -> Inline
convertInterwikiLinks (Link ref (interwiki, article)) =
  case interwiki of
    ('!':interwiki') ->
        case M.lookup interwiki' interwikiMap of
                Just url  -> case article of
                                  "" -> Link ref (url `interwikiurl` inlinesToString ref, summary $ unEscapeString $ inlinesToString ref)
                                  _  -> Link ref (url `interwikiurl` article, summary article)
                Nothing -> Link ref (interwiki, article)
            where -- 'http://starwars.wikia.com/wiki/Emperor_Palpatine'
                  interwikiurl u a = u ++ urlEncode (deunicode a)
                  deunicode = map (\x -> if x == '’' then '\'' else x)
                  -- 'Wookieepedia: Emperor Palpatine'
                  summary a = interwiki' ++ ": " ++ a
    _ -> Link ref (interwiki, article)
convertInterwikiLinks x = x
-- | Large table of constants; this is a mapping from shortcuts to a URL. The URL can be used by
--   appending to it the article name (suitably URL-escaped, of course).
interwikiMap :: M.Map String String
interwikiMap = M.fromList $ wpInterwikiMap ++ customInterwikiMap
wpInterwikiMap, customInterwikiMap :: [(String, String)]
customInterwikiMap = [("Hackage", "http://hackage.haskell.org/package/"),
                      ("Hawiki", "http://haskell.org/haskellwiki/"),
                      ("Hoogle", "http://www.haskell.org/hoogle/?hoogle=")]
wpInterwikiMap = [("Wikipedia", "http://en.wikipedia.org/wiki/"),
                  ("Wikiquote", "http://en.wikiquote.org/wiki/"),
                  ("Wiktionary", "http://en.wiktionary.org/wiki/")]
