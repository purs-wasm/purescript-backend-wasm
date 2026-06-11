-- | Version helpers shared by the ulib shadow resolution (`PursWasm.CLI.Ulib.Shadow`) and the
-- | ulib commands (`PursWasm.CLI.Ulib`). Pure string surgery (ADR 0028).
module UlibTooling.Version
  ( splitPkgVer
  , majorMinor
  , pkgVersionFromPath
  , compareVersion
  ) where

import Prelude

import Data.Array as Array
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
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

-- | Compare two dotted versions numerically over their first 
-- | three components (missing or non-numeric components count as 0)`:
-- | `0.15.9 < 0.15.10` (numeric, not lexicographic). 
-- | Used to order the supported-compiler set and
-- | to bound-check the purs pin (ADR 0029).
compareVersion :: String -> String -> Ordering
compareVersion a b = go 0
  where
  comps v = Str.split (Pattern ".") v
  pa = comps a
  pb = comps b
  component arr i = fromMaybe 0 (Int.fromString =<< Array.index arr i)
  go i
    | i >= 3 = EQ
    | otherwise = case compare (component pa i) (component pb i) of
        EQ -> go (i + 1)
        order -> order
