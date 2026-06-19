-- | Base of a 3-module chain (ADR 0038 M3 scale test): a dependency-free module exporting an enum
-- | (`Color`) + a constructor-with-a-field (`Box`) and functions, for dependents to call, construct,
-- | and pattern-match cross-module.
module Purwc.Fixture.Base where

data Color = Red | Green | Blue

data Box = Box Color

rotate :: Color -> Color
rotate = case _ of
  Red -> Green
  Green -> Blue
  Blue -> Red

unbox :: Box -> Color
unbox (Box c) = c

-- An opaque (cross-module) identity so a dependent's `Box` construction survives optimization to
-- codegen — forcing real cross-module constructor codegen (tag + field rep from `Base.pmi`).
idBox :: Box -> Box
idBox b = b
