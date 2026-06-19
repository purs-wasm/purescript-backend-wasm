-- | A dependency-free library module (ADR 0038 M2b): imports nothing, exports `rotate` for a
-- | dependent module to call cross-module. Compiled by `purwc` to `Dep.pmi` + `Dep.wasm`.
module Purwc.Fixture.Dep where

data Color = Red | Green | Blue

rotate :: Color -> Color
rotate = case _ of
  Red -> Green
  Green -> Blue
  Blue -> Red
