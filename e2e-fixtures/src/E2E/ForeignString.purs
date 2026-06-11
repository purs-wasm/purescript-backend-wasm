-- e2e fixture (ADR 0031 phase 5): String marshalling ($Str <-> JS string, ADR 0014) in BOTH
-- directions through the generated loader — `greet` is a String -> String export (export-side
-- marshalling) that internally calls the JS `shout` foreign (import-side marshalling).
module E2E.ForeignString where

import Prelude

foreign import shout :: String -> String

greet :: String -> String
greet name = shout ("hi " <> name)
