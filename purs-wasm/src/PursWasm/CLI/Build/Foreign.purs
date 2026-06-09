-- | The foreign-provider resolution ladder (ADR 0014 / 0012). For each host-import module the
-- | compiled wasm needs, find a provider: a project-local `foreign.wasm` (used directly) /
-- | `foreign.wat` (assembled), then the curated `ulib/<M>/foreign.wat` (assembled) — both merged
-- | as an in-wasm provider speaking the internal ABI; otherwise none, and it falls back to the JS
-- | loader. A project-local provider wins over ulib.
module PursWasm.CLI.Build.Foreign
  ( Provider
  , resolveForeign
  ) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (Pattern(..))
import Data.String as Str
import PursWasm.CLI.Build.Paths (ulibDir, wasmAsBin)
import PursWasm.CLI.Effect (FS, FilePath, PROC, execFile, exists, joinPath, readText, unlink, writeText)
import Run (Run)
import Type.Row (type (+))

type Provider = { name :: String, wasm :: Maybe FilePath, assembled :: Boolean }

resolveForeign :: forall r. FilePath -> FilePath -> String -> Run (FS + PROC + r) Provider
resolveForeign input bundleDir m = do
  wasmSrc <- joinPath [ input, m, "foreign.wasm" ]
  hasWasm <- exists wasmSrc
  if hasWasm then pure { name: m, wasm: Just wasmSrc, assembled: false }
  else do
    watSrc <- joinPath [ input, m, "foreign.wat" ]
    hasWat <- exists watSrc
    if hasWat then assemble bundleDir m watSrc
    else do
      ulibWat <- joinPath [ ulibDir, m, "foreign.wat" ]
      hasUlibWat <- exists ulibWat
      if hasUlibWat then assemble bundleDir m ulibWat
      else do
        ulibWasm <- joinPath [ ulibDir, m, "foreign.wasm" ]
        hasUlibWasm <- exists ulibWasm
        if hasUlibWasm then pure { name: m, wasm: Just ulibWasm, assembled: false }
        else pure { name: m, wasm: Nothing, assembled: false }

-- | Assemble a foreign `.wat`. A full `(module …)` is assembled as-is; a *fragment* (no
-- | `(module …)`) is wrapped as `(module <ulib/_header.wat> <fragment>)` first, so it shares the
-- | runtime value types via the one authoritative header (ADR 0010 / 0012).
assemble :: forall r. FilePath -> String -> FilePath -> Run (FS + PROC + r) Provider
assemble bundleDir m watSrc = readText watSrc >>= case _ of
  Nothing -> pure { name: m, wasm: Nothing, assembled: false }
  Just content -> do
    out <- joinPath [ bundleDir, m <> ".foreign.wasm" ]
    -- a full module has `(module` at the start of some line (not merely in a comment)
    let isFullModule = Array.any (\l -> Str.take 7 (Str.trim l) == "(module") (Str.split (Pattern "\n") content)
    if isFullModule then do
      execFile wasmAsBin [ watSrc, "-o", out, "--all-features" ]
      pure { name: m, wasm: Just out, assembled: true }
    else do
      header <- fromMaybe "" <$> (readText =<< joinPath [ ulibDir, "_header.wat" ])
      combined <- joinPath [ bundleDir, m <> ".combined.wat" ]
      writeText combined ("(module\n" <> header <> "\n" <> content <> "\n)\n")
      execFile wasmAsBin [ combined, "-o", out, "--all-features" ]
      unlink combined
      pure { name: m, wasm: Just out, assembled: true }
