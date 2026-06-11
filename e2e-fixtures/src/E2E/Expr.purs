module E2E.Expr where

import Prelude

-- A small arithmetic-expression evaluator + pretty-printer. This is an
-- integration scenario: ADTs, nested (decision-tree) pattern matching, a case
-- guard (the `Neg y' <- y` pattern guard purs desugars to a nested case, leaving
-- the trailing `| otherwise`), recursion, `show`, `<>`, and `negate` / `+` / `*`.
data Expr
  = Add Expr Expr
  | Mul Expr Expr
  | Neg Expr
  | Lit Int

eval :: Expr -> Int
eval = case _ of
  Add x y -> eval x + eval y
  Mul x y -> eval x * eval y
  Neg x -> negate (eval x)
  Lit n -> n

-- `prec` is the surrounding operator precedence; a subtree parenthesises itself
-- when it binds looser than its context. `Add x (Neg y')` is rendered as `x - y'`.
printExpr :: Int -> Expr -> String
printExpr prec e = case e of
  Add x y
    | Neg y' <- y ->
        if prec > 1 then "(" <> printExpr 1 x <> " - " <> printExpr 3 y' <> ")"
        else printExpr 1 x <> " - " <> printExpr 3 y'
    | otherwise ->
        if prec > 1 then "(" <> printExpr 1 x <> " + " <> printExpr 1 y <> ")"
        else printExpr 1 x <> " + " <> printExpr 1 y
  Mul x y ->
    if prec > 2 then "(" <> printExpr 2 x <> " * " <> printExpr 2 y <> ")"
    else printExpr 2 x <> " * " <> printExpr 2 y
  Neg x ->
    if prec > 3 then "(-" <> printExpr 3 x <> ")"
    else "-" <> printExpr 3 x
  Lit n -> show n

-- 1 + 2 * (-3)
ex1 :: Expr
ex1 = Add (Lit 1) (Mul (Lit 2) (Neg (Lit 3)))

-- 3 * 5 - 2 + 4 * (2 + 3)
ex2 :: Expr
ex2 = Add (Add (Mul (Lit 3) (Lit 5)) (Neg (Lit 2))) (Mul (Lit 4) (Add (Lit 2) (Lit 3)))

-- i32 entry points (the export ABI is i32-only): eval results, and `printExpr`
-- compared to the expected rendering inside wasm (1 = exact match).
eval1 :: Int
eval1 = eval ex1

eval2 :: Int
eval2 = eval ex2

print1 :: Int
print1 = if printExpr 0 ex1 == "1 + 2 * -3" then 1 else 0

print2 :: Int
print2 = if printExpr 0 ex2 == "3 * 5 - 2 + 4 * (2 + 3)" then 1 else 0
