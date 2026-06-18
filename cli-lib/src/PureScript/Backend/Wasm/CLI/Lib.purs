-- | Where the precompiled ulib lib lives (ADR 0031 §5). Shared by the user `build` CLI and the
-- | maintainer `install`/`check` commands, so they agree on the precedence: an explicit `-L`/
-- | `--lib-path` override, else `$PURS_WASM_LIB` (the lib-override flow — a user with only a
-- | prebuilt lib points the env var at it; the planned `ulib upgrade` command, ADR 0031 §5, is
-- | not yet implemented), else the default `<cliRoot>/lib` (the lib ships inside
-- | the package; `cliRoot` is the package dir in the published CLI, the repo root in dev).
module PureScript.Backend.Wasm.CLI.Lib
  ( resolveLibPath
  ) where

import Prelude

import Data.Maybe (Maybe(..))
import PureScript.Backend.Wasm.CLI.Effect (ENV, FS, FilePath, joinPath, lookupEnv)
import Run (Run)
import Type.Row (type (+))

resolveLibPath :: forall r. FilePath -> Maybe FilePath -> Run (FS + ENV + r) FilePath
resolveLibPath cliRoot = case _ of
  Just override -> pure override
  Nothing -> lookupEnv "PURS_WASM_LIB" >>= case _ of
    Just envPath | envPath /= "" -> pure envPath
    _ -> joinPath [ cliRoot, "lib" ]
