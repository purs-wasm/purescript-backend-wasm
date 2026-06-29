# 0033. Shipping `ulib` as precompiled MIR (`.pmo`) artifacts

- Status: ~~Proposed~~ **Superseded by [0040](0040-global-content-addressed-library-cache.md)** _(2026-06-20: generalized from "ship ulib's `.pmo`" to a global content-addressed cache of the whole library closure's `.pmi`/`.wasm`/`.link.json`; `.pmo` itself is retired now the `.pmi` summary + `.wasm` object are the real artifacts.)_
- Date: 2026-06-15

> **Note (2026-06-15):** Phase 4 shipped as a **`.pmi` interface + `.pmo` object** pair
> ([ADR 0034](0034-pmi-interface-pmo-object-split.md)), not the single `.pmo` this record assumes.
> When this is implemented, shipped `ulib` artifacts use that same pair (the `.pmi` carrying the
> version-stamp key in place of a source hash); read "`.pmo`" below as "the `.pmi`/`.pmo` pair".
> The local incremental cache (ADR 0034) already reuses unchanged `ulib` modules on a warm build;
> what this record still adds is precompiled distribution so the **first / cold** build skips
> `ulib` too.

## Context

`ulib` is the compiler-bundled library layer ([ADR 0031](0031-ulib-unified-library-modules.md),
[ADR 0029](0029-ulib-lib-distribution-and-purs-pinning.md)): a curated, **version-pinned**
set of registry modules (`Data.Array`, `Data.Foldable`, `Data.Functor`, `Data.Show`,
`Data.String.*`, …) shipped *as `.purs` source* (plus hand-written `.wat` foreign providers),
listed in `ulib-manifest.json`. On every user build these sources are compiled by the pinned
`purs` to `corefn.json`, then **decoded and run through the whole middle-end** (translate →
specialize → simplify / dict-elim / inline / impurify) alongside the user program.

`ulib` is the one dependency that is present in **every** build. So that per-build
"compile `ulib` from source" cost — the pinned-`purs` invocation *and* the backend's
decode + optimize of every `ulib` module — is paid unconditionally, cold and warm alike.

Two recent decisions make that cost removable:

- [ADR 0032](0032-caller-homed-specialization-for-incremental-builds.md) made a module's
  optimized MIR a **pure function of `(its corefn, its dependency summaries)`** — no upward
  or whole-program dependency. A module's optimized output no longer depends on the user
  program that consumes it.
- [ADR 0032](0032-caller-homed-specialization-for-incremental-builds.md) phase 4 introduces
  the **`.pmo`** file (`MiddleEnd.Serialize`): a compact binary encoding of a module's
  optimized MIR, the body of a per-module incremental-build cache.

`ulib` is a **closed, version-pinned set**: its modules depend only on each other, `Prim`,
and `WasmBase` ([ADR 0026](0026-wasmbase-primitive-layer.md)). So every `ulib` module's
dependency summaries are fixed at `ulib` *release* time — its optimized MIR can be computed
**once**, when `ulib` is built, and shipped. This ADR records that intent; it is the natural
endpoint of the `.pmo` work and arguably its larger payoff (it speeds cold builds too, not
just warm rebuilds).

## Decision

**Ship each `ulib` module's optimized MIR as a precompiled `.pmo`, built once at `ulib`
release time with the pinned `purs`, and load it directly at user-build time — skipping the
`purs` compile, decode, and middle-end for `ulib`.** Distribute, per `ulib` module:

- its `.pmo` (optimized MIR body), and
- the **representation information lowering still needs** — see *Companion artifact* below,

retaining the existing `.wat` foreign providers unchanged.

### Trust model: version-pinned, not source-hashed

The local incremental cache ([ADR 0032](0032-caller-homed-specialization-for-incremental-builds.md)
phase 4) validates a `.pmo` by **re-hashing the user's `corefn.json`** against the header
key. A *shipped* `ulib` `.pmo` has no user-local source to re-hash — it is a distribution
artifact, trusted like a precompiled `.cmi`. Its validity is tied to the **`ulib` /
`purs-wasm` version** (and the `.pmo` format version): the body codec is identical, but the
header key is a **version stamp** rather than a corefn hash. A version mismatch (an upgraded
`purs-wasm`, a re-released `ulib`, or a bumped `.pmo` format) invalidates the shipped set,
which is re-shipped — not recompiled on the user's machine.

### Companion artifact: the rep table

Lowering reads `ctorFieldReps` from `externs.cbor` for **every reachable module** to unbox
concrete scalar fields ([ADR 0013](0013-int-number-unboxing.md)). A `.pmo` alone does not
carry this, so shipping only `.pmo` would silently box `ulib`'s ADT fields (a perf
regression). The distribution must therefore **also ship the rep information** — either
`ulib`'s `externs.cbor`, or a distilled per-constructor rep table — alongside each `.pmo`.
(A later refinement could fold the rep table into the `.pmo` so `ulib` needs no separate
externs; out of scope here.)

## Consequences

- **Every build skips `ulib`'s front + optimize.** No pinned-`purs` run for `ulib`, no
  decode, no middle-end — `ulib` modules are loaded as MIR. Cold and warm builds both
  benefit (unlike the user-source cache, which helps only warm rebuilds).
- **Lowering, codegen, and DCE stay whole-program.** `.pmo` is *pre-lowering* MIR, so
  `ulib` functions are still lowered, representation-analyzed, and reachability-pruned
  together with the user program each build (the cheap, monotone re-derivation
  [ADR 0032](0032-caller-homed-specialization-for-incremental-builds.md) keeps
  whole-program). Unused `ulib` is still tree-shaken ([ADR 0009](0009-build-and-linking-model.md)).
- **Caller-homed specialization is unaffected.** User → `ulib`-worker specializations are
  homed in the *consuming* user module
  ([ADR 0032](0032-caller-homed-specialization-for-incremental-builds.md)); the `ulib`
  `.pmo` only carries the worker bodies. The dependency **summaries** user modules
  specialize / inline against are re-derived from the loaded `.pmo` by `DictElim.summarize`
  (a pure function of the optimized module), so nothing extra need be shipped for that.
- **Reuses the `.pmo` infrastructure.** This is "a pre-populated, shipped cache": it needs
  the codec and cache-load path from
  [ADR 0032](0032-caller-homed-specialization-for-incremental-builds.md) phase 4, plus the
  version-stamp header variant and the rep companion. No second mechanism.
- **`ulib` release gains a precompile step.** Building `ulib` now also emits `.pmo` + rep
  tables (with the pinned `purs`), and `ulib-manifest.json` / packaging grows to list them.

## Alternatives considered

- **Keep shipping `.purs` (status quo).** Simplest, but pays the pinned-`purs` compile +
  decode + optimize of `ulib` on every build, forever — the cost this ADR removes.
- **Ship `ulib` `corefn.json` instead of `.purs`.** Drops only the pinned-`purs` invocation;
  the backend still decodes and re-optimizes `ulib` every build. A strict subset of the win.
- **Ship `ulib` as prebuilt lowered wasm fragments and link them.** Rejected for the same
  wasm-GC type-sharing reasons as [ADR 0009](0009-build-and-linking-model.md) /
  [ADR 0021](0021-streaming-dependency-ordered-wpo.md): per-module separate wasm forfeits
  cross-module representation choices and whole-program DCE, and reintroduces the type-import
  problem single-wasm was chosen to avoid. `.pmo` (pre-lowering MIR) keeps lowering global.
