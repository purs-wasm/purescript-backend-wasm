-- | ulib lib-first shadow resolution (ADR 0028): scan the bundled lib for shadow corefn, and at
-- | link time prefer a shadow over the user's registry module when the user's resolved package
-- | version matches (by `major.minor`) the shadow's target — else fall back to the registry
-- | module (correct, just unspecialized) with a warning. Never fails the build.
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
import PursWasm.CLI.Ulib.Version (splitPkgVer)
import Run (Run)
import Type.Row (type (+))

-- | A lib entry for a registry module: its package/version, the shadow corefn path, and the
-- | per-module `foreign.wasm` path (the assembled kept-foreign, ADR 0031 — may not exist for a
-- | module with no kept foreign). Both paths are *candidates*; existence is checked by the caller.
type Shadow = { package :: String, version :: String, corefn :: FilePath, foreignWasm :: FilePath }

-- | Scan the lib: each `<lib>/<package>-<version>/<Module>/` holds a shadow `corefn.json` and/or a
-- | kept-foreign `foreign.wasm`. Returns a `Module name -> Shadow` map; an absent lib → empty.
loadShadowMap :: forall r. FilePath -> Run (FS + r) (Map String Shadow)
loadShadowMap libPath = do
  present <- exists libPath
  if not present then pure Map.empty
  else readDir libPath >>= case _ of
    Nothing -> pure Map.empty
    Just pkgDirs -> do
      rows <- for pkgDirs \pkgVer -> do
        pkgPath <- joinPath [ libPath, pkgVer ]
        let { pkg, ver } = splitPkgVer pkgVer
        readDir pkgPath >>= case _ of
          Nothing -> pure []
          Just ms -> for ms \m -> do
            corefn <- joinPath [ pkgPath, m, "corefn.json" ]
            foreignWasm <- joinPath [ pkgPath, m, "foreign.wasm" ]
            pure (Tuple m { package: pkg, version: ver, corefn, foreignWasm })
      pure (Map.fromFoldable (Array.concat rows))

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
          debug (Fmt.fmt @"ulib: shadowing {m} ({pkg} {ver})" { m: name, pkg: s.package, ver: s.version })
          pure libMod
  where
  name = printModname mod
