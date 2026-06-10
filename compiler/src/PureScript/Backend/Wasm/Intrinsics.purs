-- | The backend's inlined machine ops (ADR 0002, tier 1) and the
-- | foreign-primitive table that resolves a `foreign import` to one of them.
-- |
-- | `Intrinsic` is a closed enum keyed by *operation* rather than by CoreFn name,
-- | which decouples the IR from the foreign identifiers a given `Prelude` version
-- | uses: `foreignIntrinsic` owns the foreign-identifier → `Intrinsic` mapping
-- | (this module), and `genPrim` in the code generator owns `Intrinsic` → Binaryen.
-- | This module is a self-contained leaf — the IR embeds `Intrinsic` in `RPrim`.
module PureScript.Backend.Wasm.Intrinsics
  ( Intrinsic(..)
  , foreignIntrinsic
  , qualifiedIntrinsic
  , effectfulForeignNames
  ) where

import Prelude

import Control.Alt ((<|>))
import Data.Generic.Rep (class Generic)
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.Set as Set
import Data.Show.Generic (genericShow)
import Data.String (stripPrefix)
import Data.String (Pattern(..)) as Str
import Data.Tuple (Tuple(..))

data Intrinsic
  = IntAdd
  | IntSub
  | IntMul
  | IntEq -- Int -> Int -> Boolean (`i32.eq`, result boxed as an `i31` Boolean)
  -- | `Data.Ord`'s `ordIntImpl lt eq gt x y`: the `Ordering` (`lt`/`eq`/`gt`) of
  -- | two `Int`s. Five operands — the three `Ordering` values and the two ints —
  -- | selected by a signed `i32` comparison.
  | OrdInt
  -- | `Data.Eq`/`Data.Ord` on `Boolean` (`i31` bits) and `Number` (`$Num` f64).
  -- | `BoolEq` is arity 2; `OrdBool`/`OrdNumber` are the same `lt eq gt x y`
  -- | five-operand shape as `OrdInt`, differing only in unbox + compare.
  | BoolEq
  | OrdBool
  | OrdNumber
  | OrdString -- `lt eq gt x y` selecting on the `$rt.strCmp` lexicographic result
  | IntToNum -- Int -> Number (`f64.convert_i32_s`)
  | NumToInt -- Number -> Int (`i32.trunc_f64_s`)
  -- | `Data.EuclideanRing`'s `Int` instance: Euclidean division (non-negative
  -- | remainder), with a zero guard so it matches `Prelude` and never traps.
  | IntDiv -- Int -> Int -> Int  (`(x - intMod x y) / y`, 0 when y = 0)
  | IntMod -- Int -> Int -> Int  (`((x % |y|) + |y|) % |y|`, 0 when y = 0)
  | IntDegree -- Int -> Int  (`min (|x|) maxInt`)
  | NumAdd -- Number -> Number -> Number (`f64.add`)
  | NumSub -- Number -> Number -> Number (`f64.sub`)
  | NumMul -- Number -> Number -> Number (`f64.mul`)
  | NumDiv -- Number -> Number -> Number (`f64.div`)
  | NumEq -- Number -> Number -> Boolean (`f64.eq`, result boxed as an `i31` Boolean)
  | BoolAnd -- Boolean -> Boolean -> Boolean (`i32.and` on the i31 bits)
  | BoolOr -- Boolean -> Boolean -> Boolean (`i32.or`)
  | BoolNot -- Boolean -> Boolean (`i32.eqz`)
  | StrLen -- String -> Int (UTF-8 byte length, `array.len`)
  | StrConcat -- String -> String -> String (allocate + copy both byte arrays)
  | StrEq -- String -> String -> Boolean (length then byte-by-byte compare)
  -- | `Wasm.String` (WasmBase, ADR 0026/0030) first-order **byte-level** `$Str` primitives, so the
  -- | `Data.String.*` code-point operations can be written in PureScript over them (UTF-8
  -- | decode/encode in PureScript) and thus run standalone on wasm — the Rust `.as_bytes()` analog.
  -- | `StrByteAt s i` reads the `i`-th UTF-8 byte (0-255); `StrNew n` allocates a length-`n`
  -- | zeroed byte string; `StrSetByte s i b` writes byte `b` at `i` (mutating in place) and
  -- | **returns `s`**, threaded through the builder loop exactly as `ArraySet` (keeping the write
  -- | live and ordered without an effect).
  | StrByteAt -- String -> Int -> Int (`array.get` on the `$Bytes`)
  | StrNew -- Int -> String (zeroed `$Str` of `n` bytes)
  | StrSetByte -- String -> Int -> Int -> String (writes the byte, returns the string)
  -- | `Wasm.Char` (WasmBase, ADR 0026/0030): `Char` ↔ code-point `Int`. A `Char` is already an
  -- | `i32` code point in this backend (ADR 0030: `Char` = Unicode code point, not a UTF-16 unit),
  -- | so both directions are the **identity** on the `i32` — the operand *is* the result.
  | CharCodeId -- Char -> Int / Int -> Char (identity on the i32 code point)
  | ArrayLength -- Array a -> Int (`array.len`)
  | ArrayIndex -- Array a -> Int -> a (`array.get`; the element is already an `eqref`)
  | ArrayConcat -- Array a -> Array a -> Array a (`Data.Semigroup` `<>`: allocate + copy both)
  -- | `Wasm.Array` (WasmBase, ADR 0026) first-order array-build primitives, so higher-order
  -- | array combinators (`map`/`foldl`/…) can be written in PureScript over them and thus
  -- | *specialize* (ADR 0027), unlike the foreign `ulib` HOFs. `ArrayNew n` allocates a
  -- | length-`n` array (elements null until filled); `ArraySet arr i v` writes `v` at `i`
  -- | (mutating the wasm array in place) and **returns `arr`**, so the result is threaded
  -- | through the builder loop — keeping the write live (not DCE'd) and ordered by the data
  -- | dependency, without needing an effect.
  | ArrayNew -- Int -> Array a
  | ArraySet -- Array a -> Int -> a -> Array a (writes, returns the array)
  -- | `Data.Bounded`'s `top` / `bottom` for `Int` / `Char` / `Number`: nullary
  -- | constant values (the foreign is a bare value, not a function — arity 0).
  | TopInt -- maxBound Int (`i32.const 2147483647`)
  | BottomInt -- minBound Int (`i32.const -2147483648`)
  | TopChar -- maxBound Char, code point 0xFFFF (`Int`-rep)
  | BottomChar -- minBound Char, code point 0 (`Int`-rep)
  | TopNumber -- `+Infinity` (`$Num` f64)
  | BottomNumber -- `-Infinity` (`$Num` f64)
  -- | `Data.Unit.unit` (arity 0): the single `Unit` inhabitant — a nullary constant
  -- | foreign (like `topInt`), never inspected, so any boxed value serves.
  | UnitValue
  -- | `Record.Unsafe` string-keyed record access. The runtime `String` key is
  -- | resolved to its interned `i32` label id by the emitted `internStr`, then the
  -- | record's parallel id/value arrays are read or rebuilt (ADR 0007).
  | UnsafeGet -- String -> Record r -> a
  | UnsafeHas -- String -> Record r -> Boolean
  | UnsafeSet -- String -> a -> Record r1 -> Record r2
  | UnsafeDelete -- String -> Record r1 -> Record r2
  -- | Test-only effectful primitives backed by a mutable wasm global `$ctr`, used to
  -- | make `Effect`'s effect ordering/count observable (so the purity analysis that
  -- | preserves effectful `Perform`s can be verified end-to-end). `IncrCtr` bumps the
  -- | counter and returns Unit; `ReadCtr` returns its current value. Both take (and
  -- | ignore) the `perform` unit argument, so their arity is 1.
  | IncrCtr -- Effect Unit: `$ctr := $ctr + 1`
  | ReadCtr -- Effect Int: read `$ctr`
  -- | `Data.Int.fromNumberImpl just nothing n`: `Number -> Maybe Int`, the private
  -- | foreign behind `fromNumber`/`floor`/`ceil`/`round`/`trunc`. Returns `just n` when
  -- | `n` is an integer in the `Int32` range (matching JS `(n | 0) === n`), else
  -- | `nothing`; `just` is applied via the closure trampoline.
  | FromNumberImpl
  -- | `Effect.Ref` / `Control.Monad.ST` native mutable cell (ADR 0017). The cell is a
  -- | wasm `$Ref` struct, so no value crosses to JS. Each consumes the trailing
  -- | `Effect`/`ST` perform-unit operand (dropped in codegen). `RefNew`/`RefRead`/
  -- | `RefNewWithSelf` return an `eqref`; `RefWrite` returns `Unit` (`i32` 0); `RefModify`
  -- | takes `[f, ref, stateId, valueId]` (the label ids resolved at lowering) and returns
  -- | the record's `value`.
  | RefNew
  | RefRead
  | RefWrite
  | RefNewWithSelf
  | RefModify
  -- | `effect` package control-flow primitives (ADR 0018): native wasm loops applying the
  -- | body/condition closure. Each returns `Unit` and consumes the trailing perform-unit.
  | ForE
  | ForeachE
  | WhileE
  | UntilE
  -- | `Effect.Uncurried` (ADR 0018). `EffectFnN` IS the curried closure, so `mkEffectFnN`
  -- | is identity; `runEffectFnN g x₁…x_N` applies `g` to the N args (an `applyClo` chain),
  -- | yielding the `Effect` thunk (the caller performs it).
  | MkEffectFn
  | RunEffectFn
  -- | `Partial.Unsafe._unsafePartial :: (Unit -> a) -> a` — runs the partial thunk by
  -- | applying it to the unit (the erased `Partial` dictionary). Native so the wasm
  -- | closure never crosses to the JS foreign (which would call it as `f()`).
  | UnsafePartial

derive instance eqIntrinsic :: Eq Intrinsic
derive instance genericIntrinsic :: Generic Intrinsic _
instance showIntrinsic :: Show Intrinsic where
  show = genericShow

-- | The foreign-primitive table — ADR 0002's `ForeignProvider`, hard-coded for the
-- | closed surface the backend currently understands. It maps a foreign import's
-- | *identifier* to the `Intrinsic` it stands for plus that intrinsic's arity.
-- |
-- | Keyed by the bare identifier (names are unique across the modules we link), so
-- | the real `Prelude`'s foreigns (`intAdd`, `eqIntImpl`, …) resolve directly. The
-- | string/array/`numToInt` entries are backend-internal helpers for features the
-- | real `Prelude` does not yet reach here.
foreignIntrinsic :: String -> Maybe (Tuple Intrinsic Int)
foreignIntrinsic = case _ of
  -- `Data.Semiring` / `Data.Ring` integer arithmetic
  "intAdd" -> Just (Tuple IntAdd 2)
  "intMul" -> Just (Tuple IntMul 2)
  "intSub" -> Just (Tuple IntSub 2)
  -- `Data.EuclideanRing` integer division (Euclidean: non-negative remainder)
  "intDiv" -> Just (Tuple IntDiv 2)
  "intMod" -> Just (Tuple IntMod 2)
  "intDegree" -> Just (Tuple IntDegree 1)
  -- `Data.Eq` / `Data.Ord` on Int (and Char, which shares its representation)
  "eqIntImpl" -> Just (Tuple IntEq 2)
  -- `Data.Bounded` top/bottom (nullary constant values, arity 0)
  "topInt" -> Just (Tuple TopInt 0)
  "bottomInt" -> Just (Tuple BottomInt 0)
  "topChar" -> Just (Tuple TopChar 0)
  "bottomChar" -> Just (Tuple BottomChar 0)
  "topNumber" -> Just (Tuple TopNumber 0)
  "bottomNumber" -> Just (Tuple BottomNumber 0)
  "eqCharImpl" -> Just (Tuple IntEq 2)
  "eqStringImpl" -> Just (Tuple StrEq 2)
  "ordIntImpl" -> Just (Tuple OrdInt 5)
  -- `Char` compares by code point, identical to `Int` (shared `i32` rep)
  "ordCharImpl" -> Just (Tuple OrdInt 5)
  -- `Boolean` / `Number` equality and ordering
  "eqBooleanImpl" -> Just (Tuple BoolEq 2)
  "ordBooleanImpl" -> Just (Tuple OrdBool 5)
  "ordNumberImpl" -> Just (Tuple OrdNumber 5)
  "ordStringImpl" -> Just (Tuple OrdString 5)
  -- `Array` higher-order foreigns (`eqArrayImpl`/`ordArrayImpl`, `arrayMap`/`arrayApply`/
  -- `arrayBind`) are curated ulib foreigns (ADR 0012), resolved via `foreignSigs`.
  -- `Data.HeytingAlgebra` Boolean algebra
  "boolConj" -> Just (Tuple BoolAnd 2)
  "boolDisj" -> Just (Tuple BoolOr 2)
  "boolNot" -> Just (Tuple BoolNot 1)
  -- `Data.Semigroup` `<>`: string concat reuses the string runtime helper
  "concatString" -> Just (Tuple StrConcat 2)
  "concatArray" -> Just (Tuple ArrayConcat 2)
  -- `Data.Show` (`show*Impl`) and `Data.Show.Generic`'s `intercalate` are curated ulib
  -- foreigns (ADR 0012), resolved via `foreignSigs` to host imports — not intrinsics.
  -- `Data.Unit.unit` — a nullary constant foreign. (`unsafeCoerce` is not here: it
  -- is erased during lowering rather than emitted as an op.)
  "unit" -> Just (Tuple UnitValue 0)
  -- `Record.Unsafe` string-keyed record access
  "unsafeGet" -> Just (Tuple UnsafeGet 2)
  "unsafeHas" -> Just (Tuple UnsafeHas 2)
  "unsafeSet" -> Just (Tuple UnsafeSet 3)
  "unsafeDelete" -> Just (Tuple UnsafeDelete 2)
  -- `Number` arithmetic + `Int` → `Number` conversion
  "numAdd" -> Just (Tuple NumAdd 2)
  "numMul" -> Just (Tuple NumMul 2)
  "numSub" -> Just (Tuple NumSub 2)
  "numDiv" -> Just (Tuple NumDiv 2)
  "eqNumberImpl" -> Just (Tuple NumEq 2)
  "toNumber" -> Just (Tuple IntToNum 1)
  -- backend-internal helpers (no real-Prelude equivalent wired yet): strings,
  -- arrays, and Number → Int
  "lenS" -> Just (Tuple StrLen 1)
  "concatS" -> Just (Tuple StrConcat 2)
  "eqS" -> Just (Tuple StrEq 2)
  "lengthA" -> Just (Tuple ArrayLength 1)
  "indexA" -> Just (Tuple ArrayIndex 2)
  "eqI" -> Just (Tuple IntEq 2)
  "intToNum" -> Just (Tuple IntToNum 1)
  "numToInt" -> Just (Tuple NumToInt 1)
  -- `Data.Int` Number→Int (the private foreign behind `fromNumber`/`floor`/…)
  "fromNumberImpl" -> Just (Tuple FromNumberImpl 3)
  -- test-only effectful primitives (arity 1: they consume the `perform` unit)
  "incrCtr" -> Just (Tuple IncrCtr 1)
  "readCtr" -> Just (Tuple ReadCtr 1)
  _ -> Nothing

-- | Intrinsics resolved by *qualified* name (rather than the bare identifier the table
-- | above uses): the `effect`-package primitives — `Effect.Ref` cell ops (ADR
-- | 0017) and the `Effect` control-flow loops (ADR 0018) — plus
-- | `Partial.Unsafe._unsafePartial`, a couple of `Data.Array` ops, and the
-- | uncurried-function families. Qualified because names like `read` / `write` / `new`
-- | / `forE` are too generic to claim globally.
-- |
-- | The arity counts each op's value parameters plus the trailing `Effect`
-- | perform-unit for the ops whose result is `Effect Unit` (`Ref.write`, `forE`, …):
-- | they are performed via the unit-application path, and that unit operand is dropped
-- | in codegen. `modifyImpl` is here too (`RefModify`, arity 3 so an unperformed
-- | `modify' = modifyImpl` eta-expands to a proper thunk); its record `state` / `value`
-- | label ids are resolved at codegen via `internStr` (`Codegen.Prim`).
-- |
-- | The uncurried families are pure but share the closure machinery: `mkEffectFnN` /
-- | `Data.Function.Uncurried.mkFnN` are the identity (the uncurried value *is* the
-- | curried `$Clo`, arity 1), and `runEffectFnN` / `runFnN` apply the function to its N
-- | arguments via the `applyClo` chain (arity N+1, the suffix parsed) — identical
-- | codegen; the only difference (an `Effect` result performed by the caller vs. a plain
-- | result) is invisible here.
-- |
-- | (`Control.Monad.ST` shares the `$Ref` representation, a natural follow-up once its
-- | foreign names/shapes are confirmed; not wired here yet.)
qualifiedIntrinsic :: String -> Maybe (Tuple Intrinsic Int)
qualifiedIntrinsic = case _ of
  "Effect.Ref._new" -> Just (Tuple RefNew 2)
  "Effect.Ref.read" -> Just (Tuple RefRead 2)
  "Effect.Ref.write" -> Just (Tuple RefWrite 3)
  "Effect.Ref.newWithSelf" -> Just (Tuple RefNewWithSelf 2)
  "Effect.Ref.modifyImpl" -> Just (Tuple RefModify 3)
  "Effect.forE" -> Just (Tuple ForE 4) -- lo, hi, f, perform-unit
  "Effect.foreachE" -> Just (Tuple ForeachE 3) -- arr, f, perform-unit
  "Effect.whileE" -> Just (Tuple WhileE 3) -- cond, body, perform-unit
  "Effect.untilE" -> Just (Tuple UntilE 2) -- action, perform-unit
  "Partial.Unsafe._unsafePartial" -> Just (Tuple UnsafePartial 1)
  "Data.Array.unsafeIndexImpl" -> Just (Tuple ArrayIndex 2)
  -- library array/foldable FFIs implemented natively in the runtime (ulib batch 0)
  "Data.Array.length" -> Just (Tuple ArrayLength 1)
  -- `Wasm.Array` (WasmBase, ADR 0026): first-order array primitives that PureScript-level
  -- combinators build on (so they specialize). `length`/`unsafeIndex` reuse the existing ops.
  "Wasm.Array.length" -> Just (Tuple ArrayLength 1)
  "Wasm.Array.unsafeIndex" -> Just (Tuple ArrayIndex 2)
  "Wasm.Array.unsafeNew" -> Just (Tuple ArrayNew 1)
  "Wasm.Array.unsafeSet" -> Just (Tuple ArraySet 3)
  -- `Wasm.String` (WasmBase, ADR 0030): first-order byte-level `$Str` primitives the
  -- `Data.String.*` code-point ops build on. `byteLength` reuses `StrLen`.
  "Wasm.String.byteLength" -> Just (Tuple StrLen 1)
  "Wasm.String.byteAt" -> Just (Tuple StrByteAt 2)
  "Wasm.String.unsafeNew" -> Just (Tuple StrNew 1)
  "Wasm.String.unsafeSetByte" -> Just (Tuple StrSetByte 3)
  -- `Wasm.Char` (WasmBase, ADR 0030): `Char` ↔ code-point `Int`, both the identity on the i32.
  "Wasm.Char.toCodePoint" -> Just (Tuple CharCodeId 1)
  "Wasm.Char.fromCodePoint" -> Just (Tuple CharCodeId 1)
  -- `Wasm.Int` (WasmBase): first-order `Int` ops, so ulib shadows of low-level prelude
  -- modules (e.g. `Data.Functor`) need no `Prelude` for their loop arithmetic (ADR 0028).
  "Wasm.Int.add" -> Just (Tuple IntAdd 2)
  "Wasm.Int.sub" -> Just (Tuple IntSub 2)
  "Wasm.Int.mul" -> Just (Tuple IntMul 2)
  "Wasm.Int.eq" -> Just (Tuple IntEq 2)
  -- `reverse`/`sliceImpl`/`indexImpl`/`unconsImpl`, `Data.Foldable.fold{l,r}Array`,
  -- `Data.String.CodeUnits.{singleton,toCharArray,fromCharArray}`, `Data.Int.fromStringAsImpl`
  -- now live in `ulib/<Module>/foreign.wat` (ADR 0012), resolved as merged foreigns.
  name -> uncurriedMk name <|> uncurriedRun name
  where
  -- `mkEffectFnN` / `mkFnN`: identity (arity 1)
  uncurriedMk name =
    (stripPrefix (Str.Pattern "Effect.Uncurried.mkEffectFn") name <|> stripPrefix (Str.Pattern "Data.Function.Uncurried.mkFn") name)
      $> Tuple MkEffectFn 1
  -- `runEffectFnN` / `runFnN`: the function + its N arguments (N parsed from the suffix)
  uncurriedRun name = do
    suffix <- stripPrefix (Str.Pattern "Effect.Uncurried.runEffectFn") name <|> stripPrefix (Str.Pattern "Data.Function.Uncurried.runFn") name
    n <- Int.fromString suffix
    pure (Tuple RunEffectFn (n + 1))

-- | The qualified names of `foreign import`s whose *running* performs a side effect —
-- | the seed set for the middle-end's purity analysis (ADR 0015): the test-only counter
-- | primitives plus the `Effect.Ref` / `ST` cell ops (ADR 0017), so a `Perform` of a
-- | ref op is preserved. Other effectful FFI (Console, EffectFnN) is derived from
-- | externs/source types (`effectfulForeignNamesFromSigs`).
effectfulForeignNames :: Set String
effectfulForeignNames = Set.fromFoldable
  [ "Counter.incrCtr"
  , "Counter.readCtr"
  , "Effect.Ref._new"
  , "Effect.Ref.read"
  , "Effect.Ref.write"
  , "Effect.Ref.modifyImpl"
  , "Effect.Ref.newWithSelf"
  , "Effect.forE"
  , "Effect.foreachE"
  , "Effect.whileE"
  , "Effect.untilE"
  ]
