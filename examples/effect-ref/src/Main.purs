module Examples.EffRef.Main where

import Prelude

import Effect (Effect)
import Effect.Console as Console
import Effect.Ref as Ref

main :: Effect Unit
main = do
  r <- Ref.new 0
  Ref.write 1 r
  whenM (Ref.read r <#> (_ >= 0)) do
    Console.log "The ref is non-negative!"
  Ref.modify_ (_ * 2) r
  Ref.read r >>= \v -> Console.log ("The final result is " <> show v)