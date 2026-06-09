-- | Decode a module's `externs.cbor` into an `ExternsFile` (CBOR → `Foreign` → decoder), or
-- | `Nothing` if it is absent/unreadable/undecodable. Shared by the build pipeline (type-directed
-- | lowering) and `ulib check` (interface comparison). The sync `decodeFirstSync` keeps the CLI
-- | `Aff`-free (ADR 0029).
module PursWasm.CLI.Externs
  ( readExterns
  ) where

import Prelude

import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect.Exception (try)
import Node.Cbor (decodeFirstSync)
import Node.Path (FilePath)
import PureScript.ExternsFile (ExternsFile)
import PureScript.ExternsFile.Decoder.Class (decoder)
import PureScript.ExternsFile.Decoder.Monad (runDecoder)
import PursWasm.CLI.Effect (FS, readBinary)
import Run (Run, EFFECT, liftEffect)
import Type.Row (type (+))

readExterns :: forall r. FilePath -> Run (FS + EFFECT + r) (Maybe ExternsFile)
readExterns path = do
  mbuf <- readBinary path
  case mbuf of
    Nothing -> pure Nothing
    Just buf -> do
      result <- liftEffect (try (decodeFirstSync buf))
      pure case result of
        Right fgn -> case runDecoder decoder fgn of
          Right ef -> Just ef
          Left _ -> Nothing
        Left _ -> Nothing
