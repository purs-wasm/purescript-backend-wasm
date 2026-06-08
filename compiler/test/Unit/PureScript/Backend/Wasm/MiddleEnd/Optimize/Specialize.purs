-- | Unit tests for higher-order specialization: a recursive function with a static
-- | function argument, called with a lambda, gets a specialized copy and the call
-- | site is rewritten to it.
module Test.Unit.PureScript.Backend.Wasm.MiddleEnd.Optimize.Specialize (spec) where

import Prelude

import Data.Array as Array
import Data.Either (Either(..))
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Set as Set
import Data.String (Pattern(..), contains)
import PureScript.Backend.Wasm.MiddleEnd (optimizeProgram)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Specialize (specializeProgram)
import PureScript.Backend.Wasm.MiddleEnd.Transl (translModule)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)
import Test.Unit.PureScript.Backend.Wasm.Lower.Common (appE, def, lam, lv, moduleNamed, qv)

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.MiddleEnd.Optimize.Specialize" do
  it "specializes a recursive higher-order function at a lambda call site" do
    -- recf g x = g (recf g x)   -- g is a static function argument (applied,
    --                              passed unchanged in the self-call)
    -- use z   = recf (\y -> y) z
    let
      recf = def "recf" (lam "g" (lam "x" (appE (lv "g") (appE (appE (qv "recf") (lv "g")) (lv "x")))))
      use = def "use" (lam "z" (appE (appE (qv "recf") (lam "y" (lv "y"))) (lv "z")))
      out = specializeProgram [ translModule (moduleNamed [ "T" ] [ recf, use ]) ]
    case Array.head out of
      Nothing -> fail "expected a module"
      Just m -> do
        -- a specialization binding was appended
        let names = m.decls >>= declNames
        Array.any (contains (Pattern "recf$spec")) names `shouldEqual` true
        -- `use` no longer applies `recf` to a lambda — it calls the specialization
        case Array.find (declIs "use") m.decls of
          Just (M.NonRec _ _ (M.Abs _ body)) -> hasSpecCall body `shouldEqual` true
          _ -> fail "expected use to remain a function"

  -- ADR 0027: the `where`-worker idiom defeats the pre-inline specialization pass.
  it "specializes a forwarder / where-worker idiom after inlining (optimizeProgram)" do
    -- worker g x = g (worker g x)   -- the applier: static `g`, self-recursive
    -- foo g x    = worker g x       -- a forwarder: passes `g`, never applies it
    -- use z      = foo (\y -> y) z  -- the lambda reaches only the forwarder
    -- Pre-inline specialization cannot fire (foo is not a static-arg candidate; worker's
    -- call sites get the forwarded *variable*, not a lambda). Only after `optimizeProgram`
    -- inlines `foo` does the lambda land at `worker`'s call site, where the post-inline
    -- specialization pass fuses it — so a `worker$spec` must appear.
    let
      worker = def "worker" (lam "g" (lam "x" (appE (lv "g") (appE (appE (qv "worker") (lv "g")) (lv "x")))))
      foo = def "foo" (lam "g" (lam "x" (appE (appE (qv "worker") (lv "g")) (lv "x"))))
      use = def "use" (lam "z" (appE (appE (qv "foo") (lam "y" (lv "y"))) (lv "z")))
      out = optimizeProgram true Set.empty Map.empty [ moduleNamed [ "T" ] [ worker, foo, use ] ]
    case Array.find (\m -> m.name == [ "T" ]) out of
      Nothing -> fail "expected module T"
      Just m ->
        Array.any (contains (Pattern "worker$spec")) (m.decls >>= declNames) `shouldEqual` true

declNames :: M.Bind -> Array String
declNames = case _ of
  M.NonRec _ i _ -> [ i ]
  M.Rec rs -> map _.ident rs

declIs :: String -> M.Bind -> Boolean
declIs name = case _ of
  M.NonRec _ i _ -> i == name
  _ -> false

-- the body applies some `…$spec…` function
hasSpecCall :: M.Expr -> Boolean
hasSpecCall = go
  where
  go = case _ of
    M.App f args -> headIsSpec f || go f || Array.any go args
    M.Abs _ b -> go b
    M.Accessor _ e -> go e
    M.Case ss alts -> Array.any go ss || Array.any altGo alts
    M.Let bs b -> go b || Array.any bindGo bs
    _ -> false
  headIsSpec = case _ of
    M.Var q -> contains (Pattern "$spec") (show q)
    _ -> false
  altGo alt = case alt.result of
    Right e -> go e
    Left gs -> Array.any (\g -> go g.guard || go g.expression) gs
  bindGo = case _ of
    M.NonRec _ _ e -> go e
    M.Rec rs -> Array.any (go <<< _.expr) rs
