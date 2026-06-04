-- | Reconstruct foreign signatures from `.purs` **source** (ADR 0016). A foreign's type
-- | lives only in the source — externs carry just the *exported* declarations, so a
-- | private `*Impl` foreign (the common `fromNumber = fromNumberImpl Just Nothing` idiom)
-- | has no externs signature. Parsing the source with `language-cst-parser` recovers it.
-- |
-- | This is a pure pass: `parseForeignSigs` maps one module's source text to the
-- | `ForeignSig`s of its `foreign import` *value* declarations (skipping `foreign import
-- | data`/kind), keyed `Module.ident`, with the same `MarshalKind`s the externs path uses
-- | — only the syntax tree differs (`CST.Types.Type` here vs externs `T.Type`).
-- |
-- | `CST.Types` is imported qualified because its `Type`/`Row` data types would otherwise
-- | shadow `Prim`'s `Type`/`Row` kinds (in scope via `Prelude`).
module PureScript.Backend.Wasm.SourceForeigns
  ( parseForeignSigs
  ) where

import Prelude

import Data.Array (cons)
import Data.Array as Array
import Data.Array.NonEmpty as NEA
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..), snd)
import Foreign.Object (Object)
import Foreign.Object as Object
import PureScript.Backend.Wasm.Externs (ForeignSig)
import PureScript.Backend.Wasm.Lower.IR (MarshalKind(..))
import PureScript.CST (RecoveredParserResult(..), parseModule)
import PureScript.CST.Types as CST

-- | The `ForeignSig`s of a source module's `foreign import` value declarations, keyed by
-- | qualified name. A parse failure (or a module with no foreigns) yields the empty map.
parseForeignSigs :: String -> Object ForeignSig
parseForeignSigs src = case parseModule src of
  ParseSucceeded m -> Object.fromFoldable (extract m)
  ParseSucceededWithErrors m _ -> Object.fromFoldable (extract m)
  ParseFailed _ -> Object.empty

extract :: forall e. CST.Module e -> Array (Tuple String ForeignSig)
extract (CST.Module { header: CST.ModuleHeader { name: CST.Name { name: CST.ModuleName mn } }, body: CST.ModuleBody { decls } }) =
  Array.mapMaybe (foreignOf mn) decls

foreignOf :: forall e. String -> CST.Declaration e -> Maybe (Tuple String ForeignSig)
foreignOf mn = case _ of
  CST.DeclForeign _ _ (CST.ForeignValue (CST.Labeled { label: CST.Name { name: CST.Ident ident }, value: ty })) ->
    Just (Tuple (mn <> "." <> ident) { moduleName: mn, base: ident, params: cstParams ty, result: cstResult ty })
  _ -> Nothing

-- | The marshal kinds of a foreign type's parameters, in order (peeling `forall` /
-- | constraint / outer parens, then splitting on each top-level `->`).
cstParams :: forall e. CST.Type e -> Array MarshalKind
cstParams = case _ of
  CST.TypeForall _ _ _ t -> cstParams t
  CST.TypeConstrained _ _ t -> cstParams t
  CST.TypeParens (CST.Wrapped { value }) -> cstParams value
  CST.TypeArrow a _ rest -> cons (cstKind a) (cstParams rest)
  _ -> []

-- | The marshal kind of a foreign type's result (the type after the last arrow).
cstResult :: forall e. CST.Type e -> MarshalKind
cstResult = case _ of
  CST.TypeForall _ _ _ t -> cstResult t
  CST.TypeConstrained _ _ t -> cstResult t
  CST.TypeParens (CST.Wrapped { value }) -> cstResult value
  CST.TypeArrow _ _ rest -> cstResult rest
  t -> cstKind t

-- | The FFI marshal kind of a concrete CST type — mirrors `Externs.marshalKind`.
cstKind :: forall e. CST.Type e -> MarshalKind
cstKind = case _ of
  CST.TypeParens (CST.Wrapped { value }) -> cstKind value
  CST.TypeForall _ _ _ t -> cstKind t
  CST.TypeConstrained _ _ t -> cstKind t
  CST.TypeArrow a _ b -> MFunc (cstKind a) (cstKind b)
  CST.TypeRecord (CST.Wrapped { value: row }) -> MRecord (rowFields row)
  CST.TypeApp (CST.TypeConstructor q) args ->
    let
      arg = NEA.head args
    in
      if named "Array" q then MArray (cstKind arg)
      else if named "Effect" q then MEffect (cstKind arg)
      else if named "Record" q then case arg of
        CST.TypeRow (CST.Wrapped { value: row }) -> MRecord (rowFields row)
        _ -> MOpaque
      else MOpaque
  CST.TypeConstructor q -> scalarKind q
  _ -> MOpaque

scalarKind :: CST.QualifiedName CST.Proper -> MarshalKind
scalarKind (CST.QualifiedName { name: CST.Proper n })
  | n == "Int" || n == "Char" = MI32
  | n == "Number" = MF64
  | n == "Boolean" = MBool
  | n == "String" = MStr
  | otherwise = MOpaque

named :: String -> CST.QualifiedName CST.Proper -> Boolean
named n (CST.QualifiedName { name: CST.Proper p }) = p == n

-- | The fields of a record's row (`{ l :: T, … }`), in order; an open row's tail is ignored.
rowFields :: forall e. CST.Row e -> Array (Tuple String MarshalKind)
rowFields (CST.Row { labels }) = case labels of
  Nothing -> []
  Just (CST.Separated sep) -> map fieldOf (cons sep.head (map snd sep.tail))
  where
  fieldOf (CST.Labeled { label: CST.Name { name: CST.Label l }, value: ty }) = Tuple l (cstKind ty)
