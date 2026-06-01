-- | End-to-end test of real `Prelude` **Boolean algebra** (`HeytingAlgebra`):
-- | `&&` / `||` / `not` go through the `conj` / `disj` / `not` method accessors and
-- | the `heytingAlgebraBoolean` dictionary, whose fields are the `boolConj` /
-- | `boolDisj` / `boolNot` foreigns — `i32.and` / `i32.or` / `i32.eqz` on the
-- | unboxed `i31` Boolean bits. `Bool` is linked with `Data.Eq` (for `==`, which
-- | produces the Booleans) and `Data.HeytingAlgebra` (ADR 0009).
module Test.E2E.PreludeBool (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x1, callI32x2, callI32x3, instantiateLinked)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Prelude Boolean algebra (e2e): && || not via dictionaries -> wasm -> run"
    $ before
        ( liftEffect
            ( instantiateLinked [ [ "Bool" ] ]
                [ "compiler/test/fixtures/Bool.corefn.json"
                , "compiler/test/fixtures/Data.Eq.corefn.json"
                , "compiler/test/fixtures/Data.HeytingAlgebra.corefn.json"
                ]
            )
        )
    $ do
        -- conjf a b c = if (a == b) && (b == c) then 1 else 0
        it "conjuncts two Booleans with &&" \inst -> do
          yes <- liftEffect (callI32x3 inst "conjf" 5 5 5)
          no <- liftEffect (callI32x3 inst "conjf" 5 5 6)
          [ yes, no ] `shouldEqual` [ 1, 0 ]

        -- disjf a b = if (a == 0) || (b == 0) then 1 else 0
        it "disjuncts two Booleans with ||" \inst -> do
          l <- liftEffect (callI32x2 inst "disjf" 0 9)
          r <- liftEffect (callI32x2 inst "disjf" 9 0)
          n <- liftEffect (callI32x2 inst "disjf" 9 9)
          [ l, r, n ] `shouldEqual` [ 1, 1, 0 ]

        -- negf a = if not (a == 0) then 1 else 0
        it "negates a Boolean with not" \inst -> do
          t <- liftEffect (callI32x1 inst "negf" 3)
          f <- liftEffect (callI32x1 inst "negf" 0)
          [ t, f ] `shouldEqual` [ 1, 0 ]
