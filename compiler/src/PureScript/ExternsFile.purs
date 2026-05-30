module PureScript.ExternsFile
  ( Associativity(..)
  , ExternsDeclaration(..)
  , ExternsFile(..)
  , ExternsFixity(..)
  , ExternsImport(..)
  , ExternsTypeFixity(..)
  , Fixity(..)
  , ImportDeclarationType(..)
  , Precedence
  , identOfExternsDeclaration
  , module Ext
  ) where

import Prelude

import Data.Either (Either)
import Data.Generic.Rep (class Generic)
import Data.Maybe (Maybe)
import Data.Show.Generic (genericShow)
import Data.Tuple (Tuple)
import Data.Tuple.Nested (type (/\))
import PureScript.ExternsFile.Declarations (DeclarationRef(..)) as Ext
import PureScript.ExternsFile.Decoder.Class (class Decode)
import PureScript.ExternsFile.Decoder.Generic (genericDecoder)
import PureScript.ExternsFile.Names (Ident(..), ModuleName, NameSource, OpName, ProperName(..), Qualified)
import PureScript.ExternsFile.SourcePos (SourceSpan)
import PureScript.ExternsFile.Types (ChainId, DataDeclType, FunctionalDependency, SourceConstraint, SourceType, TypeKind)

data ExternsFile = ExternsFile
  String -- efVersion
  ModuleName -- efModuleName
  (Array Ext.DeclarationRef) -- efExports
  (Array ExternsImport) -- efImports
  (Array ExternsFixity) -- efFixities
  (Array ExternsTypeFixity) -- efTypeFixities
  (Array ExternsDeclaration) -- efDeclarations
  SourceSpan -- efSourceSpan

derive instance Generic ExternsFile _
instance Show ExternsFile where
  show = genericShow

instance Decode ExternsFile where
  decoder = genericDecoder

data ImportDeclarationType
  = Implicit
  | Explicit (Array Ext.DeclarationRef)
  | Hiding (Array Ext.DeclarationRef)

derive instance Eq ImportDeclarationType
derive instance Ord ImportDeclarationType
derive instance Generic ImportDeclarationType _
instance Show ImportDeclarationType where
  show = genericShow

instance Decode ImportDeclarationType where
  decoder = genericDecoder

data ExternsImport = ExternsImport
  ModuleName
  ImportDeclarationType
  (Maybe ModuleName)

derive instance Eq ExternsImport
derive instance Ord ExternsImport
derive instance Generic ExternsImport _
instance Show ExternsImport where
  show = genericShow

instance Decode ExternsImport where
  decoder = genericDecoder

type Precedence = Int

data Associativity
  = Infix
  | Infixl
  | Infixr

derive instance Eq Associativity
derive instance Ord Associativity
derive instance Generic Associativity _
instance Show Associativity where
  show = genericShow

instance Decode Associativity where
  decoder = genericDecoder

data Fixity = Fixity Associativity Precedence

derive instance Eq Fixity
derive instance Ord Fixity
derive instance Generic Fixity _
instance Show Fixity where
  show = genericShow

data ExternsFixity = ExternsFixity
  Associativity
  Precedence
  OpName
  (Qualified (Either Ident ProperName))

derive instance Eq ExternsFixity
derive instance Ord ExternsFixity
derive instance Generic ExternsFixity _
instance Show ExternsFixity where
  show = genericShow

instance Decode ExternsFixity where
  decoder = genericDecoder

data ExternsTypeFixity = ExternsTypeFixity Associativity Precedence OpName (Qualified ProperName)

derive instance Eq ExternsTypeFixity
derive instance Ord ExternsTypeFixity
derive instance Generic ExternsTypeFixity _
instance Show ExternsTypeFixity where
  show = genericShow

instance Decode ExternsTypeFixity where
  decoder = genericDecoder

data ExternsDeclaration
  = EDType
      ProperName -- edTypeName
      SourceType -- edTypeKind
      TypeKind -- edTypeDeclarationKind
  | EDTypeSynonym
      ProperName -- edTypeSynonymName
      (Array (String /\ Maybe SourceType)) -- edTypeSynonymArguments
      SourceType -- edTypeSynonymType
  | EDDataConstructor
      ProperName -- edDataCtorName
      DataDeclType -- edDataCtorOrigin
      ProperName -- edDataCtorTypeCtor
      SourceType -- edDataCtorType
      (Array Ident) -- edDataCtorFields
  | EDValue
      Ident -- edValueName
      SourceType -- edValueType
  | EDClass
      ProperName -- edClassName
      (Array (String /\ Maybe SourceType)) -- edClassTypeArguments
      (Array (Ident /\ SourceType)) -- edClassMembers
      (Array SourceConstraint) -- edClassConstraints
      (Array FunctionalDependency) -- edFunctionalDependencies
      Boolean -- edIsEmpty
  | EDInstance
      (Qualified ProperName) -- edInstanceClassName
      Ident -- edInstanceName
      (Array (Tuple String SourceType)) -- edInstanceForAll
      (Array SourceType) -- edInstanceKinds
      (Array SourceType) -- edInstanceTypes
      (Maybe (Array SourceConstraint)) -- edInstanceConstraints
      (Maybe ChainId) -- edInstanceChain
      Int -- edInstanceChainIndex
      NameSource -- edInstanceNameSource
      SourceSpan -- edInstanceSourceSpan

derive instance Generic ExternsDeclaration _
instance Show ExternsDeclaration where
  show = genericShow

instance Decode ExternsDeclaration where
  decoder = genericDecoder

identOfExternsDeclaration :: ExternsDeclaration -> Ident
identOfExternsDeclaration = case _ of
  EDType pn _ _ -> properNameIdent pn
  EDTypeSynonym pn _ _ -> properNameIdent pn
  EDDataConstructor pn _ _ _ _ -> properNameIdent pn
  EDClass pn _ _ _ _ _ -> properNameIdent pn
  EDInstance _ ident _ _ _ _ _ _ _ _ -> ident
  EDValue ident _ -> ident
  where
  properNameIdent (ProperName ident) = Ident ident
