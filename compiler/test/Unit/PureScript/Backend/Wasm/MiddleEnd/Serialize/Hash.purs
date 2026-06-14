-- | Tests for the cache-key hashing. The hash itself is opaque, but the *invariants*
-- | the cache relies on are checkable and would silently break correctness if violated:
-- | a key must change when the source or any dependency-summary hash changes (else a
-- | stale entry is reused), and must NOT change with dependency *order* (else every
-- | reorder is a spurious miss). See ADR 0032 / ADR 0021 summary-hash invalidation.
module Test.Unit.PureScript.Backend.Wasm.MiddleEnd.Serialize.Hash (spec) where

import Prelude

import Data.Maybe (Maybe(..))
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.Backend.Wasm.MiddleEnd.Serialize (encode)
import PureScript.Backend.Wasm.MiddleEnd.Serialize.Hash (cacheKey, hashBytes, hashString)
import PureScript.CoreFn (Literal(..))
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldNotEqual)

modA :: M.Module
modA = { name: [ "A" ], decls: [ M.NonRec Nothing "x" (M.Lit (LitInt 1)) ] }

modB :: M.Module
modB = { name: [ "A" ], decls: [ M.NonRec Nothing "x" (M.Lit (LitInt 2)) ] }

spec :: Spec Unit
spec = describe "PureScript.Backend.Wasm.MiddleEnd.Serialize.Hash" do
  describe "hashString / hashBytes" do
    it "is deterministic for equal input" do
      hashString "hello" `shouldEqual` hashString "hello"
      hashBytes (encode modA) `shouldEqual` hashBytes (encode modA)

    it "distinguishes different input" do
      hashString "hello" `shouldNotEqual` hashString "hallo"
      hashBytes (encode modA) `shouldNotEqual` hashBytes (encode modB)

  describe "cacheKey" do
    it "is independent of dependency order" do
      cacheKey "src" [ "a", "b", "c" ] `shouldEqual` cacheKey "src" [ "c", "a", "b" ]

    it "changes when the source hash changes" do
      cacheKey "src1" [ "a" ] `shouldNotEqual` cacheKey "src2" [ "a" ]

    it "changes when a dependency-summary hash changes" do
      cacheKey "src" [ "a" ] `shouldNotEqual` cacheKey "src" [ "b" ]

    it "distinguishes adding a dependency" do
      cacheKey "src" [ "a" ] `shouldNotEqual` cacheKey "src" [ "a", "b" ]
