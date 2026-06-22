-- | Shared foreign-wasm plumbing (ADR 0040 §P2). A module's *kept foreign* (ADR 0039) ships as a
-- | per-module `foreign.wasm` (prebuilt) or `foreign.wat` (assembled). Both the `purwc` worker
-- | (self-merging its own foreign into `{M}.wasm`, so a cached library module is one self-contained
-- | object) and the `purs-wasm` orchestrator/per-module-codegen link tail need to (a) resolve a
-- | module's provider and (b) merge a provider into a target wasm — kept here so the two agree.
module PureScript.Backend.Wasm.CLI.ForeignWasm
  ( Provider
  , foreignProvider
  , mergeForeignInto
  ) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (Pattern(..))
import Data.String as Str
import PureScript.Backend.Wasm.CLI.Effect (FS, FilePath, PROC, execFile, exists, joinPath, readBinary, readText, unlink, writeBinary, writeText)
import PureScript.Backend.Wasm.CLI.Paths (wasmAsBin, wasmMergeBin)
import PureScript.Backend.Wasm.CLI.Ulib.Manifest (headerWatFile)
import Run (Run)
import Type.Row (type (+))

-- | A resolved foreign provider: the path to a wasm that exports the module's foreign functions, and
-- | whether it was freshly assembled (so the caller can delete the scratch file).
type Provider = { wasm :: FilePath, assembled :: Boolean }

-- | Resolve module `m`'s foreign provider from `input` (a directory with `m/foreign.wasm` and/or
-- | `m/foreign.wat`). A prebuilt `foreign.wasm` is preferred; otherwise a `foreign.wat` is assembled
-- | into `tmpDir` (a *fragment* — no `(module …)` — is wrapped with `headerDir/_header.wat`, ADR 0031,
-- | so it shares the runtime value types). `Nothing` when the module has no foreign source.
foreignProvider
  :: forall r
   . FilePath
  -> FilePath
  -> FilePath
  -> FilePath
  -> String
  -> Run (FS + PROC + r) (Maybe Provider)
foreignProvider binaryenBinDir input headerDir tmpDir m = do
  wasmSrc <- joinPath [ input, m, "foreign.wasm" ]
  hasWasm <- exists wasmSrc
  if hasWasm then pure (Just { wasm: wasmSrc, assembled: false })
  else do
    watSrc <- joinPath [ input, m, "foreign.wat" ]
    hasWat <- exists watSrc
    if hasWat then assemble binaryenBinDir headerDir tmpDir m watSrc
    else pure Nothing

assemble
  :: forall r
   . FilePath
  -> FilePath
  -> FilePath
  -> String
  -> FilePath
  -> Run (FS + PROC + r) (Maybe Provider)
assemble binaryenBinDir headerDir tmpDir m watSrc = readText watSrc >>= case _ of
  Nothing -> pure Nothing
  Just content -> do
    out <- joinPath [ tmpDir, m <> ".foreign.wasm" ]
    -- a full module has `(module` at the start of some line (not merely in a comment)
    let isFullModule = Array.any (\l -> Str.take 7 (Str.trim l) == "(module") (Str.split (Pattern "\n") content)
    if isFullModule then do
      execFile (wasmAsBin binaryenBinDir) [ watSrc, "-o", out, "--all-features" ]
      pure (Just { wasm: out, assembled: true })
    else do
      header <- fromMaybe "" <$> (readText =<< joinPath [ headerDir, headerWatFile ])
      combined <- joinPath [ tmpDir, m <> ".combined.wat" ]
      writeText combined ("(module\n" <> header <> "\n" <> content <> "\n)\n")
      execFile (wasmAsBin binaryenBinDir) [ combined, "-o", out, "--all-features" ]
      unlink combined
      pure (Just { wasm: out, assembled: true })

-- | Merge `providerWasm` (named after the module `m`, so the target's `import "m" …` resolve) into
-- | `targetWasm` in place, leaving the target self-contained. `wasm-merge` is read-all-then-write, but
-- | reading and writing the same path is fragile, so it writes a scratch file that overwrites the
-- | target. The merged wasm keeps the foreign exports (a *cross*-module foreign import is resolved
-- | later, at the program's final dumb merge) — no DCE here, that is the link tail's job.
mergeForeignInto
  :: forall r
   . FilePath
  -> FilePath
  -> String
  -> FilePath
  -> Run (FS + PROC + r) Unit
mergeForeignInto binaryenBinDir targetWasm m providerWasm = do
  let scratch = targetWasm <> ".self.wasm"
  execFile (wasmMergeBin binaryenBinDir)
    [ targetWasm, "self", providerWasm, m, "-o", scratch, "--all-features" ]
  readBinary scratch >>= case _ of
    Just bytes -> writeBinary targetWasm bytes *> unlink scratch
    Nothing -> pure unit
