-- | End-to-end test of real `Prelude` **`Data.Show`** for `Int` and `Boolean`.
-- | `show` on `Int` (`showIntImpl`) lowers to the new `$rt.showInt` runtime helper:
-- | it writes the base-10 digits into an 11-byte scratch buffer from the right
-- | (extracting each digit with `rem_s` / `div_s`, taking the `abs` of the
-- | remainder so `INT_MIN` is never negated as a whole and never overflows), then
-- | copies the used suffix into the result `$Str`. `show` on `Boolean` is a pure
-- | `case` in `Data.Show` (no foreign) returning the `"true"` / `"false"` literals.
-- | Each result is checked by string equality (`eqStringImpl` → `$rt.strEq`); `Shw`
-- | is linked with `Data.Show` and `Data.Eq` (ADR 0009). (`Number` / `Char` /
-- | `String` / `Array` `show` are not wired up yet — `Number` awaits a shortest
-- | round-trip float renderer.)
module Test.E2E.PreludeShow (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x0, callI32x1, instantiateLinked)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Prelude Show (e2e): Int / Boolean -> wasm -> run"
    $ before
        ( liftEffect
            ( instantiateLinked [ [ "Shw" ] ]
                [ "compiler/test/fixtures/Shw.corefn.json"
                , "compiler/test/fixtures/Data.Show.corefn.json"
                , "compiler/test/fixtures/Data.Eq.corefn.json"
                ]
            )
        )
    $ do
        it "shows non-negative Ints (0, 42)" \inst -> do
          z <- liftEffect (callI32x0 inst "showZero")
          p <- liftEffect (callI32x0 inst "showPos")
          [ z, p ] `shouldEqual` [ 1, 1 ]

        it "shows negative Ints, including INT_MIN (no overflow on negation)" \inst -> do
          neg <- liftEffect (callI32x1 inst "showNegArg" (-7))
          mn <- liftEffect (callI32x1 inst "showMinArg" (-2147483648))
          [ neg, mn ] `shouldEqual` [ 1, 1 ]

        it "shows Booleans (\"true\" / \"false\")" \inst -> do
          t <- liftEffect (callI32x0 inst "showBoolT")
          f <- liftEffect (callI32x0 inst "showBoolF")
          [ t, f ] `shouldEqual` [ 1, 1 ]
