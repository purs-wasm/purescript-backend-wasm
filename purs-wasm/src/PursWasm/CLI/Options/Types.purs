-- | CLI option records and the top-level `Command` ADT, covering `build` and the three `ulib`
-- | subcommands (install/validate/check; ADR 0028).
module PursWasm.CLI.Options.Types
  ( BuildOption
  , UlibInstallOption
  , UlibValidateOption
  , UlibCheckOption
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

type UlibInstallOption =
  { libPath :: Maybe FilePath
  , purs :: Maybe FilePath
  , force :: Boolean
  }

type UlibValidateOption =
  { libPath :: Maybe FilePath
  , spago :: Maybe FilePath
  }

type UlibCheckOption =
  { libPath :: Maybe FilePath
  , input :: Maybe FilePath
  }

data Command
  = Build BuildOption
  | UlibInstall UlibInstallOption
  | UlibValidate UlibValidateOption
  | UlibCheck UlibCheckOption
