-- | CLI-driven e2e (ADR 0031 phase 5) of the function instances (the Reader idiom): `Functor`/`Apply`/
-- | `Applicative`/`Bind`/`Monad` over `(->) r`, plus `Category`/`Semigroupoid`. Built standalone by
-- | the real `purs-wasm build`. (Migrated from the legacy corefn-fixture `Test.E2E.PreludeFnInstance`.)
module Test.E2E.Cli.PreludeFnInstance (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x1, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Function instances / Reader (e2e/cli): Functor..Monad on (->) r -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.FnInst"))
    $ do
        it "Functor: map = composition  ((x*2)+1)" \inst -> do
          r <- liftEffect (callI32x1 inst "fnMap" 3)
          r `shouldEqual` 7

        it "Apply: apply f g x = f x (g x)  (x + x*10 = 11x)" \inst -> do
          r <- liftEffect (callI32x1 inst "fnApply" 3)
          r `shouldEqual` 33

        it "Applicative: pure = const  (42)" \inst -> do
          r <- liftEffect (callI32x1 inst "fnPure" 3)
          r `shouldEqual` 42

        it "Bind: bind m f x = f (m x) x  (2x + x = 3x)" \inst -> do
          r <- liftEffect (callI32x1 inst "fnBind" 3)
          r `shouldEqual` 9

        it "Monad do-notation over functions / Reader  ((x+1)+(x*2) = 3x+1)" \inst -> do
          r <- liftEffect (callI32x1 inst "fnDo" 3)
          r `shouldEqual` 10

        it "Category identity and Semigroupoid >>> on functions" \inst -> do
          i <- liftEffect (callI32x1 inst "fnId" 3)
          c <- liftEffect (callI32x1 inst "fnCompose" 3)
          [ i, c ] `shouldEqual` [ 3, 8 ]
