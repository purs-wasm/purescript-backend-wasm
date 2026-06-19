-- | A pure, in-memory interpreter for the CLI's effects — the testability payoff of the `run`
-- | abstraction. `FS` reads/writes a `Map String FileEntry` (directories are implicit, inferred
-- | from the `/`-joined keys), `PROC` records the external-tool invocations (so tests assert
-- | *which* tool ran with *what* args, without running it), and `LOG` captures the rendered
-- | messages. Everything folds into `Run.State` and runs purely — no disk, no child processes,
-- | deterministic.
module Test.Unit.PursWasm.CLI.Effect.Memory
  ( World
  , FileEntry(..)
  , emptyWorld
  , worldOfText
  , runMem
  ) where

import Prelude

import Data.Array as Array
import Data.ArrayBuffer.Types (Uint8Array)
import Data.Either (Either(..))
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..))
import Data.String as Str
import Data.Tuple (Tuple(..))
import Dodo as Dodo
import PureScript.Backend.Wasm.CLI.Effect.Filesystem (FS, FilesystemF(..), _fs)
import PureScript.Backend.Wasm.CLI.Effect.Log (LOG, Log(..), _log)
import PureScript.Backend.Wasm.CLI.Effect.Process (PROC, ProcF(..), _proc)
import Run (Run, extract, interpret, on, send)
import Run.State (STATE, get, modify, runState)
import Type.Row (type (+))

data FileEntry
  = Text String
  | Bin Uint8Array

-- | The in-memory world: a flat path→content map, the recorded external-tool calls, and the
-- | captured (plain-rendered) log lines.
type World =
  { fs :: Map String FileEntry
  , execs :: Array (Tuple String (Array String))
  , logs :: Array String
  }

emptyWorld :: World
emptyWorld = { fs: Map.empty, execs: [], logs: [] }

-- | A world seeded with the given text files (most fixtures need only text).
worldOfText :: Array (Tuple String String) -> World
worldOfText files = emptyWorld { fs = Map.fromFoldable (map (map Text) files) }

-- | Run a command program against the in-memory world; returns the final world (FS state, exec
-- | calls, logs) paired with the result.
runMem :: forall a. World -> Run (FS + PROC + LOG + STATE World + ()) a -> Tuple World a
runMem world prog = extract (runState world (interpLog (interpProc (interpFs prog))))

interpFs :: forall r. Run (FS + STATE World + r) ~> Run (STATE World + r)
interpFs = interpret (on _fs handle send)
  where
  handle :: FilesystemF ~> Run (STATE World + r)
  handle = case _ of
    ReadText path k -> get <#> \w -> k (textOf =<< Map.lookup path w.fs)
    ReadBinary path k -> get <#> \w -> k (binOf =<< Map.lookup path w.fs)
    WriteText path s next -> modify (\w -> w { fs = Map.insert path (Text s) w.fs }) $> next
    WriteBinary path b next -> modify (\w -> w { fs = Map.insert path (Bin b) w.fs }) $> next
    ReadDir path k -> get <#> \w -> k (childrenOf path w.fs)
    Exists path k -> get <#> \w -> k (existsIn path w.fs)
    FileSize path k -> get <#> \w -> k (sizeOfEntry <$> Map.lookup path w.fs)
    MkdirP _ next -> pure next
    Unlink path next -> modify (\w -> w { fs = Map.delete path w.fs }) $> next
    JoinPath segments k -> pure (k (pureJoin segments))
    ResolvePath segments last k -> pure (k (pureResolve segments last))

interpProc :: forall r. Run (PROC + STATE World + r) ~> Run (STATE World + r)
interpProc = interpret (on _proc handle send)
  where
  handle :: ProcF ~> Run (STATE World + r)
  handle = case _ of
    ExecFile cmd args next -> modify (\w -> w { execs = Array.snoc w.execs (Tuple cmd args) }) $> next
    -- Captured exec is recorded like any other, but not stubbed: the only caller (`ulib compat`)
    -- is covered by the differential harness and pure-helper tests, not the in-memory interpreter.
    ExecFileCapture cmd args k -> modify (\w -> w { execs = Array.snoc w.execs (Tuple cmd args) })
      $> k (Left "execFileCapture is not stubbed in the in-memory interpreter")
    ExecFileInput cmd args _ next -> modify (\w -> w { execs = Array.snoc w.execs (Tuple cmd args) }) $> next
    ReadStdin k -> pure (k "")

interpLog :: forall r. Run (LOG + STATE World + r) ~> Run (STATE World + r)
interpLog = interpret (on _log handle send)
  where
  handle :: Log ~> Run (STATE World + r)
  handle = case _ of
    Log _ doc next -> modify (\w -> w { logs = Array.snoc w.logs (Dodo.print Dodo.plainText Dodo.twoSpaces doc) }) $> next

textOf :: FileEntry -> Maybe String
textOf = case _ of
  Text s -> Just s
  _ -> Nothing

-- A rough byte size for the in-memory file (code-unit length of text; binaries are not exercised).
sizeOfEntry :: FileEntry -> Int
sizeOfEntry = case _ of
  Text s -> Str.length s
  Bin _ -> 0

binOf :: FileEntry -> Maybe Uint8Array
binOf = case _ of
  Bin b -> Just b
  _ -> Nothing

existsIn :: String -> Map String FileEntry -> Boolean
existsIn path fs =
  Map.member path fs || Array.any (isPrefix (path <> "/")) (Array.fromFoldable (Map.keys fs))

-- | Immediate children of `path` (the next path segment of each key beneath it); `Nothing` when
-- | nothing lives under it (a missing directory, mirroring a failed `readdir`).
childrenOf :: String -> Map String FileEntry -> Maybe (Array String)
childrenOf path fs =
  let
    prefix = path <> "/"
    under = Array.filter (isPrefix prefix) (Array.fromFoldable (Map.keys fs))
  in
    if Array.null under then Nothing
    else Just (Array.nub (Array.mapMaybe (firstSeg prefix) under))

-- | Pure path join for tests: `/`-join, dropping empty/`.` segments (matches `Node.Path.concat`
-- | for clean segments).
pureJoin :: Array String -> String
pureJoin segments = Str.joinWith "/" (Array.filter (\p -> p /= "" && p /= ".") segments)

-- | Pure path resolution for tests: join the segments and collapse `.`/`..` (no cwd, so the
-- | result stays relative — deterministic, unlike the Node interpreter's absolutising `resolve`).
pureResolve :: Array String -> String -> String
pureResolve segments last =
  Str.joinWith "/" (Array.foldl step [] parts)
  where
  parts = Array.filter (\p -> p /= "" && p /= ".") (Array.concatMap (Str.split (Pattern "/")) (Array.snoc segments last))
  step acc p = if p == ".." then Array.dropEnd 1 acc else Array.snoc acc p

isPrefix :: String -> String -> Boolean
isPrefix p s = Str.take (Str.length p) s == p

firstSeg :: String -> String -> Maybe String
firstSeg prefix key = Str.stripPrefix (Pattern prefix) key >>= (Array.head <<< Str.split (Pattern "/"))
