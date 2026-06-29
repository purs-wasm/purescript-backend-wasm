-- | Module-name helpers and file-level reachability. `reachableClosure` prunes the input dir to
-- | the modules an entry transitively needs (over the cheap dotted import map) before the
-- | expensive full decode — the compiler prunes again at the IR level, but this bounds the decode.
module PureScript.Backend.Wasm.CLI.Module
  ( printModname
  , entryRoot
  , reachableClosure
  ) where

import Prelude

import Data.Array as Array
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (maybe)
import Data.Set (Set)
import Data.Set as Set
import Data.String (Pattern(..))
import Data.String as Str
import PureScript.CoreFn (ModuleName)

-- | A module name as its dotted form (`["Data","Maybe"]` → `"Data.Maybe"`).
printModname :: ModuleName -> String
printModname = Str.joinWith "."

-- | `-e Data.Maybe` names the module `["Data","Maybe"]` — the root form `lowerModules` expects.
entryRoot :: String -> ModuleName
entryRoot = Str.split (Pattern ".")

-- | The set of module names transitively reachable from `roots` through the (dotted) import map —
-- | a fixpoint that only grows, so it terminates.
reachableClosure :: Array ModuleName -> Map String (Array String) -> Set String
reachableClosure roots importMap = go (Set.fromFoldable (map printModname roots))
  where
  go seen =
    let
      next = Set.fromFoldable (Array.fromFoldable seen >>= \n -> maybe [] identity (Map.lookup n importMap))
      seen' = Set.union seen next
    in
      if Set.size seen' == Set.size seen then seen else go seen'
