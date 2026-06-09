-- | The **Node** entry point: the one place that is allowed to depend on platform-native effects.
-- | It reads `argv` (Node), parses it via the platform-neutral `PursWasm.CLI.Options`, and runs the
-- | resulting command against the synchronous Node interpreter (`runNode`). A future WASI port adds
-- | its own `Main` (PureScript has no `#ifdef`, so the per-platform entry is a separate module);
-- | everything below `Main` stays platform-neutral.
module PursWasm.CLI.Main
  ( main
  ) where

import Prelude

import ArgParse.Basic as ArgParser
import Data.Array as Array
import Data.Either (Either(..))
import Effect (Effect)
import Effect.Class.Console as Console
import Node.Path (FilePath)
import Node.Process as Process
import PursWasm.CLI.Build (buildCmd)
import PursWasm.CLI.Node (runNode)
import PursWasm.CLI.Options (parse)
import PursWasm.CLI.Options.Types (Command(..))

-- `cliRoot` is the entry's directory (passed by
-- `index.dev.js`), used to locate `<cliRoot>/../lib`
main :: FilePath -> Effect Unit
main cliRoot = do
  cliArgs <- Array.drop 2 <$> Process.argv
  case parse cliArgs of
    Left err -> Console.error (ArgParser.printArgError err)
    Right (Build args) -> runNode (buildCmd cliRoot args)
