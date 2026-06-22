-- | The foreign-provider resolution ladder (ADR 0014 / 0012 / 0031). For each host-import module
-- | the compiled wasm needs, find a provider: a project-local `foreign.wasm` / `foreign.wat`
-- | (assembled), then the **lib** per-module `foreign.wasm` (a ulib module's kept foreign, ADR
-- | 0031), then the (test-only, being retired) curated `ulib/<M>/foreign.wat` — all merged as an
-- | in-wasm provider; otherwise none, and it falls back to the JS loader.
module PursWasm.CLI.Build.Foreign
  ( Provider
  , resolveForeign
  ) where

import Prelude

import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import PureScript.Backend.Wasm.CLI.Effect (FS, FilePath, PROC, exists)
import PureScript.Backend.Wasm.CLI.ForeignWasm (foreignProvider)
import PureScript.Backend.Wasm.CLI.Ulib.Shadow (Shadow)
import Run (Run)
import Type.Row (type (+))

type Provider = { name :: String, wasm :: Maybe FilePath, assembled :: Boolean }

-- | Resolve module `m`'s foreign provider for the link tail: a project-local `foreign.wasm`/`.wat`
-- | (shared `foreignProvider`, ADR 0040 §P2 — `.wat` assembled with `libPath/_header.wat`), then the
-- | **lib** per-module `foreign.wasm` (a ulib module's kept foreign, ADR 0031), else none (JS loader).
resolveForeign :: forall r. FilePath -> Map String Shadow -> FilePath -> FilePath -> FilePath -> String -> Run (FS + PROC + r) Provider
resolveForeign binaryenBinDir shadows libPath input bundleDir m =
  foreignProvider binaryenBinDir input libPath bundleDir m >>= case _ of
    Just p -> pure { name: m, wasm: Just p.wasm, assembled: p.assembled }
    Nothing -> do
      -- ADR 0031: a ulib module's foreign is the prebuilt per-module `foreign.wasm` in the lib. A
      -- foreign with no project/lib provider falls back to the JS loader.
      libWasm <- case Map.lookup m shadows of
        Just s -> exists s.foreignWasm <#> if _ then Just s.foreignWasm else Nothing
        Nothing -> pure Nothing
      pure { name: m, wasm: libWasm, assembled: false }
