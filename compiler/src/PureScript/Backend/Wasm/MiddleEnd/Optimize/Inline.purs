-- | General known-function inlining policy (ADR 0005). Where `DictElim` picks the
-- | type-class plumbing to inline, this picks *ordinary* top-level functions/values
-- | that are safe and worthwhile to inline, and feeds them to the same `Simplify`
-- | engine (as additions to its inline set and transparent-constructor set). Together
-- | with newtype transparency this collapses user abstractions — e.g. a State-monad's
-- | `bind`/`pure`/`get`/`put` inline into their call sites and the `{state, value}`
-- | record plumbing reduces away.
-- |
-- | Two guards keep it cheap and terminating, mirroring `DictElim`:
-- |   * **size / single-use** — a binding is inlined when it is small, or used at most
-- |     once across the whole program (so a single-use inline never grows code).
-- |   * **acyclicity** — the inline set's call graph (restricted to candidates) must be
-- |     acyclic, so the simplifier's inline fixpoint actually converges rather than
-- |     expanding to its fuel limit. Candidates in a call cycle (mutual recursion) are
-- |     dropped; a one-way chain `f → g → h` is kept.
module PureScript.Backend.Wasm.MiddleEnd.Optimize.Inline
  ( inlineCandidates
  , newtypeCtorNames
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (foldMap, foldl)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.Tuple (Tuple(..), fst)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Analysis (exprSize, key, references)
import PureScript.CoreFn (Meta(IsNewtype))

-- | A binding above this size is inlined only when it is used at most once (so it
-- | never grows code); at or below it, even a multi-use binding inlines.
generalInlineCap :: Int
generalInlineCap = 24

-- | The user newtype constructors (`IsNewtype`), as qualified keys. The simplifier
-- | treats these as transparent (a newtype is the identity on its payload), so
-- | `case v of State(f) -> …` becomes `…[f := v]` and the wrap/unwrap of a newtype
-- | monad collapses.
newtypeCtorNames :: Array M.Module -> Set String
newtypeCtorNames modules = Set.fromFoldable (modules >>= \m -> Array.mapMaybe (newtypeOf m.name) m.decls)
  where
  newtypeOf modName = case _ of
    M.NonRec (Just IsNewtype) ident _ -> Just (key modName ident)
    _ -> Nothing

type Cand = { key :: String, rhs :: M.Expr, refs :: Array String }

-- | The general-inline set for a whole program: non-recursive top-level bindings
-- | that are small or single-use, and not part of a call cycle among candidates.
-- | Keyed by qualified name → body.
inlineCandidates :: Array M.Module -> Map String M.Expr
inlineCandidates modules = Map.fromFoldable (Array.filter acyclic eligible)
  where
  binds :: Array Cand
  binds = modules >>= \m -> Array.mapMaybe (bindOf m.name) m.decls
  -- recursive groups are never inlined; a binding whose body is a constructor is left
  -- alone too (the simplifier's `case` matches a *named* ctor reference, so inlining
  -- it to its `Constructor` value would defeat case-of-known-constructor)
  bindOf modName = case _ of
    M.NonRec _ ident rhs
      | not (isCtorBody rhs) -> Just { key: key modName ident, rhs, refs: references rhs }
    _ -> Nothing

  -- program-wide reference counts (with multiplicity), for the single-use test
  uses :: Map String Int
  uses = foldl (\acc r -> Map.insertWith (+) r 1 acc) Map.empty (binds >>= _.refs)
  useCount k = fromMaybe 0 (Map.lookup k uses)

  eligible :: Array (Tuple String M.Expr)
  eligible = Array.mapMaybe toCandidate binds
  toCandidate b
    | Array.elem b.key b.refs = Nothing -- self-recursive
    | exprSize b.rhs <= generalInlineCap || useCount b.key <= 1 = Just (Tuple b.key b.rhs)
    | otherwise = Nothing

  -- drop candidates that lie on a call cycle (so the inline fixpoint terminates)
  eligibleKeys = Set.fromFoldable (map fst eligible)

  adj :: Map String (Set String)
  adj = Map.fromFoldable do
    b <- binds
    if Set.member b.key eligibleKeys then [ Tuple b.key (Set.fromFoldable (Array.filter (_ `Set.member` eligibleKeys) b.refs)) ]
    else []
  reach = transitiveClosure adj
  acyclic (Tuple k _) = not (maybe false (Set.member k) (Map.lookup k reach))

-- | The reflexive-on-cycles transitive closure of a graph: each node mapped to the
-- | set of nodes reachable from it. A node `k` is on a cycle iff `k` is in its own
-- | reachable set. Monotone (sets only grow), so the fixpoint converges.
transitiveClosure :: Map String (Set String) -> Map String (Set String)
transitiveClosure g = go g
  where
  go m =
    let
      m' = step m
    in
      if m' == m then m else go m'
  step m = map (\succs -> succs <> foldMap (\s -> fromMaybe Set.empty (Map.lookup s m)) succs) m

isCtorBody :: M.Expr -> Boolean
isCtorBody = bodyOf >>> case _ of
  M.Constructor _ _ _ -> true
  _ -> false

bodyOf :: M.Expr -> M.Expr
bodyOf = case _ of
  M.Abs _ b -> bodyOf b
  e -> e
