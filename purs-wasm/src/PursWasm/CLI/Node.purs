-- | The synchronous Node production interpreter for the CLI's effects (`PursWasm.CLI.Effect`).
-- | Each per-effect `interpret` peels its effect into the `EFFECT` base row via Node's
-- | *synchronous* APIs (`Node.FS.Sync` + `execFileSync`), so the CLI never touches `Aff` (ADR 0029
-- | self-hosting note: a future WASI interpreter can replace this without changing command logic).
-- | Failing reads are caught (`try`) and surfaced as `Nothing`, matching the effect algebra's
-- | totality.
module PursWasm.CLI.Node
  ( runNode
  , defaultLoggerConfig
  ) where

import Prelude

import Data.ArrayBuffer.Types (Uint8Array)
import Data.Bifunctor (lmap)
import Data.Either (hush)
import Data.Maybe (isNothing)
import Effect (Effect)
import Effect.Exception (message, try)
import Node.Encoding (Encoding(..))
import Node.FS.Perms (permsAll)
import Node.FS.Sync as Sync
import Node.Path as Path
import PursWasm.CLI.Effect.Filesystem (FS, FilesystemF(..))
import PursWasm.CLI.Effect.Filesystem as FS
import PursWasm.CLI.Effect.Log (LOG, LogLevel(..), LoggerConfig)
import PursWasm.CLI.Effect.Log as Log
import PursWasm.CLI.Effect.Process (PROC, ProcF(..))
import PursWasm.CLI.Effect.Process as Proc
import PursWasm.CLI.Effect.Registry (REGISTRY)
import PursWasm.CLI.Effect.Registry as Registry
import Run (EFFECT, Run, liftEffect, runBaseEffect)
import Type.Row (type (+))

-- | Run a CLI program (its effect row fully closed) against the synchronous Node backend. `REGISTRY`
-- | is interpreted first, into `PROC` (it asks `spago`), so it must be peeled before `PROC` is.
runNode :: forall a. Run (FS + REGISTRY + PROC + LOG + EFFECT + ()) a -> Effect a
runNode m = m
  # Registry.interpret Registry.spagoHandler
  # FS.interpret nodeFsHandler
  # Proc.interpret nodeChildProcessHandler
  # Log.interpret (Log.terminalHandler defaultLoggerConfig)
  # runBaseEffect

-- | The default console logging config. The bin prototype logged every message via `Console.log`;
-- | mapping its messages to `info` keeps them visible at this level (`debug` is the quieter tier).
defaultLoggerConfig :: LoggerConfig
defaultLoggerConfig = { minLevel: Info, color: true, strict: false }

nodeFsHandler :: forall r. FilesystemF ~> Run (EFFECT + r)
nodeFsHandler = case _ of
  ReadText path k -> k <$> liftEffect (hush <$> try (Sync.readTextFile UTF8 path))
  ReadBinary path k -> k <$> liftEffect (hush <$> try (readFileBytesImpl path))
  WriteText path contents next -> liftEffect (Sync.writeTextFile UTF8 path contents) $> next
  WriteBinary path bytes next -> liftEffect (writeFileBytesImpl path bytes) $> next
  ReadDir path k -> k <$> liftEffect (hush <$> try (Sync.readdir path))
  Exists path k -> k <$> liftEffect (isNothing <$> Sync.access path)
  MkdirP path next -> liftEffect (Sync.mkdir' path { recursive: true, mode: permsAll }) $> next
  Unlink path next -> liftEffect (Sync.unlink path) $> next
  JoinPath segments k -> pure (k (Path.concat segments))
  ResolvePath segments last k -> k <$> liftEffect (Path.resolve segments last)

nodeChildProcessHandler :: forall r. ProcF ~> Run (EFFECT + r)
nodeChildProcessHandler = case _ of
  ExecFile cmd args next -> liftEffect (execFileImpl cmd args) $> next
  ExecFileCapture cmd args k -> k <$> liftEffect (lmap message <$> try (execFileCaptureImpl cmd args))

-- | Run an external tool synchronously (`execFileSync`, stdio inherited; throws on non-zero exit).
foreign import execFileImpl :: String -> Array String -> Effect Unit

-- | Run an external tool synchronously and return its captured stdout (`execFileSync` with
-- | `encoding: utf8`); throws on failure, which the handler turns into `Left` via `try`.
foreign import execFileCaptureImpl :: String -> Array String -> Effect String

-- | Read/write a file as bytes. `node:fs` deals in `Buffer`, which *is* a `Uint8Array`, so these
-- | convert at the boundary with no copy — keeping the `Filesystem` effect Node-agnostic.
foreign import readFileBytesImpl :: String -> Effect Uint8Array

foreign import writeFileBytesImpl :: String -> Uint8Array -> Effect Unit
