-- | Harness for the CLI-driven e2e suites whose fixtures have **host foreign imports** (ADR 0014/0031
-- | phase 5). Unlike `Test.E2E.Cli.Harness` (raw standalone wasm), these are loaded through the
-- | fixture's *generated loader* `index.mjs` — the real deliverable, which bundles the foreign `.js`
-- | and the `$Str`/`$Vals`/`$Rec` marshalling glue. So `loadExports` dynamic-imports that loader and
-- | hands back its `exports`; the call helpers invoke a marshalled export (i32 directly; `callJson`
-- | passes/returns JSON-able JS values for String/Array/Record marshalling, both directions).
module Test.E2E.Cli.Loader
  ( Exports
  , loadExports
  , callI32x0
  , callI32x1
  , callJson
  , getJson
  , runUnit
  ) where

import Prelude

import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Aff.Compat (EffectFnAff, fromEffectFnAff)

-- | The marshalled `exports` object of a fixture's generated loader.
foreign import data Exports :: Type

foreign import loadExportsImpl :: String -> EffectFnAff Exports

-- | Dynamic-import `compiler/test/e2e-build/<module>/index.mjs` and return its `exports`.
loadExports :: String -> Aff Exports
loadExports = fromEffectFnAff <<< loadExportsImpl

-- | Call an i32-typed export (no marshalling needed — raw i32 in/out).
foreign import callI32x0 :: Exports -> String -> Effect Int
foreign import callI32x1 :: Exports -> String -> Int -> Effect Int

-- | Call a marshalled export generically: the JSON-encoded argument array is parsed to JS values,
-- | applied (the loader marshals String/Array/Record at the boundary), and the JS result is
-- | JSON-stringified back. Covers Int/String/Array/Record uniformly (not closures).
foreign import callJson :: Exports -> String -> String -> Effect String

-- | Read a nullary value export, JSON-stringified. The loader evaluates a nullary export once and
-- | exposes it as the value itself (`exports.x` is `42` / `"hi"`, not a function, already marshalled).
foreign import getJson :: Exports -> String -> Effect String

-- | Run an exported `Effect Unit` (the loader exposes it as a deferred thunk).
foreign import runUnit :: Exports -> String -> Effect Unit
