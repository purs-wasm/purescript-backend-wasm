-- | Round-trip tests for the `.pmo` object container (the finalized MIR half of the split
-- | cache, ADR 0034). The body codec is covered by the `Serialize` tests; this checks the
-- | framing — the module survives a round-trip, and a non-`.pmo` byte string is rejected so
-- | a stale/foreign file is a safe miss, not a mis-parse.
module Test.Unit.PureScript.Backend.Wasm.MiddleEnd.Serialize.Pmofile (spec) where

import Prelude

import Data.Either (Either(..), isLeft)
import Data.Maybe (Maybe(..))
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Serialize (encode)
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Pmofile (decodePmo, encodePmo)
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

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.MiddleEnd.Serialize.Pmofile" do
  it "round-trips a finalized module" do
    decodePmo (encodePmo finalMod) `shouldEqual` Right finalMod

  it "rejects a non-.pmo byte string (a bare module body)" do
    isLeft (decodePmo (encode finalMod)) `shouldEqual` true
