-- | Source for `Slice0.corefn.json` (the Slice 0 / scalar-Int E2E fixture).
-- |
-- | It deliberately uses module-local `foreign import` primitives (mapped to
-- | i32 intrinsics by the backend's `ForeignProvider`) instead of `+`/`*`, so
-- | it pulls in no type-class dictionaries, records, closures, or pattern
-- | matching — only top-level functions, integer literals, and saturated calls.
-- |
-- | The `.sample` extension keeps it out of the `test/**/*.purs` build glob; it
-- | is not compiled as part of the suite. See README.md for how to regenerate
-- | the `.corefn.json`.
module E2E.Scalars where

foreign import intAdd :: Int -> Int -> Int
foreign import intMul :: Int -> Int -> Int

double :: Int -> Int
double x = intAdd x x

quad :: Int -> Int
quad x = double (double x)

sumOfSquares :: Int -> Int -> Int
sumOfSquares x y = intAdd (intMul x x) (intMul y y)

five :: Int
five = intAdd 2 3
