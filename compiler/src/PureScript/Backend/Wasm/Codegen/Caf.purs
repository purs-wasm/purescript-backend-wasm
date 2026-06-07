-- | Which top-level value bindings (CAFs) are compiled to wasm globals, and the
-- | order to initialise them (ADR 0006).
-- |
-- | A CAF here is an **arity-0** function whose value is a scalar or boxed value
-- | (`I32`/`F64`/`Boxed` — a raw closure ref `CloRef` is excluded, it is rare and
-- | sidesteps a closure-cast at the global boundary). After ADR-0015 impurification
-- | an `Effect a` value is an arity-≥1 thunk, so the arity-0 criterion already keeps
-- | effectful module-level bindings out (they are never run at instantiation).
-- |
-- | A CAF that, transitively through the call graph, depends on **itself** is a
-- | value-level cycle (recursive instance dictionaries etc.); it stays a getter
-- | function, deferred to the future laziness work (ADR 0006). The remaining
-- | globalizable CAFs form a DAG and are initialised in dependency order so each is
-- | computed once, after the CAF globals it reads.
module PureScript.Backend.Wasm.Codegen.Caf
  ( CafPlan
  , cafPlan
  ) where

import Prelude

import Data.Array as Array
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.Tuple (Tuple(..))
import PureScript.Backend.Wasm.Lower.IR (AnfExpr(..), Branch(..), FuncName, LitBranch(..), Program, RecBind(..), Rep(..), Rhs(..))

type CafPlan =
  { -- | The globalizable CAFs and the representation each global holds.
    globals :: Map FuncName Rep
  -- | Dependency-topological order to initialise the globals in (a CAF appears
  -- | after every globalized CAF it reads).
  , initOrder :: Array FuncName
  }

cafPlan :: Program -> CafPlan
cafPlan prog = { globals, initOrder }
  where
  -- arity-0, non-closure-ref top-level values
  candList :: Array (Tuple FuncName Rep)
  candList = Array.mapMaybe candidateOf prog.funcs
  candidateOf fn
    | Array.null fn.params && storable fn.result = Just (Tuple fn.name fn.result)
    | otherwise = Nothing
  storable = case _ of
    CloRef -> false
    _ -> true

  candidateNames :: Set FuncName
  candidateNames = Set.fromFoldable (map (\(Tuple n _) -> n) candList)

  -- The call graph over ALL functions: the names whose code can execute (direct
  -- calls) or be built into a closure (and thus later applied) during a function's
  -- evaluation. Conservative — over-approximating only loses globalization, never
  -- correctness of the init order.
  callGraph :: Map FuncName (Set FuncName)
  callGraph = Map.fromFoldable (map (\fn -> Tuple fn.name (bodyEdges fn.body)) prog.funcs)

  succ :: FuncName -> Set FuncName
  succ n = fromMaybe Set.empty (Map.lookup n callGraph)

  -- transitively reachable names from `start` (start itself only if it cycles back)
  reachable :: FuncName -> Set FuncName
  reachable start = go Set.empty (Array.fromFoldable (succ start))
    where
    go seen stack = case Array.uncons stack of
      Nothing -> seen
      Just { head, tail }
        | Set.member head seen -> go seen tail
        | otherwise -> go (Set.insert head seen) (tail <> Array.fromFoldable (succ head))

  -- a CAF reachable from itself is a value-level cycle: not globalizable
  globalizable :: Set FuncName
  globalizable = Set.filter (\a -> not (Set.member a (reachable a))) candidateNames

  globals :: Map FuncName Rep
  globals = Map.filterKeys (\k -> Set.member k globalizable) (Map.fromFoldable candList)

  -- dependency-topological order: post-order DFS over globalized-CAF dependencies
  depsOf :: FuncName -> Set FuncName
  depsOf a = Set.intersection (reachable a) globalizable

  initOrder :: Array FuncName
  initOrder = _.out (Array.foldl visit { seen: Set.empty, out: [] } (Array.fromFoldable globalizable))

  visit acc a
    | Set.member a acc.seen = acc
    | otherwise =
        let
          afterDeps = Array.foldl visit (acc { seen = Set.insert a acc.seen }) (Array.fromFoldable (depsOf a))
        in
          afterDeps { out = Array.snoc afterDeps.out a }

-- | The names a function's evaluation may reach: direct calls (`RCallKnown`) and
-- | the code of closures it constructs (`RMkClosure` / `LetRec`).
bodyEdges :: AnfExpr -> Set FuncName
bodyEdges = go Set.empty
  where
  go acc = case _ of
    Return _ -> acc
    Let _ _ rhs k -> go (rhsEdges rhs acc) k
    Switch _ bs d -> dflt d (Array.foldl (\a (Branch _ b) -> go a b) acc bs)
    LitSwitch _ bs d -> dflt d (Array.foldl (\a (LitBranch _ b) -> go a b) acc bs)
    LetRec rbs k -> go (Array.foldl (\a (RecBind _ name _) -> Set.insert name a) acc rbs) k
    LetJoin _ _ p k -> go (go acc p) k
  dflt d acc = maybe acc (go acc) d
  rhsEdges rhs acc = case rhs of
    RCallKnown name _ -> Set.insert name acc
    RMkClosure name _ -> Set.insert name acc
    _ -> acc
