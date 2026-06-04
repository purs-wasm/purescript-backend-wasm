module Examples.EffRandom.Main where

import Prelude

import Effect (Effect)
import Effect.Console as Console
import Effect.Random (random)

main :: Effect Unit
main = do
  n <- random
  Console.log $ "I got " <> show n
