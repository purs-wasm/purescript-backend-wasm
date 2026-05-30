-- | Lower the backend IR (`PureScript.Backend.Wasm.IR`) to a Binaryen module.
-- |
-- | This is the **Slice 1** code generator. It realises the uniform `eqref`
-- | calling convention (ADR 0004) on the Wasm GC representation (ADR 0001):
-- |
-- |   * every IR value is a boxed `eqref`; internal functions take and return
-- |     `eqref`, and the host-facing `i32` interface is restored by per-export
-- |     wrapper functions that box arguments and unbox the result;
-- |   * `Int` is boxed as `$Int = (struct i32)`, an ADT as
-- |     `$ADT = (struct i32 (ref $Vals))` with `$Vals = (array (mut eqref))`;
-- |   * a `Switch` reads the scrutinee's tag (`struct.get 0`) and dispatches
-- |     through an `if`/`i32.eq` chain ending in `unreachable`.
-- |
-- | The runtime heap types are built once per module via Binaryen's
-- | `TypeBuilder` and threaded through codegen in `Ctx`.
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
import PureScript.Backend.Wasm.IR (Atom(..), Block(..), Branch(..), FuncName(..), IRFunc, Intrinsic(..), Program, Rhs(..), Slot(..), VarRef(..))

-- | The module's runtime heap types, plus the (non-null) reference value types
-- | derived from them for `ref.cast` targets and field reads.
type RuntimeTypes =
  { intHt :: B.HeapType
  , valsHt :: B.HeapType
  , adtHt :: B.HeapType
  , refInt :: B.Type
  , refVals :: B.Type
  , refAdt :: B.Type
  }

type Ctx = { mod :: B.Module, rt :: RuntimeTypes }

-- | Build a Binaryen module from a Slice 1 IR `Program`: enable GC, build the
-- | runtime type group, add every function (as an `eqref` function), then add an
-- | `i32` export wrapper for each exported function.
buildModule :: Program -> Effect B.Module
buildModule prog = do
  mod <- B.createModule
  B.setFeaturesGC mod
  rt <- buildRuntimeTypes mod
  let ctx = { mod, rt }
  traverse_ (addFunc ctx) prog.funcs
  traverse_ (addExportWrapper ctx) prog.funcs
  pure mod

-- | Build the recursive type group `$Vals` / `$Int` / `$ADT` (ADR 0001) once.
buildRuntimeTypes :: B.Module -> Effect RuntimeTypes
buildRuntimeTypes _ = do
  tb <- B.typeBuilderCreate 3
  B.typeBuilderSetArrayType tb 0 B.eqref true -- $Vals = (array (mut eqref))
  B.typeBuilderSetStructType tb 1 [ { ty: B.i32, mutable: false } ] -- $Int = (struct i32)
  valsTmp <- B.typeBuilderGetTempHeapType tb 0
  refValsTmp <- B.typeBuilderGetTempRefType tb valsTmp false
  -- $ADT = (struct i32 (ref $Vals)) — references $Vals, so it is built together
  -- with it in one rec group.
  B.typeBuilderSetStructType tb 2 [ { ty: B.i32, mutable: false }, { ty: refValsTmp, mutable: false } ]
  hts <- B.typeBuilderBuildAndDispose tb 3
  case hts of
    [ valsHt, intHt, adtHt ] -> pure
      { intHt
      , valsHt
      , adtHt
      , refInt: B.typeFromHeapType intHt false
      , refVals: B.typeFromHeapType valsHt false
      , refAdt: B.typeFromHeapType adtHt false
      }
    _ -> throwException (error "Codegen: expected exactly 3 runtime heap types")

funcNameStr :: FuncName -> String
funcNameStr (FuncName n) = n

-- | Add an internal function: all parameters and the result are `eqref`. Locals
-- | beyond the parameters (the `Let`-bound slots) are declared `eqref`.
addFunc :: Ctx -> IRFunc -> Effect Unit
addFunc ctx fn = do
  body <- genBody ctx fn.body
  let params = B.createType (const B.eqref <$> fn.params)
  let varTypes = Array.replicate (fn.localCount - Array.length fn.params) B.eqref
  _ <- B.addFunction ctx.mod (funcNameStr fn.name) params B.eqref varTypes body
  pure unit

-- | Add the host-facing `i32` wrapper for an exported function: box each `i32`
-- | argument, call the internal `eqref` function, and unbox its result.
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
-- | default block or `unreachable`. The tag is read afresh per comparison (the
-- | scrutinee is a cheap `local.get`), which avoids reserving an extra local.
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

-- | Slice 1 intrinsics are all binary `i32` ops; operands are unboxed, the op is
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
