# 0002. FFI via a code-generator intrinsics table

- Status: Accepted
- Date: 2026-05-31
- See also: [ADR 0012](0012-ulib-curated-package-ffi.md) — evolves tiers 2/3 (the
  bundled-runtime / higher-order foreigns) into manifest-driven `ulib` FFI, keeping
  tier 1 as the inline-intrinsics table.

## Context

`Prelude`'s primitives (arithmetic, comparisons, boolean logic, `show`,
string/array operations, record access) are defined as `foreign import`s with
JavaScript implementations. A wasm backend cannot use those `.js` files, so it
must provide its own implementations of the same names.

The Prelude foreign surface was measured directly (prelude 6.0.2): it is a
**closed set of ~45 functions**, in a few clear groups:

- **Scalar machine ops**: `intAdd/Sub/Mul/Div/Mod/Degree`,
  `numAdd/Sub/Mul/Div`, `boolConj/Disj/Not`, `eq{Int,Char,Boolean,Number}Impl`,
  `ord{...}Impl`, `top/bottom{Int,Char,Number}`.
- **String runtime**: `concatString`, `eqStringImpl`, `ordStringImpl`,
  `show{Int,Number,Char,String}Impl`, `intercalate`.
- **Higher-order array**: `arrayMap/Bind/Apply`, `concatArray`,
  `eqArrayImpl`, `ordArrayImpl`, `showArrayImpl`.
- **Record primitives**: `unsafeGet/Set/Has/Delete`.
- **Erasure**: `unsafeCoerce`, `unit`, `Unit`.

## Decision

Implement foreign functions as a **code-generator-internal intrinsics table**
(`Qualified Ident -> CodeGen`), in three tiers:

1. **Inline instructions** — e.g. `intAdd → i32.add`, `numMul → f64.mul`,
   `eqIntImpl → i32.eq`. Emitted directly at the call site. `intDiv`/`intMod`
   must honour PureScript's truncate-toward-zero / remainder semantics.
2. **Bundled runtime functions** — e.g. `showIntImpl`, `concatString`,
   `intercalate`, `eqStringImpl`. Emitted once into a "prelude runtime"
   section of the module and called as ordinary wasm functions.
3. **Higher-order array functions** — `arrayMap` etc., implemented on top of
   the runtime and the closure representation (see ADR 0001).

Expose a single extension seam, `ForeignProvider :: Qualified Ident -> Maybe
CodeGen`, so user-defined or platform-specific foreign implementations can be
plugged in later without changing the core.

`showNumberImpl` (IEEE-754 double → shortest decimal string) is the hardest
item and may be left unimplemented in early milestones.

## Consequences

- The whole Prelude foreign surface is satisfied inside the produced module —
  consistent with the "single wasm" goal, with no host imports.
- No general wasm linker is needed now; the closed Prelude set is handled by
  construction.
- Each new foreign name needs an explicit entry — acceptable for a closed,
  audited set; the `ForeignProvider` seam keeps it open for growth.

## Alternatives considered

- **Host imports** (the host supplies `intAdd`, etc.). Rejected: breaks the
  single-wasm goal and adds per-call boundary overhead.
- **General wasm-module bundling / static linking** (`wasm-ld` or Binaryen
  module merge of per-FFI wasm objects). Over-engineered for a closed ~45-fn
  set; revisit when real user-defined FFI arrives.
