-- | Top of the 3-module chain (ADR 0038 M3): exercises (1) a TRANSITIVE dependency — `rotate4` calls
-- | `Mid.rotate2`, which calls `Base.rotate` — and (2) cross-module constructor codegen — `viaBox`
-- | constructs `Base`'s `Box` (tag + field rep from `Base.pmi`), passes it through the opaque
-- | `Base.idBox`, then pattern-matches it via `Base.unbox`. Compiled by `purwc` against `Mid.pmi` +
-- | `Base.pmi` only — never their `.pmo`.
module Purwc.Fixture.Top where

import Purwc.Fixture.Base (Box(..), Color, idBox, unbox)
import Purwc.Fixture.Mid (rotate2)

rotate4 :: Color -> Color
rotate4 c = rotate2 (rotate2 c)

viaBox :: Color -> Color
viaBox c = unbox (idBox (Box c))
