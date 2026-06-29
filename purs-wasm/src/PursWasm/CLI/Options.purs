module PursWasm.CLI.Options
  ( parse
  ) where

import Prelude

import ArgParse.Basic (ArgParser)
import ArgParse.Basic as ArgParser
import Data.Either (Either(..))
import Data.Tuple (Tuple)
import PureScript.Backend.Wasm.CLI.Options (withGlobals)
import PureScript.Backend.Wasm.CLI.Options.Types (GlobalOptions)
import PursWasm.CLI.Options.Types (BuildOption, Command(..), Platform(..), PrewarmOption)
import PursWasm.CLI.Version as Version

-- | Read the `--platform` value, rejecting anything outside the three targets.
parsePlatform :: String -> Either String Platform
parsePlatform = case _ of
  "node" -> Right Node
  "browser" -> Right Browser
  "standalone" -> Right Standalone
  other -> Left ("unknown platform '" <> other <> "' (expected: node | browser | standalone)")

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
    , executable:
        ArgParser.flag [ "-E", "--executable" ]
          "Produce a runnable that executes the entry module's `main` (which must be\n\
          \`main :: Effect Unit`): the JS loader calls it on load. Requires --platform=node\n\
          \or browser (not valid with standalone)."
          # ArgParser.boolean
    , force:
        ArgParser.flag [ "-f", "--force" ]
          "Ignore the incremental cache under <output>/_build (rebuild every module from\n\
          \scratch) and refresh it. By default a build reuses unchanged modules from the cache."
          # ArgParser.boolean
    , perModuleCodegen:
        ArgParser.flag [ "--per-module-codegen" ]
          "Use the per-module lower+codegen core instead of the whole-program one.\n\
          \Experimental; differential-tested against the default for behaviour parity.\n\
          \The per-module engine moves to the standalone `purwc` later."
          # ArgParser.boolean
    , legacy:
        ArgParser.flag [ "--legacy" ]
          "Use the legacy whole-program build (compile every module in-process and link with\n\
          \`finishLink`) instead of the DEFAULT orchestrate build (the standalone `purwc` worker\n\
          \driven as a subprocess against the content-addressed store, ADR 0038/0040/0042)."
          # ArgParser.boolean
    , dumpMir:
        ArgParser.argument [ "--dump-mir" ]
          "Dump the given module's middle IR (MIR) at the optimizer's snapshot points\n\
          \(specialized input, per-module optimized, post-inline specialization), written\n\
          \to <output>/<MODULE>.mir.txt (debugging; cf. purs-backend-es --trace-rewrites)."
          # ArgParser.optional
    }

prewarmOptionsParser :: ArgParser PrewarmOption
prewarmOptionsParser =
  ArgParser.fromRecord
    { input:
        ArgParser.argument [ "-I", "--input" ]
          "Path to the package set's PureScript compiler artifacts (corefn.json/externs.cbor closure).\n\
          \Defaults to './output'."
          # ArgParser.default "output"
    }

commandParser :: ArgParser (Tuple GlobalOptions Command)
commandParser =
  ArgParser.choose "command"
    [ ArgParser.command [ "build" ]
        "Build a wasm module from a PureScript project's compiler artifacts"
        (withGlobals (Build <$> buildOptionsParser) <* ArgParser.flagHelp)
    , ArgParser.command [ "prewarm" ]
        "Precompile a package set's whole closure into $PURS_WASM_STORE for cross-project reuse"
        (withGlobals (Prewarm <$> prewarmOptionsParser) <* ArgParser.flagHelp)
    ]
    <* ArgParser.flagHelp
    <* ArgParser.flagInfo [ "--version", "-v" ] "Show version" Version.versionString

parse :: Array String -> Either ArgParser.ArgError (Tuple GlobalOptions Command)
parse =
  ArgParser.parseArgs "purs-wasm"
    "A PureScript backend for WebAssembly (with GC)"
    commandParser
