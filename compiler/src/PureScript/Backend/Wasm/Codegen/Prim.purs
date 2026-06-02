-- | Code generation for intrinsics (`RPrim`, ADR 0002 tier 1): unbox the operands,
-- | apply the machine op or call the runtime helper, re-box the result. Operand and
-- | result boxing follow the intrinsic's types; the lowering guarantees the arity.
module PureScript.Backend.Wasm.Codegen.Prim
  ( genPrim
  ) where

import Prelude

import Binaryen as B
import Effect (Effect)
import Effect.Exception (error, throwException)
import PureScript.Backend.Wasm.Codegen.Imports (arrayApplyHelperName, arrayBindHelperName, arrayConcatHelperName, arrayEqHelperName, arrayMapHelperName, arrayOrdHelperName, intDegreeHelperName, intDivHelperName, intModHelperName, intercalateHelperName, internStrName, projHelperName, recDeleteHelperName, recHasHelperName, recSetHelperName, showArrayHelperName, showCharHelperName, showIntHelperName, showNumberHelperName, showStringHelperName, strCmpHelperName, strConcatHelperName, strEqHelperName)
import PureScript.Backend.Wasm.Codegen.RuntimeTypes (Ctx)
import PureScript.Backend.Wasm.Codegen.Value (boxInt, boxNum, genAtom, strBytes, unboxBoolExpr, unboxIntAtom, unboxNumExpr)
import PureScript.Backend.Wasm.IR (Atom)
import PureScript.Backend.Wasm.Intrinsics (Intrinsic(..))

genPrim :: Ctx -> Intrinsic -> Array Atom -> Effect B.Expression
genPrim ctx intr args = case intr, args of
  IntAdd, [ a, b ] -> intBinop B.i32Add a b
  IntSub, [ a, b ] -> intBinop B.i32Sub a b
  IntMul, [ a, b ] -> intBinop B.i32Mul a b
  -- Int -> Int -> Boolean: compare as i32, box the result as an i31 Boolean.
  IntEq, [ a, b ] -> do
    ea <- unboxIntAtom ctx a
    eb <- unboxIntAtom ctx b
    B.i32Eq ctx.mod ea eb >>= B.i31New ctx.mod
  -- Boolean -> Boolean -> Boolean: compare the i31 bits, box as an i31 Boolean.
  BoolEq, [ a, b ] -> do
    ea <- genAtom ctx a >>= unboxBoolExpr ctx
    eb <- genAtom ctx b >>= unboxBoolExpr ctx
    B.i32Eq ctx.mod ea eb >>= B.i31New ctx.mod
  -- unsafeCompareImpl lt eq gt x y = if x < y then lt else if x == y then eq else gt,
  -- differing per type only in how the operands are unboxed and compared.
  OrdInt, [ lt, eq, gt, x, y ] -> ordSelect unboxIntAtom' B.i32LtS B.i32Eq lt eq gt x y
  OrdBool, [ lt, eq, gt, x, y ] -> ordSelect unboxBoolAtom B.i32LtS B.i32Eq lt eq gt x y
  OrdNumber, [ lt, eq, gt, x, y ] -> ordSelect unboxNumAtom B.f64Lt B.f64Eq lt eq gt x y
  -- ordStringImpl: select on the sign of the lexicographic comparison.
  OrdString, [ lt, eq, gt, x, y ] ->
    ordSelectC
      (strCmpCond x y (\c -> B.i32Const ctx.mod 0 >>= B.i32LtS ctx.mod c))
      (strCmpCond x y (\c -> B.i32Eqz ctx.mod c))
      lt
      eq
      gt
  -- Array equality / comparison: delegate to the higher-order runtime helpers,
  -- which apply the element closure per element. Box the Boolean / Int result.
  ArrayEq, [ f, xs, ys ] -> do
    ef <- genAtom ctx f
    exs <- genAtom ctx xs
    eys <- genAtom ctx ys
    B.call ctx.mod arrayEqHelperName [ ef, exs, eys ] B.i32 >>= B.i31New ctx.mod
  ArrayOrd, [ f, xs, ys ] -> do
    ef <- genAtom ctx f
    exs <- genAtom ctx xs
    eys <- genAtom ctx ys
    B.call ctx.mod arrayOrdHelperName [ ef, exs, eys ] B.i32 >>= boxInt ctx
  -- Array Functor / Apply / Bind: the higher-order helpers build a new `$Vals`
  -- (already an `eqref`, so no boxing). Operand order matches the foreign.
  ArrayMap, [ f, xs ] -> arrayHof arrayMapHelperName f xs
  ArrayApply, [ fs, xs ] -> arrayHof arrayApplyHelperName fs xs
  ArrayBind, [ xs, f ] -> arrayHof arrayBindHelperName xs f
  -- Euclidean Int division/remainder/degree: unbox, delegate to the shared
  -- runtime helpers (zero guard + non-negative remainder), re-box the result.
  IntDiv, [ a, b ] -> intCall2 intDivHelperName a b
  IntMod, [ a, b ] -> intCall2 intModHelperName a b
  IntDegree, [ a ] -> do
    ea <- unboxIntAtom ctx a
    B.call ctx.mod intDegreeHelperName [ ea ] B.i32 >>= boxInt ctx
  -- Int -> Number
  IntToNum, [ a ] -> do
    ea <- unboxIntAtom ctx a
    B.f64ConvertI32S ctx.mod ea >>= boxNum ctx
  -- Number -> Int (truncating)
  NumToInt, [ a ] -> do
    ea <- genAtom ctx a >>= unboxNumExpr ctx
    B.i32TruncF64S ctx.mod ea >>= boxInt ctx
  -- Boolean algebra on the unboxed i31 bits, re-boxed as an i31 Boolean
  BoolAnd, [ a, b ] -> boolBinop B.i32And a b
  BoolOr, [ a, b ] -> boolBinop B.i32Or a b
  BoolNot, [ a ] -> do
    ea <- genAtom ctx a >>= unboxBoolExpr ctx
    B.i32Eqz ctx.mod ea >>= B.i31New ctx.mod
  -- Number (f64) arithmetic: unbox the $Num operands, apply, re-box
  NumAdd, [ a, b ] -> numBinop B.f64Add a b
  NumSub, [ a, b ] -> numBinop B.f64Sub a b
  NumMul, [ a, b ] -> numBinop B.f64Mul a b
  NumDiv, [ a, b ] -> numBinop B.f64Div a b
  -- Number -> Number -> Boolean
  NumEq, [ a, b ] -> do
    ea <- genAtom ctx a >>= unboxNumExpr ctx
    eb <- genAtom ctx b >>= unboxNumExpr ctx
    B.f64Eq ctx.mod ea eb >>= B.i31New ctx.mod
  -- String -> Int: the UTF-8 byte length
  StrLen, [ a ] -> do
    bytes <- strBytes ctx a
    B.arrayLen ctx.mod bytes >>= boxInt ctx
  -- String -> String -> String / Boolean: delegate to the shared runtime helpers
  StrConcat, [ a, b ] -> do
    ea <- genAtom ctx a
    eb <- genAtom ctx b
    B.call ctx.mod strConcatHelperName [ ea, eb ] B.eqref
  ArrayConcat, [ a, b ] -> do
    ea <- genAtom ctx a
    eb <- genAtom ctx b
    B.call ctx.mod arrayConcatHelperName [ ea, eb ] B.eqref
  -- Int -> String: unbox the operand, delegate to the decimal-rendering helper
  ShowInt, [ a ] -> do
    ea <- unboxIntAtom ctx a
    B.call ctx.mod showIntHelperName [ ea ] B.eqref
  -- Char -> String: the code point goes to the char-rendering helper
  ShowChar, [ a ] -> do
    ea <- unboxIntAtom ctx a
    B.call ctx.mod showCharHelperName [ ea ] B.eqref
  -- String -> String: pass the `$Str` (eqref) to the string-rendering helper
  ShowString, [ a ] -> do
    ea <- genAtom ctx a
    B.call ctx.mod showStringHelperName [ ea ] B.eqref
  -- (a -> String) -> Array a -> String: the element-show closure and the array
  ShowArray, [ f, xs ] -> do
    ef <- genAtom ctx f
    exs <- genAtom ctx xs
    B.call ctx.mod showArrayHelperName [ ef, exs ] B.eqref
  -- Number -> String: unbox the `$Num` to f64, delegate to the Dragon4 helper
  ShowNumber, [ a ] -> do
    ea <- genAtom ctx a >>= unboxNumExpr ctx
    B.call ctx.mod showNumberHelperName [ ea ] B.eqref
  -- String -> Array String -> String: join the rendered strings with the separator
  Intercalate, [ sep, xs ] -> do
    esep <- genAtom ctx sep
    exs <- genAtom ctx xs
    B.call ctx.mod intercalateHelperName [ esep, exs ] B.eqref
  StrEq, [ a, b ] -> do
    ea <- genAtom ctx a
    eb <- genAtom ctx b
    B.call ctx.mod strEqHelperName [ ea, eb ] B.i32 >>= B.i31New ctx.mod
  -- Array a -> Int: the element count
  ArrayLength, [ a ] -> do
    arr <- genAtom ctx a >>= \e -> B.refCast ctx.mod e ctx.rt.refVals
    B.arrayLen ctx.mod arr >>= boxInt ctx
  -- Array a -> Int -> a: read the (already-`eqref`) element at the index
  ArrayIndex, [ a, i ] -> do
    arr <- genAtom ctx a >>= \e -> B.refCast ctx.mod e ctx.rt.refVals
    idx <- unboxIntAtom ctx i
    B.arrayGet ctx.mod arr idx B.eqref false
  -- Data.Bounded constants: Int/Char as boxed `$Int`, Number's ±Infinity as `$Num`.
  -- The Int min cannot be written as a literal (out of `Int` range), so build it.
  TopInt, [] -> B.i32Const ctx.mod 2147483647 >>= boxInt ctx
  BottomInt, [] -> B.i32Const ctx.mod (-2147483647 - 1) >>= boxInt ctx
  TopChar, [] -> B.i32Const ctx.mod 65535 >>= boxInt ctx
  BottomChar, [] -> B.i32Const ctx.mod 0 >>= boxInt ctx
  TopNumber, [] -> B.f64Const ctx.mod (1.0 / 0.0) >>= boxNum ctx
  BottomNumber, [] -> B.f64Const ctx.mod (-1.0 / 0.0) >>= boxNum ctx
  -- `Data.Unit.unit`: a never-inspected boxed `0`.
  UnitValue, [] -> B.i32Const ctx.mod 0 >>= boxInt ctx
  -- `Record.Unsafe`: resolve the `String` key to its label id, then read / rebuild
  -- the record through the id-keyed runtime helpers.
  UnsafeGet, [ key, rec ] -> do
    rid <- internId ctx key
    er <- genAtom ctx rec
    B.call ctx.mod projHelperName [ er, rid ] B.eqref
  UnsafeHas, [ key, rec ] -> do
    rid <- internId ctx key
    er <- genAtom ctx rec
    B.call ctx.mod recHasHelperName [ er, rid ] B.i32 >>= B.i31New ctx.mod
  UnsafeSet, [ key, val, rec ] -> do
    rid <- internId ctx key
    ev <- genAtom ctx val
    er <- genAtom ctx rec
    B.call ctx.mod recSetHelperName [ er, rid, ev ] B.eqref
  UnsafeDelete, [ key, rec ] -> do
    rid <- internId ctx key
    er <- genAtom ctx rec
    B.call ctx.mod recDeleteHelperName [ er, rid ] B.eqref
  _, _ -> throwException (error "Codegen: intrinsic given an operand list of the wrong arity")
  where
  -- resolve a record-label `String` atom to its interned `i32` id via `internStr`
  internId c key = do
    ek <- genAtom c key
    B.call c.mod internStrName [ ek ] B.i32
  intBinop op a b = do
    ea <- unboxIntAtom ctx a
    eb <- unboxIntAtom ctx b
    op ctx.mod ea eb >>= boxInt ctx
  intCall2 name a b = do
    ea <- unboxIntAtom ctx a
    eb <- unboxIntAtom ctx b
    B.call ctx.mod name [ ea, eb ] B.i32 >>= boxInt ctx
  -- a binary higher-order array helper: two `eqref` operands → an `eqref` result.
  arrayHof name a b = do
    ea <- genAtom ctx a
    eb <- genAtom ctx b
    B.call ctx.mod name [ ea, eb ] B.eqref
  boolBinop op a b = do
    ea <- genAtom ctx a >>= unboxBoolExpr ctx
    eb <- genAtom ctx b >>= unboxBoolExpr ctx
    op ctx.mod ea eb >>= B.i31New ctx.mod
  numBinop op a b = do
    ea <- genAtom ctx a >>= unboxNumExpr ctx
    eb <- genAtom ctx b >>= unboxNumExpr ctx
    op ctx.mod ea eb >>= boxNum ctx
  -- per-type operand unboxing, used by `ordSelect`
  unboxIntAtom' a = unboxIntAtom ctx a
  unboxBoolAtom a = genAtom ctx a >>= unboxBoolExpr ctx
  unboxNumAtom a = genAtom ctx a >>= unboxNumExpr ctx
  -- `lt eq gt`: pick `lt`/`eq`/`gt` from the given `i32` conditions.
  ordSelectC ltCondM eqCondM lt eq gt = do
    ltCond <- ltCondM
    eqCond <- eqCondM
    ltE <- genAtom ctx lt
    eqE <- genAtom ctx eq
    gtE <- genAtom ctx gt
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
    ex <- genAtom ctx x
    ey <- genAtom ctx y
    c <- B.call ctx.mod strCmpHelperName [ ex, ey ] B.i32
    k c
