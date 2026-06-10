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
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.String as Str
import Data.Traversable (for)
import Data.Tuple (Tuple(..))
import Fmt as Fmt
import PureScript.Backend.Wasm.Ulib.Interface (compatible, diffInterface, interfaceOf)
import PursWasm.CLI.Effect (FS, FilePath, LOG, PROC, execFile, info, joinPath, logAndThrow, readDir)
import PursWasm.CLI.Effect.Log as Log
import PursWasm.CLI.Externs (readExterns)
import PursWasm.CLI.Options.Types (UlibCheckOption, UlibInstallOption, UlibValidateOption)
import PursWasm.CLI.Ulib.Version (majorMinor, splitPkgVer)
import Run (Run, EFFECT)
import Type.Row (type (+))

-- | `purs-wasm ulib install` (ADR 0028): compile the ulib shadows (`<cli>/../ulib/shadow/`)
-- | into the lib (corefn + externs) via `ulib-install.sh`. Skips if the lib already exists,
-- | unless `--force`. The shadow set is the dir structure (`<pkg>-<ver>/<Module path>.purs`),
-- | compiled against the resolved package-set sources (`.spago/p`) with WasmBase overlaid.
ulibInstallCmd :: forall r. FilePath -> UlibInstallOption -> Run (FS + PROC + LOG + r) Unit
ulibInstallCmd cliRoot opt = do
  libPath <- maybe (joinPath [ cliRoot, "..", "lib" ]) pure opt.libPath
  let purs = fromMaybe "purs" opt.purs
  shadowRoot <- joinPath [ cliRoot, "..", "ulib", "shadow" ]
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
    execFile "sh" [ script, libPath, shadowRoot, wasmBaseSrc, purs, spagoP ]
    Log.br *> info (Log.strong $ Log.green "✓ ulib successfully installed!")

-- | `purs-wasm ulib validate` (ADR 0028): for each installed shadow, check that the package
-- | version it was built against still matches (by `major.minor`) the version resolved in your
-- | workspace (`.spago/p`). A patch bump keeps the interface so the shadow still applies; a
-- | minor/major divergence means the shadow would be skipped at build time (the foreign HOF
-- | stays slow) — so this fails loudly and asks you to align your version to the ulib's.
ulibValidateCmd :: forall r. FilePath -> UlibValidateOption -> Run (FS + LOG + EFFECT + r) Unit
ulibValidateCmd cliRoot opt = do
  libPath <- maybe (joinPath [ cliRoot, "..", "lib" ]) pure opt.libPath
  spago <- maybe (joinPath [ ".spago", "p" ]) pure opt.spago
  -- A lib that is absent OR present-but-empty (no shadow dirs) is "not installed": `readDir`
  -- returns `Nothing` for the former and `Just []` for the latter, so an empty list covers both
  -- (guarding against a vacuous "OK" on an empty `-L` dir).
  pkgDirs <- fromMaybe [] <$> readDir libPath
  if Array.null pkgDirs then info (Log.toLog "No lib installed (run `" <> Log.strong (Log.blue "ulib install") <> Log.toLog "`.)")
  else do
    spagoDirs <- fromMaybe [] <$> readDir spago
    let userVers = Map.fromFoldable (spagoDirs <#> \d -> let { pkg, ver } = splitPkgVer d in Tuple pkg ver)
    let
      rows = pkgDirs <#> \pkgVer ->
        let
          { pkg, ver } = splitPkgVer pkgVer
        in
          { pkg, ulibVer: ver, userVer: Map.lookup pkg userVers }
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
  -- absent OR present-but-empty (no shadow dirs) ⇒ "not installed" (see `ulibValidateCmd`).
  pkgDirs <- fromMaybe [] <$> readDir libPath
  if Array.null pkgDirs then info (Log.toLog "No lib installed (run `" <> Log.strong (Log.blue "ulib install") <> Log.toLog "`.)")
  else do
    breaks <- map Array.concat $ for pkgDirs \pkgVer -> do
      pkgPath <- joinPath [ libPath, pkgVer ]
      mods <- fromMaybe [] <$> readDir pkgPath
      map Array.catMaybes $ for mods \mod -> do
        libExt <- readExterns =<< joinPath [ pkgPath, mod, "externs.cbor" ]
        usrExt <- readExterns =<< joinPath [ input, mod, "externs.cbor" ]
        case libExt, usrExt of
          _, Nothing -> do
            info (Fmt.fmt @"  - {m} ({p}): not compiled in your workspace; skipped" { m: mod, p: pkgVer })
            pure Nothing
          Nothing, _ -> do
            info (Fmt.fmt @"  - {m} ({p}): shadow externs unreadable; skipped" { m: mod, p: pkgVer })
            pure Nothing
          Just le, Just ue -> do
            let d = diffInterface (interfaceOf ue) (interfaceOf le)
            if compatible d then do
              info $ Log.cyan
                ( Fmt.fmt @"  ✓ {m} ({p}): interface OK{extra}"
                    { m: mod, p: pkgVer, extra: if Array.null d.extra then "" else " (+" <> show (Array.length d.extra) <> " extra)" }
                )
              pure Nothing
            else do
              info $ Log.red (Fmt.fmt @"  ✗ {m} ({p}): missing {names}" { m: mod, p: pkgVer, names: Str.joinWith ", " d.missing })
              pure (Just mod)
    if Array.null breaks then info (Log.strong $ Log.green "✓ check OK.")
    else logAndThrow
      ( Fmt.fmt
          @"ulib: {n} shadow(s) are not drop-in for your workspace: {mods}. Align your version to the ulib's, or update the shadow."
          { n: Array.length breaks, mods: Str.joinWith ", " breaks }
      )
