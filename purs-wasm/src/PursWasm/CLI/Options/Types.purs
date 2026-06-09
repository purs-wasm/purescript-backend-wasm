-- | CLI option records and the top-level `Command` ADT. (The `ulib` subcommands join `Command` in
-- | a later phase; this phase wires only `build`.)
module PursWasm.CLI.Options.Types
  ( BuildOption
  , Command(..)
  ) where

import Data.List.NonEmpty (NonEmptyList)
import Data.Maybe (Maybe)
import PursWasm.CLI.Effect.Filesystem (FilePath)

type BuildOption =
  { input :: FilePath
  , outDir :: FilePath
  , entryModules :: NonEmptyList String
  , text :: Boolean
  , debug :: Boolean
  , noOpt :: Boolean
  , traceMir :: Maybe String
  }

data Command = Build BuildOption
