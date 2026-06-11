-- | Lower the backend IR (`PureScript.Backend.Wasm.Lower.IR`) to a Binaryen module, on
-- | the Wasm GC representation (ADR 0001) under the uniform `eqref` convention
-- | (ADR 0004).
-- |
-- |   * Scalars box as structs — `$Int = (struct i32)` (also `Char`),
-- |     `$Num = (struct f64)` — while `Boolean` is an unboxed `i31ref`. An ADT is an
-- |     open base `$Data = (struct i32)` (the tag) plus one subtype per constructor
-- |     shape `$Data_<sig>`, scalar fields unboxed (ADR 0013); `$Vals = (array (mut
-- |     eqref))` backs `Array`, and a record (and so a type-class dictionary) is
-- |     `$Rec = (struct (ref $LabelIds) (ref $Vals))`.
-- |   * A closure is `$Clo = (struct funcref (ref $Vals))` — its code as a
-- |     generic `funcref` plus a captured-environment array. The code's type
-- |     `$Code = (func (ref $Clo) eqref -> eqref)` is built in its own recursion
-- |     group so a lifted function's own type matches it for `call_ref`.
-- |   * `RMkClosure` → `array.new_fixed` env + `ref.func` + `struct.new $Clo`;
-- |     `RApply` → read the `funcref`, `ref.cast` to `(ref $Code)`, `call_ref`;
-- |     `EnvField` → read the env array from the closure parameter (local 0).
-- |
-- | This module is the orchestration: it walks the IR (functions, statements,
-- | control flow, export wrappers). The value-type substrate (`Codegen.RuntimeTypes`,
-- | threaded as `Ctx`), the runtime import surface (`Codegen.Imports`), the boxing
-- | convention + `Atom` translation (`Codegen.Value`), and the intrinsic generators
-- | (`Codegen.Prim`) live in the submodules it imports.
module PureScript.Backend.Wasm.Codegen
  ( buildModule
  ) where

import Prelude

import Binaryen as B
import Data.Array as Array
import Data.Foldable (foldr, traverse_)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Set (Set)
import Data.Set as Set
import Foreign.Object (Object)
import Foreign.Object as Object
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Exception (error, throwException)
import PureScript.Backend.Wasm.Codegen.Imports (applyCloHelperName, counterGlobalName, importRuntime, internStrName, projHelperName, recSetHelperName, strEqHelperName)
import PureScript.Backend.Wasm.Intrinsics (Intrinsic(..))
import PureScript.Backend.Wasm.Codegen.Prim (genPrim)
import PureScript.Backend.Wasm.Codegen.RuntimeTypes (Ctx, DataStruct, buildRuntimeTypes, repType)
import PureScript.Backend.Wasm.Codegen.Caf (CafPlan, cafPlan)
import PureScript.Backend.Wasm.Codegen.Value (atomRep, boxInt, coerce, genAtom, genAtomAs, slotRep, unboxBoolExpr)
import PureScript.Backend.Wasm.Lower.IR (Atom(..), AnfExpr(..), Branch(..), ForeignImport, FuncName(..), IRFunc, LitBranch(..), LitPat(..), MarshalKind(..), Program, RecBind(..), Rep(..), Rhs(..), Slot(..), VarRef(..), marshalRep)
import PureScript.Backend.Wasm.Lower.Reps (primRep)

-- | Build a Binaryen module from the IR `Program`: enable GC, build the
-- | runtime type group, add every function (`eqref` calling convention; lifted
-- | code functions take `(ref $Clo, eqref)`), then add an `i32` export wrapper
-- | per exported function.
buildModule :: Program -> Effect B.Module
buildModule prog = do
  mod <- B.createModule
  B.setFeaturesGC mod
  rt <- buildRuntimeTypes mod
  dataGroup <- buildDataTypes mod (dataSignatures prog)
  let sigs = Map.fromFoldable (map (\fn -> Tuple fn.name { params: fn.params, result: fn.result }) prog.funcs)
  let cplan = cafPlan prog
  let ctx = { mod, rt, params: [], localReps: [], funcResult: Boxed, tailPos: true, sigs, dataBase: dataGroup.base, dataStructs: dataGroup.structs, cafGlobals: cplan.globals }
  importRuntime ctx
  addForeignImports ctx prog
  addInternStr ctx (needsInternStr prog) prog.labels
  addNullaryGlobals ctx (nullaryTags prog)
  addCafGlobals ctx cplan.globals
  when (needsCounter prog) (addCounterGlobal ctx)
  traverse_ (addFunc ctx) prog.funcs
  addCafInit ctx cplan
  traverse_ (addExportWrapper ctx prog.exportSigs) prog.funcs
  pure mod

-- | A nullary constructor (`RMkData tag []`) is a constant `$Data` value — just its
-- | tag, no fields — fully determined by its tag, so every construction of it is
-- | the same heap object. Rather than `struct.new` one per use, allocate it once
-- | as an immutable module global and read it with `global.get`. Sharing is by
-- | tag because the `$Data` representation erases the source type: `Nothing` and
-- | `Nil` are both tag `0` and indistinguishable at runtime. (Enum-like types
-- | use `i31ref` tags instead and never reach here; ADR 0013.)
nullaryGlobalName :: Int -> String
nullaryGlobalName tag = "$nullary" <> show tag

-- | Fold a function over every `Rhs` in the program (the only nodes that build or
-- | project values), used to gather what runtime types/globals to emit.
foldProgramRhs :: forall a. (Rhs -> a -> a) -> a -> Program -> a
foldProgramRhs f z prog = foldr (\fn acc -> exprF fn.body acc) z prog.funcs
  where
  exprF expr acc = case expr of
    Return _ -> acc
    Let _ _ rhs k -> exprF k (f rhs acc)
    Switch _ branches dflt -> dfltF dflt (foldr (\(Branch _ b) -> exprF b) acc branches)
    LitSwitch _ branches dflt -> dfltF dflt (foldr (\(LitBranch _ b) -> exprF b) acc branches)
    LetRec _ k -> exprF k acc
    LetJoin _ _ producer k -> exprF k (exprF producer acc)
  dfltF dflt acc = maybe acc (\k -> exprF k acc) dflt

-- | The set of nullary-constructor tags actually constructed anywhere in the
-- | program, so a shared global is emitted for exactly those (and no more).
nullaryTags :: Program -> Set Int
nullaryTags = foldProgramRhs collect Set.empty
  where
  collect rhs acc = case rhs of
    RMkData tag _ fields | Array.null fields -> Set.insert tag acc
    _ -> acc

-- | Emit a wasm host import (ADR 0014) for each `foreign import` the program calls.
-- | The import's `(module, name)` is the foreign's source module and identifier — a
-- | JS (or wasm) loader satisfies it; its signature is the foreign's externs
-- | calling convention.
addForeignImports :: Ctx -> Program -> Effect Unit
addForeignImports ctx prog = traverse_ addOne (Object.values (foreignImports prog))
  where
  addOne sig = B.addFunctionImport ctx.mod (foreignName sig) sig.moduleName sig.base
    (B.createType ((repType ctx <<< marshalRep) <$> sig.params))
    (repType ctx (marshalRep sig.result))

-- | The foreigns the program calls (`RCallForeign`), deduplicated by internal name.
foreignImports :: Program -> Object ForeignImport
foreignImports = foldProgramRhs collect Object.empty
  where
  collect rhs acc = case rhs of
    RCallForeign sig _ -> Object.insert (foreignName sig) sig acc
    _ -> acc

-- | The internal wasm name of a foreign import: its qualified `Module.ident`.
foreignName :: ForeignImport -> String
foreignName sig = sig.moduleName <> "." <> sig.base

-- | Whether any foreign import **or export** marshals a record (so the JS glue needs
-- | `internStr` to map field names to interned ids; ADR 0014).
needsInternStr :: Program -> Boolean
needsInternStr prog = foldProgramRhs collect false prog || Array.any sigHasRecord (Object.values prog.exportSigs)
  where
  collect rhs acc = acc || case rhs of
    RCallForeign sig _ -> sigHasRecord sig
    -- modifyImpl (ADR 0017) resolves the record's `state`/`value` ids via `internStr`
    RPrim RefModify _ -> true
    _ -> false
  sigHasRecord sig = Array.any kindHasRecord sig.params || kindHasRecord sig.result

kindHasRecord :: MarshalKind -> Boolean
kindHasRecord = case _ of
  MRecord _ -> true
  MArray k -> kindHasRecord k
  MFunc p r -> kindHasRecord p || kindHasRecord r
  _ -> false

-- | Whether a marshalled result is an `Effect a` — its compiled function carries an extra
-- | perform-unit param the type signature does not name (ADR 0018).
isEffectKind :: MarshalKind -> Boolean
isEffectKind = case _ of
  MEffect _ -> true
  _ -> false

-- | Every constructor field-rep signature constructed or projected in the program,
-- | so a `$Data_<sig>` struct type is generated for exactly those.
dataSignatures :: Program -> Array (Array Rep)
dataSignatures = foldProgramRhs collect []
  where
  collect rhs acc = case rhs of
    RMkData _ sig _ -> Array.cons sig acc
    RProjField _ sig _ -> Array.cons sig acc
    _ -> acc

-- | Build the ADT struct types: a tag-only base `$Data = (struct i32)` (open) plus
-- | one subtype `$Data_<sig> = (sub $Data (struct i32 <field per rep>))` per distinct
-- | non-empty signature. The empty signature maps to the base (a nullary ctor is
-- | just its tag). All in one recursion group so the subtype declarations resolve.
buildDataTypes :: B.Module -> Array (Array Rep) -> Effect { base :: DataStruct, structs :: Map (Array Rep) DataStruct }
buildDataTypes _ sigs0 = do
  let nonEmpty = Array.filter (not <<< Array.null) (Array.nub sigs0)
  let n = Array.length nonEmpty
  tb <- B.typeBuilderCreate (1 + n)
  B.typeBuilderSetStructType tb 0 [ { ty: B.i32, mutable: false } ]
  B.typeBuilderSetOpen tb 0
  baseTmp <- B.typeBuilderGetTempHeapType tb 0
  traverse_
    ( \(Tuple i sig) -> do
        B.typeBuilderSetStructType tb (i + 1)
          (Array.cons { ty: B.i32, mutable: false } (map (\rep -> { ty: fieldWasmType rep, mutable: false }) sig))
        B.typeBuilderSetSubType tb (i + 1) baseTmp
    )
    (Array.mapWithIndex Tuple nonEmpty)
  hts <- B.typeBuilderBuildAndDispose tb (1 + n)
  case Array.uncons hts of
    Just { head: baseHt, tail: structHts } -> do
      let toStruct ht = { ht, ref: B.typeFromHeapType ht false }
      let base = toStruct baseHt
      pure
        { base
        , structs: Map.insert [] base
            (Map.fromFoldable (Array.zipWith (\sig ht -> Tuple sig (toStruct ht)) nonEmpty structHts))
        }
    Nothing -> throwException (error "Codegen: expected at least the $Data base type")

-- | The wasm type of a single ADT struct field for a given representation
-- | (`i32`/`f64` unboxed, otherwise the boxed `eqref`).
fieldWasmType :: Rep -> B.Type
fieldWasmType = case _ of
  I32 -> B.i32
  F64 -> B.f64
  _ -> B.eqref

-- | The struct type for a constructor signature (the base for the empty signature).
dataStructFor :: Ctx -> Array Rep -> DataStruct
dataStructFor ctx sig = fromMaybe ctx.dataBase (Map.lookup sig ctx.dataStructs)

-- | Whether the program uses the test-only effectful counter primitives, so its
-- | mutable backing global is emitted only when needed.
needsCounter :: Program -> Boolean
needsCounter = foldProgramRhs collect false
  where
  collect rhs acc = acc || case rhs of
    RPrim IncrCtr _ -> true
    RPrim ReadCtr _ -> true
    _ -> false

-- | Declare the mutable global `$ctr` (init 0) backing `incrCtr` / `readCtr`.
addCounterGlobal :: Ctx -> Effect Unit
addCounterGlobal ctx = do
  initE <- B.i32Const ctx.mod 0
  B.addGlobal ctx.mod counterGlobalName B.i32 true initE

addNullaryGlobals :: Ctx -> Set Int -> Effect Unit
addNullaryGlobals ctx tags = traverse_ addOne (Set.toUnfoldable tags :: Array Int)
  where
  addOne tag = do
    tagE <- B.i32Const ctx.mod tag
    initE <- B.structNew ctx.mod ctx.dataBase.ht [ tagE ]
    B.addGlobal ctx.mod (nullaryGlobalName tag) B.eqref false initE

-- | The wasm global a globalized CAF (ADR 0006) stores its computed value in.
cafGlobalName :: FuncName -> String
cafGlobalName name = "$caf." <> funcNameStr name

-- | The synthesized CAF initializer (the module `start` function).
cafInitName :: String
cafInitName = "$caf_init"

-- | Emit a mutable global per globalizable CAF (ADR 0006), holding the value at its
-- | representation (`i32`/`f64`/`eqref` — a scalar stays unboxed). The initializer is
-- | a throwaway constant the init function overwrites at instantiation; an `eqref`
-- | global uses a dummy boxed `0` (a GC const expression, like a nullary constructor).
addCafGlobals :: Ctx -> Map FuncName Rep -> Effect Unit
addCafGlobals ctx globals = traverse_ addOne (Map.toUnfoldable globals :: Array (Tuple FuncName Rep))
  where
  addOne (Tuple name rep) = do
    initE <- defaultConst ctx rep
    B.addGlobal ctx.mod (cafGlobalName name) (repType ctx rep) true initE

-- | A throwaway value of the given rep (`0` / `0.0` / a boxed `0`, a GC const expression like a
-- | nullary constructor). Used to initialise a mutable CAF global (overwritten at instantiation)
-- | and to fill an `Effect` export's dropped perform-unit param.
defaultConst :: Ctx -> Rep -> Effect B.Expression
defaultConst ctx = case _ of
  I32 -> B.i32Const ctx.mod 0
  F64 -> B.f64Const ctx.mod 0.0
  _ -> B.i32Const ctx.mod 0 >>= \z -> B.structNew ctx.mod ctx.rt.intHt [ z ]

-- | Synthesize the init function that computes each CAF once, in dependency order,
-- | storing it in its global, and register it as the module `start` so it runs at
-- | instantiation before any export. The CAF still has its own (arity-0) function —
-- | the init simply calls it once; every other reference reads the global. No-op when
-- | nothing is globalized.
addCafInit :: Ctx -> CafPlan -> Effect Unit
addCafInit ctx cplan
  | Array.null cplan.initOrder = pure unit
  | otherwise =
      do
        stmts <- traverse setOne cplan.initOrder
        body <- B.block ctx.mod stmts B.none
        initFn <- B.addFunction ctx.mod cafInitName (B.createType []) B.none [] body
        B.setStart ctx.mod initFn
      where
      setOne name = do
        let rep = fromMaybe Boxed (Map.lookup name cplan.globals)
        v <- B.call ctx.mod (funcNameStr name) [] (repType ctx rep)
        B.globalSet ctx.mod (cafGlobalName name) v

-- | Read a globalized CAF's value (`global.get`) at its representation.
readCaf :: Ctx -> FuncName -> Rep -> Effect B.Expression
readCaf ctx name rep = B.globalGet ctx.mod (cafGlobalName name) (repType ctx rep)

-- | Emit the `internStr` resolver: a `String` key → its interned `i32` label id,
-- | as an `if (strEq key "label") then <id> else …` chain over the program's
-- | `labels` (ending in `unreachable` — a queried label is always interned). Used
-- | by `Record.Unsafe`'s string-keyed access to reach the id-keyed record helpers.
-- | (Binaryen prunes it when no record op references it.)
addInternStr :: Ctx -> Boolean -> Array (Tuple String Int) -> Effect Unit
addInternStr ctx exportIt labels = do
  miss <- B.unreachable ctx.mod
  body <- foldr step (pure miss) labels
  _ <- B.addFunction ctx.mod internStrName (B.createType [ B.eqref ]) B.i32 [] body
  -- exported when a record/object foreign needs name→id resolution from the JS
  -- marshalling glue (ADR 0014); otherwise internal (and Binaryen-pruned if unused)
  when exportIt (void (B.addFunctionExport ctx.mod internStrName "internStr"))
  pure unit
  where
  step (Tuple label labelId) accM = do
    acc <- accM
    key <- B.localGet ctx.mod 0 B.eqref
    labelConst <- genAtom ctx (ALitString label)
    cond <- B.call ctx.mod strEqHelperName [ key, labelConst ] B.i32
    idExpr <- B.i32Const ctx.mod labelId
    B.if_ ctx.mod cond idExpr acc

funcNameStr :: FuncName -> String
funcNameStr (FuncName n) = n

-- | Add an internal function. Parameters take their declared representation (a
-- | lifted code function's first parameter is `(ref $Clo)`); `Let`-bound locals
-- | are all `eqref`. A code function added with `(ref $Clo, eqref) -> eqref`
-- | matches `$Code`, so `call_ref` against it validates.
addFunc :: Ctx -> IRFunc -> Effect Unit
addFunc ctx0 fn = do
  let localReps = buildLocalReps fn
  let ctx = ctx0 { params = fn.params, localReps = localReps, funcResult = fn.result, tailPos = true }
  body <- genBody ctx fn.body
  let params = B.createType (repType ctx <$> fn.params)
  -- `Let`-bound locals (the slots after the parameters) take their chosen rep
  let varTypes = repType ctx <$> Array.drop (Array.length fn.params) localReps
  _ <- B.addFunction ctx.mod (funcNameStr fn.name) params (repType ctx fn.result) varTypes body
  pure unit

-- | The representation of every local slot: a parameter takes its declared rep, a
-- | `Let`-bound slot the rep on its binding, and a `LetRec` closure slot `Boxed`.
buildLocalReps :: IRFunc -> Array Rep
buildLocalReps fn = Array.mapWithIndex slotRepAt (Array.replicate fn.localCount unit)
  where
  letReps = Map.fromFoldable (collectSlotReps fn.body)
  slotRepAt i _ = case Array.index fn.params i of
    Just r -> r
    Nothing -> fromMaybe Boxed (Map.lookup i letReps)

collectSlotReps :: AnfExpr -> Array (Tuple Int Rep)
collectSlotReps = case _ of
  Return _ -> []
  Let (Slot s) rep _ k -> Array.cons (Tuple s rep) (collectSlotReps k)
  Switch _ branches dflt ->
    (branches >>= \(Branch _ b) -> collectSlotReps b) <> maybe [] collectSlotReps dflt
  LitSwitch _ branches dflt ->
    (branches >>= \(LitBranch _ b) -> collectSlotReps b) <> maybe [] collectSlotReps dflt
  LetRec recBinds k ->
    map (\(RecBind (Slot s) _ _) -> Tuple s Boxed) recBinds <> collectSlotReps k
  LetJoin (Slot s) rep producer k ->
    Array.cons (Tuple s rep) (collectSlotReps producer <> collectSlotReps k)

-- | Add the host-facing wrapper for an exported function (never a code function —
-- | those are not exported). The host ABI is each param/result's `marshalRep` (ADR
-- | 0014): a plain `Int`/`Char` stays `i32`, `Number` is `f64`, and `String`/`Array`/
-- | `Record`/`Boolean`/closure cross as `eqref` (the JS loader marshals them via the
-- | runtime helpers). The wrapper coerces between that external rep and the internal
-- | function's rep. When the export's FFI kind is unknown (no externs entry), it
-- | falls back to the internal reps — so a plain `Int` export is unchanged.
-- |
-- | A **point-free** top-level (`inc = add 1`, type `Int -> Int`) compiles to a
-- | *nullary* function returning a closure: its compiled arity (`fn.params`) is less
-- | than its type arity (`sig.params`). The wrapper exposes the full type arity by
-- | calling the compiled function with the leading args and then applying the
-- | remaining args to the returned closure one at a time (the same over-application
-- | the internal call path performs) — so the export reads as a normal n-ary function.
addExportWrapper :: Ctx -> Object ForeignImport -> IRFunc -> Effect Unit
addExportWrapper ctx exportSigs fn = case fn.export of
  Nothing -> pure unit
  Just external -> do
    let
      compiledArity = Array.length fn.params
      -- Accept the FFI sig when it covers the compiled arity. Two ways the two can differ:
      -- a *greater* type arity is a point-free binding (eta-expanded at the boundary below);
      -- a *smaller* type arity by exactly one is an `Effect`-returning function, whose compiled
      -- form carries the extra `Effect` perform-unit param (ADR 0018). Either way the sig still
      -- describes how the marshalled params cross, so use it rather than the i32 fallback.
      mSig = case Object.lookup external exportSigs of
        Just s
          | Array.length s.params >= compiledArity
              || (isEffectKind s.result && Array.length s.params + 1 >= compiledArity) -> Just s
        _ -> Nothing
      -- with a known FFI kind, expose its `marshalRep`; without one (no externs), fall
      -- back to the historical `i32` ABI (the internal rep is often `Boxed`, so the
      -- wrapper boxes/unboxes a plain `Int` at the boundary — ADR 0014). The export exposes the
      -- sig's params only — an `Effect`'s trailing perform-unit is hidden, synthesised below.
      extParams = maybe (I32 <$ fn.params) (\s -> marshalRep <$> s.params) mSig
      extResult = maybe I32 (\s -> marshalRep s.result) mSig
      extArity = Array.length extParams
      -- params shared by the export and the compiled fn: a point-free binding exposes MORE (the
      -- extras apply to the returned closure below), an `Effect`-returning function FEWER (its
      -- compiled form's trailing perform-unit param is synthesised here, not taken from the host).
      directCount = min compiledArity extArity
    -- the leading external params drive the direct call (each coerced external → internal rep)
    leadingArgs <- traverse
      (\(Tuple i (Tuple extRep intRep)) -> B.localGet ctx.mod i (repType ctx extRep) >>= coerce ctx extRep intRep)
      (Array.mapWithIndex Tuple (Array.zip (Array.take directCount extParams) (Array.take directCount fn.params)))
    -- compiled params the export does not expose are `Effect` perform-units (ADR 0018); the value
    -- is dropped in codegen, so a throwaway default of the param's rep suffices.
    performUnits <- traverse (defaultConst ctx) (Array.drop directCount fn.params)
    let args = leadingArgs <> performUnits
    -- a globalized CAF export reads its precomputed global (ADR 0006); otherwise call
    result <- case Map.lookup fn.name ctx.cafGlobals of
      Just rep | compiledArity == 0 -> readCaf ctx fn.name rep
      _ -> B.call ctx.mod (funcNameStr fn.name) args (repType ctx fn.result)
    -- any remaining external params (point-free: extArity > compiledArity) are applied
    -- to the returned closure via the runtime trampoline; the value stays boxed `eqref`
    let
      applyExtra acc idxs = case Array.uncons idxs of
        Nothing -> pure acc
        Just { head: i, tail } -> do
          let extRep = fromMaybe Boxed (Array.index extParams i)
          a <- B.localGet ctx.mod i (repType ctx extRep) >>= coerce ctx extRep Boxed
          acc' <- B.call ctx.mod applyCloHelperName [ acc, a ] B.eqref
          applyExtra acc' tail
      extraIdxs = if extArity > compiledArity then Array.range compiledArity (extArity - 1) else []
    applied <- applyExtra result extraIdxs
    let appliedRep = if extArity > compiledArity then Boxed else fn.result
    ret <- coerce ctx appliedRep extResult applied
    let params = B.createType (repType ctx <$> extParams)
    let wrapperName = funcNameStr fn.name <> "$export"
    _ <- B.addFunction ctx.mod wrapperName params (repType ctx extResult) [] ret
    _ <- B.addFunctionExport ctx.mod wrapperName external
    pure unit

-- | Generate a function body. `Let`s become `local.set` statements sequenced in
-- | a `block` whose value is the tail (`Return` atom or `Switch`).
genBody :: Ctx -> AnfExpr -> Effect B.Expression
genBody ctx = go []
  where
  go statements = case _ of
    -- A returned atom is coerced to the function's result representation.
    Return atom -> seal statements =<< genAtomAs ctx ctx.funcResult atom
    Switch scrutAtom branches dflt -> seal statements =<< genSwitch ctx scrutAtom branches dflt
    LitSwitch scrutAtom branches dflt -> seal statements =<< genLitSwitch ctx scrutAtom branches dflt
    -- A direct call whose result is immediately returned is a *tail* call: emit
    -- `return_call` so a tail-recursive chain runs in constant stack. Only valid when
    -- the callee's result rep matches this function's (the frame is replaced, so no
    -- coercion can sit between the call and the return); otherwise fall through to a
    -- normal call. Closure tail calls (`RApply`) are not covered here.
    Let (Slot index) _ (RCallKnown name args) (Return (AVar (Local (Slot retIndex))))
      | ctx.tailPos
      , index == retIndex
      , not (Map.member name ctx.cafGlobals) -- a globalized CAF reads its global, not a tail call
      , Just sig <- Map.lookup name ctx.sigs
      , sig.result == ctx.funcResult -> do
          operands <- traverse (\(Tuple rep a) -> genAtomAs ctx rep a) (Array.zip sig.params args)
          seal statements =<< B.returnCall ctx.mod (funcNameStr name) operands (repType ctx sig.result)
    -- Store the rhs into its slot, boxing/unboxing if the slot's chosen rep differs
    -- from the rhs's natural rep.
    Let (Slot index) _ rhs k -> do
      e <- genRhs ctx rhs >>= coerce ctx (rhsRep ctx rhs) (slotRep ctx index)
      stmt <- B.localSet ctx.mod index e
      go (Array.snoc statements stmt) k
    LetRec recBinds k -> do
      let groupSlots = map (\(RecBind (Slot s) _ _) -> s) recBinds
      allocs <- traverse (allocRecClosure ctx groupSlots) recBinds
      patches <- traverse (patchRecClosure ctx groupSlots) recBinds
      go (statements <> allocs <> Array.concat patches) k
    -- A join point (ADR 0022): generate the `producer` as a value-producing block
    -- (its tails yield `rep`, and `return_call` is disabled so it cannot escape the
    -- function), store it into the join slot, then continue the (single) continuation.
    LetJoin (Slot slot) rep producer k -> do
      producerExpr <- genBody (ctx { funcResult = rep, tailPos = false }) producer
      stmt <- B.localSet ctx.mod slot producerExpr
      go (Array.snoc statements stmt) k
  -- the body / branch block produces the function's result (a tail position)
  seal statements value =
    if Array.null statements then pure value
    else B.block ctx.mod (Array.snoc statements value) (repType ctx ctx.funcResult)

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
    | otherwise = genAtomAs ctx Boxed atom

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
    val <- genAtomAs ctx Boxed atom
    B.arraySet ctx.mod envArr idx val

-- | A `Switch` becomes a chain of `if (tag == k) <branch> else …`, ending in the
-- | default block or `unreachable`. The tag is read afresh per comparison.
genSwitch :: Ctx -> Atom -> Array Branch -> Maybe AnfExpr -> Effect B.Expression
genSwitch ctx scrutAtom branches dflt = chain branches
  where
  readTag = do
    s <- genAtomAs ctx Boxed scrutAtom
    c <- B.refCast ctx.mod s ctx.dataBase.ref
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
      s <- genAtomAs ctx I32 scrutAtom
      k <- B.i32Const ctx.mod n
      B.i32Eq ctx.mod s k
    PBoolean b -> do
      s <- genAtom ctx scrutAtom >>= unboxBoolExpr ctx
      k <- B.i32Const ctx.mod (if b then 1 else 0)
      B.i32Eq ctx.mod s k
    PNumber n -> do
      s <- genAtomAs ctx F64 scrutAtom
      k <- B.f64Const ctx.mod n
      B.f64Eq ctx.mod s k
    -- the scrutinee equals the literal string iff the byte-equality helper says
    -- so (a non-zero `i32`), which serves directly as the `if` condition
    PString str -> do
      s <- genAtom ctx scrutAtom
      lit <- genAtom ctx (ALitString str)
      B.call ctx.mod strEqHelperName [ s, lit ] B.i32

-- | The natural representation a `Rhs` produces, so `genBody` can box / unbox it to
-- | the bound slot. An atom keeps its own rep, an intrinsic its `primRep`; every
-- | allocating / calling rhs yields an `eqref` (`Boxed`).
rhsRep :: Ctx -> Rhs -> Rep
rhsRep ctx = case _ of
  RAtom atom -> atomRep ctx atom
  RPrim intr _ -> primRep intr
  RCallKnown name _ -> maybe Boxed _.result (Map.lookup name ctx.sigs)
  RCallForeign sig _ -> marshalRep sig.result
  REnumTag _ -> I32
  -- a projected field is produced at its struct-field rep (so an unboxed scalar
  -- field is not spuriously unboxed again into its slot)
  RProjField _ sig idx -> fromMaybe Boxed (Array.index sig idx)
  _ -> Boxed

genRhs :: Ctx -> Rhs -> Effect B.Expression
genRhs ctx = case _ of
  RAtom atom -> genAtom ctx atom
  RPrim intr args -> genPrim ctx intr args
  -- a reference to a globalized CAF (ADR 0006) reads its global instead of calling
  -- the binding; the value was computed once by the init function
  RCallKnown name args
    | Array.null args
    , Just rep <- Map.lookup name ctx.cafGlobals -> readCaf ctx name rep
  RCallKnown name args -> do
    let sig = fromMaybe { params: const Boxed <$> args, result: Boxed } (Map.lookup name ctx.sigs)
    operands <- traverse (\(Tuple rep a) -> genAtomAs ctx rep a) (Array.zip sig.params args)
    B.call ctx.mod (funcNameStr name) operands (repType ctx sig.result)
  -- a host import (ADR 0014): coerce operands to the foreign's param reps, call its
  -- import by internal name, read the result at the foreign's result rep
  RCallForeign sig args -> do
    operands <- traverse (\(Tuple kind a) -> genAtomAs ctx (marshalRep kind) a) (Array.zip sig.params args)
    B.call ctx.mod (foreignName sig) operands (repType ctx (marshalRep sig.result))
  -- a nullary constructor is a shared module global (allocated once); a
  -- constructor with fields is one `struct.new` of its `$Data_<sig>` type, each
  -- field coerced to its struct-field rep (so a concrete scalar stays unboxed)
  RMkData tag sig fields
    | Array.null fields -> B.globalGet ctx.mod (nullaryGlobalName tag) B.eqref
    | otherwise -> do
        tagE <- B.i32Const ctx.mod tag
        fieldEs <- traverse (\(Tuple rep at) -> genAtomAs ctx rep at) (Array.zip sig fields)
        B.structNew ctx.mod (dataStructFor ctx sig).ht (Array.cons tagE fieldEs)
  -- an enum-like value is its tag as an allocation-free `i31ref`
  RMkEnum tag -> B.i32Const ctx.mod tag >>= B.i31New ctx.mod
  REnumTag atom -> genAtomAs ctx Boxed atom >>= unboxBoolExpr ctx
  -- project field `index` (struct field `index + 1`, after the tag) from the
  -- constructor's `$Data_<sig>` struct, at the field's own representation
  RProjField adtAtom sig index -> do
    a <- genAtomAs ctx Boxed adtAtom
    c <- B.refCast ctx.mod a (dataStructFor ctx sig).ref
    B.structGet ctx.mod (index + 1) c (repType ctx (fromMaybe Boxed (Array.index sig index))) false
  -- A record (a type-class dictionary, after newtype erasure) is parallel
  -- label-id / value arrays inside a `$Rec` struct (ADR 0001 / 0007).
  RMkRecord pairs -> do
    idEs <- traverse (\(Tuple labelId _) -> B.i32Const ctx.mod labelId) pairs
    valEs <- traverse (\(Tuple _ valAtom) -> genAtomAs ctx Boxed valAtom) pairs
    idsArr <- B.arrayNewFixed ctx.mod ctx.rt.labelIdsHt idEs
    valsArr <- B.arrayNewFixed ctx.mod ctx.rt.valsHt valEs
    B.structNew ctx.mod ctx.rt.recHt [ idsArr, valsArr ]
  -- Projection is a runtime label-id search, delegated to the shared helper so
  -- the loop is emitted once (ADR 0007).
  RProjLabel recAtom labelId -> do
    recE <- genAtomAs ctx Boxed recAtom
    idE <- B.i32Const ctx.mod labelId
    B.call ctx.mod projHelperName [ recE, idE ] B.eqref
  -- Copy-and-set one field by interned label id, reusing the `unsafeSet` helper; all
  -- other fields (including an open row's unknown tail) are carried over (ADR 0023).
  RRecSet recAtom labelId valAtom -> do
    recE <- genAtomAs ctx Boxed recAtom
    idE <- B.i32Const ctx.mod labelId
    valE <- genAtomAs ctx Boxed valAtom
    B.call ctx.mod recSetHelperName [ recE, idE, valE ] B.eqref
  -- An array is the bare `$Vals` array (it is already an `eqref`).
  RMkArray elements -> do
    elemEs <- traverse (genAtomAs ctx Boxed) elements
    B.arrayNewFixed ctx.mod ctx.rt.valsHt elemEs
  RMkClosure codeName captures -> do
    capEs <- traverse (genAtomAs ctx Boxed) captures
    envArr <- B.arrayNewFixed ctx.mod ctx.rt.valsHt capEs
    fref <- B.refFunc ctx.mod (funcNameStr codeName) ctx.rt.codeHt
    B.structNew ctx.mod ctx.rt.cloHt [ fref, envArr ]
  -- Apply an arity-1 closure: read its funcref, cast to `(ref $Code)`, and
  -- `call_ref` with the closure itself plus the argument. (A multi-argument
  -- application is a chain of these, produced by the lowering.)
  RApply headAtom argAtom -> do
    cloForCode <- genAtomAs ctx Boxed headAtom >>= \h -> B.refCast ctx.mod h ctx.rt.refClo
    fref <- B.structGet ctx.mod 0 cloForCode B.funcref false
    codeF <- B.refCast ctx.mod fref ctx.rt.refCode
    cloOperand <- genAtomAs ctx Boxed headAtom >>= \h -> B.refCast ctx.mod h ctx.rt.refClo
    argE <- genAtomAs ctx Boxed argAtom
    B.callRef ctx.mod codeF [ cloOperand, argE ] ctx.rt.codeHt
