-- | An MIR optimization pass (ADR 0005): **lambda-lift recursive local functions**
-- | to top-level supercombinators. A `let`/`where`-bound recursive function group —
-- | either a single self-recursive `Rec` (`where go a b = … go a' b'`) or a
-- | mutually-recursive `Rec` group (`where go … = tryCols … ; tryCols … = … go …`) —
-- | is moved out to fresh top-level bindings whose parameters are the group's shared
-- | captured free variables followed by each function's own parameters; every
-- | reference (a sibling call or the outside use site) becomes that top-level name
-- | partially applied to the captures.
-- |
-- | Why: a local function's self/sibling call goes through its closure (`call_ref`
-- | with boxed arguments), which the `return_call`-based tail-call elimination cannot
-- | reach and the per-function unboxed ABI cannot apply to. After lifting, the call
-- | is a direct call to a known top-level function, so a tail call is eliminated like
-- | any other and its `i32`/`f64` arguments stay unboxed — this is what makes both
-- | `fib`'s `go` (single) and `nqueens`'s `go`/`tryCols`/`placeAt` (mutual) loops run
-- | in constant stack with unboxed arguments.
-- |
-- | This is the MIR counterpart of the former CoreFn `Lower.LambdaLift` pre-pass;
-- | the uncurried IR makes it simpler (a parameter list rather than peeling curried
-- | `Abs`, a partial application as one `App` node rather than a fold).
-- |
-- | Scope: function `Rec` groups (every member a lambda). A non-function recursive
-- | binding in a group leaves the whole group in place.
module PureScript.Backend.Wasm.MiddleEnd.Optimize.LambdaLift
  ( lambdaLiftModule
  ) where

import Prelude

import Control.Monad.State (State, gets, modify_, runState)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (foldl, for_)
import Data.Maybe (Maybe(..))
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import PureScript.Backend.Wasm.MiddleEnd.FreeVars (binderVars, freeVars)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.CoreFn (Literal(..), ModuleName, Qualified(..))

type Sub = Tuple String M.Expr

type LiftM = State { counter :: Int, lifted :: Array M.Bind }

-- | Lift every self-recursive local function in the module to a top-level
-- | supercombinator, prepending the new bindings to the module's declarations.
lambdaLiftModule :: M.Module -> M.Module
lambdaLiftModule m =
  case runState (traverse (liftBind m.name) m.decls) { counter: 0, lifted: [] } of
    Tuple decls st -> m { decls = st.lifted <> decls }

liftBind :: ModuleName -> M.Bind -> LiftM M.Bind
liftBind modName = case _ of
  M.NonRec meta ident e -> M.NonRec meta ident <$> liftExpr modName e
  M.Rec rs -> M.Rec <$> traverse (\r -> (\e -> r { expr = e }) <$> liftExpr modName r.expr) rs

liftExpr :: ModuleName -> M.Expr -> LiftM M.Expr
liftExpr modName = go
  where
  go = case _ of
    M.Lit lit -> M.Lit <$> goLit lit
    e@(M.Constructor _ _ _) -> pure e
    M.Accessor l e -> M.Accessor l <$> go e
    M.Update e cf kvs -> M.Update <$> go e <*> pure cf <*> traverse (traverse go) kvs
    M.Abs ps b -> M.Abs ps <$> go b
    M.App f a -> M.App <$> go f <*> traverse go a
    M.Perform e -> M.Perform <$> go e
    e@(M.Var _) -> pure e
    M.Case ss alts -> M.Case <$> traverse go ss <*> traverse goAlt alts
    M.Let binds body -> liftLet modName binds body
  goLit = case _ of
    LitArray es -> LitArray <$> traverse go es
    LitObject kvs -> LitObject <$> traverse (traverse go) kvs
    other -> pure other
  goAlt alt = do
    result <- case alt.result of
      Right e -> Right <$> go e
      Left guards -> Left <$> traverse (\g -> { guard: _, expression: _ } <$> go g.guard <*> go g.expression) guards
    pure (alt { result = result })

-- | Process a `let`'s bindings left to right: lift each self-recursive function
-- | binding (recording the substitution to apply downstream) and keep the rest.
liftLet :: ModuleName -> Array M.Bind -> M.Expr -> LiftM M.Expr
liftLet modName binds body = go [] [] binds
  where
  go kept subs bs = case Array.uncons bs of
    Nothing -> do
      body' <- liftExpr modName (applySubs subs body)
      pure case kept of
        [] -> body'
        _ -> M.Let kept body'
    Just { head, tail } -> case substBind subs head of
      M.Rec [ r ]
        | M.Abs params lambdaBody <- r.expr -> do
            sub <- liftSelfRecFn modName r.ident params lambdaBody
            go kept (Array.snoc subs sub) tail
      -- a mutually-recursive group of functions (e.g. a `where` block's
      -- `go`/`tryCols`/`safe`) — lift the whole group, sharing its captured frees
      M.Rec rs
        | Array.length rs > 1
        , Just members <- traverse asAbsMember rs -> do
            groupSubs <- liftMutualRecGroup modName members
            go kept (subs <> groupSubs) tail
      other -> do
        other' <- liftBind modName other
        go (Array.snoc kept other') subs tail

-- | Lift one self-recursive function `ident = \params… -> body` to a fresh
-- | top-level `ident$liftN = \frees… params… -> body'`, returning the substitution
-- | `ident ↦ ident$liftN frees…` (the supercombinator partially applied to its
-- | captured free variables) for the reference sites.
liftSelfRecFn :: ModuleName -> String -> Array String -> M.Expr -> LiftM Sub
liftSelfRecFn modName ident params body = do
  let frees = Array.filter (_ /= ident) (freeVars params body)
  n <- gets _.counter
  modify_ \s -> s { counter = s.counter + 1 }
  let
    liftedIdent = ident <> "$lift" <> show n
    liftedVar = M.Var (Qualified (Just modName) liftedIdent)
    -- the replacement for `ident`: the supercombinator applied to its captures
    repl = mkApp liftedVar (map localVar frees)
  -- inside the lifted body the self reference becomes the same partial application
  -- (the captures resolve to the leading parameters there), then lift nested locals
  body' <- liftExpr modName (substVar ident repl body)
  let lambda' = M.Abs (frees <> params) body'
  modify_ \s -> s { lifted = Array.snoc s.lifted (M.NonRec Nothing liftedIdent lambda') }
  pure (Tuple ident repl)

type RecMember = { ident :: String, params :: Array String, body :: M.Expr }

asAbsMember :: forall r. { ident :: String, expr :: M.Expr | r } -> Maybe RecMember
asAbsMember r = case r.expr of
  M.Abs params body -> Just { ident: r.ident, params, body }
  _ -> Nothing

-- | Lift a mutually-recursive group of local functions to top-level
-- | supercombinators sharing one set of captured free variables: each member
-- | becomes `identᵢ$liftN = \frees… paramsᵢ… -> bodyᵢ'`, every reference to a group
-- | member (a sibling call or the outside use site) becomes that member's
-- | supercombinator applied to the shared `frees`. The frees are the free variables
-- | of the whole group minus the members' own names (a sibling reference is not a
-- | capture — it is rewritten to a top-level call).
liftMutualRecGroup :: ModuleName -> Array RecMember -> LiftM (Array Sub)
liftMutualRecGroup modName members = do
  let names = map _.ident members
  let frees = Array.filter (\v -> not (Array.elem v names)) (Array.nub (members >>= \m -> freeVars m.params m.body))
  n <- gets _.counter
  modify_ \s -> s { counter = s.counter + 1 }
  let
    liftedName ident = ident <> "$lift" <> show n
    replFor ident = mkApp (M.Var (Qualified (Just modName) (liftedName ident))) (map localVar frees)
    subs = map (\ident -> Tuple ident (replFor ident)) names
  for_ members \m -> do
    -- rewrite sibling + self references to the lifted supercombinators, then lift
    -- any nested locals in the (now parameter-captured) body
    body' <- liftExpr modName (applySubs subs m.body)
    let lambda' = M.Abs (frees <> m.params) body'
    modify_ \s -> s { lifted = Array.snoc s.lifted (M.NonRec Nothing (liftedName m.ident) lambda') }
  pure subs

-- substitution ---------------------------------------------------------------

applySubs :: Array Sub -> M.Expr -> M.Expr
applySubs subs e = foldl (\acc (Tuple n r) -> substVar n r acc) e subs

substBind :: Array Sub -> M.Bind -> M.Bind
substBind subs = case _ of
  M.NonRec meta i e -> M.NonRec meta i (applySubs subs e)
  M.Rec rs -> M.Rec (map (\r -> r { expr = applySubs subs r.expr }) rs)

-- | Replace free occurrences of the local `name` with `repl`, stopping at any
-- | binder that rebinds `name` (capture avoidance). `repl` only references
-- | already-in-scope names, so no further freshening is needed.
substVar :: String -> M.Expr -> M.Expr -> M.Expr
substVar name repl = go
  where
  go = case _ of
    e@(M.Var (Qualified Nothing n)) -> if n == name then repl else e
    e@(M.Var _) -> e
    M.Lit lit -> M.Lit (goLit lit)
    e@(M.Constructor _ _ _) -> e
    M.Accessor l e -> M.Accessor l (go e)
    M.Update e cf kvs -> M.Update (go e) cf (map (map go) kvs)
    M.Abs ps b -> if Array.elem name ps then M.Abs ps b else M.Abs ps (go b)
    -- a substituted head may itself be an application; keep `App` flat
    M.App f a -> mkApp (go f) (map go a)
    M.Perform e -> M.Perform (go e)
    M.Case ss alts -> M.Case (map go ss) (map goAlt alts)
    M.Let binds body ->
      if Array.elem name (binds >>= boundNames) then M.Let binds body
      else M.Let (map goBind binds) (go body)
  goLit = case _ of
    LitArray es -> LitArray (map go es)
    LitObject kvs -> LitObject (map (map go) kvs)
    other -> other
  goAlt alt =
    if Array.elem name (alt.binders >>= binderVars) then alt
    else alt { result = goResult alt.result }
  goResult = case _ of
    Right e -> Right (go e)
    Left gs -> Left (map (\g -> { guard: go g.guard, expression: go g.expression }) gs)
  goBind = case _ of
    M.NonRec meta i e -> M.NonRec meta i (go e)
    M.Rec rs -> M.Rec (map (\r -> r { expr = go r.expr }) rs)

-- | Smart application that preserves the MIR invariant that an `App` head is never
-- | itself an `App`: applying to an existing application extends its argument list.
mkApp :: M.Expr -> Array M.Expr -> M.Expr
mkApp head args
  | Array.null args = head
  | otherwise = case head of
      M.App h0 args0 -> M.App h0 (args0 <> args)
      _ -> M.App head args

boundNames :: M.Bind -> Array String
boundNames = case _ of
  M.NonRec _ i _ -> [ i ]
  M.Rec rs -> map _.ident rs

localVar :: String -> M.Expr
localVar n = M.Var (Qualified Nothing n)
