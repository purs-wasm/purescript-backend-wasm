-- | Stack-safe structural equality on the middle IR. The derived `Eq Expr`
-- | recurses through the expression tree on the native call stack, which overflows
-- | on the deeply-nested expressions a real closure produces (e.g. array/list
-- | fusion). The optimizer uses equality only as a *fixed-point* convergence check
-- | (`Simplify`'s per-expression loop, `MiddleEnd`'s whole-program loop), so it must
-- | tolerate arbitrary depth. This walks the tree with an explicit work stack — a
-- | tail-recursive `go` that PureScript compiles to a loop — pushing only the `Expr`
-- | children that need comparing and deciding each node's non-`Expr` fields with the
-- | (shallow) derived equality of the leaf types.
module PureScript.Backend.Wasm.MiddleEnd.IR.Eq
  ( eqExpr
  , eqDecls
  , eqModule
  , eqProgram
  ) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (all, foldl)
import Data.List (List(..), (:))
import Data.List as List
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..), fst, snd)
import PureScript.Backend.Wasm.MiddleEnd.IR (Alt, Bind(..), Expr(..), Module)
import PureScript.CoreFn (Literal(..))

-- | Stack-safe `==` on `Expr`.
eqExpr :: Expr -> Expr -> Boolean
eqExpr a b = go (Tuple a b : Nil)

-- | Stack-safe equality on a module's top-level binding groups.
eqDecls :: Array Bind -> Array Bind -> Boolean
eqDecls a b = case eqBinds a b of
  Just children -> go children
  Nothing -> false

eqModule :: Module -> Module -> Boolean
eqModule a b = a.name == b.name && eqDecls a.decls b.decls

-- | Stack-safe equality on a whole translated program.
eqProgram :: Array Module -> Array Module -> Boolean
eqProgram a b = Array.length a == Array.length b && all identity (Array.zipWith eqModule a b)

-- The work loop: each remaining pair must be structurally equal. `shallow` decides a
-- node's own fields and yields the child pairs that still need comparing; a `Nothing`
-- from it means the nodes already differ. Self-tail-recursive, so it runs in constant
-- native stack regardless of expression depth.
go :: List (Tuple Expr Expr) -> Boolean
go = case _ of
  Nil -> true
  Tuple a b : rest -> case shallow a b of
    Nothing -> false
    Just children -> go (children <> rest)

shallow :: Expr -> Expr -> Maybe (List (Tuple Expr Expr))
shallow = case _, _ of
  Lit la, Lit lb -> eqLit la lb
  Var x, Var y -> guardEq (x == y)
  Abs ps a, Abs qs b -> if ps == qs then Just (Tuple a b : Nil) else Nothing
  App f1 a1, App f2 a2
    | Array.length a1 == Array.length a2 -> Just (Tuple f1 f2 : zipPairs a1 a2)
    | otherwise -> Nothing
  Constructor t1 c1 f1, Constructor t2 c2 f2 -> guardEq (t1 == t2 && c1 == c2 && f1 == f2)
  Accessor l1 e1, Accessor l2 e2 -> if l1 == l2 then Just (Tuple e1 e2 : Nil) else Nothing
  Update e1 cf1 kvs1, Update e2 cf2 kvs2
    | cf1 == cf2, map fst kvs1 == map fst kvs2 ->
        Just (Tuple e1 e2 : zipPairs (map snd kvs1) (map snd kvs2))
    | otherwise -> Nothing
  Case ss1 alts1, Case ss2 alts2
    | Array.length ss1 == Array.length ss2 ->
        map (\altChildren -> zipPairs ss1 ss2 <> altChildren) (eqAlts alts1 alts2)
    | otherwise -> Nothing
  Let bs1 b1, Let bs2 b2 -> map (\bindChildren -> bindChildren <> (Tuple b1 b2 : Nil)) (eqBinds bs1 bs2)
  Perform e1, Perform e2 -> Just (Tuple e1 e2 : Nil)
  _, _ -> Nothing

eqLit :: Literal Expr -> Literal Expr -> Maybe (List (Tuple Expr Expr))
eqLit = case _, _ of
  LitInt a, LitInt b -> guardEq (a == b)
  LitNumber a, LitNumber b -> guardEq (a == b)
  LitString a, LitString b -> guardEq (a == b)
  LitChar a, LitChar b -> guardEq (a == b)
  LitBoolean a, LitBoolean b -> guardEq (a == b)
  LitArray a, LitArray b
    | Array.length a == Array.length b -> Just (zipPairs a b)
    | otherwise -> Nothing
  LitObject a, LitObject b
    | map fst a == map fst b -> Just (zipPairs (map snd a) (map snd b))
    | otherwise -> Nothing
  _, _ -> Nothing

eqBinds :: Array Bind -> Array Bind -> Maybe (List (Tuple Expr Expr))
eqBinds = zipChildren eqBind

eqBind :: Bind -> Bind -> Maybe (List (Tuple Expr Expr))
eqBind = case _, _ of
  NonRec m1 i1 e1, NonRec m2 i2 e2 -> if m1 == m2 && i1 == i2 then Just (Tuple e1 e2 : Nil) else Nothing
  Rec r1, Rec r2 ->
    if Array.length r1 == Array.length r2 && all identity (Array.zipWith (\a b -> a.meta == b.meta && a.ident == b.ident) r1 r2) then Just (zipPairs (map _.expr r1) (map _.expr r2))
    else Nothing
  _, _ -> Nothing

eqAlts :: Array Alt -> Array Alt -> Maybe (List (Tuple Expr Expr))
eqAlts = zipChildren eqAlt

eqAlt :: Alt -> Alt -> Maybe (List (Tuple Expr Expr))
eqAlt a b
  | a.binders /= b.binders = Nothing
  | otherwise = case a.result, b.result of
      Right e1, Right e2 -> Just (Tuple e1 e2 : Nil)
      Left g1, Left g2
        | Array.length g1 == Array.length g2 ->
            Just (zipPairs (map _.guard g1) (map _.guard g2) <> zipPairs (map _.expression g1) (map _.expression g2))
        | otherwise -> Nothing
      _, _ -> Nothing

-- Pair up two arrays of children for the work stack. Callers length-check first.
zipPairs :: Array Expr -> Array Expr -> List (Tuple Expr Expr)
zipPairs xs ys = List.fromFoldable (Array.zipWith Tuple xs ys)

-- Compare two arrays element-wise with a fallible child-collector, short-circuiting on
-- a length mismatch or the first differing element.
zipChildren :: forall a. (a -> a -> Maybe (List (Tuple Expr Expr))) -> Array a -> Array a -> Maybe (List (Tuple Expr Expr))
zipChildren f xs ys
  | Array.length xs /= Array.length ys = Nothing
  | otherwise = foldl step (Just Nil) (Array.zip xs ys)
      where
      step acc (Tuple x y) = case acc of
        Nothing -> Nothing
        Just cs -> map (cs <> _) (f x y)

guardEq :: Boolean -> Maybe (List (Tuple Expr Expr))
guardEq true = Just Nil
guardEq false = Nothing
