-- | A normalisation-by-evaluation (NbE) reducer for the middle IR (ADR 0020).
-- |
-- | This is the replacement for the bottom-up rewrite fixed point in `Simplify`: an
-- | expression is *evaluated* into a semantic domain (`Sem`) where reductions (inline,
-- | β, projection, known-`case`) happen as evaluation steps — and only when their
-- | operands are actually known — then *quoted* back to IR. A construct whose operand
-- | is unknown (a parameter, a recursive self-reference, an opaque foreign) stays a
-- | **neutral** and is rebuilt verbatim, so nothing is duplicated by guessing.
-- |
-- | Why NbE rather than a rule set: inlining becomes a *consequence of reduction* rather
-- | than a syntactic size/use guess. A binding is unfolded only where it leads to a
-- | redex; the quote step is where the inline-vs-share decision will eventually live
-- | (ADR 0020 stage 3). This checkpoint (stage 2) reproduces the *current* policy — it
-- | unfolds exactly the existing inline set and keeps the existing let-inline gates — so
-- | it is behaviour-neutral; the policy change is a later, isolated edit in one place.
module PureScript.Backend.Wasm.MiddleEnd.Optimize.Semantics
  ( normalize
  ) where

import Prelude

import Control.Monad.State (State, get, modify_, put, runState)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Lazy (Lazy, defer, force)
import Data.List (List(..), (:))
import Data.List as List
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Set (Set)
import Data.Set as Set
import Data.String (Pattern(..))
import Data.String as String
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), snd)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Analysis (qkey)
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Purity (PCtx, exprPure, runPure)
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Simplify (Ctx, boolCase, boolConjKey, boolDisjKey, floatAbsOutOfCase, occurrences, smallLambda, trivialRecord)
import PureScript.CoreFn (Binder(..), Literal(..), Meta, Qualified(..))

-- | The local environment: in-scope value variables bound to their semantic values.
type Env = Map String Sem

-- | The semantic domain. Values are fully known (a lambda, a literal, a record, a
-- | known constructor application); a `SNeu` is a stuck computation whose head is not
-- | known and so cannot reduce.
data Sem
  -- an uncurried lambda as a host function: applying it *is* β-reduction. Carries the
  -- original parameter names only so quote can reuse readable binders.
  = SLam (Array String) (Array Sem -> Sem)
  | SLit (Literal Sem)
  | SRecord (Array (Tuple String Sem))
  -- a (possibly partial) application of a known data/newtype constructor, recognised by
  -- name. Kept matchable so `case` over it can select an alternative.
  | SCtorApp (Qualified String) (Array Sem)
  -- a non-recursive `let` decided to be *retained* (shared), not inlined. HOAS: the body
  -- is a function of the bound variable so quote can pick a binder and reify it.
  | SLet String Sem (Sem -> Sem)
  -- a recursive group, never unfolded: bindings (bodies already evaluated with the group
  -- names opaque) plus the continuation semantic value.
  | SLetRec (Array RecB) Sem
  -- a top-level inline candidate that was unfolded, tagged with the qualified binding it came from
  -- (ADR 0035 Layer B/C). Transparent to *reduction* — `unShared` strips it wherever a value is
  -- consumed (β / projection / match / perform) so it never blocks a redex. The tag survives to
  -- `quote` only when the value was used as a *value*, never consumed by a redex: there ADR 0035
  -- Layer C reifies it as a plain **call** to the original binding (`M.Var q`) — shared at the top
  -- level, never copied — rather than materialising the (re-quoted) body. A *trivial* body (an
  -- alias / literal / nullary constructor — unfolding never grows code) is still inlined instead.
  | SShared (Qualified String) Sem
  | SNeu Neu

type RecB = { meta :: Maybe Meta, ident :: String, expr :: Sem }

-- | Stuck computations. Their compound children are themselves `Sem`, so reduction can
-- | still have happened *inside* them even though the head is stuck.
data Neu
  = NLocal String
  | NTop (Qualified String)
  | NApp Sem (Array Sem)
  | NAccessor String Sem
  | NUpdate Sem (Maybe (Array String)) (Array (Tuple String Sem))
  | NCase (Array Sem) (Array NAlt)
  | NPerform Sem
  | NCtorDecl M.Expr -- a constructor *declaration* value, reified verbatim

type NAlt = { binders :: Array Binder, result :: Either (Array NGuard) Sem }
type NGuard = { guard :: Sem, expression :: Sem }

-- | The result of matching a binder against a semantic value.
data Match
  = MYes (Array (Tuple String Sem))
  | MNo
  | MUnknown

-- | Normalise an expression: evaluate to `Sem`, then quote back to IR.
normalize :: Ctx -> M.Expr -> M.Expr
normalize ctx e =
  let
    Tuple body st = runState (quote (pctxOf ctx) (eval ctx memo Set.empty Map.empty e)) initialQ
    -- the CSE'd shared values, hoisted as a `let` at the declaration top. `defs` is most-recent-
    -- first and a binding may reference an earlier one (quoting a value records its dependencies
    -- first), so reverse to dependency order. They are closed, so a single non-recursive group works.
    defs = Array.fromFoldable (List.reverse st.defs)
  in
    if Array.null defs then body
    else M.Let (map (\(Tuple n ex) -> M.NonRec Nothing n ex) defs) body
  where
  initialQ = { counter: 0, shared: Map.empty, defs: Nil }

  -- ADR 0035 Layer A: evaluate each inline-set binding **once** and share the resulting `Sem` at
  -- every use site, rather than re-evaluating its body per reference (the M1 exponential). The memo
  -- is keyed by binding name; `evalVar` forces it. The inline set is a DAG — it is built from
  -- `NonRec` infos in `DictElim.buildCtx`, and mutual recursion is a `Rec` group `infoOf` skips —
  -- so the lazy thunks force without re-entrancy, and a diamond returns the same shared `Sem` on
  -- every path (sound because, being acyclic, a binding never references one of its own ancestors).
  memo :: Map String (Lazy Sem)
  memo = map (\body -> defer \_ -> eval ctx memo Set.empty Map.empty body) ctx.inline

pctxOf :: Ctx -> PCtx
pctxOf ctx = { eff: ctx.effectfulForeigns, impure: ctx.impureBindings, memEff: ctx.memEffBindings }

-- evaluation -----------------------------------------------------------------

-- | `visited` is the set of top-level inline keys currently being unfolded on this
-- | path; a reference to one is left as a call (`NTop`) rather than re-unfolded, which
-- | breaks cycles in the inline set and bounds unfolding depth (the rule-based engine
-- | tolerated cycles only via its `maxPasses` fuel; NbE has no fuel, so it needs this).
eval :: Ctx -> Map String (Lazy Sem) -> Set String -> Env -> M.Expr -> Sem
eval ctx memo = go
  where
  pctx = pctxOf ctx

  go visited env e = case e of
    M.Var q -> evalVar env q
    -- a record literal is the one literal with a reduction (field projection / update),
    -- so it gets its own semantic value; all other literals are inert `SLit`
    M.Lit (LitObject kvs) -> SRecord (map (map (go visited env)) kvs)
    M.Lit lit -> SLit (litToSem (go visited env) lit)
    e@(M.Constructor _ _ _) -> SNeu (NCtorDecl e)
    M.Abs ps body -> SLam ps (\args -> go visited (bindParams env ps args) body)
    M.App f args -> evalApp visited env f args
    M.Accessor l e -> accessor ctx memo visited l (go visited env e)
    M.Update e mb kvs -> update (go visited env e) mb (map (map (go visited env)) kvs)
    M.Perform e -> performSem pctx (go visited env e) e
    M.Case scruts alts -> evalCase ctx memo visited env scruts alts
    M.Let binds body -> evalLet ctx memo visited env binds body

  -- short-circuit the boolean operators into control flow (matching PureScript/JS
  -- semantics and avoiding the strict `i32.or`/`i32.and`), before they apply as foreigns
  evalApp visited env f args = case f, args of
    M.Var q, [ a, b ]
      | qkey q == Just boolDisjKey -> go visited env (boolCase a (M.Lit (LitBoolean true)) b)
      | qkey q == Just boolConjKey -> go visited env (boolCase a b (M.Lit (LitBoolean false)))
    _, _ -> apply (go visited env f) (map (go visited env) args)

  evalVar env = case _ of
    Qualified Nothing x -> fromMaybe (SNeu (NLocal x)) (Map.lookup x env)
    q@(Qualified (Just _) _) -> case qkey q of
      Just k
        -- unfold a binding in the inline set (ADR 0020), but **once** per `normalize`: every
        -- reference shares the memoized `Sem` (ADR 0035 Layer A) instead of re-evaluating the body.
        -- `memo` has an entry for exactly the inline-set keys (`ctx.inline`). The unfolded value is
        -- `SShared`-tagged with `q` so a use site that *consumes* it fires the redex (`unShared`)
        -- while one that uses it *as a value* reifies to a call to `q` at `quote` (ADR 0035 Layer C).
        | Just lz <- Map.lookup k memo -> SShared q (force lz)
        | Set.member k ctx.dataCtors -> SCtorApp q []
        | otherwise -> SNeu (NTop q)
      Nothing -> SNeu (NTop q)

-- | Apply a semantic value to arguments — β when the head is a known lambda (with
-- | arity handling), accumulation for a known constructor, otherwise a stuck `NApp`
-- | (flattened so a curried spine becomes one n-ary application).
-- | Strip the `SShared` tag wherever a value is *consumed* by a reduction, so sharing never
-- | blocks a redex (the tag exists only to let `quote` CSE an unconsumed shared value).
unShared :: Sem -> Sem
unShared = case _ of
  SShared _ s -> unShared s
  s -> s

-- | A semantic value whose unfolding never grows code — an alias to another binding, a literal, or a
-- | nullary constructor. ADR 0035 Layer C still inlines such a value at an unconsumed (value) use
-- | site; anything larger is reified as a plain call to its top-level binding.
trivialSem :: Sem -> Boolean
trivialSem = case _ of
  SNeu (NTop _) -> true
  SNeu (NLocal _) -> true
  SLit _ -> true
  SCtorApp _ [] -> true
  _ -> false

apply :: Sem -> Array Sem -> Sem
apply head args
  | Array.null args = head
  | otherwise = case head of
      SShared _ s -> apply s args
      SLam ps fn ->
        let
          np = Array.length ps
          na = Array.length args
        in
          if na == np then fn args
          else if na > np then apply (fn (Array.take np args)) (Array.drop np args)
          else SLam (Array.drop na ps) (\more -> fn (args <> more))
      SCtorApp q as -> SCtorApp q (as <> args)
      SNeu (NApp h as) -> SNeu (NApp h (as <> args))
      other -> SNeu (NApp other args)

bindParams :: Env -> Array String -> Array Sem -> Env
bindParams env ps args = Array.foldl (\e (Tuple p a) -> Map.insert p a e) env (Array.zip ps args)

accessor :: Ctx -> Map String (Lazy Sem) -> Set String -> String -> Sem -> Sem
accessor ctx memo visited l = case _ of
  SShared _ s -> accessor ctx memo visited l s
  SRecord fs -> fromMaybe (SNeu (NAccessor l (SRecord fs))) (lookupSem l fs)
  -- a transparent (newtype / dictionary) constructor is the identity on its payload, so
  -- a field read sees through it: `Dict({…}).l` is `{…}.l`
  SCtorApp q [ payload ] | Just k <- qkey q, Set.member k ctx.newtypeCtors -> accessor ctx memo visited l payload
  s@(SNeu (NTop q))
    | Just k <- qkey q
    , Just fields <- Map.lookup k ctx.instanceFields
    , not (Set.member k visited) ->
        -- project a method out of a known plain-record instance without materialising it.
        -- Guard against the instance whose fields reference each other (e.g.
        -- `heytingAlgebraBoolean.implies` calls its own `.disj`): mark it visited so the
        -- projected field's own back-reference stays a call rather than looping.
        case Array.find (\(Tuple fl _) -> fl == l) fields of
          Just (Tuple _ fieldExpr) -> eval ctx memo (Set.insert k visited) Map.empty fieldExpr
          Nothing -> SNeu (NAccessor l s)
  s -> SNeu (NAccessor l s)

update :: Sem -> Maybe (Array String) -> Array (Tuple String Sem) -> Sem
update e mb kvs = case e of
  SShared _ s -> update s mb kvs
  SRecord fs -> SRecord (Array.foldl overwrite fs kvs)
  _ -> SNeu (NUpdate e mb kvs)
  where
  overwrite fs (Tuple k v) =
    if Array.any (\(Tuple fk _) -> fk == k) fs then map (\(Tuple fk fv) -> if fk == k then Tuple fk v else Tuple fk fv) fs
    else Array.snoc fs (Tuple k v)

performSem :: PCtx -> Sem -> M.Expr -> Sem
performSem pctx se orig =
  let
    s = unShared se
  in
    case s of
      -- performing a literal thunk runs its body (apply to the unit); always sound, even
      -- for an effectful body — this is the pure-`Effect` collapse's entry point
      SLam _ _ -> apply s [ unit_ ]
      _
        | runPure pctx orig -> apply s [ unit_ ]
        | otherwise -> SNeu (NPerform s)
  where
  unit_ = SLit (LitInt 0)

-- case ------------------------------------------------------------------------

evalCase :: Ctx -> Map String (Lazy Sem) -> Set String -> Env -> Array M.Expr -> Array M.Alt -> Sem
evalCase ctx memo visited env scrutsE alts =
  let
    scruts = map (eval ctx memo visited env) scrutsE
  in
    case selectAlt ctx memo visited env scruts alts of
      Just sem -> sem
      Nothing -> SNeu (NCase scruts (map (evalAlt ctx memo visited env) alts))

-- | Select the first alternative that definitely matches (binding its sub-patterns),
-- | stopping — and leaving the whole `case` — at the first undecidable or guarded
-- | alternative. Mirrors `Simplify.caseOfKnown`.
selectAlt :: Ctx -> Map String (Lazy Sem) -> Set String -> Env -> Array Sem -> Array M.Alt -> Maybe Sem
selectAlt ctx memo visited env scruts = go
  where
  go alts = case Array.uncons alts of
    Nothing -> Nothing
    Just { head: alt, tail } -> case alt.result of
      Right body -> case matchAllSem ctx alt.binders scruts of
        MYes subs -> Just (eval ctx memo visited (Array.foldl (\e (Tuple x s) -> Map.insert x s e) env subs) body)
        MNo -> go tail
        MUnknown -> Nothing
      Left _ -> Nothing

-- | Evaluate an alternative's body(ies) with its binder variables bound to opaque
-- | locals (the scrutinee is not known, so the bound values are not either).
evalAlt :: Ctx -> Map String (Lazy Sem) -> Set String -> Env -> M.Alt -> NAlt
evalAlt ctx memo visited env alt =
  let
    env' = Array.foldl (\e v -> Map.insert v (SNeu (NLocal v)) e) env (alt.binders >>= binderVars)
  in
    { binders: alt.binders
    , result: case alt.result of
        Right e -> Right (eval ctx memo visited env' e)
        Left gs -> Left (map (\g -> { guard: eval ctx memo visited env' g.guard, expression: eval ctx memo visited env' g.expression }) gs)
    }

matchAllSem :: Ctx -> Array Binder -> Array Sem -> Match
matchAllSem ctx binders args
  | Array.length binders == Array.length args =
      Array.foldl combine (MYes []) (Array.zipWith (matchSem ctx) binders args)
  | otherwise = MNo

matchSem :: Ctx -> Binder -> Sem -> Match
matchSem ctx = case _, _ of
  NullBinder _, _ -> MYes []
  VarBinder _ v, s -> MYes [ Tuple v s ]
  NamedBinder _ n b, s -> case matchSem ctx b s of
    MYes subs -> MYes (Array.cons (Tuple n s) subs)
    other -> other
  ConstructorBinder _ _ ctor subs, s
    | Just k <- qkey ctor, Set.member k ctx.newtypeCtors -> case subs of
        [ sub ] -> matchSem ctx sub s -- transparent newtype: the value is its payload
        _ -> MUnknown
    | Just k <- qkey ctor -> case unShared s of
        SCtorApp q cargs
          | qkey q == Just k -> matchAllSem ctx subs cargs
          | otherwise -> MNo
        _ -> MUnknown
    | otherwise -> MUnknown
  LiteralBinder _ lit, s -> case unShared s of
    SLit slit -> matchLitSem lit slit
    _ -> MUnknown

matchLitSem :: Literal Binder -> Literal Sem -> Match
matchLitSem = case _, _ of
  LitInt a, LitInt b -> decide (a == b)
  LitNumber a, LitNumber b -> decide (a == b)
  LitString a, LitString b -> decide (a == b)
  LitChar a, LitChar b -> decide (a == b)
  LitBoolean a, LitBoolean b -> decide (a == b)
  _, _ -> MUnknown
  where
  decide true = MYes []
  decide false = MNo

combine :: Match -> Match -> Match
combine = case _, _ of
  MNo, _ -> MNo
  _, MNo -> MNo
  MYes a, MYes b -> MYes (a <> b)
  _, _ -> MUnknown

-- let -------------------------------------------------------------------------

-- | Evaluate a `let`. A multi-binding non-recursive group is treated as nested
-- | single bindings (order preserved), each inlined or retained per the current gates
-- | (single-use/dead pure, trivial record, small lambda); a recursive group is retained,
-- | its bound variables opaque (never unfolded — that is the infinite-loop hazard).
evalLet :: Ctx -> Map String (Lazy Sem) -> Set String -> Env -> Array M.Bind -> M.Expr -> Sem
evalLet ctx memo visited env binds body = case Array.uncons binds of
  Nothing -> eval ctx memo visited env body
  Just { head: M.NonRec _ x rhs, tail } ->
    let
      rhsSem = eval ctx memo visited env rhs
      rest e = evalLet ctx memo visited e tail body
    in
      if inlineLet ctx x rhs body then rest (Map.insert x rhsSem env)
      else SLet x rhsSem (\xv -> rest (Map.insert x xv env))
  Just { head: M.Rec rs, tail } ->
    let
      env' = Array.foldl (\e r -> Map.insert r.ident (SNeu (NLocal r.ident)) e) env rs
      rs' = map (\r -> { meta: r.meta, ident: r.ident, expr: eval ctx memo visited env' r.expr }) rs
    in
      SLetRec rs' (evalLet ctx memo visited env' tail body)

-- | Whether a `let` binding should be inlined rather than retained — the *current*
-- | policy (ADR 0020 stage 2): single-use or dead and pure, or a trivial record, or a
-- | small lambda. Stage 3 replaces this with a reduction-aware decision.
inlineLet :: Ctx -> String -> M.Expr -> M.Expr -> Boolean
inlineLet ctx x rhs body =
  (occurrences x body <= 1 && exprPure (pctxOf ctx) rhs)
    || trivialRecord rhs
    || smallLambda rhs

-- quote -----------------------------------------------------------------------

-- | `quote`'s state (ADR 0035 Layer B): the fresh-binder counter, plus the CSE table for shared
-- | values — `shared` maps a memo key to the `let` name its quoted value was bound to, and `defs`
-- | accumulates those `(name, expr)` bindings (most-recent-first) to hoist at the top of the
-- | normalized declaration. The shared values are inline bindings, evaluated with an empty
-- | environment, so their quoted expressions are closed and hoist without capture.
type QState = { counter :: Int, shared :: Map String String, defs :: List (Tuple String M.Expr) }

type Q = State QState

quote :: PCtx -> Sem -> Q M.Expr
quote pctx sem = case sem of
  -- merge a directly-nested lambda into one parameter list (disjoint params), so a
  -- curried worker `\n -> \s -> …` becomes the arity-2 `\n s -> …` whose saturated
  -- self-call is a direct, tail-callable call (constant-stack TCE; ADR 0015). Binders
  -- are freshened (below) so the merge's disjointness always holds.
  SLam ps fn -> do
    ps' <- traverse fresh ps
    mergeAbs ps' <$> quote pctx (fn (map (SNeu <<< NLocal) ps'))
  SLit lit -> M.Lit <$> quoteLit pctx lit
  SRecord fs -> M.Lit <<< LitObject <$> traverse (\(Tuple k v) -> Tuple k <$> quote pctx v) fs
  SCtorApp q args ->
    if Array.null args then pure (M.Var q)
    else M.App (M.Var q) <$> traverse (quote pctx) args
  -- freshen the bound name so two retained lets with the same source name (e.g. the
  -- `$x` impurify emits per bind step) cannot shadow/collide — the capture-avoidance
  -- the old `substMany` did, now done once at reification.
  SLet x rhs k -> do
    rhs' <- quote pctx rhs
    x' <- fresh x
    body <- quote pctx (k (SNeu (NLocal x')))
    pure (M.Let [ M.NonRec Nothing x' rhs' ] body)
  SLetRec rs body -> do
    rs' <- traverse (\r -> (\e -> { meta: r.meta, ident: r.ident, expr: e }) <$> quote pctx r.expr) rs
    body' <- quote pctx body
    pure (M.Let [ M.Rec rs' ] body')
  -- ADR 0035 Layer C: an unfolded candidate that survived to `quote` was used *as a value* (a
  -- consuming use site would have stripped the `SShared` tag and fired a redex). Reify it as a plain
  -- **call** to the original top-level binding — shared at the top level, never copying the body —
  -- which also avoids the M2 re-quote explosion (the body is quoted once, in its own declaration).
  -- A *trivial* body (alias / literal / nullary constructor) is inlined instead, since unfolding it
  -- never grows code and keeps a direct intrinsic / literal at the use site.
  SShared q s ->
    let s' = unShared s
    in if trivialSem s' then quote pctx s' else pure (M.Var q)
  SNeu n -> quoteNeu pctx n

quoteNeu :: PCtx -> Neu -> Q M.Expr
quoteNeu pctx = case _ of
  NLocal x -> pure (M.Var (Qualified Nothing x))
  NTop q -> pure (M.Var q)
  NCtorDecl e -> pure e
  NApp h args -> M.App <$> quote pctx h <*> traverse (quote pctx) args
  NAccessor l s -> M.Accessor l <$> quote pctx s
  NUpdate s mb kvs -> (\s' kvs' -> M.Update s' mb kvs') <$> quote pctx s <*> traverse (\(Tuple k v) -> Tuple k <$> quote pctx v) kvs
  NPerform s -> M.Perform <$> quote pctx s
  NCase scruts alts -> do
    scruts' <- traverse (quote pctx) scruts
    alts' <- traverse (quoteAlt pctx) alts
    -- float a common single-parameter lambda out of every branch (so the freed binder
    -- merges into the enclosing worker's parameter list and the self-call saturates to a
    -- tail call) — only when the scrutinees are pure, so floating cannot move an effect.
    pure case floatAbsOutOfCase scruts' alts' of
      Just floated | Array.all (exprPure pctx) scruts' -> floated
      _ -> M.Case scruts' alts'

quoteAlt :: PCtx -> NAlt -> Q M.Alt
quoteAlt pctx alt = do
  result <- case alt.result of
    Right e -> Right <$> quote pctx e
    Left gs -> Left <$> traverse (\g -> (\gd ex -> { guard: gd, expression: ex }) <$> quote pctx g.guard <*> quote pctx g.expression) gs
  pure { binders: alt.binders, result }

quoteLit :: PCtx -> Literal Sem -> Q (Literal M.Expr)
quoteLit pctx = case _ of
  LitArray es -> LitArray <$> traverse (quote pctx) es
  LitObject kvs -> LitObject <$> traverse (\(Tuple k v) -> Tuple k <$> quote pctx v) kvs
  LitInt i -> pure (LitInt i)
  LitNumber n -> pure (LitNumber n)
  LitString s -> pure (LitString s)
  LitChar c -> pure (LitChar c)
  LitBoolean b -> pure (LitBoolean b)

-- helpers ---------------------------------------------------------------------

-- | A fresh binder name derived from a base, unique within one `normalize` call (the
-- | counter is threaded through quote). `$q` marks an NbE-reified binder; any prior
-- | `$q` suffix is stripped first so re-normalising an already-normalised expression
-- | (each `normalize` call resets the counter and quotes deterministically) reproduces
-- | identical names rather than churning a fresh `$q` suffix on every pass — which keeps
-- | the repeated simplify passes (`localOpt` runs simplify → impurify → simplify) stable.
fresh :: String -> Q String
fresh base0 = do
  let
    base = case String.indexOf (Pattern "$q") base0 of
      Just i -> String.take i base0
      Nothing -> base0
  st <- get
  put st { counter = st.counter + 1 }
  pure (base <> "$q" <> show st.counter)

mergeAbs :: Array String -> M.Expr -> M.Expr
mergeAbs ps = case _ of
  M.Abs qs b | Array.null (Array.intersect ps qs) -> M.Abs (ps <> qs) b
  b -> M.Abs ps b

lookupSem :: String -> Array (Tuple String Sem) -> Maybe Sem
lookupSem l = Array.findMap (\(Tuple k v) -> if k == l then Just v else Nothing)

litToSem :: (M.Expr -> Sem) -> Literal M.Expr -> Literal Sem
litToSem f = case _ of
  LitArray es -> LitArray (map f es)
  LitObject kvs -> LitObject (map (map f) kvs)
  LitInt i -> LitInt i
  LitNumber n -> LitNumber n
  LitString s -> LitString s
  LitChar c -> LitChar c
  LitBoolean b -> LitBoolean b

binderVars :: Binder -> Array String
binderVars = case _ of
  NullBinder _ -> []
  VarBinder _ v -> [ v ]
  NamedBinder _ n b -> Array.cons n (binderVars b)
  ConstructorBinder _ _ _ bs -> bs >>= binderVars
  LiteralBinder _ lit -> case lit of
    LitArray bs -> bs >>= binderVars
    LitObject kvs -> kvs >>= (binderVars <<< snd)
    _ -> []
