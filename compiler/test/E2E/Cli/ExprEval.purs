-- | CLI-driven e2e (ADR 0031 phase 5) of a small expression interpreter: `eval` over nested
-- | arithmetic with negation, and `printExpr` with precedence-aware parentheses and the `x - y` rule
-- | for `x + Neg y`. Built standalone by the real `purs-wasm build`. (Migrated from the legacy
-- | corefn-fixture `Test.E2E.ExprEval`.)
module Test.E2E.Cli.ExprEval (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x0, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Expression interpreter (e2e/cli): eval + pretty-print -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Expr"))
    $ do
        it "evaluates nested arithmetic with negation" \inst -> do
          e1 <- liftEffect (callI32x0 inst "eval1")
          e2 <- liftEffect (callI32x0 inst "eval2")
          [ e1, e2 ] `shouldEqual` [ -5, 33 ]

        it "pretty-prints with the guarded subtraction rule and precedence parens" \inst -> do
          p1 <- liftEffect (callI32x0 inst "print1")
          p2 <- liftEffect (callI32x0 inst "print2")
          [ p1, p2 ] `shouldEqual` [ 1, 1 ]
