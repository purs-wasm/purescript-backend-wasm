module PureScript.Backend.Wasm.Lower.Env where

import Prelude

import Data.Set (Set)
import Foreign.Object (Object)
import PureScript.Backend.Wasm.Lower.IR (Atom, ForeignImport)
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
  -- | `foreign import`s (by qualified name) that resolve to a wasm host import,
  -- | with their calling convention (ADR 0014).
  , foreignSigs :: Object ForeignImport
  -- | Every `foreign import` name declared in CoreFn (`m.foreignNames`, qualified). A
  -- | foreign with no entry in `foreignSigs` (reconstruction failed; ADR 0016) is still
  -- | here, so it falls back to an all-opaque host import instead of failing the build.
  , foreignNames :: Set String
  }
