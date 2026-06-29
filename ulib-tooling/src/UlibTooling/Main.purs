-- | The Node entry point for the maintainer CLI (ADR 0031 §5): parse `argv` via `UlibTooling.Options`
-- | and run the chosen subcommand (`install` / `check` / `compat`) against the shared synchronous Node
-- | interpreter (`PureScript.Backend.Wasm.CLI.Node.runNode`). Mirrors `PursWasm.CLI.Main`, but for the maintainer
-- | surface — kept out of the lean user `purs-wasm` binary.
module UlibTooling.Main
  ( main
  ) where

import Prelude

import ArgParse.Basic as ArgParser
import Data.Array as Array
import Data.Either (Either(..))
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Class.Console as Console
import Node.Path (FilePath)
import Node.Process as Process
import PureScript.Backend.Wasm.CLI.Node (runNode)
import UlibTooling.Commands (ulibCheckCmd, ulibInstallCmd)
import UlibTooling.Compat (ulibCompatCmd)
import UlibTooling.Options (Command(..), parse)

-- The JS entry passes `cliRoot` (the repo root, where the `ulib` source + the installed `lib` live;
-- WasmBase is now a resolved `wasm-base` package, not a local dir) and `binaryenBinDir` (the `wasm-as`
-- location) — the maintainer tool runs from the monorepo only, but shares the asset-resolution
-- convention with the user `purs-wasm` CLI.
main :: FilePath -> FilePath -> Effect Unit
main cliRoot binaryenBinDir = do
  cliArgs <- Array.drop 2 <$> Process.argv
  case parse cliArgs of
    Left err -> Console.error (ArgParser.printArgError err)
    Right (Tuple globals cmd) -> runNode globals $ case cmd of
      Install args -> ulibInstallCmd cliRoot binaryenBinDir args
      Check args -> ulibCheckCmd cliRoot args
      Compat args -> ulibCompatCmd args
