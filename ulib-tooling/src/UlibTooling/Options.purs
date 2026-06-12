-- | The maintainer CLI's option types + argument parser (ADR 0031 §5): the `install` / `check` /
-- | `compat` subcommands. The shared global options (`--verbose`) and `withGlobals` are reused from
-- | the `purs-wasm` package, so logging behaves identically across the two binaries.
module UlibTooling.Options
  ( UlibInstallOption
  , UlibCheckOption
  , UlibCompatOption
  , Command(..)
  , parse
  ) where

import Prelude

import ArgParse.Basic (ArgParser)
import ArgParse.Basic as ArgParser
import Data.Either (Either)
import Data.Maybe (Maybe)
import Data.Tuple (Tuple)
import PursWasm.CLI.Effect (FilePath)
import PursWasm.CLI.Options (withGlobals)
import PursWasm.CLI.Options.Types (GlobalOptions)
import PursWasm.CLI.Version as Version

type UlibInstallOption =
  { libPath :: Maybe FilePath
  , purs :: Maybe FilePath
  , force :: Boolean
  }

type UlibCheckOption =
  { libPath :: Maybe FilePath
  , input :: Maybe FilePath
  }

-- | `compat`: regenerate `ulib/compat.json` (default); `--check` verifies it instead; `--dry`
-- | prints the regenerated JSON to stdout without writing the file (ADR 0029).
type UlibCompatOption =
  { check :: Boolean
  , dry :: Boolean
  }

data Command
  = Install UlibInstallOption
  | Check UlibCheckOption
  | Compat UlibCompatOption

ulibInstallParser :: ArgParser UlibInstallOption
ulibInstallParser =
  ArgParser.fromRecord
    { libPath:
        ArgParser.argument [ "-L", "--lib-path" ]
          "Where to store the compiled ulib corefn/externs.\n\
          \Defaults to $PURS_WASM_LIB, else the `lib` dir beside the CLI (`<cli>/lib`)."
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

ulibCheckParser :: ArgParser UlibCheckOption
ulibCheckParser =
  ArgParser.fromRecord
    { libPath:
        ArgParser.argument [ "-L", "--lib-path" ]
          "The installed ulib to check. Defaults to $PURS_WASM_LIB, else `<cli>/lib`."
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
    , dry:
        ArgParser.flag [ "--dry" ]
          "Print the regenerated compat.json to stdout instead of writing the file (only the JSON,\n\
          \so it pipes cleanly). Ignored when --check is given."
          # ArgParser.boolean
    }

commandParser :: ArgParser (Tuple GlobalOptions Command)
commandParser =
  ArgParser.choose "command"
    [ ArgParser.command [ "install" ]
        "Compile the ulib shadows into the lib (corefn + externs)"
        (withGlobals (Install <$> ulibInstallParser) <* ArgParser.flagHelp)
    , ArgParser.command [ "check" ]
        "Compare each shadow's public interface against your compiled module (externs)"
        (withGlobals (Check <$> ulibCheckParser) <* ArgParser.flagHelp)
    , ArgParser.command [ "compat" ]
        "Regenerate (or --check) ulib/compat.json: the package-set/version/purs pins (ADR 0029)"
        (withGlobals (Compat <$> ulibCompatParser) <* ArgParser.flagHelp)
    ]
    <* ArgParser.flagHelp
    <* ArgParser.flagInfo [ "--version", "-v" ] "Show version" Version.versionString

parse :: Array String -> Either ArgParser.ArgError (Tuple GlobalOptions Command)
parse =
  ArgParser.parseArgs "ulib-tooling"
    "Maintainer tooling for the purs-wasm ulib library"
    commandParser
