-- | Middle of the 3-module chain (ADR 0038 M3): imports `Base` and calls it; itself imported by
-- | `Top`, so `Top` reaches `Base` only transitively.
module Purwc.Fixture.Mid where

import Purwc.Fixture.Base (Color, rotate)

rotate2 :: Color -> Color
rotate2 c = rotate (rotate c)
