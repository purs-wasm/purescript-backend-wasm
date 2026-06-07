# 0003. Intermediate IR between CoreFn and Binaryen

- Status: Accepted
- Date: 2026-05-31

> **Correction (2026-06-07):** The eval/apply machinery did **not** adopt PAP/`applyN`. Per [ADR 0004](0004-uniform-eqref-calling-convention.md) ("everything eqref, arity-1 closures"), partial/over-application is handled by an **arity-1 `RApply` chain** (no PAP struct, no `applyN`). `Atom` is per-type literals (`ALitInt`/`ALitNumber`/`ALitBoolean`/`ALitString`) + `AVar (Local | EnvField)` (**no `Global`**; top-level names go through `RCallKnown`/nullary functions). The ANF, closure-conversion, and decision-tree core still holds (in `Lower/IR` and `Lower/Match`).

## Context

CoreFn is type-erased, fully curried, and keeps nested `let`/`case`
expressions. Generating Binaryen (Wasm GC) directly from it would force three
hard transforms to happen at once, interleaved with code emission:

- **Closure conversion** — make each lambda's free variables an explicit
  captured environment, and distinguish known top-level functions from
  first-class closures.
- **Representation choice** — decide which values are unboxed (`i32`/`f64`)
  and which are boxed (`eqref`, per ADR 0001), and place the coercions.
- **Pattern-match compilation** — turn a CoreFn `Case` (multiple scrutinees,
  nested binders, guards) into tag tests, field projections, and literal
  comparisons.

Doing all of this inline with emission is hard to get right and hard to
optimize. We also need to decide how curried application is compiled — the
central performance question for a higher-order functional language.

## Decision

Introduce **one thin intermediate IR** between CoreFn and Binaryen. The
CoreFn → IR lowering performs closure conversion (with lambda lifting),
pattern-match compilation, slot resolution, and representation annotation, so
that IR → Binaryen is a near-mechanical lowering.

### Form: A-normal form (ANF)

The IR is let-normalized: every non-trivial intermediate is named by a `Let`.
This maps directly onto wasm locals, makes free-variable computation (hence
closure conversion) trivial, and gives a natural place to attach
representation annotations. Sketch:

```purs
Program  = { funcs :: Array IRFunc, values :: Array CAF, exports :: ... }
IRFunc   = { name, params :: Array Slot, env :: Array Slot, body :: Block }

Atom = ALit Literal | AVar (Local Slot | EnvField Int | Global Name)  -- trivial, duplicable

Block            -- A-normal form
  = Ret    Atom
  | Let    Slot Rhs Block
  | LetRec (Array (Slot /\ Alloc)) Block          -- knot-tying
  | Switch Atom (Array Branch) (Maybe Block)      -- decision-tree node

Rhs              -- may allocate / call; result is named by the Let
  = RPrim       Intrinsic (Array Atom)            -- ADR 0002 tier-1/2
  | RCallKnown  Name (Array Atom)                 -- saturated direct call
  | RApply      Atom (Array Atom)                 -- generic curried apply
  | RMkClosure  Name (Array Atom) | RMkData Int (Array Atom) | RMkRecord ...
  | RProjField  Atom Int | RProjLabel Atom Label
  | RBox Rep Atom | RUnbox Rep Atom               -- explicit representation coercions
```

Each `Slot` carries a `Rep` annotation (`Boxed | I32 | F64 | I31`) so the code
generator can assign wasm types unambiguously.

### Pattern matching: compiled to a decision tree in the IR

CoreFn `Case` is lowered to `Switch`/nested tests during CoreFn → IR. The
initial algorithm is a simple sequential/backtracking automaton (correct and
simple); column-selection optimization (Maranget-style) is deferred.

### Curried application: eval/apply (not push/enter)

Compile curried application with the **eval/apply** model:

- When the callee and its arity are statically known and the call site is
  **saturated**, emit a native multi-argument `call` / `call_ref`
  (`RCallKnown`). No intermediate closures, no partial-application object, no
  dispatch. This is the common case (e.g. essentially all of Prelude).
- ~~Only **arity mismatches** go through a generic `applyN` family (`RApply`):~~
  - `args == arity` → `call_ref` once;
  - `args < arity` → allocate a partial-application (PAP) object;
  - `args > arity` → call with `arity` args, then apply the remainder (loop).

In Wasm GC: a closure is `(struct (field arity i32) (field (ref $Codek))
captured…)` where `$Codek = (func (param (ref $Clo) a1 … ak) (result eqref))`;
~~a PAP is `(struct (field (ref $Clo) orig) (field (ref $Vals) saved))`.~~
Tail calls use `return_call`/`return_call_ref`.

The CoreFn → IR lowering may start conservative (route more calls through
`RApply`) and grow the saturated-call analysis incrementally; both nodes exist
in the IR from the start so doing so requires no IR redesign.

### Recursion

Top-level functions become module functions that call each other by name (no
closure unless they capture). Mutually recursive local bindings (`Rec`) are
lowered to `LetRec`: allocate the closure/data structs first with mutable
environment fields left null, then back-patch them to tie the knot (per ADR
0001). Top-level non-function bindings (CAFs) are emitted in initialization
order; because PureScript is strict, genuinely recursive non-function CAFs are
not expressible and need no special support.

## Consequences

- IR → Binaryen becomes a straightforward lowering; the three hard transforms
  are isolated, independently testable passes.
- The saturated common case compiles to native wasm calls with zero
  curry/closure overhead — capturing the efficiency goal of curried calling
  conventions while fitting wasm's fixed-arity, validated call instructions.
- ANF adds a normalization pass and more verbose IR than a tree form — an
  accepted cost for the downstream simplicity.
- A genuine partial application still allocates a PAP; this is intrinsic to
  curried languages and is not specific to eval/apply.

## Alternatives considered

- **Push/enter (the ZINC abstract machine, Leroy 1990).** Arguments are pushed
  onto a shared argument stack and the callee `grab`s as many as it needs,
  avoiding intermediate closures for saturated curried calls. Its *goal* is
  desirable, but its *mechanism* assumes a variable number of arguments on a
  shared stack — which wasm's fixed-arity, type-checked calls cannot express
  without abandoning native calls in favour of a self-managed argument stack +
  trampoline, losing native calling convention, `return_call`, and host GC
  stack maps. eval/apply achieves the same saturated-case efficiency while
  using native calls. This matches the conclusion of Marlow & Peyton Jones,
  *"Making a Fast Curry: Push/Enter vs. Eval/Apply for Higher-order
  Languages"* (JFP 2006), and applies even more strongly on wasm. Worth
  revisiting only if the backend ever moves to a threaded interpreter or a
  custom stack VM.
- **No intermediate IR (emit Binaryen directly from CoreFn).** Rejected:
  forces closure conversion, representation selection, and pattern-match
  compilation to be interleaved with emission.
- **Tree-shaped IR (not ANF).** Binaryen accepts tree expressions, but ANF's
  explicit naming maps better to locals and simplifies closure conversion and
  representation annotation.

## References

- X. Leroy, *The ZINC experiment: an economical implementation of the ML
  language*, INRIA TR 117, 1990. <https://xavierleroy.org/publi/ZINC.pdf>
- S. Marlow, S. Peyton Jones, *Making a Fast Curry: Push/Enter vs. Eval/Apply
  for Higher-order Languages*, JFP 16(4–5), 2006.
