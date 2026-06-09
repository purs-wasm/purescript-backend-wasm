module PursWasm.CLI.Effect.Filesystem where

import Prelude

import Data.ArrayBuffer.Types (Uint8Array)
import Data.Maybe (Maybe)
import Run (Run)
import Run as Run
import Type.Proxy (Proxy(..))
import Type.Row (type (+))

type FilePath = String

data FilesystemF a
  = ReadText FilePath (Maybe String -> a)
  | WriteText FilePath String a
  | ReadDir FilePath (Maybe (Array String) -> a)
  | Exists FilePath (Boolean -> a)
  | MkdirP FilePath a
  | Unlink FilePath a
  -- Binary as `Uint8Array` (not Node's `Buffer`) keeps this abstract effect platform-neutral —
  -- no `Node.*` import here; the Node interpreter converts at its boundary.
  | ReadBinary FilePath (Maybe Uint8Array -> a)
  | WriteBinary FilePath Uint8Array a

derive instance functorFilesystemF :: Functor FilesystemF

type FS r = (fs :: FilesystemF | r)

_fs :: Proxy "fs"
_fs = Proxy

interpret :: forall r a. (FilesystemF ~> Run r) -> Run (FS + r) a -> Run r a
interpret h = Run.interpret (Run.on _fs h Run.send)

-- | Read a UTF-8 file, `Nothing` if it cannot be read.
readText :: forall r. FilePath -> Run (FS + r) (Maybe String)
readText path = Run.lift _fs (ReadText path identity)

-- | Read a file as bytes, `Nothing` if it cannot be read.
readBinary :: forall r. FilePath -> Run (FS + r) (Maybe Uint8Array)
readBinary path = Run.lift _fs (ReadBinary path identity)

writeText :: forall r. FilePath -> String -> Run (FS + r) Unit
writeText path contents = Run.lift _fs (WriteText path contents unit)

writeBinary :: forall r. FilePath -> Uint8Array -> Run (FS + r) Unit
writeBinary path bytes = Run.lift _fs (WriteBinary path bytes unit)

-- | List a directory's entries, `Nothing` if it cannot be read.
readDir :: forall r. FilePath -> Run (FS + r) (Maybe (Array String))
readDir path = Run.lift _fs (ReadDir path identity)

exists :: forall r. FilePath -> Run (FS + r) Boolean
exists path = Run.lift _fs (Exists path identity)

-- | Create a directory (and any missing parents).
mkdirP :: forall r. FilePath -> Run (FS + r) Unit
mkdirP path = Run.lift _fs (MkdirP path unit)

unlink :: forall r. FilePath -> Run (FS + r) Unit
unlink path = Run.lift _fs (Unlink path unit)