-- | ulib support manifest (ADR 0031): `ulib-manifest.json` is the single source of truth for which
-- | packages/modules ulib covers and at which version. This module reads it and drives resolution:
-- | `shadowSet` / `resolveModuleSet` decide which modules are taken from the lib, and the build-time
-- | **version check** (`reachedMismatches`) compares each *reached* ulib package's resolved version
-- | (`spago.lock`) to the manifest version. Self-contained (the `spago.lock` reader lives here, not in
-- | the soon-to-be-retired `Ulib.Compat`) and pure where it can be.
module PursWasm.CLI.Ulib.Manifest
  ( PkgEntry
  , Manifest
  , ulibManifestFile
  , headerWatFile
  , isLibModuleDir
  , readManifest
  , parseManifest
  , LockView
  , parseLock
  , lockVersion
  , Mismatch
  , reachedMismatches
  , shadowSet
  , manifestPackages
  , manifestModules
  , ResolvedModules
  , resolveModuleSet
  ) where

import Prelude

import Control.Alt ((<|>))
import Data.Argonaut.Core (Json, toArray, toObject, toString)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (hush)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Foreign.Object (Object)
import Foreign.Object as FO
import PureScript.CoreFn (ModuleName)
import PursWasm.CLI.Effect (FS, FilePath, readText)
import PursWasm.CLI.Module (reachableClosure)
import Run (Run)
import Type.Row (type (+))

-- | The manifest's filename. It is copied into the installed lib (`$LIB/ulib-manifest.json`, ADR
-- | 0031) so the precompiled lib is self-describing — a user with only `$PURS_WASM_LIB` (no ulib
-- | source tree) can still resolve shadows and `validate`. Lib scanners filter this entry out.
ulibManifestFile :: String
ulibManifestFile = "ulib-manifest.json"

-- | The shared wat header's filename, shipped at the lib root (`$LIB/_header.wat`, ADR 0031) so
-- | assembling a project-local foreign `.wat` fragment needs no ulib source tree.
headerWatFile :: String
headerWatFile = "_header.wat"

-- | Whether a lib-root entry is a module directory rather than one of the self-describing files the
-- | lib also carries at its root (`ulib-manifest.json`, `_header.wat`). The lib scanners
-- | (`loadShadowMap`, `ulib check` / `validate`) use this to ignore those files.
isLibModuleDir :: String -> Boolean
isLibModuleDir name = name /= ulibManifestFile && name /= headerWatFile

-- | A manifest entry: the one supported version of a ulib package, and the modules it covers.
type PkgEntry = { version :: String, modules :: Array String }

-- | `package name -> entry`.
type Manifest = Map String PkgEntry

-- | Read and parse `ulib-manifest.json`; an absent / unparsable file is `Nothing` (the check is
-- | then skipped, never an error).
readManifest :: forall r. FilePath -> Run (FS + r) (Maybe Manifest)
readManifest path = (_ >>= parseManifest) <$> readText path

parseManifest :: String -> Maybe Manifest
parseManifest txt = do
  obj <- toObject =<< hush (jsonParser txt)
  Map.fromFoldable <$> traverse entry (FO.toUnfoldable obj :: Array (Tuple String Json))
  where
  entry (Tuple pkg v) = do
    vobj <- toObject v
    version <- toString =<< FO.lookup "version" vobj
    modules <- traverse toString =<< toArray =<< FO.lookup "modules" vobj
    pure (Tuple pkg { version, modules })

-- ─────────────────────────── spago.lock (the resolved-version source) ───────────────────────────

type LockView =
  { content :: Object Json
  , packages :: Object Json
  }

parseLock :: String -> LockView
parseLock txt =
  { content: maybe FO.empty identity (pkgSet >>= field "content" >>= toObject)
  , packages: maybe FO.empty identity (mj >>= field "packages" >>= toObject)
  }
  where
  mj = hush (jsonParser txt)
  pkgSet = mj >>= field "workspace" >>= field "package_set"
  field k j = toObject j >>= FO.lookup k

-- | The version the workspace resolves for a package: its `package_set.content` override, else the
-- | resolved `packages.<pkg>.version`, else nothing.
lockVersion :: LockView -> String -> Maybe String
lockVersion lock pkg =
  (FO.lookup pkg lock.content >>= toString)
    <|> (FO.lookup pkg lock.packages >>= \p -> toObject p >>= FO.lookup "version" >>= toString)

-- ─────────────────────────────────── the version check ───────────────────────────────────

type Mismatch = { package :: String, want :: String, got :: Maybe String }

-- | One mismatch per **reached** ulib package whose resolved version (`spago.lock`) differs from the
-- | supported version (manifest). "Reached" = at least one of the package's covered modules is in
-- | the reachable closure, so an unused package's version is ignored (ADR 0031 §4 "pay for what you
-- | use"). Exact-version comparison (ulib targets exactly one version).
reachedMismatches :: Manifest -> LockView -> Set String -> Array Mismatch
reachedMismatches manifest lock reached =
  Array.mapMaybe check (Map.toUnfoldable manifest)
  where
  check (Tuple package entry) =
    let
      got = lockVersion lock package
    in
      if Array.any (\m -> Set.member m reached) entry.modules && got /= Just entry.version then Just { package, want: entry.version, got }
      else Nothing

-- | The set of registry modules that resolve to the ulib (lib) corefn (ADR 0031): a covered module is
-- | used iff it is reachable AND its package's resolved version (`spago.lock`) **exactly** equals the
-- | manifest version. `resolveModuleSet` calls this each fixpoint round to decide the shadowed set.
shadowSet :: Manifest -> LockView -> Set String -> Set String
shadowSet manifest lock reached =
  Set.fromFoldable (Array.concatMap covered (Map.toUnfoldable manifest))
  where
  covered (Tuple pkg entry) =
    if lockVersion lock pkg == Just entry.version then Array.filter (\m -> Set.member m reached) entry.modules
    else []

-- | The packages the manifest covers, each with its supported version — the `{pkg, ver}` shape the
-- | (legacy, pre-0031) `ulib compat` derived from the `ulib/shadow/<pkg>-<ver>` directory names.
manifestPackages :: Manifest -> Array { pkg :: String, ver :: String }
manifestPackages = map (\(Tuple pkg entry) -> { pkg, ver: entry.version }) <<< Map.toUnfoldable

-- | Every registry module the manifest covers (across all packages). A lib module *outside* this set
-- | is a ulib internal helper (ADR 0031 §6) with no registry counterpart.
manifestModules :: Manifest -> Set String
manifestModules = Set.fromFoldable <<< Array.concatMap _.modules <<< Array.fromFoldable <<< Map.values

-- ─────────────────────────── module-set resolution (ADR 0031 §6) ───────────────────────────

-- | The resolved build module set + the per-module source decision (ADR 0031 §6). `reachable` is the
-- | final transitive closure; `libSourced` are the modules whose **corefn** must come from the lib (a
-- | shadowed registry module *or* an injected internal helper). A foreign-only ulib module (e.g.
-- | `Data.Int`) can be in `libSourced` yet have no lib corefn — the caller falls back to the registry
-- | corefn in that case.
type ResolvedModules = { reachable :: Set String, libSourced :: Set String }

-- | Resolve the module set via the **plan → recompute → materialize** fixpoint (ADR 0031 §6). Pure:
-- | the FS reads (user + lib corefn import lists) are hoisted out by the caller. `userMods` is the set
-- | of modules the user compiled; `userImports` / `libImports` are each module's import list from the
-- | user output / the lib (only lib modules with a corefn appear in `libImports`). Starting from the
-- | empty plan, each round recomputes the closure under the current source decision (lib import lists
-- | for `libSourced` modules, so a shadow's private helper becomes reachable), then re-derives the
-- | plan: `libSourced = shadowed ∪ internal`, where `internal` is a reached module the lib provides
-- | but the user did not (i.e. not a registry module). "reached" only grows and the version match is
-- | static, so the plan is **monotone** and converges (typically a round or two — one per level of
-- | internal nesting, rarely more than one).
resolveModuleSet
  :: Array ModuleName
  -> Set String
  -> Map String (Array String)
  -> Map String (Array String)
  -> Maybe Manifest
  -> Maybe LockView
  -> ResolvedModules
resolveModuleSet roots userMods userImports libImports mManifest mLock = go Set.empty
  where
  allNames = Set.toUnfoldable (Set.fromFoldable (Map.keys userImports) <> Set.fromFoldable (Map.keys libImports)) :: Array String
  shadowedOf reached = fromMaybe Set.empty (shadowSet <$> mManifest <*> mLock <*> pure reached)
  -- a reached module the lib provides (has a corefn) but the user does not compile → inject it.
  internalOf reached = Set.filter (\n -> not (Set.member n userMods) && Map.member n libImports) reached
  importsOf libSourced n = fromMaybe [] (Map.lookup n (if Set.member n libSourced then libImports else userImports))
  go libSourced =
    let
      reachable = reachableClosure roots (Map.fromFoldable (allNames <#> \n -> Tuple n (importsOf libSourced n)))
      libSourced' = Set.union (shadowedOf reachable) (internalOf reachable)
    in
      if libSourced' == libSourced then { reachable, libSourced } else go libSourced'
