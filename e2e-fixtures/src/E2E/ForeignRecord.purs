-- e2e fixture (ADR 0031 phase 5): Record marshalling ($Rec <-> JS object, ADR 0014) through a TYPE
-- SYNONYM (`Point`) — the regression guard for the externs synonym-expansion fix (a foreign typed by
-- an alias must marshal by the real record type, not fall to MOpaque). `pointX`/`pointY` exercise the
-- foreign boundary (Int exports); `bump` the export boundary (record arg + result).
module E2E.ForeignRecord where

import Prelude

type Point = { x :: Int, y :: Int }

foreign import shiftX :: Point -> Point

pointX :: Int -> Int
pointX n = (shiftX { x: n, y: n + 1 }).x

pointY :: Int -> Int
pointY n = (shiftX { x: n, y: n + 1 }).y

bump :: Point -> Point
bump p = shiftX p
