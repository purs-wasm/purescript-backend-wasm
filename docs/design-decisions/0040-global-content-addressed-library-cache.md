# 0040. A global content-addressed library cache (`$PURS_WASM_LIB`)

- Status: ~~Proposed~~ **Accepted — P1–P6 implemented; §2/§4 revised** _(2026-06-24: the store, the
  recursive `.pmi` cache key (P1), foreign self-merge into `{M}.wasm` (P2), `caf_init` reachability
  pruning (#19), content-addressed write-back **partitioned by own vs library** (P3 — `.spago`
  dependencies + ulib shadows go to the global store, the project's own modules stay in the local
  `_build`), optional `prewarm` (P4), and `.pmo` retirement (P6) are all implemented and suite-green.
  Two parts are **revised**: the §2 "raw `.purs` + dumb source overlay" distribution model is dropped
  in favour of shipping pre-built corefn behind a build-time compatibility gate — see
  [ADR 0041](0041-prebuilt-library-artifacts-and-compatibility-gate.md); the build-mode default
  (orchestrate) and the retirement of the whole-program oracle move to
  [ADR 0042](0042-orchestrate-default-and-oracle-retirement.md). The P5 "resolution-free" experiment
  was tried and reverted as too eager about cache use; the own/library partition (P3) is its sound
  replacement.)_
- Date: 2026-06-20

> Supersedes [ADR 0033](0033-precompiled-ulib-pmo-artifacts.md) (precompiled `.pmo`). Builds on
> [ADR 0034](0034-pmi-interface-pmo-object-split.md) (`.pmi`/object split),
> [ADR 0037](0037-separate-per-module-codegen-and-linking.md) /
> [0038](0038-separated-compilation-purwc-worker-and-cli-lib.md) (per-module / separated compilation).
> Realizes the versioning policy of [ADR 0039](0039-ulib-as-registry-package-patch.md). ~~**Depends on**
> [ADR 0035](0035-sharing-nbe-reduction-aware-inlining.md) Layer C (reduction-aware inlining) for the
> determinism that makes content-addressing sound.~~ _(2026-06-24: outdated — the determinism concern
> was **self-pollution** (since fixed, docs/investigations/0005); full-`.pmi` keying is sound without
> Layer C, confirmed by measured `.pmi` byte-identity between the worker and whole-program cores. §4's
> "Layer C required" is superseded; the cap remains only as a Binaryen size budget.)_

## Context

Separated compilation ([ADR 0038](0038-separated-compilation-purwc-worker-and-cli-lib.md)) makes each
module a self-contained compilation: `purwc` compiles one module from its source and its
dependencies' `.pmi` interfaces into three artifacts — `{M}.pmi` (the dependent-facing interface +
optimization summary), `{M}.wasm` (the object), and `{M}.link.json` (the orchestrator's link
metadata). These artifacts are a deterministic function of the module's inputs, so they are reusable
*across builds and across projects* — but today they are rebuilt per project under
`output-wasm/_build`, and ulib ships as a separate precompiled `lib/` of a different shape (
[ADR 0031](0031-ulib-unified-library-modules.md): per-module `corefn`/`externs` + `foreign.wasm`).

This ADR unifies the two: `$PURS_WASM_LIB` becomes a **global, content-addressed cache of compiled
library-module artifacts**, holding the three siblings for *every* library module (the `.spago`
dependency closure minus the project's own application modules), whether ulib-patched
([ADR 0039](0039-ulib-as-registry-package-patch.md)) or plain registry. The user's project compiles
only its own modules and links them against this cache. It generalizes the precompiled-ulib idea of
[ADR 0033](0033-precompiled-ulib-pmo-artifacts.md) from "ship ulib's `.pmo`" to "content-address the
whole library closure's `.pmi`/`.wasm`/`.link.json", and replaces `.pmo` (a transitional cache of
optimized MIR) with the `.pmi` summary + `.wasm` object that are now the real artifacts.

## Decision

### 1. `$PURS_WASM_LIB` is a Nix-store-like cache of three artifacts per library module

`$PURS_WASM_LIB` holds `{M}.pmi`, `{M}.wasm`, and `{M}.link.json` for every library module, keyed by
content (below). It is **not** a per-project directory and **not** ulib-specific: a plain registry
dependency (`Data.Number`) and a ulib-patched module (`Data.Show`) are both ordinary entries. Multiple
versions, and the patched/unpatched variants of a module, coexist because their keys differ.
`foreign.wasm` / `foreign.wat` cease to exist as separate shipped artifacts — a module's kept foreign
([ADR 0039](0039-ulib-as-registry-package-patch.md)) is compiled *into* its `{M}.wasm` by `purwc`.

### 2. The cache key is content-addressed

Each artifact is addressed by a hash over its complete, output-affecting input:

- **`{M}.pmi`** = `hash(purs/corefn-format pin, M's corefn source, the `.pmi` of each of M's
  dependencies, toolchain)`.
- **`{M}.wasm` / `{M}.link.json`** = the above **plus** the kept-foreign `{M}.wat` content (a wat-only
  patch leaves the corefn identical to the registry's but changes the object) **plus** the
  codegen-affecting toolchain axes.
- **toolchain** = the `purs-wasm` compiler version, the `wasm-base` version, the optimization level,
  and the target platform. These are part of the key (or namespace the store, e.g.
  `$PURS_WASM_LIB/<toolchain>/`), so artifacts never mis-share across toolchains.

Because a dependency enters a dependent's key as its **`.pmi`**, version coexistence and cross-project
reuse fall out: two projects pinning different patch versions of a dependency get distinct keys, and a
dependency bump whose `.pmi` is unchanged leaves every dependent's key unchanged.

### 3. Leniency rides on the interface, validated empirically

The intent of [ADR 0039](0039-ulib-as-registry-package-patch.md) §3 — *a no-op version bump should
hit the cache* — is realized by keying a dependent on its dependencies' **interface**: if a bump does
not change a dependency's `.pmi` *interface*, dependents are reused. This is sound only insofar as a
dependent's compiled output genuinely depends on its dependencies' interfaces and not on their
*implementation*. Cross-module optimization (caller-homed specialization,
[ADR 0032](0032-caller-homed-specialization-for-incremental-builds.md); summary inlining) currently
makes a dependent depend on a dependency's summary *bodies*, which would narrow this leniency. The
boundary between "interface-only (max sharing)" and "implementation-dependent (max optimization)" is
**decided empirically** (open question 1) rather than fixed here.

### 4. Determinism is a hard prerequisite — and is why this depends on Layer C

Content-addressing is sound **only if** a module's artifacts are a deterministic, context-independent
function of `(source, dependency `.pmi`, toolchain)` — i.e. they must not depend on the *dependents*
or on the rest of the program. The current optimizer **violates this**: `compileModuleMir` (the
worker) computes its inline keep-set (`summaryInlineKeys`) over `deps ∪ target`, while the in-process
`optimizeIncrementalM` computes it over the **whole program**. For reduction-heavy code these diverge
sharply — `Examples.Metatheory.Typecheck`'s `.pmi` is **636 KB** under the whole-program keys and
**4.8 MB** under the local keys (the generic `Show`/`Eq` machinery is re-derived per-helper rather
than shared, and the medium copies slip under the per-declaration size cap). A summary that depends on
the whole program cannot be content-addressed.

The fix is not a patch to `summaryInlineKeys` but the deferred **reduction-aware inline policy**
([ADR 0035](0035-sharing-nbe-reduction-aware-inlining.md) Layer C): inline a reference exactly where,
in its use-site continuation, it reduces, and otherwise share it (never copy). Because that decision
is made from the *local* use-site spine, per-module compilation becomes context-independent — which is
precisely the determinism this cache requires — and the per-helper duplication that bloats the local
summary is prevented at the source. This ADR therefore **depends on** completing Layer C; the size cap
remains only as a context-independent safety net.

### 5. `ulib install` is the prewarm; the project build is resolution-free

**Prewarm (`ulib install`).** For each library module of a package set:
1. `spago install` materializes the library sources under `.spago`.
2. Apply the ulib overlay ([ADR 0039](0039-ulib-as-registry-package-patch.md) §2, last-wins) onto
   those sources.
3. Build normally (`purs`) → `corefn` / `externs` (+ a `foreign.js` for any kept foreign, ignored on
   the wasm path).
4. If the module has a ulib `{M}.wat`, attach it; run `purwc` against the dependencies' cached `.pmi`.
5. Store the resulting `{M}.pmi` / `{M}.wasm` / `{M}.link.json` in `$PURS_WASM_LIB` under its key.

The two ulib shapes (wat-only / reimplementation) flow through this identically — the only difference
is whether step 2 overlaid a `.purs`. A module the prewarm misses is populated lazily by the first
project build that needs it (write-back), so the cache fills incrementally without a mandatory
whole-closure prewarm.

**Project build.** The project compiles only its **own** modules (`purwc`, against the cached
dependencies' `.pmi`), then links: a **dumb last-wins merge** of the reachable cached `.wasm` with the
project's `.wasm`, with **link-time reachability** computed over the real `.pmi` / `.link.json`
interfaces from the program's roots. There is no `resolveModuleSet`, no module-selection resolver, and
no re-decode of library `corefn` / `externs` — a dependency contributes only its cached `.pmi`
(to compile against) and `.wasm` / `.link.json` (to merge).

## Consequences

- **`.pmo` is retired** ([ADR 0033](0033-precompiled-ulib-pmo-artifacts.md)): the cached `.pmi`
  (interface + summary) and `.wasm` (object) are the artifacts; there is no separate optimized-MIR
  object. `--dump-mir` re-targets to the `.pmi` summary / in-memory MIR.
- **`$PURS_WASM_LIB` changes role** from "the precompiled ulib lib" to "the global library-artifact
  cache"; ulib modules are ordinary cache entries that happen to have been built from patched source.
- **The build loses its ulib resolution logic** (see [ADR 0039](0039-ulib-as-registry-package-patch.md)):
  overlay → compile → content-address → dumb merge.
- **Determinism becomes a tested invariant**, not an aspiration: the cache is only correct if
  `(source, dep `.pmi`, toolchain)` fully determines the artifacts (open question 2).

## Open questions (to measure, not to assert)

1. **Where to sit on the interface↔implementation axis** (§3): how impl-dependent are dependents'
   outputs in practice? Differential test — change a dependency's implementation keeping its interface,
   recompile dependents, and quantify how often / how much their artifacts change. The data sets how
   lenient interface-keying can safely be, and how much cross-module specialization
   ([ADR 0032](0032-caller-homed-specialization-for-incremental-builds.md)) to keep vs. trade for cache
   sharing.
2. **The determinism gate** (§4): once Layer C lands, verify a module's artifacts are byte-identical
   across the worker and any whole-program path, on a reduction-heavy corpus (the
   `Metatheory.Typecheck` / generic-`Show` case), so content-addressing is provably sound.
3. **Cache lifecycle**: population concurrency (atomic, concurrent-safe writes), eviction / GC, and the
   toolchain namespacing of the store path.
