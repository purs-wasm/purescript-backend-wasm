-- | Unit tests for the whole-program purity analysis (ADR 0015): which top-level
-- | bindings are effectful to run. A binding is effectful iff running its value
-- | performs an effectful foreign — directly, transitively, or via an opaque (local)
-- | producer. A self-recursive binding that only performs itself stays pure (the
-- | `Effect` loop case), and a pure thunk is pure.
module Test.Unit.PureScript.Backend.Wasm.MiddleEnd.Optimize.Purity (spec) where

import Prelude

import Data.Maybe (Maybe(..))
import Data.Set as Set
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Optimize.Purity (impureKeys, memEffKeys)
import PureScript.CoreFn (Literal(..), Qualified(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

-- a top-level reference in module T, and a local
tv :: String -> M.Expr
tv n = M.Var (Qualified (Just [ "T" ]) n)

loc :: String -> M.Expr
loc n = M.Var (Qualified Nothing n)

def :: String -> M.Expr -> M.Bind
def n e = M.NonRec Nothing n e

-- the analysis over one module `T`, seeded with the single effectful foreign `T.eff`
impureOf :: Array M.Bind -> Set.Set String
impureOf decls = impureKeys (Set.singleton "T.eff") Set.empty [ { name: [ "T" ], decls } ]

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.MiddleEnd.Optimize.Purity" do

  it "a pure thunk is not effectful" do
    -- pureV = \$ev -> 1
    let impure = impureOf [ def "pureV" (M.Abs [ "$ev" ] (M.Lit (LitInt 1))) ]
    Set.member "T.pureV" impure `shouldEqual` false

  it "performing an effectful foreign is effectful" do
    -- runsEff = \$ev -> perform T.eff
    let impure = impureOf [ def "runsEff" (M.Abs [ "$ev" ] (M.Perform (tv "eff"))) ]
    Set.member "T.runsEff" impure `shouldEqual` true

  it "effectfulness is transitive through a performed binding" do
    -- g = \$ev -> perform T.eff ;  h = \$ev -> perform (g)
    let
      impure = impureOf
        [ def "g" (M.Abs [ "$ev" ] (M.Perform (tv "eff")))
        , def "h" (M.Abs [ "$ev" ] (M.Perform (tv "g")))
        ]
    Set.member "T.g" impure `shouldEqual` true
    Set.member "T.h" impure `shouldEqual` true

  it "a self-recursive binding that only performs itself stays pure (Effect loop)" do
    -- loop = \acc $ev -> case acc of _ -> perform (loop(acc))   (no effectful foreign)
    let
      body = M.Case [ loc "acc" ]
        [ { binders: [], result: pure (M.Perform (M.App (tv "loop") [ loc "acc" ])) } ]
      impure = impureOf [ def "loop" (M.Abs [ "acc", "$ev" ] body) ]
    Set.member "T.loop" impure `shouldEqual` false

  it "performing an opaque local is conservatively effectful" do
    -- op = \k $ev -> perform k     (k a local of unknown effect)
    let impure = impureOf [ def "op" (M.Abs [ "k", "$ev" ] (M.Perform (loc "k"))) ]
    Set.member "T.op" impure `shouldEqual` true

  describe "memEffKeys (memory-write effect set)" do
    let
      wa n = M.Var (Qualified (Just [ "Wasm", "Array" ]) n)
      memEffOf decls = memEffKeys Set.empty [ { name: [ "T" ], decls } ]

    it "a binding that writes via unsafeSet is memory-effectful" do
      -- w = \a -> unsafeSet a 0 1
      let m = memEffOf [ def "w" (M.Abs [ "a" ] (M.App (wa "unsafeSet") [ loc "a", M.Lit (LitInt 0), M.Lit (LitInt 1) ])) ]
      Set.member "T.w" m `shouldEqual` true

    it "a binding that allocates via unsafeNew is memory-effectful" do
      -- a = \n -> unsafeNew n
      let m = memEffOf [ def "a" (M.Abs [ "n" ] (M.App (wa "unsafeNew") [ loc "n" ])) ]
      Set.member "T.a" m `shouldEqual` true

    it "the write effect is transitive through a caller" do
      -- w = \a -> unsafeSet a 0 1 ;  caller = \a -> w a
      let
        m = memEffOf
          [ def "w" (M.Abs [ "a" ] (M.App (wa "unsafeSet") [ loc "a", M.Lit (LitInt 0), M.Lit (LitInt 1) ]))
          , def "caller" (M.Abs [ "a" ] (M.App (tv "w") [ loc "a" ]))
          ]
      Set.member "T.w" m `shouldEqual` true
      Set.member "T.caller" m `shouldEqual` true

    it "a binding that only reads (no write/alloc) is not memory-effectful" do
      -- r = \a -> unsafeIndex a 0     (a read, not a write)
      let m = memEffOf [ def "r" (M.Abs [ "a" ] (M.App (wa "unsafeIndex") [ loc "a", M.Lit (LitInt 0) ])) ]
      Set.member "T.r" m `shouldEqual` false
