-- | The Node entry point for the `purwc` worker (ADR 0038): read `argv`, parse it via the
-- | platform-neutral `Purwc.CLI.Options`, and run the chosen command against the shared synchronous
-- | Node interpreter (`cli-lib`'s `runNode`). Mirrors `PursWasm.CLI.Main`.
module Purwc.CLI.Main
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
import Purwc.CLI.Batch (batchCmd)
import Purwc.CLI.Compile (compileCmd)
import Purwc.CLI.Options (parse)
import Purwc.CLI.Options.Types (Command(..))

-- The JS entry passes `cliRoot` (locates `<cliRoot>/runtime`/`lib`) and `binaryenBinDir` (the
-- `wasm-dis` binary), resolved per environment — the same convention as `purs-wasm`.
main :: FilePath -> FilePath -> Effect Unit
main cliRoot binaryenBinDir = do
  cliArgs <- Array.drop 2 <$> Process.argv
  case parse cliArgs of
    Left err -> Console.error (ArgParser.printArgError err)
    Right (Tuple globals cmd) -> runNode globals $ case cmd of
      Compile args -> compileCmd cliRoot binaryenBinDir args
      Batch args -> batchCmd cliRoot binaryenBinDir args
