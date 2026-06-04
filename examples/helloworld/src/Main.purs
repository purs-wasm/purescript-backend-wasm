module Examples.HelloWorld.Main where

import Prelude

import Effect (Effect)
import Effect.Console as Console

sub :: Effect Unit
sub = Console.log "This should not be printed"

main :: Effect Unit
main = do
  Console.log "Hello from WASM World!"
