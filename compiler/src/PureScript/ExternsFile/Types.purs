module PureScript.ExternsFile.Types where

import Prelude
import Prim hiding (Type, Constraint)

import Data.Foldable (class Foldable)
import Data.Generic.Rep (class Generic)
import Data.Maybe (Maybe)
import Data.Newtype (class Newtype)
import Data.Show.Generic (genericShow)
import Data.Traversable (class Traversable)
import Data.Tuple.Nested (type (/\), (/\))
import PureScript.ExternsFile.Decoder.Class (class Decode, decoder)
import PureScript.ExternsFile.Decoder.Generic (genericDecoder)
import PureScript.ExternsFile.Decoder.Monad (Decoder(..), runDecoder)
import PureScript.ExternsFile.Decoder.Newtype (newtypeDecoder)
import PureScript.ExternsFile.Decoder.Utils (readAt)
import PureScript.ExternsFile.Names (OpName, ProperName, Qualified)
import PureScript.ExternsFile.PSString (PSString, toString)
import PureScript.ExternsFile.SourcePos (SourceAnn, SourcePos)

newtype SkolemScope = SkolemScope Int

derive instance eqSkolemScope :: Eq SkolemScope
derive instance ordSkolemScope :: Ord SkolemScope
derive instance newtypeSkolemScope :: Newtype SkolemScope _

instance showSkolemScope :: Show SkolemScope where
  show (SkolemScope s) = "(SkolemScope " <> show s <> ")"

instance decodeSkolemScope :: Decode SkolemScope where
  decoder = newtypeDecoder

data WildcardData
  = HoleWildcard String
  | UnnamedWildcard
  | IgnoredWildcard

derive instance eqWildcardData :: Eq WildcardData
derive instance ordWildcardData :: Ord WildcardData
derive instance genericWildcardData :: Generic WildcardData _
instance showWildcardData :: Show WildcardData where
  show = genericShow

instance decodeWildcardData :: Decode WildcardData where
  decoder = genericDecoder

data TypeVarVisibility
  = TypeVarVisible
  | TypeVarInvisible

derive instance eqTypeVarVisibility :: Eq TypeVarVisibility
derive instance ordTypeVarVisibility :: Ord TypeVarVisibility
derive instance genericTypeVarVisibility :: Generic TypeVarVisibility _
instance showTypeVarVisibility :: Show TypeVarVisibility where
  show = genericShow

instance decodeTypeVarVisibility :: Decode TypeVarVisibility where
  decoder = genericDecoder

data ConstraintData = PartialConstraintData (Array (Array String)) Boolean

derive instance eqConstraintData :: Eq ConstraintData
derive instance ordConstraintData :: Ord ConstraintData
derive instance genericConstraintData :: Generic ConstraintData _
instance showConstraintData :: Show ConstraintData where
  show = genericShow

instance decodeConstraintData :: Decode ConstraintData where
  decoder = genericDecoder

data Constraint a = Constraint
  a
  (Qualified ProperName)
  (Array (Type a))
  (Array (Type a))
  (Maybe ConstraintData)

derive instance functorConstraint :: Functor Constraint
derive instance foldableConstraint :: Foldable Constraint
derive instance traversableConstraint :: Traversable Constraint
derive instance genericConstraint :: Generic (Constraint a) _
instance showConstraint :: Show a => Show (Constraint a) where
  show = genericShow

instance decodeConstraint :: Decode a => Decode (Constraint a) where
  decoder = genericDecoder

type SourceType = Type SourceAnn

type SourceConstraint = Constraint SourceAnn

newtype Label = Label PSString

derive instance newtypeLabel :: Newtype Label _
derive newtype instance eqLabel :: Eq Label
derive newtype instance ordLabel :: Ord Label

instance showLabel :: Show Label where
  show (Label pss) = toString pss

instance decodeLabel :: Decode Label where
  decoder = newtypeDecoder

data Type a
  = TUnknown a Int
  | TypeVar a String
  | TypeLevelString a PSString
  | TypeLevelInt a Int
  | TypeWildcard a WildcardData
  | TypeConstructor a (Qualified ProperName)
  | TypeOp a (Qualified OpName)
  | TypeApp a (Type a) (Type a)
  | KindApp a (Type a) (Type a)
  | ForAll a TypeVarVisibility String (Maybe (Type a)) (Type a) (Maybe SkolemScope)
  | ConstrainedType a (Constraint a) (Type a)
  | Skolem a String (Maybe (Type a)) Int SkolemScope
  | REmpty a
  | RCons a Label (Type a) (Type a)
  | KindedType a (Type a) (Type a)
  | BinaryNoParensType a (Type a) (Type a) (Type a)
  | ParensInType a (Type a)

derive instance functorType :: Functor Type
derive instance foldableType :: Foldable Type
derive instance traversableType :: Traversable Type
derive instance genericType :: Generic (Type a) _
instance showType :: Show a => Show (Type a) where
  show typ = genericShow typ

instance decodeType :: Decode a => Decode (Type a) where
  decoder = Decoder \fgn -> runDecoder (genericDecoder @(Type a)) fgn

data Role
  = Nominal
  | Representational
  | Phantom

derive instance eqRole :: Eq Role
derive instance ordRole :: Ord Role
derive instance genericRole :: Generic Role _
instance showRole :: Show Role where
  show = genericShow

instance decodeRole :: Decode Role where
  decoder = genericDecoder

displayRole :: Role -> String
displayRole r = case r of
  Nominal -> "nominal"
  Representational -> "representational"
  Phantom -> "phantom"

-- | A type's type-argument with its declared kind and role, encoded as the
-- | flat 3-tuple `[name, kind, role]`.
newtype DataTypeArg = DataTypeArg
  { name :: String
  , kind :: Maybe SourceType
  , role :: Role
  }

derive instance newtypeDataTypeArg :: Newtype DataTypeArg _
derive instance genericDataTypeArg :: Generic DataTypeArg _
instance showDataTypeArg :: Show DataTypeArg where
  show = genericShow

instance decodeDataTypeArg :: Decode DataTypeArg where
  decoder = Decoder \fgn -> ado
    name <- readAt 0 fgn >>= runDecoder decoder
    kind <- readAt 1 fgn >>= runDecoder decoder
    role <- readAt 2 fgn >>= runDecoder decoder
    in DataTypeArg { name, kind, role }

data TypeKind
  = DataType
      DataDeclType
      (Array DataTypeArg)
      (Array (ProperName /\ Array SourceType))
  | TypeSynonym
  | ExternData (Array Role)
  | LocalTypeVariable
  | ScopedTypeVar

derive instance genericTypeKind :: Generic TypeKind _
instance showTypeKind :: Show TypeKind where
  show = genericShow

instance decodeTypeKind :: Decode TypeKind where
  decoder = genericDecoder

data DataDeclType
  = Data
  | Newtype

derive instance eqDataDeclType :: Eq DataDeclType
derive instance ordDataDeclType :: Ord DataDeclType
derive instance genericDataDeclType :: Generic DataDeclType _
instance showDataDeclType :: Show DataDeclType where
  show = genericShow

instance decodeDataDeclType :: Decode DataDeclType where
  decoder = genericDecoder

data FunctionalDependency = FunctionalDependency
  (Array Int) -- determiners
  (Array Int) -- determined

derive instance eqFunctionalDependency :: Eq FunctionalDependency
derive instance ordFunctionalDependency :: Ord FunctionalDependency
derive instance genericFunctionalDependency :: Generic FunctionalDependency _
instance showFunctionalDependency :: Show FunctionalDependency where
  show = genericShow

instance decodeFunctionalDependency :: Decode FunctionalDependency where
  decoder = genericDecoder

newtype ChainId = ChainId (String /\ SourcePos)

derive instance eqChainId :: Eq ChainId
derive instance ordChainId :: Ord ChainId
derive instance newtypeChainId :: Newtype ChainId _
instance showChainId :: Show ChainId where
  show (ChainId cid) = "(ChainId " <> show cid <> ")"

instance decodeChainId :: Decode ChainId where
  decoder = ChainId <$> decoder

mkChainId :: String -> SourcePos -> ChainId
mkChainId fileName startingSourcePos = ChainId (fileName /\ startingSourcePos)
