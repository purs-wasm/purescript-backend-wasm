-- e2e fixture (ADR 0031 phase 5): ADR-0015 regression guard. `bump` is a user-defined,
-- deliberately un-inlinable Effect function that performs the host foreign `record`.
-- Each entry performs `bump` with the result DISCARDED through a different combinator —
-- do-notation (`bindBody`), `void` (`mapBody`), and `*>` (`applyBody`) — then reads the
-- recorded total. The bug: a discarded `perform (bump k)` for a non-inlined user Effect
-- function was misrouted to the host-foreign lowering path (`isEffectForeignApp` matched
-- it because ADR-0016 gives it an `MEffect` reconstructed sig) and built as a partial
-- closure never applied to the perform-unit — silently dropping the effect. `total` reads
-- the sum of what actually ran; each entry's expected value is the sum of its bumped `k`s.
module E2E.PerformUserEffect where

import Prelude

import Effect (Effect)
import Effect.Unsafe (unsafePerformEffect)

foreign import record :: Int -> Effect Unit
foreign import total :: Effect Int
foreign import reset :: Effect Unit

-- Past the inline caps (Inline 24 / DictElim 32) and used many times, so it stays a
-- SEPARATE binding and the call sites survive as `perform (bump k)` — the regressed path.
-- The `record 0`s are genuine (kept) effects; pure padding would be DCE'd and could shrink
-- `bump` back under the cap, silently reverting these tests to the inlined path.
bump :: Int -> Effect Unit
bump k = do
  record k
  record 0
  record 0
  record 0
  record 0
  record 0
  record 0
  record 0

-- do-notation discard (bindBody path) => 1 + 10 = 11
runBumps :: Int -> Int
runBumps _ = unsafePerformEffect do
  reset
  bump 1
  bump 10
  total

-- void / Functor-map discard (mapBody path) => 2
runVoid :: Int -> Int
runVoid _ = unsafePerformEffect do
  reset
  void (bump 2)
  total

-- applySecond / `*>` discard (applyBody path) => 3 + 4 = 7
runSeq :: Int -> Int
runSeq _ = unsafePerformEffect do
  reset
  bump 3 *> bump 4
  total