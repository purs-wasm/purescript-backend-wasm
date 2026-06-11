-- | Where the precompiled ulib lib lives (ADR 0031 §5). Shared by the user `build` CLI and the
-- | maintainer `install`/`check` commands, so they agree on the precedence: an explicit `-L`/
-- | `--lib-path` override, else `$PURS_WASM_LIB` (the `ulib upgrade` flow — a user with only a
-- | prebuilt lib points the env var at it), else the default `<cliRoot>/../lib` beside the binary.
module PursWasm.CLI.Lib
  ( resolveLibPath
  ) where

import Prelude

import Data.Maybe (Maybe(..))
import PursWasm.CLI.Effect (ENV, FS, FilePath, joinPath, lookupEnv)
import Run (Run)
import Type.Row (type (+))

resolveLibPath :: forall r. FilePath -> Maybe FilePath -> Run (FS + ENV + r) FilePath
resolveLibPath cliRoot = case _ of
  Just override -> pure override
  Nothing -> lookupEnv "PURS_WASM_LIB" >>= case _ of
    Just envPath | envPath /= "" -> pure envPath
    _ -> joinPath [ cliRoot, "..", "lib" ]
