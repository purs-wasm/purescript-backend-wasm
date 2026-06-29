-- | A dependency that DECLARES a `foreign import` (ADR 0038 M3 risk test). A foreign has no MIR
-- | binding, so it never appears in the `.pmi`'s `funcs` table — a dependent that calls it relies
-- | entirely on the `.pmi`'s `foreignSigs`/`foreignNames` to resolve it (precise marshalling, not the
-- | opaque fallback).
module Purwc.Fixture.ForeignDep where

foreign import bumpInt :: Int -> Int
