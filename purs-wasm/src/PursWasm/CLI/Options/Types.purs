-- | CLI option records and the top-level `Command` ADT, covering `build` and the three `ulib`
-- | subcommands (install/validate/check; ADR 0028).
module PursWasm.CLI.Options.Types
  ( BuildOption
  , Command(..)
  , GlobalOptions
  , Platform(..)
  , UlibCheckOption
  , UlibCompatOption
  , UlibInstallOption
  , UlibValidateOption
  ) where

import Prelude

import Data.Generic.Rep (class Generic)
import Data.List.NonEmpty (NonEmptyList)
import Data.Maybe (Maybe)
import Data.Show.Generic (genericShow)
import PursWasm.CLI.Effect.Filesystem (FilePath)

-- | The deployment target a build produces (`-p/--platform`). `Node` and `Browser` emit a single
-- | wasm plus a JS loader; `Standalone` emits a self-contained single wasm with no loader. (Browser
-- | will eventually emit wasm chunks; until then it behaves like `Node`, see `--no-chunks`.)
data Platform
  = Node
  | Browser
  | Standalone

derive instance eqPlatform :: Eq Platform
derive instance genericPlatform :: Generic Platform _
instance showPlatform :: Show Platform where
  show = genericShow

-- | Options every command accepts, parsed once and threaded to the interpreter — not part of any
-- | command's own option record.
type GlobalOptions = { verbose :: Boolean }

type BuildOption =
  { input :: FilePath
  , outDir :: FilePath
  , entryModules :: NonEmptyList String
  , text :: Boolean
  , debug :: Boolean
  , noOpt :: Boolean
  , platform :: Platform
  , noChunks :: Boolean
  , noJsFallback :: Boolean
  , dumpMir :: Maybe String
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

-- | `ulib compat`: regenerate (default) or, with `--check`, verify `ulib/compat.json` (ADR 0029).
type UlibCompatOption =
  { check :: Boolean
  }

data Command
  = Build BuildOption
  | UlibInstall UlibInstallOption
  | UlibValidate UlibValidateOption
  | UlibCheck UlibCheckOption
  | UlibCompat UlibCompatOption
