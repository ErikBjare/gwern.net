-- $ cabal install cassava stringsearch
-- $ wget http://www.gwern.net/docs/gwern-goodreads.csv
-- $ rm foo.html; runhaskell tmp.hs | pandoc --standalone --smart --number-sections --toc --reference-links --css=/home/gwern/wiki/static/css/default.css --css=http://www.gwern.net/static/css/default.css --mathml -o foo.html && firefox foo.html
{- Background on parsing the GoodReads CSV export:

CSV header looks like this:
Book Id,Title,Author,Author l-f,Additional Authors,ISBN,ISBN13,My Rating,Average Rating,Publisher,Binding,Number of Pages,Year Published,Original Publication Year,Date Read,Date Added,Bookshelves,Bookshelves with positions,Exclusive Shelf,My Review,Spoiler,Private Notes,Read Count,Recommended For,Recommended By,Owned Copies,Original Purchase Date,Original Purchase Location,Condition,Condition Description,BCID

Example CSV line:
8535464,"The Geeks Shall Inherit the Earth: Popularity, Quirk Theory and Why Outsiders Thrive After High School","Alexandra Robbins","Robbins, Alexandra","",="1401302025",="9781401302023",2,"3.62","Hyperion","Hardcover","448",2009,2009,2011/10/15,2012/07/16,"","","read","Found it only OK. Basically extended anecdotes, with some light science mixed in to buttress her manifesto (and used for support, not illumination).","","","","","",0,,,,,
-}
-- Background on Amazon: Generic ISBN search looks like this http://www.amazon.com/gp/search/ref=sr_adv_b/?search-alias=stripbooks&unfiltered=1&field-isbn=9781401302023

{-# LANGUAGE OverloadedStrings, RecordWildCards #-}
import Control.Applicative
import Data.ByteString.Lazy.Search as BLS (replace)
import Data.Csv
import Data.Maybe
import Text.Pandoc
import Text.Pandoc.Builder as TPB
import Text.Pandoc.Highlighting (pygments)
import qualified Data.ByteString.Lazy as B
import qualified Data.Sequence as S
import qualified Data.Vector as V
-- import System.Environment (getArgs)
main :: IO ()
main = do books <- B.readFile "gwern-goodreads.csv"
          -- books <- fmap head getArgs >>= B.readFile
          let books' = BLS.replace "=\"" ("\""::B.ByteString) books
          -- B.putStrLn books'
          case decodeByName books' of
              Left err -> putStrLn err
              Right (_, v) -> putStrLn (writeMarkdown def (Pandoc nullMeta [(bookTable v)]))

data GoodReads = GoodReads { title :: String, author :: String, isbn :: Maybe Int,
                             myRating :: Int,
                             yearPublished :: Maybe Int, originalYearPublished :: Maybe Int,
                             dateRead :: String, review :: String }
instance FromNamedRecord GoodReads where
  parseNamedRecord m = GoodReads <$>
                          m .: "Title" <*>
                          m .: "Author" <*>
                          m .: "ISBN" <*>
                          m .: "My Rating" <*>
                          m .: "Year Published" <*>
                          m .: "Original Publication Year" <*>
                          m .: "Date Read" <*>
                          m .: "My Review"

-- relevant types:
-- Table [Inline] [Alignment] [Double] [TableCell] [[TableCell]]
-- simpleTable :: [Blocks] -> [[Blocks]] -> Blocks
-- type Blocks  = Many Block

bookTable :: V.Vector GoodReads -> Block
bookTable books = let rows = V.toList (V.map bookToRow books)
                      in S.index (unBlocks (simpleTable colHeaders rows)) 0

colHeaders :: [Blocks]
colHeaders = Prelude.map TPB.singleton [Plain [Str "Title"],
                                        Plain [Str "Author"],
                                        Plain [Str "Rating"],
                                        Plain [Str "Year"],
                                        Plain [Str "Read"],
                                        Plain [Str "Review"]]

bookToRow :: GoodReads -> [Blocks]
bookToRow gr = Prelude.map TPB.singleton [Plain [Emph [Link [Str (title gr)] (handleISBN (isbn gr))]],
                                          Plain [Str (author gr)],
                                          Plain [Str (handleRating (myRating gr))],
                                          Plain [Str (handleDate gr)],
                                          Plain [Str (dateRead gr)]] ++
              Prelude.map TPB.singleton (handleReview (review gr))

handleISBN :: Maybe Int -> (String,String)
handleISBN i = case i of
                Nothing -> ("","")
                Just i' -> (getAmazonPage i', "ISBN: "++show(i'))

                where getAmazonPage :: Int -> String
                      getAmazonPage isbn =  "http://www.amazon.com/gp/search?keywords="++show(isbn)++"&index=books"

handleRating :: Int -> String
handleRating stars = replicate stars '★'
handleDate :: GoodReads -> String
handleDate gr = show $ head $ catMaybes [yearPublished gr, originalYearPublished gr, Just 0]
handleReview :: String -> [Block]
handleReview rvw = let (Pandoc _ x) = readMarkdown defaultParserState rvw in x


nullMeta :: Meta
nullMeta = Meta { docTitle = []
                , docAuthors = []
                , docDate = [] }

def :: WriterOptions
def = WriterOptions { writerStandalone         = False
                      , writerTemplate         = ""
                      , writerVariables        = []
                      , writerTabStop          = 4
                      , writerTableOfContents  = False
                      , writerSlideVariant     = NoSlides
                      , writerIncremental      = False
                      , writerHTMLMathMethod   = PlainMath
                      , writerIgnoreNotes      = False
                      , writerNumberSections   = False
                      , writerSectionDivs      = False
                      , writerReferenceLinks   = False
                      , writerWrapText         = True
                      , writerColumns          = 90
                      , writerIdentifierPrefix = ""
                      , writerSourceDirectory  = "."
                      , writerUserDataDir      = Nothing
                      , writerCiteMethod       = Citeproc
                      , writerBiblioFiles      = []
                      , writerHtml5            = False
                      , writerBeamer           = False
                      , writerSlideLevel       = Nothing
                      , writerChapters         = False
                      , writerListings         = False
                      , writerHighlight        = False
                      , writerSetextHeaders    = True
                      , writerTeXLigatures     = True
                      , writerEPUBMetadata     = ""
                      , writerStrictMarkdown   = True
                      , writerLiterateHaskell  = False
                      , writerEmailObfuscation = undefined
                      , writerHighlightStyle   = pygments
                      , writerXeTeX = False
                      }