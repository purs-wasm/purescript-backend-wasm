-- | A dependency-free fixture (ADR 0038 M1): imports nothing, so it has no cross-module references.
-- | `purwc compile` builds it in true isolation (empty dependency set) and the result is compared
-- | byte-for-byte against the whole-program per-module oracle.
module Purwc.Fixture.Solo where

data Color = Red | Green | Blue

-- An enum rotation (i31-represented Color → Color through a `case`).
next :: Color -> Color
next = case _ of
  Red -> Green
  Green -> Blue
  Blue -> Red

-- An intra-module call (exercises a same-module known-call, not a cross-module import).
twice :: Color -> Color
twice c = next (next c)
