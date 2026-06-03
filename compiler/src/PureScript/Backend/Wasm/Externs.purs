-- | Bridge from `purs`'s externs (`externs.cbor`) to the backend's representation
-- | choices. CoreFn is type-erased, but the externs retain each data
-- | constructor's *type* — so this is where top-level type information re-enters
-- | the pipeline (ADR 0013, front B): a constructor field that is concretely
-- | `Int`/`Char`/`Number` can be stored unboxed (`i32`/`f64`) in the constructor's
-- | struct instead of as a boxed `eqref`. The same externs are the foundation for
-- | later type-directed work (nominal record / dictionary layout).
module PureScript.Backend.Wasm.Externs
  ( ctorFieldReps
  , ForeignSig
  , foreignSigs
  ) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Foreign.Object (Object)
import Foreign.Object as Object
import PureScript.Backend.Wasm.Lower.IR (Rep(..))
import PureScript.ExternsFile (ExternsDeclaration(..), ExternsFile(..))
import PureScript.ExternsFile.Names (Ident(..), ModuleName(..), ProperName(..), Qualified(..), QualifiedBy(..))
import PureScript.ExternsFile.Types as T

-- | Map every data constructor (by qualified name, `Module.Ctor`) to the wasm
-- | representation of each of its fields, in field order: `I32` for `Int`/`Char`,
-- | `F64` for `Number`, `Boxed` for anything else (polymorphic vars, other ADTs,
-- | records, …). Constructors absent from this table (no externs supplied) default
-- | to all-`Boxed` at the use site, so the table is purely an optimisation input.
ctorFieldReps :: Array ExternsFile -> Object (Array Rep)
ctorFieldReps externs = Object.fromFoldable (externs >>= declsOf)
  where
  declsOf (ExternsFile _ (ModuleName mn) _ _ _ _ decls _) = Array.mapMaybe (ctorOf mn) decls
  ctorOf mn = case _ of
    EDDataConstructor (ProperName ctorName) _ _ ty _ ->
      Just (Tuple (mn <> "." <> ctorName) (map scalarRep (fieldTypes ty)))
    _ -> Nothing

-- | The wasm calling convention of a `foreign import`, derived from its externs
-- | type: the representation of each parameter and of the result. A fully-scalar
-- | foreign (`cos :: Number -> Number`) becomes `{ params: [F64], result: F64 }`,
-- | which crosses the JS boundary with no marshalling (an `f64`/`i32` *is* a JS
-- | `number`); a non-scalar parameter/result stays `Boxed` (ADR 0014, host imports).
-- | `moduleName`/`base` are the foreign's source module and identifier — the wasm
-- | import's `(module, name)` pair the JS loader satisfies.
type ForeignSig =
  { moduleName :: String
  , base :: String
  , params :: Array Rep
  , result :: Rep
  }

-- | Every top-level value's externs signature, keyed by qualified name
-- | (`Module.ident`). This includes ordinary functions, but only actual
-- | `foreign import`s reach the foreign-resolution path at a use site (a defined
-- | function resolves earlier as a known function), so the extra entries are inert.
foreignSigs :: Array ExternsFile -> Object ForeignSig
foreignSigs externs = Object.fromFoldable (externs >>= declsOf)
  where
  declsOf (ExternsFile _ (ModuleName mn) _ _ _ _ decls _) = Array.mapMaybe (valueOf mn) decls
  valueOf mn = case _ of
    EDValue (Ident ident) ty ->
      Just (Tuple (mn <> "." <> ident) { moduleName: mn, base: ident, params: foreignParams ty, result: foreignResult ty })
    _ -> Nothing

-- | The wasm representation of each runtime parameter of a foreign's type, in
-- | order. `forall` quantifiers are transparent; each **constraint** is a runtime
-- | dictionary argument (a boxed `eqref`); each function arrow contributes its
-- | argument's scalar rep. So `forall a. Show a => a -> String` has params
-- | `[Boxed (the Show dict), Boxed (a)]`.
foreignParams :: forall a. T.Type a -> Array Rep
foreignParams = case _ of
  T.ForAll _ _ _ _ t _ -> foreignParams t
  T.ConstrainedType _ _ t -> Array.cons Boxed (foreignParams t)
  T.TypeApp _ (T.TypeApp _ (T.TypeConstructor _ fn) arg) rest
    | isFunction fn -> Array.cons (scalarRep arg) (foreignParams rest)
  _ -> []

-- | The rep of a foreign's result — the type left after the quantifiers,
-- | constraints, and argument arrows.
foreignResult :: forall a. T.Type a -> Rep
foreignResult = case _ of
  T.ForAll _ _ _ _ t _ -> foreignResult t
  T.ConstrainedType _ _ t -> foreignResult t
  T.TypeApp _ (T.TypeApp _ (T.TypeConstructor _ fn) _) rest
    | isFunction fn -> foreignResult rest
  t -> scalarRep t

-- | The argument types of a curried function type, in order. A constructor's
-- | externs type is `field0 -> field1 -> … -> T`, encoded as nested `TypeApp`s of
-- | the `Prim.Function` constructor (`A -> B` is `(Function A) B`), so peeling that
-- | spine yields exactly the field types.
fieldTypes :: forall a. T.Type a -> Array (T.Type a)
fieldTypes = case _ of
  T.TypeApp _ (T.TypeApp _ (T.TypeConstructor _ fn) arg) rest
    | isFunction fn -> Array.cons arg (fieldTypes rest)
  _ -> []

isFunction :: Qualified ProperName -> Boolean
isFunction = case _ of
  Qualified (ByModuleName (ModuleName "Prim")) (ProperName "Function") -> true
  _ -> false

-- | The representation a concretely-typed scalar field gets. Only the primitive
-- | scalar type constructors are recognised; everything else stays boxed.
scalarRep :: forall a. T.Type a -> Rep
scalarRep = case _ of
  T.TypeConstructor _ (Qualified _ (ProperName n))
    | n == "Int" || n == "Char" -> I32
    | n == "Number" -> F64
  _ -> Boxed
