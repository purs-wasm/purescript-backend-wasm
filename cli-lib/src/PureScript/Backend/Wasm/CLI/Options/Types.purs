-- | Option types shared by every CLI built on `cli-lib` (the user `purs-wasm` orchestrator, the
-- | per-module `purwc` worker, and the maintainer `ulib-tooling`). Command-specific option records
-- | live in each binary's own `Options.Types`.
module PureScript.Backend.Wasm.CLI.Options.Types
  ( GlobalOptions
  ) where

-- | Options every command accepts, parsed once and threaded to the interpreter — not part of any
-- | command's own option record.
type GlobalOptions = { verbose :: Boolean }
