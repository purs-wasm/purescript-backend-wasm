module E2E.EffP where

import Prelude
import Effect (Effect, forE)
import Effect.Ref as Ref

-- An EffP-local binding referenced *inside* the cross-module `Ref.modify` lambda. This is
-- what makes `Specialize`'s `Effect.Ref.modify$specN` (placed in Effect.Ref) reference EffP,
-- forming the defining↔consuming dependency cycle that broke `topoOrder` (regression #2).
step :: Int -> Int
step n = n + 1

-- #1: `void` must NOT drop the wrapped effect (modify runs → cell = 5).
voidTest :: Effect Int
voidTest = do
  acc <- Ref.new 0
  void (Ref.modify (\s -> s + 5) acc)
  Ref.read acc

-- #2: forE + cross-module `Ref.modify (\s -> step (step s))` (lambda references EffP.step →
-- the spec cycle). Each of 5 iterations adds 2 → cell = 10.
forETest :: Effect Int
forETest = do
  acc <- Ref.new 0
  forE 0 5 \_ -> void (Ref.modify (\s -> step (step s)) acc)
  Ref.read acc
