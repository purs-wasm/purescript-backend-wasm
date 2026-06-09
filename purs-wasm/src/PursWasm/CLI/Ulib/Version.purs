-- | Version helpers shared by the ulib shadow resolution (`PursWasm.CLI.Ulib.Shadow`) and the
-- | ulib commands (`PursWasm.CLI.Ulib`). Pure string surgery (ADR 0028).
module PursWasm.CLI.Ulib.Version
  ( splitPkgVer
  , majorMinor
  , pkgVersionFromPath
  ) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..))
import Data.String as Str

-- | Split a `<package>-<version>` directory name on its last `-` (versions carry no `-`, but a
-- | package name may: `foldable-traversable-6.0.0` → package `foldable-traversable`, ver `6.0.0`).
splitPkgVer :: String -> { pkg :: String, ver :: String }
splitPkgVer s = case Array.unsnoc (Str.split (Pattern "-") s) of
  Just { init, last } -> { pkg: Str.joinWith "-" init, ver: last }
  Nothing -> { pkg: s, ver: "" }

-- | `6.0.2` → `6.0`. Shadows match a registry version by `major.minor` (a patch bump keeps the
-- | module interface, so it still applies; a minor/major bump may not — ADR 0028).
majorMinor :: String -> String
majorMinor v = Str.joinWith "." (Array.take 2 (Str.split (Pattern ".") v))

-- | Extract `<package>`'s version from a corefn modulePath (`…/<package>-<version>/…`).
pkgVersionFromPath :: String -> String -> Maybe String
pkgVersionFromPath pkg path =
  Array.index (Str.split (Pattern (pkg <> "-")) path) 1 >>= (Array.head <<< Str.split (Pattern "/"))
