# 0028. ulib as a compiler-bundled library layer: lib-first shadowing of registry modules

- Status: ~~Proposed~~ ~~**Accepted**~~ **Superseded by [0031](0031-ulib-unified-library-modules.md)** _(2026-06-10: promoted — implemented: ulib shadows (Data.Functor/Foldable/Array) + lib-first resolution + `ulib install`/`validate`/`check`.)_
- Date: 2026-06-09

> **Superseded by [0031](0031-ulib-unified-library-modules.md) (2026-06-12).** The lib-first
> *intent* (ulib shadows the registry module, WasmBase underneath) carries forward, but the in-code
> `shadowOrRegistry` per-module `major.minor` version match is replaced by 0031's **last-wins
> artifact merge** driven by `ulib-manifest.json` (an *exact*-version `shadowSet` / `resolveModuleSet`
> decides provenance, not branching in the compiler). `validate` is retired (the build-time check
> covers it); the maintainer `install`/`check`/`compat` ops moved to the separate `ulib-tooling` CLI,
> so the user `purs-wasm` binary carries only `build`.

## Context

ADR 0026 gives WasmBase (`Wasm.*`) the **primitive** layer — a normal spago package, never
shadowed (distinct namespace). But for *idiomatic* code to be fast — a user writing
`map (+1) arr` / `Data.Array.foldl` rather than calling `Wasm.Array.*` directly — the
registry's **foreign / higher-order-bearing core modules** (`Data.Functor`'s `arrayMap`,
`Data.Foldable`'s array folds, `Data.Array`, `Data.String`, …) must be replaced by
PureScript-over-WasmBase reimplementations whose closures specialize (ADR 0027). A foreign
HOF can never specialize (ADR 0027), so the win requires the higher-order layer to be
PureScript.

Three facts shape how:

1. **They collide with the registry.** These are the *same module names* the registry ships,
   and PureScript forbids two versions of a package in one build (module names are global).
   So they cannot be an add-on package installed *alongside* the registry ones — they must
   **shadow** (override) them.
2. **The relevant packages are stable; the package *set* is not.** A package set bumps almost
   daily (any leaf package change ⇒ a new set), but the core packages we shadow (`prelude`,
   `arrays`, `foldable-traversable`, `strings`) bump *rarely* (majors years apart — `arrays`
   4.0.0 was 2017, 7.x today). So coupling must track **packages**, not the set.
3. **purs typechecks against the registry; purs-wasm codegens from the shadow.** The frontend
   (`purs`) compiles the user's code against their *registry* module version; purs-wasm then
   substitutes the shadow at codegen. The two interfaces must match ⇒ a shadow is tied to a
   specific *package version*.

(Concretely, grounding the design: `prelude`'s `Data.Functor` imports only
`Data.Function`/`Data.Unit`/`Type.Proxy` — no arithmetic — so a PureScript `arrayMap` loop
there cannot use `Prelude`'s `+`/`>=` without a cycle. It needs prelude-free `Int` ops, i.e.
`Wasm.Int` — the case ADR 0026 anticipated. So WasmBase regains a `Wasm.Int` primitive
module. Higher library modules, e.g. in `arrays`, freely use `Prelude` and don't need it.)

## Decision

**ulib is a compiler-bundled *library* layer** — PureScript modules that **shadow** the
registry's foreign/HOF-bearing core modules, reimplemented over WasmBase so their closures
specialize. It is a distinct layer from wasm-base (ADR 0026): wasm-base = the primitive layer
(spago package, distinct namespace, never shadowed); ulib = the library layer
(compiler-bundled, *shadows* the registry).

- **Lib-first resolution.** At compile time, before reading a module's corefn from the user's
  `input`, purs-wasm checks its bundled lib. If the lib has a shadow for that module **and**
  the user's resolved package version matches the shadow's target ⇒ use the lib's corefn
  (fast). Otherwise ⇒ use the user's `input` corefn (the registry version — correct but slow):
  a **graceful fallback** with a warning.
- **Per-package version matching, not per-package-set.** The shadow targets specific *package*
  versions via a compat map (`{ prelude: 6.0.2, arrays: 7.3.0, foldable-traversable: …,
  strings: … }`); the user's version is read from the corefn `modulePath`
  (`.spago/p/<pkg>-<ver>/…`). This is the registry's per-version `compilers`-metadata idea
  applied to "which package version this shadow targets". It tracks a handful of stable core
  packages, updated only on their (rare) releases — **independent of the daily package-set
  churn**.
- **Graceful fallback, never a hard error.** A user bumping `arrays` past what ulib shadows
  must not break the build — they just lose the speedup (fall back to the registry module)
  until ulib catches up; emit a warning.
- **Module-level granularity.** Shadow only the foreign/HOF-bearing modules; pure-PureScript
  modules come from the registry unchanged.
- **`Wasm.Int` returns to WasmBase.** Shadowing a low-level prelude module (e.g.
  `Data.Functor`) needs prelude-free `Int` ops for its loop, so `Wasm.Int` (`add`/`eq`/…) is a
  required WasmBase primitive after all.
- **Fidelity by copy.** Each shadow is the registry module's *own source* with only the
  foreign HOFs replaced by PureScript over WasmBase — preserving the exact interface (exports
  + types) of the version it targets.

> **Update (2026-06-09): the `ulib` subcommand and its `validate` / `check` tools.**
> The lib is managed by a `purs-wasm ulib` command group:
>
> - **`ulib install`** — compile the shadows (`ulib/shadow/<pkg>-<ver>/<Module>.purs`) against the
>   resolved package-set sources (`.spago/p`) with WasmBase overlaid, and store each shadowed
>   module's `corefn.json` **+ `externs.cbor`** into `<lib>/<pkg>-<ver>/<Module>/`. (Externs are
>   stored so `check` can later compare interfaces.) Skips if the lib exists, unless `-f/--force`.
> - **`ulib validate`** — for each installed shadow, compare the package version it targets against
>   the version resolved in the user's workspace (`.spago/p`), by `major.minor` (a patch bump keeps
>   the interface). A divergence is the case where the build-time lib-first resolution would *skip*
>   the shadow (fall back to the registry, losing the speedup), so `validate` reports it and exits
>   non-zero — the user aligns their version to the ulib's (per the resolution direction below).
> - **`ulib check`** (deep check) — compare each shadow's **public interface** (exported names,
>   distilled from the stored externs by `Ulib.Interface.interfaceOf`) against the *same module
>   compiled in the user's workspace* (`<input>/<Module>/externs.cbor`, i.e. their spago build
>   output). A shadow that **drops** a name the registry module exports is not a drop-in ⇒ fail;
>   one that only **adds** names is reported but allowed. A not-yet-compiled module is skipped with
>   a note. This is the operational guard for the "fidelity by copy" risk below. The interface is
>   export *names* only (values/ops/types+ctors/classes); name-insensitive *type*-level comparison
>   is deferred.
>
> **Resolution direction.** The comparison baseline is the user's workspace packages (`.spago` /
> their build output), not the upstream registry source — those are what their IDE and spago build
> actually run against, so any ulib/workspace divergence is what hurts them in practice. On a
> mismatch, the user aligns *their* version to the ulib's (rather than ulib chasing every user).

> **Update (2026-06-09): `Data.Array` added to the shadow set (arrays 7.3.x).** The third shadow.
> It is the registry `Data.Array` copied verbatim, with only the higher-order `*Impl` foreigns
> reimplemented over `Wasm.Array`: `filter`, `partition`, `zipWith`, `scanl`/`scanr`,
> `findIndex`/`findLastIndex`/`findMap`, `any`/`all`. Structural foreigns
> (`range`/`reverse`/`slice`/`uncons`/`index`, still wat-provided) and the `Data.Array.ST`-based
> functions are left as-is — identical behaviour, resolved or DCE'd exactly as for the registry
> module, so the change is strictly Pareto (some HOFs specialize; nothing regresses).
>
> **Follow-up (same day): the structural foreigns that had *no* wasm provider were reimplemented
> too**, since they were host-imports that simply could not run standalone — `replicate`, `concat`,
> `insertAt`/`deleteAt`/`updateAt`, and `sortBy`/`sort` (a stable top-down merge sort over
> `Wasm.Array`). These take no static closure (no specialization win) but close real capability
> gaps: `sort` and friends now run on a self-contained wasm with no JS loader. Verified on wasm
> (incl. sort stability); only `fromFoldable` (Foldable-polymorphic) and the five wat-provided
> readers remain foreign. Unlike the sub-`Prelude`
> shadows, the index arithmetic uses ordinary `Prelude` `Int` ops (already intrinsics here), so no
> `Wasm.Int` is needed. Verified on wasm: all reimplemented HOFs match registry semantics; the
> public interface is unchanged (`ulib check` ✓). No benchmark case was kept: a `filter`-based
> bench was prototyped but it is allocation/GC-bound (a fresh result array per call) and boxing-
> bound (#19), so it measures heap churn, not the specialization, and cannot beat js-es's native
> arrays until int unboxing lands — revisit array-HOF benchmarks after #19. The shadow's actual
> win is on the wasm side (the predicate specializes into the loop instead of an opaque per-element
> `call_ref`), which the wasm-vs-js bench harness cannot isolate.
>
> **Single-allocation invariant (gotcha).** Each reimplemented HOF must call `Wasm.Array.unsafeNew`
> **exactly once** and thread that one buffer through a single recursion. The optimizer treats
> `unsafeNew` as pure, so a working buffer referenced from two places (e.g. fill into it, then a
> separate pass to trim it) is **duplicated** — each site allocates its own array, and the second
> reads an uninitialised one (→ `illegal cast` at run time). `filter`, whose result size isn't
> known up front, therefore counts matches in a cheap first pass and then fills one exact-size
> buffer, rather than over-allocating and trimming. (The deeper fix — marking `unsafeNew` impure so
> the optimizer never duplicates it — is a separate compiler change; the single-allocation
> discipline is the shadow-level workaround.)

> **Update (2026-06-09): the optimizer now treats the array mutators as memory-effectful, so the
> single-allocation discipline above is no longer load-bearing.** `Purity` gained `memEffKeys` — a
> least-fixpoint set of top-level bindings whose *evaluation* writes/allocates memory, seeded by
> `Wasm.Array.unsafeNew`/`unsafeSet` and propagated through the call graph (lambda-lifting has
> already promoted the buffer-filling local helpers to top level, so the set reaches them).
> `evalImpure` consults it on an application head, so the simplifier's drop/duplicate/move rules
> (all gated on `exprPure`) now leave a buffer fill alone even when its own result is discarded —
> the write runs, in place. This is distinct from `impureKeys` (Effect *performing*, ADR 0015): a
> memory write happens on plain evaluation, never via a `Perform`, so `memEffKeys` ignores `Effect`
> and does not over-mark Effect bindings (no regression to the State/Effect collapse — full suite
> green). Both the trapping patterns (a direct write whose result is unused, and a local helper
> that fills then returns a count) now run correctly; the `filter` shadow's count-first shape is
> kept (it also avoids over-allocating) but is no longer *required* for correctness.

> **Update (2026-06-09): the compat-map is realised + a sync guard.** `ulib/compat.json` records
> the pinned package-set version (`workspace.package_set.address.registry` in `spago.lock`, here
> `77.4.0`) and, per shadowed package, the version that set resolves (`package_set.content`). It is
> git-managed — the explicit statement of what a ulib release targets. `ulib-compat.mjs` generates
> it (`node ulib-compat.mjs`) and verifies it (`--check`, wired into the bench workflow): a shadow
> whose `major.minor` diverges from the pinned set is **stale** and fails the check (the package set
> bumped that package past what the shadow targets — re-shadow it), a patch-only divergence warns,
> and a missing/out-of-date `compat.json` fails. This closes the release/sync loop: when the pinned
> set is bumped, `--check` flags exactly which shadow dirs (`ulib/shadow/<pkg>-<ver>/`) need
> updating. (Distinct from `ulib validate`, which compares the installed lib against the *user's*
> workspace; this compares the shadows against the *project's pinned set*.)

> **Update (2026-06-10): `ulib-compat.mjs` is now the `purs-wasm ulib compat` subcommand.** The
> prototype script has been reimplemented in PureScript as `purs-wasm ulib compat` (same generate /
> `--check` modes; the regenerated `compat.json` is byte-for-byte identical, verified by a
> differential test against the script). Read both `ulib-compat.mjs` mentions in the 2026-06-09
> update above as that subcommand. The old `.mjs` stays in-tree only until the `bin` CLI is retired.
> (Detail — the registry compiler-compat query behind the regenerate path is abstracted as a
> `REGISTRY` effect — lives in ADR 0029, which this layer's compat-map extends.)

## Consequences

- **Idiomatic code is fast on wasm with no user action** — no `spago install`, no `Wasm.*` in
  user code. JS portability is preserved (stock `purs` / `purs-backend-es` use the registry
  modules; the shadow is purs-wasm-only).
- **Maintenance tracks a few stable core packages**, not the daily package set — update a
  shadow only when its package releases.
- **Fidelity is the central risk**: a shadow must mirror its targeted version's interface
  exactly (hence "copy the source, replace only the foreigns" + version-pin + tests). A
  mismatch within a supposedly-matched version would miscompile.
- Needs a **lib location** and a **precompile step** (ship precompiled corefn, pinning a purs
  version, to avoid the npm `ignore-scripts` problem; later also MIR artifacts, ADR 0021).
- The shadow's own dependencies (`Wasm.*`) must be available when the lib is built; the lib
  bundles the resulting corefn, so a `Data.*`-only user gets WasmBase transitively without
  installing it.

## Alternatives considered

- **ulib as installable spago packages (coexisting with the registry).** Impossible: two
  versions of a package can't coexist in a build (global module names), and shadowing needs
  *override*, not coexistence; plus the registry can't publish a monorepo subdir (ADR 0026).
  Rejected.
- **Pin to a package-*set* version.** Infeasible — sets bump ~daily; chasing them is
  unsustainable. Rejected in favour of tracking the (stable) packages.
- **Hard error on version mismatch.** Brittle — a routine `arrays` bump would break builds.
  Rejected for graceful fallback + warning.
- **Ship only `Wasm.*` and make users rewrite over it.** Defeats "idiomatic is fast" (users
  would hand-port hot paths). Rejected — that is exactly what the shadow avoids.

## References

- ADR 0026 (WasmBase primitive layer; `Wasm.Int` now needed for low-level shadows).
- ADR 0027 (post-inline specialization — what makes the PureScript shadows fast).
- ADR 0021 (precompiled / MIR artifacts as the lib's incremental form).
- ADR 0011 / 0025 (packaging / platform — where the bundled lib ships).
- Issues #5 (foreign HOF specialization), #19 (monomorphization — the residual cost).
- The registry per-package `compilers` metadata (`metadata/<pkg>.json`) — the per-version
  compatibility-record precedent this mirrors.
