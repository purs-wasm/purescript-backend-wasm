-- | ulib support manifest (ADR 0031): `ulib-manifest.json` is the single source of truth for which
-- | packages/modules ulib covers and at which version. This module reads it and runs the build-time
-- | **version check** — for each *reached* ulib package, compare the user's resolved version
-- | (`spago.lock`) to the manifest version. It is self-contained (the `spago.lock` reader lives here,
-- | not in the soon-to-be-retired `Ulib.Compat`) and pure where it can be.
-- |
-- | ADR 0031 migration phase 1: the result is *warned*, never fatal — this lays the new rail beside
-- | the existing `Ulib.Shadow.shadowOrRegistry` without changing behaviour.
module PursWasm.CLI.Ulib.Manifest
  ( PkgEntry
  , Manifest
  , readManifest
  , parseManifest
  , LockView
  , parseLock
  , lockVersion
  , Mismatch
  , reachedMismatches
  , shadowSet
  , manifestPackages
  ) where

import Prelude

import Control.Alt ((<|>))
import Data.Argonaut.Core (Json, toArray, toObject, toString)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (hush)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Foreign.Object (Object)
import Foreign.Object as FO
import PursWasm.CLI.Effect (FS, FilePath, readText)
import Run (Run)
import Type.Row (type (+))

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

-- | The set of modules that resolve to the ulib (lib) corefn under the new policy (ADR 0031): a
-- | covered module is used iff it is reachable AND its package's resolved version (`spago.lock`)
-- | **exactly** equals the manifest version. This is the resolution the last-wins merge will drive;
-- | in migration phase 2 it is computed only to diff against the legacy `shadowOrRegistry`.
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
