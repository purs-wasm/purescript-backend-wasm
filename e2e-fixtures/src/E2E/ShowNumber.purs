-- e2e fixture (ADR 0031 phase 5): exposes `show :: Number -> String` (the ulib `Data.Show` shadow's
-- `showNumberImpl`) as a marshalled String export, so the exhaustive `showNumber.mjs` oracle can drive
-- it through the real `purs-wasm build` + loader (replacing the retired global `ulib/Data.Show` wat).
module E2E.ShowNumber where

import Prelude

showNum :: Number -> String
showNum n = show n
