module Main where

import Prelude

import ArgParse.Basic (ArgParser)
import ArgParse.Basic as ArgParser
import Data.Array as Array
import Data.Either (Either(..))
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
import PureScript.Backend.Wasm.Compiler (compileModules, compileModulesText, parseModule)
import PureScript.CoreFn (ModuleName, toModuleName)
import Unsafe.Coerce (unsafeCoerce)
import Version as Version

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
  let mods = Array.sort (Array.mapMaybe toModuleName entries)
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
  if args.text then
    liftEffect (compileModulesText opts roots modules) >>= case _ of
      Left err -> throwError (error err)
      Right wat -> writeArtifact (Path.concat [ bundleDir, "index.wat" ]) (\f -> FS.writeTextFile UTF8 f wat)
  else
    liftEffect (compileModules opts roots modules) >>= case _ of
      Left err -> throwError (error err)
      Right bytes -> writeArtifact (Path.concat [ bundleDir, "index.wasm" ]) (\f -> FS.writeFile f (unsafeCoerce bytes))
  where
  writeArtifact :: FilePath -> (FilePath -> Aff Unit) -> Aff Unit
  writeArtifact outFile write = do
    write outFile
    Console.log (Fmt.fmt @"Wrote {file}" { file: outFile })
