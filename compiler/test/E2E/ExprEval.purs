-- | End-to-end **integration** test: a small arithmetic-expression evaluator and
-- | pretty-printer (`Expr.purs.sample`, mirroring `example/src/Main.purs`). It
-- | exercises, together in one module, the features added across the recent work —
-- | ADTs, nested decision-tree pattern matching, a **case guard** (the pattern
-- | guard `Neg y' <- y` purs desugars to a nested case, leaving the trailing
-- | `| otherwise`), recursion, `show`, string `<>`, and real Prelude `negate` /
-- | `+` / `*` / `>`.
-- |
-- | The export ABI is i32-only, so the fixture exposes nullary `Int` entry points:
-- | `eval*` return the evaluated number and `print*` compare `printExpr`'s output
-- | against the expected rendering inside wasm (1 = exact match).
module Test.E2E.ExprEval (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x0, instantiateLinked)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Expr evaluator/printer (e2e): ADTs + guards + show + <> -> wasm -> run"
    $ before
        ( liftEffect
            ( instantiateLinked [ [ "Expr" ] ]
                [ "compiler/test/fixtures/Expr.corefn.json"
                , "compiler/test/fixtures/Data.Boolean.corefn.json"
                , "compiler/test/fixtures/Data.Eq.corefn.json"
                , "compiler/test/fixtures/Data.Ord.corefn.json"
                , "compiler/test/fixtures/Data.Ordering.corefn.json"
                , "compiler/test/fixtures/Data.Ring.corefn.json"
                , "compiler/test/fixtures/Data.Semigroup.corefn.json"
                , "compiler/test/fixtures/Data.Semiring.corefn.json"
                , "compiler/test/fixtures/Data.Show.corefn.json"
                ]
            )
        )
    $ do
        -- eval ex1 = 1 + 2 * (-3) = -5 ; eval ex2 = 3*5 - 2 + 4*(2+3) = 33
        it "evaluates nested arithmetic with negation" \inst -> do
          e1 <- liftEffect (callI32x0 inst "eval1")
          e2 <- liftEffect (callI32x0 inst "eval2")
          [ e1, e2 ] `shouldEqual` [ -5, 33 ]

        -- printExpr renders with precedence-aware parentheses and `x - y` for `x + Neg y`
        it "pretty-prints with the guarded subtraction rule and precedence parens" \inst -> do
          p1 <- liftEffect (callI32x0 inst "print1") -- "1 + 2 * -3"
          p2 <- liftEffect (callI32x0 inst "print2") -- "3 * 5 - 2 + 4 * (2 + 3)"
          [ p1, p2 ] `shouldEqual` [ 1, 1 ]
