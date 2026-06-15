-- | The `.pmi` ("PureScript Module Interface") file: a module's cache **interface**, the
-- | small always-read half of the split incremental-build cache (ADR 0034, by analogy with
-- | OCaml's `.cmi`). It carries everything the warm driver needs *without* decoding or
-- | translating the corefn — to build the dependency graph, decide a hit, and supply a
-- | dependent's optimization context:
-- |
-- |  - `sourceHash` — the module's `corefn.json` digest, for the coarse decode-skip pre-pass
-- |                   (a module + all its transitive deps source-unchanged ⇒ a guaranteed hit,
-- |                   so it need not be decoded at all);
-- |  - `key`     — the cache key (source hash ⊕ consumed dependency-summary hashes);
-- |  - `deps`    — the precise dependency module names (`declRefs`-level, recorded when the
-- |                module was optimized), so the graph/key need no re-translation;
-- |  - `summary` — the pruned MIR dependents optimize against (ADR 0021 b1).
-- |
-- | Its object companion is the `.pmo` (`Serialize.Pmofile`, the finalized MIR); the two are
-- | written and read as a pair and share one format version (see `Pmofile`).
module PureScript.Backend.Wasm.MiddleEnd.Serialize.Pmifile
  ( PmiEntry
  , encodePmi
  , decodePmi
  ) where

import Prelude

import Data.Array as Array
import Data.ArrayBuffer.Types (Uint8Array)
import Data.Bifunctor (lmap)
import Data.Either (Either, either)
import Data.Foldable (traverse_)
import Data.Traversable (traverse)
import Effect (Effect)
import Effect.Exception (error, message, throwException, try)
import Effect.Unsafe (unsafePerformEffect)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Serialize (decode, encode)
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Bytes (finish, getBytes, getInt, getString, getU8, newReader, newWriter, putBytes, putInt, putString, putU8)

-- | A cache interface entry: source hash, validation key, precise dependency module names, and
-- | the pruned summary dependents consume.
type PmiEntry = { sourceHash :: String, key :: String, deps :: Array String, summary :: M.Module }

-- | ASCII "PWPMI".
magic :: Array Int
magic = [ 0x50, 0x57, 0x50, 0x4D, 0x49 ]

formatVersion :: Int
formatVersion = 1

-- | Serialize a cache interface entry to `.pmi` bytes.
encodePmi :: PmiEntry -> Uint8Array
encodePmi entry = unsafePerformEffect do
  w <- newWriter
  traverse_ (putU8 w) magic
  putU8 w formatVersion
  putString w entry.sourceHash
  putString w entry.key
  putInt w (Array.length entry.deps)
  traverse_ (putString w) entry.deps
  putBytes w (encode entry.summary)
  finish w

-- | Parse `.pmi` bytes back to a cache interface entry, or report why (bad magic, version
-- | mismatch, truncation, or a malformed summary). Pure: a failure is a `Left`, so a
-- | corrupt or stale `.pmi` degrades to a cache miss, never a wrong tree.
decodePmi :: Uint8Array -> Either String PmiEntry
decodePmi bytes = unsafePerformEffect $ map (lmap message) $ try do
  r <- newReader bytes
  read <- traverse (\_ -> getU8 r) magic
  v <- getU8 r
  when (read /= magic) (fail "not a .pmi file (bad magic)")
  when (v /= formatVersion) (fail ("unsupported .pmi version: " <> show v))
  sourceHash <- getString r
  key <- getString r
  n <- getInt r
  deps <- if n <= 0 then pure [] else traverse (\_ -> getString r) (Array.range 1 n)
  summaryBytes <- getBytes r
  summary <- either fail pure (decode summaryBytes)
  pure { sourceHash, key, deps, summary }

fail :: forall a. String -> Effect a
fail = throwException <<< error
