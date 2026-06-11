-- | Harness for the CLI-driven e2e suite (ADR 0031 phase 5): instantiate a fixture's **prebuilt
-- | standalone wasm** (produced by `e2eCliPrebuild.mjs` running the real `purs-wasm build`) and call
-- | its `i32` exports. Unlike the legacy `Test.E2E.Wasm`, there is no in-process lowering and no
-- | `ulibImports` — the artifact is exactly what a user gets (runtime + ulib foreigns already merged),
-- | instantiated with no host imports. This is the "one path" the migration converges on.
module Test.E2E.Cli.Harness
  ( Instance
  , cliFixture
  , callI32x0
  , callI32x1
  , callI32x2
  , callI32x3
  ) where

import Effect (Effect)

-- | A live `WebAssembly.Instance`.
foreign import data Instance :: Type

-- | Instantiate the prebuilt `compiler/test/e2e-build/<module>/index.wasm` with no host imports.
foreign import cliFixture :: String -> Effect Instance

foreign import callI32x0 :: Instance -> String -> Effect Int
foreign import callI32x1 :: Instance -> String -> Int -> Effect Int
foreign import callI32x2 :: Instance -> String -> Int -> Int -> Effect Int
foreign import callI32x3 :: Instance -> String -> Int -> Int -> Int -> Effect Int
