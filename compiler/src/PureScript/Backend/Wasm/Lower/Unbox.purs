-- | The representation analysis (ADR 0013, front A): assign each `Let`-bound slot a
-- | wasm representation, keeping `Int`/`Number` values unboxed (`I32`/`F64`) where
-- | that avoids a boxing allocation, so that monomorphic arithmetic and its
-- | intermediate results no longer round-trip through `$Int`/`$Num`.
-- |
-- | A slot is unboxed when its rhs naturally produces an unboxed value (an arithmetic
-- | intrinsic or a numeric literal) *and* it flows into at most one boxing (`eqref`)
-- | use — so an unboxed slot never adds a box relative to the boxed default; it only
-- | removes the binding's box and its unboxing uses. The analysis is non-iterative:
-- | a producer's rep and every use's demanded rep are fixed (codegen coerces at the
-- | boundaries). Function parameters and results stay `eqref` here; unboxing those
-- | (so a tail loop runs entirely in `i32`) is a later, whole-program step.
module PureScript.Backend.Wasm.Lower.Unbox
  ( assignReps
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (foldl)
import Data.FoldableWithIndex (foldlWithIndex)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Tuple (Tuple(..))
import PureScript.Backend.Wasm.Lower.IR (AnfExpr(..), Atom(..), Branch(..), IRFunc, LitBranch(..), LitPat(..), RecBind(..), Rep(..), Rhs(..), Slot(..), VarRef(..))
import PureScript.Backend.Wasm.Lower.Reps (primOperandReps, primRep)

type Counts = { i32 :: Int, f64 :: Int, boxed :: Int }

emptyCounts :: Counts
emptyCounts = { i32: 0, f64: 0, boxed: 0 }

assignReps :: IRFunc -> IRFunc
assignReps fn = fn { body = rewrite fn.body }
  where
  demands = collectDemands Map.empty fn.body
  countsFor s = fromMaybe emptyCounts (Map.lookup s demands)
  rewrite = case _ of
    Return a -> Return a
    Let slot@(Slot s) _ rhs k ->
      Let slot (chooseRep (producerRep rhs) (countsFor s)) rhs (rewrite k)
    Switch scrut branches dflt ->
      Switch scrut (map (\(Branch t b) -> Branch t (rewrite b)) branches) (map rewrite dflt)
    LitSwitch scrut branches dflt ->
      LitSwitch scrut (map (\(LitBranch p b) -> LitBranch p (rewrite b)) branches) (map rewrite dflt)
    LetRec binds k -> LetRec binds (rewrite k)

-- | Keep a value unboxed when its rhs produces it unboxed and at most one use boxes
-- | it (so the choice never increases the number of boxing allocations).
chooseRep :: Rep -> Counts -> Rep
chooseRep producer counts = case producer of
  I32 | counts.boxed <= 1 -> I32
  F64 | counts.boxed <= 1 -> F64
  _ -> Boxed

producerRep :: Rhs -> Rep
producerRep = case _ of
  RPrim intr _ -> primRep intr
  RAtom (ALitInt _) -> I32
  RAtom (ALitNumber _) -> F64
  _ -> Boxed

-- | Tally, per local slot, the representation each of its *uses* demands.
collectDemands :: Map Int Counts -> AnfExpr -> Map Int Counts
collectDemands acc = case _ of
  Return atom -> demand Boxed atom acc
  Let _ _ rhs k -> collectDemands (rhsDemands acc rhs) k
  Switch scrut branches dflt ->
    let
      acc1 = demand Boxed scrut acc
      acc2 = foldl (\a (Branch _ b) -> collectDemands a b) acc1 branches
    in
      maybe acc2 (collectDemands acc2) dflt
  LitSwitch scrut branches dflt ->
    let
      acc1 = demand (litSwitchDemand branches) scrut acc
      acc2 = foldl (\a (LitBranch _ b) -> collectDemands a b) acc1 branches
    in
      maybe acc2 (collectDemands acc2) dflt
  LetRec recBinds k ->
    collectDemands (foldl (\a (RecBind _ _ env) -> boxedAll a env) acc recBinds) k

rhsDemands :: Map Int Counts -> Rhs -> Map Int Counts
rhsDemands acc = case _ of
  RPrim intr args -> foldlWithIndex (\i a at -> demand (operandRep intr i) at a) acc args
  RAtom at -> demand Boxed at acc
  RCallKnown _ args -> boxedAll acc args
  RMkData _ fields -> boxedAll acc fields
  RProjField at _ -> demand Boxed at acc
  RMkRecord pairs -> foldl (\a (Tuple _ at) -> demand Boxed at a) acc pairs
  RProjLabel at _ -> demand Boxed at acc
  RMkArray els -> boxedAll acc els
  RMkClosure _ caps -> boxedAll acc caps
  RApply h ar -> demand Boxed ar (demand Boxed h acc)
  where
  operandRep intr i = fromMaybe Boxed (Array.index (primOperandReps intr) i)

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
