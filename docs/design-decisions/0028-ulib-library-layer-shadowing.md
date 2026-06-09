# 0028. ulib as a compiler-bundled library layer: lib-first shadowing of registry modules

- Status: Proposed
- Date: 2026-06-09

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
