-- | The backend's inlined machine ops (ADR 0002, tier 1) and the
-- | foreign-primitive table that resolves a `foreign import` to one of them.
-- |
-- | `Intrinsic` is a closed enum keyed by *operation* rather than by CoreFn name,
-- | which decouples the IR from the foreign identifiers a given `Prelude` version
-- | uses: `foreignIntrinsic` owns the foreign-identifier → `Intrinsic` mapping
-- | (this module), and `genPrim` in the code generator owns `Intrinsic` → Binaryen.
-- | This module is a self-contained leaf — the IR embeds `Intrinsic` in `RPrim`.
module PureScript.Backend.Wasm.Intrinsics
  ( Intrinsic(..)
  , foreignIntrinsic
  ) where

import Prelude

import Data.Generic.Rep (class Generic)
import Data.Maybe (Maybe(..))
import Data.Show.Generic (genericShow)
import Data.Tuple (Tuple(..))

data Intrinsic
  = IntAdd
  | IntSub
  | IntMul
  | IntEq -- Int -> Int -> Boolean (`i32.eq`, result boxed as an `i31` Boolean)
  -- | `Data.Ord`'s `ordIntImpl lt eq gt x y`: the `Ordering` (`lt`/`eq`/`gt`) of
  -- | two `Int`s. Five operands — the three `Ordering` values and the two ints —
  -- | selected by a signed `i32` comparison.
  | OrdInt
  | IntToNum -- Int -> Number (`f64.convert_i32_s`)
  | NumToInt -- Number -> Int (`i32.trunc_f64_s`)
  -- | `Data.EuclideanRing`'s `Int` instance: Euclidean division (non-negative
  -- | remainder), with a zero guard so it matches `Prelude` and never traps.
  | IntDiv -- Int -> Int -> Int  (`(x - intMod x y) / y`, 0 when y = 0)
  | IntMod -- Int -> Int -> Int  (`((x % |y|) + |y|) % |y|`, 0 when y = 0)
  | IntDegree -- Int -> Int  (`min (|x|) maxInt`)
  | NumAdd -- Number -> Number -> Number (`f64.add`)
  | NumSub -- Number -> Number -> Number (`f64.sub`)
  | NumMul -- Number -> Number -> Number (`f64.mul`)
  | NumDiv -- Number -> Number -> Number (`f64.div`)
  | NumEq -- Number -> Number -> Boolean (`f64.eq`, result boxed as an `i31` Boolean)
  | BoolAnd -- Boolean -> Boolean -> Boolean (`i32.and` on the i31 bits)
  | BoolOr -- Boolean -> Boolean -> Boolean (`i32.or`)
  | BoolNot -- Boolean -> Boolean (`i32.eqz`)
  | StrLen -- String -> Int (UTF-8 byte length, `array.len`)
  | StrConcat -- String -> String -> String (allocate + copy both byte arrays)
  | StrEq -- String -> String -> Boolean (length then byte-by-byte compare)
  | ArrayLength -- Array a -> Int (`array.len`)
  | ArrayIndex -- Array a -> Int -> a (`array.get`; the element is already an `eqref`)
  -- | `Data.Bounded`'s `top` / `bottom` for `Int` / `Char` / `Number`: nullary
  -- | constant values (the foreign is a bare value, not a function — arity 0).
  | TopInt -- maxBound Int (`i32.const 2147483647`)
  | BottomInt -- minBound Int (`i32.const -2147483648`)
  | TopChar -- maxBound Char, code point 0xFFFF (`Int`-rep)
  | BottomChar -- minBound Char, code point 0 (`Int`-rep)
  | TopNumber -- `+Infinity` (`$Num` f64)
  | BottomNumber -- `-Infinity` (`$Num` f64)

derive instance eqIntrinsic :: Eq Intrinsic
derive instance genericIntrinsic :: Generic Intrinsic _
instance showIntrinsic :: Show Intrinsic where
  show = genericShow

-- | The foreign-primitive table — ADR 0002's `ForeignProvider`, hard-coded for the
-- | closed surface the backend currently understands. It maps a foreign import's
-- | *identifier* to the `Intrinsic` it stands for plus that intrinsic's arity.
-- |
-- | Keyed by the bare identifier (names are unique across the modules we link), so
-- | the real `Prelude`'s foreigns (`intAdd`, `eqIntImpl`, …) resolve directly. The
-- | string/array/`numToInt` entries are backend-internal helpers for features the
-- | real `Prelude` does not yet reach here.
foreignIntrinsic :: String -> Maybe (Tuple Intrinsic Int)
foreignIntrinsic = case _ of
  -- `Data.Semiring` / `Data.Ring` integer arithmetic
  "intAdd" -> Just (Tuple IntAdd 2)
  "intMul" -> Just (Tuple IntMul 2)
  "intSub" -> Just (Tuple IntSub 2)
  -- `Data.EuclideanRing` integer division (Euclidean: non-negative remainder)
  "intDiv" -> Just (Tuple IntDiv 2)
  "intMod" -> Just (Tuple IntMod 2)
  "intDegree" -> Just (Tuple IntDegree 1)
  -- `Data.Eq` / `Data.Ord` on Int (and Char, which shares its representation)
  "eqIntImpl" -> Just (Tuple IntEq 2)
  -- `Data.Bounded` top/bottom (nullary constant values, arity 0)
  "topInt" -> Just (Tuple TopInt 0)
  "bottomInt" -> Just (Tuple BottomInt 0)
  "topChar" -> Just (Tuple TopChar 0)
  "bottomChar" -> Just (Tuple BottomChar 0)
  "topNumber" -> Just (Tuple TopNumber 0)
  "bottomNumber" -> Just (Tuple BottomNumber 0)
  "eqCharImpl" -> Just (Tuple IntEq 2)
  "eqStringImpl" -> Just (Tuple StrEq 2)
  "ordIntImpl" -> Just (Tuple OrdInt 5)
  -- `Char` compares by code point, identical to `Int` (shared `i32` rep)
  "ordCharImpl" -> Just (Tuple OrdInt 5)
  -- `Data.HeytingAlgebra` Boolean algebra
  "boolConj" -> Just (Tuple BoolAnd 2)
  "boolDisj" -> Just (Tuple BoolOr 2)
  "boolNot" -> Just (Tuple BoolNot 1)
  -- `Number` arithmetic + `Int` → `Number` conversion
  "numAdd" -> Just (Tuple NumAdd 2)
  "numMul" -> Just (Tuple NumMul 2)
  "numSub" -> Just (Tuple NumSub 2)
  "numDiv" -> Just (Tuple NumDiv 2)
  "eqNumberImpl" -> Just (Tuple NumEq 2)
  "toNumber" -> Just (Tuple IntToNum 1)
  -- backend-internal helpers (no real-Prelude equivalent wired yet): strings,
  -- arrays, and Number → Int
  "lenS" -> Just (Tuple StrLen 1)
  "concatS" -> Just (Tuple StrConcat 2)
  "eqS" -> Just (Tuple StrEq 2)
  "lengthA" -> Just (Tuple ArrayLength 1)
  "indexA" -> Just (Tuple ArrayIndex 2)
  "eqI" -> Just (Tuple IntEq 2)
  "intToNum" -> Just (Tuple IntToNum 1)
  "numToInt" -> Just (Tuple NumToInt 1)
  _ -> Nothing
