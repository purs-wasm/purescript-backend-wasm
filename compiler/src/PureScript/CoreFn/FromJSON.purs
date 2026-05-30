-- | Decode the JSON produced by `purs compile --codegen corefn` into the
-- | `PureScript.CoreFn` AST. Verified against compiler 0.15.16 output.
module PureScript.CoreFn.FromJSON
  ( decodeModule
  , decodeExpr
  , decodeBinder
  , decodeBind
  ) where

import Prelude

import Data.Argonaut.Core (Json, isNull, toArray, toObject)
import Data.Argonaut.Decode (JsonDecodeError(..), decodeJson, (.:), (.:?))
import Data.Either (Either(..), note)
import Data.Maybe (Maybe(..))
import Data.String.CodeUnits (charAt)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Foreign.Object (Object)
import PureScript.CoreFn (Ann, Bind(..), Binder(..), CaseAlternative, ConstructorType(..), Expr(..), Guard, Literal(..), Meta(..), Module, Qualified(..), RecBinding, SourcePos, SourceSpan)

-- | Decode a full CoreFn module.
decodeModule :: Json -> Either JsonDecodeError Module
decodeModule json = do
  o <- objectOf json
  name <- o .: "moduleName"
  path <- o .: "modulePath"
  builtWith <- o .: "builtWith"
  imports <- arrayOf decodeImport =<< o .: "imports"
  exports <- o .: "exports"
  reExports <- o .: "reExports" :: Either JsonDecodeError (Object (Array String))
  foreignNames <- o .: "foreign"
  decls <- arrayOf decodeBind =<< o .: "decls"
  pure { name, path, builtWith, imports, exports, reExports, foreignNames, decls }

decodeImport :: Json -> Either JsonDecodeError { ann :: Ann, moduleName :: Array String }
decodeImport json = do
  o <- objectOf json
  ann <- decodeAnn =<< o .: "annotation"
  moduleName <- o .: "moduleName"
  pure { ann, moduleName }

-- | Decode a binding group (`NonRec` / `Rec`).
decodeBind :: Json -> Either JsonDecodeError Bind
decodeBind json = do
  o <- objectOf json
  bindType <- o .: "bindType"
  case bindType of
    "NonRec" -> NonRec <$> (decodeAnn =<< o .: "annotation") <*> o .: "identifier" <*> (decodeExpr =<< o .: "expression")
    "Rec" -> Rec <$> (arrayOf decodeRecBinding =<< o .: "binds")
    other -> Left (Named ("unknown bindType " <> show other) MissingValue)

decodeRecBinding :: Json -> Either JsonDecodeError RecBinding
decodeRecBinding json = do
  o <- objectOf json
  ann <- decodeAnn =<< o .: "annotation"
  ident <- o .: "identifier"
  expr <- decodeExpr =<< o .: "expression"
  pure { ann, ident, expr }

-- | Decode an expression.
decodeExpr :: Json -> Either JsonDecodeError Expr
decodeExpr json = do
  o <- objectOf json
  ann <- decodeAnn =<< o .: "annotation"
  exprType <- o .: "type"
  case exprType of
    "Literal" ->
      Literal ann <$> (decodeLiteral decodeExpr =<< o .: "value")
    "Constructor" ->
      Constructor ann <$> o .: "typeName" <*> o .: "constructorName" <*> o .: "fieldNames"
    "Accessor" ->
      Accessor ann <$> o .: "fieldName" <*> (decodeExpr =<< o .: "expression")
    "ObjectUpdate" ->
      ObjectUpdate ann
        <$> (decodeExpr =<< o .: "expression")
        <*> o .:? "copy"
        <*> (arrayOf decodeAssoc =<< o .: "updates")
    "Abs" ->
      Abs ann <$> o .: "argument" <*> (decodeExpr =<< o .: "body")
    "App" ->
      App ann <$> (decodeExpr =<< o .: "abstraction") <*> (decodeExpr =<< o .: "argument")
    "Var" ->
      Var ann <$> (decodeQualified =<< o .: "value")
    "Case" ->
      Case ann
        <$> (arrayOf decodeExpr =<< o .: "caseExpressions")
        <*> (arrayOf decodeCaseAlternative =<< o .: "caseAlternatives")
    "Let" ->
      Let ann
        <$> (arrayOf decodeBind =<< o .: "binds")
        <*> (decodeExpr =<< o .: "expression")
    other -> Left (Named ("unknown expression type " <> show other) MissingValue)

decodeCaseAlternative :: Json -> Either JsonDecodeError CaseAlternative
decodeCaseAlternative json = do
  o <- objectOf json
  binders <- arrayOf decodeBinder =<< o .: "binders"
  isGuarded <- o .: "isGuarded"
  result <-
    if isGuarded then Left <$> (arrayOf decodeGuard =<< o .: "expressions")
    else Right <$> (decodeExpr =<< o .: "expression")
  pure { binders, result }

decodeGuard :: Json -> Either JsonDecodeError Guard
decodeGuard json = do
  o <- objectOf json
  guard <- decodeExpr =<< o .: "guard"
  expression <- decodeExpr =<< o .: "expression"
  pure { guard, expression }

-- | Decode a pattern binder.
decodeBinder :: Json -> Either JsonDecodeError Binder
decodeBinder json = do
  o <- objectOf json
  ann <- decodeAnn =<< o .: "annotation"
  binderType <- o .: "binderType"
  case binderType of
    "NullBinder" -> pure (NullBinder ann)
    "VarBinder" -> VarBinder ann <$> o .: "identifier"
    "LiteralBinder" -> LiteralBinder ann <$> (decodeLiteral decodeBinder =<< o .: "literal")
    "NamedBinder" -> NamedBinder ann <$> o .: "identifier" <*> (decodeBinder =<< o .: "binder")
    "ConstructorBinder" ->
      ConstructorBinder ann
        <$> (decodeQualified =<< o .: "typeName")
        <*> (decodeQualified =<< o .: "constructorName")
        <*> (arrayOf decodeBinder =<< o .: "binders")
    other -> Left (Named ("unknown binderType " <> show other) MissingValue)

-- | Decode a literal, given a decoder for its element type (`Expr` or
-- | `Binder`).
decodeLiteral :: forall a. (Json -> Either JsonDecodeError a) -> Json -> Either JsonDecodeError (Literal a)
decodeLiteral decodeElem json = do
  o <- objectOf json
  literalType <- o .: "literalType"
  case literalType of
    "IntLiteral" -> LitInt <$> o .: "value"
    "NumberLiteral" -> LitNumber <$> o .: "value"
    "StringLiteral" -> LitString <$> o .: "value"
    "BooleanLiteral" -> LitBoolean <$> o .: "value"
    "CharLiteral" -> do
      s <- o .: "value"
      LitChar <$> note (TypeMismatch "Char") (charAt 0 s)
    "ArrayLiteral" -> LitArray <$> (arrayOf decodeElem =<< o .: "value")
    "ObjectLiteral" -> LitObject <$> (arrayOf (decodeAssocWith decodeElem) =<< o .: "value")
    other -> Left (Named ("unknown literalType " <> show other) MissingValue)

-- | Decode a qualified name. `moduleName` present means imported; absent (a
-- | local `sourcePos` reference) means local to the current scope.
decodeQualified :: Json -> Either JsonDecodeError (Qualified String)
decodeQualified json = do
  o <- objectOf json
  moduleName <- o .:? "moduleName"
  identifier <- o .: "identifier"
  pure (Qualified moduleName identifier)

decodeAnn :: Json -> Either JsonDecodeError Ann
decodeAnn json = do
  o <- objectOf json
  span <- decodeSpan =<< o .: "sourceSpan"
  metaJson <- o .: "meta"
  meta <- if isNull metaJson then pure Nothing else Just <$> decodeMeta metaJson
  pure { span, meta }

decodeMeta :: Json -> Either JsonDecodeError Meta
decodeMeta json = do
  o <- objectOf json
  metaType <- o .: "metaType"
  case metaType of
    "IsConstructor" ->
      IsConstructor <$> (decodeConstructorType =<< o .: "constructorType") <*> o .: "identifiers"
    "IsNewtype" -> pure IsNewtype
    "IsTypeClassConstructor" -> pure IsTypeClassConstructor
    "IsForeign" -> pure IsForeign
    "IsWhere" -> pure IsWhere
    "IsSyntheticApp" -> pure IsSyntheticApp
    other -> Left (Named ("unknown metaType " <> show other) MissingValue)

decodeConstructorType :: String -> Either JsonDecodeError ConstructorType
decodeConstructorType = case _ of
  "ProductType" -> Right ProductType
  "SumType" -> Right SumType
  other -> Left (Named ("unknown constructorType " <> show other) MissingValue)

decodeSpan :: Json -> Either JsonDecodeError SourceSpan
decodeSpan json = do
  o <- objectOf json
  start <- decodePos =<< o .: "start"
  end <- decodePos =<< o .: "end"
  pure { start, end }

decodePos :: Json -> Either JsonDecodeError SourcePos
decodePos json = do
  pair <- note (TypeMismatch "Array") (toArray json) >>= traverse decodeInt
  case pair of
    [ line, column ] -> Right { line, column }
    _ -> Left (TypeMismatch "[line, column]")

decodeInt :: Json -> Either JsonDecodeError Int
decodeInt = decodeJson

-- | `[key, value]` association where the value is an expression.
decodeAssoc :: Json -> Either JsonDecodeError (Tuple String Expr)
decodeAssoc json = decodeAssocWith decodeExpr json

-- | `[key, value]` association decoded with a given value decoder.
decodeAssocWith :: forall a. (Json -> Either JsonDecodeError a) -> Json -> Either JsonDecodeError (Tuple String a)
decodeAssocWith decodeValue json = do
  pair <- note (TypeMismatch "Array") (toArray json)
  case pair of
    [ keyJson, valueJson ] -> Tuple <$> decodeJsonString keyJson <*> decodeValue valueJson
    _ -> Left (TypeMismatch "[key, value]")

-- --- small primitives ------------------------------------------------------

objectOf :: Json -> Either JsonDecodeError (Object Json)
objectOf = note (TypeMismatch "Object") <<< toObject

-- | Decode a JSON array, applying `decode` to each element.
arrayOf :: forall a. (Json -> Either JsonDecodeError a) -> Json -> Either JsonDecodeError (Array a)
arrayOf decode json = note (TypeMismatch "Array") (toArray json) >>= traverse decode

decodeJsonString :: Json -> Either JsonDecodeError String
decodeJsonString = decodeJson
