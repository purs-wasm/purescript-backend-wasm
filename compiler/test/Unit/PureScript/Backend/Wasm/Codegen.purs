-- | Stack-safety regression guards for whole-program code generation
-- | (`Codegen.buildModule`). These do not inspect the emitted wasm — only that codegen
-- | does not overflow the host JS stack on the shapes a self-sized program produces: a long
-- | `Let` spine (`genBody`), a wide `Switch` (the `genSwitch` / `genLitSwitch` if-chain), and a
-- | program with many functions (the whole-program emission loop). Each size is well past the
-- | ~10k default-stack-frame limit the pre-`tailRecM` code died at; before the stack-safety
-- | fixes these `buildModule` calls raised `RangeError: Maximum call stack size exceeded`.
module Test.Unit.PureScript.Backend.Wasm.Codegen (spec) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..))
import Effect.Class (liftEffect)
import Foreign.Object as Object
import PureScript.Backend.Wasm.Codegen (buildModule)
import PureScript.Backend.Wasm.Lower.IR (AnfExpr(..), Atom(..), FuncName(..), IRFunc, LitBranch(..), LitPat(..), Program, Rep(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

prog :: Array IRFunc -> Program
prog funcs = { funcs, labels: [], exportSigs: Object.empty }

-- | A nullary function with the given local-slot count and body.
caf :: String -> Int -> AnfExpr -> IRFunc
caf name localCount body = { name: FuncName name, params: [], result: Boxed, body, export: Nothing, localCount }

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.Codegen.buildModule (stack safety)" do
  it "emits a switch with many branches without overflowing (genLitSwitch if-chain)" do
    let
      n = 30000
      branches = map (\k -> LitBranch (PInt k) (Return (ALitInt k))) (Array.range 0 (n - 1))
      p = prog [ caf "wide" 1 (LitSwitch (ALitInt 0) branches (Just (Return (ALitInt (-1))))) ]
    r <- liftEffect (buildModule p)
    Array.length r.foreignModules `shouldEqual` 0

  it "emits a program with many functions without overflowing (whole-program loop)" do
    let
      n = 30000
      fns = map (\i -> { name: FuncName ("f" <> show i), params: [ Boxed ], result: Boxed, body: Return (ALitInt 0), export: Nothing, localCount: 1 }) (Array.range 0 (n - 1))
    r <- liftEffect (buildModule (prog fns))
    Array.length r.foreignModules `shouldEqual` 0
