module PureScript.Backend.Wasm.Lower.Env where

import Prelude

import Foreign.Object (Object)
import PureScript.Backend.Wasm.Lower.IR (Atom)
import PureScript.Backend.Wasm.Lower.Types (CtorInfo)

-- | The local environment plus the module facts. `locals` maps a CoreFn
-- | identifier to the `Atom` it denotes (a local slot, or — inside a lifted code
-- | function — a captured `EnvField`).
type Env =
  { locals :: Object Atom
  , knownFuncs :: Object Int
  , ctors :: Object CtorInfo
  , moduleName :: Array String
  , dictCtors :: Object Unit
  -- | Constructors of enum-like types (all-nullary), represented as `i31ref` tags.
  , enumCtors :: Object Unit
  , labelIds :: Object Int
  }
