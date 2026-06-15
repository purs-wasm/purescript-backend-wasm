-- | Round-trip tests for the `.pmi` interface container (key + deps + summary, ADR 0034).
-- | Checks that all three fields survive a round-trip — including an empty and a multi-entry
-- | dependency list — and that a non-`.pmi` byte string (e.g. a `.pmo`) is rejected.
module Test.Unit.PureScript.Backend.Wasm.MiddleEnd.Serialize.Pmifile (spec) where

import Prelude

import Data.Either (Either(..), isLeft)
import Data.Maybe (Maybe(..))
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Pmifile (PmiEntry, decodePmi, encodePmi)
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Pmofile (encodePmo)
import PureScript.CoreFn (Qualified(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

summaryMod :: M.Module
summaryMod = { name: [ "Data", "Demo" ], decls: [ M.NonRec Nothing "go" (M.Var (Qualified Nothing "x")) ] }

entry :: PmiEntry
entry = { sourceHash: "0011223344556677", key: "deadbeefcafef00d", deps: [ "Data.Dep.A", "Data.Dep.B" ], summary: summaryMod }

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.MiddleEnd.Serialize.Pmifile" do
  it "round-trips an interface entry (key + deps + summary)" do
    decodePmi (encodePmi entry) `shouldEqual` Right entry

  it "round-trips an entry with no dependencies" do
    let e = entry { deps = [] }
    decodePmi (encodePmi e) `shouldEqual` Right e

  it "rejects a non-.pmi byte string (a .pmo object)" do
    isLeft (decodePmi (encodePmo summaryMod)) `shouldEqual` true
