-- | The `ulib/compat.json` record (ADR 0029) and its codecs. Output is serialized to bytes that
-- | match the prototype's `JSON.stringify(out, null, 2) + "\n"` exactly (the differential test
-- | asserts byte-identity), so the serializer is hand-written rather than delegated to a generic
-- | pretty-printer whose spacing/field-order we could not pin down. Inputs (a prior compat.json)
-- | are read leniently — a missing/garbled file yields empty data, mirroring the prototype's
-- | `?? null` / `?? {}` fallbacks.
module PursWasm.CLI.Ulib.Compat.Types
  ( Compat
  , CompatCore
  , encodeCompat
  , coreOf
  , readCompatCore
  ) where

import Prelude

import Data.Argonaut.Core (Json, toObject, toString)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (either)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), maybe)
import Data.String as Str
import Data.Tuple (Tuple(..))
import Foreign.Object as FO

-- | The full compat record (the regenerated output).
type Compat =
  { packageSet :: Maybe String
  , pursPin :: String
  , pursMin :: String
  , pursMax :: String
  , packages :: Map String String
  }

-- | The offline-derivable subset (`--check` compares only this against the recorded file; the purs
-- | pins are release-time/online and excluded).
type CompatCore =
  { packageSet :: Maybe String
  , packages :: Map String String
  }

coreOf :: Compat -> CompatCore
coreOf c = { packageSet: c.packageSet, packages: c.packages }

-- | Serialize to the exact bytes the prototype wrote: 2-space indent, fixed field order, packages
-- | sorted by key (a `Map` already iterates in key order), trailing newline. Package names and
-- | versions are plain ASCII, so no JSON string escaping is required.
encodeCompat :: Compat -> String
encodeCompat c =
  "{\n"
    <> "  \"packageSet\": "
    <> maybe "null" jsonStr c.packageSet
    <> ",\n"
    <> "  \"pursPin\": "
    <> jsonStr c.pursPin
    <> ",\n"
    <> "  \"pursMin\": "
    <> jsonStr c.pursMin
    <> ",\n"
    <> "  \"pursMax\": "
    <> jsonStr c.pursMax
    <> ",\n"
    <> "  \"packages\": "
    <> packagesBlock
    <> "\n"
    <> "}\n"
  where
  jsonStr s = "\"" <> s <> "\""
  packagesBlock = case (Map.toUnfoldable c.packages :: Array (Tuple String String)) of
    [] -> "{}"
    entries ->
      "{\n"
        <> Str.joinWith ",\n" (entries <#> \(Tuple k v) -> "    " <> jsonStr k <> ": " <> jsonStr v)
        <> "\n  }"

-- | Read a prior compat.json's offline core leniently: `packageSet` (string or absent) and the
-- | `packages` map (string→string). Anything missing/malformed degrades to empty.
readCompatCore :: String -> CompatCore
readCompatCore txt = either (const empty) fromJson (jsonParser txt)
  where
  empty = { packageSet: Nothing, packages: Map.empty }
  fromJson j =
    { packageSet: field "packageSet" j >>= toString
    , packages: maybe Map.empty objToStrMap (field "packages" j >>= toObject)
    }

field :: String -> Json -> Maybe Json
field k j = toObject j >>= FO.lookup k

objToStrMap :: FO.Object Json -> Map String String
objToStrMap o =
  Map.fromFoldable
    (Array.mapMaybe (\(Tuple k v) -> Tuple k <$> toString v) (FO.toUnfoldable o))
