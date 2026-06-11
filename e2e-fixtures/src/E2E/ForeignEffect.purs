-- e2e fixture (ADR 0031 phase 5): host **effectful** FFI (ADR 0015) through the generated loader —
-- `record`/`tick` are genuine host effects (the bundled `.js` keeps module-level state); `runRec`
-- performs two ordered `record`s and reads the sum back (1+2=3), `getTick` ticks twice and returns the
-- second (2). Pins that the purity analysis performs each effect exactly once, in order. (Migrated
-- from the legacy `Test.E2E.HostEff`.)
module E2E.ForeignEffect where

import Prelude

import Effect (Effect)
import Effect.Unsafe (unsafePerformEffect)

foreign import tick :: Effect Int
foreign import record :: Int -> Effect Unit
foreign import readSum :: Effect Int

runRec :: Int -> Int
runRec _ = unsafePerformEffect do
  record 1
  record 2
  readSum

getTick :: Int -> Int
getTick _ = unsafePerformEffect do
  _ <- tick
  tick
