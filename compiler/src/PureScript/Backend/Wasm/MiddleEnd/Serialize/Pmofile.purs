-- | The `.pmo` ("PureScript Module Object") file: a module's **finalized** optimized MIR
-- | (the body fed to codegen), the *object* half of the split incremental-build cache
-- | (ADR 0034). Its interface companion is the `.pmi` (`Serialize.Pmifile`); the two are
-- | written and read as a pair. A `.pmo` is loaded only to emit a module's code — never to
-- | decide a cache hit or to optimize a dependent, which read the small `.pmi` instead.
-- |
-- | Layout: the magic `"PWPMO"`, a format version, then the finalized module as a
-- | length-prefixed `Serialize` body. The version covers both `.pmi` and `.pmo`; bump it
-- | on any change to either so stale caches are rejected rather than mis-parsed.
module PureScript.Backend.Wasm.MiddleEnd.Serialize.Pmofile
  ( encodePmo
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
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Bytes (finish, getBytes, getU8, newReader, newWriter, putBytes, putU8)

-- | ASCII "PWPMO".
magic :: Array Int
magic = [ 0x50, 0x57, 0x50, 0x4D, 0x4F ]

-- | Shared with `.pmi` (`Pmifile`); bumped to 2 for the `.pmi` lowering-interface fields
-- | (ADR 0038 Phase B M2a) so a stale v1 cache is rejected rather than mis-parsed.
formatVersion :: Int
formatVersion = 2

-- | Serialize a module's finalized MIR to `.pmo` bytes.
encodePmo :: M.Module -> Uint8Array
encodePmo finalMod = unsafePerformEffect do
  w <- newWriter
  traverse_ (putU8 w) magic
  putU8 w formatVersion
  putBytes w (encode finalMod)
  finish w

-- | Parse `.pmo` bytes back to the finalized MIR, or report why (bad magic, version
-- | mismatch, or a malformed body). Pure: a failure is a `Left`, so a corrupt or stale
-- | `.pmo` degrades to a cache miss, never a wrong tree.
decodePmo :: Uint8Array -> Either String M.Module
decodePmo bytes = unsafePerformEffect $ map (lmap message) $ try do
  r <- newReader bytes
  read <- traverse (\_ -> getU8 r) magic
  v <- getU8 r
  when (read /= magic) (fail "not a .pmo file (bad magic)")
  when (v /= formatVersion) (fail ("unsupported .pmo version: " <> show v))
  body <- getBytes r
  either fail pure (decode body)

fail :: forall a. String -> Effect a
fail = throwException <<< error
