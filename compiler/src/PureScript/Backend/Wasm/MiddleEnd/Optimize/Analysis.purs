-- | Pure MIR analysis utilities shared by the optimization passes (`DictElim`,
-- | `Inline`): the size of an expression, the top-level (qualified) names it
-- | references, and the key helpers that name a top-level binding. Kept separate so
-- | neither pass owns them (ADR 0005).
module PureScript.Backend.Wasm.MiddleEnd.Optimize.Analysis
  ( exprSize
  , references
  , litExprs
  , key
  , qkey
  ) where

import Prelude

import Data.Either (Either(..))
import Data.Foldable (sum)
import Data.Maybe (Maybe(..), maybe)
import Data.String (joinWith)
import Data.Tuple (snd)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.CoreFn (Literal(..), ModuleName, Qualified(..))

-- | A node count for an expression: the inlining size budget.
exprSize :: M.Expr -> Int
exprSize = case _ of
  M.Lit lit -> 1 + sum (map exprSize (litExprs lit))
  M.Var _ -> 1
  M.Constructor _ _ _ -> 1
  M.Accessor _ e -> 1 + exprSize e
  M.Update e _ kvs -> 1 + exprSize e + sum (map (exprSize <<< snd) kvs)
  M.Abs _ b -> 1 + exprSize b
  M.App f args -> 1 + exprSize f + sum (map exprSize args)
  M.Perform e -> 1 + exprSize e
  M.Case scruts alts -> 1 + sum (map exprSize scruts) + sum (map altSize alts)
  M.Let binds body -> 1 + sum (map bindSize binds) + exprSize body
  where
  altSize alt = case alt.result of
    Right e -> exprSize e
    Left gs -> sum (map (\g -> exprSize g.guard + exprSize g.expression) gs)
  bindSize = case _ of
    M.NonRec _ _ e -> exprSize e
    M.Rec rs -> sum (map (exprSize <<< _.expr) rs)

-- | Every top-level (qualified) name an expression references, with multiplicity
-- | (so callers can both test membership and count uses).
references :: M.Expr -> Array String
references = case _ of
  M.Var q -> maybe [] pure (qkey q)
  M.Lit lit -> litExprs lit >>= references
  M.Constructor _ _ _ -> []
  M.Accessor _ e -> references e
  M.Update e _ kvs -> references e <> (kvs >>= references <<< snd)
  M.Abs _ b -> references b
  M.App f args -> references f <> (args >>= references)
  M.Perform e -> references e
  M.Case scruts alts -> (scruts >>= references) <> (alts >>= altExprs >>= references)
  M.Let binds body -> (binds >>= bindExprs >>= references) <> references body
  where
  altExprs alt = case alt.result of
    Right e -> [ e ]
    Left gs -> gs >>= \g -> [ g.guard, g.expression ]
  bindExprs = case _ of
    M.NonRec _ _ e -> [ e ]
    M.Rec rs -> map _.expr rs

litExprs :: Literal M.Expr -> Array M.Expr
litExprs = case _ of
  LitArray es -> es
  LitObject kvs -> map snd kvs
  _ -> []

-- | The qualified key of a top-level binding (`Data.Maybe.fromMaybe`).
key :: ModuleName -> String -> String
key modName ident = joinWith "." modName <> "." <> ident

qkey :: Qualified String -> Maybe String
qkey = case _ of
  Qualified (Just m) n -> Just (joinWith "." m <> "." <> n)
  Qualified Nothing _ -> Nothing
