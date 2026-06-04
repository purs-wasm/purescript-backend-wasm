-- | Unit tests for impurification (ADR 0015): the rewrite of `Effect`'s opaque
-- | primitives into the `Effect a ≃ Unit -> a` thunk encoding. These pin the property
-- | the type system cannot — that the rewrite **preserves effect semantics**: each
-- | effect is performed exactly once, and `bindE` performs its action *before* its
-- | continuation (left-to-right order). `perform e` is `e` applied to a (unit) `0`.
module Test.Unit.PureScript.Backend.Wasm.MiddleEnd.Optimize.Impurify (spec) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Tuple (snd)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Impurify (impurifyProgram)
import PureScript.CoreFn (Qualified(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

-- references to the three recognised primitives
pureE :: M.Expr
pureE = M.Var (Qualified (Just [ "Effect" ]) "pureE")

bindE :: M.Expr
bindE = M.Var (Qualified (Just [ "Effect" ]) "bindE")

unsafePerform :: M.Expr
unsafePerform = M.Var (Qualified (Just [ "Effect", "Unsafe" ]) "unsafePerformEffect")

loc :: String -> M.Expr
loc n = M.Var (Qualified Nothing n)

-- | `perform e` = the distinct `Perform` node (running the thunk).
perform :: M.Expr -> M.Expr
perform e = M.Perform e

-- | Run a single expression through `impurifyProgram` (as the sole top-level binding)
-- | and recover the rewritten expression.
impurify :: M.Expr -> M.Expr
impurify e =
  fromMaybe e do
    m <- Array.head (impurifyProgram [ { name: [ "T" ], decls: [ M.NonRec Nothing "t" e ] } ])
    decl <- Array.head m.decls
    case decl of
      M.NonRec _ _ e' -> Just e'
      _ -> Nothing

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.MiddleEnd.Optimize.Impurify" do

  it "pureE(a) becomes a thunk that returns a, performing nothing" do
    -- pureE(a) → \$ev -> a   (a is delayed, never performed: a pure value)
    impurify (M.App pureE [ loc "a" ])
      `shouldEqual` M.Abs [ "$ev" ] (loc "a")

  it "unsafePerformEffect(e) performs e exactly once" do
    -- unsafePerformEffect(e) → e(0)   (one perform, no duplication)
    impurify (M.App unsafePerform [ loc "e" ])
      `shouldEqual` perform (loc "e")

  it "bindE(m, \\x -> k) performs m before k, each exactly once (ordering + count)" do
    -- bindE(m, \x -> k) → \$ev -> let x = perform m in perform k
    -- the `let` performs `m` first (binding its result to x), *then* performs `k`:
    -- left-to-right order, and each appears once.
    impurify (M.App bindE [ loc "m", M.Abs [ "x" ] (loc "k") ])
      `shouldEqual`
        M.Abs [ "$ev" ]
          ( M.Let [ M.NonRec Nothing "x" (perform (loc "m")) ]
              (perform (loc "k"))
          )

  it "a nested do (two binds) performs each action exactly once" do
    -- bindE(m1, \x -> bindE(m2, \y -> pureE r)) — both m1 and m2 must be performed
    -- once and only once (no dropped or duplicated effect).
    let
      prog =
        M.App bindE
          [ loc "m1"
          , M.Abs [ "x" ]
              ( M.App bindE
                  [ loc "m2"
                  , M.Abs [ "y" ] (M.App pureE [ loc "r" ])
                  ]
              )
          ]
      out = impurify prog
    performsOf "m1" out `shouldEqual` 1
    performsOf "m2" out `shouldEqual` 1

-- | Count how many times the local `name` is *performed* — i.e. occurs as the callee of
-- | an application to the unit `0`. This is the operational "effect count": one per
-- | actual run of the action.
performsOf :: String -> M.Expr -> Int
performsOf name = go
  where
  here = case _ of
    M.Perform (M.Var (Qualified Nothing n)) -> if n == name then 1 else 0
    _ -> 0
  go e = here e + sub e
  sub = case _ of
    M.App f args -> go f + sum (map go args)
    M.Perform e -> go e
    M.Abs _ b -> go b
    M.Accessor _ x -> go x
    M.Update x _ kvs -> go x + sum (map (go <<< snd) kvs)
    M.Let bs b -> sum (map bindGo bs) + go b
    M.Case ss alts -> sum (map go ss) + sum (map altGo alts)
    M.Lit _ -> 0
    M.Var _ -> 0
    M.Constructor _ _ _ -> 0
  bindGo = case _ of
    M.NonRec _ _ x -> go x
    M.Rec rs -> sum (map (go <<< _.expr) rs)
  altGo alt = case alt.result of
    Right e -> go e
    Left gs -> sum (map (\g -> go g.guard + go g.expression) gs)

sum :: Array Int -> Int
sum = Array.foldl (+) 0
