-- | The `.pmo` ("PureScript Module Object") file container: the on-disk form of one
-- | module's incremental-build cache entry (ADR 0032 phase 4 / ADR 0021 *Future:
-- | incremental compilation cache*; ADR 0033 reuses this for shipped `ulib` artifacts).
-- |
-- | A `.pmo` is **header + body**. The header is a magic number, a format version, and
-- | the **cache key** (`Serialize.Hash.cacheKey`: the source hash ⊕ the consumed
-- | dependency-summary hashes) — recomputed and compared on a build to decide hit/miss.
-- | The body is the module's optimized MIR, as two `Serialize`-encoded sub-documents:
-- | the **finalized** module (fed to codegen) and its pruned **summary** (the context
-- | later modules optimize against, ADR 0021 b1). Both are needed to resume the
-- | dependency-ordered loop from a cache hit without re-optimizing.
-- |
-- | The version byte covers the whole `.pmo` format (this container *and* the `Serialize`
-- | body codec): bump it on any change to either, so stale caches are rejected as a miss
-- | rather than mis-parsed.
module PureScript.Backend.Wasm.MiddleEnd.Serialize.Pmofile
  ( PmoEntry
  , encodePmo
  , decodePmo
  ) where

import Prelude

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
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Bytes (finish, getBytes, getString, getU8, newReader, newWriter, putBytes, putString, putU8)

-- | One cached module: the validation `key`, the finalized MIR for codegen, and the
-- | pruned `summary` later modules optimize against.
type PmoEntry = { key :: String, finalMod :: M.Module, summary :: M.Module }

-- | ASCII "PWPMO" (PureScript Wasm PureScript Module Object), the `.pmo` magic.
magic :: Array Int
magic = [ 0x50, 0x57, 0x50, 0x4D, 0x4F ]

formatVersion :: Int
formatVersion = 1

-- | Serialize a cache entry to `.pmo` bytes. Pure and total (the internal `Effect` only
-- | drives the byte buffer).
encodePmo :: PmoEntry -> Uint8Array
encodePmo entry = unsafePerformEffect do
  w <- newWriter
  traverse_ (putU8 w) magic
  putU8 w formatVersion
  putString w entry.key
  putBytes w (encode entry.finalMod)
  putBytes w (encode entry.summary)
  finish w

-- | Parse `.pmo` bytes back to a cache entry, or report why (bad magic, version
-- | mismatch, truncation, or a malformed body). Pure: any failure is a `Left`, so a
-- | corrupt or stale `.pmo` degrades to a cache miss and a recompute, never a wrong tree.
decodePmo :: Uint8Array -> Either String PmoEntry
decodePmo bytes = unsafePerformEffect $ map (lmap message) $ try do
  r <- newReader bytes
  read <- traverse (\_ -> getU8 r) magic
  v <- getU8 r
  when (read /= magic) (fail "not a .pmo file (bad magic)")
  when (v /= formatVersion) (fail ("unsupported .pmo version: " <> show v))
  key <- getString r
  finBytes <- getBytes r
  sumBytes <- getBytes r
  finalMod <- either fail pure (decode finBytes)
  summary <- either fail pure (decode sumBytes)
  pure { key, finalMod, summary }

fail :: forall a. String -> Effect a
fail = throwException <<< error
