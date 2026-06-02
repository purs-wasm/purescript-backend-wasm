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
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Set (Set)
import Data.Set as Set
import Data.String (joinWith)
import Data.Tuple (Tuple(..))
import PureScript.Backend.Wasm.MiddleEnd.FreeVars (binderVars)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.CoreFn (Binder(..), Literal(..), Qualified(..))

type Ctx =
  { newtypeCtors :: Set String -- transparent ctors: a value is its payload (newtype / dict)
  , dataCtors :: Set String -- rigid data ctors, matched by name in `case`
  , inline :: Map String M.Expr -- inlinable top-level bindings, keyed by qualified name
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
    M.Accessor l (M.Lit (LitObject kvs)) -> lookupField l kvs
    M.Case [ scrut ] alts -> caseOfKnown ctx scrut alts
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

-- | A single-scrutinee `case`: select the first alternative whose (single) binder
-- | definitely matches the scrutinee, binding its sub-patterns. Stops at the first
-- | alternative whose match cannot be decided (the scrutinee is not a known
-- | constructor value), leaving the `case` in place; guarded alternatives are left
-- | untouched.
caseOfKnown :: Ctx -> M.Expr -> Array M.Alt -> Maybe M.Expr
caseOfKnown ctx scrut = go
  where
  go alts = case Array.uncons alts of
    Nothing -> Nothing
    Just { head: alt, tail } -> case alt.binders, alt.result of
      [ binder ], Right body -> case matchBinder ctx binder scrut of
        Yes subs -> Just (substMany (Map.fromFoldable subs) body)
        No -> go tail
        Unknown -> Nothing
      _, _ -> Nothing

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

-- substitution ----------------------------------------------------------------

-- | Capture-avoiding simultaneous substitution: replace free local vars per the
-- | map, dropping shadowed names at each binder. (Substituted expressions reference
-- | only names already in scope at the redex, so no freshening is required.)
substMany :: Map String M.Expr -> M.Expr -> M.Expr
substMany = go
  where
  go subs
    | Map.isEmpty subs = identity
    | otherwise = case _ of
        e@(M.Var (Qualified Nothing n)) -> fromMaybe e (Map.lookup n subs)
        e@(M.Var _) -> e
        M.Lit lit -> M.Lit (mapLit (go subs) lit)
        e@(M.Constructor _ _ _) -> e
        M.Accessor l e -> M.Accessor l (go subs e)
        M.Update e cf kvs -> M.Update (go subs e) cf (map (map (go subs)) kvs)
        M.Abs ps b -> M.Abs ps (go (without ps subs) b)
        M.App f args -> M.App (go subs f) (map (go subs) args)
        M.Case ss alts -> M.Case (map (go subs) ss) (map (goAlt subs) alts)
        M.Let bs body ->
          let
            subs' = without (bs >>= boundNames) subs
          in
            M.Let (map (goBind subs') bs) (go subs' body)
  goAlt subs alt =
    let
      subs' = without (alt.binders >>= binderVars) subs
    in
      alt
        { result = case alt.result of
            Right e -> Right (go subs' e)
            Left gs -> Left (map (\g -> { guard: go subs' g.guard, expression: go subs' g.expression }) gs)
        }
  goBind subs = case _ of
    M.NonRec meta i e -> M.NonRec meta i (go subs e)
    M.Rec rs -> M.Rec (map (\r -> r { expr = go subs r.expr }) rs)
  without ks subs = Array.foldr Map.delete subs ks

boundNames :: M.Bind -> Array String
boundNames = case _ of
  M.NonRec _ i _ -> [ i ]
  M.Rec rs -> map _.ident rs

mapLit :: (M.Expr -> M.Expr) -> Literal M.Expr -> Literal M.Expr
mapLit f = case _ of
  LitArray es -> LitArray (map f es)
  LitObject kvs -> LitObject (map (map f) kvs)
  other -> other

qkey :: Qualified String -> Maybe String
qkey = case _ of
  Qualified (Just m) n -> Just (joinWith "." m <> "." <> n)
  Qualified Nothing _ -> Nothing
