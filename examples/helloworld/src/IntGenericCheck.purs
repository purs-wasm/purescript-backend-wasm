-- Regression fixture for the wat-only ulib modules (ADR 0031 phase 4b-2): `Data.Int`
-- (`fromStringAsImpl`) and `Data.Show.Generic` (`intercalate`) are NOT shadowed (the build uses
-- their registry corefn), but ulib provides their foreign from the lib `foreign.wasm`, so a program
-- using them stays STANDALONE (no JS host import). This builds with `{}` imports and must run.
-- Driven by `compiler/test/intGenericShadow.mjs`.
module Examples.HelloWorld.IntGenericCheck where

import Prelude

import Data.Generic.Rep (class Generic)
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Show.Generic (genericShow)

data Pair = Pair Int Boolean

derive instance Generic Pair _
instance Show Pair where
  show = genericShow

check :: Int -> Int
check _ =
  bit 0 (Int.fromString "42" == Just 42) -- Data.Int.fromStringAsImpl

    + bit 1 (Int.fromString "zz" == Nothing)
    + bit 2 (show (Pair 5 true) == "(Pair 5 true)") -- Data.Show.Generic.intercalate
  where
  bit n b = if b then pow2 n else 0
  pow2 n = if n == 0 then 1 else 2 * pow2 (n - 1)
