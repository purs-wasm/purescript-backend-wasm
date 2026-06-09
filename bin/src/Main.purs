module Main where

import Prelude

import ArgParse.Basic (ArgParser)
import ArgParse.Basic as ArgParser
import Data.Array as Array
import Data.Either (Either(..), either)
import Data.ArrayBuffer.Types (Uint8Array)
import Data.Foldable (for_)
import Data.Maybe (Maybe(..), fromMaybe, isJust, isNothing, maybe)
import Data.List.NonEmpty as NEL
import Data.Map as Map
import Data.Set (Set)
import Data.Set as Set
import Data.String (Pattern(..))
import Data.String as Str
import Data.Traversable (for)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Aff, launchAff_, throwError, try)
import Effect.Class (liftEffect)
import Effect.Class.Console (logShow)
import Effect.Class.Console as Console
import Effect.Exception (error)
import Fmt as Fmt
import Node.Encoding (Encoding(..))
import Node.FS.Aff as FS
import Node.FS.Perms (permsAll)
import Node.Path (FilePath)
import Node.Path as Path
import Node.Process as Process
import Node.Cbor (decodeFirst)
import Foreign.Object (Object)
import Foreign.Object as Object
import PureScript.Backend.Wasm.Compiler (compileModules, mirTrace, parseModule)
import PureScript.Backend.Wasm.Intrinsics (foreignIntrinsic, qualifiedIntrinsic)
import PureScript.Backend.Wasm.Externs (foreignSigs)
import PureScript.Backend.Wasm.SourceForeigns (parseForeignSigs)
import PureScript.Backend.Wasm.Ulib (parseUlibSigs)
import PureScript.Backend.Wasm.Ulib.Interface (compatible, diffInterface, interfaceOf)
import PureScript.ExternsFile (ExternsFile)
import PureScript.Backend.Wasm.Lower.IR (ForeignImport, MarshalKind(..), foreignManifestJson, exportManifestJson)
import PureScript.CoreFn (Module, ModuleName, toModuleName)
import PureScript.ExternsFile.Decoder.Class (decoder)
import PureScript.ExternsFile.Decoder.Monad (runDecoder)
import Unsafe.Coerce (unsafeCoerce)
import Version as Version

-- | Run an external tool synchronously (used for `wasm-merge` / `wasm-dis`).
foreign import execFileImpl :: String -> Array String -> Effect Unit

execFile :: String -> Array String -> Aff Unit
execFile cmd args = liftEffect (execFileImpl cmd args)

-- | The host-import module names a wasm binary declares (the user `foreign import`
-- | modules a JS loader must satisfy; ADR 0014).
foreign import importModulesImpl :: Uint8Array -> Effect (Array String)

-- | Module name → its `.purs` source path, parsed from spago's `cache-db.json` (ADR
-- | 0016). Paths are relative to the build's working directory (our cwd).
foreign import cacheDbSourcesImpl :: String -> Object String

-- | The dotted import module names of a `corefn.json` source, extracted cheaply (no
-- | full decode), for file-level reachability pruning.
foreign import corefnImportsImpl :: String -> Array String

type BuildOption =
  { input :: FilePath
  , outDir :: FilePath
  , entryModules :: NEL.NonEmptyList String
  , text :: Boolean
  , debug :: Boolean
  , noOpt :: Boolean
  , traceMir :: Maybe String
  }

buildOptionsParser :: ArgParser BuildOption
buildOptionsParser =
  ArgParser.fromRecord
    { input:
        ArgParser.argument [ "-I", "--input" ]
          "Path to input directory containing PureScript compiler's artifacts (namely, corefn.json and externs.cbor)\n\
          \Defaults to './output'."
          # ArgParser.default (Path.concat [ ".", "output" ])
    , outDir:
        ArgParser.argument [ "-O", "--output" ]
          "The output directory the bundled wasm is placed in.\n\
          \Defaults to './output-wasm'."
          # ArgParser.default (Path.concat [ ".", "output-wasm" ])
    , entryModules: ArgParser.many1 $
        ArgParser.argument [ "-e", "--entry" ]
          "The name of an entry module (whose exports are kept). You can pass several."
    , text:
        ArgParser.flag [ "-t", "--text" ]
          "Emit the WebAssembly text format (.wat) instead of a binary .wasm."
          # ArgParser.boolean
    , debug:
        ArgParser.flag [ "-g", "--debug" ]
          "Debug build: skip the Binaryen optimizer (keeps the wasm close to the\n\
          \emitted IR; also the future home of source-map output)."
          # ArgParser.boolean
    , noOpt:
        ArgParser.flag [ "--no-opt" ]
          "Skip the middle-end optimization (dictionary elimination); lambda lifting\n\
          \still runs. Use to build an unoptimized baseline for benchmarking."
          # ArgParser.boolean
    , traceMir:
        ArgParser.argument [ "--trace-mir" ]
          "Trace how the given module's middle IR (MIR) changes after every optimizer\n\
          \sub-stage (specialize/simplify/impurify) of every round, written to\n\
          \./mir-trace.txt (debugging; cf. purs-backend-es --trace-rewrites)."
          # ArgParser.optional
    }

type UlibInstallOption =
  { libPath :: Maybe FilePath
  , purs :: Maybe FilePath
  , force :: Boolean
  }

ulibInstallParser :: ArgParser UlibInstallOption
ulibInstallParser =
  ArgParser.fromRecord
    { libPath:
        ArgParser.argument [ "-L", "--lib-path" ]
          "Where to store the compiled ulib corefn/externs.\n\
          \Defaults to the `lib` dir beside the compiler (`<cli>/../lib`)."
          # ArgParser.optional
    , purs:
        ArgParser.argument [ "-x", "--purs" ]
          "Path to the `purs` executable used to compile the shadows. Defaults to `purs` on PATH."
          # ArgParser.optional
    , force:
        ArgParser.flag [ "-f", "--force" ]
          "Rebuild even if the lib is already present."
          # ArgParser.boolean
    }

type UlibValidateOption =
  { libPath :: Maybe FilePath
  , spago :: Maybe FilePath
  }

ulibValidateParser :: ArgParser UlibValidateOption
ulibValidateParser =
  ArgParser.fromRecord
    { libPath:
        ArgParser.argument [ "-L", "--lib-path" ]
          "The installed ulib to validate. Defaults to `<cli>/../lib`."
          # ArgParser.optional
    , spago:
        ArgParser.argument [ "-S", "--spago" ]
          "The resolved package-set sources to compare against (one dir per package,\n\
          \`<package>-<version>`). Defaults to `.spago/p`."
          # ArgParser.optional
    }

type UlibCheckOption =
  { libPath :: Maybe FilePath
  , input :: Maybe FilePath
  }

ulibCheckParser :: ArgParser UlibCheckOption
ulibCheckParser =
  ArgParser.fromRecord
    { libPath:
        ArgParser.argument [ "-L", "--lib-path" ]
          "The installed ulib to check. Defaults to `<cli>/../lib`."
          # ArgParser.optional
    , input:
        ArgParser.argument [ "-I", "--input" ]
          "The directory of *your* compiled artifacts (per-module `externs.cbor`) to compare\n\
          \the shadows' interface against — i.e. your spago build output. Defaults to `output`."
          # ArgParser.optional
    }

data Command
  = Build BuildOption
  | UlibInstall UlibInstallOption
  | UlibValidate UlibValidateOption
  | UlibCheck UlibCheckOption

commandParser :: ArgParser Command
commandParser =
  ArgParser.choose "command"
    [ ArgParser.command [ "build" ]
        "Build a wasm module from a PureScript project's compiler artifacts"
        do
          Build <$> buildOptionsParser <* ArgParser.flagHelp
    , ArgParser.command [ "ulib" ]
        "Manage the ulib shadow library (ADR 0028)"
        do
          ArgParser.choose "ulib command"
            [ ArgParser.command [ "install" ]
                "Compile the ulib shadows into the lib (corefn + externs)"
                (UlibInstall <$> ulibInstallParser <* ArgParser.flagHelp)
            , ArgParser.command [ "validate" ]
                "Check each installed shadow's version matches your resolved package set"
                (UlibValidate <$> ulibValidateParser <* ArgParser.flagHelp)
            , ArgParser.command [ "check" ]
                "Compare each shadow's public interface against your compiled module (externs)"
                (UlibCheck <$> ulibCheckParser <* ArgParser.flagHelp)
            ] <* ArgParser.flagHelp
    ]
    <* ArgParser.flagHelp
    <* ArgParser.flagInfo [ "--version", "-v" ] "Show version" Version.versionString

parseArgs :: Effect (Either ArgParser.ArgError Command)
parseArgs = do
  cliArgs <- Array.drop 2 <$> Process.argv
  pure $ ArgParser.parseArgs "purs-backend-wasm"
    "A PureScript backend for WebAssembly (with GC)"
    commandParser
    cliArgs

-- | A module name as its on-disk directory / dotted form (`Data.Maybe`).
printModname :: ModuleName -> String
printModname = Str.joinWith "."

-- | `-e Data.Maybe` names the module `["Data", "Maybe"]` — the root form
-- | `lowerModules` expects.
entryRoot :: String -> ModuleName
entryRoot = Str.split (Pattern ".")

-- | The set of module names transitively reachable from `roots` through the (dotted)
-- | import map — a fixpoint that only grows, so it terminates. Used to prune the input
-- | dir to what the entry actually needs before decoding (the compiler prunes again at
-- | the IR level, but this keeps the decode itself bounded).
reachableClosure :: Array ModuleName -> Map.Map String (Array String) -> Set String
reachableClosure roots importMap = go (Set.fromFoldable (map printModname roots))
  where
  go seen =
    let
      next = Set.fromFoldable (Array.fromFoldable seen >>= \n -> maybe [] identity (Map.lookup n importMap))
      seen' = Set.union seen next
    in
      if Set.size seen' == Set.size seen then seen else go seen'

-- | Capability check for `wasm-base` (ADR 0026): `Wasm.*` is `wasm-base`'s reserved namespace,
-- | and its foreigns are meant to resolve to *this* backend's intrinsics (the JS foreigns it
-- | bundles are for the JS backends only). A `Wasm.*` foreign this backend does not recognize
-- | means the `wasm-base` is newer than the backend supports — fail with a clear message rather
-- | than silently degrading to the JS-foreign / trap path on wasm.
-- |
-- | While `wasm-base` is intrinsic-only it exposes no GC-type ABI, so a name (capability) check
-- | is the right, version-independent guard. A stricter version lock becomes necessary only once
-- | `wasm-base` ships hand-written `.wat` (which talks the backend's GC types directly). See
-- | ADR 0026.
checkWasmBaseCompat :: forall r. Array { name :: ModuleName, foreignNames :: Array String | r } -> Either String Unit
checkWasmBaseCompat modules = case Array.nub (modules >>= unsupported) of
  [] -> Right unit
  bad -> Left
    ( Fmt.fmt
        @"This purs-wasm backend ({backend}) does not provide {n} `Wasm.*` primitive(s): {names}. Your `wasm-base` is newer than this backend supports — install a `wasm-base` compatible with it."
        { backend: Version.version, n: Array.length bad, names: Str.joinWith ", " bad }
    )
  where
  -- only `Wasm.*` modules; other foreigns may legitimately resolve via ulib / JS-fallback
  unsupported m
    | Array.head m.name == Just "Wasm" = Array.filter (not <<< recognized) (map (qualified m.name) m.foreignNames)
    | otherwise = []
  qualified modName fn = Str.joinWith "." modName <> "." <> fn
  recognized qual = isJust (qualifiedIntrinsic qual) || isJust (foreignIntrinsic (lastSegment qual))
  lastSegment q = fromMaybe q (Array.last (Str.split (Pattern ".") q))

-- | The purs compiler version(s) whose CoreFn format this backend's decoder is verified against
-- | (ADR 0029). A linked module — the user's app *or* a ulib shadow — built with another compiler
-- | may carry a subtly different CoreFn shape this backend would mis-decode, so it is rejected
-- | loudly rather than silently miscompiled. Widen only after testing the decoder against the new
-- | compiler's output (a breaking CoreFn change between two purs releases is exactly what this
-- | guards: it surfaces as a clear error, not a wrong build).
supportedCorefn :: Array String
supportedCorefn = [ "0.15.16" ]

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

-- | The registry modules ulib shadows (ADR 0028), each tied to the *package* version its
-- | shadow was reimplemented against.
type Shadow = { package :: String, version :: String, corefn :: FilePath }

-- | Scan the ulib lib for shadows: each `<lib>/<package>-<version>/<Module>/corefn.json` is a
-- | shadow of registry module `<Module>`, tagged with the package version it targets (ADR 0028).
-- | Returns a `Module name -> Shadow` map. An absent lib (e.g. the lib build hasn't run) → empty.
loadShadowMap :: FilePath -> Aff (Map.Map String Shadow)
loadShadowMap libPath = do
  present <- isNothing <$> FS.access libPath
  if not present then pure Map.empty
  else do
    pkgDirs <- FS.readdir libPath
    rows <- for pkgDirs \pkgVer -> do
      let pkgPath = Path.concat [ libPath, pkgVer ]
      let { pkg, ver } = splitPkgVer pkgVer
      mods <- try (FS.readdir pkgPath)
      pure case mods of
        Right ms -> ms <#> \m -> Tuple m { package: pkg, version: ver, corefn: Path.concat [ pkgPath, m, "corefn.json" ] }
        Left _ -> []
    pure (Map.fromFoldable (Array.concat rows))

-- | Split a `<package>-<version>` directory name on its last `-` (versions carry no `-`, but a
-- | package name may: `foldable-traversable-6.0.0` → package `foldable-traversable`, ver `6.0.0`).
splitPkgVer :: String -> { pkg :: String, ver :: String }
splitPkgVer s = case Array.unsnoc (Str.split (Pattern "-") s) of
  Just { init, last } -> { pkg: Str.joinWith "-" init, ver: last }
  Nothing -> { pkg: s, ver: "" }

-- | `6.0.2` -> `6.0`. Shadows match a registry version by `major.minor` (a patch bump keeps the
-- | module interface, so it still applies; a minor/major bump may not — ADR 0028).
majorMinor :: String -> String
majorMinor v = Str.joinWith "." (Array.take 2 (Str.split (Pattern ".") v))

-- | Extract `<package>`'s version from a corefn modulePath (`…/<package>-<version>/…`).
pkgVersionFromPath :: String -> String -> Maybe String
pkgVersionFromPath pkg path =
  Array.index (Str.split (Pattern (pkg <> "-")) path) 1 >>= (Array.head <<< Str.split (Pattern "/"))

-- | ulib lib-first shadowing (ADR 0028): if `mod` has a ulib shadow whose target package version
-- | matches (by `major.minor`) the user's resolved version, use the shadow's corefn (PureScript
-- | over WasmBase → the closures specialize, ADR 0027). Otherwise keep the registry module
-- | (correct, but the foreign HOF stays opaque) with a warning. Never fails the build.
shadowOrRegistry :: Map.Map String Shadow -> ModuleName -> Module -> Aff Module
shadowOrRegistry shadows mod registryMod = case Map.lookup (printModname mod) shadows of
  Nothing -> pure registryMod
  Just s
    | (majorMinor <$> pkgVersionFromPath s.package registryMod.path) /= Just (majorMinor s.version) -> do
        Console.log
          ( Fmt.fmt
              @"  ulib: {m} not shadowed ({pkg} {got} ≠ supported {want}); using registry (foreign HOF stays slow)"
              { m: printModname mod, pkg: s.package, got: fromMaybe "?" (pkgVersionFromPath s.package registryMod.path), want: s.version }
          )
        pure registryMod
    | otherwise -> do
        libSrc <- FS.readTextFile UTF8 s.corefn
        case parseModule libSrc of
          Left _ -> pure registryMod
          Right libMod -> do
            Console.log (Fmt.fmt @"  ulib: shadowing {m} ({pkg} {ver})" { m: printModname mod, pkg: s.package, ver: s.version })
            pure libMod

main :: FilePath -> Effect Unit
main _cliRoot =
  parseArgs >>= case _ of
    Left err -> Console.error (ArgParser.printArgError err)
    Right (Build args) -> launchAff_ (buildCmd _cliRoot args)
    Right (UlibInstall args) -> launchAff_ (ulibInstallCmd _cliRoot args)
    Right (UlibValidate args) -> launchAff_ (ulibValidateCmd _cliRoot args)
    Right (UlibCheck args) -> launchAff_ (ulibCheckCmd _cliRoot args)

-- | Link every module found under `input` into one wasm and write it to
-- | `output`. Paths are resolved against the current working directory.
-- | `purs-wasm ulib install` (ADR 0028): compile the ulib shadows (`<cli>/../ulib/shadow/`)
-- | into the lib (corefn + externs) via `ulib-install.sh`. Skips if the lib already exists,
-- | unless `--force`. The shadow set is the dir structure (`<pkg>-<ver>/<Module path>.purs`),
-- | compiled against the resolved package-set sources (`.spago/p`) with WasmBase overlaid.
ulibInstallCmd :: FilePath -> UlibInstallOption -> Aff Unit
ulibInstallCmd cliRoot opt = do
  let libPath = fromMaybe (Path.concat [ cliRoot, "..", "lib" ]) opt.libPath
  let purs = fromMaybe "purs" opt.purs
  let shadowRoot = Path.concat [ cliRoot, "..", "ulib", "shadow" ]
  let wasmBaseSrc = Path.concat [ cliRoot, "..", "wasm-base", "src" ]
  let script = Path.concat [ cliRoot, "ulib-install.sh" ]
  present <- isNothing <$> FS.access libPath
  if present && not opt.force then
    Console.log "ulib: lib already present (use -f/--force to rebuild)."
  else do
    when opt.force (execFile "rm" [ "-rf", libPath ])
    Console.log "ulib: compiling shadows -> lib …"
    execFile "sh" [ script, libPath, shadowRoot, wasmBaseSrc, purs, Path.concat [ ".spago", "p" ] ]
    Console.log "ulib: done."

-- | Decode a `externs.cbor` file, or `Nothing` if it is absent/unreadable/undecodable
-- | (CBOR → Foreign → `ExternsFile`). Mirrors the externs read in `buildCmd`.
readExterns :: FilePath -> Aff (Maybe ExternsFile)
readExterns path = do
  result <- try do
    buf <- FS.readFile path
    fgn <- decodeFirst buf
    pure (runDecoder decoder fgn)
  pure case result of
    Right (Right ef) -> Just ef
    _ -> Nothing

-- | `purs-wasm ulib validate` (ADR 0028): for each installed shadow, check that the package
-- | version it was built against still matches (by `major.minor`) the version resolved in your
-- | workspace (`.spago/p`). A patch bump keeps the interface so the shadow still applies; a
-- | minor/major divergence means the shadow would be skipped at build time (the foreign HOF
-- | stays slow) — so this fails loudly and asks you to align your version to the ulib's.
ulibValidateCmd :: FilePath -> UlibValidateOption -> Aff Unit
ulibValidateCmd cliRoot opt = do
  let libPath = fromMaybe (Path.concat [ cliRoot, "..", "lib" ]) opt.libPath
  let spago = fromMaybe (Path.concat [ ".spago", "p" ]) opt.spago
  libPresent <- isNothing <$> FS.access libPath
  if not libPresent then Console.log "ulib: no lib installed (run `ulib install`)."
  else do
    pkgDirs <- FS.readdir libPath
    spagoDirs <- either (const []) identity <$> try (FS.readdir spago)
    let userVers = Map.fromFoldable (spagoDirs <#> \d -> let { pkg, ver } = splitPkgVer d in Tuple pkg ver)
    let
      rows = pkgDirs <#> \pkgVer ->
        let
          { pkg, ver } = splitPkgVer pkgVer
        in
          { pkg, ulibVer: ver, userVer: Map.lookup pkg userVers }
    for_ rows \r -> case r.userVer of
      Nothing ->
        Console.log (Fmt.fmt @"  ? {pkg}: ulib {u}, not in your workspace" { pkg: r.pkg, u: r.ulibVer })
      Just uv
        | majorMinor uv == majorMinor r.ulibVer ->
            Console.log (Fmt.fmt @"  ✓ {pkg}: ulib {u}, yours {y}" { pkg: r.pkg, u: r.ulibVer, y: uv })
        | otherwise ->
            Console.log (Fmt.fmt @"  ✗ {pkg}: ulib {u} ≠ yours {y} (major.minor differs)" { pkg: r.pkg, u: r.ulibVer, y: uv })
    let mismatches = Array.filter (\r -> maybe false (\uv -> majorMinor uv /= majorMinor r.ulibVer) r.userVer) rows
    if Array.null mismatches then Console.log "ulib: validate OK."
    else throwError
      ( error
          ( Fmt.fmt
              @"ulib: {n} package(s) diverge from the shadows. Align your workspace to: {pkgs}."
              { n: Array.length mismatches, pkgs: Str.joinWith ", " (mismatches <#> \r -> r.pkg <> " " <> r.ulibVer) }
          )
      )

-- | `purs-wasm ulib check` (ADR 0028, deep check): compare each installed shadow's *public
-- | interface* (exported names, from its stored externs) against the same module compiled in
-- | your workspace (`<input>/<Module>/externs.cbor`, i.e. your spago build output). A shadow
-- | that drops a name the registry module exports is not a drop-in — that fails the check; a
-- | shadow that only *adds* names is reported but allowed. A module you have not compiled yet
-- | is skipped with a note (build your project first to check it).
ulibCheckCmd :: FilePath -> UlibCheckOption -> Aff Unit
ulibCheckCmd cliRoot opt = do
  let libPath = fromMaybe (Path.concat [ cliRoot, "..", "lib" ]) opt.libPath
  let input = fromMaybe (Path.concat [ ".", "output" ]) opt.input
  libPresent <- isNothing <$> FS.access libPath
  if not libPresent then Console.log "ulib: no lib installed (run `ulib install`)."
  else do
    pkgDirs <- FS.readdir libPath
    breaks <- map Array.concat $ for pkgDirs \pkgVer -> do
      let pkgPath = Path.concat [ libPath, pkgVer ]
      mods <- either (const []) identity <$> try (FS.readdir pkgPath)
      map Array.catMaybes $ for mods \mod -> do
        libExt <- readExterns (Path.concat [ pkgPath, mod, "externs.cbor" ])
        usrExt <- readExterns (Path.concat [ input, mod, "externs.cbor" ])
        case libExt, usrExt of
          _, Nothing -> do
            Console.log (Fmt.fmt @"  - {m} ({p}): not compiled in your workspace; skipped" { m: mod, p: pkgVer })
            pure Nothing
          Nothing, _ -> do
            Console.log (Fmt.fmt @"  - {m} ({p}): shadow externs unreadable; skipped" { m: mod, p: pkgVer })
            pure Nothing
          Just le, Just ue -> do
            let d = diffInterface (interfaceOf ue) (interfaceOf le)
            if compatible d then do
              Console.log
                ( Fmt.fmt @"  ✓ {m} ({p}): interface OK{extra}"
                    { m: mod, p: pkgVer, extra: if Array.null d.extra then "" else " (+" <> show (Array.length d.extra) <> " extra)" }
                )
              pure Nothing
            else do
              Console.log (Fmt.fmt @"  ✗ {m} ({p}): missing {names}" { m: mod, p: pkgVer, names: Str.joinWith ", " d.missing })
              pure (Just mod)
    if Array.null breaks then Console.log "ulib: check OK."
    else throwError
      ( error
          ( Fmt.fmt
              @"ulib: {n} shadow(s) are not drop-in for your workspace: {mods}. Align your version to the ulib's, or update the shadow."
              { n: Array.length breaks, mods: Str.joinWith ", " breaks }
          )
      )

buildCmd :: FilePath -> BuildOption -> Aff Unit
buildCmd cliRoot args = do
  logShow args
  -- ulib lib (ADR 0028) sits beside the compiler: `node_modules/purs-wasm/lib`, the nix
  -- store path, or — for this in-repo prototype — the project root `lib/`. `cliRoot` is the
  -- `bin/` dir (the CLI entry's dirname), so the lib is one level up.
  let libPath = Path.concat [ cliRoot, "..", "lib" ]
  shadows <- loadShadowMap libPath
  -- Each subdirectory of `input` is named by its dotted module name; sort for a
  -- deterministic build (ADR 0009).
  entries <- FS.readdir args.input
  let named = Array.sort (Array.mapMaybe toModuleName entries)
  -- `Prim` and the other built-in pseudo-modules have an output directory but no
  -- `corefn.json` (they are compiler intrinsics with no CoreFn); skip any module
  -- whose CoreFn artifact is absent rather than failing the whole build.
  allMods <- Array.filterA (\mod -> isNothing <$> FS.access (Path.concat [ args.input, printModname mod, "corefn.json" ])) named
  let roots = map entryRoot (Array.fromFoldable args.entryModules)
  -- File-level reachability pruning (before the expensive full decode): a real app's
  -- output dir holds far more modules than one entry needs, and decoding them all OOMs
  -- the build. Read each module's imports cheaply (transient `JSON.parse`, GC'd), then
  -- keep only the modules transitively reachable from the entry roots.
  importPairs <- for allMods \mod -> do
    source <- FS.readTextFile UTF8 (Path.concat [ args.input, printModname mod, "corefn.json" ])
    pure (Tuple (printModname mod) (corefnImportsImpl source))
  let reachable = reachableClosure roots (Map.fromFoldable importPairs)
  let mods = Array.filter (\mod -> Set.member (printModname mod) reachable) allMods
  Console.log (Fmt.fmt @"Linking {count} of {total} module(s) from {dir}" { count: Array.length mods, total: Array.length allMods, dir: args.input })
  modules <- for mods \mod -> do
    source <- FS.readTextFile UTF8 (Path.concat [ args.input, printModname mod, "corefn.json" ])
    case parseModule source of
      Left err -> throwError (error (printModname mod <> ": " <> err))
      Right m -> shadowOrRegistry shadows mod m
  -- Fail early on a `wasm-base` whose version is incompatible with this backend (ADR 0026).
  either (throwError <<< error) pure (checkWasmBaseCompat modules)
  -- Reject CoreFn from an unsupported purs (ADR 0029): the user's app and the bundled ulib lib
  -- must both be the compiler this backend's decoder is verified against, else a CoreFn-format
  -- change could mis-decode silently.
  either (throwError <<< error) pure (checkCorefnVersions modules)
  -- Each module's `externs.cbor` carries the top-level type information CoreFn
  -- erased; it drives type-directed lowering (front B). A module without readable
  -- or decodable externs is simply skipped — its constructors fall back to boxed.
  externs <- map Array.catMaybes $ for mods \mod -> do
    result <- try do
      buf <- FS.readFile (Path.concat [ args.input, printModname mod, "externs.cbor" ])
      fgn <- decodeFirst buf
      pure (runDecoder decoder fgn)
    pure case result of
      Right (Right ef) -> Just ef
      _ -> Nothing
  -- Reconstruct foreign signatures from `.purs` source (ADR 0016): externs omit private
  -- `*Impl` foreigns, but the source has them. We only parse a module's source when its
  -- CoreFn `foreignNames` mentions a foreign that externs do NOT cover (i.e. a private one),
  -- so the common all-exported-foreigns module never pays the parse cost. `cache-db.json`
  -- (beside the artifacts) maps each module to its source path.
  let externsSigs = foreignSigs externs
  cacheDbTxt <- try (FS.readTextFile UTF8 (Path.concat [ args.input, "cache-db.json" ]))
  let sourcePaths = either (const Object.empty) cacheDbSourcesImpl cacheDbTxt
  srcSigsByMod <- for modules \m -> do
    let mn = printModname m.name
    let hasPrivate = Array.any (\base -> not (Object.member (mn <> "." <> base) externsSigs)) m.foreignNames
    case Tuple hasPrivate (Object.lookup mn sourcePaths) of
      Tuple true (Just path) -> do
        result <- try (FS.readTextFile UTF8 path)
        pure (either (const Object.empty) parseForeignSigs result)
      _ -> pure Object.empty
  -- externs win over source (`Object.union` is left-biased): externs types are already
  -- desugared by `purs`, so they are authoritative for *exported* foreigns; source only
  -- fills the private foreigns externs omit (ADR 0016). Both keyed by `Module.ident`.
  let srcSigs = Array.foldl Object.union Object.empty srcSigsByMod
  -- ulib (ADR 0012): for a module with no project-local provider, read the curated
  -- `ulib/<M>/foreign.wat` export signatures (the wasm export is the source of truth) so the
  -- compiler emits correctly-typed host imports the merge resolves — this covers the polymorphic
  -- `*Impl` foreigns whose arity externs cannot reconstruct. The ulib sig overrides
  -- externs/source (the merged ulib provider is authoritative for those foreigns).
  ulibSigsByMod <- for modules \m -> do
    let mn = printModname m.name
    projWasm <- isNothing <$> FS.access (Path.concat [ args.input, mn, "foreign.wasm" ])
    projWat <- isNothing <$> FS.access (Path.concat [ args.input, mn, "foreign.wat" ])
    if projWasm || projWat then pure Object.empty
    else do
      let ulibWat = Path.concat [ ulibDir, mn, "foreign.wat" ]
      has <- isNothing <$> FS.access ulibWat
      if has then either (const Object.empty) (parseUlibSigs mn) <$> try (FS.readTextFile UTF8 ulibWat)
      else pure Object.empty
  let ulibSigs = Array.foldl Object.union Object.empty ulibSigsByMod
  let allSigs = Object.union ulibSigs (Object.union externsSigs srcSigs)
  let opts = { optimize: not args.debug, optimizeMir: not args.noOpt }
  -- `--trace-mir <Module>`: dump that module's MIR after every optimizer sub-stage to
  -- ./mir-trace.txt (debugging the optimizer; cf. purs-backend-es --trace-rewrites).
  case args.traceMir of
    Nothing -> pure unit
    Just target -> do
      FS.writeTextFile UTF8 "mir-trace.txt" (mirTrace opts modules allSigs target)
      Console.log ("Wrote MIR trace for " <> target <> " to ./mir-trace.txt")
  -- one bundle per build: place it in a directory named after the (first) entry
  -- module, mirroring purs / backend-es (`<output>/<Entry>/index.{wasm,wat}`), so
  -- companion artifacts (a .wat, a future JS loader / source map) sit together.
  let bundleDir = Path.concat [ args.outDir, NEL.head args.entryModules ]
  FS.mkdir' bundleDir { recursive: true, mode: permsAll }
  -- The generated module imports the shared runtime (`$rt.*`, ADR 0010). Compile
  -- it, then merge `runtime.wasm` in with `wasm-merge` to produce one
  -- self-contained wasm (imports resolved); `--text` disassembles that result.
  let appPath = Path.concat [ bundleDir, "app.wasm" ]
  let wasmPath = Path.concat [ bundleDir, "index.wasm" ]
  liftEffect (compileModules opts roots modules externs allSigs) >>= case _ of
    Left err -> throwError (error err)
    Right bytes -> do
      -- the user `foreign import` modules the wasm needs (ADR 0014); empty for a
      -- self-contained program (only intrinsic / runtime foreigns)
      foreignMods <- liftEffect (importModulesImpl bytes)
      FS.writeFile appPath (unsafeCoerce bytes)
      -- Resolve each foreign module along the ADR 0014 ladder, packaging stage: a
      -- `foreign.wasm`/`foreign.wat` provider is merged in (self-contained, no
      -- marshalling — it speaks the internal ABI); otherwise it falls back to JS
      -- (`foreign.js`, satisfied by the generated loader).
      providers <- for foreignMods (resolveForeign args.input bundleDir)
      let wasmProvided = Array.mapMaybe (\p -> Tuple p.name <$> p.wasm) providers
      let jsProvided = Array.mapMaybe (\p -> if isNothing p.wasm then Just p.name else Nothing) providers
      let mergeForeigns = wasmProvided >>= \(Tuple name wp) -> [ wp, name ]
      execFile wasmMergeBin ([ appPath, "app", runtimeWasm, "rt" ] <> mergeForeigns <> [ "-o", wasmPath, "--all-features" ])
      FS.unlink appPath
      for_ providers \p -> when p.assembled (maybe (pure unit) FS.unlink p.wasm)
      if args.text then do
        let watPath = Path.concat [ bundleDir, "index.wat" ]
        execFile wasmDisBin [ wasmPath, "-o", watPath, "--all-features" ]
        FS.unlink wasmPath
        Console.log (Fmt.fmt @"Wrote {file}" { file: watPath })
      else do
        -- emit the JS loader when there are JS foreign imports to satisfy, or when any
        -- entry export needs marshalling (a non-`i32`/`f64` param/result); ADR 0014.
        -- `allSigs` (source ∪ externs, ADR 0016) is the manifest source so private
        -- foreigns are marshalled too.
        let exportSigs = rootExportSigs roots allSigs
        let needLoader = not (Array.null jsProvided) || Array.any exportNeedsLoader (Object.values exportSigs)
        when needLoader (emitLoader bundleDir args.input jsProvided allSigs (exportManifestJson exportSigs))
        Console.log (Fmt.fmt @"Wrote {file}" { file: wasmPath })
  where
  -- Resolved against the current working directory (run `bin` from the repo root).
  runtimeWasm = "runtime/runtime.wasm"
  ulibDir = "ulib"
  wasmMergeBin = "binaryen/node_modules/binaryen/bin/wasm-merge"
  wasmDisBin = "binaryen/node_modules/binaryen/bin/wasm-dis"
  wasmAsBin = "binaryen/node_modules/binaryen/bin/wasm-as"

  -- The foreign provider for a module (ADR 0014 / 0012). Resolution order: a project-local
  -- `foreign.wasm` (used directly) / `foreign.wat` (assembled), then the curated
  -- `ulib/<Module>/foreign.wat` (assembled), both merged as the in-wasm provider that speaks
  -- the internal ABI; otherwise `wasm` is `Nothing` and it falls back to the JS loader.
  -- A project-local provider wins over `ulib` (a program can override a curated module).
  resolveForeign input bundleDir m = do
    let wasmSrc = Path.concat [ input, m, "foreign.wasm" ]
    hasWasm <- exists wasmSrc
    if hasWasm then pure { name: m, wasm: Just wasmSrc, assembled: false }
    else do
      let watSrc = Path.concat [ input, m, "foreign.wat" ]
      hasWat <- exists watSrc
      if hasWat then assemble watSrc
      else do
        let ulibWat = Path.concat [ ulibDir, m, "foreign.wat" ]
        hasUlibWat <- exists ulibWat
        if hasUlibWat then assemble ulibWat
        else do
          let ulibWasm = Path.concat [ ulibDir, m, "foreign.wasm" ]
          hasUlibWasm <- exists ulibWasm
          if hasUlibWasm then pure { name: m, wasm: Just ulibWasm, assembled: false }
          else pure { name: m, wasm: Nothing, assembled: false }
    where
    exists p = isNothing <$> FS.access p
    -- Assemble a foreign `.wat`. A full `(module …)` is assembled as-is; a *fragment*
    -- (no `(module …)`) is wrapped as `(module <ulib/_header.wat> <fragment>)` first, so it
    -- shares the runtime value types via the one authoritative header (ADR 0010 / 0012).
    assemble watSrc = do
      content <- FS.readTextFile UTF8 watSrc
      let out = Path.concat [ bundleDir, m <> ".foreign.wasm" ]
      -- a full module has `(module` at the start of some line (not merely in a comment)
      let isFullModule = Array.any (\l -> Str.take 7 (Str.trim l) == "(module") (Str.split (Pattern "\n") content)
      if isFullModule then do
        execFile wasmAsBin [ watSrc, "-o", out, "--all-features" ]
        pure { name: m, wasm: Just out, assembled: true }
      else do
        header <- FS.readTextFile UTF8 (Path.concat [ ulibDir, "_header.wat" ])
        let combined = Path.concat [ bundleDir, m <> ".combined.wat" ]
        FS.writeTextFile UTF8 combined ("(module\n" <> header <> "\n" <> content <> "\n)\n")
        execFile wasmAsBin [ combined, "-o", out, "--all-features" ]
        FS.unlink combined
        pure { name: m, wasm: Just out, assembled: true }

-- | Emit the JS loader for a program that has host imports (ADR 0014): copy each
-- | used module's `foreign.js` into `<bundle>/foreign/<Module>.js`, then write a
-- | generic `index.mjs` that instantiates `index.wasm`, discovers its imports at
-- | run time, and satisfies each from the matching foreign module's JS.
emitLoader :: FilePath -> FilePath -> Array String -> Object ForeignImport -> String -> Aff Unit
emitLoader bundleDir input mods sigs exportManifest = do
  let foreignDir = Path.concat [ bundleDir, "foreign" ]
  FS.mkdir' foreignDir { recursive: true, mode: permsAll }
  for_ mods \m -> do
    src <- FS.readTextFile UTF8 (Path.concat [ input, m, "foreign.js" ])
    FS.writeTextFile UTF8 (Path.concat [ foreignDir, m <> ".js" ]) src
  FS.writeTextFile UTF8 (Path.concat [ bundleDir, "index.mjs" ]) (loaderSource (manifestJs mods sigs) exportManifest)
  Console.log (Fmt.fmt @"Wrote {file} (+ {n} foreign module(s))" { file: Path.concat [ bundleDir, "index.mjs" ], n: Array.length mods })

-- | The export marshal signatures for the entry (`roots`) modules: every top-level
-- | value of a root module, keyed by its bare name (ADR 0014). A superset of the
-- | actually-exported functions — the loader only wraps names present in
-- | `inst.exports`, so extra entries are harmless.
rootExportSigs :: Array (Array String) -> Object ForeignImport -> Object ForeignImport
rootExportSigs roots sigs = Object.fromFoldable do
  s <- Object.values sigs
  if Array.elem s.moduleName (map printModname roots) then [ Tuple s.base s ] else []

-- | Whether a root export needs the JS loader to marshal it: any param/result that is
-- | not a raw scalar (`Int`/`Char` → `i32`, `Number` → `f64`) crosses as an `eqref`
-- | and so needs the glue (`String`/`Boolean`/`Array`/`Record`/closure).
exportNeedsLoader :: ForeignImport -> Boolean
exportNeedsLoader s = Array.any nonRaw s.params || nonRaw s.result
  where
  nonRaw = case _ of
    MI32 -> false
    MF64 -> false
    _ -> true

-- | The marshalling manifest as a JSON object literal, keyed by import name
-- | `Module.base`: `{ "M.f": { "params": [<kind>…], "result": <kind> } }` (ADR 0014).
-- | Each `<kind>` is an `encodeMarshalKind` value (`"i"`/`"s"` leaves, `{"a":…}`
-- | array, `{"r":{…}}` record). Restricted to the foreign modules actually linked.
manifestJs :: Array String -> Object ForeignImport -> String
manifestJs mods sigs =
  foreignManifestJson (Array.filter (\s -> Array.elem s.moduleName mods) (Object.values sigs))

-- | The generated loader (ADR 0014): instantiate the GC wasm, discover its host
-- | imports, satisfy each from `./foreign/<Module>.js` (wrapping them with argument/
-- | result marshalling per the baked import `MANIFEST`), and expose the wasm exports
-- | with the **mirror-image** marshalling (per `EXPORTS_MANIFEST`) so JS callers pass
-- | and receive ordinary JS values. Conversions go through the runtime's exported
-- | helpers (`strLen`/`strNew`/`boxInt`/`recEmpty`/`applyClo`/…).
loaderSource :: String -> String -> String
loaderSource manifest exportManifest =
  """import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const MANIFEST = """ <> manifest
    <>
      """;
const EXPORTS_MANIFEST = """
    <> exportManifest
    <>
      """;

const bytes = readFileSync(fileURLToPath(new URL("./index.wasm", import.meta.url)));
const mod = await WebAssembly.compile(bytes);

let inst;
const enc = new TextEncoder();
const dec = new TextDecoder();
const strToJs = (ref) => {
  const n = inst.exports.strLen(ref);
  const b = new Uint8Array(n);
  for (let i = 0; i < n; i++) b[i] = inst.exports.strByteAt(ref, i);
  return dec.decode(b);
};
const strFromJs = (s) => {
  const b = enc.encode(s);
  const ref = inst.exports.strNew(b.length);
  for (let i = 0; i < b.length; i++) inst.exports.strSetByte(ref, i, b[i]);
  return ref;
};
// `k` is a parsed encodeMarshalKind value: a string leaf ("i"/"f"/"b"/"s"/"o"), {a:k}
// (array), {fn:[pk,rk]} (function), or {r:{field:k}} (record). eqref → JS, by kind.
const eqrefToJs = (k, ref) => {
  if (typeof k === "string") {
    if (k === "i") return inst.exports.unboxInt(ref);
    if (k === "f") return inst.exports.unboxNum(ref);
    if (k === "b") return !!inst.exports.unboxBool(ref);
    if (k === "s") return strToJs(ref);
    return ref;
  }
  if (k.a !== undefined) {
    const n = inst.exports.arrayLen(ref);
    const out = new Array(n);
    for (let i = 0; i < n; i++) out[i] = eqrefToJs(k.a, inst.exports.arrayGet(ref, i));
    return out;
  }
  if (k.fn !== undefined) {
    // a wasm $Clo → a JS function: marshal the arg in, apply via the trampoline, marshal out
    const [pk, rk] = k.fn;
    return (a) => eqrefToJs(rk, inst.exports.applyClo(ref, eqrefFromJs(pk, a)));
  }
  // Effect a (export side): wasm already performed it, so the value IS the inner result
  if (k.eff !== undefined) return eqrefToJs(k.eff, ref);
  // record: read each known field by its interned label id
  const out = {};
  for (const name of Object.keys(k.r)) {
    out[name] = eqrefToJs(k.r[name], inst.exports.proj(ref, inst.exports.internStr(strFromJs(name))));
  }
  return out;
};
// JS → eqref (a boxed, nested value), by kind.
const eqrefFromJs = (k, val) => {
  if (typeof k === "string") {
    if (k === "i") return inst.exports.boxInt(val);
    if (k === "f") return inst.exports.boxNum(val);
    if (k === "b") return inst.exports.boxBool(val ? 1 : 0);
    if (k === "s") return strFromJs(val);
    return val;
  }
  if (k.a !== undefined) {
    const ref = inst.exports.arrayNew(val.length);
    for (let i = 0; i < val.length; i++) inst.exports.arraySet(ref, i, eqrefFromJs(k.a, val[i]));
    return ref;
  }
  if (k.fn !== undefined) {
    throw new Error("FFI: marshalling a JS function into wasm is not yet supported (ADR 0014, closure direction 2)");
  }
  // record: recSet each field onto an empty record, keyed by interned label id
  let ref = inst.exports.recEmpty();
  for (const name of Object.keys(k.r)) {
    ref = inst.exports.recSet(ref, inst.exports.internStr(strFromJs(name)), eqrefFromJs(k.r[name], val[name]));
  }
  return ref;
};
const isRaw = (k) => k === "i" || k === "f";
// PureScript FFI foreigns are *curried* (`a => b => c`), so apply one argument at a
// time — `fn(...xs)` would pass only the first to a curried foreign (a multi-arg
// foreign like `unfoldrArrayImpl` would return a function, not its result).
const applyCurried = (fn, xs) => xs.reduce((g, x) => g(x), fn);
// import direction: wasm calls the JS foreign — args wasm→JS, result JS→wasm
const wrap = (fn, sig) => (...args) => {
  const xs = args.map((a, i) => (isRaw(sig.params[i]) ? a : eqrefToJs(sig.params[i], a)));
  // an effectful foreign (`{eff:k}` result): applying the value args yields the Effect
  // thunk, which we RUN here (the perform is on the JS side), then marshal the inner
  // result by `k` (ADR 0015). A *nullary* Effect foreign (`Effect a`, no value args, e.g.
  // `random`) IS the thunk, so we must not pre-call it. Unit (undefined) → boxed 0.
  if (sig.result && sig.result.eff !== undefined) {
    const thunk = applyCurried(fn, xs);
    const ran = thunk();
    const k = sig.result.eff;
    if (ran === undefined || ran === null) return inst.exports.boxInt(0);
    return isRaw(k) ? ran : eqrefFromJs(k, ran);
  }
  const r = applyCurried(fn, xs);
  return isRaw(sig.result) ? r : eqrefFromJs(sig.result, r);
};
// export direction: JS calls the wasm export — args JS→wasm, result wasm→JS
const wrapExport = (fn, sig) => (...args) => {
  const xs = args.map((a, i) => (isRaw(sig.params[i]) ? a : eqrefFromJs(sig.params[i], a)));
  const r = fn(...xs);
  return isRaw(sig.result) ? r : eqrefToJs(sig.result, r);
};

const importObject = {};
const nsCache = {};
for (const { module, name } of WebAssembly.Module.imports(mod)) {
  if (!nsCache[module]) {
    nsCache[module] = await import(new URL(`./foreign/${module}.js`, import.meta.url).href);
    importObject[module] = {};
  }
  const sig = MANIFEST[module + "." + name];
  importObject[module][name] = sig ? wrap(nsCache[module][name], sig) : nsCache[module][name];
}

inst = await WebAssembly.instantiate(mod, importObject);
// expose the exports as plain JS values. A function export (the type has arguments) is
// wrapped so callers pass/receive JS values; a nullary value binding (a CAF, the type
// has no arguments) is evaluated once here and exposed as the value itself — marshalled
// for a non-raw result — so JS sees `exports.x` as `42` / "hi" / {…}, not a function.
const marshalledExports = {};
for (const name of Object.keys(inst.exports)) {
  const e = inst.exports[name];
  const sig = EXPORTS_MANIFEST[name];
  if (!sig || typeof e !== "function") {
    marshalledExports[name] = e;
  } else if (sig.params.length === 0 && sig.result && sig.result.eff !== undefined) {
    // an `Effect a` value binding (e.g. `main`) is a *deferred computation*, not a CAF:
    // expose it as a JS thunk `() => a` so the effect runs when CALLED, not at load
    // (matching `Effect a ≃ () => a`). The wasm export performs it on each call.
    const k = sig.result.eff;
    marshalledExports[name] = () => {
      const r = e();
      return isRaw(k) ? r : eqrefToJs(k, r);
    };
  } else if (sig.params.length === 0 && e.length === 0) {
    // a genuine CAF (source value, compiled to a nullary function): call it once at load
    // and expose the resulting value, so it reads as a value on the JS side, not a thunk.
    const r = e();
    marshalledExports[name] = isRaw(sig.result) ? r : eqrefToJs(sig.result, r);
  } else if (sig.params.length === 0) {
    // the source type is a value but the backend compiled it to a *function* — a monadic
    // value (e.g. `TypingM a`) collapsed to take its reader/state arguments (ADR 0015). It
    // is not a JS-usable CAF, and calling it with no args would trap (`illegal cast` on the
    // missing argument), so expose the raw wasm export rather than evaluating it at load.
    marshalledExports[name] = e;
  } else {
    marshalledExports[name] = wrapExport(e, sig);
  }
}
export const exports = marshalledExports;
export default exports;
"""
