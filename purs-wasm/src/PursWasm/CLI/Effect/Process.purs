module PursWasm.CLI.Effect.Process where

import Prelude

import Run (Run, EFFECT)
import Run as Run
import Type.Proxy (Proxy(..))
import Type.Row (type (+))

data ProcF a = ExecFile String (Array String) a

derive instance functorProcF :: Functor ProcF

type PROC r = (proc :: ProcF | r)

_proc :: Proxy "proc"
_proc = Proxy

interpret :: forall r a. (ProcF ~> Run r) -> Run (PROC + r) a -> Run r a
interpret h = Run.interpret (Run.on _proc h Run.send)

-- | Run an external tool synchronously (e.g. `wasm-merge`); throws in the interpreter on a
-- | non-zero exit, matching the prototype's `execFileSync` behaviour.
execFile :: forall r. String -> Array String -> Run (PROC + r) Unit
execFile cmd args = Run.lift _proc (ExecFile cmd args unit)

