-- | The lowering subsystem's shared vocabulary: the read-only fact tables
-- | (`CtorInfo` / `ModuleInfo` / `Env`), the module-qualified name encoding that
-- | keys those tables and the emitted wasm functions, and the one MIR-spine
-- | utility (`peelAbs`) used by both the link-time collection pass and the lowering
-- | itself.
module PureScript.Backend.Wasm.Lower.Types
  ( CtorInfo
  , ModuleInfo
  , ctorSig
  , qualifiedKey
  , qualifiedKeyOf
  , qualifiedFuncName
  , peelAbs
  ) where

import Prelude

import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.String (joinWith)
import Foreign.Object (Object)
import PureScript.Backend.Wasm.Lower.IR (FuncName(..), ForeignImport, Rep)
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.CoreFn (Qualified(..))

-- | `fieldReps` is the wasm representation chosen for each field (in field order):
-- | a concretely-`Int`/`Char`/`Number` field is stored unboxed (`I32`/`F64`) in the
-- | constructor's struct, everything else `Boxed` (ADR 0013, front B). It is read
-- | from the externs (`PureScript.Backend.Wasm.Externs`); without externs every
-- | field defaults to `Boxed`, so `length fieldReps == arity` always holds.
type CtorInfo = { tag :: Int, arity :: Int, fieldReps :: Array Rep }

-- | The struct-field signature a constructor lowers to — what `RMkData` /
-- | `RProjField` carry so codegen picks the `$Data_<sig>` struct type. Uses the
-- | externs-derived `fieldReps` (ADR 0013 front B), so a concrete `Int`/`Number`
-- | field is stored unboxed; without externs `fieldReps` is all-`Boxed`, recovering
-- | the uniform representation.
ctorSig :: CtorInfo -> Array Rep
ctorSig info = info.fieldReps

-- | Read-only facts about the whole program being lowered. All name-keyed
-- | tables use the **module-qualified** name (`Module.ident`), so a reference can
-- | resolve a callee in any linked module, not just its own (ADR 0009). `labelIds`
-- | is interned once across every module so records built and projected in
-- | different modules agree on a label's id.
type ModuleInfo =
  { knownFuncs :: Object Int
  , ctors :: Object CtorInfo
  -- | Names of type-class dictionary constructors (decls tagged
  -- | `IsTypeClassConstructor`). They are newtype identities (`\x -> x`) wrapping
  -- | the dictionary record, so their application is erased (ADR 0007).
  , dictCtors :: Object Unit
  -- | Constructors of enum-like types (every constructor nullary), built as
  -- | `i31ref` tags rather than heap `$ADT` structs (ADR 0013).
  , enumCtors :: Object Unit
  , labelIds :: Object Int
  -- | `foreign import`s that resolve to wasm host imports (ADR 0014), by qualified
  -- | name → calling convention; from the externs (`Externs.foreignSigs`).
  , foreignSigs :: Object ForeignImport
  -- | Every CoreFn-declared foreign name (qualified), used to fall back to an all-opaque
  -- | host import when a foreign has no reconstructed signature (ADR 0016).
  , foreignNames :: Set String
  }

-- | The globally-unique key/name for a module-qualified top-level identifier:
-- | `Module.ident`. The same string is used as a symbol-table key and as the
-- | emitted wasm function name, so cross-module references line up (ADR 0009).
qualifiedKey :: Array String -> String -> String
qualifiedKey moduleName ident = joinWith "." moduleName <> "." <> ident

-- | The key for a `Qualified` reference. A `Nothing` module means a local, which
-- | is never a top-level key; callers guard against that, but we fall back to the
-- | bare name so the lookup simply misses.
qualifiedKeyOf :: Qualified String -> String
qualifiedKeyOf (Qualified mModule name) = case mModule of
  Just moduleName -> qualifiedKey moduleName name
  Nothing -> name

qualifiedFuncName :: Qualified String -> FuncName
qualifiedFuncName = FuncName <<< qualifiedKeyOf

-- | Peel leading (uncurried) lambdas into the parameter idents (outermost first)
-- | and body. The MIR already groups a lambda's parameters into one list, but a
-- | pass may leave a residual nested `Abs`, so this still flattens.
peelAbs :: M.Expr -> { params :: Array String, body :: M.Expr }
peelAbs = go []
  where
  go acc = case _ of
    M.Abs ps b -> go (acc <> ps) b
    body -> { params: acc, body }
