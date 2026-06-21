-- | The backend intermediate representation: a thin, A-normal-form layer
-- | between CoreFn and Binaryen. See `docs/design-decisions/0003-intermediate-ir.md`
-- | for the rationale.
module PureScript.Backend.Wasm.Lower.IR where

import Prelude

import Data.Argonaut.Core (Json)
import Data.Argonaut.Core as J
import Data.Generic.Rep (class Generic)
import Data.Maybe (Maybe)
import Data.Show.Generic (genericShow)
import Data.Tuple (Tuple(..))
import Foreign.Object (Object)
import Foreign.Object as Object
import PureScript.Backend.Wasm.Intrinsics (Intrinsic)

-- | The wasm-level representation chosen for a value.
-- | CoreFn is type-erased, but the code generator must commit to concrete wasm types. 
-- | Instead of reconstructing PureScript types, we carry the representation we *chose* 
-- | on each binder and let codegen switch on it.
data Rep
  = I32 -- Int, Char, Boolean
  | I64 -- Int64
  | F64 -- Number
  | Boxed -- the universal `eqref` box
  | CloRef -- (ref $Clo): the closure parameter of a lifted code function

derive instance eqRep :: Eq Rep
derive instance ordRep :: Ord Rep
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

-- | A variable reference that may appear inside an `Atom`: a local slot, or — in
-- | a lifted code function — a free variable captured in the enclosing closure's
-- | environment array (read by index).
data VarRef
  = Local Slot
  | EnvField Int

derive instance eqVarRef :: Eq VarRef
derive instance genericVarRef :: Generic VarRef _
instance showVarRef :: Show VarRef where
  show = genericShow

-- | Atoms are *trivial* operands: evaluating one allocates nothing and imposes
-- | no ordering. A-normal form guarantees every operand/argument is an `Atom`,
-- | so the code generator never has to sequence nested computations — that is
-- | entirely the job of `Let` (below).
data Atom
  = ALitInt Int -- also a `Char` (its code point); both box as `$Int = (struct i32)`
  | ALitNumber Number -- boxes as `$Num = (struct f64)`
  | ALitBoolean Boolean -- an `i31ref` (`true` = 1, `false` = 0), per ADR 0001
  | ALitString String -- a UTF-8 `$Str = (struct (ref (array (mut i32))))`, per ADR 0001
  | AVar VarRef

derive instance eqAtom :: Eq Atom
derive instance genericAtom :: Generic Atom _
instance showAtom :: Show Atom where
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
  -- | Saturated call to a `foreign import` that is neither an intrinsic nor a
  -- | runtime helper — emitted as a wasm **host import** (ADR 0014). Carries the
  -- | import's calling convention inline (`ForeignImport`); its internal wasm name
  -- | is `moduleName <> "." <> base`.
  | RCallForeign ForeignImport (Array Atom)
  -- | Allocate an ADT value: constructor `tag`, the wasm representation of each
  -- | field (its struct-field signature; ADR 0013 front B), and the field
  -- | initializers in field order. The value is one struct `$Data_<sig> = (sub
  -- | $Data (struct i32 <reps…>))` — the `i32` tag plus a typed field per `Rep`
  -- | (`i32`/`f64` for concrete scalars, `eqref` otherwise). A nullary constructor
  -- | (empty fields) is the tag-only base `$Data` and is shared (see Codegen).
  | RMkData Int (Array Rep) (Array Atom)
  -- | Construct an *enum-like* ADT value (a type whose every constructor is
  -- | nullary, e.g. `Ordering`): the value is just the constructor `tag` as an
  -- | allocation-free `i31ref` (like `Boolean`, ADR 0013), not a heap `$Data`.
  | RMkEnum Int
  -- | Read the constructor tag of an enum-like value as an `i32` (`ref.cast i31ref`
  -- | then `i31.get_s`), to drive a `LitSwitch` rather than reading a `$Data` tag.
  | REnumTag Atom
  -- | Project field `index` out of an ADT value (an `eqref`), given the
  -- | constructor's field-rep signature (to pick its `$Data_<sig>` struct type).
  -- | Lowered to a `ref.cast` to that struct, then a `struct.get` of field
  -- | `index + 1` (field 0 is the tag), read at the field's representation.
  | RProjField Atom (Array Rep) Int
  -- | Allocate a closure: the lifted code function plus the captured free
  -- | variables (its environment), in capture order. Lowered to
  -- | `struct.new $Clo [ref.func code, array.new_fixed $Vals captures]`.
  | RMkClosure FuncName (Array Atom)
  -- | Apply a closure value (an `eqref`) to a *single* argument via `call_ref`.
  -- | Closures are arity-1 (PureScript curries), so the lowering decomposes a
  -- | multi-argument application into a left-to-right chain of these.
  | RApply Atom Atom
  -- | Allocate a record (and, since dictionaries are records in CoreFn, a
  -- | type-class dictionary): parallel arrays of **interned `i32` label ids** and
  -- | their `eqref` values, given here as `(labelId, value)` pairs **sorted by
  -- | labelId** (the canonical layout; ADR 0001 / 0007). Lowered to
  -- | `struct.new $Rec [array.new_fixed $LabelIds ids, array.new_fixed $Vals vals]`.
  | RMkRecord (Array (Tuple Int Atom))
  -- | Project the value for an interned `i32` label id out of a record `eqref`,
  -- | by runtime search of the label-id array (no static layout / type info
  -- | needed — handles methods and superclass fields uniformly, ADR 0007).
  | RProjLabel Atom Int
  -- | Functional copy-and-set of one record field by interned `i32` label id (ADR
  -- | 0023): `$rt.recSet rec labelId value`, copying the record and replacing the
  -- | named field while preserving every other field — including an open row's
  -- | unknown tail. Chained to lower a polymorphic (open-row) record update.
  | RRecSet Atom Int Atom
  -- | Allocate an `Array` from its (already-`eqref`) elements. An array is the
  -- | bare `$Vals = (array (mut eqref))` (no wrapping struct), so this lowers to a
  -- | single `array.new_fixed $Vals [elements]`.
  | RMkArray (Array Atom)

-- where needed: | RBox Rep Atom | RUnbox Rep Atom

derive instance genericRhs :: Generic Rhs _
instance showRhs :: Show Rhs where
  show = genericShow

-- | An expression in A-normal form: a chain of `Let` bindings ending in a tail
-- | position. Every intermediate result is named by a `Slot`, mapping 1:1 onto
-- | a wasm local. The `Rep` on each `Let` is the representation of the bound
-- | slot, so codegen can declare the local's wasm type without consulting
-- | anything else.
data AnfExpr
  -- | The tail position: the expression evaluates to this already-computed atom.
  = Return Atom
  | Let Slot Rep Rhs AnfExpr
  -- | A compiled pattern match: read the scrutinee ADT's constructor tag and
  -- | branch on it. Field bindings live inside each branch body as `RProjField`
  -- | `Let`s. The optional default is taken when no tag matches; a
  -- | non-exhaustive match with no default traps (`unreachable`).
  | Switch Atom (Array Branch) (Maybe AnfExpr)
  -- | A mutually-recursive closure group (a `let rec` of functions). Each
  -- | `RecBind` is allocated first with its environment, then the slots that
  -- | refer to sibling group members are back-patched (knot-tying), since those
  -- | closures do not exist when the array is built. Bound for the continuation.
  | LetRec (Array RecBind) AnfExpr
  -- | A compiled match on **literal** patterns: test the scrutinee for
  -- | value-equality against each pattern in turn, branching to the first match.
  -- | Unlike `Switch` (which reads an ADT constructor tag), each test unboxes the
  -- | scrutinee and compares it to the literal. The optional default is the
  -- | catch-all (`_`/var) arm; its absence with no match traps.
  | LitSwitch Atom (Array LitBranch) (Maybe AnfExpr)
  -- | A join point (ADR 0022): run `producer` as a value-producing block — every
  -- | tail `Return v` inside it yields the join value — bind that value to `slot`
  -- | at `rep`, then run the continuation once. Lowered to
  -- | `(local.set slot (block (result rep) <producer>)); <k>`. This is how a `case`
  -- | in *argument* position is lowered without duplicating the continuation into
  -- | every branch (the commuting-conversion blowup).
  | LetJoin Slot Rep AnfExpr AnfExpr

-- | A literal pattern. A `Char` pattern is a `PInt` of its code point (same
-- | runtime representation); a `String` pattern compares by the runtime
-- | byte-equality helper.
data LitPat
  = PInt Int
  | PNumber Number
  | PBoolean Boolean
  | PString String

derive instance eqLitPat :: Eq LitPat
derive instance genericLitPat :: Generic LitPat _
instance showLitPat :: Show LitPat where
  show = genericShow

-- | One arm of a `LitSwitch`: the literal it matches and the body to run.
data LitBranch = LitBranch LitPat AnfExpr

-- | One arm of a `Switch`: the constructor `tag` it matches, and the expression
-- | to run when the scrutinee has that tag.
data Branch = Branch Int AnfExpr

-- | One member of a `LetRec`: the slot it binds, the lifted code function, and
-- | its captured environment (in order). Env atoms that reference another
-- | member's slot are the forward references resolved by knot-tying.
data RecBind = RecBind Slot FuncName (Array Atom)

instance showBranch :: Show Branch where
  show (Branch tag body) = "(Branch " <> show tag <> " " <> show body <> ")"

instance showLitBranch :: Show LitBranch where
  show (LitBranch pat body) = "(LitBranch " <> show pat <> " " <> show body <> ")"

instance showRecBind :: Show RecBind where
  show (RecBind slot name env) = "(RecBind " <> show slot <> " " <> show name <> " " <> show env <> ")"

instance showAnfExpr :: Show AnfExpr where
  show = case _ of
    Return a -> "(Return " <> show a <> ")"
    Let s r rhs k -> "(Let " <> show s <> " " <> show r <> " " <> show rhs <> " " <> show k <> ")"
    Switch scrut branches dflt -> "(Switch " <> show scrut <> " " <> show branches <> " " <> show dflt <> ")"
    LetRec binds k -> "(LetRec " <> show binds <> " " <> show k <> ")"
    LitSwitch scrut branches dflt -> "(LitSwitch " <> show scrut <> " " <> show branches <> " " <> show dflt <> ")"
    LetJoin slot rep producer k -> "(LetJoin " <> show slot <> " " <> show rep <> " " <> show producer <> " " <> show k <> ")"

-- | A top-level function. `params` carries both the arity (its length) and the
-- | representation of each parameter; parameters occupy slots
-- | `0 .. length params - 1`, and `Let` bindings in `body` take the slots after
-- | them. `export` is the external name when the function is exported from the
-- | module — exported functions are the module's observable surface, called by
-- | the host.
type IRFunc =
  { name :: FuncName
  , params :: Array Rep
  , result :: Rep
  , body :: AnfExpr
  , export :: Maybe String
  -- | Total local slots (parameters plus every `Let`-bound temporary, including
  -- | those inside `Switch` branches). Codegen declares `localCount - |params|`
  -- | extra locals; lowering supplies it from its final fresh-slot counter.
  , localCount :: Int
  }

-- | A whole compiled module: the top-level functions (including lifted code
-- | functions and the nullary functions that top-level value bindings compile
-- | to). The shared runtime helpers (string / array / `Effect` primitives) are not
-- | here — they live in a separate runtime wasm module imported at the `rt`
-- | namespace and linked in by wasm-merge (ADR 0010).
-- |
-- | `labels` is the program's record-label intern table — every record label as
-- | its `(string, i32 id)` pair (ids dense from 0, the same ids baked into
-- | `RProjLabel` / `RMkRecord`). Codegen emits it as the runtime `internStr`
-- | resolver so `Record.Unsafe`'s string-keyed access (`unsafeGet`, …) can turn a
-- | runtime label string — e.g. a `reflectSymbol` result — back into its id.
type Program =
  { funcs :: Array IRFunc
  , labels :: Array (Tuple String Int)
  -- | The marshal signature of each **exported** function, keyed by its external
  -- | name. Lets the export wrapper expose host-facing params/result at their
  -- | `marshalRep` (so a `String`/`Array`/`Record`/`Boolean`/`Number` export crosses
  -- | properly, not forced to `i32`), and the JS loader marshal them (ADR 0014).
  , exportSigs :: Object ForeignImport
  }

-- | A `foreign import` resolved to a wasm host import: its source module / base
-- | name (the import's `(module, name)`) and its calling convention as a
-- | `MarshalKind` per parameter and result. Carried inline by `RCallForeign`;
-- | structurally matches `Externs.ForeignSig`.
type ForeignImport =
  { moduleName :: String
  , base :: String
  , params :: Array MarshalKind
  , result :: MarshalKind
  }

-- | How a value crosses the wasm↔JS FFI boundary (ADR 0014). It refines `Rep`:
-- | `MI32`/`MF64` are raw scalars that *are* a JS `number` (no marshalling); `MBool`
-- | is an `i31ref` converted to/from a JS `boolean`; `MStr` is a `$Str` converted
-- | to/from a JS `string`; `MArray` is a `$Vals` array converted to/from a JS array,
-- | each element marshalled by the inner kind; `MRecord` a record ⇄ object; `MOpaque`
-- | is any other `eqref` (passed through as a reference).
data MarshalKind
  = MI32 -- Int, Char
  | MF64 -- Number
  | MBool -- Boolean
  | MStr -- String
  | MArray MarshalKind -- Array a (elements marshalled by the inner kind)
  | MRecord (Array (Tuple String MarshalKind)) -- a record { l :: T … } (fields by name)
  | MFunc MarshalKind MarshalKind -- a function a -> b (a `$Clo` ⇄ a JS function)
  | MEffect MarshalKind -- `Effect a`: the JS glue *runs* the foreign's thunk (`()`) and
  -- marshals the result by the inner kind, so wasm never holds a JS thunk (ADR 0015)
  | MOpaque -- any other boxed value

derive instance eqMarshalKind :: Eq MarshalKind
derive instance genericMarshalKind :: Generic MarshalKind _
instance showMarshalKind :: Show MarshalKind where
  show m = genericShow m

-- | The wasm representation a `MarshalKind` lowers to: scalars stay raw, everything
-- | else is the boxed `eqref`.
marshalRep :: MarshalKind -> Rep
marshalRep = case _ of
  MI32 -> I32
  MF64 -> F64
  -- a Boolean is always the boxed `i31ref` (never an unboxed `i32` — it reaches `i32`
  -- only at condition sites via `unboxBoolExpr`), so it crosses as an `eqref`
  MBool -> Boxed
  MStr -> Boxed
  MArray _ -> Boxed
  MRecord _ -> Boxed
  MFunc _ _ -> Boxed -- a closure is the `$Clo` eqref
  MEffect k -> marshalRep k -- the performed result's rep (the boundary value is the result)
  MOpaque -> Boxed

-- | A JSON encoding of a `MarshalKind` for the JS marshalling glue (ADR 0014): the leaves are the
-- | strings `"i"`/`"f"`/`"b"`/`"s"`/`"o"`; an array is `{"a":<kind>}`; a record is
-- | `{"r":{<field>:<kind>,…}}`; a function is `{"fn":[<param>,<result>]}`; an effect is
-- | `{"eff":<kind>}`. The glue dispatches on `typeof`/`.a`/`.r`/`.fn`/`.eff` and marshals
-- | recursively. Built as a structured `Json` value (argonaut handles the quoting/escaping), not a
-- | hand-concatenated string.
marshalKindJson :: MarshalKind -> Json
marshalKindJson = case _ of
  MI32 -> J.fromString "i"
  MF64 -> J.fromString "f"
  MBool -> J.fromString "b"
  MStr -> J.fromString "s"
  MOpaque -> J.fromString "o"
  MArray k -> tagged "a" (marshalKindJson k)
  MRecord fields -> tagged "r" (jsonObject (map (\(Tuple n k) -> Tuple n (marshalKindJson k)) fields))
  MFunc p r -> tagged "fn" (J.fromArray [ marshalKindJson p, marshalKindJson r ])
  MEffect k -> tagged "eff" (marshalKindJson k)
  where
  tagged key v = jsonObject [ Tuple key v ]

-- | A foreign/export signature as a JSON object: `{"params":[<kind>…],"result":<kind>}`.
sigJson :: ForeignImport -> Json
sigJson s = jsonObject
  [ Tuple "params" (J.fromArray (map marshalKindJson s.params))
  , Tuple "result" (marshalKindJson s.result)
  ]

jsonObject :: Array (Tuple String Json) -> Json
jsonObject = J.fromObject <<< Object.fromFoldable

-- | The FFI marshal manifest as a JSON object string, keyed by import name `Module.base`, each
-- | entry `{"params":[<kind>…],"result":<kind>}` (ADR 0014). The production loader bakes it; the
-- | harness `JSON.parse`s it. The glue looks up `manifest[module + "." + name]` per host import.
foreignManifestJson :: Array ForeignImport -> String
foreignManifestJson sigs =
  J.stringify (jsonObject (map (\s -> Tuple (s.moduleName <> "." <> s.base) (sigJson s)) sigs))

-- | The export marshal manifest as a JSON object string, keyed by each export's **external name**
-- | (the name `inst.exports.<name>` is reached by), each entry `{"params":[…],"result":<kind>}`
-- | (ADR 0014). The loader/harness use it to marshal a JS caller's args into wasm and back out.
exportManifestJson :: Object ForeignImport -> String
exportManifestJson sigs = J.stringify (J.fromObject (map sigJson sigs))
