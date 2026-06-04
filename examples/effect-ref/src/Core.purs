-- A testable exercise of the native `Effect.Ref` core (ADR 0017): `new`/`write`/
-- `modify`/`read` threaded through `Effect` do-notation, returning a checkable `Int`
-- (so a bin-integration test can assert the result without `Console`). It deliberately
-- avoids `whenM`/`void`, which hit pre-existing Effect-collapse limitations unrelated to
-- `Ref`.
module Examples.EffRef.Core (compute) where

import Prelude

import Effect (Effect)
import Effect.Ref as Ref

compute :: Effect Int
compute = do
  r <- Ref.new 10
  Ref.write 5 r
  x <- Ref.modify (_ * 3) r -- cell 5 → 15, x = 15
  y <- Ref.read r -- y = 15
  pure (x + y) -- 30
