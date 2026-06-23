module E2E.PackedArrays where

import Prelude

import Data.Int (round)
import Wasm.F64Array as F
import Wasm.I32Array as I
import Wasm.I64Array as L
import Wasm.Int64 as I64

-- I32Array
i32Len :: Int -> Int
i32Len _ =
  let
    a = I.unsafeSet (I.unsafeSet (I.unsafeSet (I.unsafeNew 3) 0 10) 1 20) 2 30
  in
    I.length a

i32At :: Int -> Int
i32At i =
  let
    a = I.unsafeSet (I.unsafeSet (I.unsafeSet (I.unsafeNew 3) 0 10) 1 20) 2 30
  in
    I.unsafeIndex a i

i32Sum :: Int -> Int
i32Sum _ =
  let
    a = I.unsafeSet (I.unsafeSet (I.unsafeSet (I.unsafeNew 3) 0 10) 1 20) 2 30
  in
    I.unsafeIndex a 0 + I.unsafeIndex a 1 + I.unsafeIndex a 2

i32ZeroInit :: Int -> Int
i32ZeroInit _ = I.unsafeIndex (I.unsafeNew 4) 2

-- F64Array
f64Mul :: Int -> Int
f64Mul _ =
  let
    a = F.unsafeSet (F.unsafeSet (F.unsafeNew 2) 0 3.0) 1 4.0
  in
    round (F.unsafeIndex a 0 * F.unsafeIndex a 1)

f64Len :: Int -> Int
f64Len _ = F.length (F.unsafeNew 5)

f64ZeroInit :: Int -> Int
f64ZeroInit _ = round (F.unsafeIndex (F.unsafeNew 3) 1)

-- I64Array (native 64-bit lanes; values round-tripped through Wasm.Int64)
i64Len :: Int -> Int
i64Len _ = L.length (L.unsafeNew 4)

i64At :: Int -> Int
i64At i =
  let
    a = L.unsafeSet (L.unsafeSet (L.unsafeSet (L.unsafeNew 3) 0 (I64.fromInt 10)) 1 (I64.fromInt 20)) 2 (I64.fromInt 30)
  in
    I64.lowBits (L.unsafeIndex a i)

i64ZeroInit :: Int -> Int
i64ZeroInit _ = I64.lowBits (L.unsafeIndex (L.unsafeNew 3) 1)