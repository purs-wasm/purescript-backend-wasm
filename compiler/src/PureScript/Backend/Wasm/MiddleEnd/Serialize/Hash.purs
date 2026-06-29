-- | Content hashing for the `.pmo` cache key (ADR 0032 phase 4). A module is a cache
-- | hit iff its source is unchanged **and** every dependency summary it consumed is
-- | unchanged (ADR 0021's summary-hash invalidation); `cacheKey` packs exactly that into
-- | one digest. The hash is a fast non-cryptographic one (see `Hash.js`): a build cache
-- | needs only that an accidental clash be astronomically unlikely, and it must stay a
-- | pure function so it can run inside the optimizer loop.
module PureScript.Backend.Wasm.MiddleEnd.Serialize.Hash
  ( hashBytes
  , hashString
  , cacheKey
  ) where

import Prelude

import Data.Array as Array
import Data.ArrayBuffer.Types (Uint8Array)
import Data.String (joinWith)

-- | A 16-hex-character digest of the bytes (e.g. an encoded `.pmo` body / a module summary).
foreign import hashBytes :: Uint8Array -> String

-- | A 16-hex-character digest of the string's UTF-8 bytes.
foreign import hashString :: String -> String

-- | The cache key for a module: a digest of its own source hash combined with the
-- | **cache keys** of the dependencies it consumed (ADR 0040 §2 — a recursive,
-- | content-addressed key). Keying on each dependency's *own key* (rather than its summary
-- | hash) makes the key a Merkle digest of the whole transitive input, so a module's store
-- | path is derivable bottom-up from sources alone without materializing any summary.
-- | Dependency keys are sorted so the key is independent of import order (the dependency
-- | *set*, not its sequence, is what the module's optimized output depends on — ADR 0032).
cacheKey :: String -> Array String -> String
cacheKey sourceHash depKeys =
  hashString (sourceHash <> "\n" <> joinWith "\n" (Array.sort depKeys))
