-- | CLI-driven e2e (ADR 0031 phase 5) of `Show`: `Int` (incl. `INT_MIN`), `Boolean`, `Char` (plain /
-- | escaped / named-control / UTF-8), `String` (escapes + `\&` separator), `Array`, emoji (BMP / astral
-- | / ZWJ), and `Number` — exercising the ulib `Data.Show` shadow (and its `showNumberImpl` foreign)
-- | through the real `purs-wasm build`. (Migrated from the legacy corefn-fixture `Test.E2E.PreludeShow`;
-- | `compiler/test/showNumber.mjs` remains the exhaustive Number oracle.)
module Test.E2E.Cli.PreludeShow (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Cli.Harness (callI32x0, callI32x1, cliFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Show (e2e/cli): Int/Bool/Char/String/Array/emoji/Number -> purs-wasm build -> run"
    $ before (liftEffect (cliFixture "E2E.Shw"))
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

        it "shows Numbers: 0.0, fraction, integer, and exponential forms" \inst -> do
          z <- liftEffect (callI32x0 inst "showNumZero")
          f <- liftEffect (callI32x0 inst "showNumFrac")
          i <- liftEffect (callI32x0 inst "showNumInt")
          eb <- liftEffect (callI32x0 inst "showNumExpBig")
          es <- liftEffect (callI32x0 inst "showNumExpSmall")
          [ z, f, i, eb, es ] `shouldEqual` [ 1, 1, 1, 1, 1 ]
