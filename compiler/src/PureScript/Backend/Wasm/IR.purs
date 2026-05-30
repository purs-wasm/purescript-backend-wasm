-- | The backend intermediate representation: a thin, A-normal-form layer
-- | between CoreFn and Binaryen. See `docs/design-decisions/0003-intermediate-ir.md`
-- | for the rationale.
-- |
-- | This module starts at the **Slice 0** subset — the scalar `Int`-only world:
-- | top-level functions, saturated calls, integer literals, and inlined machine
-- | ops. It is deliberately minimal; later slices extend it where the lowering
-- | and code generator prove a need, rather than speculatively up front. Each
-- | place a later slice will grow is marked with a `Slice N:` note so the
-- | intended shape is visible without committing code to it yet.
module PureScript.Backend.Wasm.IR where

import Prelude

import Data.Generic.Rep (class Generic)
import Data.Maybe (Maybe)
import Data.Show.Generic (genericShow)

-- | The wasm-level representation chosen for a value.
-- |
-- | Why this exists: CoreFn is type-erased, but the code generator must commit
-- | to concrete wasm types. Instead of reconstructing PureScript types, we carry
-- | the representation we *chose* (per ADR 0001) on each binder and let codegen
-- | switch on it. Slice 0 only ever produces `I32`; `F64`/`Boxed` are declared
-- | now so the type is stable once later slices begin emitting them.
data Rep
  = I32 -- Int (and, in monomorphic positions later, Char / Boolean)
  | F64 -- Number
  | Boxed -- the universal `eqref` box of ADR 0001 (Slice 1+)

derive instance eqRep :: Eq Rep
derive instance genericRep :: Generic Rep _
instance showRep :: Show Rep where
  show = genericShow

-- | A local slot: a dense 0-based index into the enclosing function's wasm
-- | locals (parameters occupy the first slots, then `Let`-bound temporaries).
-- |
-- | Why integer slots rather than names: CoreFn identifies locals by textual
-- | `Ident`, but wasm addresses locals by index. Resolving names to slots once,
-- | during lowering, makes codegen a direct `local.get <slot>` with no
-- | environment lookup at emission time.
newtype Slot = Slot Int

derive instance eqSlot :: Eq Slot
derive instance ordSlot :: Ord Slot
instance showSlot :: Show Slot where
  show (Slot n) = "(Slot " <> show n <> ")"

-- | A variable reference that may appear inside an `Atom`.
-- |
-- | Slice 0 only needs `Local`; the constructors a later slice adds are noted
-- | rather than declared, to keep pattern matches in the lowering/codegen total
-- | over exactly what exists today.
data VarRef = Local Slot

-- Slice 1: | Global FuncName  -- reference to a top-level value
-- Slice 2: | EnvField Int     -- a captured free variable, read from the closure env

derive instance eqVarRef :: Eq VarRef
derive instance genericVarRef :: Generic VarRef _
instance showVarRef :: Show VarRef where
  show = genericShow

-- | Atoms are *trivial* operands: evaluating one allocates nothing and imposes
-- | no ordering. A-normal form guarantees every operand/argument is an `Atom`,
-- | so the code generator never has to sequence nested computations — that is
-- | entirely the job of `Let` (below).
data Atom
  = ALitInt Int
  | AVar VarRef

-- Slice with each literal kind: ALitNumber / ALitChar / ALitString / ALitBoolean

derive instance eqAtom :: Eq Atom
derive instance genericAtom :: Generic Atom _
instance showAtom :: Show Atom where
  show = genericShow

-- | The inlined machine ops (ADR 0002, tier 1).
-- |
-- | Why a closed enum keyed by operation rather than by CoreFn name: it
-- | decouples the IR from the foreign *identifiers* a given Prelude version
-- | uses. The lowering owns the mapping from a foreign `Qualified Ident` to one
-- | of these; codegen owns the mapping from these to Binaryen instructions.
data Intrinsic
  = IntAdd
  | IntSub
  | IntMul

derive instance eqIntrinsic :: Eq Intrinsic
derive instance genericIntrinsic :: Generic Intrinsic _
instance showIntrinsic :: Show Intrinsic where
  show = genericShow

-- | The name of a top-level function, as it will be known to codegen and to
-- | `RCallKnown`. Lowering derives these from CoreFn module + identifier.
newtype FuncName = FuncName String

derive instance eqFuncName :: Eq FuncName
derive instance ordFuncName :: Ord FuncName
instance showFuncName :: Show FuncName where
  show (FuncName n) = "(FuncName " <> show n <> ")"

-- | Right-hand sides: the only nodes that compute or call. Each is the bound
-- | expression of a `Let`, which is exactly what makes evaluation order explicit
-- | in ANF — the operands are already-evaluated `Atom`s, and the `Rhs` is the
-- | single step performed before binding its result.
data Rhs
  = RAtom Atom
  | RPrim Intrinsic (Array Atom) -- inlined machine op over evaluated operands
  | RCallKnown FuncName (Array Atom) -- saturated direct call to a top-level function (ADR 0003 eval/apply)
  -- | Allocate an ADT value: constructor `tag` plus its field initializers in
  -- | field order. Operands are `eqref` (ADR 0004); a nullary constructor has an
  -- | empty operand list. Lowered to `struct.new $ADT [tag, array.new_fixed
  -- | $Vals fields]`.
  | RMkData Int (Array Atom)
  -- | Project field `index` out of an ADT value (itself an `eqref`), yielding
  -- | the field's `eqref`. Lowered to a cast to `(ref $ADT)`, a `struct.get` of
  -- | the fields array, then `array.get`.
  | RProjField Atom Int

-- Slice 2: | RApply Atom (Array Atom)      -- generic curried apply (arity mismatch)
--          | RMkClosure FuncName (Array Atom)
-- Slice 3: | RMkRecord (Array (Tuple String Atom)) | RProjLabel Atom String
-- where needed: | RBox Rep Atom | RUnbox Rep Atom

derive instance genericRhs :: Generic Rhs _
instance showRhs :: Show Rhs where
  show = genericShow

-- | An A-normal-form block: a chain of `Let` bindings ending in a tail `Ret`.
-- | Every intermediate result is named by a `Slot`, mapping 1:1 onto a wasm
-- | local. The `Rep` on each `Let` is the representation of the bound slot, so
-- | codegen can declare the local's wasm type without consulting anything else.
data Block
  = Ret Atom
  | Let Slot Rep Rhs Block
  -- | A compiled pattern match: read the scrutinee ADT's constructor tag and
  -- | branch on it. Field bindings live inside each branch body as `RProjField`
  -- | `Let`s. The optional default block is taken when no tag matches; a
  -- | non-exhaustive match with no default traps (`unreachable`).
  | Switch Atom (Array Branch) (Maybe Block)

-- Slice 2: | LetRec (Array (Tuple Slot Alloc)) Block   -- allocate-then-patch knot-tying

-- | One arm of a `Switch`: the constructor `tag` it matches, and the block to
-- | run when the scrutinee has that tag.
data Branch = Branch Int Block

instance showBranch :: Show Branch where
  show (Branch tag body) = "(Branch " <> show tag <> " " <> show body <> ")"

instance showBlock :: Show Block where
  show = case _ of
    Ret a -> "(Ret " <> show a <> ")"
    Let s r rhs k -> "(Let " <> show s <> " " <> show r <> " " <> show rhs <> " " <> show k <> ")"
    Switch scrut branches dflt -> "(Switch " <> show scrut <> " " <> show branches <> " " <> show dflt <> ")"

-- | A top-level function. `params` carries both the arity (its length) and the
-- | representation of each parameter; parameters occupy slots
-- | `0 .. length params - 1`, and `Let` bindings in `body` take the slots after
-- | them. `export` is the external name when the function is exported from the
-- | module (Slice 0's observable surface is exported functions called by the
-- | host).
type IRFunc =
  { name :: FuncName
  , params :: Array Rep
  , result :: Rep
  , body :: Block
  , export :: Maybe String
  -- | Total local slots (parameters plus every `Let`-bound temporary, including
  -- | those inside `Switch` branches). Codegen declares `localCount - |params|`
  -- | extra locals; lowering supplies it from its final fresh-slot counter.
  , localCount :: Int
  }

-- | A whole compiled module.
-- |
-- | Slice 0 is just functions. Slice 1 adds top-level value bindings (CAFs) in
-- | initialization order; ADR 0002's tier-2 runtime functions also live here
-- | once strings/arrays arrive.
type Program =
  { funcs :: Array IRFunc
  }
