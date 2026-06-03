# 0014. User FFI: a foreign-provider ladder and the JS marshalling boundary

- Status: Proposed
- Date: 2026-06-03

## Context

ADR 0002 resolves a `foreign import` through a code-generator **intrinsics table**
(`foreignIntrinsic`): a closed, compiler-baked set (`intAdd`, `boolDisj`, `strLen`,
…). A foreign identifier *not* in that table is today a hard compile error —
`Lower` throws `UnsupportedExpr ("unapplied top-level reference: …")`. That is fine
for the current milestone (compile modules that depend only on `Prelude`, whose
foreigns are all curated into the table or the runtime), but it is the wall between
this backend and **running real programs**:

- A user's own `foreign import` (their package's `.js`) cannot be called at all.
- `Effect` — and `ST`, `Ref`, etc. — are *implemented in PureScript via FFI*; their
  runtime bottoms out in `foreign import`s. So there is no `Effect` without user FFI.
- The long tail of ecosystem packages each ship `.js` foreigns the compiler must be
  able to resolve.

PureScript keeps the **compiler minimal**: a package ships its own foreign `.js`,
and the JS backend resolves a foreign from *that* file, not from the compiler. A
wasm backend has no `.wasm` shipped by packages, so it must supply equivalents
(ADR 0012's `ulib` is the in-repo precursor to a wasm package set).

Two earlier ADRs already framed the answer but stopped short of the mechanism:

- **ADR 0011** decided that for `Effect` / user FFI, **host imports are mandatory and
  correct** ("there is no in-wasm alternative to a host call"), that this is a
  *packaging-stage* concern selected by `--platform`, and that **the ADR 0002
  `ForeignProvider` seam is exactly where a foreign resolves to an intrinsic, a
  runtime helper, or a host import.**
- **ADR 0012** introduced `ulib/<Module>/` as the home for per-module `.wat`/`.wasm`
  foreign implementations, linked like the runtime (ADR 0010).

What is **not** yet decided, and what this ADR settles:

1. *How* a foreign resolves when it is neither an intrinsic nor a runtime helper —
   the order in which a wasm-provided and a JS-provided implementation are tried.
2. *How values cross the wasm↔JS boundary.* This is the crux. Our values are
   wasm-GC objects (`$Str`, `$Int`, `$ADT`, `$Clo`, …; ADR 0001/0004). A JS foreign
   such as `log :: String -> Effect Unit` is handed a `$Str` **struct that JS cannot
   introspect**. Calling JS therefore requires a value-marshalling layer — the same
   boundary the host-interop direction (calling *into* wasm from JS) needs.

## Decision

### A foreign-provider ladder

Generalise ADR 0002's `ForeignProvider` seam from a single table into an ordered
**resolution ladder**. For a `foreign import` identifier, the first provider that
supplies it wins:

```text
1. intrinsic table        (ADR 0002 — i32.add, boolDisj, …; native, inlined)
2. wasm/wat foreign        (ulib/<Module>/ or a user foreign.{wasm,wat}; native, merged)
3. JS foreign              (foreign.js — emitted as a host import + marshalling glue)
4. trap / compile error    (no provider found)
```

The intrinsic table stays **on top**, so curated/performance-critical foreigns
remain native and inlined; nothing about existing builds changes. Resolution is
**per-foreign** and may depend on `--platform` (ADR 0011) — e.g. a heavy *pure*
primitive may be a wasm provider on `standalone` and a host import on `browser`.

Foreign modules are **discovered** alongside each module's `corefn.json` /
`externs.cbor` in the input directory (and under `ulib/` for curated packages),
mirroring how the JS backend finds a package's shipped `.js`: for module `M`, look
for `foreign.wasm` / `foreign.wat`, else `foreign.js`.

### Two backends, one seam

- **wasm/wat provider** speaks the *internal* ABI directly (`eqref`, `$Str`, `$Int`,
  the runtime types) and is linked with `wasm-merge` (ADR 0010/0012). **No
  marshalling**, and the artifact **stays a single self-contained `.wasm`**. This is
  the path for `ulib` and any performance-critical foreign. Authoring is expert-only
  (hand-written wat against the runtime types) — acceptable for curated code.

- **JS provider** is emitted as a wasm **host import**, satisfied at instantiation by
  a generated **JS loader** that supplies the import object and **marshals values at
  the boundary**. This is the ergonomic path: a user (or an existing package) writes
  ordinary JS, exactly as in the stock PureScript backend, and it Just Works as a
  fallback when no wasm provider exists.

The JS path is what unlocks the existing ecosystem (use packages' `.js` foreigns
unchanged); the wasm path is what keeps the hot/curated ones native and
self-contained. The ladder is the bridge between them.

### The marshalling boundary, introduced in layers

Define the wasm↔JS value correspondence per type, rolled out **scalars-first** so an
end-to-end FFI call works early and the hard part is de-risked incrementally:

- **L1 — scalars (first):** `Int` ⇄ JS `number` (`i32`), `Number` ⇄ `number` (`f64`),
  `Boolean` ⇄ `boolean` (`i31`), `Char` ⇄ a code-point `number`. These cross (almost)
  directly; the glue is trivial. A numeric foreign (`foreign import cos :: Number ->
  Number`) is the first end-to-end target.
- **L2 — `String`:** `$Str` ⇄ JS `string`, via **exported runtime accessors** — the
  glue reads a `$Str` with `strLen`/`strByteAt` to build a JS string, and builds a
  `$Str` from a JS string via an exported constructor. (These primitives already
  exist in the runtime.)
- **L3 — `Array` / record / closure (later):** `Array` ⇄ `[]` (**done** — recursive
  element marshalling via `arrayLen`/`arrayGet`/`arrayNew`/`arraySet`), record ⇄
  object (**done** — field-by-field, each field recursing into its own kind; the glue
  reads with `proj` and builds from `recEmpty` via `recSet`, keying on `internStr`
  applied to the type's field names), closure ⇄ JS `function` (a `call_ref`
  trampoline, possibly passing PureScript closures to JS as opaque references the glue
  can re-enter; still later). `Object a` (dynamic string keys) is **deferred** — its
  representation differs from a static-label `$Rec` and needs a separate decision.
  Each is additive.

The marshalling glue is **generated JS** that calls exported runtime helpers; it is
the same machinery the reverse direction (host calling wasm exports with real values)
will reuse, so the investment is not JS-FFI-specific.

### Rollout (the agreed sequencing)

1. The **resolver + foreign-module discovery** (the ladder itself), with the
   intrinsic table as provider #1 unchanged.
2. The **JS provider**: host-import emission + JS loader + **L1 scalar marshalling**,
   proven end-to-end on a numeric foreign; then **L2 strings**.
3. The **wasm/wat provider** (merged like `ulib`), with JS as the fallback.
4. `Effect` support and `ulib` growth proceed on top, in parallel, as the foreigns
   they need become resolvable (a separate ADR for `Effect`'s representation).

## Consequences

- **Unblocks the capability frontier:** user `foreign import`s, the package long
  tail, and (via its foreigns) `Effect`/`ST` all become expressible. This is the step
  from "beats JS on pure microbenchmarks" to "runs real programs".
- **The intrinsics table is generalised, not superseded:** ADR 0002 remains provider
  #1; it is now the top of a ladder.
- **Self-containedness is conditional:** a program using only intrinsic/wasm
  providers stays a single `.wasm`; a program using any JS provider becomes
  `app.wasm + runtime + a generated JS loader` (the ADR 0011 host-import packaging) —
  host imports have no in-wasm alternative.
- **A real marshalling boundary is introduced** — the genuine cost of this work. It
  is scoped by the L1/L2/L3 layering so it lands incrementally rather than as a
  monolith; the runtime's existing string/array primitives are reused as the glue's
  exported accessors.
- **A packaging stage is now load-bearing:** when host imports exist, the build emits
  a JS loader and wires the import object (`{ rt: …, M: foreignModule }`),
  `--platform`-selected (ADR 0011).

## Alternatives considered

- **JS-only FFI (no wasm provider).** Simplest, and matches the stock PureScript
  ergonomics. Rejected as the *whole* answer: every foreign would become a host
  import, so no program is ever self-contained and a performance-critical or curated
  foreign (`ulib`'s `Prelude`) could never be native wasm. We keep JS as the
  *fallback*, not the only path.
- **wasm/wat-only FFI (no JS provider).** Keeps everything self-contained and fast,
  but forces *every* foreign to be hand-written wat — the entire existing ecosystem of
  `.js` foreigns would be unusable without a rewrite. Rejected: the barrier defeats
  "run real programs"; the JS fallback is precisely what removes it.
- **Marshal all types up front (L1–L3 at once).** Rejected: the boundary is the hard
  part. Scalars-first gets a working end-to-end FFI call and lets strings, arrays,
  and closures land as separate, individually-verifiable slices.
- **Opaque references only (no marshalling): JS holds wasm-GC refs and calls back
  into exported accessors.** Viable and avoids per-type conversion, but forces JS
  authors to use exported accessors instead of native JS `string`/`[]`, which is
  un-idiomatic and breaks drop-in use of existing `.js` foreigns. We prefer boundary
  marshalling for idiomatic JS, while still using opaque references where they fit
  (e.g. passing a PureScript closure to a JS callback).
