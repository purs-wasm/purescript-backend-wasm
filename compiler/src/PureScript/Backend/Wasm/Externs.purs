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
  , effectfulForeignNamesFromSigs
  , effectfulForeignNamesFromExterns
  ) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.Set as Set
import Data.Tuple (Tuple(..))
import Foreign.Object (Object)
import Foreign.Object as Object
import PureScript.Backend.Wasm.Lower.IR (MarshalKind(..), Rep(..))
import PureScript.ExternsFile (ExternsDeclaration(..), ExternsFile(..))
import PureScript.ExternsFile.Names (Ident(..), ModuleName(..), ProperName(..), Qualified(..), QualifiedBy(..))
import PureScript.ExternsFile.PSString (toString)
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
  , params :: Array MarshalKind
  , result :: MarshalKind
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

-- | The qualified names (`Module.ident`) of foreign signatures whose *running* performs a
-- | side effect — i.e. whose result is an `MEffect`. The seed the middle-end purity
-- | analysis (ADR 0015) needs so a host effect like `log` is preserved rather than
-- | dropped/reordered. Operates on `ForeignSig`s, so it works for both the externs- and
-- | source-derived (ADR 0016) sets.
effectfulForeignNamesFromSigs :: Object ForeignSig -> Set String
effectfulForeignNamesFromSigs sigs = Set.fromFoldable (Array.mapMaybe pick (Object.toUnfoldable sigs))
  where
  pick (Tuple key sig) = case sig.result of
    MEffect _ -> Just key
    _ -> Nothing

-- | The effectful foreign names from externs (the externs-only path, e.g. the e2e harness).
effectfulForeignNamesFromExterns :: Array ExternsFile -> Set String
effectfulForeignNamesFromExterns = effectfulForeignNamesFromSigs <<< foreignSigs

-- | The marshal kind of each parameter of a foreign's type, in order. `forall`
-- | quantifiers are transparent (a foreign may be polymorphic, e.g. `forall a. a ->
-- | a`); each function arrow contributes its argument's kind. (Constraints need no
-- | handling: purs rejects them on `foreign import`s.)
foreignParams :: forall a. T.Type a -> Array MarshalKind
foreignParams = case _ of
  T.ForAll _ _ _ _ t _ -> foreignParams t
  T.TypeApp _ (T.TypeApp _ (T.TypeConstructor _ fn) arg) rest
    | isFunction fn -> Array.cons (marshalKind arg) (foreignParams rest)
  _ -> []

-- | The marshal kind of a foreign's result — the type left after the `forall`
-- | quantifiers and argument arrows.
foreignResult :: forall a. T.Type a -> MarshalKind
foreignResult = case _ of
  T.ForAll _ _ _ _ t _ -> foreignResult t
  T.TypeApp _ (T.TypeApp _ (T.TypeConstructor _ fn) _) rest
    | isFunction fn -> foreignResult rest
  t -> marshalKind t

-- | The FFI marshal kind of a concrete type at the boundary: scalars cross as a JS
-- | `number` (`MI32`/`MF64`), `Boolean` to/from a JS `boolean` (`MBool`), `String`
-- | to/from a JS `string` (`MStr`), `Array a` to/from a JS array (`MArray`, recursing
-- | on the element), `Record` to/from a JS object (`MRecord`), a function `a -> b`
-- | to/from a JS function (`MFunc`, recursing on both sides), everything else opaque
-- | (`MOpaque`).
marshalKind :: forall a. T.Type a -> MarshalKind
marshalKind = case _ of
  T.TypeApp _ (T.TypeApp _ (T.TypeConstructor _ fn) arg) rest
    | isFunction fn -> MFunc (marshalKind arg) (marshalKind rest)
  T.TypeApp _ (T.TypeConstructor _ ctor) arg
    | named "Array" ctor -> MArray (marshalKind arg)
    | named "Record" ctor -> MRecord (rowFields arg)
    -- `Effect a`: an effectful foreign — the JS glue runs its thunk and marshals the
    -- inner result `a` (ADR 0015). (`EffectFnN` is future work.)
    | named "Effect" ctor -> MEffect (marshalKind arg)
  T.TypeConstructor _ (Qualified _ (ProperName n))
    | n == "Int" || n == "Char" -> MI32
    | n == "Number" -> MF64
    | n == "Boolean" -> MBool
    | n == "String" -> MStr
  _ -> MOpaque

named :: String -> Qualified ProperName -> Boolean
named n = case _ of
  Qualified _ (ProperName m) -> m == n

-- | The fields of a record's row type `( l :: T, … )`, encoded as nested `RCons`
-- | terminated by `REmpty` (an open row's tail var is ignored).
rowFields :: forall a. T.Type a -> Array (Tuple String MarshalKind)
rowFields = case _ of
  T.RCons _ (T.Label pss) ty rest -> Array.cons (Tuple (toString pss) (marshalKind ty)) (rowFields rest)
  _ -> []

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
