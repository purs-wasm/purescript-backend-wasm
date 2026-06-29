-- | The global content-addressed artifact store (ADR 0040 §1/§2, P3). A compiled library module's
-- | three siblings — `{M}.pmi` (interface + optimization summary), `{M}.wasm` (object), and
-- | `{M}.link.json` (link metadata) — are written here keyed by content, so they are reusable across
-- | builds and across projects. The `.pmi` is platform-independent (keyed by its recursive `.pmi`
-- | key, ADR 0040 §2); the `.wasm` / `.link.json` are codegen-specific (keyed by the `.wasm` key =
-- | `.pmi` key ⊕ codegen axes ⊕ the module's kept-foreign `.wat`). The store is **opt-in** via
-- | `$PURS_WASM_STORE`; with it unset there is no global store and the per-project `_build` cache is
-- | used as before.
-- |
-- | P3 introduces write-back only (populate the store); store-*hit* (skip compilation for a key that
-- | is already present) is a following step. Concurrency-safe atomic writes and GC are deferred
-- | (ADR 0040 open question 3); a content-addressed file already present is left as-is.
module PureScript.Backend.Wasm.CLI.Store
  ( storeRoot
  , wasmKey
  , putStoreFile
  ) where

import Prelude

import Data.ArrayBuffer.Types (Uint8Array)
import Data.Maybe (Maybe(..))
import PureScript.Backend.Wasm.CLI.Effect (ENV, FS, FilePath, exists, joinPath, lookupEnv, mkdirP, writeBinary)
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Hash (hashString)
import Run (Run)
import Type.Row (type (+))

-- | The store root, from `$PURS_WASM_STORE`. `Nothing` (unset/empty) disables the global store.
storeRoot :: forall r. Run (ENV + r) (Maybe FilePath)
storeRoot = lookupEnv "PURS_WASM_STORE" <#> case _ of
  Just p | p /= "" -> Just p
  _ -> Nothing

-- | The `.wasm` / `.link.json` content key: the module's `.pmi` key combined with the codegen axes
-- | (`Compat.codegenTag`) and the hash of its kept-foreign `.wat` (empty when the module has none —
-- | a wat-only patch leaves the `.pmi`/corefn identical to the registry's but changes the object).
wasmKey :: String -> String -> String -> String
wasmKey pmiKey codegenTag foreignWatHash =
  hashString (pmiKey <> "\n" <> codegenTag <> "\n" <> foreignWatHash)

-- | Write `bytes` to `<root>/<name>` unless it already exists — a content-addressed name means an
-- | existing file has identical content, so a present artifact is never rewritten.
putStoreFile :: forall r. FilePath -> String -> Uint8Array -> Run (FS + r) Unit
putStoreFile root name bytes = do
  mkdirP root
  p <- joinPath [ root, name ]
  exists p >>= \present -> when (not present) (writeBinary p bytes)
