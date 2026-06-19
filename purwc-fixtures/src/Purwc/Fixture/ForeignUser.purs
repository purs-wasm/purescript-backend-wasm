-- | Calls a foreign declared in a DIFFERENT module (ADR 0038 M3). `purwc` must resolve
-- | `ForeignDep.bumpInt` from `ForeignDep.pmi`'s `foreignSigs` (the foreign has no MIR binding, so it
-- | is absent from `funcs`) — else lowering throws `unknown callee`.
module Purwc.Fixture.ForeignUser where

import Purwc.Fixture.ForeignDep (bumpInt)

useBump :: Int -> Int
useBump x = bumpInt (bumpInt x)
