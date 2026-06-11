-- e2e fixture (ADR 0031 phase 5): general records — construction (`{ x, y }`), field access (`p.x`),
-- update (`p { x = … }`: updated field takes the new value, untouched fields are copied), and pattern
-- destructuring (`\{ x } -> …`), all over the label-map record machinery (ADR 0001/0007). `intAdd` is
-- declared foreign but resolves to the `intAdd` intrinsic, so the build stays standalone. Asserted by
-- `Test.E2E.Cli.Records`. (Migrated from the legacy `Records` corefn fixture.)
module E2E.Records where

foreign import intAdd :: Int -> Int -> Int

type Point = { x :: Int, y :: Int }

mk :: Int -> Int -> Point
mk x y = { x, y }

getX :: Int -> Int
getX n = (mk n (intAdd n n)).x

sumXY :: Int -> Int
sumXY n = let p = mk n (intAdd n 1) in intAdd p.x p.y

updatedX :: Int -> Int
updatedX n = let p = mk n 100 in (p { x = intAdd p.x 5 }).x

keptY :: Int -> Int
keptY n = let p = mk n 100 in (p { x = intAdd p.x 5 }).y

patX :: Int -> Int
patX n = (\{ x } -> x) (mk n 0)
