-- | Lower the backend IR (`PureScript.Backend.Wasm.IR`) to a Binaryen module, on
-- | the Wasm GC representation (ADR 0001) under the uniform `eqref` convention
-- | (ADR 0004).
-- |
-- |   * Scalars box as structs — `$Int = (struct i32)` (also `Char`),
-- |     `$Num = (struct f64)` — while `Boolean` is an unboxed `i31ref`. An ADT is
-- |     `$ADT = (struct i32 (ref $Vals))`, `$Vals = (array (mut eqref))`; a record
-- |     (and so a type-class dictionary) is `$Rec = (struct (ref $LabelIds) (ref $Vals))`.
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
import Data.Enum (fromEnum)
import Data.Foldable (traverse_)
import Data.Int.Bits (and, shr)
import Data.Maybe (Maybe(..))
import Data.String.CodePoints (toCodePointArray)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Exception (error, throwException)
import PureScript.Backend.Wasm.Intrinsics (Intrinsic(..))
import PureScript.Backend.Wasm.IR (Atom(..), AnfExpr(..), Branch(..), FuncName(..), IRFunc, LitBranch(..), LitPat(..), Program, RecBind(..), Rep(..), Rhs(..), Slot(..), VarRef(..))

-- | The module's runtime heap types, plus the (non-null) reference value types
-- | derived from them for `ref.cast` targets, field reads, and signatures.
type RuntimeTypes =
  { intHt :: B.HeapType
  , valsHt :: B.HeapType
  , adtHt :: B.HeapType
  , cloHt :: B.HeapType
  , labelIdsHt :: B.HeapType
  , recHt :: B.HeapType
  , numHt :: B.HeapType
  , bytesHt :: B.HeapType
  , strHt :: B.HeapType
  , codeHt :: B.HeapType
  , refInt :: B.Type
  , refVals :: B.Type
  , refAdt :: B.Type
  , refClo :: B.Type
  , refLabelIds :: B.Type
  , refRec :: B.Type
  , refNum :: B.Type
  , refBytes :: B.Type
  , refStr :: B.Type
  , refCode :: B.Type
  }

-- | `params` is the representation of the function currently being generated,
-- | so a `local.get` uses the slot's actual type (a code function's local 0 is
-- | `(ref $Clo)`, not `eqref`).
type Ctx = { mod :: B.Module, rt :: RuntimeTypes, params :: Array Rep }

-- | Build a Binaryen module from the IR `Program`: enable GC, build the
-- | runtime type group, add every function (`eqref` calling convention; lifted
-- | code functions take `(ref $Clo, eqref)`), then add an `i32` export wrapper
-- | per exported function.
buildModule :: Program -> Effect B.Module
buildModule prog = do
  mod <- B.createModule
  B.setFeaturesGC mod
  rt <- buildRuntimeTypes mod
  let ctx = { mod, rt, params: [] }
  importRuntime ctx
  traverse_ (addFunc ctx) prog.funcs
  traverse_ (addExportWrapper ctx) prog.funcs
  pure mod

-- | The module name under which generated code imports the shared runtime
-- | (ADR 0010). Satisfied by instantiating `runtime.wasm` (tests) or by
-- | `wasm-merge` (the single-file build).
runtimeModuleName :: String
runtimeModuleName = "rt"

-- | Declare the imports for the shared runtime helpers (now defined in
-- | `runtime.wat`, ADR 0010). The internal names (e.g. `$rt.strEq`) are unchanged,
-- | so existing `B.call` sites resolve to the imports transparently. The boundary
-- | uses only `eqref`/`i32` (ADR 0004), so no concrete GC type crosses it.
importRuntime :: Ctx -> Effect Unit
importRuntime ctx = do
  let imp name base params result = B.addFunctionImport ctx.mod name runtimeModuleName base (B.createType params) result
  imp projHelperName "proj" [ B.eqref, B.i32 ] B.eqref
  imp strEqHelperName "strEq" [ B.eqref, B.eqref ] B.i32
  imp strConcatHelperName "strConcat" [ B.eqref, B.eqref ] B.eqref
  imp arrayConcatHelperName "arrayConcat" [ B.eqref, B.eqref ] B.eqref
  imp showIntHelperName "showInt" [ B.i32 ] B.eqref
  imp intModHelperName "intMod" [ B.i32, B.i32 ] B.i32
  imp intDivHelperName "intDiv" [ B.i32, B.i32 ] B.i32
  imp intDegreeHelperName "intDegree" [ B.i32 ] B.i32

-- | The shared record/dictionary projection helper (see `addProjHelper`).
projHelperName :: String
projHelperName = "$rt.proj"

-- | The shared string byte-equality helper (see `addStrEqHelper`): returns `i32`
-- | `1`/`0`.
strEqHelperName :: String
strEqHelperName = "$rt.strEq"

-- | The shared string concatenation helper (see `addStrConcatHelper`).
strConcatHelperName :: String
strConcatHelperName = "$rt.strConcat"

-- | The shared array concatenation helper (see `addArrayConcatHelper`).
arrayConcatHelperName :: String
arrayConcatHelperName = "$rt.arrayConcat"

-- | The shared `Int` decimal-rendering helper (see `addShowIntHelper`).
showIntHelperName :: String
showIntHelperName = "$rt.showInt"

-- | The shared Euclidean `Int` division/remainder/degree helpers (see
-- | `addIntEuclidHelpers`).
intModHelperName :: String
intModHelperName = "$rt.intMod"

intDivHelperName :: String
intDivHelperName = "$rt.intDiv"

intDegreeHelperName :: String
intDegreeHelperName = "$rt.intDegree"

-- | Build the value type group (`$Vals` / `$Int` / `$ADT` / `$Clo`) and, in a
-- | separate recursion group, the closure code signature `$Code`. `$Clo` holds
-- | its code as a generic `funcref` (not `(ref $Code)`), which keeps `$Code` out
-- | of `$Clo`'s recursion group so a lifted function's structurally-equal type
-- | matches `$Code` for `call_ref`.
buildRuntimeTypes :: B.Module -> Effect RuntimeTypes
buildRuntimeTypes _ = do
  tb <- B.typeBuilderCreate 9
  B.typeBuilderSetArrayType tb 0 B.eqref true -- $Vals = (array (mut eqref))
  B.typeBuilderSetStructType tb 1 [ { ty: B.i32, mutable: false } ] -- $Int (also $Char)
  refValsTmp <- B.typeBuilderGetTempHeapType tb 0 >>= \h -> B.typeBuilderGetTempRefType tb h false
  B.typeBuilderSetStructType tb 2 [ { ty: B.i32, mutable: false }, { ty: refValsTmp, mutable: false } ] -- $ADT
  B.typeBuilderSetStructType tb 3 [ { ty: B.funcref, mutable: false }, { ty: refValsTmp, mutable: false } ] -- $Clo
  B.typeBuilderSetArrayType tb 4 B.i32 false -- $LabelIds = (array i32), interned record labels
  refLabelIdsTmp <- B.typeBuilderGetTempHeapType tb 4 >>= \h -> B.typeBuilderGetTempRefType tb h false
  -- $Rec = (struct (ref $LabelIds) (ref $Vals)) — parallel label-id / value arrays
  B.typeBuilderSetStructType tb 5 [ { ty: refLabelIdsTmp, mutable: false }, { ty: refValsTmp, mutable: false } ]
  B.typeBuilderSetStructType tb 6 [ { ty: B.f64, mutable: false } ] -- $Num = (struct f64)
  B.typeBuilderSetArrayType tb 7 B.i32 true -- $Bytes = (array (mut i8)); built with i32 operands
  refBytesTmp <- B.typeBuilderGetTempHeapType tb 7 >>= \h -> B.typeBuilderGetTempRefType tb h false
  B.typeBuilderSetStructType tb 8 [ { ty: refBytesTmp, mutable: false } ] -- $Str = (struct (ref $Bytes))
  main <- B.typeBuilderBuildAndDispose tb 9
  case main of
    [ valsHt, intHt, adtHt, cloHt, labelIdsHt, recHt, numHt, bytesHt, strHt ] -> do
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
          , labelIdsHt
          , recHt
          , numHt
          , bytesHt
          , strHt
          , codeHt
          , refInt: B.typeFromHeapType intHt false
          , refVals: B.typeFromHeapType valsHt false
          , refAdt: B.typeFromHeapType adtHt false
          , refClo
          , refLabelIds: B.typeFromHeapType labelIdsHt false
          , refRec: B.typeFromHeapType recHt false
          , refNum: B.typeFromHeapType numHt false
          , refBytes: B.typeFromHeapType bytesHt false
          , refStr: B.typeFromHeapType strHt false
          , refCode: B.typeFromHeapType codeHt false
          }
        _ -> throwException (error "Codegen: expected exactly 1 code heap type")
    _ -> throwException (error "Codegen: expected exactly 9 runtime heap types")

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
  body <- genBody (ctx { params = fn.params }) fn.body
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

-- | The `(ref $Bytes)` byte array of a `String` atom (`ref.cast $Str` then
-- | `struct.get 0`).
strBytes :: Ctx -> Atom -> Effect B.Expression
strBytes ctx atom = do
  s <- genAtom ctx atom >>= \e -> B.refCast ctx.mod e ctx.rt.refStr
  B.structGet ctx.mod 0 s ctx.rt.refBytes false

-- | Encode a `String` to its UTF-8 bytes (the elements of a `$Bytes` literal).
utf8Bytes :: String -> Array Int
utf8Bytes = toCodePointArray >=> (encode <<< fromEnum)
  where
  encode cp
    | cp < 0x80 = [ cp ]
    | cp < 0x800 =
        [ 0xC0 + shr cp 6, cont cp 0 ]
    | cp < 0x10000 =
        [ 0xE0 + shr cp 12, cont cp 6, cont cp 0 ]
    | otherwise =
        [ 0xF0 + shr cp 18, cont cp 12, cont cp 6, cont cp 0 ]
  cont cp n = 0x80 + (and (shr cp n) 0x3F)

-- | Box an `i32` expression into an `eqref` (`struct.new $Int`).
boxInt :: Ctx -> B.Expression -> Effect B.Expression
boxInt ctx e = B.structNew ctx.mod ctx.rt.intHt [ e ]

-- | Unbox an `eqref` expression to `i32` (`ref.cast` then `struct.get 0`).
unboxIntExpr :: Ctx -> B.Expression -> Effect B.Expression
unboxIntExpr ctx e = do
  c <- B.refCast ctx.mod e ctx.rt.refInt
  B.structGet ctx.mod 0 c B.i32 false

-- | Box an `f64` expression into an `eqref` (`struct.new $Num`).
boxNum :: Ctx -> B.Expression -> Effect B.Expression
boxNum ctx e = B.structNew ctx.mod ctx.rt.numHt [ e ]

-- | Unbox an `eqref` expression to `f64` (`ref.cast $Num` then `struct.get 0`).
unboxNumExpr :: Ctx -> B.Expression -> Effect B.Expression
unboxNumExpr ctx e = do
  c <- B.refCast ctx.mod e ctx.rt.refNum
  B.structGet ctx.mod 0 c B.f64 false

-- | Box a `Boolean` as an `i31ref` (`true` = 1, `false` = 0; ADR 0001).
boxBool :: Ctx -> Boolean -> Effect B.Expression
boxBool ctx b = B.i32Const ctx.mod (if b then 1 else 0) >>= B.i31New ctx.mod

-- | Unbox an `eqref` known to hold an `i31` Boolean to its `i32` (`ref.cast`
-- | `i31ref` then `i31.get_s`).
unboxBoolExpr :: Ctx -> B.Expression -> Effect B.Expression
unboxBoolExpr ctx e = do
  c <- B.refCast ctx.mod e B.i31ref
  B.i31GetS ctx.mod c

-- | Generate a function body. `Let`s become `local.set` statements sequenced in
-- | a `block` whose value is the tail (`Return` atom or `Switch`).
genBody :: Ctx -> AnfExpr -> Effect B.Expression
genBody ctx = go []
  where
  go statements = case _ of
    Return atom -> seal statements =<< genAtom ctx atom
    Switch scrutAtom branches dflt -> seal statements =<< genSwitch ctx scrutAtom branches dflt
    LitSwitch scrutAtom branches dflt -> seal statements =<< genLitSwitch ctx scrutAtom branches dflt
    Let (Slot index) _ rhs k -> do
      e <- genRhs ctx rhs
      stmt <- B.localSet ctx.mod index e
      go (Array.snoc statements stmt) k
    LetRec recBinds k -> do
      let groupSlots = map (\(RecBind (Slot s) _ _) -> s) recBinds
      allocs <- traverse (allocRecClosure ctx groupSlots) recBinds
      patches <- traverse (patchRecClosure ctx groupSlots) recBinds
      go (statements <> allocs <> Array.concat patches) k
  seal statements value =
    if Array.null statements then pure value
    else B.block ctx.mod (Array.snoc statements value) B.eqref

-- | Is this captured atom a forward reference to another member of the same
-- | `LetRec` group (and thus a slot to back-patch)?
isGroupRef :: Array Int -> Atom -> Boolean
isGroupRef groupSlots = case _ of
  AVar (Local (Slot s)) -> Array.elem s groupSlots
  _ -> false

-- | Allocate one recursive closure, with sibling-referencing env slots left as a
-- | placeholder (a boxed 0, overwritten by `patchRecClosure`); returns the
-- | `local.set` of the closure into its slot.
allocRecClosure :: Ctx -> Array Int -> RecBind -> Effect B.Expression
allocRecClosure ctx groupSlots (RecBind (Slot slot) codeName env) = do
  envEls <- traverse element env
  envArr <- B.arrayNewFixed ctx.mod ctx.rt.valsHt envEls
  fref <- B.refFunc ctx.mod (funcNameStr codeName) ctx.rt.codeHt
  clo <- B.structNew ctx.mod ctx.rt.cloHt [ fref, envArr ]
  B.localSet ctx.mod slot clo
  where
  element atom
    | isGroupRef groupSlots atom = B.i32Const ctx.mod 0 >>= boxInt ctx
    | otherwise = genAtom ctx atom

-- | Back-patch a recursive closure's environment: for every slot that referred
-- | to a sibling (now allocated), `array.set` the real closure into place.
patchRecClosure :: Ctx -> Array Int -> RecBind -> Effect (Array B.Expression)
patchRecClosure ctx groupSlots (RecBind (Slot slot) _ env) =
  traverse patch (Array.filter (\(Tuple _ a) -> isGroupRef groupSlots a) (Array.mapWithIndex Tuple env))
  where
  patch (Tuple index atom) = do
    -- the group slot is an `eqref` local; narrow it to `(ref $Clo)` to reach the
    -- environment array
    clo <- B.localGet ctx.mod slot B.eqref >>= \c -> B.refCast ctx.mod c ctx.rt.refClo
    envArr <- B.structGet ctx.mod 1 clo ctx.rt.refVals false
    idx <- B.i32Const ctx.mod index
    val <- genAtom ctx atom
    B.arraySet ctx.mod envArr idx val

-- | A `Switch` becomes a chain of `if (tag == k) <branch> else …`, ending in the
-- | default block or `unreachable`. The tag is read afresh per comparison.
genSwitch :: Ctx -> Atom -> Array Branch -> Maybe AnfExpr -> Effect B.Expression
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

-- | A `LitSwitch` becomes a chain of `if (scrutinee == literal) <branch> else …`.
-- | The equality test unboxes the scrutinee per literal kind: `Int`/`Char` and
-- | `Boolean` compare as `i32`, `Number` as `f64`.
genLitSwitch :: Ctx -> Atom -> Array LitBranch -> Maybe AnfExpr -> Effect B.Expression
genLitSwitch ctx scrutAtom branches dflt = chain branches
  where
  chain bs = case Array.uncons bs of
    Nothing -> case dflt of
      Just d -> genBody ctx d
      Nothing -> B.unreachable ctx.mod
    Just { head: LitBranch pat body, tail } -> do
      cond <- litTest pat
      thenE <- genBody ctx body
      elseE <- chain tail
      B.if_ ctx.mod cond thenE elseE
  litTest = case _ of
    PInt n -> do
      s <- unboxIntAtom ctx scrutAtom
      k <- B.i32Const ctx.mod n
      B.i32Eq ctx.mod s k
    PBoolean b -> do
      s <- genAtom ctx scrutAtom >>= unboxBoolExpr ctx
      k <- B.i32Const ctx.mod (if b then 1 else 0)
      B.i32Eq ctx.mod s k
    PNumber n -> do
      s <- genAtom ctx scrutAtom >>= unboxNumExpr ctx
      k <- B.f64Const ctx.mod n
      B.f64Eq ctx.mod s k
    -- the scrutinee equals the literal string iff the byte-equality helper says
    -- so (a non-zero `i32`), which serves directly as the `if` condition
    PString str -> do
      s <- genAtom ctx scrutAtom
      lit <- genAtom ctx (ALitString str)
      B.call ctx.mod strEqHelperName [ s, lit ] B.i32

-- | The wasm type of local `i` in the current function: a parameter takes its
-- | declared representation (local 0 of a code function is `(ref $Clo)`), while
-- | `Let`-bound locals are always `eqref`.
localType :: Ctx -> Int -> B.Type
localType ctx i = case Array.index ctx.params i of
  Just rep -> repType ctx rep
  Nothing -> B.eqref

genAtom :: Ctx -> Atom -> Effect B.Expression
genAtom ctx = case _ of
  ALitInt n -> B.i32Const ctx.mod n >>= boxInt ctx
  ALitNumber n -> B.f64Const ctx.mod n >>= boxNum ctx
  ALitBoolean b -> boxBool ctx b
  ALitString s -> do
    byteEs <- traverse (B.i32Const ctx.mod) (utf8Bytes s)
    bytes <- B.arrayNewFixed ctx.mod ctx.rt.bytesHt byteEs
    B.structNew ctx.mod ctx.rt.strHt [ bytes ]
  AVar (Local (Slot index)) -> B.localGet ctx.mod index (localType ctx index)
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
  -- A record (a type-class dictionary, after newtype erasure) is parallel
  -- label-id / value arrays inside a `$Rec` struct (ADR 0001 / 0007).
  RMkRecord pairs -> do
    idEs <- traverse (\(Tuple labelId _) -> B.i32Const ctx.mod labelId) pairs
    valEs <- traverse (\(Tuple _ valAtom) -> genAtom ctx valAtom) pairs
    idsArr <- B.arrayNewFixed ctx.mod ctx.rt.labelIdsHt idEs
    valsArr <- B.arrayNewFixed ctx.mod ctx.rt.valsHt valEs
    B.structNew ctx.mod ctx.rt.recHt [ idsArr, valsArr ]
  -- Projection is a runtime label-id search, delegated to the shared helper so
  -- the loop is emitted once (ADR 0007).
  RProjLabel recAtom labelId -> do
    recE <- genAtom ctx recAtom
    idE <- B.i32Const ctx.mod labelId
    B.call ctx.mod projHelperName [ recE, idE ] B.eqref
  -- An array is the bare `$Vals` array (it is already an `eqref`).
  RMkArray elements -> do
    elemEs <- traverse (genAtom ctx) elements
    B.arrayNewFixed ctx.mod ctx.rt.valsHt elemEs
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

-- | An intrinsic (ADR 0002 tier 1): unbox the operands, apply the machine op,
-- | re-box the result. Operand and result boxing follow the intrinsic's types;
-- | the lowering guarantees the arity.
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
  -- ordIntImpl lt eq gt x y = if x < y then lt else if x == y then eq else gt
  OrdInt, [ lt, eq, gt, x, y ] -> do
    ltCond <- do
      ex <- unboxIntAtom ctx x
      ey <- unboxIntAtom ctx y
      B.i32LtS ctx.mod ex ey
    eqCond <- do
      ex <- unboxIntAtom ctx x
      ey <- unboxIntAtom ctx y
      B.i32Eq ctx.mod ex ey
    ltE <- genAtom ctx lt
    eqE <- genAtom ctx eq
    gtE <- genAtom ctx gt
    inner <- B.if_ ctx.mod eqCond eqE gtE
    B.if_ ctx.mod ltCond ltE inner
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
  _, _ -> throwException (error "Codegen: intrinsic given an operand list of the wrong arity")
  where
  intBinop op a b = do
    ea <- unboxIntAtom ctx a
    eb <- unboxIntAtom ctx b
    op ctx.mod ea eb >>= boxInt ctx
  intCall2 name a b = do
    ea <- unboxIntAtom ctx a
    eb <- unboxIntAtom ctx b
    B.call ctx.mod name [ ea, eb ] B.i32 >>= boxInt ctx
  boolBinop op a b = do
    ea <- genAtom ctx a >>= unboxBoolExpr ctx
    eb <- genAtom ctx b >>= unboxBoolExpr ctx
    op ctx.mod ea eb >>= B.i31New ctx.mod
  numBinop op a b = do
    ea <- genAtom ctx a >>= unboxNumExpr ctx
    eb <- genAtom ctx b >>= unboxNumExpr ctx
    op ctx.mod ea eb >>= boxNum ctx

unboxIntAtom :: Ctx -> Atom -> Effect B.Expression
unboxIntAtom ctx atom = genAtom ctx atom >>= unboxIntExpr ctx
