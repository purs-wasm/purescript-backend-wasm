-- | Lower the backend IR (`PureScript.Backend.Wasm.IR`) to a Binaryen module.
-- |
-- | This is the **Slice 2** code generator: Slice 0/1 (scalar Int, ADTs,
-- | pattern matching) plus **closures**, on the Wasm GC representation
-- | (ADR 0001) under the uniform `eqref` convention (ADR 0004).
-- |
-- |   * `Int` boxes as `$Int = (struct i32)`; an ADT as
-- |     `$ADT = (struct i32 (ref $Vals))`, `$Vals = (array (mut eqref))`.
-- |   * A closure is `$Clo = (struct funcref (ref $Vals))` — its code as a
-- |     generic `funcref` plus a captured-environment array. The code's type
-- |     `$Code = (func (ref $Clo) eqref -> eqref)` is built in its own recursion
-- |     group so a lifted function's own type matches it for `call_ref`.
-- |   * `RMkClosure` → `array.new_fixed` env + `ref.func` + `struct.new $Clo`;
-- |     `RApply` → read the `funcref`, `ref.cast` to `(ref $Code)`, `call_ref`;
-- |     `EnvField` → read the env array from the closure parameter (local 0).
-- |
-- | The runtime heap types are built once per module and threaded through `Ctx`.
module PureScript.Backend.Wasm.Codegen
  ( buildModule
  ) where

import Prelude

import Binaryen as B
import Data.Array as Array
import Data.Foldable (traverse_)
import Data.Maybe (Maybe(..))
import Data.Traversable (traverse)
import Effect (Effect)
import Effect.Exception (error, throwException)
import PureScript.Backend.Wasm.IR (Atom(..), Block(..), Branch(..), FuncName(..), IRFunc, Intrinsic(..), Program, Rep(..), Rhs(..), Slot(..), VarRef(..))

-- | The module's runtime heap types, plus the (non-null) reference value types
-- | derived from them for `ref.cast` targets, field reads, and signatures.
type RuntimeTypes =
  { intHt :: B.HeapType
  , valsHt :: B.HeapType
  , adtHt :: B.HeapType
  , cloHt :: B.HeapType
  , codeHt :: B.HeapType
  , refInt :: B.Type
  , refVals :: B.Type
  , refAdt :: B.Type
  , refClo :: B.Type
  , refCode :: B.Type
  }

type Ctx = { mod :: B.Module, rt :: RuntimeTypes }

-- | Build a Binaryen module from a Slice 2 IR `Program`: enable GC, build the
-- | runtime type group, add every function (`eqref` calling convention; lifted
-- | code functions take `(ref $Clo, eqref)`), then add an `i32` export wrapper
-- | per exported function.
buildModule :: Program -> Effect B.Module
buildModule prog = do
  mod <- B.createModule
  B.setFeaturesGC mod
  rt <- buildRuntimeTypes mod
  let ctx = { mod, rt }
  traverse_ (addFunc ctx) prog.funcs
  traverse_ (addExportWrapper ctx) prog.funcs
  pure mod

-- | Build the value type group (`$Vals` / `$Int` / `$ADT` / `$Clo`) and, in a
-- | separate recursion group, the closure code signature `$Code`. `$Clo` holds
-- | its code as a generic `funcref` (not `(ref $Code)`), which keeps `$Code` out
-- | of `$Clo`'s recursion group so a lifted function's structurally-equal type
-- | matches `$Code` for `call_ref`.
buildRuntimeTypes :: B.Module -> Effect RuntimeTypes
buildRuntimeTypes _ = do
  tb <- B.typeBuilderCreate 4
  B.typeBuilderSetArrayType tb 0 B.eqref true -- $Vals = (array (mut eqref))
  B.typeBuilderSetStructType tb 1 [ { ty: B.i32, mutable: false } ] -- $Int
  refValsTmp <- B.typeBuilderGetTempHeapType tb 0 >>= \h -> B.typeBuilderGetTempRefType tb h false
  B.typeBuilderSetStructType tb 2 [ { ty: B.i32, mutable: false }, { ty: refValsTmp, mutable: false } ] -- $ADT
  B.typeBuilderSetStructType tb 3 [ { ty: B.funcref, mutable: false }, { ty: refValsTmp, mutable: false } ] -- $Clo
  main <- B.typeBuilderBuildAndDispose tb 4
  case main of
    [ valsHt, intHt, adtHt, cloHt ] -> do
      let refClo = B.typeFromHeapType cloHt false
      tb2 <- B.typeBuilderCreate 1
      B.typeBuilderSetSignatureType tb2 0 (B.createType [ refClo, B.eqref ]) B.eqref
      codeGroup <- B.typeBuilderBuildAndDispose tb2 1
      case codeGroup of
        [ codeHt ] -> pure
          { intHt
          , valsHt
          , adtHt
          , cloHt
          , codeHt
          , refInt: B.typeFromHeapType intHt false
          , refVals: B.typeFromHeapType valsHt false
          , refAdt: B.typeFromHeapType adtHt false
          , refClo
          , refCode: B.typeFromHeapType codeHt false
          }
        _ -> throwException (error "Codegen: expected exactly 1 code heap type")
    _ -> throwException (error "Codegen: expected exactly 4 runtime heap types")

-- | The wasm value type for an IR representation.
repType :: Ctx -> Rep -> B.Type
repType ctx = case _ of
  I32 -> B.i32
  F64 -> B.f64
  Boxed -> B.eqref
  CloRef -> ctx.rt.refClo

funcNameStr :: FuncName -> String
funcNameStr (FuncName n) = n

-- | Add an internal function. Parameters take their declared representation (a
-- | lifted code function's first parameter is `(ref $Clo)`); `Let`-bound locals
-- | are all `eqref`. A code function added with `(ref $Clo, eqref) -> eqref`
-- | matches `$Code`, so `call_ref` against it validates.
addFunc :: Ctx -> IRFunc -> Effect Unit
addFunc ctx fn = do
  body <- genBody ctx fn.body
  let params = B.createType (repType ctx <$> fn.params)
  let varTypes = Array.replicate (fn.localCount - Array.length fn.params) B.eqref
  _ <- B.addFunction ctx.mod (funcNameStr fn.name) params B.eqref varTypes body
  pure unit

-- | Add the host-facing `i32` wrapper for an exported function (never a code
-- | function — those are not exported): box each `i32` argument, call the
-- | internal `eqref` function, unbox the result.
addExportWrapper :: Ctx -> IRFunc -> Effect Unit
addExportWrapper ctx fn = case fn.export of
  Nothing -> pure unit
  Just external -> do
    let indices = Array.mapWithIndex (\i _ -> i) fn.params
    boxedArgs <- traverse (\i -> B.localGet ctx.mod i B.i32 >>= boxInt ctx) indices
    result <- B.call ctx.mod (funcNameStr fn.name) boxedArgs B.eqref
    unboxed <- unboxIntExpr ctx result
    let params = B.createType (const B.i32 <$> fn.params)
    let wrapperName = funcNameStr fn.name <> "$export"
    _ <- B.addFunction ctx.mod wrapperName params B.i32 [] unboxed
    _ <- B.addFunctionExport ctx.mod wrapperName external
    pure unit

-- | Box an `i32` expression into an `eqref` (`struct.new $Int`).
boxInt :: Ctx -> B.Expression -> Effect B.Expression
boxInt ctx e = B.structNew ctx.mod ctx.rt.intHt [ e ]

-- | Unbox an `eqref` expression to `i32` (`ref.cast` then `struct.get 0`).
unboxIntExpr :: Ctx -> B.Expression -> Effect B.Expression
unboxIntExpr ctx e = do
  c <- B.refCast ctx.mod e ctx.rt.refInt
  B.structGet ctx.mod 0 c B.i32 false

-- | Generate a function body. `Let`s become `local.set` statements sequenced in
-- | a `block` whose value is the tail (`Ret` atom or `Switch`).
genBody :: Ctx -> Block -> Effect B.Expression
genBody ctx = go []
  where
  go statements = case _ of
    Ret atom -> seal statements =<< genAtom ctx atom
    Switch scrutAtom branches dflt -> seal statements =<< genSwitch ctx scrutAtom branches dflt
    Let (Slot index) _ rhs k -> do
      e <- genRhs ctx rhs
      stmt <- B.localSet ctx.mod index e
      go (Array.snoc statements stmt) k
  seal statements value =
    if Array.null statements then pure value
    else B.block ctx.mod (Array.snoc statements value) B.eqref

-- | A `Switch` becomes a chain of `if (tag == k) <branch> else …`, ending in the
-- | default block or `unreachable`. The tag is read afresh per comparison.
genSwitch :: Ctx -> Atom -> Array Branch -> Maybe Block -> Effect B.Expression
genSwitch ctx scrutAtom branches dflt = chain branches
  where
  readTag = do
    s <- genAtom ctx scrutAtom
    c <- B.refCast ctx.mod s ctx.rt.refAdt
    B.structGet ctx.mod 0 c B.i32 false
  chain bs = case Array.uncons bs of
    Nothing -> case dflt of
      Just d -> genBody ctx d
      Nothing -> B.unreachable ctx.mod
    Just { head: Branch tag body, tail } -> do
      tagExpr <- readTag
      k <- B.i32Const ctx.mod tag
      cond <- B.i32Eq ctx.mod tagExpr k
      thenE <- genBody ctx body
      elseE <- chain tail
      B.if_ ctx.mod cond thenE elseE

genAtom :: Ctx -> Atom -> Effect B.Expression
genAtom ctx = case _ of
  ALitInt n -> B.i32Const ctx.mod n >>= boxInt ctx
  AVar (Local (Slot index)) -> B.localGet ctx.mod index B.eqref
  -- A captured variable: read the env array from the closure (local 0, the only
  -- `(ref $Clo)`-typed local — `EnvField` appears only in lifted code functions)
  -- and index into it.
  AVar (EnvField i) -> do
    clo <- B.localGet ctx.mod 0 ctx.rt.refClo
    env <- B.structGet ctx.mod 1 clo ctx.rt.refVals false
    idx <- B.i32Const ctx.mod i
    B.arrayGet ctx.mod env idx B.eqref false

genRhs :: Ctx -> Rhs -> Effect B.Expression
genRhs ctx = case _ of
  RAtom atom -> genAtom ctx atom
  RPrim intr args -> genPrim ctx intr args
  RCallKnown name args -> do
    operands <- traverse (genAtom ctx) args
    B.call ctx.mod (funcNameStr name) operands B.eqref
  RMkData tag fields -> do
    fieldEs <- traverse (genAtom ctx) fields
    vals <- B.arrayNewFixed ctx.mod ctx.rt.valsHt fieldEs
    tagE <- B.i32Const ctx.mod tag
    B.structNew ctx.mod ctx.rt.adtHt [ tagE, vals ]
  RProjField adtAtom index -> do
    a <- genAtom ctx adtAtom
    c <- B.refCast ctx.mod a ctx.rt.refAdt
    vals <- B.structGet ctx.mod 1 c ctx.rt.refVals false
    idx <- B.i32Const ctx.mod index
    B.arrayGet ctx.mod vals idx B.eqref false
  RMkClosure codeName captures -> do
    capEs <- traverse (genAtom ctx) captures
    envArr <- B.arrayNewFixed ctx.mod ctx.rt.valsHt capEs
    fref <- B.refFunc ctx.mod (funcNameStr codeName) ctx.rt.codeHt
    B.structNew ctx.mod ctx.rt.cloHt [ fref, envArr ]
  -- Apply an arity-1 closure: read its funcref, cast to `(ref $Code)`, and
  -- `call_ref` with the closure itself plus the argument. (A multi-argument
  -- application is a chain of these, produced by the lowering.)
  RApply headAtom argAtom -> do
    cloForCode <- genAtom ctx headAtom >>= \h -> B.refCast ctx.mod h ctx.rt.refClo
    fref <- B.structGet ctx.mod 0 cloForCode B.funcref false
    codeF <- B.refCast ctx.mod fref ctx.rt.refCode
    cloOperand <- genAtom ctx headAtom >>= \h -> B.refCast ctx.mod h ctx.rt.refClo
    argE <- genAtom ctx argAtom
    B.callRef ctx.mod codeF [ cloOperand, argE ] ctx.rt.codeHt

-- | Slice 0/1 intrinsics are all binary `i32` ops; operands are unboxed, the op
-- | applied, and the result re-boxed. The lowering guarantees the arity.
genPrim :: Ctx -> Intrinsic -> Array Atom -> Effect B.Expression
genPrim ctx intr = case _ of
  [ a, b ] -> do
    ea <- unboxIntAtom ctx a
    eb <- unboxIntAtom ctx b
    r <- case intr of
      IntAdd -> B.i32Add ctx.mod ea eb
      IntSub -> B.i32Sub ctx.mod ea eb
      IntMul -> B.i32Mul ctx.mod ea eb
    boxInt ctx r
  _ -> throwException (error "Codegen: binary intrinsic given a non-binary operand list")

unboxIntAtom :: Ctx -> Atom -> Effect B.Expression
unboxIntAtom ctx atom = genAtom ctx atom >>= unboxIntExpr ctx
