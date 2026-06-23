-- | Option records and the top-level `Command` ADT for the `purwc` worker (ADR 0038): a single
-- | `compile` subcommand that compiles ONE module to its `.pmi`/`.pmo`/`.wasm`(/`.wat`) artifacts.
module Purwc.CLI.Options.Types
  ( CompileOption
  , BatchOption
  , Command(..)
  ) where

import PureScript.Backend.Wasm.CLI.Effect.Filesystem (FilePath)

type CompileOption =
  { entryModule :: String
  , input :: FilePath
  , depsDir :: FilePath
  , outDir :: FilePath
  , programEntry :: Boolean
  , text :: Boolean
  , noOpt :: Boolean
  , debug :: Boolean
  }

-- | Options for the long-lived `compile-batch` worker (ADR 0038 Phase C2): the shared input/deps/
-- | output dirs + build flags; the per-module work-list (each module's name, `*`-prefixed if it is the
-- | program entry) is streamed in on stdin. One process compiles every module in the list in order,
-- | so the costly one-time Binaryen init is paid once and amortised across the whole list.
type BatchOption =
  { input :: FilePath
  , depsDir :: FilePath
  , outDir :: FilePath
  -- The global content-addressed store root (ADR 0040). When set, the worker writes each compiled
  -- LIBRARY module's artifacts to the store under the per-line store keys as soon as that module
  -- finishes (rather than the orchestrator copying them back after the whole batch). Empty disables.
  , storeDir :: FilePath
  , noOpt :: Boolean
  , debug :: Boolean
  }

data Command
  = Compile CompileOption
  | Batch BatchOption
