-- Regression fixture for the ulib `Data.Show` shadow (ADR 0028 / 0030): showIntImpl/showCharImpl/
-- showStringImpl/showArrayImpl are reimplemented in PureScript over `Wasm.String`/`Wasm.Char`/
-- `Wasm.Array`; showNumberImpl is kept foreign (the wat provides the float→string). `ulib check`
-- guards the interface; this guards the runtime semantics (escaping, decimal rendering, the kept
-- foreign path). Driven by `compiler/test/showShadow.mjs`.
-- |
-- `check n` returns a 16-bit pass mask (65535 = all pass), one bit per case. Covers 1/2/3-byte code
-- points, escapes, negative / min Int, arrays, a record, the foreign Number path, and Bool/Unit.
module Examples.HelloWorld.ShowShadowCheck where

import Prelude

check :: Int -> Int
check _ =
  bit 0 (show (42 :: Int) == "42")
    + bit 1 (show (-7 :: Int) == "-7")
    + bit 2 (show (bottom :: Int) == "-2147483648")
    + bit 3 (show 'a' == "'a'")
    + bit 4 (show '\n' == "'\\n'")
    + bit 5 (show '☺' == "'☺'")
    + bit 6 (show '\'' == "'\\''")
    + bit 7 (show "hi" == "\"hi\"")
    + bit 8 (show "a\nb" == "\"a\\nb\"")
    + bit 9 (show "a\"b" == "\"a\\\"b\"")
    + bit 10 (show "aé☺" == "\"aé☺\"")
    + bit 11 (show [ 1, 2, 3 ] == "[1,2,3]")
    + bit 12 (show ([ "a", "b" ] :: Array String) == "[\"a\",\"b\"]")
    + bit 13 (show { x: 1 } == "{ x: 1 }")
    + bit 14 (show (3.14 :: Number) == "3.14")
    + bit 15 (show true == "true" && show unit == "unit")
  where
  bit n b = if b then pow2 n else 0
  pow2 n = if n == 0 then 1 else 2 * pow2 (n - 1)
