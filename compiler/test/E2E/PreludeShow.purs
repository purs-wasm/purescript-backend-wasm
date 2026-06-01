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
                , "compiler/test/fixtures/Data.Semigroup.corefn.json"
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

        it "shows Chars: plain, escaped ' and \\, named control, and UTF-8" \inst -> do
          a <- liftEffect (callI32x0 inst "showCharA")
          q <- liftEffect (callI32x0 inst "showCharQuote")
          bs <- liftEffect (callI32x0 inst "showCharBackslash")
          nl <- liftEffect (callI32x0 inst "showCharNewline")
          u <- liftEffect (callI32x0 inst "showCharUnicode")
          [ a, q, bs, nl, u ] `shouldEqual` [ 1, 1, 1, 1, 1 ]

        it "shows Strings: plain, escaped \" and \\, named control" \inst -> do
          hi <- liftEffect (callI32x0 inst "showStrHi")
          esc <- liftEffect (callI32x0 inst "showStrEsc")
          nl <- liftEffect (callI32x0 inst "showStrNewline")
          [ hi, esc, nl ] `shouldEqual` [ 1, 1, 1 ]

        it "inserts the \\& separator when a \\DDD escape is followed by a digit" \inst -> do
          amp <- liftEffect (callI32x0 inst "showStrAmp")
          amp `shouldEqual` 1

        it "shows Arrays by joining element shows (Int, empty, String)" \inst -> do
          ints <- liftEffect (callI32x0 inst "showArrInts")
          empty <- liftEffect (callI32x0 inst "showArrEmpty")
          strs <- liftEffect (callI32x0 inst "showArrStr")
          [ ints, empty, strs ] `shouldEqual` [ 1, 1, 1 ]

        it "round-trips emoji Strings (BMP + 4-byte astral + ZWJ) and a BMP Char" \inst -> do
          smiley <- liftEffect (callI32x0 inst "showEmojiSmiley")
          family <- liftEffect (callI32x0 inst "showEmojiFamily")
          bmp <- liftEffect (callI32x0 inst "showBmpChar")
          [ smiley, family, bmp ] `shouldEqual` [ 1, 1, 1 ]
