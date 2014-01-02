{-# LANGUAGE OverloadedStrings, QuasiQuotes, TemplateHaskell, TupleSections, GeneralizedNewtypeDeriving #-}
module Yesod.EmbeddedStatic.Css.Util where

import Prelude hiding (FilePath)
import Control.Applicative
import Control.Monad (void, foldM)
import Data.Hashable (Hashable)
import Data.Monoid
import Network.Mime (MimeType, defaultMimeLookup)
import Filesystem.Path.CurrentOS (FilePath, directory, (</>), dropExtension, filename, toText, decodeString, encodeString, fromText)
import Text.CSS.Parse (parseBlocks)
import Language.Haskell.TH (litE, stringL)
import Text.CSS.Render (renderBlocks)
import Yesod.EmbeddedStatic.Types
import Yesod.EmbeddedStatic (pathToName)
import Data.Default (def)

import qualified Blaze.ByteString.Builder as B
import qualified Blaze.ByteString.Builder.Char.Utf8 as B
import qualified Data.Attoparsec.Text as P
import qualified Data.Attoparsec.ByteString.Lazy as PBL
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Base64 as B64
import qualified Data.HashMap.Lazy as M
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Builder as TL

-------------------------------------------------------------------------------
-- Loading CSS
-------------------------------------------------------------------------------

-- | In the parsed CSS, this will be an image reference that we want to replace.
-- the contents will be the filepath.
newtype UrlReference = UrlReference T.Text
    deriving (Show, Eq, Hashable, Ord)

type EithUrl = (T.Text, Either T.Text UrlReference)

-- | The parsed CSS
type Css = [(T.Text, [EithUrl])]

-- | Parse the filename out of url('filename')
parseUrl :: P.Parser T.Text
parseUrl = do
    P.skipSpace
    void $ P.string "url('"
    P.takeTill (== '\'')

checkForUrl :: T.Text -> T.Text -> EithUrl
checkForUrl n@("background-image") v = parseBackgroundImage n v
checkForUrl n@("src") v = parseBackgroundImage n v
checkForUrl n v = (n, Left v)

-- | Check if a given CSS attribute is a background image referencing a local file
checkForImage :: T.Text -> T.Text -> EithUrl
checkForImage n@("background-image") v = parseBackgroundImage n v
checkForImage n v = (n, Left v)

parseBackgroundImage :: T.Text -> T.Text -> EithUrl
parseBackgroundImage n v = case P.parseOnly parseUrl v of
    Left _ -> (n, Left v) -- Can't parse url
    Right url
        | "http" `T.isPrefixOf` url -> (n, Left v)
        | "/" `T.isPrefixOf` url -> (n, Left v)
        | otherwise -> (n, Right $ UrlReference url)

parseCssWith :: (T.Text -> T.Text -> EithUrl) -> FilePath -> IO Css
parseCssWith urlParser fp = do
    mparsed <- parseBlocks <$> T.readFile (encodeString fp)
    case mparsed of
        Left err -> fail $ "Unable to parse " ++ encodeString fp ++ ": " ++ err
        Right blocks ->
            return [ (t, map (uncurry urlParser) b) | (t,b) <- blocks ]

parseCssUrls :: FilePath -> IO Css
parseCssUrls = parseCssWith checkForUrl

-- | Parse the CSS from the file.  If a parse error occurs, a failure is raised (exception)
parseCss :: FilePath -> IO Css
parseCss = parseCssWith checkForImage

renderCssWith :: (UrlReference -> T.Text) -> Css -> TL.Text
renderCssWith urlRenderer css =
    TL.toLazyText $ renderBlocks [(n, map render block) | (n,block) <- css]
  where
    render (n, Left b) = (n, b)
    render (n, Right f) = (n, urlRenderer f)

-- | Load an image map from the images in the CSS
loadImages :: FilePath -> Css -> (FilePath -> IO (Maybe a)) -> IO (M.HashMap UrlReference a)
loadImages dir css loadImage = foldM load M.empty $ concat [map snd block | (_,block) <- css]
    where
        load imap (Left _) = return imap
        load imap (Right f) | f `M.member` imap = return imap
        load imap (Right f@(UrlReference path)) = do
            img <- loadImage (dir </> fromText path)
            return $ maybe imap (\i -> M.insert f i imap) img


-- | If you tack on additional CSS post-processing filters, they use this as an argument.
data CssGeneration = CssGeneration {
                       cssContent :: BL.ByteString
                     , cssStaticLocation :: Location
                     , cssFileLocation :: FilePath
                     }

mkCssGeneration :: Location -> FilePath -> BL.ByteString -> CssGeneration
mkCssGeneration loc file content =
    CssGeneration { cssContent = content
                  , cssStaticLocation = loc
                  , cssFileLocation = file
                  }

cssProductionFilter ::
       (FilePath ->  IO BL.ByteString) -- ^ a filter to be run on production
     -> Location -- ^ The location the CSS file should appear in the static subsite
     -> FilePath -- ^ Path to the CSS file.
     -> Entry
cssProductionFilter prodFilter loc file =
    def { ebHaskellName = Just $ pathToName loc
        , ebLocation = loc
        , ebMimeType = "text/css"
        , ebProductionContent = prodFilter file
        , ebDevelReload = [| develPassThrough $(litE (stringL loc)) $(litE (stringL $ encodeString file)) |]
        , ebDevelExtraFiles = Nothing
        }

cssProductionImageFilter :: (FilePath -> IO BL.ByteString) -> Location -> FilePath -> Entry
cssProductionImageFilter prodFilter loc file =
  (cssProductionFilter prodFilter loc file)
    { ebDevelReload = [| develBgImgB64 $(litE (stringL loc)) $(litE (stringL $ encodeString file)) |]
    , ebDevelExtraFiles = Just [| develExtraFiles $(litE (stringL loc)) |]
    }

-------------------------------------------------------------------------------
-- Helpers for the generators
-------------------------------------------------------------------------------

-- For development, all we need to do is update the background-image url to base64 encode it.
-- We want to preserve the formatting (whitespace+newlines) during development so we do not parse
-- using css-parse.  Instead we write a simple custom parser.

parseBackground :: Location -> FilePath -> PBL.Parser B.Builder
parseBackground loc file = do
    void $ PBL.string "background-image"
    s1 <- PBL.takeWhile (\x -> x == 32 || x == 9) -- space or tab
    void $ PBL.word8 58 -- colon
    s2 <- PBL.takeWhile (\x -> x == 32 || x == 9) -- space or tab
    void $ PBL.string "url('"
    url <- PBL.takeWhile (/= 39) -- single quote
    void $ PBL.string "')"

    let b64 = B64.encode $ T.encodeUtf8 (either id id $ toText (directory file)) <> url
        newUrl = B.fromString (encodeString $ filename $ decodeString loc) <> B.fromString "/" <> B.fromByteString b64

    return $ B.fromByteString "background-image"
          <> B.fromByteString s1
          <> B.fromByteString ":"
          <> B.fromByteString s2
          <> B.fromByteString "url('"
          <> newUrl
          <> B.fromByteString "')"

parseDev :: Location -> FilePath -> B.Builder -> PBL.Parser B.Builder
parseDev loc file b = do
    b' <- parseBackground loc file <|> (B.fromWord8 <$> PBL.anyWord8)
    (PBL.endOfInput *> (pure $! b <> b')) <|> (parseDev loc file $! b <> b')

develPassThrough :: Location -> FilePath -> IO BL.ByteString
develPassThrough _ = BL.readFile . encodeString

-- | Create the CSS during development
develBgImgB64 :: Location -> FilePath -> IO BL.ByteString
develBgImgB64 loc file = do
    ct <- BL.readFile $ encodeString file
    case PBL.eitherResult $ PBL.parse (parseDev loc file mempty) ct of
        Left err -> error err
        Right b -> return $ B.toLazyByteString b

-- | Serve the extra image files during development
develExtraFiles :: Location -> [T.Text] -> IO (Maybe (MimeType, BL.ByteString))
develExtraFiles loc parts =
    case reverse parts of
        (file:dir) | T.pack loc == T.intercalate "/" (reverse dir) -> do
            let file' = T.decodeUtf8 $ B64.decodeLenient $ T.encodeUtf8 $ either id id $ toText $ dropExtension $ fromText file
            ct <- BL.readFile $ T.unpack file'
            return $ Just (defaultMimeLookup file', ct)
        _ -> return Nothing
