-- Regression fixture for the ulib `Data.String.CodeUnits` / `Data.String.Common` shadows (ADR 0028
-- / 0030): the registry modules' UTF-16 JS foreigns are reimplemented in PureScript over
-- `Wasm.String` with **code-point** semantics over the UTF-8 `$Str`. `ulib check` guards the
-- interface; this guards the runtime semantics of the hand-written UTF-8 codecs across 1/2/3-byte
-- code points. Driven by `compiler/test/stringShadow.mjs`.
-- |
-- `check n` returns a 24-bit pass mask (16777215 = all pass), one bit per operation. The test
-- string `"aé☺b"` mixes a 1-byte ('a'/'b'), a 2-byte ('é' = U+00E9) and a 3-byte ('☺' = U+263A)
-- code point, so a byte-vs-code-point confusion in any operation flips its bit.
module Examples.HelloWorld.StringShadowCheck where

import Prelude

import Data.Maybe (Maybe(..))
import Data.String.Common as C
import Data.String.CodeUnits as S
import Data.String.Pattern (Pattern(..), Replacement(..))

check :: Int -> Int
check _ =
  -- Data.String.CodeUnits (bits 0-15)
  bit 0 (S.length s == 4)
    + bit 1 (S.take 2 s == "aé")
    + bit 2 (S.drop 2 s == "☺b")
    + bit 3 (S.charAt 2 s == Just '☺')
    + bit 4 (S.charAt 4 s == Nothing)
    + bit 5 (S.toCharArray s == [ 'a', 'é', '☺', 'b' ])
    + bit 6 (S.fromCharArray [ 'a', 'é', '☺', 'b' ] == s)
    + bit 7 (S.singleton '☺' == "☺")
    + bit 8 (S.splitAt 2 s == { before: "aé", after: "☺b" })
    + bit 9 (S.slice 1 3 s == "é☺")
    + bit 10 (S.indexOf (Pattern "☺") s == Just 2)
    + bit 11 (S.lastIndexOf (Pattern "é") "éaé" == Just 2)
    + bit 12 (S.countPrefix (_ /= '☺') s == 2)
    + bit 13 (S.stripPrefix (Pattern "aé") s == Just "☺b")
    + bit 14 (S.uncons s == Just { head: 'a', tail: "é☺b" })
    + bit 15 (S.toChar "☺" == Just '☺' && S.toChar "aé" == Nothing)
    -- Data.String.Common (bits 16-23)
    + bit 16 (C.split (Pattern ",") "a,b,c" == [ "a", "b", "c" ])
    + bit 17 (C.split (Pattern "") "aé☺" == [ "a", "é", "☺" ])
    + bit 18 (C.joinWith ", " [ "a", "é", "☺" ] == "a, é, ☺")
    + bit 19 (C.replace (Pattern "é") (Replacement "X") "aéaé" == "aXaé")
    + bit 20 (C.replaceAll (Pattern "é") (Replacement "X") "aéaé" == "aXaX")
    + bit 21 (C.trim "  aé  " == "aé")
    + bit 22 (C.null "" && not (C.null "a"))
    + bit 23 (C.split (Pattern "☺") "a☺b☺c" == [ "a", "b", "c" ])
  where
  s = "aé☺b"
  bit n b = if b then pow2 n else 0
  pow2 n = if n == 0 then 1 else 2 * pow2 (n - 1)
