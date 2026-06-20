# 0039. ulib as a patch on registry packages, with content-based lenient versioning

- Status: Proposed
- Date: 2026-06-20

> Supersedes [ADR 0031](0031-ulib-unified-library-modules.md) (and, transitively, the already-superseded
> [0012](0012-ulib-curated-package-ffi.md) / [0028](0028-ulib-library-layer-shadowing.md)). Carries
> forward the purs-pin / `builtWith` link guard of [ADR 0029](0029-ulib-lib-distribution-and-purs-pinning.md).
> The artifact store and build flow that realize this policy are the companion
> [ADR 0040](0040-global-content-addressed-library-cache.md); the optimizer property both rely on is
> [ADR 0035](0035-sharing-nbe-reduction-aware-inlining.md) Layer C (reduction-aware inlining).

## Context

ulib exists for two reasons, unchanged since [ADR 0012](0012-ulib-curated-package-ffi.md):

1. **Capability** — a function implemented in JS as a `foreign import` has no wasm provider, so a
   program using it cannot run standalone. ulib supplies the missing implementation on the wasm
   substrate, either as pure PureScript over `Wasm.*` ([ADR 0026](0026-wasmbase-primitive-layer.md))
   or, where that is impossible (e.g. a Dragon4 float formatter), as a hand-written `foreign.wat`.
2. **Specialization** — a higher-order `foreign import` (e.g. prelude's `arrayMap`) is opaque to the
   MIR optimizer. Reimplementing it in PureScript over `Wasm.*` brings its element closure onto the
   optimizer's turf so it specializes ([ADR 0027](0027-specialize-after-inlining.md)).

[ADR 0031](0031-ulib-unified-library-modules.md) gave ulib its current shape: one source per module
(`ulib/{package}/{Module}.purs` + optional sibling `{Module}.wat`), resolved by a **last-wins
artifact merge** of a precompiled `lib/` over the user output, with an `ulib-manifest.json` doing
**exact-version gating** (a shadow applies only when `spago.lock` pins the manifest's exact version).
That design also admitted a third, weaker category — a **foreign-only** module: a manifest entry with
*only* a `.wat`, *no* `.purs`, where the registry corefn is kept and the lib supplies just one
foreign (`Data.Int` ships only `fromStringAsImpl`).

Two problems surfaced once single-module compilation ([ADR 0037](0037-separate-per-module-codegen-and-linking.md)
/ [0038](0038-separated-compilation-purwc-worker-and-cli-lib.md)) put each module on the optimizer's
turf in isolation:

- **Foreign-only modules are an unsound half-shadow.** `Data.Int` is registered as ulib-covered, yet
  its body is the *registry* corefn, which imports `Data.Number` (`isFinite`) and ships six other JS
  foreigns the lib never provides. The module's *declared* import surface (empty — there is no lib
  corefn) diverges from the *compiled* source's real imports. Under the whole-program build this is
  masked by dead-code elimination; under per-module compilation the worker over-exports the dead
  `fromNumber` and fails with `unknown callee: Data.Number.isFinite`. The fix is not in the compiler:
  a "shadow" that delegates its body to the registry while pretending to own the module is the defect.
- **Exact-version gating is brittle and lives in the wrong place.** A registry patch (`6.0.2`) that is
  perfectly source-compatible with `6.0.3` is rejected outright, and the gate runs as build-time
  *resolution logic* (`resolveModuleSet`) rather than being a property of the artifacts.

## Decision

### 1. ulib is a *patch* on a registry package — never a reimplementation, never a partial API

A ulib module is one of exactly two shapes, and nothing else:

- **wat-only patch** — the PureScript is the registry source *verbatim*; ulib adds a hand-written
  `{Module}.wat` providing the foreigns that have no wasm implementation. Behaviour is identical to
  the registry (the `.purs` is unchanged), only the foreign provider changes (JS → wasm).
- **PureScript-reimplementation patch** — ulib replaces some or all of the package's `.purs` with an
  *interface-compatible* reimplementation over `Wasm.*` (plus a `{Module}.wat` for any kept foreign).
  Only the interface must match the registry; the implementation is free.

Additions are allowed — a patch may be a strict *superset* (e.g. `strings`' private
`Data.String.Internal.Utf8`) — but a patch may never *remove* or *narrow* the registry's public
surface, and may never be a from-scratch package with its own API. This keeps ulib a low-maintenance
*delta* over upstream rather than a fork we must keep behaviourally complete.

**The "foreign-only" category is abolished.** A module that ships a `.wat` but keeps the registry
`.purs` is simply a *wat-only patch* (category above), and the *registry source it keeps is the source
that is compiled* — with its real imports. There is no module whose declared surface diverges from
its compiled body, so the import-surface mismatch (the `Data.Number` failure) cannot recur. A patch
that wants the kept module to be self-contained on wasm must say so in PureScript (the
reimplementation shape); otherwise its registry dependencies (`Data.Number`, …) are honest
dependencies that get compiled like any other.

### 2. Applying the patch is a dumb source overlay — no resolution logic

A patch is applied by a **last-wins overlay of `ulib/{package}/` onto the package's source tree**,
before compilation. The overlaid tree *is* the source that is compiled; its imports and interface are
whatever the (possibly patched) source says. The build carries **no ulib-specific resolution code** —
no `shadowOrRegistry`, no foreign-only special case, no `resolveModuleSet` selecting "which modules
come from the lib." Whether a module is patched is decided once, at overlay time, by which files exist
in `ulib/{package}/`; downstream everything is ordinary module compilation.

### 3. Versioning is content-based and lenient, not exact-match

A ulib patch is authored against a specific upstream version, but it **applies to any registry version
whose patched source it is compatible with**, not only the exact authored version. Concretely:

- A **wat-only patch** applies to a registry version iff the registry module's *foreign-import
  signatures* the `.wat` provides are unchanged. The kept `.purs` is the registry's own, so behaviour
  tracks upstream automatically.
- A **reimplementation patch** applies to a registry version iff the patch's interface still matches
  (the existing `ulib check` interface-diff, [ADR 0028](0028-ulib-library-layer-shadowing.md)).

"Lenient" means a registry version bump that does **not** change the patched surface keeps the patch
applicable — no manifest edit, no rejection. Soundness of a given leniency (does the patch's behaviour
still hold across the bump?) is **validated empirically** (the differential `ulib`/e2e harnesses),
not asserted by an exact-version equality. This replaces `ulib-manifest.json`'s exact-version gate;
the manifest, if retained, records *which packages ulib patches* and the *authored* version for
provenance, not a hard equality gate.

The mechanism that makes coexistence and cross-project reuse free under this policy is
content-addressing: a (patched-or-not, version) source hashes to a distinct artifact key, so multiple
registry versions and the patched/unpatched variants coexist in the cache without a resolver
deciding between them. That store and its keys are specified in
[ADR 0040](0040-global-content-addressed-library-cache.md).

### 4. The purs / corefn pin carries forward

The decoder-version pin and the `builtWith` link guard of
[ADR 0029](0029-ulib-lib-distribution-and-purs-pinning.md) are unchanged: the toolchain still fixes a
single corefn-format version, imposed on the user, so a module built with an incompatible purs fails
loudly. Lenient *package* versioning (this ADR) is orthogonal to the fixed *compiler/corefn* pin.

## Consequences

- The `Data.Number`-class import-surface bug dissolves at the source: no module's declared surface
  diverges from its compiled body. The compiler-side workarounds explored for it (an orchestrate-only
  import-closure expansion; a `resolveModuleSet.importsOf` fallback) are unnecessary and are not taken.
- `resolveModuleSet`, the foreign-only handling, and exact-version manifest gating are retired from the
  build; resolution collapses to "overlay the source, then compile and link like any other module"
  (the build-side mechanics are [ADR 0040](0040-global-content-addressed-library-cache.md) §build).
- ulib stays a *delta* over upstream: a wat-only patch is the smallest possible (a `.wat` + the
  registry `.purs`), a reimplementation patch only diverges where it must (the HOF foreigns). We never
  owe upstream a complete reimplementation.
- The leniency is a *policy with an empirical gate*: we gain cache hits across no-op version bumps at
  the cost of having to measure that a patch survives a bump. ADR 0040 §open-questions tracks that
  measurement.

## Supersedes / relationships

- **Supersedes** [ADR 0031](0031-ulib-unified-library-modules.md) (the exact-match last-wins design and
  its foreign-only category).
- **Carries forward** [ADR 0029](0029-ulib-lib-distribution-and-purs-pinning.md) (purs pin / link guard).
- **Companion** [ADR 0040](0040-global-content-addressed-library-cache.md) (the artifact cache + build
  flow that realize this policy).
- **Depends on** [ADR 0035](0035-sharing-nbe-reduction-aware-inlining.md) Layer C: per-module
  compilation must be context-independent for content-addressed coexistence to be sound (see ADR 0040).
