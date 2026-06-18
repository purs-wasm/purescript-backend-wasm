-- | The `purwc` package entry module. The Node loader (`index.dev.js`) imports `main` from here and
-- | calls `main(cliRoot)(binaryenBinDir)()`; the real logic lives in `Purwc.CLI.Main`.
module Purwc (module Purwc.CLI.Main) where

import Purwc.CLI.Main (main)
