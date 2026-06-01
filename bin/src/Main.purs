module Main where

import Prelude

import ArgParse.Basic (ArgParser)
import ArgParse.Basic as ArgParser
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (isNothing)
import Data.List.NonEmpty as NEL
import Data.String (Pattern(..))
import Data.String as Str
import Data.Traversable (for)
import Effect (Effect)
import Effect.Aff (Aff, launchAff_, throwError)
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
import PureScript.Backend.Wasm.Compiler (compileModules, parseModule)
import PureScript.CoreFn (ModuleName, toModuleName)
import Unsafe.Coerce (unsafeCoerce)
import Version as Version

-- | Run an external tool synchronously (used for `wasm-merge` / `wasm-dis`).
foreign import execFileImpl :: String -> Array String -> Effect Unit

execFile :: String -> Array String -> Aff Unit
execFile cmd args = liftEffect (execFileImpl cmd args)

type BuildOption =
  { input :: FilePath
  , outDir :: FilePath
  , entryModules :: NEL.NonEmptyList String
  , text :: Boolean
  , debug :: Boolean
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
    }

data Command = Build BuildOption

commandParser :: ArgParser Command
commandParser =
  ArgParser.choose "command"
    [ ArgParser.command [ "build" ]
        "Build a wasm module from a PureScript project's compiler artifacts"
        do
          Build <$> buildOptionsParser <* ArgParser.flagHelp
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

main :: FilePath -> Effect Unit
main _cliRoot =
  parseArgs >>= case _ of
    Left err -> Console.error (ArgParser.printArgError err)
    Right (Build args) -> launchAff_ (buildCmd args)

-- | Link every module found under `input` into one wasm and write it to
-- | `output`. Paths are resolved against the current working directory.
buildCmd :: BuildOption -> Aff Unit
buildCmd args = do
  logShow args
  -- Each subdirectory of `input` is named by its dotted module name; sort for a
  -- deterministic build (ADR 0009).
  entries <- FS.readdir args.input
  let named = Array.sort (Array.mapMaybe toModuleName entries)
  -- `Prim` and the other built-in pseudo-modules have an output directory but no
  -- `corefn.json` (they are compiler intrinsics with no CoreFn); skip any module
  -- whose CoreFn artifact is absent rather than failing the whole build.
  mods <- Array.filterA (\mod -> isNothing <$> FS.access (Path.concat [ args.input, printModname mod, "corefn.json" ])) named
  Console.log (Fmt.fmt @"Linking {count} module(s) from {dir}" { count: Array.length mods, dir: args.input })
  modules <- for mods \mod -> do
    source <- FS.readTextFile UTF8 (Path.concat [ args.input, printModname mod, "corefn.json" ])
    case parseModule source of
      Left err -> throwError (error (printModname mod <> ": " <> err))
      Right m -> pure m
  let roots = map entryRoot (Array.fromFoldable args.entryModules)
  let opts = { optimize: not args.debug }
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
  liftEffect (compileModules opts roots modules) >>= case _ of
    Left err -> throwError (error err)
    Right bytes -> do
      FS.writeFile appPath (unsafeCoerce bytes)
      execFile wasmMergeBin [ appPath, "app", runtimeWasm, "rt", "-o", wasmPath, "--all-features" ]
      FS.unlink appPath
      if args.text then do
        let watPath = Path.concat [ bundleDir, "index.wat" ]
        execFile wasmDisBin [ wasmPath, "-o", watPath, "--all-features" ]
        FS.unlink wasmPath
        Console.log (Fmt.fmt @"Wrote {file}" { file: watPath })
      else
        Console.log (Fmt.fmt @"Wrote {file}" { file: wasmPath })
  where
  -- Resolved against the current working directory (run `bin` from the repo root).
  runtimeWasm = "runtime/runtime.wasm"
  wasmMergeBin = "binaryen/node_modules/binaryen/bin/wasm-merge"
  wasmDisBin = "binaryen/node_modules/binaryen/bin/wasm-dis"
