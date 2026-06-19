-- | The `compile-batch` command (ADR 0038 Phase C2): a long-lived worker that compiles EVERY module
-- | in a stdin work-list, in order, within ONE process. Each line is a module name, `*`-prefixed if it
-- | is the program entry (host-ABI bare exports); the orchestrator streams the topologically-ordered
-- | list so a dependency is compiled (its `.pmi` written) before any dependent reads it from `--deps`.
-- |
-- | The point is amortisation: a one-shot `purwc compile` pays the Binaryen.js Emscripten init (~1.3 s)
-- | per spawn, which dominates a 34-module program. Here the `binaryen` ES-module singleton instantiates
-- | ONCE for the process and every module's `new binaryen.Module()` reuses it, so that cost is paid once
-- | for the whole batch — the per-module compile is the only marginal work.
module Purwc.CLI.Batch
  ( batchCmd
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (for_)
import Data.String as Str
import PureScript.Backend.Wasm.CLI.Effect (ENV, FS, FilePath, LOG, PROC, readStdin)
import Purwc.CLI.Compile (compileCmd)
import Purwc.CLI.Options.Types (BatchOption)
import Run (EFFECT, Run)
import Type.Row (type (+))

batchCmd :: forall r. FilePath -> FilePath -> BatchOption -> Run (ENV + FS + PROC + LOG + EFFECT + r) Unit
batchCmd cliRoot binaryenBinDir args = do
  raw <- readStdin
  let lines = Array.filter (not <<< Str.null) (map Str.trim (Str.split (Str.Pattern "\n") raw))
  for_ lines \line -> do
    let entry = Str.take 1 line == "*"
    let name = if entry then Str.drop 1 line else line
    -- Reuse the single-module compile unchanged: the same process means the loaded compiler graph and
    -- the Binaryen runtime are shared across every iteration (the whole reason for the batch).
    compileCmd cliRoot binaryenBinDir
      { entryModule: name
      , input: args.input
      , depsDir: args.depsDir
      , outDir: args.outDir
      , programEntry: entry
      , text: false
      , noOpt: args.noOpt
      , debug: args.debug
      }
