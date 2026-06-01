-- | The PureScript CoreFn AST, mirroring the JSON emitted by
-- | `purs compile --codegen corefn` (verified against compiler 0.15.16).
-- |
-- | This is the functional-core IR the backend consumes: desugared, fully
-- | qualified, but not yet optimized. Source positions are kept only where the
-- | backend needs them; local-variable provenance (`sourcePos`) is dropped.
module PureScript.CoreFn where

import Prelude

import Data.Either (Either)
import Data.Filterable (maybeBool)
import Data.Generic.Rep (class Generic)
import Data.Maybe (Maybe)
import Data.Show.Generic (genericShow)
import Data.String (Pattern(..))
import Data.String as Str
import Data.String.Regex as Re
import Data.String.Regex.Flags (unicode)
import Data.String.Regex.Unsafe (unsafeRegex)
import Data.Traversable (traverse)
import Data.Tuple (Tuple)
import Foreign.Object (Object)

-- | A module name as its dot-separated parts, e.g. `["Data", "Maybe"]`.
type ModuleName = Array String

toModuleName :: String -> Maybe ModuleName
toModuleName = Str.split (Pattern ".") >>> traverse (maybeBool (Re.test moduleNamePartRegex))
  where
  moduleNamePartRegex = unsafeRegex """[A-Z][a-zA-Z0-9_]*""" unicode

-- | An identifier (value-level name).
type Ident = String

-- | A constructor or type name (`ProperName` in the compiler).
type ProperName = String

-- | A name that is either qualified by the module it came from
-- | (`Just`), or local to the current scope (`Nothing`).
data Qualified a = Qualified (Maybe ModuleName) a

derive instance genericQualified :: Generic (Qualified a) _
derive instance eqQualified :: Eq a => Eq (Qualified a)
instance showQualified :: Show a => Show (Qualified a) where
  show q = genericShow q

-- | A 1-based source position `{ line, column }`.
type SourcePos = { line :: Int, column :: Int }

-- | A source span. Synthetic nodes use `{ start: {0,0}, end: {0,0} }`.
type SourceSpan = { start :: SourcePos, end :: SourcePos }

-- | Whether a data constructor belongs to a single-constructor (product) or
-- | multi-constructor (sum) type.
data ConstructorType = ProductType | SumType

derive instance genericConstructorType :: Generic ConstructorType _
derive instance eqConstructorType :: Eq ConstructorType
instance showConstructorType :: Show ConstructorType where
  show = genericShow

-- | Compiler-attached metadata on a node, guiding code generation.
data Meta
  = IsConstructor ConstructorType (Array Ident)
  | IsNewtype
  | IsTypeClassConstructor
  | IsForeign
  | IsWhere
  | IsSyntheticApp

derive instance genericMeta :: Generic Meta _
derive instance eqMeta :: Eq Meta
instance showMeta :: Show Meta where
  show = genericShow

-- | Per-node annotation: where it came from and any compiler metadata.
type Ann = { span :: SourceSpan, meta :: Maybe Meta }

-- | A literal value. Polymorphic in `a` because the same shapes appear in both
-- | expression literals (`a = Expr`) and pattern literals (`a = Binder`).
data Literal a
  = LitInt Int
  | LitNumber Number
  | LitString String
  | LitChar Char
  | LitBoolean Boolean
  | LitArray (Array a)
  | LitObject (Array (Tuple String a))

derive instance genericLiteral :: Generic (Literal a) _
derive instance eqLiteral :: Eq a => Eq (Literal a)
instance showLiteral :: Show a => Show (Literal a) where
  show l = genericShow l

-- | A CoreFn expression.
data Expr
  = Literal Ann (Literal Expr)
  -- | `Constructor ann typeName constructorName fieldNames`
  | Constructor Ann ProperName ProperName (Array Ident)
  -- | `Accessor ann fieldName record`
  | Accessor Ann String Expr
  -- | `ObjectUpdate ann record copyFields updates`; `copyFields` is the
  -- | `Just` list of untouched labels for a polymorphic record update.
  | ObjectUpdate Ann Expr (Maybe (Array String)) (Array (Tuple String Expr))
  -- | `Abs ann argument body`
  | Abs Ann Ident Expr
  -- | `App ann abstraction argument`
  | App Ann Expr Expr
  | Var Ann (Qualified Ident)
  -- | `Case ann scrutinees alternatives`
  | Case Ann (Array Expr) (Array CaseAlternative)
  -- | `Let ann bindings body`
  | Let Ann (Array Bind) Expr

derive instance genericExpr :: Generic Expr _
derive instance eqExpr :: Eq Expr
instance showExpr :: Show Expr where
  show e = genericShow e

-- | A binding group: a single non-recursive binding or a set of mutually
-- | recursive ones.
data Bind
  = NonRec Ann Ident Expr
  | Rec (Array RecBinding)

derive instance genericBind :: Generic Bind _
derive instance eqBind :: Eq Bind
instance showBind :: Show Bind where
  show b = genericShow b

-- | One binding within a recursive group.
type RecBinding = { ann :: Ann, ident :: Ident, expr :: Expr }

-- | A guarded result: the guard expression and the value it produces.
type Guard = { guard :: Expr, expression :: Expr }

-- | A `case` alternative: a row of binders and either a single unguarded
-- | result (`Right`) or a list of guarded results (`Left`).
type CaseAlternative =
  { binders :: Array Binder
  , result :: Either (Array Guard) Expr
  }

-- | A pattern binder.
data Binder
  = NullBinder Ann
  | LiteralBinder Ann (Literal Binder)
  | VarBinder Ann Ident
  -- | `ConstructorBinder ann typeName constructorName subBinders`
  | ConstructorBinder Ann (Qualified ProperName) (Qualified ProperName) (Array Binder)
  -- | `NamedBinder ann name binder` — an as-pattern (`name@binder`).
  | NamedBinder Ann Ident Binder

derive instance genericBinder :: Generic Binder _
derive instance eqBinder :: Eq Binder
instance showBinder :: Show Binder where
  show b = genericShow b

-- | An imported module reference.
type Import = { ann :: Ann, moduleName :: ModuleName }

-- | A decoded CoreFn module.
type Module =
  { name :: ModuleName
  , path :: String
  , builtWith :: String
  , imports :: Array Import
  , exports :: Array Ident
  , reExports :: Object (Array Ident)
  , foreignNames :: Array Ident
  , decls :: Array Bind
  }
