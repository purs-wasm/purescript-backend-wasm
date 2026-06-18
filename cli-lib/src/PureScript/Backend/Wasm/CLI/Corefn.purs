-- | Cheap metadata extracted from a `corefn.json` *without* a full decode: the dotted import module
-- | names (for file-level reachability pruning before the expensive decode) and the bare
-- | foreign-import names a module declares (for lowering's qualified foreign set on the cache path,
-- | ADR 0034). Both are total — a malformed/unparseable corefn yields `[]` — so they are safe to use
-- | directly. Shared by the `purs-wasm` orchestrator and the `purwc` worker (ADR 0038).
module PureScript.Backend.Wasm.CLI.Corefn
  ( corefnImports
  , corefnForeignNames
  ) where

-- | The dotted import module names of a `corefn.json` (`["Data","Maybe"]` joined → `"Data.Maybe"`).
foreign import corefnImports :: String -> Array String

-- | The bare foreign-import names a `corefn.json` declares (its `foreign` list).
foreign import corefnForeignNames :: String -> Array String
