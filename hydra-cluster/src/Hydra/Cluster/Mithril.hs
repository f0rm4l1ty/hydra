-- | Mithril client to bootstrap cardano nodes in the hydra-cluster.
module Hydra.Cluster.Mithril where

import Hydra.Prelude

import Control.Tracer (Tracer, traceWith)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Hydra.Cluster.Fixture (KnownNetwork (..))
import Network.HTTP.Simple (getResponseBody, httpBS, parseRequest)
import System.IO.Error (isEOFError)
import System.Process.Typed (createPipe, getStdout, proc, setStdout, withProcessWait_)

data MithrilLog
  = StartSnapshotDownload {network :: KnownNetwork, directory :: FilePath}
  | -- | Output captured directly from mithril-client
    StdOut {output :: Value}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Downloads and unpacks latest snapshot for given network in db/ of given
-- directory.
downloadLatestSnapshotTo :: Tracer IO MithrilLog -> KnownNetwork -> FilePath -> IO ()
downloadLatestSnapshotTo tracer network directory = do
  traceWith tracer StartSnapshotDownload{network, directory}
  genesisKey <- parseRequest (genesisKeyURLForNetwork network) >>= httpBS <&> getResponseBody
  let cmd =
        setStdout createPipe $
          proc "mithril-client" $
            concat
              [ ["--aggregator-endpoint", aggregatorEndpointForNetwork network]
              , ["snapshot", "download", "latest"]
              , ["--genesis-verification-key", decodeUtf8 genesisKey]
              , ["--download-dir", directory]
              , ["--json"]
              ]
  withProcessWait_ cmd traceStdout
 where
  traceStdout p =
    ignoreEOFErrors . forever $ do
      bytes <- BS.hGetLine (getStdout p)
      case Aeson.eitherDecodeStrict bytes of
        Left err -> error $ "failed to decode: \n" <> show bytes <> "\nerror: " <> show err
        Right output -> traceWith tracer StdOut{output}

  ignoreEOFErrors =
    handleJust (guard . isEOFError) (const $ pure ())

  genesisKeyURLForNetwork = \case
    Mainnet -> "https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/release-mainnet/genesis.vkey"
    Preproduction -> "https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/release-preprod/genesis.vkey"
    Preview -> "https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/pre-release-preview/genesis.vkey"

  aggregatorEndpointForNetwork = \case
    Mainnet -> "https://aggregator.release-mainnet.api.mithril.network/aggregator"
    Preproduction -> "https://aggregator.release-preprod.api.mithril.network/aggregator"
    Preview -> "https://aggregator.pre-release-preview.api.mithril.network/aggregator"