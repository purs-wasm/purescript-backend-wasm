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
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Traversable (for)
import Data.Tuple (Tuple(..))
import Fmt as Fmt
import PureScript.Backend.Wasm.Compiler (parseModule)
import PureScript.CoreFn (Module, ModuleName)
import PursWasm.CLI.Effect (FS, FilePath, LOG, debug, exists, info, joinPath, readDir, readText)
import PursWasm.CLI.Module (printModname)
import PursWasm.CLI.Ulib.Version (majorMinor, pkgVersionFromPath, splitPkgVer)
import Run (Run)
import Type.Row (type (+))

-- | The registry modules ulib shadows, each tied to the *package* version its shadow targets.
type Shadow = { package :: String, version :: String, corefn :: FilePath }

-- | Scan the lib for shadows: each `<lib>/<package>-<version>/<Module>/corefn.json` is a shadow of
-- | registry module `<Module>`. Returns a `Module name -> Shadow` map; an absent lib → empty.
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
          Just ms -> for ms \m ->
            joinPath [ pkgPath, m, "corefn.json" ] <#> \corefn -> Tuple m { package: pkg, version: ver, corefn }
      pure (Map.fromFoldable (Array.concat rows))

-- | Use a module's ulib shadow if its target version matches (by `major.minor`) the user's
-- | resolved version; otherwise the registry module, with a warning. Never fails.
shadowOrRegistry :: forall r. Map String Shadow -> ModuleName -> Module -> Run (FS + LOG + r) Module
shadowOrRegistry shadows mod registryMod = case Map.lookup (printModname mod) shadows of
  Nothing -> pure registryMod
  Just s
    | (majorMinor <$> pkgVersionFromPath s.package registryMod.path) /= Just (majorMinor s.version) -> do
        info
          ( Fmt.fmt
              @"  ulib: {m} not shadowed ({pkg} {got} ≠ supported {want}); using registry (foreign HOF stays slow)"
              { m: printModname mod, pkg: s.package, got: fromMaybe "?" (pkgVersionFromPath s.package registryMod.path), want: s.version }
          )
        pure registryMod
    | otherwise -> readText s.corefn >>= case _ of
        Nothing -> pure registryMod
        Just libSrc -> case parseModule libSrc of
          Left _ -> pure registryMod
          Right libMod -> do
            debug (Fmt.fmt @"ulib: shadowing {m} ({pkg} {ver})" { m: printModname mod, pkg: s.package, ver: s.version })
            pure libMod
