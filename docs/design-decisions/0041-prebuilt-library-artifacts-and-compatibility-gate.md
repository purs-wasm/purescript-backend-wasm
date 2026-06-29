# 0041. Library artifacts ship pre-built; a build-time content-based compatibility gate

- Status: Proposed
- Date: 2026-06-24

> Revises the "raw `.purs`, dumb source overlay" half of [ADR 0040 §2](0040-global-content-addressed-library-cache.md)
> and replaces the "always apply, version is informational" leniency of
> [ADR 0039 §3](0039-ulib-as-registry-package-patch.md) with an explicit, content-based gate. Builds on
> the content-addressed store and own/library write-back partition that
> [ADR 0040](0040-global-content-addressed-library-cache.md) actually shipped. Companion to
> [ADR 0042](0042-orchestrate-default-and-oracle-retirement.md) (build-mode default).

## Context

[ADR 0040](0040-global-content-addressed-library-cache.md) landed the content-addressed store
(`$PURS_WASM_STORE`): a build writes a **library** module (a `.spago` dependency or a ulib shadow) to
the global store keyed by content and keeps the project's **own** modules in the local `_build`; a hit
copies the cached `.pmi`/`.wasm`/`.link.json`, so reuse is sound across builds and projects, and the
store is populated lazily (no required install — `prewarm` is optional). `.pmo` is retired
([ADR 0040 P6](0040-global-content-addressed-library-cache.md)).

Two parts of the original 0040 vision were **not** taken, and a review of the intended end-state
clarified why:

- **Distribution.** 0040 §2 imagined ulib shipping **raw `.purs`** plus optional `.wasm`, with the
  project compiling only its own modules and a "dumb source overlay" producing the patched library
  corefn on demand. Today ulib still ships **pre-compiled** corefn + externs + `foreign.wasm` and a
  user runs `ulib install` to compile the shadows.
- **Patch application.** [ADR 0039](0039-ulib-as-registry-package-patch.md) made patching
  **presence-driven and lenient** — a reached patched module is always taken from the lib, with a
  version drift reported only as an informational note. There is **no build-time gate** that decides
  *whether* a patch is safe to apply.

The current vs intended gap, restricted to the ulib/distribution axis:

| Intended | Current | Status |
| --- | --- | --- |
| cache hit → copy from store, no build, no patch | P3 store hit, content-addressed; no re-patch on hit | done |
| miss → compatibility gate → apply patch + build + store / incompatible → warn + build unpatched | miss → **always** patch (0039 lenient); store write-back done | gate missing |
| library artifacts bundled with the toolchain, no user install | shipped pre-built, but a user `ulib install` compiles shadows | not done |
| ulib-tooling: only a maintainer check | `check`/`install`/`compat`/`validate` all present | not done |

### Why raw `.purs` buys nothing — and costs the wrong dependency

The decisive observation: a ulib patch is **whole-module replacement**, not a diff/merge. So per
module the decision is binary — apply the patch's source in full, or do not. And corefn references its
dependencies **by name** (it is interface-portable; it does not embed dependency versions). Therefore
the patched module's corefn, compiled by the maintainer's **pinned** purs, is identical to what a
user's **same pinned** purs would produce. Shipping raw `.purs` and compiling it user-side yields
**exactly the pre-built corefn** — for the only case where it would be applied (interface-compatible).
It adds nothing, while dragging a `purs` invocation into the purs-wasm build path. purs-wasm's compiler
core is, and must stay, **corefn-in**: it never runs `purs`.

The "version adaptivity" that raw `.purs` seemed to offer is illusory under a whole-module,
interface-gated model: an interface-compatible user already gets the identical artifact; an
interface-incompatible user must not get the patch at all (see the gate).

## Decision

1. **purs-wasm never runs `purs`.** The compiler core stays corefn-in; no source overlay or `purs`
   invocation enters the `purs-wasm build` path.

2. **Ship library patch artifacts pre-built**, bundled with the toolchain under `$PURS_WASM_LIB`: for a
   reimplementation patch its corefn (+ externs); for a wat-only patch the registry pass-through plus
   `foreign.wasm`; and, for each, an **interface digest** recording the dependency interface the patch
   was built against. Not raw `.purs`.

   - *Soundness invariant:* the shipped corefn equals what a user's purs would emit **because the purs
     version is pinned** (currently 0.15.16). The maintainer `validate` step regenerates the artifacts
     with that same pin. **Bumping purs requires regenerating the bundled artifacts** — this is the one
     thing the pin buys and the one thing that invalidates the shipped corefn.

3. **A build-time, content-based compatibility gate**, evaluated only on a cache **miss** for a patched
   library module (a hit copies from the store — no gate, no patch):

   - *wat-only patch:* compatible iff the registry module's foreign-import signatures (from the user's
     resolved externs) match what `foreign.wasm` provides.
   - *reimpl patch:* compatible iff the patch's recorded interface digest matches (is compatible with)
     the user's resolved dependency externs for that module.
   - **Compatible** → apply the patch (use the shipped corefn / merge `foreign.wasm`), build, write to
     the store.
   - **Incompatible** → warn and **skip the patch**: build the registry version, whose foreign has no
     wasm provider → JS fallback. Under `--no-js-fallback` or `--platform=standalone` this is a
     **hard error**, whose message names the incompatible patch as the cause.

   The gate is cheap (an externs/interface comparison), runs **no purs**, and degrades gracefully.
   Version remains provenance only (0039); the gate is content/interface-based.

4. **Remove user-side `ulib install`.** Artifacts are bundled; the store is populated lazily by the
   first build that needs each module (0040 own/library partition). `prewarm` stays optional ("first
   build slow, then cached").

5. **ulib-tooling collapses to a maintainer `validate`** — compile each patch with the pinned purs,
   record its interface digest, and check it against the package-set it targets. `install` / `check` /
   `compat`-as-commands retire; the compat metadata (interface digests) becomes part of the shipped
   bundle and the gate's input.

## Consequences

- **Gives up** per-user recompilation of a reimpl against the user's exact dependency versions. Under
  the whole-module, interface-gated model this costs nothing real: an in-range user gets the identical
  artifact anyway; an out-of-range user gets a graceful **skip** (JS fallback) instead of a
  recompile-and-maybe-work. The payoff is that `purs` never enters the purs-wasm build path.
- Store soundness/determinism is unchanged — still content-addressed
  ([ADR 0040](0040-global-content-addressed-library-cache.md)).
- Should a future need for true per-user recompilation arise, it belongs in a **separate resolver
  layer** (an evolved ulib-tooling or a build front-end) that runs `purs` and writes corefn to the
  store — never in the purs-wasm compiler core.

## Open questions

- The exact form of the **interface digest**: a hash of the full module externs, or only the subset of
  symbols/types that dependents actually use (the latter is more lenient and closer to 0039's
  content-based spirit, but harder to compute).
- How the gate **reports a skip** (per-module warning vs a build summary), and how it interacts with
  the existing 0039 drift note.
- Where the bundled artifacts physically live relative to `$PURS_WASM_LIB` and the npm package layout.
