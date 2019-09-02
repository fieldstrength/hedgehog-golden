module Hedgehog.Golden.Aeson
  ( encodeGolden
  , decodeGolden
  , decodeSeed
  , goldenTest
  , TestConfig(..)
  , defaultTestConfig
  ) where

import           Prelude

import           Data.Aeson (FromJSON, ToJSON, (.=), (.:))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson
import           Data.Aeson.Encode.Pretty (Config(..), Indent(..), encodePretty', defConfig)
import qualified Data.ByteString.Lazy as ByteString (toStrict)
import           Data.Proxy (Proxy(..))
import           Data.Sequence (Seq)
import           Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import           Data.Typeable (Typeable, typeRep)
import           Hedgehog (Gen, Seed(..))
import           Hedgehog.Golden.Sample (genSamples)
import           Hedgehog.Golden.Types (GoldenTest(..), TestName(..))
import           GHC.Stack (HasCallStack, callStack, withFrozenCallStack)
import           System.Directory (doesFileExist)
import           System.FilePath ((</>))

encodeGolden :: ToJSON a => Seed -> Seq a -> Text
encodeGolden seed samples =
  let
    aesonSeed (Seed value gamma) =
      Aeson.object [ "value" .= value, "gamma" .= gamma ]

    encodePretty =
      Text.decodeUtf8 . ByteString.toStrict . encodePretty' defConfig
        { confIndent = Spaces 2
        , confCompare = compare
        }
  in
    encodePretty $
      Aeson.object [ "seed" .= aesonSeed seed, "samples" .= Aeson.toJSON samples ]

decodeSeed :: Text -> Either String Seed
decodeSeed text =
  let
    getSeed :: Aeson.Object -> Either String Seed
    getSeed =
      Aeson.parseEither $ \obj -> do
        value <- obj .: "seed" >>= (.: "value")
        gamma <- obj .: "seed" >>= (.: "gamma")
        pure $ Seed value gamma
  in
    Aeson.eitherDecodeStrict (Text.encodeUtf8 text) >>= getSeed

decodeGolden :: FromJSON a => Aeson.Object -> Either String (Seed, Seq a)
decodeGolden = Aeson.parseEither $ \obj -> do
  value <- obj .: "seed" >>= (.: "value")
  gamma <- obj .: "seed" >>= (.: "gamma")
  samples <- obj .: "samples"
  pure (Seed value gamma, samples)


data TestConfig = TestConfig
  { goldenFolderPath :: FilePath }

defaultTestConfig :: TestConfig
defaultTestConfig = TestConfig
  { goldenFolderPath = "golden" }

goldenTest ::
  forall a. HasCallStack
  => Typeable a
  => FromJSON a
  => ToJSON a
  => TestConfig -> Gen a -> IO GoldenTest
goldenTest conf gen = withFrozenCallStack $ do
  let
    typeName = show . typeRep $ Proxy @a
    testName = TestName $ Text.pack typeName
    fileName =  goldenFolderPath conf </> typeName <> ".json"
    aesonValueGenerator seed = Text.lines . encodeGolden seed $ genSamples seed gen
    aesonValueReader t =
      either (Left . Text.pack) (const $ Right ()) $
        Aeson.eitherDecodeStrict (Text.encodeUtf8 t) >>= decodeGolden @a
  fileExists <- doesFileExist fileName
  pure $
    if
      fileExists
    then
      ExistingFile testName callStack fileName aesonValueGenerator (Just aesonValueReader)
    else
      NewFile testName callStack fileName aesonValueGenerator
