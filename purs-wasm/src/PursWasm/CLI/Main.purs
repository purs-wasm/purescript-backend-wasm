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
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Class.Console as Console
import Node.Path (FilePath)
import Node.Process as Process
import PursWasm.CLI.Build (buildCmd)
import PureScript.Backend.Wasm.CLI.Node (runNode)
import PursWasm.CLI.Options (parse)
import PursWasm.CLI.Options.Types (Command(..))

-- The JS entry passes two roots (it resolves them per environment): `cliRoot` locates the bundled
-- assets (`<cliRoot>/runtime`, `<cliRoot>/lib`), and `binaryenBinDir` the `wasm-merge`/`wasm-dis`
-- binaries (`<repo>/binaryen/node_modules/binaryen/bin` in dev, `require.resolve('binaryen')` in the
-- published package). Keeping the resolution in JS keeps the wasm self-locating without an FFI.
main :: FilePath -> FilePath -> Effect Unit
main cliRoot binaryenBinDir = do
  cliArgs <- Array.drop 2 <$> Process.argv

  case parse cliArgs of
    Left err -> Console.error (ArgParser.printArgError err)
    Right (Tuple globals cmd) -> runNode globals $ case cmd of
      Build args -> buildCmd cliRoot binaryenBinDir args