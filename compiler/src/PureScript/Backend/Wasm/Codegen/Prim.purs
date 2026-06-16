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
import Data.Array as Array
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Exception (error, throwException)
import PureScript.Backend.Wasm.Codegen.Imports (applyCloHelperName, arrayConcatHelperName, arrayNewHelperName, arraySetHelperName, counterGlobalName, forEHelperName, foreachEHelperName, intDegreeHelperName, intDivHelperName, intModHelperName, internStrName, projHelperName, recDeleteHelperName, recHasHelperName, recSetHelperName, refModifyHelperName, refNewHelperName, refNewWithSelfHelperName, refReadHelperName, refWriteHelperName, strCmpHelperName, strConcatHelperName, strEqHelperName, strNewHelperName, strSetByteHelperName, untilEHelperName, whileEHelperName)
import PureScript.Backend.Wasm.Codegen.RuntimeTypes (Ctx)
import PureScript.Backend.Wasm.Codegen.Value (boxInt, genAtom, genAtomAs, strBytes, unboxBoolExpr)
import PureScript.Backend.Wasm.Lower.IR (Atom(..), Rep(..))
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
  IntLt, [ a, b ] -> do
    ea <- intArg a
    eb <- intArg b
    B.i32LtS ctx.mod ea eb >>= B.i31New ctx.mod
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
  StrEq, [ a, b ] -> do
    ea <- genAtomAs ctx Boxed a
    eb <- genAtomAs ctx Boxed b
    B.call ctx.mod strEqHelperName [ ea, eb ] B.i32 >>= B.i31New ctx.mod
  -- `Wasm.String.byteAt s i`: read the i-th UTF-8 byte (0-255), inlined like `StrLen` (no helper).
  StrByteAt, [ a, i ] -> do
    bytes <- strBytes ctx a
    idx <- intArg i
    B.arrayGet ctx.mod bytes idx B.i32 false
  -- `Wasm.Char.toCodePoint` / `fromCodePoint`: identity on the i32 code point (ADR 0030).
  CharCodeId, [ x ] -> intArg x
  -- `Wasm.String.unsafeNew n`: allocate a zeroed `$Str` of `n` bytes.
  StrNew, [ n ] -> do
    len <- intArg n
    B.call ctx.mod strNewHelperName [ len ] B.eqref
  -- `Wasm.String.unsafeSetByte s i b`: write byte `b` at `i` (mutating in place), then return `s`,
  -- so a builder loop threads the string through (keeping the write live and ordered) — mirrors
  -- `ArraySet`. The string operand is a local atom, so re-reading it is just a `local.get`.
  StrSetByte, [ s, i, b ] -> do
    str <- genAtomAs ctx Boxed s
    idx <- intArg i
    byte <- intArg b
    setE <- B.call ctx.mod strSetByteHelperName [ str, idx, byte ] B.none
    strAgain <- genAtomAs ctx Boxed s
    B.block ctx.mod [ setE, strAgain ] B.eqref
  -- Array a -> Int: the element count
  ArrayLength, [ a ] -> do
    arr <- genAtomAs ctx Boxed a >>= \e -> B.refCast ctx.mod e ctx.rt.refVals
    B.arrayLen ctx.mod arr
  -- Array a -> Int -> a: read the (already-`eqref`) element at the index
  ArrayIndex, [ a, i ] -> do
    arr <- genAtomAs ctx Boxed a >>= \e -> B.refCast ctx.mod e ctx.rt.refVals
    idx <- intArg i
    B.arrayGet ctx.mod arr idx B.eqref false
  -- `Wasm.Array.unsafeNew n`: allocate a length-`n` `$Vals` (elements null until filled).
  ArrayNew, [ n ] -> do
    len <- intArg n
    B.call ctx.mod arrayNewHelperName [ len ] B.eqref
  -- `Wasm.Array.unsafeSet arr i v`: write `v` at `i` (mutating in place), then return `arr`,
  -- so the builder loop threads the array through (keeping the write live and ordered). The
  -- array operand is a local atom, so re-reading it for the block result is just a `local.get`.
  ArraySet, [ a, i, v ] -> do
    arr <- genAtomAs ctx Boxed a
    idx <- intArg i
    val <- genAtomAs ctx Boxed v
    setE <- B.call ctx.mod arraySetHelperName [ arr, idx, val ] B.none
    arrAgain <- genAtomAs ctx Boxed a
    B.block ctx.mod [ setE, arrAgain ] B.eqref
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
  -- `Effect.Ref` native cell ops (ADR 0017): a `$Ref` struct touched only by the
  -- runtime helpers. The trailing `Effect` perform-unit operand is ignored (`_`).
  RefNew, [ v, _ ] -> do
    ev <- genAtomAs ctx Boxed v
    B.call ctx.mod refNewHelperName [ ev ] B.eqref
  RefRead, [ r, _ ] -> do
    er <- genAtomAs ctx Boxed r
    B.call ctx.mod refReadHelperName [ er ] B.eqref
  RefWrite, [ v, r, _ ] -> do
    ev <- genAtomAs ctx Boxed v
    er <- genAtomAs ctx Boxed r
    B.call ctx.mod refWriteHelperName [ er, ev ] B.i32
  RefNewWithSelf, [ f, _ ] -> do
    ef <- genAtomAs ctx Boxed f
    B.call ctx.mod refNewWithSelfHelperName [ ef ] B.eqref
  -- modifyImpl f r (perform-unit ignored): read cell, apply `f`, store the record's
  -- `state`, return its `value`. The `state`/`value` label ids are resolved through the
  -- emitted `internStr` (the same id space the record's fields use).
  RefModify, [ f, r, _ ] -> do
    er <- genAtomAs ctx Boxed r
    ef <- genAtomAs ctx Boxed f
    sId <- genAtom ctx (ALitString "state") >>= \s -> B.call ctx.mod internStrName [ s ] B.i32
    vId <- genAtom ctx (ALitString "value") >>= \s -> B.call ctx.mod internStrName [ s ] B.i32
    B.call ctx.mod refModifyHelperName [ er, ef, sId, vId ] B.eqref
  -- `effect` control-flow loops (ADR 0018): native wasm loops via runtime helpers; the
  -- trailing perform-unit operand is dropped (`_`).
  ForE, [ lo, hi, f, _ ] -> do
    elo <- genAtomAs ctx I32 lo
    ehi <- genAtomAs ctx I32 hi
    ef <- genAtomAs ctx Boxed f
    B.call ctx.mod forEHelperName [ elo, ehi, ef ] B.i32
  ForeachE, [ arr, f, _ ] -> do
    earr <- genAtomAs ctx Boxed arr
    ef <- genAtomAs ctx Boxed f
    B.call ctx.mod foreachEHelperName [ earr, ef ] B.i32
  WhileE, [ cond, body, _ ] -> do
    ec <- genAtomAs ctx Boxed cond
    eb <- genAtomAs ctx Boxed body
    B.call ctx.mod whileEHelperName [ ec, eb ] B.i32
  UntilE, [ act, _ ] -> do
    ea <- genAtomAs ctx Boxed act
    B.call ctx.mod untilEHelperName [ ea ] B.i32
  -- `Effect.Uncurried` (ADR 0018): `EffectFnN` is the curried closure, so `mkEffectFnN` is
  -- identity; `runEffectFnN g x₁…x_N` applies `g` to the N args (the result is the `Effect`).
  MkEffectFn, [ x ] -> genAtomAs ctx Boxed x
  RunEffectFn, args' -> case Array.uncons args' of
    Just { head: g, tail: xs } -> do
      g0 <- genAtomAs ctx Boxed g
      applyEffectFnArgs g0 xs
    Nothing -> throwException (error "Codegen: runEffectFn with no operands")
  -- `_unsafePartial f` = `f unit`: apply the thunk to the (erased `Partial` dict) unit
  UnsafePartial, [ f ] -> do
    f0 <- genAtomAs ctx Boxed f
    unitE <- B.i32Const ctx.mod 0 >>= B.i31New ctx.mod
    B.call ctx.mod applyCloHelperName [ f0, unitE ] B.eqref
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
  -- `Data.Int.Bits`: single i32 instructions. `IntShr` is arithmetic
  -- (sign-propagating, JS `>>`); `IntZshr` is logical (zero-fill, JS `>>>`).
  IntAnd, [ a, b ] -> intBinop B.i32And a b
  IntOr, [ a, b ] -> intBinop B.i32Or a b
  IntXor, [ a, b ] -> intBinop B.i32Xor a b
  IntShl, [ a, b ] -> intBinop B.i32Shl a b
  IntShr, [ a, b ] -> intBinop B.i32ShrS a b
  IntZshr, [ a, b ] -> intBinop B.i32ShrU a b
  IntComplement, [ a ] -> do
    ea <- intArg a
    m1 <- B.i32Const ctx.mod (-1)
    B.i32Xor ctx.mod ea m1
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
  -- apply a closure expression to each remaining argument atom in turn (the curried
  -- application `runEffectFnN` performs), via the runtime `applyClo` trampoline (ADR 0018)
  applyEffectFnArgs acc xs = case Array.uncons xs of
    Nothing -> pure acc
    Just { head: x, tail } -> do
      ex <- genAtomAs ctx Boxed x
      acc' <- B.call ctx.mod applyCloHelperName [ acc, ex ] B.eqref
      applyEffectFnArgs acc' tail
  intBinop op a b = do
    ea <- intArg a
    eb <- intArg b
    op ctx.mod ea eb
  intCall2 name a b = do
    ea <- intArg a
    eb <- intArg b
    B.call ctx.mod name [ ea, eb ] B.i32
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
