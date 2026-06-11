module Node.Cbor
  ( decodeAll
  , decodeFirst
  , decodeFirstSync
  ) where

import Prelude

import Data.ArrayBuffer.Types (Uint8Array)
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Uncurried (EffectFn1, runEffectFn1)
import Foreign (Foreign)
import Node.Buffer (Buffer)
import Promise.Aff (Promise, toAffE)

decodeAll :: Buffer -> Aff (Array Foreign)
decodeAll = runEffectFn1 decodeAllImpl >>> toAffE

decodeFirst :: Buffer -> Aff Foreign
decodeFirst = runEffectFn1 decodeFirstImpl >>> toAffE

-- | Synchronous decode of the first CBOR value (the `cbor` library's `decodeFirstSync`, which
-- | accepts any `Uint8Array`). Used by the sync `purs-wasm` CLI (which avoids `Aff` for
-- | self-hosting; ADR 0029 / the CLI re-architecture). The `Uint8Array` argument (rather than a
-- | Node `Buffer`) keeps the CLI's binary currency platform-neutral. Throws (in `Effect`) on
-- | malformed input — callers wrap in `try`.
decodeFirstSync :: Uint8Array -> Effect Foreign
decodeFirstSync = runEffectFn1 decodeFirstSyncImpl

foreign import decodeAllImpl :: EffectFn1 Buffer (Promise (Array Foreign))

foreign import decodeFirstImpl :: EffectFn1 Buffer (Promise Foreign)

foreign import decodeFirstSyncImpl :: EffectFn1 Uint8Array Foreign
