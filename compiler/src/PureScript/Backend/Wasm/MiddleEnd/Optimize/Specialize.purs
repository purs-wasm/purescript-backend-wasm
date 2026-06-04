-- | Higher-order specialization (the static-argument transformation, ADR 0005).
-- |
-- | A recursive higher-order function — `filterBy`, `mapList`, `foldlList`, … —
-- | takes a *function* parameter that it passes **unchanged** through its own
-- | recursion (a "static argument"). Where it is called with a known lambda, that
-- | lambda is otherwise compiled to a heap closure and applied per element via an
-- | indirect `call_ref` with boxed operands. This pass instead **specializes the
-- | callee for the lambda**: it emits a copy of the function with the lambda's body
-- | inlined and the function parameter removed, the lambda's free variables threaded
-- | as ordinary leading parameters (as in lambda lifting). The closure and the
-- | `call_ref` disappear; the lambda's body (a comparison, an arithmetic op) inlines
-- | to a direct operation.
-- |
-- | `mapList (\x -> x + 1) xs`  becomes  `mapList$spec0 xs`, where
-- | `mapList$spec0 v = case v of Nil -> Nil ; Cons x xs -> Cons (x + 1) (mapList$spec0 xs)`.
-- |
-- | Specializations are de-duplicated by the callee plus the lambda's *shape* (its
-- | free variables abstracted), so two call sites with the same lambda up to their
-- | captures share one specialization, each passing its own captures.
module PureScript.Backend.Wasm.MiddleEnd.Optimize.Specialize
  ( specializeProgram
  ) where

import Prelude

import Control.Monad.State (State, gets, modify_, runState)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (foldl)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (joinWith)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), snd)
import PureScript.Backend.Wasm.MiddleEnd.FreeVars (binderVars, freeVars)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.CoreFn (Literal(..), ModuleName, Qualified(..))

-- | A top-level function that is a candidate callee: its parameter list, body, and
-- | the indices of its **static function parameters** (passed unchanged through its
-- | own recursion and actually applied).
type FuncInfo =
  { modName :: ModuleName
  , ident :: String
  , params :: Array String
  , body :: M.Expr
  , static :: Array Int
  }

type SpecEntry = { modName :: ModuleName, ident :: String, expr :: M.Expr }

type S = State { counter :: Int, specs :: Map String SpecEntry }

specializeProgram :: Array M.Module -> Array M.Module
specializeProgram modules =
  let
    funcs = Map.fromFoldable (modules >>= moduleFuncs)
    Tuple modules' st = runState (traverse (specModule funcs) modules) { counter: 0, specs: Map.empty }
    specsOf mn = Array.mapMaybe (\e -> if e.modName == mn then Just (M.Rec [ { meta: Nothing, ident: e.ident, expr: e.expr } ]) else Nothing) (Map.values st.specs # Array.fromFoldable)
  in
    map (\m -> m { decls = m.decls <> specsOf m.name }) modules'

-- collect candidate callees ---------------------------------------------------

moduleFuncs :: M.Module -> Array (Tuple String FuncInfo)
moduleFuncs m = Array.mapMaybe (funcOf m.name) m.decls

-- only single self-recursive `Rec` and plain `NonRec` function bindings; mutual
-- groups are not handled (their static-argument analysis is more involved)
funcOf :: ModuleName -> M.Bind -> Maybe (Tuple String FuncInfo)
funcOf modName = case _ of
  M.NonRec _ ident (M.Abs params body) -> Just (mk modName ident params body)
  M.Rec [ r ] | M.Abs params body <- r.expr -> Just (mk modName r.ident params body)
  _ -> Nothing
  where
  mk mn ident params body =
    let
      q = key mn ident
    in
      Tuple q { modName: mn, ident, params, body, static: staticFnParams q params body }

-- | The parameter indices that are *static function arguments*: applied as a
-- | function in the body, and passed unchanged at the same position in every
-- | self-call.
staticFnParams :: String -> Array String -> M.Expr -> Array Int
staticFnParams qname params body =
  Array.mapMaybe check (Array.mapWithIndex Tuple params)
  where
  check (Tuple i p) =
    if isApplied p body && allSelfCallsPass qname i p body then Just i else Nothing

-- p appears as the head of an application `p(...)`
isApplied :: String -> M.Expr -> Boolean
isApplied p = go
  where
  go = case _ of
    M.App (M.Var (Qualified Nothing n)) _ | n == p -> true
    M.App f args -> go f || Array.any go args
    M.Abs ps b -> not (Array.elem p ps) && go b
    M.Lit lit -> Array.any go (litExprs lit)
    M.Accessor _ e -> go e
    M.Perform e -> go e
    M.Update e _ kvs -> go e || Array.any (go <<< snd) kvs
    M.Case ss alts -> Array.any go ss || Array.any altGo alts
    M.Let bs b -> Array.any bindGo bs || (not (Array.elem p (bs >>= boundNames)) && go b)
    _ -> false
  altGo alt = not (Array.elem p (alt.binders >>= binderVars)) && case alt.result of
    Right e -> go e
    Left gs -> Array.any (\g -> go g.guard || go g.expression) gs
  bindGo = case _ of
    M.NonRec _ _ e -> go e
    M.Rec rs -> Array.any (go <<< _.expr) rs

-- every self-call to `qname` passes `Var p` at argument index `i`
allSelfCallsPass :: String -> Int -> String -> M.Expr -> Boolean
allSelfCallsPass qname i p = go
  where
  go = case _ of
    M.App (M.Var q) args
      | qkey q == Just qname -> argOk args && Array.all go args
      | otherwise -> Array.all go args
    M.App f args -> go f && Array.all go args
    M.Abs _ b -> go b
    M.Lit lit -> Array.all go (litExprs lit)
    M.Accessor _ e -> go e
    M.Perform e -> go e
    M.Update e _ kvs -> go e && Array.all (go <<< snd) kvs
    M.Case ss alts -> Array.all go ss && Array.all altGo alts
    M.Let bs b -> Array.all bindGo bs && go b
    _ -> true
  argOk args = case Array.index args i of
    Just (M.Var (Qualified Nothing n)) -> n == p
    _ -> false
  altGo alt = case alt.result of
    Right e -> go e
    Left gs -> Array.all (\g -> go g.guard && go g.expression) gs
  bindGo = case _ of
    M.NonRec _ _ e -> go e
    M.Rec rs -> Array.all (go <<< _.expr) rs

-- transformation --------------------------------------------------------------

specModule :: Map String FuncInfo -> M.Module -> S M.Module
specModule funcs m = do
  decls <- traverse (specBind funcs) m.decls
  pure m { decls = decls }

specBind :: Map String FuncInfo -> M.Bind -> S M.Bind
specBind funcs = case _ of
  M.NonRec meta i e -> M.NonRec meta i <$> specExpr funcs e
  M.Rec rs -> M.Rec <$> traverse (\r -> (\e -> r { expr = e }) <$> specExpr funcs r.expr) rs

specExpr :: Map String FuncInfo -> M.Expr -> S M.Expr
specExpr funcs = go
  where
  go expr = do
    expr' <- descend expr
    case expr' of
      M.App (M.Var q) args
        | Just qn <- qkey q
        , Just info <- Map.lookup qn funcs
        , Just k <- firstSpecializable info args ->
            specializeCall funcs info k args
      _ -> pure expr'

  descend = case _ of
    M.Lit lit -> M.Lit <$> traverseLit go lit
    e@(M.Var _) -> pure e
    e@(M.Constructor _ _ _) -> pure e
    M.Accessor l e -> M.Accessor l <$> go e
    M.Update e cf kvs -> M.Update <$> go e <*> pure cf <*> traverse (traverse go) kvs
    M.Abs ps b -> M.Abs ps <$> go b
    M.App f args -> M.App <$> go f <*> traverse go args
    M.Perform e -> M.Perform <$> go e
    M.Case ss alts -> M.Case <$> traverse go ss <*> traverse goAlt alts
    M.Let bs b -> M.Let <$> traverse goBind bs <*> go b
  goAlt alt = case alt.result of
    Right e -> (\e' -> alt { result = Right e' }) <$> go e
    Left gs -> (\gs' -> alt { result = Left gs' }) <$> traverse (\g -> { guard: _, expression: _ } <$> go g.guard <*> go g.expression) gs
  goBind = case _ of
    M.NonRec meta i e -> M.NonRec meta i <$> go e
    M.Rec rs -> M.Rec <$> traverse (\r -> (\e -> r { expr = e }) <$> go r.expr) rs

-- the first static function-parameter index whose argument is a lambda
firstSpecializable :: FuncInfo -> Array M.Expr -> Maybe Int
firstSpecializable info args = Array.find isLam info.static
  where
  isLam k = case Array.index args k of
    Just (M.Abs _ _) -> true
    _ -> false

specializeCall :: Map String FuncInfo -> FuncInfo -> Int -> Array M.Expr -> S M.Expr
specializeCall funcs info k args = do
  let lam = fromMaybe (M.Lit (LitInt 0)) (Array.index args k)
  let frees = lambdaFrees lam
  let dedup = key info.modName info.ident <> "#" <> show k <> "#" <> canonicalKey frees lam
  existing <- gets (Map.lookup dedup <<< _.specs)
  specIdent <- case existing of
    Just e -> pure e.ident
    Nothing -> createSpec funcs info k lam frees dedup
  let callArgs = map localVar frees <> removeAt k args
  pure (mkApp (M.Var (Qualified (Just info.modName) specIdent)) callArgs)

createSpec :: Map String FuncInfo -> FuncInfo -> Int -> M.Expr -> Array String -> String -> S String
createSpec funcs info k lam frees dedup = do
  n <- gets _.counter
  modify_ \s -> s { counter = s.counter + 1 }
  let specIdent = info.ident <> "$spec" <> show n
  let pk = fromMaybe "" (Array.index info.params k)
  let restParams = removeAt k info.params
  -- inside the spec the lambda's free vars are the leading parameters; the static
  -- parameter is replaced by the lambda, and self-calls go to the specialization
  let specName = Qualified (Just info.modName) specIdent
  let rewritten = substVar pk lam (rewriteSelfCalls (key info.modName info.ident) specName k frees info.body)
  -- register first (so a self-call inside resolves to this spec), then specialize
  -- nested higher-order calls in the body
  modify_ \s -> s { specs = Map.insert dedup { modName: info.modName, ident: specIdent, expr: M.Abs (frees <> restParams) rewritten } s.specs }
  body' <- specExpr funcs rewritten
  modify_ \s -> s { specs = Map.insert dedup { modName: info.modName, ident: specIdent, expr: M.Abs (frees <> restParams) body' } s.specs }
  pure specIdent

-- rewrite every self-call `f(… pk …)` to `f$spec(frees…, … without pk …)`
rewriteSelfCalls :: String -> Qualified String -> Int -> Array String -> M.Expr -> M.Expr
rewriteSelfCalls fqname specName k frees = go
  where
  go = case _ of
    M.App (M.Var q) args
      | qkey q == Just fqname, Array.length args > k ->
          mkApp (M.Var specName) (map localVar frees <> removeAt k (map go args))
    M.App f args -> M.App (go f) (map go args)
    M.Abs ps b -> M.Abs ps (go b)
    M.Lit lit -> M.Lit (mapLit go lit)
    e@(M.Var _) -> e
    e@(M.Constructor _ _ _) -> e
    M.Accessor l e -> M.Accessor l (go e)
    M.Perform e -> M.Perform (go e)
    M.Update e cf kvs -> M.Update (go e) cf (map (map go) kvs)
    M.Case ss alts -> M.Case (map go ss) (map goAlt alts)
    M.Let bs b -> M.Let (map goBind bs) (go b)
  goAlt alt = alt
    { result = case alt.result of
        Right e -> Right (go e)
        Left gs -> Left (map (\g -> { guard: go g.guard, expression: go g.expression }) gs)
    }
  goBind = case _ of
    M.NonRec meta i e -> M.NonRec meta i (go e)
    M.Rec rs -> M.Rec (map (\r -> r { expr = go r.expr }) rs)

-- the lambda's free variables (its own parameters removed)
lambdaFrees :: M.Expr -> Array String
lambdaFrees = case _ of
  M.Abs ps b -> freeVars ps b
  e -> freeVars [] e

-- a structural key for the lambda with its free variables abstracted, so two
-- lambdas equal up to their captures share a specialization
canonicalKey :: Array String -> M.Expr -> String
canonicalKey frees lam =
  show (foldlWithIndexArr (\i e f -> substVar f (M.Var (Qualified Nothing ("#" <> show i))) e) lam frees)

-- substitution / helpers ------------------------------------------------------

-- replace free occurrences of local `name` with `repl`, stopping at shadowing
substVar :: String -> M.Expr -> M.Expr -> M.Expr
substVar name repl = go
  where
  go = case _ of
    e@(M.Var (Qualified Nothing n)) -> if n == name then repl else e
    e@(M.Var _) -> e
    M.Lit lit -> M.Lit (mapLit go lit)
    e@(M.Constructor _ _ _) -> e
    M.Accessor l e -> M.Accessor l (go e)
    M.Update e cf kvs -> M.Update (go e) cf (map (map go) kvs)
    M.Abs ps b -> if Array.elem name ps then M.Abs ps b else M.Abs ps (go b)
    M.App f a -> mkApp (go f) (map go a)
    M.Perform e -> M.Perform (go e)
    M.Case ss alts -> M.Case (map go ss) (map goAlt alts)
    M.Let bs body ->
      if Array.elem name (bs >>= boundNames) then M.Let bs body
      else M.Let (map goBind bs) (go body)
  goAlt alt =
    if Array.elem name (alt.binders >>= binderVars) then alt
    else alt
      { result = case alt.result of
          Right e -> Right (go e)
          Left gs -> Left (map (\g -> { guard: go g.guard, expression: go g.expression }) gs)
      }
  goBind = case _ of
    M.NonRec meta i e -> M.NonRec meta i (go e)
    M.Rec rs -> M.Rec (map (\r -> r { expr = go r.expr }) rs)

-- keep `App` heads flat (never an `App` of an `App`)
mkApp :: M.Expr -> Array M.Expr -> M.Expr
mkApp head args
  | Array.null args = head
  | otherwise = case head of
      M.App h0 a0 -> M.App h0 (a0 <> args)
      _ -> M.App head args

localVar :: String -> M.Expr
localVar n = M.Var (Qualified Nothing n)

removeAt :: forall a. Int -> Array a -> Array a
removeAt i arr = Array.take i arr <> Array.drop (i + 1) arr

boundNames :: M.Bind -> Array String
boundNames = case _ of
  M.NonRec _ i _ -> [ i ]
  M.Rec rs -> map _.ident rs

mapLit :: (M.Expr -> M.Expr) -> Literal M.Expr -> Literal M.Expr
mapLit f = case _ of
  LitArray es -> LitArray (map f es)
  LitObject kvs -> LitObject (map (map f) kvs)
  other -> other

traverseLit :: forall m. Applicative m => (M.Expr -> m M.Expr) -> Literal M.Expr -> m (Literal M.Expr)
traverseLit f = case _ of
  LitArray es -> LitArray <$> traverse f es
  LitObject kvs -> LitObject <$> traverse (traverse f) kvs
  LitInt i -> pure (LitInt i)
  LitNumber n -> pure (LitNumber n)
  LitString s -> pure (LitString s)
  LitChar c -> pure (LitChar c)
  LitBoolean b -> pure (LitBoolean b)

litExprs :: Literal M.Expr -> Array M.Expr
litExprs = case _ of
  LitArray es -> es
  LitObject kvs -> map snd kvs
  _ -> []

foldlWithIndexArr :: forall a b. (Int -> b -> a -> b) -> b -> Array a -> b
foldlWithIndexArr f z arr = foldl (\acc (Tuple i a) -> f i acc a) z (Array.mapWithIndex Tuple arr)

key :: ModuleName -> String -> String
key modName ident = joinWith "." modName <> "." <> ident

qkey :: Qualified String -> Maybe String
qkey = case _ of
  Qualified (Just m) n -> Just (joinWith "." m <> "." <> n)
  Qualified Nothing _ -> Nothing
