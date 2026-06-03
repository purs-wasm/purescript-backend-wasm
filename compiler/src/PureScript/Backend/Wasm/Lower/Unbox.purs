-- | The representation analysis (ADR 0013, front A): assign each `Let`-bound slot,
-- | function parameter, and function result a wasm representation, keeping
-- | `Int`/`Number` values unboxed (`I32`/`F64`) where it avoids boxing.
-- |
-- | This is a **whole-program** analysis, because a representation must match a
-- | value's actual runtime type (unboxing an `eqref` that is not a `$Int` would trap
-- | at the cast). A parameter's type is the join of the types of every argument
-- | passed to it; a result's type the join of every value returned; a call result
-- | takes the callee's result type. Those are mutually dependent (a self-recursive
-- | loop passes its own results back as arguments), so the function signatures
-- | (parameter and result types) are solved by a fixpoint over a small type lattice
-- | (`⊤ ⊐ {I32, F64} ⊐ Boxed`). Once the signatures are known, local slots are
-- | assigned by the same boxing-minimising rule as before — keep a value unboxed
-- | when its rhs produces it unboxed and at most one use boxes it — now reading
-- | producer / demand reps across calls.
-- |
-- | Unboxing function parameters/results is what lets a tail loop run entirely in
-- | `i32`: the recursive call's arithmetic arguments are demanded `i32`, so they
-- | never box.
module PureScript.Backend.Wasm.Lower.Unbox
  ( assignProgramReps
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (foldl)
import Data.FoldableWithIndex (foldlWithIndex)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Tuple (Tuple(..))
import PureScript.Backend.Wasm.Lower.IR (AnfExpr(..), Atom(..), Branch(..), FuncName, IRFunc, LitBranch(..), LitPat(..), RecBind(..), Rep(..), Rhs(..), Slot(..), VarRef(..), marshalRep)
import PureScript.Backend.Wasm.Lower.Reps (primOperandReps, primRep)

-- type lattice ----------------------------------------------------------------

-- | A type-inference lattice value: `Top` (no information yet), the unboxable scalar
-- | types, or `Bx` (must be boxed — the bottom, where mixed/`eqref` values land).
data TyRep = Top | Ti32 | Tf64 | Bx

derive instance Eq TyRep

-- | Join two inferred types: equal types are kept, `Top` is the identity, anything
-- | else (mixed scalars, or any `eqref`) is `Bx`.
joinTy :: TyRep -> TyRep -> TyRep
joinTy a b = case a, b of
  Top, x -> x
  x, Top -> x
  Ti32, Ti32 -> Ti32
  Tf64, Tf64 -> Tf64
  _, _ -> Bx

-- | The wasm representation a final inferred type maps to (`Top`/`Bx` → `Boxed`).
repOfTy :: TyRep -> Rep
repOfTy = case _ of
  Ti32 -> I32
  Tf64 -> F64
  _ -> Boxed

tyOfRep :: Rep -> TyRep
tyOfRep = case _ of
  I32 -> Ti32
  F64 -> Tf64
  _ -> Bx

-- signatures ------------------------------------------------------------------

type Sig = { params :: Array TyRep, result :: TyRep }

assignProgramReps :: Array IRFunc -> Array IRFunc
assignProgramReps funcs = map (rewriteFunc sigs) funcs
  where
  callSites = buildCallSites funcs
  funcByName = Map.fromFoldable (map (\fn -> Tuple fn.name fn) funcs)
  sigs = solve (Map.fromFoldable (map (\fn -> Tuple fn.name (initialSig fn)) funcs))

  -- | Iterate the signature inference to a fixed point (monotone on a finite
  -- | lattice, so it terminates; a generous bound guards pathological cases).
  solve s =
    let
      s' = Map.fromFoldable (map (\fn -> Tuple fn.name (deriveSig s fn)) funcs)
    in
      if s' == s then s else solve s'

  deriveSig s fn =
    { params: Array.mapWithIndex (paramTy s fn) fn.params
    , result: resultTy s fn
    }

  -- | A parameter's inferred type is the join of every argument passed to it across
  -- | the program; the closure parameter of a lifted code function stays `Bx`.
  paramTy s fn i origRep = case origRep of
    CloRef -> Bx
    _ -> foldl (\acc (Tuple caller args) -> joinTy acc (atomTy s caller (Array.index args i))) Top
      (fromMaybe [] (Map.lookup fn.name callSites))

  resultTy s fn = returnsTy s fn fn.body

  -- argument / returned atom types are read in the *caller's* local type context
  atomTy s callerName mAtom = case mAtom of
    Just (AVar (Local (Slot slot))) ->
      maybe Bx (\caller -> fromMaybe Bx (Map.lookup slot (localTypes s caller))) (Map.lookup callerName funcByName)
    Just (ALitInt _) -> Ti32
    Just (ALitNumber _) -> Tf64
    Just _ -> Bx
    Nothing -> Bx

  -- | The inferred type of every slot of `fn` (parameters read from the *current*
  -- | signature — not recomputed, which would recurse forever on a self-recursive
  -- | function — `Let` slots from their producer), given the current signatures.
  localTypes s fn = Map.union paramTypes (collectProducers s Map.empty fn.body)
    where
    sigParams = maybe [] _.params (Map.lookup fn.name s)
    paramTypes = Map.fromFoldable
      (Array.mapWithIndex (\i _ -> Tuple i (fromMaybe Bx (Array.index sigParams i))) fn.params)

  -- producer type of each `Let` slot
  collectProducers s acc = case _ of
    Return _ -> acc
    Let (Slot slot) _ rhs k -> collectProducers s (Map.insert slot (producerTy s rhs) acc) k
    Switch _ branches dflt ->
      let
        acc1 = foldl (\a (Branch _ b) -> collectProducers s a b) acc branches
      in
        maybe acc1 (collectProducers s acc1) dflt
    LitSwitch _ branches dflt ->
      let
        acc1 = foldl (\a (LitBranch _ b) -> collectProducers s a b) acc branches
      in
        maybe acc1 (collectProducers s acc1) dflt
    LetRec recBinds k ->
      collectProducers s (foldl (\a (RecBind (Slot slot) _ _) -> Map.insert slot Bx a) acc recBinds) k

  producerTy s = case _ of
    RPrim intr _ -> tyOfRep (primRep intr)
    RAtom (ALitInt _) -> Ti32
    RAtom (ALitNumber _) -> Tf64
    RCallKnown name _ -> maybe Bx _.result (Map.lookup name s)
    RCallForeign sig _ -> tyOfRep (marshalRep sig.result)
    REnumTag _ -> Ti32
    -- a projected field is produced at the constructor's struct-field rep
    RProjField _ sig idx -> tyOfRep (fromMaybe Boxed (Array.index sig idx))
    _ -> Bx

  -- the join of the types of every atom an expression returns
  returnsTy s fn = go
    where
    lts = localTypes s fn
    go = case _ of
      Return atom -> atomReturnTy atom
      Let _ _ _ k -> go k
      Switch _ branches dflt ->
        foldl joinTy (maybe Top go dflt) (map (\(Branch _ b) -> go b) branches)
      LitSwitch _ branches dflt ->
        foldl joinTy (maybe Top go dflt) (map (\(LitBranch _ b) -> go b) branches)
      LetRec _ k -> go k
    atomReturnTy = case _ of
      AVar (Local (Slot slot)) -> fromMaybe Bx (Map.lookup slot lts)
      ALitInt _ -> Ti32
      ALitNumber _ -> Tf64
      _ -> Bx

-- | A signature seeded from the function's existing (mostly `Boxed`) reps; the
-- | fixpoint refines it.
initialSig :: IRFunc -> Sig
initialSig fn = { params: map (const Top) fn.params, result: Top }

-- | Every call site, indexed by callee: the caller and the argument atoms.
buildCallSites :: Array IRFunc -> Map FuncName (Array (Tuple FuncName (Array Atom)))
buildCallSites funcs = foldl perFunc Map.empty funcs
  where
  perFunc acc fn = goExpr fn.name acc fn.body
  goExpr caller = go
    where
    go acc = case _ of
      Return _ -> acc
      Let _ _ (RCallKnown callee args) k ->
        go (Map.insertWith (<>) callee [ Tuple caller args ] acc) k
      Let _ _ _ k -> go acc k
      Switch _ branches dflt ->
        let
          acc1 = foldl (\a (Branch _ b) -> go a b) acc branches
        in
          maybe acc1 (go acc1) dflt
      LitSwitch _ branches dflt ->
        let
          acc1 = foldl (\a (LitBranch _ b) -> go a b) acc branches
        in
          maybe acc1 (go acc1) dflt
      LetRec _ k -> go acc k

-- applying the signatures -----------------------------------------------------

-- | Rewrite a function with its inferred parameter / result reps and per-`Let` slot
-- | reps (the boxing-minimising local rule, reading producer / demand reps across
-- | calls via the signatures).
rewriteFunc :: Map FuncName Sig -> IRFunc -> IRFunc
rewriteFunc sigs fn = fn
  { params = Array.mapWithIndex paramRep fn.params
  -- a lifted code function is called via `call_ref` against the fixed `$Code` type
  -- `(ref $Clo, eqref) -> eqref`, so its parameters and result must stay boxed
  , result = if isCodeFunc then Boxed else exportSafe (repOfTy sig.result)
  , body = rewrite fn.body
  }
  where
  sig :: Sig
  sig = fromMaybe { params: [], result: Bx } (Map.lookup fn.name sigs)
  isCodeFunc = Array.head fn.params == Just CloRef
  -- the host export ABI is `i32` (ADR 0011), so an exported function's `f64`
  -- parameters / result cannot be unboxed at that boundary — keep them `Boxed`.
  isExported = case fn.export of
    Just _ -> true
    Nothing -> false
  exportSafe rep = if isExported && rep == F64 then Boxed else rep
  paramRep i origRep = case origRep of
    CloRef -> CloRef
    _ | isCodeFunc -> origRep
    _ -> exportSafe (repOfTy (fromMaybe Bx (Array.index sig.params i)))
  demands = collectDemands sigs Map.empty fn.body
  countsFor s = fromMaybe emptyCounts (Map.lookup s demands)
  rewrite = case _ of
    Return a -> Return a
    Let slot@(Slot s) _ rhs k ->
      Let slot (chooseRep (producerRep sigs rhs) (countsFor s)) rhs (rewrite k)
    Switch scrut branches dflt ->
      Switch scrut (map (\(Branch t b) -> Branch t (rewrite b)) branches) (map rewrite dflt)
    LitSwitch scrut branches dflt ->
      LitSwitch scrut (map (\(LitBranch p b) -> LitBranch p (rewrite b)) branches) (map rewrite dflt)
    LetRec binds k -> LetRec binds (rewrite k)

-- local slot rule -------------------------------------------------------------

type Counts = { i32 :: Int, f64 :: Int, boxed :: Int }

emptyCounts :: Counts
emptyCounts = { i32: 0, f64: 0, boxed: 0 }

-- | Keep a local slot unboxed when its rhs produces it unboxed and at most one use
-- | boxes it (so the choice never increases the number of boxing allocations).
chooseRep :: Rep -> Counts -> Rep
chooseRep producer counts = case producer of
  I32 | counts.boxed <= 1 -> I32
  F64 | counts.boxed <= 1 -> F64
  _ -> Boxed

producerRep :: Map FuncName Sig -> Rhs -> Rep
producerRep sigs = case _ of
  RPrim intr _ -> primRep intr
  RAtom (ALitInt _) -> I32
  RAtom (ALitNumber _) -> F64
  RCallKnown name _ -> maybe Boxed (repOfTy <<< _.result) (Map.lookup name sigs)
  RCallForeign sig _ -> marshalRep sig.result
  REnumTag _ -> I32
  RProjField _ sig idx -> fromMaybe Boxed (Array.index sig idx)
  _ -> Boxed

-- | Tally, per local slot, the representation each of its uses demands (calls demand
-- | the callee's parameter reps; returns the function's result rep).
collectDemands :: Map FuncName Sig -> Map Int Counts -> AnfExpr -> Map Int Counts
collectDemands sigs = go
  where
  go acc = case _ of
    Return atom -> demand Boxed atom acc
    Let _ _ rhs k -> go (rhsDemands sigs acc rhs) k
    Switch scrut branches dflt ->
      let
        acc1 = demand Boxed scrut acc
        acc2 = foldl (\a (Branch _ b) -> go a b) acc1 branches
      in
        maybe acc2 (go acc2) dflt
    LitSwitch scrut branches dflt ->
      let
        acc1 = demand (litSwitchDemand branches) scrut acc
        acc2 = foldl (\a (LitBranch _ b) -> go a b) acc1 branches
      in
        maybe acc2 (go acc2) dflt
    LetRec recBinds k ->
      go (foldl (\a (RecBind _ _ env) -> boxedAll a env) acc recBinds) k

rhsDemands :: Map FuncName Sig -> Map Int Counts -> Rhs -> Map Int Counts
rhsDemands sigs acc = case _ of
  RPrim intr args -> foldlWithIndex (\i a at -> demand (operandRep intr i) at a) acc args
  RAtom at -> demand Boxed at acc
  RCallKnown name args ->
    foldlWithIndex (\i a at -> demand (calleeParamRep sigs name i) at a) acc args
  RCallForeign sig args ->
    foldlWithIndex (\i a at -> demand (maybe Boxed marshalRep (Array.index sig.params i)) at a) acc args
  RMkData _ sig fields -> foldlWithIndex (\i a at -> demand (fromMaybe Boxed (Array.index sig i)) at a) acc fields
  RMkEnum _ -> acc
  REnumTag at -> demand Boxed at acc
  RProjField at _ _ -> demand Boxed at acc
  RMkRecord pairs -> foldl (\a (Tuple _ at) -> demand Boxed at a) acc pairs
  RProjLabel at _ -> demand Boxed at acc
  RMkArray els -> boxedAll acc els
  RMkClosure _ caps -> boxedAll acc caps
  RApply h ar -> demand Boxed ar (demand Boxed h acc)
  where
  operandRep intr i = fromMaybe Boxed (Array.index (primOperandReps intr) i)

calleeParamRep :: Map FuncName Sig -> FuncName -> Int -> Rep
calleeParamRep sigs name i =
  maybe Boxed (\sig -> repOfTy (fromMaybe Bx (Array.index sig.params i))) (Map.lookup name sigs)

boxedAll :: Map Int Counts -> Array Atom -> Map Int Counts
boxedAll acc = foldl (\a at -> demand Boxed at a) acc

demand :: Rep -> Atom -> Map Int Counts -> Map Int Counts
demand rep atom acc = case atom of
  AVar (Local (Slot s)) -> Map.insertWith mergeCounts s bump acc
  _ -> acc
  where
  bump = case rep of
    I32 -> emptyCounts { i32 = 1 }
    F64 -> emptyCounts { f64 = 1 }
    _ -> emptyCounts { boxed = 1 }

mergeCounts :: Counts -> Counts -> Counts
mergeCounts a b = { i32: a.i32 + b.i32, f64: a.f64 + b.f64, boxed: a.boxed + b.boxed }

litSwitchDemand :: Array LitBranch -> Rep
litSwitchDemand branches = case Array.head branches of
  Just (LitBranch (PInt _) _) -> I32
  Just (LitBranch (PNumber _) _) -> F64
  _ -> Boxed
