-- | ulib lib-first resolution (ADR 0028 / 0031): scan the bundled lib (flat `$LIB/<Module>/`) for
-- | each module's shadow corefn and/or kept-foreign wasm; at link time the build's `shadowSet`
-- | (manifest + lock) decides which to use (`shadowOrRegistry`). Never fails the build.
module PursWasm.CLI.Ulib.Shadow
  ( Shadow
  , loadShadowMap
  , shadowOrRegistry
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.Set as Set
import Data.Traversable (for)
import Data.Tuple (Tuple(..))
import Fmt as Fmt
import PureScript.Backend.Wasm.Compiler (parseModule)
import PureScript.CoreFn (Module, ModuleName)
import PursWasm.CLI.Effect (FS, FilePath, LOG, debug, exists, joinPath, readDir, readText)
import PursWasm.CLI.Module (printModname)
import PursWasm.CLI.Ulib.Manifest (ulibManifestFile)
import Run (Run)
import Type.Row (type (+))

-- | A lib entry for a registry module: candidate paths for its shadow `corefn.json` and its
-- | kept-foreign `foreign.wasm` (ADR 0031 — either may be absent: a wat-only module has no corefn,
-- | a foreign-free shadow has no foreign.wasm). Existence is checked by the caller. The version is
-- | no longer stored — it lives in the manifest, and the build's `shadowSet` drives resolution.
type Shadow = { corefn :: FilePath, foreignWasm :: FilePath }

-- | Scan the (flat, ADR 0031 §2.2) lib: each `<lib>/<Module>/` holds a shadow `corefn.json` and/or a
-- | kept-foreign `foreign.wasm`. Returns a `Module name -> Shadow` map; an absent lib → empty.
loadShadowMap :: forall r. FilePath -> Run (FS + r) (Map String Shadow)
loadShadowMap libPath = do
  present <- exists libPath
  if not present then pure Map.empty
  else readDir libPath >>= case _ of
    Nothing -> pure Map.empty
    -- the lib root also holds the self-describing `ulib-manifest.json` (ADR 0031) — not a module dir.
    Just ms -> Map.fromFoldable <$> for (Array.filter (_ /= ulibManifestFile) ms) \m -> do
      corefn <- joinPath [ libPath, m, "corefn.json" ]
      foreignWasm <- joinPath [ libPath, m, "foreign.wasm" ]
      pure (Tuple m { corefn, foreignWasm })

-- | Use a module's ulib corefn (lib) iff it is in `shadowed` — the set the manifest-based
-- | `Manifest.shadowSet` computed (reached ∩ covered ∩ exact-version-match, ADR 0031). Otherwise
-- | the registry module. Never fails: a module in the set but absent from the lib, or an
-- | unreadable/unparsable lib corefn, falls back to the registry module. The version-drift warning
-- | is emitted once by the build (`warnUlibVersionDrift`), not here.
shadowOrRegistry :: forall r. Set String -> Map String Shadow -> ModuleName -> Module -> Run (FS + LOG + r) Module
shadowOrRegistry shadowed shadows mod registryMod =
  if not (Set.member name shadowed) then pure registryMod
  else case Map.lookup name shadows of
    Nothing -> pure registryMod
    Just s -> readText s.corefn >>= case _ of
      Nothing -> pure registryMod
      Just libSrc -> case parseModule libSrc of
        Left _ -> pure registryMod
        Right libMod -> do
          debug (Fmt.fmt @"ulib: shadowing {m}" { m: name })
          pure libMod
  where
  name = printModname mod
