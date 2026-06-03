-- | The MIR simplifier (ADR 0005): the reduction engine behind dictionary
-- | elimination. Given a context of inlinable top-level bindings, the transparent
-- | (newtype / dict) constructors, and the rigid data constructors, it rewrites an
-- | expression to a fixed point under these local reductions:
-- |
-- |   * **inline**            `f`                    → its body, for `f` in the inline set
-- |   * **beta**              `(\ps -> b)(args)`     → `b` with `ps` bound to `args`
-- |   * **accessor / record** `{… l: v …}.l`        → `v`
-- |   * **case of known ctor** `case C(as) of … C(bs) -> b …` → `b` with `bs` bound to `as`
-- |
-- | The case rule covers both transparent constructors (a newtype/dict binds its
-- | payload) and rigid data constructors (an alternative is selected by matching the
-- | scrutinee's constructor, top to bottom). Together these collapse type-class
-- | dictionary plumbing: a method accessor (`\d -> case d of C(v) -> v.m`) applied to
-- | an instance (`C({ m: impl })`) reduces to `impl`.
module PureScript.Backend.Wasm.MiddleEnd.Optimize.Simplify
  ( Ctx
  , simplifyExpr
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (foldMap, sum)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Set (Set)
import Data.Set as Set
import Data.String (joinWith)
import Data.Tuple (Tuple(..), snd)
import PureScript.Backend.Wasm.MiddleEnd.FreeVars (binderVars, freeVars)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.CoreFn (Ann, Binder(..), Literal(..), Qualified(..))

type Ctx =
  { newtypeCtors :: Set String -- transparent ctors: a value is its payload (newtype / dict)
  , dataCtors :: Set String -- rigid data ctors, matched by name in `case`
  , inline :: Map String M.Expr -- inlinable top-level bindings, keyed by qualified name
  -- top-level bindings whose value is a record literal (a plain-record instance
  -- dictionary, or any constant record), keyed by qualified name → its fields. A
  -- method accessor on such a name (`heytingAlgebraBoolean.disj`) is projected to
  -- the field directly, without materialising the whole record (so a record that
  -- references itself through another field, like `implies`, never expands).
  , instanceFields :: Map String (Array (Tuple String M.Expr))
  }

-- | A generous ceiling on simplification passes; dictionary elimination converges in
-- | a handful, this only bounds pathological cases.
maxPasses :: Int
maxPasses = 1000

-- | Simplify an expression to a fixed point. Each pass rebuilds the expression
-- | bottom-up and applies one top-level reduction per node; passes repeat until the
-- | expression stops changing, bounded by `maxPasses` so that even a pathological
-- | (cyclic) inline set terminates with a partially-reduced — still correct — result.
simplifyExpr :: Ctx -> M.Expr -> M.Expr
simplifyExpr ctx = fixpoint maxPasses
  where
  fixpoint :: Int -> M.Expr -> M.Expr
  fixpoint n e
    | n <= 0 = e
    | otherwise =
        let
          e' = pass e
        in
          if e' == e then e else fixpoint (n - 1) e'

  pass e = let r = descend e in fromMaybe r (step r)

  descend = case _ of
    M.Lit lit -> M.Lit (mapLit pass lit)
    e@(M.Var _) -> e
    e@(M.Constructor _ _ _) -> e
    M.Accessor l e -> M.Accessor l (pass e)
    M.Update e cf kvs -> M.Update (pass e) cf (map (map pass) kvs)
    M.Abs ps b -> M.Abs ps (pass b)
    M.App f args -> M.App (pass f) (map pass args)
    M.Case ss alts -> M.Case (map pass ss) (map passAlt alts)
    M.Let bs body -> M.Let (map passBind bs) (pass body)

  passAlt alt = alt
    { result = case alt.result of
        Right e -> Right (pass e)
        Left gs -> Left (map (\g -> { guard: pass g.guard, expression: pass g.expression }) gs)
    }

  passBind = case _ of
    M.NonRec meta i e -> M.NonRec meta i (pass e)
    M.Rec rs -> M.Rec (map (\r -> r { expr = pass r.expr }) rs)

  step = case _ of
    M.Var q
      | Just key <- qkey q
      , Just body <- Map.lookup key ctx.inline -> Just body
    M.App (M.Abs ps b) args -> Just (betaApp ps b args)
    -- merge a curried lambda introduced by optimization back into one parameter list,
    -- so a saturated self-call becomes a direct (tail-callable) call rather than a
    -- call returning a closure that is then applied — e.g. a State worker collapsed to
    -- `\n -> \s -> … go(n, s') …` becomes the arity-2 `\n s -> …` that TCEs (ADR 0015).
    -- Only when the parameter lists are disjoint, so the merge cannot collide two
    -- params of the same name (which would change which binder a use refers to).
    M.Abs ps (M.Abs qs b)
      | Array.null (Array.intersect ps qs) -> Just (M.Abs (ps <> qs) b)
    -- short-circuit the boolean operators: `a || b` / `a && b` evaluate `b` only
    -- when needed, matching PureScript/JS semantics (and saving work — e.g. the
    -- three comparisons in nqueens' `safe` stop at the first that holds). The
    -- `Boolean` `disj`/`conj` resolve to these foreign intrinsics, which the
    -- backend would otherwise emit as the *strict* `i32.or` / `i32.and`.
    M.App (M.Var q) [ a, b ]
      | qkey q == Just boolDisjKey -> Just (boolCase a (M.Lit (LitBoolean true)) b)
      | qkey q == Just boolConjKey -> Just (boolCase a b (M.Lit (LitBoolean false)))
    -- flatten curried application to the canonical n-ary form, so a partially
    -- applied function (e.g. `ordIntImpl(LT, EQ, GT)`) saturates once its remaining
    -- arguments arrive and is recognised as the intrinsic rather than a closure
    M.App (M.App f as) bs -> Just (M.App f (as <> bs))
    -- commuting conversion: push an application down into a `case`'s branches, so a
    -- branch ending in a (self-)call becomes a tail call rather than the result of an
    -- applied-`case` — e.g. a State worker's `(case … of _ -> \s -> go(n,s'))(s)`
    -- becomes `case … of _ -> go(n,s')`, which TCEs to a constant-stack loop (ADR
    -- 0015). Only when the arguments are trivial (so duplicating them per branch is
    -- free) and no branch binder would capture one of their free variables.
    M.App (M.Case ss alts) args
      | canCommute args alts -> Just (M.Case ss (map (pushArgs args) alts))
    -- split a multi-binding non-recursive let into nested single-binding lets
    -- (order preserved, so a later binding still sees the earlier ones), so the
    -- single-binding inline rule below can reach each one — e.g. `negate = let
    -- sub = intSub; zero = 0 in \a -> sub(zero, a)` collapses to `\a -> intSub(0, a)`
    M.Let bs body
      | Array.length bs > 1
      , Array.all isNonRec bs -> Just (Array.foldr (\b acc -> M.Let [ b ] acc) body bs)
    -- inline a single-use (or dead) non-recursive let binding: this lets the
    -- partial application a dictionary method resolves to (`let cmp =
    -- ordIntImpl(LT, EQ, GT) in … cmp(x, y) …`) flow into its one application and
    -- saturate, instead of staying a heap-allocated closure called via `call_ref`
    M.Let [ M.NonRec _ x e ] body
      | occurrences x body <= 1 -> Just (substMany (Map.singleton x e) body)
    -- inline a let-bound record literal whose fields are all trivial (vars/scalars),
    -- even when used several times: duplicating trivial fields is free, and it lets
    -- the accessor rule below project each `.l` directly — so an intermediate record
    -- (e.g. a State step's `{ state, value }`) never allocates. Safe to substitute now
    -- that `substMany` is capture-avoiding (its `s` field can sit under a `\s`).
    M.Let [ M.NonRec _ x e ] body
      | trivialRecord e -> Just (substMany (Map.singleton x e) body)
    M.Accessor l (M.Lit (LitObject kvs)) -> lookupField l kvs
    -- project a method out of a known plain-record instance by name
    M.Accessor l (M.Var q)
      | Just key <- qkey q
      , Just kvs <- Map.lookup key ctx.instanceFields -> lookupField l kvs
    M.Case scruts alts -> caseOfKnown ctx scruts alts
    _ -> Nothing

-- | `(\ps -> b)(args)`: substitute as many params as there are args. Extra args
-- | are re-applied to the result; missing args leave a residual lambda.
betaApp :: Array String -> M.Expr -> Array M.Expr -> M.Expr
betaApp ps b args =
  let
    n = min (Array.length ps) (Array.length args)
    bound = Map.fromFoldable (Array.zip (Array.take n ps) (Array.take n args))
    body = substMany bound b
    restParams = Array.drop n ps
    restArgs = Array.drop n args
  in
    case Array.null restParams, Array.null restArgs of
      true, true -> body
      false, _ -> M.Abs restParams body
      _, false -> M.App body restArgs

-- case of known constructor ---------------------------------------------------

-- | A `case` over one *or more* scrutinees: select the first alternative whose
-- | binders (one per scrutinee) all definitely match, binding their sub-patterns.
-- | Stops at the first alternative whose match cannot be decided (some scrutinee is
-- | not a known constructor value), leaving the `case` in place; guarded alternatives
-- | are left untouched. The multi-scrutinee form is what PureScript desugars a
-- | multi-argument pattern equation to — e.g. `bind (State g) f = …` becomes `case v,
-- | f of State(g), f1 -> …`, so reducing it is what collapses a function-represented
-- | monad's combinators (ADR 0015).
caseOfKnown :: Ctx -> Array M.Expr -> Array M.Alt -> Maybe M.Expr
caseOfKnown ctx scruts = go
  where
  go alts = case Array.uncons alts of
    Nothing -> Nothing
    Just { head: alt, tail } -> case alt.result of
      Right body -> case matchAll ctx alt.binders scruts of
        Yes subs -> Just (substMany (Map.fromFoldable subs) body)
        No -> go tail
        Unknown -> Nothing
      Left _ -> Nothing

data MatchResult
  = Yes (Array (Tuple String M.Expr))
  | No
  | Unknown

matchBinder :: Ctx -> Binder -> M.Expr -> MatchResult
matchBinder ctx = case _, _ of
  NullBinder _, _ -> Yes []
  VarBinder _ v, scrut -> Yes [ Tuple v scrut ]
  NamedBinder _ n b, scrut -> case matchBinder ctx b scrut of
    Yes subs -> Yes (Array.cons (Tuple n scrut) subs)
    other -> other
  ConstructorBinder _ _ ctor subs, scrut
    | Just key <- qkey ctor, Set.member key ctx.newtypeCtors -> case subs of
        -- a transparent ctor is the identity: the value is its single payload
        [ sub ] -> matchBinder ctx sub scrut
        _ -> Unknown
    | Just key <- qkey ctor -> case asCtorApp ctx scrut of
        Just (Tuple ck cargs)
          | ck == key -> matchAll ctx subs cargs
          | otherwise -> No
        Nothing -> Unknown
    | otherwise -> Unknown
  LiteralBinder _ lit, M.Lit slit -> matchLit lit slit
  LiteralBinder _ _, _ -> Unknown

matchAll :: Ctx -> Array Binder -> Array M.Expr -> MatchResult
matchAll ctx binders args
  | Array.length binders == Array.length args =
      Array.foldl combine (Yes []) (Array.zipWith (matchBinder ctx) binders args)
  | otherwise = No

combine :: MatchResult -> MatchResult -> MatchResult
combine = case _, _ of
  No, _ -> No
  _, No -> No
  Yes a, Yes b -> Yes (a <> b)
  _, _ -> Unknown

-- | A scrutinee that is a saturated application of a known rigid data constructor.
asCtorApp :: Ctx -> M.Expr -> Maybe (Tuple String (Array M.Expr))
asCtorApp ctx = case _ of
  M.Var q | Just k <- qkey q, Set.member k ctx.dataCtors -> Just (Tuple k [])
  M.App (M.Var q) args | Just k <- qkey q, Set.member k ctx.dataCtors -> Just (Tuple k args)
  _ -> Nothing

matchLit :: Literal Binder -> Literal M.Expr -> MatchResult
matchLit = case _, _ of
  LitInt a, LitInt b -> decide (a == b)
  LitNumber a, LitNumber b -> decide (a == b)
  LitString a, LitString b -> decide (a == b)
  LitChar a, LitChar b -> decide (a == b)
  LitBoolean a, LitBoolean b -> decide (a == b)
  _, _ -> Unknown
  where
  decide true = Yes []
  decide false = No

lookupField :: String -> Array (Tuple String M.Expr) -> Maybe M.Expr
lookupField l = Array.findMap \(Tuple k v) -> if k == l then Just v else Nothing

isNonRec :: M.Bind -> Boolean
isNonRec = case _ of
  M.NonRec _ _ _ -> true
  M.Rec _ -> false

-- | A record literal all of whose field values are trivial (a variable or a scalar
-- | literal) — so substituting copies of it costs nothing and lets `.l` project away.
trivialRecord :: M.Expr -> Boolean
trivialRecord = case _ of
  M.Lit (LitObject kvs) -> Array.all (trivialExpr <<< snd) kvs
  _ -> false

trivialExpr :: M.Expr -> Boolean
trivialExpr = case _ of
  M.Var _ -> true
  M.Lit (LitInt _) -> true
  M.Lit (LitNumber _) -> true
  M.Lit (LitString _) -> true
  M.Lit (LitChar _) -> true
  M.Lit (LitBoolean _) -> true
  _ -> false

-- | Whether `App (Case … alts) args` may be pushed into the branches: the arguments
-- | are trivial (no work duplicated by copying them per branch) and no branch's
-- | pattern binds a variable that occurs free in the arguments (which would capture).
canCommute :: Array M.Expr -> Array M.Alt -> Boolean
canCommute args alts =
  Array.all trivialExpr args && Array.all safeAlt alts
  where
  fvs = Set.fromFoldable (args >>= freeVars [])
  safeAlt alt = not (Array.any (_ `Set.member` fvs) (alt.binders >>= binderVars))

-- | Apply `args` to each of an alternative's result expressions (the body, or each
-- | guard's expression — never the guard condition itself).
pushArgs :: Array M.Expr -> M.Alt -> M.Alt
pushArgs args alt = alt
  { result = case alt.result of
      Right e -> Right (M.App e args)
      Left gs -> Left (map (\g -> g { expression = M.App g.expression args }) gs)
  }

-- the `Boolean` `HeytingAlgebra` operators, after dictionary resolution
boolDisjKey :: String
boolDisjKey = "Data.HeytingAlgebra.boolDisj"

boolConjKey :: String
boolConjKey = "Data.HeytingAlgebra.boolConj"

-- | `case cond of true -> t ; _ -> f` — the control-flow form of a short-circuit
-- | boolean operator, so the unchosen branch is never evaluated.
boolCase :: M.Expr -> M.Expr -> M.Expr -> M.Expr
boolCase cond t f =
  M.Case [ cond ]
    [ { binders: [ LiteralBinder zeroAnn (LitBoolean true) ], result: Right t }
    , { binders: [ NullBinder zeroAnn ], result: Right f }
    ]

zeroAnn :: Ann
zeroAnn = { span: { start: origin, end: origin }, meta: Nothing }
  where
  origin = { line: 0, column: 0 }

-- | Count references to a local name `x`. Inner binders that shadow `x` are not
-- | discounted, so this may *over*-count — which only ever suppresses an inline,
-- | never causes one to wrongly duplicate work (`substMany` itself respects
-- | shadowing). Used to gate single-use let inlining.
occurrences :: String -> M.Expr -> Int
occurrences x = go
  where
  go = case _ of
    M.Var (Qualified Nothing n) -> if n == x then 1 else 0
    M.Var _ -> 0
    M.Lit lit -> sum (map go (litExprs lit))
    M.Constructor _ _ _ -> 0
    M.Accessor _ e -> go e
    M.Update e _ kvs -> go e + sum (map (go <<< snd) kvs)
    M.Abs _ b -> go b
    M.App f args -> go f + sum (map go args)
    M.Case ss alts -> sum (map go ss) + sum (map goAlt alts)
    M.Let bs body -> sum (map goBind bs) + go body
  goAlt alt = case alt.result of
    Right e -> go e
    Left gs -> sum (map (\g -> go g.guard + go g.expression) gs)
  goBind = case _ of
    M.NonRec _ _ e -> go e
    M.Rec rs -> sum (map (go <<< _.expr) rs)
  litExprs = case _ of
    LitArray es -> es
    LitObject kvs -> map snd kvs
    _ -> []

-- substitution ----------------------------------------------------------------

-- | Capture-avoiding simultaneous substitution. It carries an **in-scope set** — the
-- | free variables of the replacement terms — so that when it descends under a binder
-- | whose name occurs free in some replacement, it **clones** that binder to a fresh
-- | name (GHC's approach) and renames it in the body, instead of letting the
-- | replacement's free variable be captured. A binder that merely shadows a
-- | substituted name is dropped from the map as before. Capture genuinely arises here:
-- | inlining and β compose independently-named scopes, and the names a monad's
-- | combinators reuse (every `State` step is a `\s -> …`) end up nested.
substMany :: Map String M.Expr -> M.Expr -> M.Expr
substMany subs0 = go (scopeOf subs0) subs0
  where
  scopeOf s = Set.fromFoldable (Array.fromFoldable (Map.values s) >>= freeVars [])

  go :: Set String -> Map String M.Expr -> M.Expr -> M.Expr
  go inScope subs
    | Map.isEmpty subs = identity
    | otherwise = case _ of
        e@(M.Var (Qualified Nothing n)) -> fromMaybe e (Map.lookup n subs)
        e@(M.Var _) -> e
        M.Lit lit -> M.Lit (mapLit (go inScope subs) lit)
        e@(M.Constructor _ _ _) -> e
        M.Accessor l e -> M.Accessor l (go inScope subs e)
        M.Update e cf kvs -> M.Update (go inScope subs e) cf (map (map (go inScope subs)) kvs)
        M.App f args -> M.App (go inScope subs f) (map (go inScope subs) args)
        M.Abs ps b ->
          let
            sc = enterScope inScope subs (allIdents b) ps
          in
            M.Abs (map (renameWith sc.renames) ps) (go sc.inScope sc.subs b)
        M.Case ss alts -> M.Case (map (go inScope subs) ss) (map (goAlt inScope subs) alts)
        M.Let bs body ->
          let
            sc = enterScope inScope subs (foldMap allIdents (bs >>= bindExprs) <> allIdents body) (bs >>= boundNames)
          in
            M.Let (map (goBind sc) bs) (go sc.inScope sc.subs body)
  goAlt inScope subs alt =
    let
      sc = enterScope inScope subs (altIdents alt) (alt.binders >>= binderVars)
    in
      alt
        { binders = map (renameBinder sc.renames) alt.binders
        , result = case alt.result of
            Right e -> Right (go sc.inScope sc.subs e)
            Left gs -> Left (map (\g -> { guard: go sc.inScope sc.subs g.guard, expression: go sc.inScope sc.subs g.expression }) gs)
        }
  goBind sc = case _ of
    M.NonRec meta i e -> M.NonRec meta (renameWith sc.renames i) (go sc.inScope sc.subs e)
    M.Rec rs -> M.Rec (map (\r -> r { ident = renameWith sc.renames r.ident, expr = go sc.inScope sc.subs r.expr }) rs)

type Scope = { renames :: Map String String, subs :: Map String M.Expr, inScope :: Set String }

-- | Descend a substitution under binders `names` (over a body whose identifiers are
-- | `bodyIds`): a name free in some replacement is cloned to a fresh name (recorded in
-- | `renames`, and mapped in `subs` so its body uses rename it); any other bound name
-- | merely shadows, so it is removed from `subs`.
enterScope :: Set String -> Map String M.Expr -> Set String -> Array String -> Scope
enterScope inScope0 subs0 bodyIds names = strip (Array.foldl step seed names)
  where
  seed = { renames: Map.empty, subs: subs0, inScope: inScope0, avoid: Set.union inScope0 (Set.union bodyIds (Set.fromFoldable names)) }
  strip acc = { renames: acc.renames, subs: acc.subs, inScope: acc.inScope }
  step acc p
    | Set.member p inScope0 =
        let
          p' = freshName acc.avoid p
        in
          acc
            { renames = Map.insert p p' acc.renames
            , subs = Map.insert p (M.Var (Qualified Nothing p')) acc.subs
            , inScope = Set.insert p' acc.inScope
            , avoid = Set.insert p' acc.avoid
            }
    | otherwise = acc { subs = Map.delete p acc.subs }

renameWith :: Map String String -> String -> String
renameWith ren n = fromMaybe n (Map.lookup n ren)

-- | A name not in `avoid`, derived from `base` (`$c` marks a capture-avoidance clone).
freshName :: Set String -> String -> String
freshName avoid base = go 0
  where
  go i = let cand = base <> "$c" <> show i in if Set.member cand avoid then go (i + 1) else cand

-- | Every identifier mentioned anywhere in an expression — free *or* bound — so a
-- | fresh clone name can avoid colliding with any of them.
allIdents :: M.Expr -> Set String
allIdents = case _ of
  M.Var (Qualified Nothing n) -> Set.singleton n
  M.Var _ -> Set.empty
  M.Lit lit -> foldMap allIdents (litExprs lit)
  M.Constructor _ _ _ -> Set.empty
  M.Accessor _ e -> allIdents e
  M.Update e _ kvs -> Set.union (allIdents e) (foldMap (allIdents <<< snd) kvs)
  M.Abs ps b -> Set.union (Set.fromFoldable ps) (allIdents b)
  M.App f args -> Set.union (allIdents f) (foldMap allIdents args)
  M.Case ss alts -> Set.union (foldMap allIdents ss) (foldMap altIdents alts)
  M.Let bs body -> Set.union (foldMap bindIdents bs) (allIdents body)
  where
  bindIdents = case _ of
    M.NonRec _ i e -> Set.insert i (allIdents e)
    M.Rec rs -> foldMap (\r -> Set.insert r.ident (allIdents r.expr)) rs

altIdents :: M.Alt -> Set String
altIdents alt = Set.union (Set.fromFoldable (alt.binders >>= binderVars)) $ case alt.result of
  Right e -> allIdents e
  Left gs -> foldMap (\g -> Set.union (allIdents g.guard) (allIdents g.expression)) gs

renameBinder :: Map String String -> Binder -> Binder
renameBinder ren = case _ of
  NullBinder a -> NullBinder a
  VarBinder a n -> VarBinder a (renameWith ren n)
  NamedBinder a n b -> NamedBinder a (renameWith ren n) (renameBinder ren b)
  ConstructorBinder a t c bs -> ConstructorBinder a t c (map (renameBinder ren) bs)
  LiteralBinder a lit -> LiteralBinder a (renameLitBinder lit)
  where
  renameLitBinder = case _ of
    LitArray bs -> LitArray (map (renameBinder ren) bs)
    LitObject kvs -> LitObject (map (map (renameBinder ren)) kvs)
    other -> other

litExprs :: Literal M.Expr -> Array M.Expr
litExprs = case _ of
  LitArray es -> es
  LitObject kvs -> map snd kvs
  _ -> []

boundNames :: M.Bind -> Array String
boundNames = case _ of
  M.NonRec _ i _ -> [ i ]
  M.Rec rs -> map _.ident rs

bindExprs :: M.Bind -> Array M.Expr
bindExprs = case _ of
  M.NonRec _ _ e -> [ e ]
  M.Rec rs -> map _.expr rs

mapLit :: (M.Expr -> M.Expr) -> Literal M.Expr -> Literal M.Expr
mapLit f = case _ of
  LitArray es -> LitArray (map f es)
  LitObject kvs -> LitObject (map (map f) kvs)
  other -> other

qkey :: Qualified String -> Maybe String
qkey = case _ of
  Qualified (Just m) n -> Just (joinWith "." m <> "." <> n)
  Qualified Nothing _ -> Nothing
