# 0034. Split the module cache into `.pmi` interface and `.pmo` object

- Status: Proposed _(refines [ADR 0032](0032-caller-homed-specialization-for-incremental-builds.md) phase 4: the single-file `.pmo` cache landed there; this splits it so warm builds skip decode/translate, not just optimize)_
- Date: 2026-06-15

## Context

[ADR 0032](0032-caller-homed-specialization-for-incremental-builds.md) phase 4 landed the
incremental MIR cache as **one `.pmo` per module** holding `{ cache key, finalized MIR,
summary }`. Measured on `metatheory` (133 modules) it is correct — a cold build, a fully
warm build, and a non-cached build all produce **byte-identical** `index.wasm` — but a warm
build is only **~8% faster**. Two costs remain:

1. **The cache elides only the optimize passes (~2.1 s).** `decode` + `translate` +
   `lambda-lift` still run for *every* module, because the dependency graph and the cache
   keys were derived from the **translated** MIR (`declRefs` / `topoOrder`). So a warm build
   re-decodes and re-translates all 133 modules even when nothing changed.
2. **The single `.pmo` bundles the heavy finalized MIR with the small summary.** Reading a
   dependency's *summary* (needed for keys and for the optimization context of its
   dependents) drags in the whole finalized body — ~13 MB total for `metatheory`, ~1.2 s
   just to deserialize, nearly cancelling the optimize saving.

A re-examination corrected a wrong assumption behind (1). CoreFn `imports` **already names
every defining module of a referenced binding, re-exports included** — verified across real
modules (every `Var`'s module is in `imports`; `purs` needs this for the JS backend's import
emission). So a dependency graph can be built from corefn imports *without* decoding or
translating; the re-export hole that seemed to force a translated `declRefs` graph does not
exist. (`imports` is a sound dependency set, merely *coarser* than `declRefs` — it includes
imported-but-unreferenced modules.)

## Decision

**Split each module's cache entry into two files, by analogy with OCaml's `.cmi` / `.cmo`
(the analogy [ADR 0033](0033-precompiled-ulib-pmo-artifacts.md) already invoked), and make
the warm driver decode-free for cache hits.**

- **`.pmi` (interface)** — the small, always-read part: the module's **cache key**, its
  precise **dependency list** (the `declRefs` defining-module references, recorded when it
  was last optimized), and its **summary** (the pruned MIR its dependents optimize against,
  [ADR 0021](0021-streaming-dependency-ordered-wpo.md) b1). The dependency graph, the
  hit/miss decision, and a *dependent's* optimization context all read only `.pmi`.
- **`.pmo` (object)** — the large part: the **finalized MIR** fed to codegen. Loaded only
  when a module's code is emitted — never to decide a hit, nor to optimize a dependent.

The warm driver:

- derives module order from corefn **imports** (cheap text extraction, no Argonaut decode;
  imports are acyclic and a superset of references, so the order is sound);
- computes each module's key from its **source hash ⊕ its dependencies' summary hashes**,
  taking the dependency set from its `.pmi` (precise);
- on a **hit** (key matches the `.pmi`) loads only `.pmi` (and its `.pmo` at codegen time),
  **skipping decode / translate / lambda-lift / optimize entirely**;
- on a **miss** decodes the corefn and runs the full pipeline, rewriting both `.pmi` and
  `.pmo`.

## Consequences

- **Warm builds skip `decode` + `translate` + `lambda-lift` for unchanged modules** — the
  dominant remaining cost — not just the optimize passes. Optimizing a *changed* module
  loads only its dependencies' `.pmi` summaries (small), never their finalized MIR. This is
  the step that moves a warm rebuild toward purs-backend-es class; thereafter lowering,
  Binaryen `-O`, and `wasm-merge` (all whole-program, [ADR 0009](0009-build-and-linking-model.md))
  dominate.
- **The finalized program is still fully loaded for codegen** on every build (single-wasm,
  [ADR 0009](0009-build-and-linking-model.md)). The split *defers* the `.pmo` load to
  codegen rather than removing it; the win is in the decide/optimize phase reading only
  interfaces.
- **Invalidation stays as precise as the phase-4 baseline.** The key's dependency set comes
  from the `.pmi`'s recorded `declRefs` deps, not the coarser corefn imports; imports are
  used only for the (sound) module *ordering*.
- **Soundness is unchanged** from [ADR 0032](0032-caller-homed-specialization-for-incremental-builds.md):
  a module is reused iff its source hash and every consumed dependency summary hash are
  unchanged. Byte-identical output remains the acceptance gate.
- **One format version** covers both files (a `.pmi` and its `.pmo` are written and read as a
  pair); bumping it invalidates stale caches of either.

### Future enrichment (not in the first cut)

The `.pmi` is the natural home for denormalized optimization facts a dependent would
otherwise re-derive, so a later refinement may add, beside the summary:

- per-binding **purity / memory-effect** flags (today re-derived from the summary,
  [ADR 0019](0019-faithful-effect-lowering.md));
- the marker that a CAF is really a **type-class dictionary** record eligible for
  tuple-ization ([ADR 0007](0007-positional-dictionary-specialization.md)).

These are additive; the first cut keeps `.pmi` minimal (`key` + `deps` + `summary`), the
focus being the decode-free incremental loop itself.

## Alternatives considered

- **Keep the single `.pmo` (the phase-4 baseline).** Correct, but warm builds stay ~8%
  faster only: decode/translate/lift run for all modules, and a summary cannot be read
  without deserializing the heavy finalized MIR.
- **Build the graph and keys from corefn imports alone, no `.pmi`.** Sound (imports include
  re-export origins) and decode-free, but the key's dependency set becomes coarser
  (`imports ⊋ references` → more spurious invalidation), and the summary / finalized MIR stay
  bundled. `.pmi` keeps the dep set precise *and* separates interface from object.
- **Cache the lowered backend IR or per-module wasm too.** Rejected: lowering and codegen are
  whole-program (reachability, representation analysis, type sharing —
  [ADR 0009](0009-build-and-linking-model.md) / [ADR 0013](0013-int-number-unboxing.md)), so
  a per-module lowered artifact is not a sound unit.
