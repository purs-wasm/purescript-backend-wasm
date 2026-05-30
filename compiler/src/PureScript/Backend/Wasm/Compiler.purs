module PureScript.Backend.Wasm.Compiler
  ( demoWat
  ) where

import Prelude

import Binaryen as B
import Effect (Effect)

-- | A smoke-test of the Binaryen round-trip: build a module exporting a single
-- | `add(i32, i32) -> i32` function and return it as WAT.
-- |
-- | This exists to prove the toolchain (purs + spago + pnpm + Binaryen FFI) is
-- | wired up end to end. It will be replaced by the real CoreFn -> Wasm
-- | compiler once the input/IR layers land.
demoWat :: Effect String
demoWat = do
  mod <- B.createModule
  let ii = B.createType [ B.i32, B.i32 ]
  a <- B.localGet mod 0 B.i32
  b <- B.localGet mod 1 B.i32
  body <- B.i32Add mod a b
  _ <- B.addFunction mod "add" ii B.i32 [] body
  _ <- B.addFunctionExport mod "add" "add"
  ok <- B.validate mod
  wat <- B.emitText mod
  B.dispose mod
  pure $ if ok then wat else "; module failed validation\n" <> wat
