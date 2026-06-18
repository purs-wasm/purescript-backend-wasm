module Purwc where

import Prelude

import Effect (Effect)
import Effect.Console as Console
import Fmt as Fmt
import PureScript.Backend.Wasm.CLI (FilePath)

main :: FilePath -> FilePath -> Effect Unit
main cliRoot binaryenBinDir = do
  Console.log "purwc - A WebAssembly Compiler for PureScript"
  Console.log ""
  Console.log $ Fmt.fmt @"cliRoot\t= {cliRoot}" { cliRoot }
  Console.log $ Fmt.fmt @"binaryenBinDir\t= {binaryenBinDir}" { binaryenBinDir }