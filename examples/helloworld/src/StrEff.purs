-- A `String -> Effect Unit` export — the regression fixture for `compiler/test/runStringEffect.mjs`
-- (marshalled String argument + `Effect` result: the export wrapper synthesises the `Effect`
-- perform-unit, the loader exposes a deferred thunk). Kept in the stable `helloworld` example so the
-- guard does not couple to a volatile example's `main` shape.
module Examples.HelloWorld.StrEff where

import Prelude

import Effect (Effect)
import Effect.Console (log)

main :: String -> Effect Unit
main name = log ("Hello, " <> name <> "!")
