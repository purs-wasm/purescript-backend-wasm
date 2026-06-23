# 0042. Orchestrate as the default build; retiring the whole-program path and its differential oracles

- Status: Proposed
- Date: 2026-06-24

> Builds on [ADR 0037](0037-separate-per-module-codegen-and-linking.md) (per-module codegen) and
> [ADR 0038](0038-separated-compilation-purwc-worker-and-cli-lib.md) (the `purwc` worker + orchestrator),
> and on the content-addressed store of [ADR 0040](0040-global-content-addressed-library-cache.md).
> Companion to [ADR 0041](0041-prebuilt-library-artifacts-and-compatibility-gate.md).

## Context

Three build cores coexist today behind `purs-wasm build`:

- **whole-program** (`finishLink`, in-process) — the default, and the original well-tested path;
- **`--per-module-codegen`** (`compilePerModule`, in-process) — the per-module lower+codegen core,
  experimental;
- **`--orchestrate`** — drives the standalone `purwc` worker as a subprocess per module against the
  store ([ADR 0038](0038-separated-compilation-purwc-worker-and-cli-lib.md) /
  [ADR 0040](0040-global-content-addressed-library-cache.md)), opt-in.

Plus an experimental `--per-module-rep` flag (a per-module unboxing-boundary A/B measurement).

The whole-program path doubles as the **differential oracle** for the newer paths, via two checks:

- `diffPerModule` — `--per-module-codegen` vs whole-program `finishLink` (**codegen** equivalence);
- `diffPurwc` — the `purwc` worker (merged) vs `--per-module-codegen` (**orchestration plumbing**:
  subprocess + `.pmi` exchange + `wasm-merge` + link).

Intended end-state: orchestrate is *the* build mode; the experimental flags are gone; the whole-program
path survives only as an internal oracle until it has earned retirement.

| Intended | Current | Status |
| --- | --- | --- |
| orchestrate is the default; `--orchestrate` / `--per-module-rep` removed; `--per-module-codegen` not user-facing | orchestrate opt-in; all three flags present; whole-program is the default | not done |

## Decision

1. **Make orchestrate the default build mode.**
2. **Remove user-facing flags:** `--orchestrate` (always on) and `--per-module-rep` (delete — it was an
   A/B measurement aid).
3. **`--per-module-codegen`:** remove from the user-facing help, but **keep the `finishLink`
   (whole-program) and `compilePerModule` cores as internal test entries** — the oracles below depend
   on them. The user surface shrinks; the internal differential machinery does not (yet).
4. **Retire the differential oracles on triggers, not dates, in two stages** (a differential oracle is
   worth keeping exactly while one side is trusted and the other is being validated; it is dead weight
   once the new side has its own independent ground truth):

   - **`diffPurwc` (plumbing) — retire first.** The worker and `--per-module-codegen` share the same
     codegen core, so `diffPurwc` really only exercises the orchestration plumbing. Once `e2e` +
     `test:bin` run **through the orchestrate path** (every behavioural test then drives the plumbing)
     and the plumbing has been stable, `diffPurwc` is redundant.
   - **`diffPerModule` (codegen) + the whole-program path — retire later, on two conditions:**
     (a) orchestrate is the sole shipped path and behavioural tests assert **output** (independent
     ground truth), with that corpus covering the divergence categories the oracle has historically
     caught (cross-module ABI, foreign self-merge byte changes, `caf_init` reachability (#19),
     over-export, dict-elim, the `effectPrim` cluster); **and**
     (b) the practical signal fires — **the first time keeping the whole-program path green requires
     real work for a feature that only matters in the orchestrate path** ("the tail wagging the dog").
     Until (b), the whole-program path is cheap insurance — keep it.

5. **Link time becomes the perf frontier.** With orchestrate as default, the warm-build cost is
   dominated by **link** (`wasm-merge` + dead-code elimination), not codegen. Link-time optimization is
   the explicit follow-up.

## Consequences

- A smaller, clearer CLI surface (`build` has no per-module/orchestrate experimental flags).
- The whole-program and per-module-codegen cores live on **internally** purely to back `diffPerModule`
  until its retirement trigger — a deliberate, time-boxed-by-condition carry, not indefinite drift.
- Link time is surfaced as the next optimization target.

## Open questions

- Whether to route the existing `e2e` / `test:bin` suites through orchestrate wholesale (the
  precondition for retiring `diffPurwc`) in one step or incrementally.
- Whether any whole-program-only diagnostics (e.g. `--dump-mir`'s whole-program trace) need an
  orchestrate-path equivalent before the whole-program core is removed.
