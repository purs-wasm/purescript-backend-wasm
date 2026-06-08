# 0026. WasmBase: a stable primitive layer between `Prim` and `Prelude`

- Status: Proposed
- Date: 2026-06-08
- Supersedes: [0012](0012-ulib-curated-package-ffi.md) (its hand-written-`.wat` mechanism and provider ladder; `ulib`'s curated-core intent carries forward in PureScript form)

## Context

Three threads converge on one missing layer.

**1. `foreign` is an optimization barrier (issue #5).** Higher-order specialization
(`MiddleEnd/Optimize/Specialize.purs`) inlines a statically-known closure into a copy of
its callee — but only when the callee has a visible MIR body. Candidates come from
`moduleFuncs` (`m.decls` bindings that are `M.Abs`); the call-site gate requires
`Map.lookup qn funcs` to succeed (`Specialize.purs:75`, `:170`). A `foreign` has **no
body** — it lives in `m.foreignNames`, is emitted as hand-written wat merged at link time,
and is therefore opaque to specialization, inlining, dictionary elimination, purity
analysis, and unboxing. A *higher-order* foreign (e.g. `Data.Functor.arrayMap`,
`Data.Foldable.foldlArray`) is the pathological case: the closure it receives can never be
fused, so it is applied per element via `call_ref` (`ulib/Data.Functor/foreign.wat`,
`runtime.wat`'s `$callClo1`). This is precisely why `mapFoldArray` (foreign HOFs over
`Data.Array`) does not specialize, while `mapFold` (pure-PureScript HOFs over `Data.List`)
does.

A general fix must not be per-function (special-casing `arrayMap` does not scale and
unfairly privileges benchmarked functions). The only general resolution is structural:
**a higher-order function we want optimized must not be a `foreign` at all** — it must be
PureScript, built on *first-order* primitives. First-order operations (array `get`/`set`,
`length`, string byte access) carry no closure, so the foreign barrier costs nothing there.

**2. The versioning problem has two axes, and hand-written per-package wat is exposed to
both.** Any hand-written wat FFI — whether a full wasm package set or the curated core
`ulib` keeps today (see ADR 0012) — must contend with:

- **Axis 1 — package API version.** A wat fragment is written against a specific library
  version's foreign set and signatures; an upstream bump can silently desync it.
- **Axis 2 — backend runtime ABI version.** A wat fragment imports `rt.*` helpers
  (`applyClo`, …) and is written against the backend's private GC type layout (`$Vals`,
  `$Clo`, `$Code`, `$Int`, `$Rec`, `$Str` in `_header.wat`). When the backend changes its
  representation (as it has, repeatedly — int unboxing, rep-aware codegen), **every
  package's hand-written wat breaks.** Unlike JS FFI (which targets the stable JS language),
  raw wat FFI targets a young, moving ABI. This axis is the one usually underestimated, and
  it makes "every package ships hand-written wat" (the purerl-style model) untenable as a
  default.

Minimizing hand-written wat to a tiny first-order layer shrinks the exposure on *both*
axes: PureScript code riding that layer is version-correct (it is just source) and
ABI-decoupled (it is compiled by the current backend, so it always matches). The same move
that fixes #5 (HOFs in PureScript) also contains the versioning blast radius.

**3. `ulib` today mixes the two kinds of primitive.** The intrinsic surface
(`Intrinsics.purs` + `runtime.wat` exports) and `ulib/*/foreign.wat` currently hold both
genuine first-order primitives (`arrayNew`/`arrayGet`/`arraySet`/`arrayLen`,
`strByteAt`/`strSetByte`/`strLen`/`strConcat`/`strCmp`, `refNew`/`read`/`write`,
`unsafeGet`/`unsafeSet`, `eq*Impl`/`ord*Impl`, `intAdd`/`numAdd`/…) **and** higher-order
operations that should not be primitives at all (`Effect.forE`/`foreachE`/`whileE`/`untilE`,
and the ulib HOFs `arrayMap`/`foldlArray`). The first-order set is stable and irreducible;
the higher-order set is exactly what the foreign barrier penalizes.

There is no named, public, stable home for "the operations PureScript cannot express on
this backend." Stock `purs` ships `Prim` (types) with the compiler; this backend has an
analogous but *value-level* need one layer up.

## Decision

Introduce **WasmBase** (working name): a compiler-coupled, version-locked, public
PureScript layer sitting **between `Prim` and `Prelude`**. It exposes the first-order
operations and representation contract that PureScript cannot express on this backend.
`Prelude` and the FFI-bearing core packages (`arrays`, `strings`, `foldable-traversable`,
…) are reimplemented in pure PureScript **on top of WasmBase**, so they specialize and are
ABI-decoupled.

Naming (decided 2026-06-08): the *layer* is **WasmBase** (this record's name); the *module
namespace* is **`Wasm.*`** (`Wasm.Array`, `Wasm.String`, … — short, cf. ReScript's `Js.*`
for reaching the host platform). It deliberately does **not** live under `Prim`: `Prim` is
the compiler's reserved *type-level* namespace, whereas WasmBase is *value-level* and must
not pollute it.

```
Prim          types only (compiler-provided)
  │
WasmBase      first-order value primitives + representation contract
  │           (compiler-provided, version-locked to the backend)
  │
Prelude / arrays / strings / …    pure PureScript over WasmBase
```

### Inclusion rules (the boundary that makes WasmBase work)

1. **First-order only. No higher-order operations.** A HOF placed in WasmBase would
   reintroduce the foreign barrier one level down (its closure argument could not be fused).
   Iteration is therefore *not* a primitive: loops are written as PureScript recursion over
   `get`/`set`/`length`. This directly reshapes the current surface — `forE`/`foreachE`/
   `whileE`/`untilE` and `arrayMap`/`foldlArray` are **relocated** out of the primitive
   layer into PureScript.
2. **Representation-revealing.** WasmBase is where the backend's representation decisions
   surface *as a contract*: UTF-8 byte strings, boxed `Int`, `eqref` values. This is a
   feature — the representation becomes explicit and stable, not hidden.
3. **No type classes.** Abstraction is `Prelude`'s job; WasmBase is the bare substrate.
4. **Always native, never JS-fallback.** WasmBase operations are the foundation; they must
   resolve to intrinsics/runtime, never to the slow JS path (see the ladder below).

The first implementation task is the **inventory**: take the current
`Intrinsics.qualifiedIntrinsic`/`foreignIntrinsic` tables and `runtime.wat` exports as the
candidate set, keep the first-order members, and group them into provisional WasmBase
modules (provisional grouping: `Array` build/index/length, `String` UTF-8 bytes, `Ref`,
`Record` label ops, scalar `Int`/`Number`/`Char`/`Boolean` ops, `Partial`). The HOFs are
dropped from the primitive set and rewritten as PureScript.

### The three FFI paths and their precedence

WasmBase does **not** replace the foreign-resolution ladder — it becomes its top rung.
There are three FFI paths; only one is fragile:

| Path | Speed | What the author targets | Backend-ABI (axis 2) exposure |
| --- | --- | --- | --- |
| raw per-package wat | fast but fragile | the raw GC types | **direct** (breaks on backend change) |
| **WasmBase** | fast, optimizable | a stable primitive contract | concentrated/hidden in the backend |
| **JS fallback** | slow but effortless | plain JS | absorbed by the marshalling glue |

Resolution precedence: **WasmBase/intrinsic → `ulib` (repositioned, see below) →
JS fallback.** Raw *per-package* wat is discouraged and ultimately eliminated; WasmBase and
JS fallback are the two sanctioned paths, occupying opposite ends of a
convenience↔performance spectrum.

### `ulib` is repositioned, not retired

`ulib` persists, but its contents change. A full, purerl-style migration — every package
shipping its own wasm FFI, resolved as a coherent package set — is a large effort and is
**deferred**. The pragmatic middle ground is that this project keeps curating a **small,
hand-picked set of core libraries** (`strings`, `arrays`, `effect`, …) itself. What changes
is the *form* of that curation:

- **Before:** `ulib/<Module>/foreign.wat` — hand-written wat (first-order *and* higher-order,
  coupled to the raw GC ABI).
- **After:** `ulib` becomes a collection of **PureScript modules reimplemented on
  WasmBase.** The first-order operations its wat used to provide move down into WasmBase
  (compiler-owned); the library logic (including the HOFs) moves up into PureScript that
  rides WasmBase — specializable and ABI-decoupled.

So `ulib`'s role shifts from "a curated `foreign.wat` collection" to "a curated
**WasmBase-based PureScript** collection": the project-maintained core that exists until (and
if) a full wasm package set arrives. Raw hand-written wat survives only inside WasmBase
itself (the irreducible primitive layer), not per library.

### The JS fallback is retained (and is a versioning asset)

The JS fallback — a `foreign import` with no wasm implementation is resolved by importing
its `foreign.js` and wrapping it with the loader's marshalling glue (`eqrefToJs` /
`eqrefFromJs` / `applyCurried`, ADR 0014/0016) — is kept as the **convenience tier**. It is
the backend's distinctive "drop in JS and it just works" sweetener. Notably it is
*axis-2-decoupled for the author*: the author writes plain JS, and the backend-provided glue
absorbs the GC ABI. WasmBase (speed, ABI concentrated) and JS fallback (convenience, ABI
absorbed by glue) are thus the two complementary ways to **avoid the fragile raw-wat path**.

This enables **progressive optimization**: ship a foreign on the JS fallback (works
immediately, slower), and later graduate the hot ones to WasmBase-based PureScript — the
`foreign import` signature is unchanged; only the resolution target moves from JS to
WasmBase.

### Optional: unboxed primitive container types

Because WasmBase reveals representation, it may later expose *monomorphic* primitive
containers (e.g. `IntArray` backed by `(array (mut i32))`, like the existing `$Bytes`).
Combined with closure fusion (#5), a PureScript `map`/`fold` over such a type produces a
loop that touches `i32` directly — an **opt-in** way to avoid element boxing without the
full monomorphization pass (issue #19). This is a consequence WasmBase unlocks, not a
requirement of this ADR.

## Consequences

- **#5 is resolved structurally.** Higher-order library functions become PureScript over
  WasmBase and ride the existing, fully general specialization — no per-function compiler
  code, no benchmarked-function privilege.
- **Versioning axis 2 is concentrated.** Per-package raw-wat ABI coupling collapses to a
  single, compiler-maintained contract. Packages depend on a WasmBase *version*, not on the
  raw GC layout.
- **WasmBase becomes the highest-stakes contract.** It is version-locked to the backend, so
  breaking it breaks everything above it. The central design work is choosing the
  **minimal-complete** primitive set: too small and authors fall back to raw wat (defeating
  the purpose); too large and both the stability burden and the ABI surface grow.
- **FFI-bearing core modules need parallel reimplementation.** Modules whose upstream
  source uses `foreign import` (`Data.Functor`'s `arrayMap`, `Data.Foldable`'s array folds,
  `Data.String`, …) must be rewritten as PureScript over WasmBase; their pure-PureScript
  parts are unchanged. This is a maintenance/fidelity cost with precedent (purerl maintains
  a parallel package set with Erlang FFI).
- **Adding a WasmBase type touches the marshalling glue.** A new primitive type (e.g.
  `IntArray`) that can cross to JS needs a marshalling rule (`IntArray ↔ Int32Array`/
  `number[]`). The glue and WasmBase share one type vocabulary and must evolve together —
  the single real coupling point between the two sanctioned paths.
- **Layering discipline is required.** WasmBase is for core-library implementors;
  application authors use `Prelude`/`arrays` (portable). Using WasmBase directly leaks
  non-portable representation into user code.
- **It does not solve element boxing (#19) by itself.** WasmBase enables specialization
  (cost (a)); polymorphic-element boxing (cost (b)) remains until monomorphization, except
  via the opt-in unboxed-container escape hatch above. The benchmarks show (b) dominates
  numeric workloads, so WasmBase is necessary but not sufficient for numeric parity.
- **`ulib` is repositioned, not retired.** Its first-order wat fragments move down into
  WasmBase; its higher-order/library logic becomes PureScript over WasmBase; the directory
  itself persists as a curated **WasmBase-based PureScript** collection of a small,
  project-maintained core (`strings`/`arrays`/`effect`/…). A full purerl-style package set
  is the eventual end-state but is a separate, larger effort, deliberately deferred — `ulib`
  remains the pragmatic middle ground until then.

## Alternatives considered

- **Per-foreign rewrite (specialize `arrayMap` & co. in the compiler).** Rejected: does not
  scale ("endless"), and special-casing the benchmarked functions is unfair and misleading.
- **Teach the optimizer to inline through foreigns.** Rejected as impossible in general: a
  foreign has no body to inline into. The only realizations are per-foreign templates
  (== special-casing) or a wasm-level partial evaluator (a bespoke wat inliner —
  unrealistic). The foreign boundary is, and should remain, a hard optimization barrier.
- **Keep higher-order operations in hand-written `ulib` wat.** Rejected: this is the
  optimization barrier (#5) *and* the axis-2 versioning fragility, in one place.
- **Packages ship raw wat FFI (purerl-style), no WasmBase.** Rejected as the default: every
  package's wat is then coupled to the moving backend ABI (axis 2). WasmBase concentrates
  that coupling into one compiler-maintained contract instead.
- **Do full monomorphization first (#19) instead.** Orthogonal and larger. Monomorphization
  addresses element boxing (cost (b)); WasmBase addresses the foreign barrier (cost (a)) and
  versioning. They compose; WasmBase is the smaller, enabling step and a prerequisite for
  "functional library code is fast".
- **Drop the JS fallback to simplify.** Rejected: it is the backend's distinctive
  convenience tier and an axis-2-decoupled FFI path. It coexists with WasmBase as the
  convenience end of the spectrum.

## References

- Issue #5 (foreign/ulib higher-order functions do not receive higher-order
  specialization) — the immediate motivation.
- Issue #19 (monomorphization / unboxing polymorphic container elements) — the orthogonal
  cost (b); composes with WasmBase's opt-in unboxed containers.
- Issue #12 (FFI closure direction 2) — bounds how closures cross the JS-fallback boundary.
- ADR 0012 (`ulib` curated-package wasm FFI) — **superseded by this ADR**: its
  hand-written-`.wat` mechanism and provider ladder are replaced; `ulib` persists but as
  WasmBase-based PureScript, and raw wat survives only inside WasmBase.
- ADR 0013 (int/number unboxing) — establishes that polymorphic element boxing needs
  monomorphization (out of scope there); WasmBase's unboxed containers are an opt-in
  partial answer.
- ADR 0014 / 0016 (user FFI resolution, marshalling, foreign-signature reconstruction) —
  the JS-fallback path and its marshalling glue.
- ADR 0020 (reduction-aware inliner) — foreign results are neutrals; reduction-awareness
  does not cross the foreign barrier.
- ADR 0011 / 0025 (packaging / `--platform`) — the packaging layer the eventual WasmBase
  package set plugs into.
- `Intrinsics.purs`, `runtime.wat`, `ulib/_header.wat` — the candidate primitive surface
  to be inventoried into WasmBase.

## Appendix: primitive inventory (2026-06-08)

The classification of the candidate surface (`Intrinsics.purs` `Intrinsic` /
`foreignIntrinsic` / `qualifiedIntrinsic`, `runtime.wat` exports, `ulib/*/foreign.wat`).
**Key finding:** most first-order primitives *already exist* in `runtime.wat`; they are
simply not surfaced as PureScript-callable intrinsics. WasmBase is largely "promote existing
runtime helpers to recognized intrinsics", not new implementation.

Status legend — ✅ existing intrinsic · 🔌 present in `runtime.wat` but not exposed to PS
(surface work) · ✂️ reshape to a first-order shape.

### A. First-order primitives → WasmBase (provisional modules)

**`Wasm.Array`** — `{unsafeNew, unsafeSet, unsafeIndex, length}` is sufficient to write
`map`/`foldl`/`filter`/… in PureScript (`$Vals` is mutable; no `freeze` needed — fill, then
return as `Array`).

| primitive | intrinsic | runtime | arity | status |
| --- | --- | --- | --- | --- |
| `length :: Array a -> Int` | `ArrayLength` | `arrayLen` | 1 | ✅ |
| `unsafeIndex :: Array a -> Int -> a` | `ArrayIndex` | `arrayGet` | 2 | ✅ |
| `unsafeNew :: Int -> Array a` | — | `arrayNew` | 1 | 🔌 **key enabler** |
| `unsafeSet :: Array a -> Int -> a -> Unit` | — | `arraySet` | 3 | 🔌 **key enabler** |
| `concat :: Array a -> Array a -> Array a` | `ArrayConcat` | `arrayConcat` | 2 | ✅ (PS-able) |

**`Wasm.String`** (UTF-8 bytes) — `{byteLength, byteAt, unsafeNew, unsafeSetByte}` is the
build/read core.

| primitive | intrinsic | runtime | arity | status |
| --- | --- | --- | --- | --- |
| `byteLength :: String -> Int` | `StrLen` | `strLen` | 1 | ✅ |
| `byteAt :: String -> Int -> Int` | — | `strByteAt` | 2 | 🔌 |
| `unsafeNew :: Int -> String` | — | `strNew` | 1 | 🔌 **key enabler** |
| `unsafeSetByte :: String -> Int -> Int -> Unit` | — | `strSetByte` | 3 | 🔌 **key enabler** |
| `concat`/`compare`/`eq` | `StrConcat`/`OrdString`/`StrEq` | `strConcat`/`strCmp`/`strEq` | 2 | ✅ (PS-able) |

**`Wasm.Record`** (String-keyed; label ids interned by codegen) — all inherently primitive,
keep: `unsafeGet`/`unsafeHas`/`unsafeSet`/`unsafeDelete` (✅ `UnsafeGet`/`Has`/`Set`/`Delete`
↔ `proj`/`recHas`/`recSet`/`recDelete`) + `empty` (`recEmpty`).

**`Wasm.Ref`** — `new`/`read`/`write` (✅ `RefNew`/`Read`/`Write` ↔ `refNew`/`refRead`/
`refWrite`). `modify`/`newWithSelf` are excluded → PureScript (see B).

**Scalars** (all ✅): `Wasm.Int` (add/sub/mul/div/mod/degree, eq, compare ✂️, toNumber,
top/bottom, fromNumber ✂️); `Wasm.Number` (add/sub/mul/div, eq, compare ✂️, toInt,
top/bottom = ±Inf); `Wasm.Char` (top/bottom, shares `Int` rep); `Wasm.Boolean`
(and/or/not, eq, compare ✂️).

### B. Move to PureScript (HOFs / closure-applying) → repositioned `ulib`

| item | why | written in PS as |
| --- | --- | --- |
| `forE`/`foreachE`/`whileE`/`untilE` | take a body/cond closure | PS recursion over the primitives |
| `Ref.modify`/`newWithSelf` | apply `f` | PS over `new`/`read`/`write` |
| `arrayMap`/`foldlArray`/`foldrArray`/`arrayApply`/`arrayBind`/`eqArrayImpl`/`ordArrayImpl` | ulib HOFs | PS recursion over `Wasm.Array` (this is the #5 fix) |
| `mkFnN`/`runFnN`/`mkEffectFnN`/`runEffectFnN` | closure-ABI bridge (here: identity + ordinary application) | PS over `unsafeCoerce` + application |
| `_unsafePartial` | `f unit` | PS |
| ulib first-order library fns (`reverse`/`slice`/`range`/`show*Impl`/`intercalate`/CodeUnits) | library code, not primitives | PS over `Wasm.Array`/`Wasm.String` |

### C. Internal — not public WasmBase API

- `boxInt`/`unboxInt`, `boxNum`/`unboxNum`, `boxBool`/`unboxBool` — the representation
  contract itself, but emitted by codegen, never called from PS.
- `applyClo` (`callClo1`) — the closure-call primitive codegen emits for ordinary
  application; not PS-facing.
- `IncrCtr`/`ReadCtr` — test-only (`Counter`). Excluded.

### D. Work required (small) + reshapes

- **Surface (🔌):** make `arrayNew`/`arraySet`, `strNew`/`strSetByte`/`strByteAt`
  recognized intrinsics (new `Intrinsic` constructors + `genPrim` cases + a WasmBase PS
  module of `foreign import`s). This alone unblocks writing the HOFs in PureScript.
- **Reshape (✂️):**
  - `Ord*` 5-operand `lt eq gt x y` → 2-operand `compare :: a -> a -> Int` (-1/0/1); the
    `Ordering` selection moves to PureScript. Drops the "pass the three `Ordering` values"
    encoding.
  - `fromNumberImpl just nothing n` (applies `just`/`nothing` — effectively higher-order) →
    a first-order primitive (return `{ ok, value }` or a sentinel); the `Maybe` wrapping
    moves to PureScript.

### E. Conclusion

The minimal-complete first-order set is ≈ 6 groups (Array ×4, String ×4, Record ×5, Ref ×3,
scalar families). Most already exist; the only real gap is exposing `arrayNew`/`arraySet`
(and `strNew`/`strSetByte`/`strByteAt`). The current intrinsic table mixes these primitives
with HOFs (the `forE` family, `Ref.modify`, the `Fn`/`EffectFn` families, `_unsafePartial`,
the ulib HOFs) and reshape candidates (`Ord*`, `fromNumberImpl`); this inventory fixes that
split.
