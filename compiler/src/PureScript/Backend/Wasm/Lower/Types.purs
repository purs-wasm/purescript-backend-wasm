-- | The lowering subsystem's shared vocabulary: the read-only fact tables
-- | (`CtorInfo` / `ModuleInfo` / `Env`), the module-qualified name encoding that
-- | keys those tables and the emitted wasm functions, and the one MIR-spine
-- | utility (`peelAbs`) used by both the link-time collection pass and the lowering
-- | itself.
module PureScript.Backend.Wasm.Lower.Types
  ( CtorInfo
  , ModuleInfo
  , qualifiedKey
  , qualifiedKeyOf
  , qualifiedFuncName
  , peelAbs
  ) where

import Prelude

import Data.Maybe (Maybe(..))
import Data.String (joinWith)
import Foreign.Object (Object)
import PureScript.Backend.Wasm.Lower.IR (FuncName(..))
import PureScript.Backend.Wasm.MiddleEnd.IR as M
import PureScript.CoreFn (Qualified(..))

type CtorInfo = { tag :: Int, arity :: Int }

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
  , labelIds :: Object Int
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
