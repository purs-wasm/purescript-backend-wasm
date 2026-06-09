-- | Fixed, **cwd-relative** paths the build shells out to / reads from. The CLI is run from the
-- | repo root (every bench script / harness `cd`s there first), so these resolve against the cwd —
-- | distinct from the `cliRoot`-relative `lib`/`ulib/shadow` paths the ulib commands use.
module PursWasm.CLI.Build.Paths
  ( runtimeWasm
  , ulibDir
  , wasmMergeBin
  , wasmDisBin
  , wasmAsBin
  ) where

runtimeWasm :: String
runtimeWasm = "runtime/runtime.wasm"

ulibDir :: String
ulibDir = "ulib"

wasmMergeBin :: String
wasmMergeBin = "binaryen/node_modules/binaryen/bin/wasm-merge"

wasmDisBin :: String
wasmDisBin = "binaryen/node_modules/binaryen/bin/wasm-dis"

wasmAsBin :: String
wasmAsBin = "binaryen/node_modules/binaryen/bin/wasm-as"
