-- | Build assets and binaries, resolved against the CLI's own roots (NOT the cwd) so the installed
-- | package works from any directory. `runtime/*` live under `cliRoot`; the binaryen binaries under
-- | `binaryenBinDir` — the JS entry resolves that per environment (`<repo>/binaryen/node_modules/
-- | binaryen/bin` in dev, `require.resolve('binaryen')` in the published package).
module PureScript.Backend.Wasm.CLI.Paths
  ( runtimeWasm
  , loaderGlue
  , wasmMergeBin
  , wasmDisBin
  , wasmAsBin
  ) where

import Prelude ((<>))

-- | The merged runtime wasm (`$rt.*`, ADR 0010), under `cliRoot`.
runtimeWasm :: String -> String
runtimeWasm cliRoot = cliRoot <> "/runtime/runtime.wasm"

-- | The shared FFI marshalling glue (Issue #10), copied verbatim next to the generated `index.mjs`
-- | so the loader can `import { makeMarshal } from "./marshal.js"`. Under `cliRoot`.
loaderGlue :: String -> String
loaderGlue cliRoot = cliRoot <> "/runtime/marshal.js"

wasmMergeBin :: String -> String
wasmMergeBin binaryenBinDir = binaryenBinDir <> "/wasm-merge"

wasmDisBin :: String -> String
wasmDisBin binaryenBinDir = binaryenBinDir <> "/wasm-dis"

wasmAsBin :: String -> String
wasmAsBin binaryenBinDir = binaryenBinDir <> "/wasm-as"
