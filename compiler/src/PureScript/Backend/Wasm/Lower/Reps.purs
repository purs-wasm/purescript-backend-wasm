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
-- | `Boxed` (an `i31` Boolean or an `eqref`) otherwise.
primRep :: Intrinsic -> Rep
primRep = case _ of
  IntAdd -> I32
  IntSub -> I32
  IntMul -> I32
  IntDiv -> I32
  IntMod -> I32
  IntDegree -> I32
  NumToInt -> I32
  StrLen -> I32
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
-- | `Boxed`.
primOperandReps :: Intrinsic -> Array Rep
primOperandReps = case _ of
  IntAdd -> [ I32, I32 ]
  IntSub -> [ I32, I32 ]
  IntMul -> [ I32, I32 ]
  IntDiv -> [ I32, I32 ]
  IntMod -> [ I32, I32 ]
  IntEq -> [ I32, I32 ]
  IntDegree -> [ I32 ]
  IntToNum -> [ I32 ]
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
  -- unsafeCompareImpl lt eq gt x y: the selected values are boxed, the operands typed
  OrdInt -> [ Boxed, Boxed, Boxed, I32, I32 ]
  OrdNumber -> [ Boxed, Boxed, Boxed, F64, F64 ]
  -- forE lo hi f (perform-unit): the bounds are unboxed i32, the body closure boxed
  ForE -> [ I32, I32, Boxed, Boxed ]
  _ -> []
