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
  , effectfulForeignAritiesFromSigs
  , effectfulForeignAritiesFromExterns
  ) where

import Prelude

import Data.Array as Array
import Data.Map (Map)
import Data.Map as Map
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
  -- A `type Foo = { … }` alias is stored unexpanded in the externs, so a foreign typed `Foo -> …`
  -- would otherwise marshal as `MOpaque`. Resolve nullary synonyms first so record/array/etc. aliases
  -- reach their real `marshalKind`.
  syns = synonymTable externs
  declsOf (ExternsFile _ (ModuleName mn) _ _ _ _ decls _) = Array.mapMaybe (valueOf mn) decls
  valueOf mn = case _ of
    EDValue (Ident ident) ty ->
      Just (Tuple (mn <> "." <> ident) { moduleName: mn, base: ident, params: foreignParams syns ty, result: foreignResult syns ty })
    _ -> Nothing

-- | Nullary type synonyms across every externs file, keyed by qualified name (`Module.Name`) →
-- | body. Parameterized synonyms are skipped (kept `MOpaque`); the common `type Point = { … }` is
-- | nullary. `marshalKind` expands these so a foreign typed by an alias marshals by the real type.
synonymTable :: Array ExternsFile -> Map String T.SourceType
synonymTable externs = Map.fromFoldable (externs >>= synsOf)
  where
  synsOf (ExternsFile _ (ModuleName mn) _ _ _ _ decls _) = Array.mapMaybe (synOf mn) decls
  synOf mn = case _ of
    EDTypeSynonym (ProperName name) [] body -> Just (Tuple (mn <> "." <> name) body)
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

-- | Each effectful foreign signature (`MEffect` result) → its value-parameter count. Used by
-- | generalized effect reflection (ADR 0019): a host foreign applied to exactly this many
-- | arguments is a complete `Effect` value, so it is reflected to a thunk.
effectfulForeignAritiesFromSigs :: Object ForeignSig -> Map String Int
effectfulForeignAritiesFromSigs sigs = Map.fromFoldable (Array.mapMaybe pick (Object.toUnfoldable sigs))
  where
  pick (Tuple key sig) = case sig.result of
    MEffect _ -> Just (Tuple key (Array.length sig.params))
    _ -> Nothing

effectfulForeignAritiesFromExterns :: Array ExternsFile -> Map String Int
effectfulForeignAritiesFromExterns = effectfulForeignAritiesFromSigs <<< foreignSigs

-- | The marshal kind of each parameter of a foreign's type, in order. `forall`
-- | quantifiers are transparent (a foreign may be polymorphic, e.g. `forall a. a ->
-- | a`); each function arrow contributes its argument's kind. (Constraints need no
-- | handling: purs rejects them on `foreign import`s.)
foreignParams :: forall a. Map String T.SourceType -> T.Type a -> Array MarshalKind
foreignParams syns = case _ of
  T.ForAll _ _ _ _ t _ -> foreignParams syns t
  T.TypeApp _ (T.TypeApp _ (T.TypeConstructor _ fn) arg) rest
    | isFunction fn -> Array.cons (marshalKind syns arg) (foreignParams syns rest)
  _ -> []

-- | The marshal kind of a foreign's result — the type left after the `forall`
-- | quantifiers and argument arrows.
foreignResult :: forall a. Map String T.SourceType -> T.Type a -> MarshalKind
foreignResult syns = case _ of
  T.ForAll _ _ _ _ t _ -> foreignResult syns t
  T.TypeApp _ (T.TypeApp _ (T.TypeConstructor _ fn) _) rest
    | isFunction fn -> foreignResult syns rest
  t -> marshalKind syns t

-- | The FFI marshal kind of a concrete type at the boundary: scalars cross as a JS
-- | `number` (`MI32`/`MF64`), `Boolean` to/from a JS `boolean` (`MBool`), `String`
-- | to/from a JS `string` (`MStr`), `Array a` to/from a JS array (`MArray`, recursing
-- | on the element), `Record` to/from a JS object (`MRecord`), a function `a -> b`
-- | to/from a JS function (`MFunc`, recursing on both sides), everything else opaque
-- | (`MOpaque`).
marshalKind :: forall a. Map String T.SourceType -> T.Type a -> MarshalKind
marshalKind syns = case _ of
  T.TypeApp _ (T.TypeApp _ (T.TypeConstructor _ fn) arg) rest
    | isFunction fn -> MFunc (marshalKind syns arg) (marshalKind syns rest)
  T.TypeApp _ (T.TypeConstructor _ ctor) arg
    | named "Array" ctor -> MArray (marshalKind syns arg)
    | named "Record" ctor -> MRecord (rowFields syns arg)
    -- `Effect a`: an effectful foreign — the JS glue runs its thunk and marshals the
    -- inner result `a` (ADR 0015). (`EffectFnN` is future work.)
    | named "Effect" ctor -> MEffect (marshalKind syns arg)
  T.TypeConstructor _ q@(Qualified _ (ProperName n))
    | n == "Int" || n == "Char" -> MI32
    | n == "Number" -> MF64
    | n == "Boolean" -> MBool
    | n == "String" -> MStr
    -- a nullary type synonym (`type Point = { … }`) is stored unexpanded; resolve it and recurse so
    -- aliases marshal by their real type rather than falling to `MOpaque`.
    | otherwise -> case synKey q >>= flip Map.lookup syns of
        Just body -> marshalKind syns body
        Nothing -> MOpaque
  _ -> MOpaque

named :: String -> Qualified ProperName -> Boolean
named n = case _ of
  Qualified _ (ProperName m) -> m == n

-- | The qualified-name key (`Module.Name`) of a module-qualified type constructor, for synonym
-- | lookup; `Nothing` for an unqualified/local constructor (not a cross-module synonym reference).
synKey :: Qualified ProperName -> Maybe String
synKey = case _ of
  Qualified (ByModuleName (ModuleName mn)) (ProperName n) -> Just (mn <> "." <> n)
  _ -> Nothing

-- | The fields of a record's row type `( l :: T, … )`, encoded as nested `RCons`
-- | terminated by `REmpty` (an open row's tail var is ignored).
rowFields :: forall a. Map String T.SourceType -> T.Type a -> Array (Tuple String MarshalKind)
rowFields syns = case _ of
  T.RCons _ (T.Label pss) ty rest -> Array.cons (Tuple (toString pss) (marshalKind syns ty)) (rowFields syns rest)
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
