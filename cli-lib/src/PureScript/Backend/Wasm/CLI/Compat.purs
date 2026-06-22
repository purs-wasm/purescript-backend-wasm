-- | Two compatibility guards over the linked modules, both pure (`Either String Unit`):
-- |
-- |   * `checkWasmBaseCompat` (ADR 0026) — every `Wasm.*` foreign must resolve to a backend
-- |     intrinsic; an unrecognised one means the `wasm-base` is newer than this backend supports.
-- |   * `checkCorefnVersions` (ADR 0029) — every linked module (the user's app *or* a ulib shadow)
-- |     must be compiled by a `purs` whose CoreFn this backend's decoder is verified against, so a
-- |     breaking CoreFn change surfaces as a clear error rather than a silent miscompile.
module PureScript.Backend.Wasm.CLI.Compat
  ( checkWasmBaseCompat
  , supportedCorefn
  , checkCorefnVersions
  , backendCacheVersion
  , toolchainTag
  , codegenTag
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe, isJust) as M
import Data.String (Pattern(..))
import Data.String as Str
import Fmt as Fmt
import PureScript.Backend.Wasm.Intrinsics (foreignIntrinsic, qualifiedIntrinsic)
import PureScript.CoreFn (ModuleName)

-- | `Wasm.*` is `wasm-base`'s reserved namespace, and its foreigns are meant to resolve to *this*
-- | backend's intrinsics. A `Wasm.*` foreign this backend does not recognise means the `wasm-base`
-- | is newer than the backend supports — fail with a clear message rather than degrading silently.
-- | The `backendVersion` is supplied by the caller (each binary has its own version string), so this
-- | shared check stays decoupled from any one binary's `Version` module.
checkWasmBaseCompat :: forall r. String -> Array { name :: ModuleName, foreignNames :: Array String | r } -> Either String Unit
checkWasmBaseCompat backendVersion modules = case Array.nub (modules >>= unsupported) of
  [] -> Right unit
  bad -> Left
    ( Fmt.fmt
        @"This purs-wasm backend ({backend}) does not provide {n} `Wasm.*` primitive(s): {names}. Your `wasm-base` is newer than this backend supports — install a `wasm-base` compatible with it."
        { backend: backendVersion, n: Array.length bad, names: Str.joinWith ", " bad }
    )
  where
  unsupported m
    | Array.head m.name == M.Just "Wasm" = Array.filter (not <<< recognized) (map (qualified m.name) m.foreignNames)
    | otherwise = []
  qualified modName fn = Str.joinWith "." modName <> "." <> fn
  recognized qual = M.isJust (qualifiedIntrinsic qual) || M.isJust (foreignIntrinsic (lastSegment qual))
  lastSegment q = M.fromMaybe q (Array.last (Str.split (Pattern ".") q))

-- | The purs compiler version(s) whose CoreFn format this backend's decoder is verified against
-- | (ADR 0029). Widen only after testing the decoder against the new compiler's output.
supportedCorefn :: Array String
supportedCorefn = [ "0.15.16" ]

-- | A manually-bumped tag for the backend's **output-affecting** behaviour (optimizer + lowering +
-- | codegen). It is part of the `.pmi` cache key (ADR 0040) so a compiler change that alters a
-- | module's compiled output invalidates every cached artifact, even when the module source is
-- | unchanged. It is a *shared* constant — both the `purwc` worker and the `purs-wasm` orchestrator
-- | (and the whole-program oracle) read the same value, so their cache keys agree byte-for-byte (the
-- | differential `diffPurwc` `.pmi` byte-parity contract requires this). Bump it on any optimizer /
-- | lowering / codegen change whose output should not be served from a stale cache. (The `purs` /
-- | CoreFn-format axis is `supportedCorefn`; the per-binary CLI `Version` strings are deliberately
-- | NOT used here — they can differ between binaries and would break key agreement.)
backendCacheVersion :: String
backendCacheVersion = "1"

-- | The toolchain component of the `.pmi` content-address (ADR 0040 §2): the axes that affect a
-- | module's interface + optimization summary — the `purs`/CoreFn pin and the backend output version.
-- | Platform / optimization-level / per-module-rep are *codegen* axes that affect only the object
-- | (`.wasm`), not the `.pmi`, so they belong in the `.wasm` key (a later phase), not here. Folded
-- | into each module's source hash at the CLI boundary so it enters the cache key without threading a
-- | new parameter through the optimizer.
toolchainTag :: String
toolchainTag = "corefn=" <> Str.joinWith "," supportedCorefn <> ";backend=" <> backendCacheVersion

-- | The codegen-axis component of the `.wasm` / `.link.json` content-address (ADR 0040 §2 / P3): the
-- | axes that affect the *object* but not the `.pmi` — target platform, optimization on/off, and the
-- | per-module-rep flag — plus the backend version. Combined with the `.pmi` key (which already
-- | carries `toolchainTag`) it forms the object's store key, so two builds that differ only in
-- | platform/opt get distinct `.wasm` artifacts but can still share the platform-independent `.pmi`.
codegenTag :: { platform :: String, optimize :: Boolean, perModuleRep :: Boolean } -> String
codegenTag o =
  "platform=" <> o.platform
    <> ";opt="
    <> (if o.optimize then "1" else "0")
    <> ";pmr="
    <> (if o.perModuleRep then "1" else "0")
    <> ";backend="
    <> backendCacheVersion

-- | Reject any linked module whose `builtWith` compiler is not one this backend supports.
checkCorefnVersions :: forall r. Array { name :: ModuleName, builtWith :: String | r } -> Either String Unit
checkCorefnVersions modules = case Array.filter (\m -> not (Array.elem m.builtWith supportedCorefn)) modules of
  [] -> Right unit
  bad -> Left
    ( Fmt.fmt
        @"{n} module(s) were compiled with an unsupported purs (version(s): {versions}); e.g. {egs}{more}. This purs-wasm decodes CoreFn from {supported} — rebuild with that compiler (your project and the bundled ulib lib must agree on it)."
        { n: Array.length bad
        , versions: Str.joinWith ", " (Array.nub (map _.builtWith bad))
        , egs: Str.joinWith ", " (map (Str.joinWith "." <<< _.name) (Array.take 5 bad))
        , more: if Array.length bad > 5 then ", …" else ""
        , supported: Str.joinWith ", " supportedCorefn
        }
    )
