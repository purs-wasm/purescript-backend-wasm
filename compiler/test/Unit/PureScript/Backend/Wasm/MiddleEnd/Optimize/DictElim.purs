-- | Cross-module dictionary elimination — the load-bearing invariant for the dependency-ordered
-- | (and, with streaming, summary-driven) optimizer: a type-class dictionary defined in one module
-- | and used through another is eliminated, because the user module inlines the dependency's
-- | finalized accessor + instance, leaving a direct call (no runtime dict projection).
-- |
-- | This is **correctness-neutral** — a non-eliminated dictionary still computes the right value —
-- | so e2e cannot catch its regression. This unit test guards it directly (run the optimizer over a
-- | two-module program and assert the dict machinery is gone from the user module), with a companion
-- | that proves the test discriminates (middle-end off ⇒ the dict stays).
module Test.Unit.PureScript.Backend.Wasm.MiddleEnd.Optimize.DictElim (spec) where

import Prelude

import Data.Array as Array
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Set as Set
import Data.String (Pattern(..), contains)
import PureScript.Backend.Wasm.MiddleEnd (optimizeProgram)
import PureScript.Backend.Wasm.MiddleEnd.Print (printModule)
import PureScript.CoreFn as CF
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)
import Test.Unit.PureScript.Backend.Wasm.Lower.Common (ann, annMeta, appE, caseOf, ctorAlt, def, lam, lv, moduleNamed, qv, qvIn, varBinder)

-- A class dictionary defined in module `T`, used through module `U`:
--   module T:
--     DictCtor       -- the class dict constructor (IsTypeClassConstructor)
--     methodImpl x = x
--     dictAccessor d = case d of DictCtor o -> o   -- the `op` method accessor
--     dictInstance   = DictCtor methodImpl         -- the instance
--   module U:
--     useOp x = T.dictAccessor T.dictInstance x    -- a cross-module method call
-- Dict elimination should reduce `useOp` to a direct call (no `dictAccessor`/`dictInstance`).
modules :: Array CF.Module
modules = [ dep, use ]
  where
  dep = moduleNamed [ "T" ]
    [ CF.NonRec (annMeta CF.IsTypeClassConstructor) "DictCtor" (CF.Constructor ann "Dict" "DictCtor" [ "op" ])
    , def "methodImpl" (lam "x" (lv "x"))
    , def "dictAccessor" (lam "d" (caseOf (lv "d") [ ctorAlt "DictCtor" [ varBinder "o" ] (lv "o") ]))
    , def "dictInstance" (appE (qv "DictCtor") (qv "methodImpl"))
    ]
  use = moduleNamed [ "U" ]
    [ def "useOp" (lam "x" (appE (appE (qvIn "T" "dictAccessor") (qvIn "T" "dictInstance")) (lv "x"))) ]

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.MiddleEnd.Optimize.DictElim (cross-module)" do
  it "eliminates a dictionary used across a module boundary" do
    case Array.find (\m -> m.name == [ "U" ]) (optimizeProgram true Set.empty Map.empty modules) of
      Nothing -> fail "expected module U"
      Just u -> do
        let printed = printModule u
        contains (Pattern "dictAccessor") printed `shouldEqual` false
        contains (Pattern "dictInstance") printed `shouldEqual` false

  it "leaves the cross-module dictionary in place when the middle-end is off (the test discriminates)" do
    case Array.find (\m -> m.name == [ "U" ]) (optimizeProgram false Set.empty Map.empty modules) of
      Nothing -> fail "expected module U"
      Just u -> do
        let printed = printModule u
        contains (Pattern "dictAccessor") printed `shouldEqual` true
