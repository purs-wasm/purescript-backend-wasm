# 0012. A `ulib` directory for curated-package wasm FFI

- Status: Proposed
- Date: 2026-06-02

## Context

`runtime/runtime.wat` (ADR 0010) currently conflates two concerns:

- **(A) the backend's runtime *system*** — the GC value-type group, the
  closure-call helpers (`$callClo*`), record projection (`$proj`). Code generation
  emits / relies on these for *language* features (closures, records, ADTs),
  independent of any user library.
- **(B) *library* foreign implementations** — `show*`, `str*`, `array*`,
  `intMod`/`intDiv`, `Record.Unsafe`'s `rec*`, `intercalate`, plus the Dragon4 /
  bignum machinery only `showNumber` uses. These implement *specific packages'*
  `foreign import`s.

In fact most of `runtime.wat` is (B).

`Prelude` is, conceptually, a user package. PureScript keeps the **compiler
minimal**: the JS backend resolves a package's foreigns from the `.js` files that
*package* ships, not from the compiler. A wasm backend has no `.wasm` shipped by
packages, so it must supply the equivalents — but bundling all of them into the
compiler's runtime conflicts with that minimal-compiler ethos.

The eventual "proper" answer is a **wasm package set** where each package carries
its own `.wat` / `.wasm` FFI — the model the Erlang backend (`purerl`) uses, with an
Erlang-flavoured package set that includes `Prelude`. That needs package / registry
/ versioning infrastructure this PoC does not have.

## Decision

Introduce a top-level **`ulib/`** directory: the in-repo, curated home for the wasm
FFI of the common, quasi-stdlib packages (`Prelude` first), organised **per source
module** (`ulib/<Module.Name>/`). It is the precursor to a wasm package set, without
that infrastructure now.

Split the two concerns:

- **`runtime/` keeps the runtime *core*** (A): the value-type group, `$callClo*`,
  `$proj`, and any genuinely shared low-level helper. Always linked.
- **`ulib/<Module>/` holds the library foreigns** (B), one `.wat`/`.wasm` per source
  module — the wasm equivalent of the `.js` the JS backend ships per package.
  `ulib` modules may depend on the runtime core; the dependency is one-way
  (`ulib → runtime-core`).

Shared GC types: each `ulib` module declares the rec-type group as singletons so
they canonicalize identically (ADR 0010), factored through a **shared header
fragment** so the declarations are authored once, not copy-pasted into every module.

**Compiler-side foreign resolution becomes manifest-driven with a small retained
inline table** — the `purs-backend-es` model, and a formalisation of ADR 0002's
three tiers + `ForeignProvider` seam:

- **Inline-intrinsics table (kept, small):** the true machine primitives that must
  be *inlined*, not called — `intAdd → i32.add`, `intSub`, `intMul`,
  `eqIntImpl → i32.eq`, the boolean ops, … (ADR 0002 tier 1).
- **Manifest (everything else):** a data mapping `foreign ident → ulib module +
  symbol`, from which code generation emits an import + call. Adding a curated
  package's foreign becomes "drop a `.wat` into `ulib/<Module>/` and add a manifest
  entry" — no compiler code change.

Build / link:

- Assemble each `ulib` module's `.wat` → `.wasm` (alongside the runtime core).
- `bin` links per program: from the CoreFn imports it knows which modules a program
  uses and `wasm-merge`s only those `ulib` modules plus the runtime core
  (package-level selection, complementing Binaryen's function-level DCE). The test
  harness instantiates the needed set.

### Slicing (incremental, each step behaviour-neutral)

1. **Reorganise only.** Carve `runtime.wat` into the runtime core +
   `ulib/<Module>/`, establishing the (A)/(B) boundary and the shared type header.
   Keep the build merging *everything* for now (selective linking deferred); the
   whole suite stays green.
2. **Selective linking.** `bin` / the harness merge only the `ulib` modules a
   program uses; add the module → `.wasm` map.
3. **Manifest-driven mapping.** Replace the hardcoded runtime-call entries of the
   intrinsics table with the manifest, keeping only the inline table.

## Consequences

- Aligns with PureScript's minimal-compiler ethos: the compiler stops *being* the
  `Prelude` runtime; `ulib` is curated FFI, separable later into real packages.
- A clean seam for **curated-package growth** (the README WIP item "Additional
  builtin support for curated packages (strings, arrays, records, …)"): new packages
  are additive `ulib` modules + manifest entries, not compiler edits.
- Per-package link selection on top of Binaryen's DCE; the inline table stays small
  and principled.
- More moving parts than one `runtime.wat`: N modules to assemble, a shared type
  header, a manifest, a richer link step. The slicing keeps each step testable.
- Extends ADR 0010's "two sources of truth for the rec group" to N (each `ulib`
  module); the shared header fragment contains that duplication.

## Alternatives considered

- **Keep the monolithic `runtime.wat`.** Simple, but conflates the runtime system
  with library FFI and scales poorly to curated packages and the minimal-compiler
  goal.
- **A full wasm package set now (`purerl` model).** The proper end-state, but needs
  package / registry / versioning infrastructure out of scope for a PoC. `ulib` is
  the in-repo precursor that can migrate there later.
- **Keep the intrinsics table fully hardcoded.** Every curated foreign needs a
  compiler edit; does not scale. (The inline table is retained only for the true
  machine primitives.)

## References

- ADR 0002 (FFI via an intrinsics table) — the three tiers + `ForeignProvider` seam
  this refines: tier 1 stays as the inline table; tiers 2/3 move to `ulib`, resolved
  by manifest.
- ADR 0010 (runtime as a separate wasm module) — the import / `wasm-merge` model and
  the singleton-type canonicalization that `ulib` modules reuse.
- `purerl` (PureScript Erlang backend) — an Erlang package set carrying `Prelude`;
  the eventual package-set model.
- `purescript-backend-optimizer` (`purs-backend-es`) — a small inlined-intrinsics
  set plus per-package JS FFI.
