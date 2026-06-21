-- | The representation signature of each intrinsic: the wasm representation of its
-- | result (`primRep`) and of each operand (`primOperandReps`). Shared by codegen
-- | (which generates operands / results at these reps) and the unboxing analysis
-- | (which uses them as the producer / demand reps). These must match how
-- | `Codegen.Prim` actually generates each intrinsic.
module PureScript.Backend.Wasm.Lower.Reps
  ( primRep
  , primOperandReps
  ) where

import PureScript.Backend.Wasm.Intrinsics (Intrinsic(..))
import PureScript.Backend.Wasm.Lower.IR (Rep(..))

-- | The natural representation an intrinsic's result is produced at: raw `i32` for
-- | `Int` arithmetic / lengths / constants, raw `f64` for `Number` arithmetic,
-- | raw `i64` for the `Wasm.Int64` ops, `Boxed` (an `i31` Boolean or an `eqref`)
-- | otherwise.
-- |
-- | INVARIANT: this MUST equal the wasm rep `Codegen.Prim.genPrim` actually emits
-- | for the intrinsic. A wrong entry here does not box/unbox harmlessly; it makes
-- | `coerce` apply a transition (e.g. `Boxed -> I64` = `ref.cast (ref $Int64)`) to
-- | an expression of the wrong binaryen type, which aborts in binaryen's
-- | `visitRefCast` (`isSubType` assertion), not at the PureScript layer.
primRep :: Intrinsic -> Rep
primRep = case _ of
  IntAdd -> I32
  IntSub -> I32
  IntMul -> I32
  IntDiv -> I32
  IntMod -> I32
  IntDegree -> I32
  -- `Data.Int.Bits` 32-bit bitwise ops all produce a raw i32
  IntAnd -> I32
  IntOr -> I32
  IntXor -> I32
  IntShl -> I32
  IntShr -> I32
  IntZshr -> I32
  IntComplement -> I32
  -- `Wasm.Int64`: the ops returning `Int64` produce a raw i64 (single `i64.*`
  -- instruction in `Codegen.Prim`); `toInt` wraps to i32; `eq`/`lt` produce an
  -- i31 Boolean (`Boxed`, via the catch-all below).
  Int64FromInt -> I64
  Int64And -> I64
  Int64Or -> I64
  Int64Xor -> I64
  Int64Complement -> I64
  Int64Shl -> I64
  Int64ShrS -> I64
  Int64ShrU -> I64
  Int64RotL -> I64
  Int64RotR -> I64
  Int64ToInt -> I32
  Int64Eq -> Boxed -- i31 Boolean
  Int64Lt -> Boxed -- i31 Boolean
  NumToInt -> I32
  StrLen -> I32
  StrByteAt -> I32 -- a UTF-8 byte (0-255), as an Int
  CharCodeId -> I32 -- Char/Int share the i32 code-point rep; the conversion is the identity
  ArrayLength -> I32
  TopInt -> I32
  BottomInt -> I32
  TopChar -> I32
  BottomChar -> I32
  UnitValue -> I32
  IncrCtr -> I32 -- Unit, as the i32 `0`
  ReadCtr -> I32 -- the counter, an unboxed i32
  RefWrite -> I32 -- Effect.Ref.write returns Unit, as the i32 `0` (ADR 0017)
  -- the `effect` control-flow loops return Unit (i32 0); ADR 0018
  ForE -> I32
  ForeachE -> I32
  WhileE -> I32
  UntilE -> I32
  NumAdd -> F64
  NumSub -> F64
  NumMul -> F64
  NumDiv -> F64
  IntToNum -> F64
  TopNumber -> F64
  BottomNumber -> F64
  _ -> Boxed

-- | The representation each operand is generated at (by position); operands past
-- | the listed reps — and every operand of an unlisted intrinsic — default to
-- | `Boxed`. This must agree with the reps `Codegen.Prim` coerces each operand to
-- | (the i64 ops coerce every operand with `i64Arg = genAtomAs ctx I64`); a
-- | mismatch here is "only" a box/unbox round-trip (valid but wasteful), unlike a
-- | wrong `primRep`, but keep it correct so the box-elision analysis is accurate.
primOperandReps :: Intrinsic -> Array Rep
primOperandReps = case _ of
  IntAdd -> [ I32, I32 ]
  IntSub -> [ I32, I32 ]
  IntMul -> [ I32, I32 ]
  IntDiv -> [ I32, I32 ]
  IntMod -> [ I32, I32 ]
  IntEq -> [ I32, I32 ]
  IntLt -> [ I32, I32 ]
  IntDegree -> [ I32 ]
  IntToNum -> [ I32 ]
  -- `Data.Int.Bits`: both operands unboxed i32 (the shift count too)
  IntAnd -> [ I32, I32 ]
  IntOr -> [ I32, I32 ]
  IntXor -> [ I32, I32 ]
  IntShl -> [ I32, I32 ]
  IntShr -> [ I32, I32 ]
  IntZshr -> [ I32, I32 ]
  IntComplement -> [ I32 ]
  -- `Wasm.Int64`: operands are i64, except `fromInt` (takes an i32 `Int`) and the
  -- shift/rotate count, which is itself an `Int64` on the surface and coerced to
  -- i64 by `i64Arg`, so `[ I64, I64 ]` for the binary shifts/rotates.
  Int64And -> [ I64, I64 ]
  Int64Or -> [ I64, I64 ]
  Int64Xor -> [ I64, I64 ]
  Int64Complement -> [ I64 ]
  Int64Shl -> [ I64, I64 ]
  Int64ShrS -> [ I64, I64 ]
  Int64ShrU -> [ I64, I64 ]
  Int64RotL -> [ I64, I64 ]
  Int64RotR -> [ I64, I64 ]
  Int64Eq -> [ I64, I64 ]
  Int64Lt -> [ I64, I64 ]
  Int64FromInt -> [ I32 ]
  Int64ToInt -> [ I64 ]
  FromNumberImpl -> [ Boxed, Boxed, F64 ] -- just, nothing, n (the Number is unboxed)
  NumToInt -> [ F64 ]
  NumAdd -> [ F64, F64 ]
  NumSub -> [ F64, F64 ]
  NumMul -> [ F64, F64 ]
  NumDiv -> [ F64, F64 ]
  NumEq -> [ F64, F64 ]
  -- Array a -> Int -> a: the array is `eqref`, the index `i32`
  ArrayIndex -> [ Boxed, I32 ]
  -- Wasm.Array build primitives: lengths / indices are unboxed i32, arrays / values boxed
  ArrayNew -> [ I32 ]
  ArraySet -> [ Boxed, I32, Boxed ]
  -- Wasm.String byte primitives: the string is boxed ($Str eqref), indices / bytes are i32
  StrByteAt -> [ Boxed, I32 ]
  StrNew -> [ I32 ]
  StrSetByte -> [ Boxed, I32, I32 ]
  -- Wasm.Char identity: the operand (Char or Int) is the i32 code point
  CharCodeId -> [ I32 ]
  -- unsafeCompareImpl lt eq gt x y: the selected values are boxed, the operands typed
  OrdInt -> [ Boxed, Boxed, Boxed, I32, I32 ]
  OrdNumber -> [ Boxed, Boxed, Boxed, F64, F64 ]
  -- forE lo hi f (perform-unit): the bounds are unboxed i32, the body closure boxed
  ForE -> [ I32, I32, Boxed, Boxed ]
  _ -> []