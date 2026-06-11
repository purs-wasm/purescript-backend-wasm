-- | The three `ulib` subcommands that manage the shadow library (ADR 0028): `install` compiles the
-- | shadows into the lib, `validate` checks each shadow's package version still matches the resolved
-- | package set (by `major.minor`), and `check` compares each shadow's public interface against the
-- | user's compiled module. Ported verbatim from the prototype; only the effects are abstract
-- | (`Run`), so the same logic runs under the Node interpreter or the in-memory test one.
module PursWasm.CLI.Ulib
  ( ulibInstallCmd
  , ulibValidateCmd
  , ulibCheckCmd
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (for_)
import Data.Map as Map
import Data.Set as Set
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.String as Str
import Data.Traversable (for)
import Data.Tuple (Tuple(..))
import Fmt as Fmt
import PureScript.Backend.Wasm.Ulib.Interface (compatible, diffInterface, interfaceOf)
import PursWasm.CLI.Build.Paths (wasmAsBin)
import PursWasm.CLI.Effect (FS, FilePath, LOG, PROC, execFile, info, joinPath, logAndThrow, readDir)
import PursWasm.CLI.Effect.Log as Log
import PursWasm.CLI.Externs (readExterns)
import PursWasm.CLI.Options.Types (UlibCheckOption, UlibInstallOption, UlibValidateOption)
import PursWasm.CLI.Ulib.Manifest (manifestModules, manifestPackages, readManifest, ulibManifestFile)
import PursWasm.CLI.Ulib.Version (majorMinor, splitPkgVer)
import Run (Run, EFFECT)
import Type.Row (type (+))

-- | `purs-wasm ulib install` (ADR 0028/0031): compile the ulib modules (`<cli>/../ulib/<package>/
-- | <Module>.purs`, ADR 0031 §2.1) into the flat lib (`$LIB/<Module>/`, corefn + externs +
-- | per-module kept-foreign `foreign.wasm`, ADR 0031 §2.2) via `ulib-install.sh`. Skips if the lib
-- | already exists, unless `--force`. Versions come from `ulib-manifest.json` (no longer the source
-- | path); compiled against the resolved package-set sources (`.spago/p`) with WasmBase overlaid.
ulibInstallCmd :: forall r. FilePath -> UlibInstallOption -> Run (FS + PROC + LOG + r) Unit
ulibInstallCmd cliRoot opt = do
  libPath <- maybe (joinPath [ cliRoot, "..", "lib" ]) pure opt.libPath
  let purs = fromMaybe "purs" opt.purs
  ulibSrc <- joinPath [ cliRoot, "..", "ulib" ]
  manifest <- joinPath [ cliRoot, "..", "ulib", "ulib-manifest.json" ]
  wasmBaseSrc <- joinPath [ cliRoot, "..", "wasm-base", "src" ]
  script <- joinPath [ cliRoot, "ulib-install.sh" ]
  spagoP <- joinPath [ ".spago", "p" ]
  -- "present" means the lib actually holds shadows, not merely that the directory exists — an
  -- empty `-L` dir must still install (`readDir`: `Nothing` if absent, `Just []` if empty).
  present <- not <<< Array.null <<< fromMaybe [] <$> readDir libPath
  if present && not opt.force then
    info "ulib: lib already present (use -f/--force to rebuild)."
  else do
    when opt.force (execFile "rm" [ "-rf", libPath ])
    info $ Log.green "✓ Compiling shadows..."
    execFile "sh" [ script, libPath, ulibSrc, wasmBaseSrc, purs, manifest, wasmAsBin, spagoP ]
    Log.br *> info (Log.strong $ Log.green "✓ ulib successfully installed!")

-- | `purs-wasm ulib validate` (ADR 0028/0031): for each ulib-covered package (from
-- | `ulib-manifest.json` — the single source of truth, ADR 0031), check that its supported version
-- | still matches (by `major.minor`) the version resolved in your workspace (`.spago/p`). A patch
-- | bump keeps the interface so the shadow still applies; a minor/major divergence means the shadow
-- | would be skipped at build time (the foreign HOF stays slow) — so this fails loudly and asks you
-- | to align your version to the ulib's.
ulibValidateCmd :: forall r. FilePath -> UlibValidateOption -> Run (FS + LOG + EFFECT + r) Unit
ulibValidateCmd cliRoot opt = do
  libPath <- maybe (joinPath [ cliRoot, "..", "lib" ]) pure opt.libPath
  spago <- maybe (joinPath [ ".spago", "p" ]) pure opt.spago
  -- the manifest is read from the lib itself (`$LIB/ulib-manifest.json`, copied in at install) so a
  -- lib-only user (no ulib source tree, the `ulib upgrade` flow) can still validate. ADR 0031.
  manifestPath <- joinPath [ libPath, ulibManifestFile ]
  -- A lib that is absent OR present-but-empty (no module dirs) is "not installed": `readDir`
  -- returns `Nothing` for the former and `Just []` for the latter, so an empty list covers both
  -- (guarding against a vacuous "OK" on an empty `-L` dir). The self-describing manifest file is not
  -- a module dir, so exclude it.
  libMods <- Array.filter (_ /= ulibManifestFile) <<< fromMaybe [] <$> readDir libPath
  mManifest <- readManifest manifestPath
  case mManifest of
    _ | Array.null libMods -> info (Log.toLog "No lib installed (run `" <> Log.strong (Log.blue "ulib install") <> Log.toLog "`.)")
    Nothing -> info (Log.toLog "No ulib manifest found; cannot validate.")
    Just manifest -> do
      spagoDirs <- fromMaybe [] <$> readDir spago
      let userVers = Map.fromFoldable (spagoDirs <#> \d -> let { pkg, ver } = splitPkgVer d in Tuple pkg ver)
      let rows = manifestPackages manifest <#> \{ pkg, ver } -> { pkg, ulibVer: ver, userVer: Map.lookup pkg userVers }
      validateRows rows

-- | Report each package's ulib-vs-workspace version status and fail if any major.minor diverges.
validateRows
  :: forall r
   . Array { pkg :: String, ulibVer :: String, userVer :: Maybe String }
  -> Run (FS + LOG + EFFECT + r) Unit
validateRows rows = do
  for_ rows \r -> case r.userVer of
    Nothing ->
      info (Fmt.fmt @"  ? {pkg}: ulib {u}, not in your workspace" { pkg: r.pkg, u: r.ulibVer })
    Just uv
      | majorMinor uv == majorMinor r.ulibVer ->
          info (Log.cyan $ Fmt.fmt @"  ✓ {pkg}: ulib {u}, yours {y}" { pkg: r.pkg, u: r.ulibVer, y: uv })
      | otherwise ->
          info (Fmt.fmt @"  ✗ {pkg}: ulib {u} ≠ yours {y} (major.minor differs)" { pkg: r.pkg, u: r.ulibVer, y: uv })
  let mismatches = Array.filter (\r -> maybe false (\uv -> majorMinor uv /= majorMinor r.ulibVer) r.userVer) rows
  if Array.null mismatches then info (Log.strong $ Log.green "✓ validate OK.")
  else logAndThrow
    ( Fmt.fmt
        @"⚠️ {n} package(s) diverge from the shadows. Align your workspace to: {pkgs}."
        { n: Array.length mismatches, pkgs: Str.joinWith ", " (mismatches <#> \r -> r.pkg <> " " <> r.ulibVer) }
    )

-- | `purs-wasm ulib check` (ADR 0028, deep check): compare each installed shadow's *public
-- | interface* (exported names, from its stored externs) against the same module compiled in
-- | your workspace (`<input>/<Module>/externs.cbor`, i.e. your spago build output). A shadow
-- | that drops a name the registry module exports is not a drop-in — that fails the check; a
-- | shadow that only *adds* names is reported but allowed. A module you have not compiled yet
-- | is skipped with a note (build your project first to check it).
ulibCheckCmd :: forall r. FilePath -> UlibCheckOption -> Run (FS + LOG + EFFECT + r) Unit
ulibCheckCmd cliRoot opt = do
  libPath <- maybe (joinPath [ cliRoot, "..", "lib" ]) pure opt.libPath
  input <- maybe (joinPath [ ".", "output" ]) pure opt.input
  -- absent OR present-but-empty (no module dirs) ⇒ "not installed" (see `ulibValidateCmd`); the
  -- self-describing `ulib-manifest.json` at the lib root is not a module dir, so exclude it.
  libMods <- Array.filter (_ /= ulibManifestFile) <<< fromMaybe [] <$> readDir libPath
  -- the manifest's covered modules are the registry shadows; a lib module outside it is a ulib
  -- *internal* helper (ADR 0031 §6) with no registry counterpart — there is no interface to check.
  covered <- maybe Set.empty manifestModules <$> (readManifest =<< joinPath [ libPath, ulibManifestFile ])
  if Array.null libMods then info (Log.toLog "No lib installed (run `" <> Log.strong (Log.blue "ulib install") <> Log.toLog "`.)")
  else do
    breaks <- map Array.catMaybes $ for libMods \mod ->
      if not (Set.member mod covered) then do
        info (Fmt.fmt @"  - {m}: ulib internal helper (no registry interface); skipped" { m: mod })
        pure Nothing
      else do
        libExt <- readExterns =<< joinPath [ libPath, mod, "externs.cbor" ]
        usrExt <- readExterns =<< joinPath [ input, mod, "externs.cbor" ]
        case libExt, usrExt of
          -- a wat-only ulib module (e.g. Data.Int) has a `foreign.wasm` but no externs — not a
          -- shadow, so there is no interface to check; the `Nothing` lib externs skips it below.
          _, Nothing -> do
            info (Fmt.fmt @"  - {m}: not compiled in your workspace; skipped" { m: mod })
            pure Nothing
          Nothing, _ -> do
            info (Fmt.fmt @"  - {m}: no shadow externs (foreign-only or unreadable); skipped" { m: mod })
            pure Nothing
          Just le, Just ue -> do
            let d = diffInterface (interfaceOf ue) (interfaceOf le)
            if compatible d then do
              info $ Log.cyan
                ( Fmt.fmt @"  ✓ {m}: interface OK{extra}"
                    { m: mod, extra: if Array.null d.extra then "" else " (+" <> show (Array.length d.extra) <> " extra)" }
                )
              pure Nothing
            else do
              info $ Log.red (Fmt.fmt @"  ✗ {m}: missing {names}" { m: mod, names: Str.joinWith ", " d.missing })
              pure (Just mod)
    if Array.null breaks then info (Log.strong $ Log.green "✓ check OK.")
    else logAndThrow
      ( Fmt.fmt
          @"ulib: {n} shadow(s) are not drop-in for your workspace: {mods}. Align your version to the ulib's, or update the shadow."
          { n: Array.length breaks, mods: Str.joinWith ", " breaks }
      )
