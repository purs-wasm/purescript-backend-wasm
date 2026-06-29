-- | Decode a module's `externs.cbor` into an `ExternsFile` (CBOR → `Foreign` → decoder), or
-- | `Nothing` if it is absent/unreadable/undecodable. Shared by the build pipeline (type-directed
-- | lowering) and `ulib check` (interface comparison). The sync `decodeFirstSync` keeps the CLI
-- | `Aff`-free (ADR 0029).
module PureScript.Backend.Wasm.CLI.Externs
  ( readExterns
  ) where

import Prelude

import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect.Exception (try)
-- NOTE: This is the last place command logic still touches `Node.*` directly. For portability
-- (the WASI self-host goal) CBOR decoding should be a Run effect interpreted in the Node handler,
-- as we did for path ops (`joinPath`/`resolvePath`). Deferred: a one-off CBOR effect is not worth
-- it yet, so `decodeFirstSync` is used inline for now. Revisit when a second backend needs it.
import Node.Cbor (decodeFirstSync)
import PureScript.ExternsFile (ExternsFile)
import PureScript.ExternsFile.Decoder.Class (decoder)
import PureScript.ExternsFile.Decoder.Monad (runDecoder)
import PureScript.Backend.Wasm.CLI.Effect (FS, FilePath, readBinary)
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
