-- | Code generation for intrinsics (`RPrim`, ADR 0002 tier 1): generate the
-- | operands at the representation the machine op needs (`genAtomAs I32`/`F64` is a
-- | no-op when the operand is already unboxed, an unbox otherwise), apply the op or
-- | call the runtime helper, and yield the result at its *natural* representation —
-- | a raw `i32`/`f64` for arithmetic (`genBody` boxes it only if the bound slot is
-- | `Boxed`), an `i31` Boolean or an `eqref` otherwise. The lowering guarantees the
-- | arity. `primRep` records each intrinsic's result representation so `genBody` can
-- | coerce it to the bound slot.
module PureScript.Backend.Wasm.Codegen.Prim
  ( genPrim
  ) where

import Prelude

import Binaryen as B
import Effect (Effect)
import Effect.Exception (error, throwException)
import PureScript.Backend.Wasm.Codegen.Imports (arrayApplyHelperName, arrayBindHelperName, arrayConcatHelperName, arrayEqHelperName, arrayMapHelperName, arrayOrdHelperName, counterGlobalName, intDegreeHelperName, intDivHelperName, intModHelperName, intercalateHelperName, internStrName, projHelperName, recDeleteHelperName, recHasHelperName, recSetHelperName, showArrayHelperName, showCharHelperName, showIntHelperName, showNumberHelperName, showStringHelperName, strCmpHelperName, strConcatHelperName, strEqHelperName)
import PureScript.Backend.Wasm.Codegen.RuntimeTypes (Ctx)
import PureScript.Backend.Wasm.Codegen.Value (boxInt, genAtomAs, strBytes, unboxBoolExpr)
import PureScript.Backend.Wasm.Lower.IR (Atom, Rep(..))
import PureScript.Backend.Wasm.Intrinsics (Intrinsic(..))

genPrim :: Ctx -> Intrinsic -> Array Atom -> Effect B.Expression
genPrim ctx intr args = case intr, args of
  IntAdd, [ a, b ] -> intBinop B.i32Add a b
  IntSub, [ a, b ] -> intBinop B.i32Sub a b
  IntMul, [ a, b ] -> intBinop B.i32Mul a b
  -- Int -> Int -> Boolean: compare as i32, box the result as an i31 Boolean.
  IntEq, [ a, b ] -> do
    ea <- intArg a
    eb <- intArg b
    B.i32Eq ctx.mod ea eb >>= B.i31New ctx.mod
  -- Boolean -> Boolean -> Boolean: compare the i31 bits, box as an i31 Boolean.
  BoolEq, [ a, b ] -> do
    ea <- boolArg a
    eb <- boolArg b
    B.i32Eq ctx.mod ea eb >>= B.i31New ctx.mod
  -- unsafeCompareImpl lt eq gt x y = if x < y then lt else if x == y then eq else gt,
  -- differing per type only in how the operands are unboxed and compared.
  OrdInt, [ lt, eq, gt, x, y ] -> ordSelect intArg B.i32LtS B.i32Eq lt eq gt x y
  OrdBool, [ lt, eq, gt, x, y ] -> ordSelect boolArg B.i32LtS B.i32Eq lt eq gt x y
  OrdNumber, [ lt, eq, gt, x, y ] -> ordSelect numArg B.f64Lt B.f64Eq lt eq gt x y
  -- ordStringImpl: select on the sign of the lexicographic comparison.
  OrdString, [ lt, eq, gt, x, y ] ->
    ordSelectC
      (strCmpCond x y (\c -> B.i32Const ctx.mod 0 >>= B.i32LtS ctx.mod c))
      (strCmpCond x y (\c -> B.i32Eqz ctx.mod c))
      lt
      eq
      gt
  -- Array equality / comparison: delegate to the higher-order runtime helpers,
  -- which apply the element closure per element.
  ArrayEq, [ f, xs, ys ] -> do
    ef <- genAtomAs ctx Boxed f
    exs <- genAtomAs ctx Boxed xs
    eys <- genAtomAs ctx Boxed ys
    B.call ctx.mod arrayEqHelperName [ ef, exs, eys ] B.i32 >>= B.i31New ctx.mod
  ArrayOrd, [ f, xs, ys ] -> do
    ef <- genAtomAs ctx Boxed f
    exs <- genAtomAs ctx Boxed xs
    eys <- genAtomAs ctx Boxed ys
    B.call ctx.mod arrayOrdHelperName [ ef, exs, eys ] B.i32
  -- Array Functor / Apply / Bind: the higher-order helpers build a new `$Vals`
  -- (already an `eqref`, so no boxing). Operand order matches the foreign.
  ArrayMap, [ f, xs ] -> arrayHof arrayMapHelperName f xs
  ArrayApply, [ fs, xs ] -> arrayHof arrayApplyHelperName fs xs
  ArrayBind, [ xs, f ] -> arrayHof arrayBindHelperName xs f
  -- Euclidean Int division/remainder/degree: unbox, delegate to the shared
  -- runtime helpers (zero guard + non-negative remainder).
  IntDiv, [ a, b ] -> intCall2 intDivHelperName a b
  IntMod, [ a, b ] -> intCall2 intModHelperName a b
  IntDegree, [ a ] -> do
    ea <- intArg a
    B.call ctx.mod intDegreeHelperName [ ea ] B.i32
  -- Int -> Number
  IntToNum, [ a ] -> do
    ea <- intArg a
    B.f64ConvertI32S ctx.mod ea
  -- Number -> Int (truncating)
  NumToInt, [ a ] -> do
    ea <- numArg a
    B.i32TruncF64S ctx.mod ea
  -- Boolean algebra on the unboxed i31 bits, re-boxed as an i31 Boolean
  BoolAnd, [ a, b ] -> boolBinop B.i32And a b
  BoolOr, [ a, b ] -> boolBinop B.i32Or a b
  BoolNot, [ a ] -> do
    ea <- boolArg a
    B.i32Eqz ctx.mod ea >>= B.i31New ctx.mod
  -- Number (f64) arithmetic: unbox the $Num operands, apply
  NumAdd, [ a, b ] -> numBinop B.f64Add a b
  NumSub, [ a, b ] -> numBinop B.f64Sub a b
  NumMul, [ a, b ] -> numBinop B.f64Mul a b
  NumDiv, [ a, b ] -> numBinop B.f64Div a b
  -- Number -> Number -> Boolean
  NumEq, [ a, b ] -> do
    ea <- numArg a
    eb <- numArg b
    B.f64Eq ctx.mod ea eb >>= B.i31New ctx.mod
  -- String -> Int: the UTF-8 byte length
  StrLen, [ a ] -> do
    bytes <- strBytes ctx a
    B.arrayLen ctx.mod bytes
  -- String -> String -> String / Boolean: delegate to the shared runtime helpers
  StrConcat, [ a, b ] -> do
    ea <- genAtomAs ctx Boxed a
    eb <- genAtomAs ctx Boxed b
    B.call ctx.mod strConcatHelperName [ ea, eb ] B.eqref
  ArrayConcat, [ a, b ] -> do
    ea <- genAtomAs ctx Boxed a
    eb <- genAtomAs ctx Boxed b
    B.call ctx.mod arrayConcatHelperName [ ea, eb ] B.eqref
  -- Int -> String: unbox the operand, delegate to the decimal-rendering helper
  ShowInt, [ a ] -> do
    ea <- intArg a
    B.call ctx.mod showIntHelperName [ ea ] B.eqref
  -- Char -> String: the code point goes to the char-rendering helper
  ShowChar, [ a ] -> do
    ea <- intArg a
    B.call ctx.mod showCharHelperName [ ea ] B.eqref
  -- String -> String: pass the `$Str` (eqref) to the string-rendering helper
  ShowString, [ a ] -> do
    ea <- genAtomAs ctx Boxed a
    B.call ctx.mod showStringHelperName [ ea ] B.eqref
  -- (a -> String) -> Array a -> String: the element-show closure and the array
  ShowArray, [ f, xs ] -> do
    ef <- genAtomAs ctx Boxed f
    exs <- genAtomAs ctx Boxed xs
    B.call ctx.mod showArrayHelperName [ ef, exs ] B.eqref
  -- Number -> String: unbox the `$Num` to f64, delegate to the Dragon4 helper
  ShowNumber, [ a ] -> do
    ea <- numArg a
    B.call ctx.mod showNumberHelperName [ ea ] B.eqref
  -- String -> Array String -> String: join the rendered strings with the separator
  Intercalate, [ sep, xs ] -> do
    esep <- genAtomAs ctx Boxed sep
    exs <- genAtomAs ctx Boxed xs
    B.call ctx.mod intercalateHelperName [ esep, exs ] B.eqref
  StrEq, [ a, b ] -> do
    ea <- genAtomAs ctx Boxed a
    eb <- genAtomAs ctx Boxed b
    B.call ctx.mod strEqHelperName [ ea, eb ] B.i32 >>= B.i31New ctx.mod
  -- Array a -> Int: the element count
  ArrayLength, [ a ] -> do
    arr <- genAtomAs ctx Boxed a >>= \e -> B.refCast ctx.mod e ctx.rt.refVals
    B.arrayLen ctx.mod arr
  -- Array a -> Int -> a: read the (already-`eqref`) element at the index
  ArrayIndex, [ a, i ] -> do
    arr <- genAtomAs ctx Boxed a >>= \e -> B.refCast ctx.mod e ctx.rt.refVals
    idx <- intArg i
    B.arrayGet ctx.mod arr idx B.eqref false
  -- Data.Bounded constants as raw values (boxed by the binding if needed).
  -- The Int min cannot be written as a literal (out of `Int` range), so build it.
  TopInt, [] -> B.i32Const ctx.mod 2147483647
  BottomInt, [] -> B.i32Const ctx.mod (-2147483647 - 1)
  TopChar, [] -> B.i32Const ctx.mod 65535
  BottomChar, [] -> B.i32Const ctx.mod 0
  TopNumber, [] -> B.f64Const ctx.mod (1.0 / 0.0)
  BottomNumber, [] -> B.f64Const ctx.mod (-1.0 / 0.0)
  -- `Data.Unit.unit`: a never-inspected `0`.
  UnitValue, [] -> B.i32Const ctx.mod 0
  -- test-only effectful counter (mutable global `$ctr`); the unit operand is ignored.
  IncrCtr, _ -> do
    cur <- B.globalGet ctx.mod counterGlobalName B.i32
    one <- B.i32Const ctx.mod 1
    next <- B.i32Add ctx.mod cur one
    setE <- B.globalSet ctx.mod counterGlobalName next
    unitE <- B.i32Const ctx.mod 0
    B.block ctx.mod [ setE, unitE ] B.i32
  ReadCtr, _ -> B.globalGet ctx.mod counterGlobalName B.i32
  -- `Record.Unsafe`: resolve the `String` key to its label id, then read / rebuild
  -- the record through the id-keyed runtime helpers.
  UnsafeGet, [ key, rec ] -> do
    rid <- internId key
    er <- genAtomAs ctx Boxed rec
    B.call ctx.mod projHelperName [ er, rid ] B.eqref
  UnsafeHas, [ key, rec ] -> do
    rid <- internId key
    er <- genAtomAs ctx Boxed rec
    B.call ctx.mod recHasHelperName [ er, rid ] B.i32 >>= B.i31New ctx.mod
  UnsafeSet, [ key, val, rec ] -> do
    rid <- internId key
    ev <- genAtomAs ctx Boxed val
    er <- genAtomAs ctx Boxed rec
    B.call ctx.mod recSetHelperName [ er, rid, ev ] B.eqref
  UnsafeDelete, [ key, rec ] -> do
    rid <- internId key
    er <- genAtomAs ctx Boxed rec
    B.call ctx.mod recDeleteHelperName [ er, rid ] B.eqref
  -- `Data.Int.fromNumberImpl just nothing n`: `just (trunc n)` when `n` is an integer in
  -- the Int32 range (JS `(n | 0) === n`), else `nothing`. The outer guard keeps `n` away
  -- from `i32.trunc_f64_s`'s trap (NaN / out of range — those yield `nothing`).
  FromNumberImpl, [ just, nothing, n ] -> do
    -- guard = not NaN  &&  n >= -2^31  &&  n <= 2^31-1
    notNaN <- join (B.f64Eq ctx.mod <$> numArg n <*> numArg n)
    geMin <- numArg n >>= \a -> B.f64Const ctx.mod (-2147483648.0) >>= B.f64Lt ctx.mod a >>= B.i32Eqz ctx.mod
    leMax <- numArg n >>= \a -> B.f64Const ctx.mod 2147483647.0 >>= \m -> B.f64Lt ctx.mod m a >>= B.i32Eqz ctx.mod
    guardE <- join (B.i32And ctx.mod <$> B.i32And ctx.mod notNaN geMin <*> pure leMax)
    -- integral? (f64)(trunc n) == n
    isInt <- join (B.f64Eq ctx.mod <$> (numArg n >>= B.i32TruncF64S ctx.mod >>= B.f64ConvertI32S ctx.mod) <*> numArg n)
    -- just (box (trunc n))
    justApplied <- (numArg n >>= B.i32TruncF64S ctx.mod >>= boxInt ctx) >>= applyClo just
    nothingThen <- genAtomAs ctx Boxed nothing
    nothingElse <- genAtomAs ctx Boxed nothing
    inner <- B.if_ ctx.mod isInt justApplied nothingThen
    B.if_ ctx.mod guardE inner nothingElse
  _, _ -> throwException (error "Codegen: intrinsic given an operand list of the wrong arity")
  where
  -- operand at the representation the op needs (no-op if already that rep)
  intArg = genAtomAs ctx I32
  numArg = genAtomAs ctx F64
  boolArg a = genAtomAs ctx Boxed a >>= unboxBoolExpr ctx
  -- apply a closure atom to one (already-built) argument via the runtime trampoline
  -- (`ref.cast $Clo`, read the `funcref`, `ref.cast $Code`, `call_ref`)
  applyClo cloAtom argE = do
    cloForCode <- genAtomAs ctx Boxed cloAtom >>= \h -> B.refCast ctx.mod h ctx.rt.refClo
    fref <- B.structGet ctx.mod 0 cloForCode B.funcref false
    codeF <- B.refCast ctx.mod fref ctx.rt.refCode
    cloOperand <- genAtomAs ctx Boxed cloAtom >>= \h -> B.refCast ctx.mod h ctx.rt.refClo
    B.callRef ctx.mod codeF [ cloOperand, argE ] ctx.rt.codeHt
  -- resolve a record-label `String` atom to its interned `i32` id via `internStr`
  internId key = do
    ek <- genAtomAs ctx Boxed key
    B.call ctx.mod internStrName [ ek ] B.i32
  intBinop op a b = do
    ea <- intArg a
    eb <- intArg b
    op ctx.mod ea eb
  intCall2 name a b = do
    ea <- intArg a
    eb <- intArg b
    B.call ctx.mod name [ ea, eb ] B.i32
  -- a binary higher-order array helper: two `eqref` operands → an `eqref` result.
  arrayHof name a b = do
    ea <- genAtomAs ctx Boxed a
    eb <- genAtomAs ctx Boxed b
    B.call ctx.mod name [ ea, eb ] B.eqref
  boolBinop op a b = do
    ea <- boolArg a
    eb <- boolArg b
    op ctx.mod ea eb >>= B.i31New ctx.mod
  numBinop op a b = do
    ea <- numArg a
    eb <- numArg b
    op ctx.mod ea eb
  -- `lt eq gt`: pick `lt`/`eq`/`gt` (boxed values) from the given `i32` conditions.
  ordSelectC ltCondM eqCondM lt eq gt = do
    ltCond <- ltCondM
    eqCond <- eqCondM
    ltE <- genAtomAs ctx Boxed lt
    eqE <- genAtomAs ctx Boxed eq
    gtE <- genAtomAs ctx Boxed gt
    inner <- B.if_ ctx.mod eqCond eqE gtE
    B.if_ ctx.mod ltCond ltE inner
  -- ordSelectC specialised to unbox both operands and apply a primitive compare.
  ordSelect unbox ltOp eqOp lt eq gt x y =
    let
      cmp2 op = do
        ex <- unbox x
        ey <- unbox y
        op ctx.mod ex ey
    in
      ordSelectC (cmp2 ltOp) (cmp2 eqOp) lt eq gt
  -- a condition derived from `$rt.strCmp x y` (e.g. `< 0`, `== 0`).
  strCmpCond x y k = do
    ex <- genAtomAs ctx Boxed x
    ey <- genAtomAs ctx Boxed y
    c <- B.call ctx.mod strCmpHelperName [ ex, ey ] B.i32
    k c
