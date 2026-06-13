-- | Record metaprogramming with the `record-studio` library (`shrink` / `//` / `keys`).
-- |
-- | ⚠️ KNOWN LIMITATION — this currently **fails at run time** (`TypeError: type incompatibility
-- | when transforming from/to JS`). `record-studio`'s `keys`/`shrink` reach
-- | `Data.Unfoldable.unfoldrArrayImpl`, a higher-order JS foreign whose step callback passes
-- | `Maybe`/`Tuple` values across the JS boundary — a marshalling case (non-scalar callback values)
-- | not yet supported. It is independent of where the value is computed (CAF or `main`).
-- |
-- | (The earlier *Gap B* — a top-level CAF whose init re-entered wasm trapping at load — is now
-- | fixed: the loader runs `$caf_init` after instantiation. What remains is the foreign-marshalling
-- | limitation above.) Kept as a **repro**. See *Performance and Limitations § higher-order foreigns
-- | whose callbacks carry non-scalar values*. Record metaprogramming over first-order primitives
-- | (RowToList + `Record.insert`, no `unfoldr` callback) works — see `Test.E2E.Cli.RecordMeta`.
module Examples.RecordMeta where

import Prelude

import Effect (Effect)
import Effect.Console (logShow)
import Record.Studio (recordKeys, shrink, (//))

type Person = { name :: String, age :: Int }

alice :: Person
alice = { name: "Alice", age: 15 }

nameAndProfile :: { name :: String, bio :: String }
nameAndProfile = shrink (alice // { bio: "Seven-Colored Puppeteer" })

main :: Effect Unit
main = do
  logShow alice
  logShow nameAndProfile
  logShow (recordKeys nameAndProfile)
