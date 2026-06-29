-- | The `.pmi` ("PureScript Module Interface") file: a module's cache **interface**, the
-- | small always-read half of the split incremental-build cache (ADR 0034, by analogy with
-- | OCaml's `.cmi`). It carries everything a dependent needs *without* reading the module's
-- | object code (`.pmo`):
-- |
-- |  - `sourceHash` — the module's `corefn.json` digest, for the coarse decode-skip pre-pass;
-- |  - `key`     — the cache key (source hash ⊕ consumed dependency-summary hashes);
-- |  - `deps`    — the precise dependency module names (`declRefs`-level);
-- |  - `summary` — the pruned MIR dependents OPTIMIZE against (ADR 0021 b1);
-- |  - the **lowering interface** (ADR 0038 Phase B): `funcs`/`ctors`/`dictCtors`/`enumCtors`/
-- |    `foreignSigs`/`foreignNames` — the symbol signatures a dependent LOWERS against (so it can
-- |    codegen a cross-module callee without ever reading this module's compiled body); and `labels`,
-- |    this module's record-label ids (for the orchestrator's pre-merge hash-collision check).
-- |
-- | The `.pmi` interface + summary and the per-module `.wasm` object are the cache artifacts (ADR
-- | 0040): the separate optimized-MIR object (`.pmo`) is retired — the interface absorbs everything
-- | dependents need, and the orchestrate store holds the compiled `.wasm`.
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
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Exception (error, message, throwException, try)
import Effect.Unsafe (unsafePerformEffect)
import Foreign.Object (Object)
import Foreign.Object as Object
import PureScript.Backend.Wasm.Lower.IR (MarshalKind(..), Rep(..), ForeignImport)
import PureScript.Backend.Wasm.Lower.Types (CtorInfo)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Serialize (decode, encode)
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Bytes (Reader, Writer, finish, getBytes, getInt, getString, getU8, newReader, newWriter, putBytes, putInt, putString, putU8)

-- | A cache interface entry: the cache header (source hash, validation key, dependency names),
-- | the optimization `summary`, and the lowering interface tables (ADR 0038 Phase B).
type PmiEntry =
  { sourceHash :: String
  , key :: String
  , deps :: Array String
  , summary :: M.Module
  -- the lowering interface (ADR 0038 Phase B): a dependent merges these to lower its
  -- cross-module callees without reading this module's `.pmo`.
  , funcs :: Object Int
  , ctors :: Object CtorInfo
  , dictCtors :: Object Unit
  , enumCtors :: Object Unit
  , foreignSigs :: Object ForeignImport
  , foreignNames :: Array String
  -- this module's record-label ids; consumed only by the orchestrator's pre-merge collision check.
  , labels :: Object Int
  }

-- | ASCII "PWPMI".
magic :: Array Int
magic = [ 0x50, 0x57, 0x50, 0x4D, 0x49 ]

-- | Bumped to 2 for the lowering-interface fields (ADR 0038 Phase B M2a); a stale v1 `.pmi` fails the
-- | version guard and degrades to a clean miss. The format itself is unchanged by retiring `.pmo`
-- | (ADR 0040) — the `.pmi` bytes are the same, so existing store artifacts stay valid.
formatVersion :: Int
formatVersion = 2

-- | Serialize a cache interface entry to `.pmi` bytes.
encodePmi :: PmiEntry -> Uint8Array
encodePmi entry = unsafePerformEffect do
  w <- newWriter
  traverse_ (putU8 w) magic
  putU8 w formatVersion
  putString w entry.sourceHash
  putString w entry.key
  putArr w (putString w) entry.deps
  putBytes w (encode entry.summary)
  putObject w (putInt w) entry.funcs
  putObject w (putCtorInfo w) entry.ctors
  putObject w putUnit entry.dictCtors
  putObject w putUnit entry.enumCtors
  putObject w (putForeignImport w) entry.foreignSigs
  putArr w (putString w) entry.foreignNames
  putObject w (putInt w) entry.labels
  finish w

-- | Parse `.pmi` bytes back to a cache interface entry, or report why (bad magic, version
-- | mismatch, truncation, or a malformed summary). Pure: a failure is a `Left`, so a corrupt
-- | or stale `.pmi` degrades to a cache miss, never a wrong tree.
decodePmi :: Uint8Array -> Either String PmiEntry
decodePmi bytes = unsafePerformEffect $ map (lmap message) $ try do
  r <- newReader bytes
  read <- traverse (\_ -> getU8 r) magic
  v <- getU8 r
  when (read /= magic) (fail "not a .pmi file (bad magic)")
  when (v /= formatVersion) (fail ("unsupported .pmi version: " <> show v))
  sourceHash <- getString r
  key <- getString r
  deps <- getArr r (getString r)
  summaryBytes <- getBytes r
  summary <- either fail pure (decode summaryBytes)
  funcs <- getObject r (getInt r)
  ctors <- getObject r (getCtorInfo r)
  dictCtors <- getObject r getUnit
  enumCtors <- getObject r getUnit
  foreignSigs <- getObject r (getForeignImport r)
  foreignNames <- getArr r (getString r)
  labels <- getObject r (getInt r)
  pure { sourceHash, key, deps, summary, funcs, ctors, dictCtors, enumCtors, foreignSigs, foreignNames, labels }

-- --- codecs for the interface tables (Bytes primitives only) ---

-- | A length-prefixed homogeneous array.
putArr :: forall a. Writer -> (a -> Effect Unit) -> Array a -> Effect Unit
putArr w put xs = putInt w (Array.length xs) *> traverse_ put xs

getArr :: forall a. Reader -> Effect a -> Effect (Array a)
getArr r get = do
  n <- getInt r
  if n <= 0 then pure [] else traverse (\_ -> get) (Array.range 1 n)

-- | An `Object a` as a length-prefixed list of (key, value) pairs (the `LitObject` shape).
putObject :: forall a. Writer -> (a -> Effect Unit) -> Object a -> Effect Unit
putObject w put o = putArr w (\(Tuple k v) -> putString w k *> put v) (Object.toUnfoldable o)

getObject :: forall a. Reader -> Effect a -> Effect (Object a)
getObject r get = Object.fromFoldable <$> getArr r (Tuple <$> getString r <*> get)

putUnit :: Unit -> Effect Unit
putUnit _ = pure unit

getUnit :: Effect Unit
getUnit = pure unit

putRep :: Writer -> Rep -> Effect Unit
putRep w = case _ of
  I32 -> putU8 w 0
  F64 -> putU8 w 1
  Boxed -> putU8 w 2
  CloRef -> putU8 w 3

getRep :: Reader -> Effect Rep
getRep r = getU8 r >>= case _ of
  0 -> pure I32
  1 -> pure F64
  2 -> pure Boxed
  3 -> pure CloRef
  n -> fail ("bad Rep tag: " <> show n)

putCtorInfo :: Writer -> CtorInfo -> Effect Unit
putCtorInfo w c = putInt w c.tag *> putInt w c.arity *> putArr w (putRep w) c.fieldReps

getCtorInfo :: Reader -> Effect CtorInfo
getCtorInfo r = do
  tag <- getInt r
  arity <- getInt r
  fieldReps <- getArr r (getRep r)
  pure { tag, arity, fieldReps }

-- | The recursive FFI marshalling-kind enum (ADR 0014).
putMarshalKind :: Writer -> MarshalKind -> Effect Unit
putMarshalKind w = case _ of
  MI32 -> putU8 w 0
  MF64 -> putU8 w 1
  MBool -> putU8 w 2
  MStr -> putU8 w 3
  MOpaque -> putU8 w 4
  MArray k -> putU8 w 5 *> putMarshalKind w k
  MEffect k -> putU8 w 6 *> putMarshalKind w k
  MFunc a b -> putU8 w 7 *> putMarshalKind w a *> putMarshalKind w b
  MRecord fs -> putU8 w 8 *> putArr w (\(Tuple l k) -> putString w l *> putMarshalKind w k) fs

getMarshalKind :: Reader -> Effect MarshalKind
getMarshalKind r = getU8 r >>= case _ of
  0 -> pure MI32
  1 -> pure MF64
  2 -> pure MBool
  3 -> pure MStr
  4 -> pure MOpaque
  5 -> MArray <$> getMarshalKind r
  6 -> MEffect <$> getMarshalKind r
  7 -> MFunc <$> getMarshalKind r <*> getMarshalKind r
  8 -> MRecord <$> getArr r (Tuple <$> getString r <*> getMarshalKind r)
  n -> fail ("bad MarshalKind tag: " <> show n)

putForeignImport :: Writer -> ForeignImport -> Effect Unit
putForeignImport w fi = do
  putString w fi.moduleName
  putString w fi.base
  putArr w (putMarshalKind w) fi.params
  putMarshalKind w fi.result

getForeignImport :: Reader -> Effect ForeignImport
getForeignImport r = do
  moduleName <- getString r
  base <- getString r
  params <- getArr r (getMarshalKind r)
  result <- getMarshalKind r
  pure { moduleName, base, params, result }

fail :: forall a. String -> Effect a
fail = throwException <<< error
