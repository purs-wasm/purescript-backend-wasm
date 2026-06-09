-- | Entry point for the `purs-wasm` CLI. During the re-architecture this is a stub; it will
-- | grow into the thin dispatch over `PursWasm.CLI.Options.parseArgs` once the command modules
-- | land (see the plan). `cliRoot` is the CLI entry's directory (passed by `index.dev.js`), used
-- | to locate `<cliRoot>/../lib`, `<cliRoot>/../ulib`, and `<cliRoot>/ulib-install.sh`.
module PursWasm.CLI.Main where

import Prelude

import Effect (Effect)
import Effect.Class.Console as Console
import Node.Path (FilePath)
import PursWasm.CLI.Version as Version

main :: FilePath -> Effect Unit
main _cliRoot = Console.log (Version.versionString <> " — scaffold (no commands wired yet)")
