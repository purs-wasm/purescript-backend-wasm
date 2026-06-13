-- | Record metaprogramming with the `record-studio` library (`shrink` / `//` / `keys`).
-- |
-- | ⚠️ KNOWN LIMITATION (Gap B) — this currently **traps at load**, by design of the present
-- | CAF-init mechanism. `record-studio`'s `keys`/`shrink` reach a higher-order JS foreign
-- | (`Data.Unfoldable.unfoldrArrayImpl`) that re-enters wasm, and the library holds a top-level
-- | value (CAF) that routes through it. CAFs are computed at instantiation (the wasm `start`
-- | section, ADR 0006), and an instance's exports cannot be re-entered from JS during its own
-- | start, so it fails with `TypeError: … reading 'exports'`. Moving the computation into `main`
-- | does NOT help here, because the offending CAF is inside the library, not this module.
-- |
-- | This example is kept as a **repro**: it will start working once the planned fix lands — the
-- | loader runs initialization *after* instantiation, instead of the wasm `start` section (it rides
-- | along with the streaming-compilation work). See *Performance and Limitations § a top-level
-- | value computed through a re-entrant JS foreign*, ADR 0006, and ADR 0021.
-- |
-- | (For record metaprogramming that works today — RowToList + dynamic field insert with no
-- | re-entrant foreign — see the `Test.E2E.Cli.RecordMeta` fixture.)
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
