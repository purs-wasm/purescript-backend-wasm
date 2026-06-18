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

import Data.Array as Array
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (Pattern(..))
import Data.String as Str
import PureScript.Backend.Wasm.CLI.Paths (wasmAsBin)
import PureScript.Backend.Wasm.CLI.Effect (FS, FilePath, PROC, execFile, exists, joinPath, readText, unlink, writeText)
import PureScript.Backend.Wasm.CLI.Ulib.Manifest (headerWatFile)
import PureScript.Backend.Wasm.CLI.Ulib.Shadow (Shadow)
import Run (Run)
import Type.Row (type (+))

type Provider = { name :: String, wasm :: Maybe FilePath, assembled :: Boolean }

resolveForeign :: forall r. FilePath -> Map String Shadow -> FilePath -> FilePath -> FilePath -> String -> Run (FS + PROC + r) Provider
resolveForeign binaryenBinDir shadows libPath input bundleDir m = do
  wasmSrc <- joinPath [ input, m, "foreign.wasm" ]
  hasWasm <- exists wasmSrc
  if hasWasm then pure { name: m, wasm: Just wasmSrc, assembled: false }
  else do
    watSrc <- joinPath [ input, m, "foreign.wat" ]
    hasWat <- exists watSrc
    if hasWat then assemble binaryenBinDir libPath bundleDir m watSrc
    else do
      -- ADR 0031: a ulib module's foreign is the prebuilt per-module `foreign.wasm` in the lib. The
      -- build no longer consults the global `ulib/<M>/foreign.wat` layer (now test-only, for the e2e
      -- harness). A foreign with no project/lib provider falls back to the JS loader.
      libWasm <- case Map.lookup m shadows of
        Just s -> exists s.foreignWasm <#> if _ then Just s.foreignWasm else Nothing
        Nothing -> pure Nothing
      pure { name: m, wasm: libWasm, assembled: false }

-- | Assemble a foreign `.wat`. A full `(module …)` is assembled as-is; a *fragment* (no
-- | `(module …)`) is wrapped as `(module <$LIB/_header.wat> <fragment>)` first, so it shares the
-- | runtime value types via the one authoritative header (ADR 0010 / 0012). The header ships in the
-- | lib (`$LIB/_header.wat`, ADR 0031) so assembling a project foreign needs no ulib source tree.
assemble :: forall r. FilePath -> FilePath -> FilePath -> String -> FilePath -> Run (FS + PROC + r) Provider
assemble binaryenBinDir libPath bundleDir m watSrc = readText watSrc >>= case _ of
  Nothing -> pure { name: m, wasm: Nothing, assembled: false }
  Just content -> do
    out <- joinPath [ bundleDir, m <> ".foreign.wasm" ]
    -- a full module has `(module` at the start of some line (not merely in a comment)
    let isFullModule = Array.any (\l -> Str.take 7 (Str.trim l) == "(module") (Str.split (Pattern "\n") content)
    if isFullModule then do
      execFile (wasmAsBin binaryenBinDir) [ watSrc, "-o", out, "--all-features" ]
      pure { name: m, wasm: Just out, assembled: true }
    else do
      header <- fromMaybe "" <$> (readText =<< joinPath [ libPath, headerWatFile ])
      combined <- joinPath [ bundleDir, m <> ".combined.wat" ]
      writeText combined ("(module\n" <> header <> "\n" <> content <> "\n)\n")
      execFile (wasmAsBin binaryenBinDir) [ combined, "-o", out, "--all-features" ]
      unlink combined
      pure { name: m, wasm: Just out, assembled: true }
