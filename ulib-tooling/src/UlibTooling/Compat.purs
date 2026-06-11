-- | `purs-wasm ulib compat` — regenerate (or `--check`) `ulib/compat.json`, the record of which
-- | package-set version the ulib shadows are pinned to, the exact version each shadow targets, and
-- | the `purs` compiler the shipped lib is built with (ADR 0028/0029).
-- |
-- | `spago.lock` is the authoritative version source; the shadow set + versions come from
-- | `ulib-manifest.json` (ADR 0031); the purs pin is cross-checked (regenerate only, online best-effort) against
-- | the registry's per-version `compilers` lists via `spago registry info <pkg> --json`.
-- |
-- | Paths are cwd-relative (the command is run from the repo root, like the prototype). The pure
-- | decision logic (`withinConstraint`/`supportedRange`/`pursGuard`/`classifyShadow`) is factored out
-- | and unit-tested; the orchestration below is thin.
module PursWasm.CLI.Ulib.Compat
  ( ulibCompatCmd
  , CheckRow(..)
  , withinConstraint
  , supportedRange
  , pursGuard
  , classifyShadow
  , querySupported
  ) where

import Prelude

import Control.Alt ((<|>))
import Data.Argonaut.Core (Json, toObject, toString)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Array.NonEmpty as NEA
import Data.Either (Either(..), hush)
import Data.Foldable (for_, sum)
import Data.Generic.Rep (class Generic)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Set as Set
import Data.Show.Generic (genericShow)
import Data.String as Str
import Data.String.Regex (Regex)
import Data.String.Regex as Re
import Data.String.Regex.Flags (noFlags)
import Data.String.Regex.Unsafe (unsafeRegex)
import Data.Traversable (for)
import Data.Tuple (Tuple(..))
import Foreign.Object as FO
import PursWasm.CLI.Effect (FS, LOG, exists, info, logAndThrow, readText, writeText)
import PursWasm.CLI.Effect.Registry (REGISTRY, supportedCompilers)
import PursWasm.CLI.Options.Types (UlibCompatOption)
import PursWasm.CLI.Ulib.Compat.Types (Compat, CompatCore, encodeCompat, readCompatCore)
import PursWasm.CLI.Ulib.Manifest (manifestPackages, readManifest)
import PursWasm.CLI.Ulib.Version (compareVersion, majorMinor)
import Run (Run, EFFECT)
import Type.Row (type (+))

-- cwd-relative constants (run from the repo root), mirroring the prototype.
lockPath :: String
lockPath = "spago.lock"

-- | ADR 0031: the shadow set + versions now come from `ulib-manifest.json` (the curated source of
-- | truth), not the `ulib/shadow/<pkg>-<ver>` directory names (which moved to `ulib/<package>/`).
manifestPath :: String
manifestPath = "ulib/ulib-manifest.json"

compatPath :: String
compatPath = "ulib/compat.json"

-- | purs-wasm's CoreFn decoder is verified against this compiler; the shipped lib is built with it
-- | (ADR 0029). It must lie in the shadowed packages' supported-compiler range — `pursGuard`.
pursPinConst :: String
pursPinConst = "0.15.16"

-- ─────────────────────────── pure decision logic (unit-tested) ───────────────────────────

-- | Is version `v` within a package-set compiler constraint like `">=0.15.15 <0.16.0"`? An absent
-- | constraint admits everything; each bound is optional and compared numerically.
withinConstraint :: Maybe String -> String -> Boolean
withinConstraint Nothing _ = true
withinConstraint (Just c) v =
  maybe true (\lo -> compareVersion v lo /= LT) (firstCapture lowerRe c)
    && maybe true (\hi -> compareVersion v hi == LT) (firstCapture upperRe c)
  where
  lowerRe = unsafeRegex ">=?\\s*([0-9.]+)" noFlags
  upperRe = unsafeRegex "<\\s*([0-9.]+)" noFlags

-- | The purs versions every shadowed package supports, within the package-set constraint: the
-- | intersection of the per-package `compilers` lists, filtered to the constraint and numerically
-- | sorted. Empty input (no shadows) yields the empty range.
supportedRange :: Maybe String -> Array (Array String) -> Array String
supportedRange constraint perPackage =
  Array.sortBy compareVersion (Array.filter (withinConstraint constraint) (intersectAll perPackage))
  where
  intersectAll arrs = case Array.uncons arrs of
    Nothing -> []
    Just { head, tail } ->
      Set.toUnfoldable (Array.foldl (\acc a -> Set.intersection acc (Set.fromFoldable a)) (Set.fromFoldable head) tail)

-- | Bound-check the purs pin against the supported range: `Right { min, max }` when the pin is a
-- | member, otherwise `Left <diagnostic>` (too old / too new / a gap), matching the prototype's
-- | hard-fail messages exactly.
pursGuard :: String -> Array String -> Either String { min :: String, max :: String }
pursGuard pin range = case Array.head range, Array.last range of
  Just mn, Just mx
    | Array.elem pin range -> Right { min: mn, max: mx }
    | otherwise -> Left (pinDiagnostic pin mn mx range)
  _, _ -> Left "ulib-compat: no purs is supported by all shadowed packages within the package-set constraint."

pinDiagnostic :: String -> String -> String -> Array String -> String
pinDiagnostic pin mn mx range =
  "ulib-compat: pinned purs " <> pin <> " is " <> why
    <> ". Re-shadow against package versions that support "
    <> pin
    <> ", or bump the decoder's pin."
  where
  why
    | compareVersion pin mn == LT = "too old (below the supported min " <> mn <> ")"
    | compareVersion pin mx == GT =
        "too new (above the supported max " <> mx <> " — a shadowed package has not been published-tested against it)"
    | otherwise = "not in the supported set (a gap; supported: " <> Str.joinWith ", " range <> ")"

-- | A shadow's status against the package set, for `--check`.
data CheckRow
  = Unresolved
  | Stale String
  | Drift String
  | Match

derive instance eqCheckRow :: Eq CheckRow
derive instance genericCheckRow :: Generic CheckRow _
instance showCheckRow :: Show CheckRow where
  show = genericShow

-- | Classify a shadow version against the version the package set resolves: not in the set, a
-- | major.minor divergence (stale), a patch-only divergence (drift, still applies), or a match.
classifyShadow :: String -> Maybe String -> CheckRow
classifyShadow shadowVer = case _ of
  Nothing -> Unresolved
  Just setVer
    | majorMinor setVer /= majorMinor shadowVer -> Stale setVer
    | setVer /= shadowVer -> Drift setVer
    | otherwise -> Match

-- ─────────────────────────────────── the command ────────────────────────────────────────

ulibCompatCmd :: forall r. UlibCompatOption -> Run (FS + REGISTRY + LOG + EFFECT + r) Unit
ulibCompatCmd opt = do
  mlock <- readText lockPath
  case mlock of
    Nothing -> logAndThrow ("ulib-compat: " <> lockPath <> " not found (run a spago build first).")
    Just lockTxt -> do
      let lock = parseLock lockTxt
      shadows <- map (maybe [] manifestPackages) (readManifest manifestPath)
      let core = deriveCore lock shadows
      priorTxt <- readText compatPath
      if opt.check then runCheck lock shadows core priorTxt
      else runRegen lock shadows core priorTxt

runCheck
  :: forall r
   . LockView
  -> Array { pkg :: String, ver :: String }
  -> CompatCore
  -> Maybe String
  -> Run (FS + LOG + EFFECT + r) Unit
runCheck lock shadows core priorTxt = do
  counts <- for shadows \s -> case classifyShadow s.ver (lockVersion lock s.pkg) of
    Unresolved ->
      info ("  ? " <> s.pkg <> ": shadow " <> s.ver <> ", not resolved in the package set") $> { stale: 0, drift: 0 }
    Stale setVer ->
      info ("  ✗ " <> s.pkg <> ": shadow " <> s.ver <> " ≠ set " <> setVer <> " (major.minor) — shadow is STALE, re-shadow it")
        $> { stale: 1, drift: 0 }
    Drift setVer ->
      info ("  ~ " <> s.pkg <> ": shadow " <> s.ver <> ", set " <> setVer <> " (patch differs — still applies; refresh compat.json)")
        $> { stale: 0, drift: 1 }
    Match ->
      info ("  ✓ " <> s.pkg <> ": " <> s.ver) $> { stale: 0, drift: 0 }
  let stale = sum (_.stale <$> counts)
  let drift = sum (_.drift <$> counts)
  compatExists <- exists compatPath
  outOfDate <-
    if not compatExists then
      info ("  ✗ " <> compatPath <> " is missing — run `purs-wasm ulib compat`") $> true
    else if maybe true (\t -> readCompatCore t /= core) priorTxt then
      info ("  ✗ " <> compatPath <> " version data is out of date — run `purs-wasm ulib compat`") $> true
    else pure false
  if stale > 0 || outOfDate then
    logAndThrow
      ( "ulib-compat: check failed (" <> show stale <> " stale shadow(s)"
          <> (if outOfDate then ", compat.json out of date" else "")
          <> ")."
      )
  else
    info ("ulib-compat: check OK" <> (if drift > 0 then " (" <> show drift <> " patch drift — regenerate compat.json)" else "") <> ".")

runRegen
  :: forall r
   . LockView
  -> Array { pkg :: String, ver :: String }
  -> CompatCore
  -> Maybe String
  -> Run (FS + REGISTRY + LOG + EFFECT + r) Unit
runRegen lock shadows core priorTxt = do
  range <- querySupported lock.setCompiler (lockVersion lock) shadows
  purs <- case range of
    Left errMsg -> case readPriorPurs priorTxt of
      Just p -> do
        info ("ulib-compat: keeping prior purs pin " <> p.pursPin <> " (compiler-compat query skipped: " <> errMsg <> ").")
        pure p
      Nothing -> logAndThrow ("ulib-compat: " <> errMsg)
    Right comps -> case pursGuard pursPinConst comps of
      Left msg -> logAndThrow msg
      Right { min, max } -> do
        info ("ulib-compat: purs pin " <> pursPinConst <> " ∈ supported [" <> min <> " .. " <> max <> "] — OK (not too old, not too new).")
        pure { pursPin: pursPinConst, pursMin: min, pursMax: max }
  let
    out :: Compat
    out =
      { packageSet: core.packageSet
      , pursPin: purs.pursPin
      , pursMin: purs.pursMin
      , pursMax: purs.pursMax
      , packages: core.packages
      }
  writeText compatPath (encodeCompat out)
  info ("ulib-compat: wrote " <> compatPath <> " (package-set " <> fromMaybe "null" core.packageSet <> "):")
  for_ shadows \s ->
    info ("  " <> s.pkg <> ": shadow " <> s.ver <> ", set " <> fromMaybe "?" (lockVersion lock s.pkg))

-- | Reduce each shadowed package's supported-compiler set (read via the abstract `REGISTRY` effect)
-- | to the supported range. A query failure short-circuits to `Left` — the caller then falls back
-- | to the prior pin, matching the prototype's try/catch. Takes the package-set constraint and a
-- | version lookup directly (rather than a `LockView`) so it is exercisable with a stub registry,
-- | no spago.lock needed.
querySupported
  :: forall r
   . Maybe String
  -> (String -> Maybe String)
  -> Array { pkg :: String, ver :: String }
  -> Run (REGISTRY + r) (Either String (Array String))
querySupported setCompiler lookupVersion = go []
  where
  go acc arr = case Array.uncons arr of
    Nothing -> pure (Right (supportedRange setCompiler acc))
    Just { head: s, tail } -> do
      result <- supportedCompilers s.pkg (fromMaybe s.ver (lookupVersion s.pkg))
      case result of
        Left e -> pure (Left e)
        Right comps -> go (Array.snoc acc comps) tail

-- ─────────────────────────────── JSON navigation (lenient) ───────────────────────────────

type LockView =
  { packageSet :: Maybe String
  , setCompiler :: Maybe String
  , content :: FO.Object Json
  , packages :: FO.Object Json
  }

parseLock :: String -> LockView
parseLock txt =
  { packageSet: pkgSet >>= field "address" >>= field "registry" >>= toString
  , setCompiler: pkgSet >>= field "compiler" >>= toString
  , content: maybe FO.empty identity (pkgSet >>= field "content" >>= toObject)
  , packages: maybe FO.empty identity (mj >>= field "packages" >>= toObject)
  }
  where
  mj = hush (jsonParser txt)
  pkgSet = mj >>= field "workspace" >>= field "package_set"

-- | The version the package set resolves for a package: its `content` entry, else the resolved
-- | `packages.<pkg>.version`, else nothing.
lockVersion :: LockView -> String -> Maybe String
lockVersion lock pkg =
  (FO.lookup pkg lock.content >>= toString)
    <|> (FO.lookup pkg lock.packages >>= field "version" >>= toString)

deriveCore :: LockView -> Array { pkg :: String, ver :: String } -> CompatCore
deriveCore lock shadows =
  { packageSet: lock.packageSet
  , packages: Map.fromFoldable (shadows <#> \s -> Tuple s.pkg (fromMaybe s.ver (lockVersion lock s.pkg)))
  }

readPriorPurs :: Maybe String -> Maybe { pursPin :: String, pursMin :: String, pursMax :: String }
readPriorPurs = case _ of
  Nothing -> Nothing
  Just txt -> do
    j <- hush (jsonParser txt)
    pin <- field "pursPin" j >>= toString
    pure
      { pursPin: pin
      , pursMin: fromMaybe "" (field "pursMin" j >>= toString)
      , pursMax: fromMaybe "" (field "pursMax" j >>= toString)
      }

field :: String -> Json -> Maybe Json
field k j = toObject j >>= FO.lookup k

firstCapture :: Regex -> String -> Maybe String
firstCapture re s = Re.match re s >>= \groups -> join (NEA.index groups 1)
