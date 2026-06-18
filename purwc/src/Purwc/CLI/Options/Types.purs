-- | Option records and the top-level `Command` ADT for the `purwc` worker (ADR 0038): a single
-- | `compile` subcommand that compiles ONE module to its `.pmi`/`.pmo`/`.wasm`(/`.wat`) artifacts.
module Purwc.CLI.Options.Types
  ( CompileOption
  , Command(..)
  ) where

import PureScript.Backend.Wasm.CLI.Effect.Filesystem (FilePath)

type CompileOption =
  { entryModule :: String
  , input :: FilePath
  , depsDir :: FilePath
  , outDir :: FilePath
  , text :: Boolean
  , noOpt :: Boolean
  , debug :: Boolean
  }

data Command = Compile CompileOption
