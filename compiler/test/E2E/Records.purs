-- | End-to-end test of general records (beyond type-class dictionaries, which
-- | already share the representation): construction (`{ x, y }`), field access
-- | (`p.x`), record update (`p { x = … }` — updated fields take new values,
-- | untouched fields are copied from the original), and record-pattern
-- | destructuring (`\{ x } -> …`). All reuse the label-map `RMkRecord` /
-- | `RProjLabel` machinery (ADR 0001 / 0007); no new representation.
module Test.E2E.Records (spec) where

import Prelude

import Effect.Class (liftEffect)
import Test.E2E.Wasm (callI32x1, instantiateFixture)
import Test.Spec (Spec, before, describe, it)
import Test.Spec.Assertions (shouldEqual)

spec :: Spec Unit
spec =
  describe "Records (e2e): construct / access / update / pattern -> wasm -> run"
    $ before (liftEffect (instantiateFixture "compiler/test/fixtures/Records.corefn.json"))
    $ do
        -- getX n = (mk n (addI n n)).x
        it "constructs a record and projects a field" \inst -> do
          result <- liftEffect (callI32x1 inst "getX" 7)
          result `shouldEqual` 7

        -- sumXY n = addI p.x p.y, p = mk n (n+1)
        it "projects two fields" \inst -> do
          result <- liftEffect (callI32x1 inst "sumXY" 7)
          result `shouldEqual` 15

        -- updatedX n = (p { x = p.x + 5 }).x
        it "reads an updated field after a record update" \inst -> do
          result <- liftEffect (callI32x1 inst "updatedX" 7)
          result `shouldEqual` 12

        -- keptY n = (p { x = … }).y   -- y is copied from the original (= 100)
        it "copies untouched fields through a record update" \inst -> do
          result <- liftEffect (callI32x1 inst "keptY" 7)
          result `shouldEqual` 100

        -- patX n = (\{ x } -> x) (mk n 0)
        it "destructures a record pattern" \inst -> do
          result <- liftEffect (callI32x1 inst "patX" 7)
          result `shouldEqual` 7
