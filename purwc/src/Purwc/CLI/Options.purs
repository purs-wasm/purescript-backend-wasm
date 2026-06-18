-- | Argument parsing for `purwc` (ADR 0038). One `compile` subcommand; the global options come from
-- | the shared `cli-lib` parser (`withGlobals`).
module Purwc.CLI.Options
  ( parse
  ) where

import Prelude

import ArgParse.Basic (ArgParser)
import ArgParse.Basic as ArgParser
import Data.Either (Either)
import Data.Tuple (Tuple)
import PureScript.Backend.Wasm.CLI.Options (withGlobals)
import PureScript.Backend.Wasm.CLI.Options.Types (GlobalOptions)
import Purwc.CLI.Options.Types (Command(..), CompileOption)
import Purwc.CLI.Version as Version

compileOptionsParser :: ArgParser CompileOption
compileOptionsParser =
  ArgParser.fromRecord
    { entryModule:
        ArgParser.argument [ "-e", "--module" ]
          "The dotted name of the single module to compile (e.g. Data.Maybe)."
    , input:
        ArgParser.argument [ "-I", "--input" ]
          "Directory of the module's compiler artifacts (<Module>/corefn.json + externs.cbor).\n\
          \Defaults to './output'."
          # ArgParser.default "output"
    , depsDir:
        ArgParser.argument [ "--deps" ]
          "Directory of the module's dependencies' .pmi/.pmo artifacts. Defaults to the\n\
          \output directory. (Unused until dependency-aware compilation lands; ADR 0038 M2.)"
          # ArgParser.default ""
    , outDir:
        ArgParser.argument [ "-O", "--output" ]
          "Directory the module's .pmi/.pmo/.wasm (and .wat) are written to.\n\
          \Defaults to './output-purwc'."
          # ArgParser.default "output-purwc"
    , text:
        ArgParser.flag [ "-t", "--text" ]
          "Also emit the WebAssembly text format (.wat) alongside the .wasm."
          # ArgParser.boolean
    , noOpt:
        ArgParser.flag [ "--no-opt" ]
          "Skip the middle-end optimization (dictionary elimination); lambda lifting still runs."
          # ArgParser.boolean
    , debug:
        ArgParser.flag [ "-g", "--debug" ]
          "Debug build: skip the Binaryen optimizer (keeps the wasm close to the emitted IR)."
          # ArgParser.boolean
    }

commandParser :: ArgParser (Tuple GlobalOptions Command)
commandParser =
  ArgParser.choose "command"
    [ ArgParser.command [ "compile" ]
        "Compile a single module to its .pmi/.pmo/.wasm artifacts"
        (withGlobals (Compile <$> compileOptionsParser) <* ArgParser.flagHelp)
    ]
    <* ArgParser.flagHelp
    <* ArgParser.flagInfo [ "--version", "-v" ] "Show version" Version.versionString

parse :: Array String -> Either ArgParser.ArgError (Tuple GlobalOptions Command)
parse =
  ArgParser.parseArgs "purwc"
    "A single-module WebAssembly compiler for PureScript (the ADR 0038 worker)"
    commandParser
