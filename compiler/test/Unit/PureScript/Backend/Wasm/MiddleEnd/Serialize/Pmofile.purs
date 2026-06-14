-- | Round-trip tests for the `.pmo` container. The container wraps two `Serialize`
-- | bodies (finalized + summary) behind a magic/version/key header; the codec already
-- | covers the bodies, so this checks the framing: the key and both modules survive a
-- | round-trip, and a non-`.pmo` byte string is rejected (so a stale/foreign file is a
-- | safe miss, not a mis-parse).
module Test.Unit.PureScript.Backend.Wasm.MiddleEnd.Serialize.Pmofile (spec) where

import Prelude

import Data.Either (Either(..), isLeft)
import Data.Maybe (Maybe(..))
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Serialize (encode)
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Pmofile (PmoEntry, decodePmo, encodePmo)
import PureScript.CoreFn (Literal(..), Qualified(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

finalMod :: M.Module
finalMod =
  { name: [ "Data", "Demo" ]
  , decls:
      [ M.NonRec Nothing "go" (M.Abs [ "x" ] (M.App (M.Var (Qualified Nothing "x")) [ M.Lit (LitInt 1) ]))
      , M.NonRec Nothing "v" (M.Lit (LitString "out"))
      ]
  }

summaryMod :: M.Module
summaryMod = { name: [ "Data", "Demo" ], decls: [ M.NonRec Nothing "go" (M.Var (Qualified Nothing "x")) ] }

entry :: PmoEntry
entry = { key: "deadbeefcafef00d", finalMod, summary: summaryMod }

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.MiddleEnd.Serialize.Pmo" do
  it "round-trips a cache entry (key + finalized + summary)" do
    decodePmo (encodePmo entry) `shouldEqual` Right entry

  it "rejects a non-.pmo byte string (a bare module body)" do
    isLeft (decodePmo (encode finalMod)) `shouldEqual` true
