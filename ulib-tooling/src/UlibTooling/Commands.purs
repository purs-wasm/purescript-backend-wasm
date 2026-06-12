-- | The maintainer `ulib` subcommands that manage the shadow library (ADR 0028/0031): `install`
-- | compiles the shadows into the lib, and `check` compares each shadow's public interface against
-- | the user's compiled module. Only the effects are abstract (`Run`), so the same logic runs under
-- | the Node interpreter or the in-memory test one.
module UlibTooling.Commands
  ( ulibInstallCmd
  , ulibCheckCmd
  ) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Set as Set
import Data.String as Str
import Data.Traversable (for)
import Fmt as Fmt
import PureScript.Backend.Wasm.Ulib.Interface (compatible, diffInterface, interfaceOf)
import PursWasm.CLI.Build.Paths (wasmAsBin)
import PursWasm.CLI.Effect (ENV, FS, FilePath, LOG, PROC, execFile, info, joinPath, logAndThrow, readDir)
import PursWasm.CLI.Effect.Log as Log
import PursWasm.CLI.Externs (readExterns)
import PursWasm.CLI.Lib (resolveLibPath)
import PursWasm.CLI.Ulib.Manifest (isLibModuleDir, manifestModules, readManifest, ulibManifestFile)
import UlibTooling.Options (UlibCheckOption, UlibInstallOption)
import Run (Run, EFFECT)
import Type.Row (type (+))

-- | `ulib-tooling install` (ADR 0028/0031): compile the ulib modules (`<cli>/ulib/<package>/
-- | <Module>.purs`, ADR 0031 §2.1) into the flat lib (`$LIB/<Module>/`, corefn + externs +
-- | per-module kept-foreign `foreign.wasm`, ADR 0031 §2.2) via `ulib-install.sh`. Skips if the lib
-- | already exists, unless `--force`. Versions come from `ulib-manifest.json` (no longer the source
-- | path); compiled against the resolved package-set sources (`.spago/p`) with WasmBase overlaid.
ulibInstallCmd :: forall r. FilePath -> FilePath -> UlibInstallOption -> Run (ENV + FS + PROC + LOG + r) Unit
ulibInstallCmd cliRoot binaryenBinDir opt = do
  libPath <- resolveLibPath cliRoot opt.libPath
  let purs = fromMaybe "purs" opt.purs
  ulibSrc <- joinPath [ cliRoot, "ulib" ]
  manifest <- joinPath [ cliRoot, "ulib", "ulib-manifest.json" ]
  wasmBaseSrc <- joinPath [ cliRoot, "wasm-base", "src" ]
  script <- joinPath [ cliRoot, "ulib-tooling", "ulib-install.sh" ]
  spagoP <- joinPath [ ".spago", "p" ]
  -- "present" means the lib actually holds shadows, not merely that the directory exists — an
  -- empty `-L` dir must still install (`readDir`: `Nothing` if absent, `Just []` if empty).
  present <- not <<< Array.null <<< fromMaybe [] <$> readDir libPath
  if present && not opt.force then
    info "ulib: lib already present (use -f/--force to rebuild)."
  else do
    when opt.force (execFile "rm" [ "-rf", libPath ])
    info $ Log.green "✓ Compiling shadows..."
    execFile "sh" [ script, libPath, ulibSrc, wasmBaseSrc, purs, manifest, wasmAsBin binaryenBinDir, spagoP ]
    Log.br *> info (Log.strong $ Log.green "✓ ulib successfully installed!")

-- | `ulib-tooling check` (ADR 0028, deep check): compare each installed shadow's *public
-- | interface* (exported names, from its stored externs) against the same module compiled in
-- | your workspace (`<input>/<Module>/externs.cbor`, i.e. your spago build output). A shadow
-- | that drops a name the registry module exports is not a drop-in — that fails the check; a
-- | shadow that only *adds* names is reported but allowed. A module you have not compiled yet
-- | is skipped with a note (build your project first to check it).
ulibCheckCmd :: forall r. FilePath -> UlibCheckOption -> Run (ENV + FS + LOG + EFFECT + r) Unit
ulibCheckCmd cliRoot opt = do
  libPath <- resolveLibPath cliRoot opt.libPath
  input <- maybe (joinPath [ ".", "output" ]) pure opt.input
  -- absent OR present-but-empty (no module dirs) ⇒ "not installed"; `isLibModuleDir` drops the lib
  -- root's self-describing files (manifest, `_header.wat`), which are not module dirs.
  libMods <- Array.filter isLibModuleDir <<< fromMaybe [] <$> readDir libPath
  -- the manifest's covered modules are the registry shadows; a lib module outside it is a ulib
  -- *internal* helper (ADR 0031 §6) with no registry counterpart — there is no interface to check.
  covered <- maybe Set.empty manifestModules <$> (readManifest =<< joinPath [ libPath, ulibManifestFile ])
  if Array.null libMods then info (Log.toLog "No lib installed (run `" <> Log.strong (Log.blue "ulib-tooling install") <> Log.toLog "`.)")
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
