-- | Shared helpers for the Binaryen test suites.
module Test.Fixtures where

import Prelude

import Binaryen as B
import Effect (Effect)

-- | Run an action against a fresh module, disposing it afterwards.
withModule :: forall a. (B.Module -> Effect a) -> Effect a
withModule f = do
  mod <- B.createModule
  result <- f mod
  B.dispose mod
  pure result

-- | Build the canonical `add(i32, i32) -> i32` export into an existing module.
buildAddInto :: B.Module -> Effect Unit
buildAddInto mod = do
  let params = B.createType [ B.i32, B.i32 ]
  a <- B.localGet mod 0 B.i32
  b <- B.localGet mod 1 B.i32
  body <- B.i32Add mod a b
  _ <- B.addFunction mod "add" params B.i32 [] body
  _ <- B.addFunctionExport mod "add" "add"
  pure unit
