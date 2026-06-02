-- | The middle IR (MIR): the high-level optimization IR between CoreFn and the
-- | backend lowering (ADR 0005). It is a faithful, **uncurried** tree — the one
-- | structural change from CoreFn is that `Abs` / `App` carry parameter / argument
-- | *lists* (so arity is explicit and saturated calls are visible), which makes
-- | inlining, lambda lifting, and direct-call detection tractable. Everything else
-- | mirrors CoreFn: type-class dictionaries and records remain ordinary values
-- | (dictionary elimination is a later `Optimize` pass, not baked into the IR), and
-- | the leaf types (`Literal`, `Binder`, `Qualified`, `Meta`, …) are reused from
-- | `PureScript.CoreFn`. Source spans are dropped; only the `Meta` that downstream
-- | passes need (e.g. `IsTypeClassConstructor`, `IsNewtype`) is kept.
module PureScript.Backend.Wasm.MiddleEnd.IR
  ( Module
  , Expr(..)
  , Bind(..)
  , RecBinding
  , Alt
  , Guard
  ) where

import Prelude

import Data.Either (Either)
import Data.Generic.Rep (class Generic)
import Data.Maybe (Maybe)
import Data.Show.Generic (genericShow)
import Data.Tuple (Tuple)
import PureScript.CoreFn (Binder, Ident, Literal, Meta, ModuleName, ProperName, Qualified)

-- | A whole module after translation: its name and top-level binding groups.
type Module = { name :: ModuleName, decls :: Array Bind }

data Expr
  = Lit (Literal Expr)
  -- | A variable: `Qualified Nothing` is a local, `Qualified (Just m)` a top-level
  -- | reference (function / value / constructor). Whether a top-level name is a
  -- | known function (and its arity) is carried by an analysis environment, not the
  -- | node.
  | Var (Qualified Ident)
  -- | An **uncurried** lambda: the full parameter list at once (non-empty in
  -- | practice). A nullary value binding is just its body, not an `Abs`.
  | Abs (Array Ident) Expr
  -- | An **uncurried** application: a head applied to an argument list at once
  -- | (non-empty). Saturation against a known function's arity is a simple length
  -- | check here, rather than walking a curried `App` spine.
  | App Expr (Array Expr)
  -- | A constructor *declaration* (type name, constructor name, field names), the
  -- | form CoreFn gives a data constructor's top-level binding. Use sites are a
  -- | `Var` of the constructor name applied to its fields.
  | Constructor ProperName ProperName (Array Ident)
  -- | Record / dictionary field read.
  | Accessor String Expr
  -- | Record update; `Just` lists the untouched labels for a monomorphic update.
  | Update Expr (Maybe (Array String)) (Array (Tuple String Expr))
  | Case (Array Expr) (Array Alt)
  | Let (Array Bind) Expr

derive instance Generic Expr _
derive instance Eq Expr
instance Show Expr where
  show e = genericShow e

-- | A binding group. `meta` carries the CoreFn binding meta a later pass needs —
-- | chiefly `IsTypeClassConstructor`, which marks the newtype-identity dictionary
-- | constructors that dictionary elimination erases.
data Bind
  = NonRec (Maybe Meta) Ident Expr
  | Rec (Array RecBinding)

derive instance Generic Bind _
derive instance Eq Bind
instance Show Bind where
  show b = genericShow b

type RecBinding = { meta :: Maybe Meta, ident :: Ident, expr :: Expr }

-- | A `case` alternative: a row of binders and either a single unguarded result
-- | (`Right`) or guarded results (`Left`). `Binder` is reused from CoreFn (it
-- | carries no sub-expressions except guards, which live in `Guard`).
type Alt = { binders :: Array Binder, result :: Either (Array Guard) Expr }

type Guard = { guard :: Expr, expression :: Expr }
