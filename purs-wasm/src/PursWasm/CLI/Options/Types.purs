-- | CLI option records and the top-level `Command` ADT for the user `purs-wasm` binary (just
-- | `build`). The maintainer `ulib` subcommands live in the separate `ulib-tooling` package (ADR
-- | 0031 §5).
module PursWasm.CLI.Options.Types
  ( BuildOption
  , Command(..)
  , Platform(..)
  ) where

import Prelude

import Data.Generic.Rep (class Generic)
import Data.List.NonEmpty (NonEmptyList)
import Data.Maybe (Maybe)
import Data.Show.Generic (genericShow)
import PureScript.Backend.Wasm.CLI.Effect.Filesystem (FilePath)

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
  , executable :: Boolean
  , force :: Boolean
  , perModuleRep :: Boolean
  , perModuleCodegen :: Boolean
  , orchestrate :: Boolean
  , dumpMir :: Maybe String
  }

data Command = Build BuildOption
