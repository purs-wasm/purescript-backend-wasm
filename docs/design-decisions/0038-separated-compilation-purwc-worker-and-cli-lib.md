# 0038. Separated compilation: the `purwc` worker, the `purs-wasm` orchestrator, and the shared `cli-lib`

- Status: Accepted; **Phase A + Phase B M1/M2a/M2b implemented**. Phase A (2026-06-18) — `cli-lib`
  extracted, three CLIs re-homed (behaviour-neutral). Phase B M0+M1 (2026-06-19) — the two
  single-module compiler APIs (`MiddleEnd.compileModuleMir` = optimize one module against its
  dependency summaries; `Compiler.compileModuleWasm` = lower+codegen one module) and the `purwc
  compile` worker CLI. Phase B M2a — **`.pmi` extended to the complete module interface** (`.pmi` v2):
  besides the optimization summary it carries the lowering interface (`funcs`/`ctors`/`dictCtors`/
  `enumCtors`/`foreignSigs`/`foreignNames`) + `labels`, all derived from a module's own finalized MIR
  (`Compiler.moduleInterface`). Phase B M2b — the worker now **consumes `.pmi` interfaces ONLY**, never
  a dependency's `.pmo`: `Lower.lowerModuleWithInterfaces` builds the lowering `ModuleInfo` by merging
  the target's own `collect*` tables with the dependencies' `.pmi` interface tables (`DepInterface`);
  `compileModuleWasm` takes `Array DepInterface` (was `Array M.Module`); `purwc compile --deps` loads
  each dependency `.pmi` once (summary → optimizer context, interface tables → codegen context); and
  **the worker stops writing `.pmo`**. Verified on a 2-module cross-module fixture
  (`Purwc.Fixture.User` → `Dep`): each module's `.pmi` is byte-identical to the oracle and the merged
  program is behaviour-identical to the whole-program build (a per-module `.wasm` legitimately diverges
  in bytes — the worker over-exports all its functions since it cannot see its dependents, pinning more
  to the boxed ABI; behaviour-safe). Phase B M3 (2026-06-19) — **scale-verified** (no code change): the
  `.pmi`-only architecture is correct across a 3-module transitive chain (Top→Mid→Base), cross-module
  constructor construct/match (a `Box` with a field — tag/arity/fieldReps resolved from the dep `.pmi`),
  and a re-exported `foreign import` (resolved via the dep `.pmi`'s `foreignSigs`, with the precise
  `i32→i32` marshalling, NOT the opaque fallback) — every module's `.pmi` byte-identical to the oracle,
  all merged programs behaviour-identical. The `summaryInlineKeys` locality concern was measured benign:
  the divergence needs a *large, non-collapsible* binding used 2+ times by dependents and 0 locally, but
  the optimizer's case-of-case collapse makes such bindings small (kept by the size criterion on both
  sides), so even an adversarial construction kept the `.pmi` identical; if it ever bites it is
  perf/`.pmi`-size only, never correctness. Deferred perf refinement: over-export only the module's
  *exported* functions (not all), to avoid boxing internal helpers — needs the CoreFn export list
  threaded to lowering. Phase C (orchestrator: dependency-graph driving + pre-merge label-collision
  check + retire `.pmo`/`--per-module-codegen`) remains.
- Date: 2026-06-18 (Phase B M1 + M2a + M2b + M3: 2026-06-19)

## Context

ADR 0037 made codegen per-module (`--per-module-codegen`): each module is lowered and emitted to its
own wasm, then `wasm-merge`d. But that flag is still a *whole-program* process — `compilePerModule`
takes the whole optimized module array and emits every module's wasm in one `Effect`, after the
whole-program optimizer (`optimizeIncrementalM`) has run across all modules in one process. It is
per-module *codegen*, not per-module *compilation*.

The next stage is **truly separated compilation**, the "batch compiler" shape: one module compiled
in isolation, from its own inputs plus its dependencies' *interfaces* — so module compilations are
independent processes that can run in parallel and be cached at the process boundary.

Two existing ADRs already make this sound:

- **ADR 0032 (caller-homed specialization)** keeps the per-module property under cross-module
  specialization: each caller homes its own `f$specN` against its dependencies' *summaries*, so a
  module's output never depends on its dependents. No upward dependency to break isolation.
- **ADR 0034 (`.pmi`/`.pmo` split)** makes a dependency's `.pmi` **summary** the necessary and
  sufficient optimization context for a dependent — a changed module is optimized loading only its
  dependencies' `.pmi`s, never their full MIR. The `.pmi` summary *is* the module interface a
  separate-process compile needs.

So the inputs to compile one module `M` in isolation are: `M`'s `corefn.json` + `externs.cbor` + the
foreign signatures it needs, and the `.pmi` of each of `M`'s dependencies. The outputs are `M.pmi`
(interface), `M.pmo` (optimized MIR object), and `M.wasm` (its codegen, ready for `wasm-merge`) — and
`M.wat` on request.

This restructures responsibilities:

- **`purwc`** — a small worker CLI that compiles **one** module: load → optimize (against dependency
  `.pmi`s) → lower → codegen → write `M.{pmi,pmo,wasm,wat}`.
- **`purs-wasm`** — the orchestrator: build the module dependency graph, run `purwc` per module in
  dependency order, then `wasm-merge` the per-module wasms (+ runtime + foreign providers) into the
  final artifact, emitting the loader. The whole packaging tail it already owns stays.

That creates a **logical dependency cycle**: `purs-wasm` invokes `purwc`, while `purwc` wants
`purs-wasm`'s library code (the effect layer, externs/foreign-sig readers, compatibility guards). The
cycle is resolved by extracting the **lower layer both share** into a new package, **`cli-lib`**, on
which `purs-wasm`, `purwc`, and the maintainer `ulib-tooling` all depend — and none of which depends
on another binary.

## Decision

**Invocation model: subprocess.** `purs-wasm` spawns `purwc` as an OS process per module (not an
in-process library call). This is the literal "separated compilation" shape: process isolation, a
path to module-level parallelism, and a clean cut of the `purs-wasm` ⇄ `purwc` cycle (CLI → CLI, no
shared mutable Binaryen state across modules). The cost — `binaryen.js` initialization per process —
is accepted; it is amortized by parallelism and per-module wasm caching (ADR 0037 Phase 3), and the
dominant build cost is already inside `binaryen.js` regardless.

**`cli-lib` boundary.** `cli-lib` owns the shared, binary-agnostic CLI foundation, under the
namespace `PureScript.Backend.Wasm.CLI.*`:

- the abstract effect layer (`Effect` + `Effect.{Env,Filesystem,Log,Process,Registry}`) and the
  synchronous Node interpreter (`Node`, `runNode`);
- option globals (`Options.withGlobals`, `Options.Types.GlobalOptions`);
- the readers/resolvers shared by compilation: `Externs`, `ForeignSigs`, `Paths`, `Lib`, `Module`,
  and the ulib resolution (`Ulib.Manifest`, `Ulib.Shadow`);
- the compatibility guards (`Compat`).

Each binary stays a thin layer: its `Main`, its command `Options`/`Options.Types`, its `Version`, and
(for `purs-wasm`) the `Build` orchestrator + `Build.Loader`/`Build.Foreign` packaging tail. A binary's
own version string is **not** in `cli-lib` (it is per-binary, from generated `BuildInfo`); the one
shared check that referenced it, `Compat.checkWasmBaseCompat`, takes the backend version as a
parameter so `cli-lib` is decoupled from any binary's `Version`.

`ulib-tooling` likewise re-homes from `purs-wasm` onto `cli-lib` — the maintainer machinery never
needed the orchestrator, only the shared infra.

### Phasing

- **Phase A — `cli-lib` extraction (this ADR, done 2026-06-18).** Move the shared modules into
  `cli-lib`; re-home `purs-wasm`, `purwc` (scaffold), and `ulib-tooling` onto it. Behaviour-neutral —
  verified by the unit suites (cli-lib 33, purs-wasm 12, ulib-tooling 37) and the full e2e CLI suite
  (153/153, the real `purs-wasm build` per fixture + `ulib-tooling install`). No new compilation
  semantics.
- **Phase B — the `purwc` worker.** A single-module compile entry: given `M`'s corefn/externs/foreign
  sigs and its dependencies' `.pmi`s, optimize `M` in isolation (extract the single-module step out of
  the batch `optimizeIncrementalM`), lower + codegen it (the single-module path already exists inside
  `compilePerModule`), and write `M.{pmi,pmo,wasm,wat}`. Differentially checked against the current
  `--per-module-codegen` output. Decomposed into milestones:
  - **M0 + M1 (done 2026-06-19)** — the two compiler APIs and the `purwc compile` CLI. `compileModuleMir`
    folds the dependency summaries to rebuild the optimization context (the cache-hit fold of
    `optimizeIncrementalM`) then runs the per-module miss step; `compileModuleWasm` reuses
    `lowerProgramFragments [deps…, target]` and codegens only the target fragment via `buildModuleSingle`
    (the worker emits no link glue and does no merge). The corefn-metadata FFI moved to cli-lib
    (`CLI.Corefn`). Verified on a dependency-free fixture (`Purwc.Fixture.Solo`): `purwc compile`'s
    `.pmi`/`.pmo`/`.wasm` are **byte-identical** to the oracle's per-module `_build/<M>.{pmi,pmo,wasm}`
    (`purwc/test/diffPurwc.mjs`).
  - **M2** — dependency-aware codegen: load deps' `.pmi`/`.pmo` from `--deps`, compute the transitive
    closure + topo order, byte-check a dependency-having module against the oracle (reusing the oracle's
    `.pmo` for deps).
  - **M3** — dependency-aware optimize: `purwc` produces its own `.pmi`/`.pmo`, compile a whole fixture
    module-by-module, `wasm-merge`, behaviour-parity against the whole-program oracle. The
    `summaryInlineKeys` locality question (above) is measured here.
  - **M4** — flags (`--no-opt`/`--force`/`--text`), errors, `--version`.
- **Phase C — the `purs-wasm` orchestrator.** Build the dependency graph, drive `purwc` per module as
  a subprocess (in dependency order, then in parallel), and `wasm-merge` the results. Once at parity,
  make this the default path and retire the in-process `--per-module-codegen`.

## Consequences

- The `purs-wasm` ⇄ `purwc` cycle cannot form: both sit above `cli-lib`, neither above the other.
- `ulib-tooling` no longer drags in the `purs-wasm` orchestrator package.
- The module interface for a separate-process compile is the existing `.pmi` (ADR 0034); no new
  interface format is introduced. The cross-module GC-type / call-boundary concerns are already
  handled by `wasm-merge` (ADR 0037 barriers ①–③).
- Per-binary `Version` divergence: `ulib-tooling`'s `--version` now reports its own (purs-compat-only)
  banner rather than borrowing `purs-wasm`'s semantic version — a maintainer-tool nicety, not a
  user-facing change.
- The per-process `binaryen.js` init cost is real; Phase C must measure it against the in-process path
  and rely on parallelism + the Phase-3 wasm cache to stay ahead.

## Alternatives considered

- **In-process library call** (`purs-wasm` calls a `purwc` compile function directly). Simpler, no
  IPC, but it is "separated compilation" in name only: no process isolation, no module-level
  parallelism, shared Binaryen state across modules, and the logical cycle is severed only by
  convention. Rejected as the end state; `cli-lib` would still be the right factoring under it, so
  Phase A is a no-regret step either way.
- **Keep everything in `purs-wasm` and let `purwc` depend on it.** Reintroduces the cycle the moment
  `purs-wasm` needs to invoke `purwc`. Rejected.
- **A new module-interface format for the worker.** Unnecessary — the `.pmi` summary already carries
  exactly the dependent-side optimization context (ADR 0034).
