module PursWasm.CLI.Options
  ( parse
  ) where

import Prelude

import ArgParse.Basic (ArgParser)
import ArgParse.Basic as ArgParser
import Data.Either (Either(..))
import Data.Tuple (Tuple(..))
import PursWasm.CLI.Options.Types (BuildOption, Command(..), GlobalOptions, Platform(..), UlibCheckOption, UlibCompatOption, UlibInstallOption, UlibValidateOption)
import PursWasm.CLI.Version as Version

-- | Read the `--platform` value, rejecting anything outside the three targets.
parsePlatform :: String -> Either String Platform
parsePlatform = case _ of
  "node" -> Right Node
  "browser" -> Right Browser
  "standalone" -> Right Standalone
  other -> Left ("unknown platform '" <> other <> "' (expected: node | browser | standalone)")

-- | The options every command accepts (logging verbosity, …). Defined once and threaded onto each
-- | command by `withGlobals`, so there is no per-command copy.
globalOptionsParser :: ArgParser GlobalOptions
globalOptionsParser =
  ArgParser.fromRecord
    { verbose:
        ArgParser.flag [ "--verbose" ]
          "Print all messages, including debug-level logs."
          # ArgParser.boolean
    }

-- | Pair a command's own parser with the shared global options. ArgParse confines flags to the
-- | subcommand they follow, so the globals must live inside each leaf — but the flag definition
-- | stays in `globalOptionsParser` alone.
withGlobals :: ArgParser Command -> ArgParser (Tuple GlobalOptions Command)
withGlobals command = Tuple <$> globalOptionsParser <*> command

buildOptionsParser :: ArgParser BuildOption
buildOptionsParser =
  ArgParser.fromRecord
    { input:
        ArgParser.argument [ "-I", "--input" ]
          "Path to input directory containing PureScript compiler's artifacts (namely, corefn.json and externs.cbor)\n\
          \Defaults to './output'."
          # ArgParser.default "output"
    , outDir:
        ArgParser.argument [ "-O", "--output" ]
          "The output directory the bundled wasm is placed in.\n\
          \Defaults to './output-wasm'."
          # ArgParser.default "output-wasm"
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
    , platform:
        ArgParser.argument [ "-p", "--platform" ]
          "Deployment target: 'node' or 'browser' (single wasm + JS loader) or\n\
          \'standalone' (self-contained single wasm, no loader). Defaults to 'node'."
          # ArgParser.unformat "PLATFORM" parsePlatform
          # ArgParser.default Node
    , noChunks:
        ArgParser.flag [ "--no-chunks" ]
          "Emit a single wasm instead of code-split chunks (browser only; chunking is not\n\
          \implemented yet, so this is currently the default behaviour for --platform=browser)."
          # ArgParser.boolean
    , noJsFallback:
        ArgParser.flag [ "--no-js-fallback" ]
          "Fail the build instead of falling back to a foreign.js for a foreign import that\n\
          \has no foreign.wat provider (only meaningful for --platform=node|browser)."
          # ArgParser.boolean
    , dumpMir:
        ArgParser.argument [ "--dump-mir" ]
          "Dump how the given module's middle IR (MIR) changes after every optimizer\n\
          \sub-stage (specialize/simplify/impurify) of every round, written to\n\
          \<output>/<MODULE>.mir.txt (debugging; cf. purs-backend-es --trace-rewrites)."
          # ArgParser.optional
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

ulibCompatParser :: ArgParser UlibCompatOption
ulibCompatParser =
  ArgParser.fromRecord
    { check:
        ArgParser.flag [ "--check" ]
          "Verify (offline) that the shadows are still in sync with the pinned package set and\n\
          \that ulib/compat.json's version data is current, instead of regenerating it. A\n\
          \major.minor divergence fails; a patch-only divergence warns."
          # ArgParser.boolean
    }

commandParser :: ArgParser (Tuple GlobalOptions Command)
commandParser =
  ArgParser.choose "command"
    [ ArgParser.command [ "build" ]
        "Build a wasm module from a PureScript project's compiler artifacts"
        (withGlobals (Build <$> buildOptionsParser) <* ArgParser.flagHelp)
    , ArgParser.command [ "ulib" ]
        "Manage the ulib shadow library (ADR 0028)"
        do
          ArgParser.choose "ulib command"
            [ ArgParser.command [ "install" ]
                "Compile the ulib shadows into the lib (corefn + externs)"
                (withGlobals (UlibInstall <$> ulibInstallParser) <* ArgParser.flagHelp)
            , ArgParser.command [ "validate" ]
                "Check each installed shadow's version matches your resolved package set"
                (withGlobals (UlibValidate <$> ulibValidateParser) <* ArgParser.flagHelp)
            , ArgParser.command [ "check" ]
                "Compare each shadow's public interface against your compiled module (externs)"
                (withGlobals (UlibCheck <$> ulibCheckParser) <* ArgParser.flagHelp)
            , ArgParser.command [ "compat" ]
                "Regenerate (or --check) ulib/compat.json: the package-set/version/purs pins (ADR 0029)"
                (withGlobals (UlibCompat <$> ulibCompatParser) <* ArgParser.flagHelp)
            ]
            <* ArgParser.flagHelp
    ]
    <* ArgParser.flagHelp
    <* ArgParser.flagInfo [ "--version", "-v" ] "Show version" Version.versionString

parse :: Array String -> Either ArgParser.ArgError (Tuple GlobalOptions Command)
parse =
  ArgParser.parseArgs "purs-wasm"
    "A PureScript backend for WebAssembly (with GC)"
    commandParser
