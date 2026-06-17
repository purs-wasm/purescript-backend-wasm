-- | Dictionary elimination (ADR 0005): the whole-program policy that drives the
-- | MIR `Simplify` engine. It scans every module to find the type-class plumbing —
-- | the transparent dictionary constructors, the method accessors that destructure
-- | them, the instance dictionaries that construct them, and the derived helpers
-- | (`lessThan`, `notEq`, …) that consume them — and feeds them to the simplifier as
-- | its inline set and transparent-constructor set. The simplifier then collapses
-- | `accessor(instance)` down to the underlying implementation.
-- |
-- | This is necessarily whole-program: a use site like `Data.Eq.eq(eqInt)` lives in
-- | one module while `eq` and `eqInt` are defined in another, so the inline set is
-- | built across all linked modules.
-- |
-- | Two guards keep inlining cheap and terminating: a **size cap** (large instances
-- | such as the Generic `to`/`from` records are not inlined) and **acyclicity** (a
-- | derived helper that references another inline candidate is dropped, so the
-- | inline set never forms a cycle).
module PureScript.Backend.Wasm.MiddleEnd.Optimize.DictElim
  ( buildCtx
  , simplifyModule
  , summarize
  , normalFormSizeCap
  ) where

import Prelude

import Data.Array as Array
import Data.Map as Map
import Data.Maybe (Maybe(..), maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.Tuple (Tuple(..))
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Analysis (exprSize, key, qkey, references)
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Inline (generalInlineCap)
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Semantics (normalize)
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Simplify (Ctx, simplifyExpr)
import PureScript.CoreFn (Binder(..), Literal(LitObject), Meta(..), ModuleName, Qualified)

-- | Bindings larger than this are never inlined (keeps code size bounded).
inlineSizeCap :: Int
inlineSizeCap = 32

-- | Build the simplifier context for a whole program: the transparent dictionary
-- | constructors, the rigid data constructors, and the inlinable bindings.
buildCtx :: Array M.Module -> Ctx
buildCtx modules =
  { newtypeCtors: ctors
  , dataCtors: Set.fromFoldable (modules >>= \m -> Array.mapMaybe (dataCtorName m.name) m.decls)
  , inline: Map.fromFoldable (coreInline <> helperInline)
  -- collected from the raw decls (not `infos`), since a plain-record instance that
  -- references itself through a field — `heytingAlgebraBoolean`'s `implies` calls
  -- its own `disj` — is a self-recursive `Rec` binding that `infoOf` skips
  , instanceFields: Map.fromFoldable (modules >>= \m -> m.decls >>= recordFieldsOf m.name)
  -- purity fields default empty here; `MiddleEnd` fills them from the whole-program
  -- effectful-foreign seed + purity analysis (ADR 0015)
  , effectfulForeigns: Set.empty
  , impureBindings: Set.empty
  , memEffBindings: Set.empty
  }
  where
  recordFieldsOf modName = case _ of
    M.NonRec _ ident (M.Lit (LitObject kvs)) -> [ Tuple (key modName ident) kvs ]
    M.Rec rs -> Array.mapMaybe recRecord rs
      where
      recRecord r = case r.expr of
        M.Lit (LitObject kvs) -> Just (Tuple (key modName r.ident) kvs)
        _ -> Nothing
    _ -> []
  ctors = Set.fromFoldable (modules >>= \m -> Array.mapMaybe (dictCtorName m.name) m.decls)
  infos = modules >>= \m -> Array.mapMaybe (infoOf ctors m.name) m.decls

  accessorKeys = Set.fromFoldable (Array.mapMaybe (\i -> if i.category == Just Accessor then Just i.key else Nothing) infos)
  coreInline = Array.mapMaybe coreSelect infos

  -- derived helpers: small non-recursive functions that consume a method accessor,
  -- excluding any that reference another candidate (so the inline set stays acyclic)
  candidates = Array.filter isCandidate infos
  candidateKeys = Set.fromFoldable (map _.key candidates)
  helperInline = Array.mapMaybe acceptHelper candidates

  coreSelect i = case i.category of
    Just DictCtor -> Just (Tuple i.key i.rhs)
    Just _ | i.size <= inlineSizeCap -> Just (Tuple i.key i.rhs)
    -- a trivial alias (`add = Data.Semiring.intAdd`, the residue of dictionary
    -- elimination) inlines so a use `add(x, y)` becomes the intrinsic directly,
    -- rather than calling a nullary CAF and applying its result
    Nothing | isVarAlias i.rhs, not i.selfRef -> Just (Tuple i.key i.rhs)
    _ -> Nothing

  isVarAlias = case _ of
    M.Var _ -> true
    _ -> false

  isCandidate i =
    i.category == Nothing
      && i.isFn
      && not i.selfRef
      && i.size <= inlineSizeCap
      && intersects i.refs accessorKeys

  acceptHelper i = if intersects i.refs candidateKeys then Nothing else Just (Tuple i.key i.rhs)

-- | Prune a finalized dependency module to the subset a *dependent's* optimization context needs
-- | (ADR 0021, streaming b1). `keepKeys` is the set of binding keys whose *bodies* a dependent may
-- | still need: the whole-program inline set (`buildCtx.inline` ∪ general inline candidates, computed
-- | once over the specialized program — so a large single-use cross-module helper such as
-- | `Control.Monad.ap` that the simplifier inlines to expose a `perform` is preserved) plus the
-- | effectful / memory-effecting bindings (so impurification still sees a discarded effect, e.g. a
-- | single-use `modify$specN`). A binding outside `keepKeys` is kept only when it is small, dict
-- | machinery, or an instance record / constructor. Dropping the rest loses only large multi-use
-- | *pure* cross-module bodies (never inlined anyway), so dictionary elimination and effect
-- | preservation are exact — guarded by the cross-module `DictElim` unit test and the `StackSafe` /
-- | `EffectPrim` (`void`) e2e fixtures.
summarize :: Set String -> M.Module -> M.Module
summarize keepKeys m = m { decls = Array.filter keep m.decls }
  where
  keep = case _ of
    M.Rec _ -> true -- recursive instance / dictionary groups (ADR 0008), incl. effectful loops
    M.NonRec meta ident rhs ->
      -- a whole-program inline candidate or an effectful binding …
      Set.member (key m.name ident) keepKeys
        || isDictCtor meta
        || exprSize rhs <= generalInlineCap -- a small (size) inline candidate (post-dict-elim alias)
        || isRecordOrCtor (bodyOf rhs) -- an instance dictionary (record) or a data/dict constructor
  isRecordOrCtor = case _ of
    M.Lit (LitObject _) -> true
    M.Constructor _ _ _ -> true
    _ -> false

-- | Reduce an expression. `useNbE` selects the reducer: the NbE reducer (`Semantics`,
-- | ADR 0020) is the default (`true`); set it to `false` to fall back to the legacy
-- | rule-based `Simplify` engine — e.g. to A/B the two against the test suite.
useNbE :: Boolean
useNbE = true

-- | A reduced declaration larger than this many IR nodes is re-reduced with the inline
-- | context emptied (ADR 0035, the Layer C size guard). Inlining exists to *shrink* code by
-- | firing redexes; when a binding instead inlines into a normal form orders of magnitude
-- | larger than any real declaration — the canonical case is the `genericShow` dictionary of a
-- | large derived-`Generic` ADT inlined into a `show`, which produces no redex, only bulk — it is
-- | pure code-size blow-up. Falling back to the un-inlined form keeps that dictionary an ordinary
-- | call, the same (correct) shape `--no-opt` emits, and is what bounds NbE when a program is
-- | itself `show`-heavy (notably the compiler compiling itself). The threshold sits far above any
-- | genuine declaration (tens of thousands of nodes) and far below the observed blow-ups
-- | (5×10⁵–2×10⁶), so only pathological declarations fall back; the guard measures the *actual*
-- | reduced size, so a large-but-shared normal form (which quote CSEs back down) is kept inlined.
normalFormSizeCap :: Int
normalFormSizeCap = 200_000

reduce :: Ctx -> M.Expr -> M.Expr
reduce ctx e =
  let
    r = reduce1 ctx e
  in
    if exprSize r > normalFormSizeCap && ctxInlines ctx then reduce1 (ctx { inline = Map.empty, instanceFields = Map.empty }) e
    else r
  where
  reduce1 c = if useNbE then normalize c else simplifyExpr c
  ctxInlines c = not (Map.isEmpty c.inline) || not (Map.isEmpty c.instanceFields)

simplifyModule :: Ctx -> M.Module -> M.Module
simplifyModule ctx m = m { decls = map go m.decls }
  where
  go = case _ of
    M.NonRec meta i e -> M.NonRec meta i (reduce ctx e)
    M.Rec rs -> M.Rec (map (\r -> r { expr = reduce ctx r.expr }) rs)

-- classification --------------------------------------------------------------

data Category = DictCtor | Accessor | Instance

derive instance Eq Category

type BindInfo =
  { key :: String
  , rhs :: M.Expr
  , category :: Maybe Category
  , size :: Int
  , selfRef :: Boolean
  , isFn :: Boolean
  , refs :: Array String
  }

infoOf :: Set String -> ModuleName -> M.Bind -> Maybe BindInfo
infoOf ctors modName = case _ of
  M.NonRec meta ident rhs ->
    let
      k = key modName ident
      rs = references rhs
    in
      Just
        { key: k
        , rhs
        , category: classify ctors meta rhs
        , size: exprSize rhs
        , selfRef: Array.elem k rs
        , isFn: isAbs rhs
        , refs: rs
        }
  M.Rec _ -> Nothing

-- | A dictionary constructor (`IsTypeClassConstructor`), a method accessor (a
-- | single-alt case destructuring a transparent constructor), or an instance (a
-- | dictionary constructor applied to its record, possibly under parameters).
classify :: Set String -> Maybe Meta -> M.Expr -> Maybe Category
classify ctors meta rhs
  | isDictCtor meta = Just DictCtor
  | otherwise = case bodyOf rhs of
      M.Case [ _ ] [ alt ]
        | [ ConstructorBinder _ _ ctor _ ] <- alt.binders
        , ctorMember ctors ctor -> Just Accessor
      M.App (M.Var ctor) _ | ctorMember ctors ctor -> Just Instance
      _ -> Nothing

isDictCtor :: Maybe Meta -> Boolean
isDictCtor = case _ of
  Just IsTypeClassConstructor -> true
  _ -> false

bodyOf :: M.Expr -> M.Expr
bodyOf = case _ of
  M.Abs _ b -> bodyOf b
  e -> e

isAbs :: M.Expr -> Boolean
isAbs = case _ of
  M.Abs _ _ -> true
  _ -> false

-- transparent / data constructor names ----------------------------------------

dictCtorName :: ModuleName -> M.Bind -> Maybe String
dictCtorName modName = case _ of
  M.NonRec (Just IsTypeClassConstructor) ident _ -> Just (key modName ident)
  _ -> Nothing

-- | Rigid data constructors are the top-level `Constructor` declarations; their
-- | name is matched by `case` in the simplifier.
dataCtorName :: ModuleName -> M.Bind -> Maybe String
dataCtorName modName = case _ of
  M.NonRec _ ident (M.Constructor _ _ _) -> Just (key modName ident)
  _ -> Nothing

-- keys ------------------------------------------------------------------------

intersects :: Array String -> Set String -> Boolean
intersects refs s = Array.any (_ `Set.member` s) refs

ctorMember :: Set String -> Qualified String -> Boolean
ctorMember ctors q = maybe false (_ `Set.member` ctors) (qkey q)
