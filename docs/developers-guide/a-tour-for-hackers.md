# A Tour for Hackers

Since you are reading this page, it means you are interested in contributing to purs-wasm. Welcome!
In this page, we describe the procedures and guidelines for working on the backend: running the dev CLI, adding an intrinsic, installing a `ulib` library, running the tests, and benchmarking. For the *workflow* (branching, PRs, commit messages, CI gates) see [`CONTRIBUTING.md`](../../CONTRIBUTING.md); for coding conventions see
[`CLAUDE.md`](../../CLAUDE.md); for the design rationale see the
[ADRs](../design-decisions). The pipeline these steps act on is mapped in
[compilation-pipeline.md](./compilation-pipeline.md).

## Environment

The toolchain is pinned with Nix. Work from inside the dev shell:

```sh
nix develop                 # purs, spago, esbuild, node, binaryen tools, purs-tidy
pnpm install                # the FFI npm deps (binaryen, cbor) across the workspace
git config core.hooksPath .githooks   # once per clone — local mirror of the CI gates
```

The repository is a **monorepo** setup using pnpm and spago: `compiler`, `purs-wasm`, `ulib-tooling`, `bench`, `binaryen` and `examples`.

- `spago build` (no `-p`) compiles every package into the shared `output/`
- `spago build -p <pkg>` builds one and its dependencies
- For each package, several npm scripts are available via `pnpm -F {package} run {script}`. For instance, to build the runtime, run `pnpm -F ./compiler run build:runtime`
- To run the full test suite, run `pnpm -F ./compiler run test`

## Running the dev CLI (`purs-wasm`)

`purs-wasm` is the user-facing build CLI. In development you run it through its dev entry `purs-wasm/index.dev.js`, which resolves `runtime/` and `lib/` from the repo root (the published package resolves them from the package dir).

One-time setup — compile the CLI and install the bundled `ulib` library it links against:

```sh
# Build spago-packages necessary to run bench
spago build -p purs-wasm                       # compile the CLI -> output/
spago build -p bench --output bench/output     # prime .spago with the ulib deps (incl wasm-base)
spago build -p ulib-tooling                     # compile the maintainer tool

# ...or build the whole workspace at once!
spago build

# Then install ulib packages. 
node ulib-tooling/index.dev.js install
```

Then build any project whose `purs` artifacts (`corefn.json` + `externs.cbor`) sit under an
input directory:

```sh
node purs-wasm/index.dev.js build -e Main -I output -O output-wasm
```

Key flags (full list in [overview.md](../getting-started/overview.md#compiler-options)):
`-e <Module>` entry (repeatable, required) · `-I <dir>` input (default `output`) ·
`-O <dir>` output (default `output-wasm`) · `-p <node|browser|standalone>` platform ·
`-E` executable loader · `-t` emit `.wat` · `-g` debug (skip the Binaryen optimizer) ·
`-f`/`--force` ignore the incremental cache · `--no-opt` skip the middle-end optimizer ·
`--dump-mir <Module>` dump a module's optimized MIR.

## Adding an intrinsic / primitive

A typical case of contributing is of "adding the package support to ulib".
Basically, it is welcome -- but special consideration is needed for implementing those, which is not the case for an ordinary JS-backed PureScript library.

A `foreign import` is resolved down a **provider ladder** (ADR
[0014](../design-decisions/0014-user-ffi-resolution-and-marshalling.md)):

1. **intrinsic** — lowered inline to a Binaryen op (the fast path);
2. **`wasm-base` `Wasm.*` primitive** — a PureScript primitive whose foreign resolves to an intrinsic on this backend (ADR [0026](../design-decisions/0026-wasmbase-primitive-layer.md));
3. **`ulib` wasm foreign** — a library's hand-written `foreign.wasm`/`.wat` in `lib/`;
4. **JS fallback** — the module's `foreign.js` via the loader.

Rungs 1–2 are where you add a *primitive*. The choice between them:

| Add an **intrinsic table entry** when… | Add a **`wasm-base` `Wasm.*`** primitive when… |
| - | - |
| the operation is **already a foreign in a standard/registry package you don't own** (`Prelude`'s `intAdd`, `Effect.Ref`, `Data.Array.length`, `Data.Function.Uncurried.*`). You can't add `Wasm.*` to upstream packages, so the backend recognizes their foreign by name and accelerates *existing* ecosystem code automatically. | you need a **new primitive building block** that no upstream package exposes (e.g. `Wasm.Array.unsafeNew/unsafeSet`, `Wasm.String` byte ops) — typically as the substrate `ulib` shadows are written over. |

### Adding an intrinsic table entry (rung 1)

In `compiler/src/PureScript/Backend/Wasm/Intrinsics.purs`:

- `foreignIntrinsic` — keyed by the **bare** identifier, for names unique across linked
  modules (`intAdd`, `concatString`, …).
- `qualifiedIntrinsic` — keyed by the **qualified** name, for generic names that can't be
  claimed globally (`Effect.Ref.read`, `Data.Array.unsafeIndexImpl`, the `Wasm.*` entries).

Each entry maps the name to an `Intrinsic` (a closed enum, *keyed by operation*) plus its
**arity**. The arity of an effectful op (result `Effect _`) counts its value parameters
**plus the trailing perform-unit** (ADR
[0019](../design-decisions/0019-faithful-effect-lowering.md)) — e.g. `Effect.Ref.write` is
arity 3. If the op is effectful, also list it in `effectfulForeignNames` so the optimizer
preserves its `Perform`.

If the operation is genuinely new (not just an alias of an existing `Intrinsic`):

1. add the `Intrinsic` constructor in `Intrinsics.purs`;
2. generate it in `compiler/src/PureScript/Backend/Wasm/Codegen/Prim.purs` (`genPrim` —
   `Intrinsic` → Binaryen);
3. mind the representation/unboxing of its operands and result (ADR
   [0013](../design-decisions/0013-int-number-unboxing.md)).

### Adding a `wasm-base` primitive (rung 2)

`wasm-base` is its **own repository** (`purs-wasm/purescript-wasm-base`), consumed here as a
git-pinned `extraPackages` dependency in the root [`spago.yaml`](../../spago.yaml). Adding a
`Wasm.*` primitive therefore spans two repos, in lockstep:

1. in `purescript-wasm-base`: add the `Wasm.X` PureScript module declaring the primitive,
   **with a real `foreign.js`** (so a `wasm-base`-using project still compiles and runs on
   stock `purs` / `purs-backend-es` — it is not locked to this backend), and release a tag;
2. here: add the `qualifiedIntrinsic` mapping (+ `Intrinsic`/`genPrim` as above) so the
   foreign resolves to the intrinsic on wasm, and bump the git pin in `spago.yaml`.

Two constraints (ADR 0026):

- **Capability coupling.** The set of `Wasm.*` names the backend recognizes *is* the ABI
  contract. A `Wasm.*` foreign the backend doesn't recognize silently degrades to the JS
  fallback on wasm — keep `wasm-base` within what this backend's intrinsic table provides,
  and bump `wasm-base`'s version in step with the recognized set.
- **Single-allocation invariant.** A `Wasm.Array.unsafeNew`-style primitive that allocates
  must be authored so the optimizer cannot duplicate the allocation site (a duplicated
  `unsafeNew` lowers to an illegal cast). See the array-shadow notes when adding allocating
  array/string primitives.

## Adding a library to `ulib` and installing it into `$PURS_WASM_LIB`

`ulib` is the compiler-bundled library layer: PureScript **shadow** modules written over the
`Wasm.*` primitives, merged last-wins into `$PURS_WASM_LIB` (defaults to `./lib`) and consulted ahead of the registry sources
at build time (ADR [0031](../design-decisions/0031-ulib-unified-library-modules.md)).

1. Add the shadow under `ulib/<package>/<Module>.purs` (and, if it needs a hand-written wasm
   foreign, a co-located `<Module>.wat` fragment over the shared `_header.wat`).
2. Record the package + module in `$PURS_WASM_LIB/ulib-manifest.json`.
3. Install — compile the shadows into the per-module lib:

   ```sh
   spago build -p bench --output bench/output    # ensure .spago has the shadows' deps
   node ulib-tooling/index.dev.js install         # -> lib/<Module>/{corefn.json,externs.cbor,foreign.wasm,foreign.wat}
   #                                              add -f to force a clean rebuild
   ```

4. **Verify the installed shadows match their public interface**:

   ```sh
   node ulib-tooling/index.dev.js check
   ```

A build reads `$PURS_WASM_LIB` (and `$PURS_WASM_LIB/ulib-manifest.json`) at link time, so re-run `install` after
changing any shadow. The shadow-authoring rules (the single-allocation invariant, what may be
shadowed) live with the [ulib design](../design-decisions/0031-ulib-unified-library-modules.md).

## Test suite

Each package has npm scripts; run them in the package directory (or with `pnpm -F ./<pkg>
run <script>`). CI runs `compile → test → check` for `compiler` and `binaryen`.

**`compiler`** (the bulk of the suite):

```sh
cd compiler
npm run test:unit        # spago test — type-class laws, codecs, optimizer/lowering invariants
npm run test:e2e         # builds runtime.wasm, prebuilds fixtures, runs Test.E2E.Cli (build->run)
npm run test:shownumber  # numeric formatting end-to-end
npm run test:bin         # the .mjs functional tests: Effect, Ref, source-foreign, ulib shadows, …
npm run test             # all of the above
```

Other packages: `pnpm -F ./purs-wasm run test:unit`, `pnpm -F ./ulib-tooling run test`.

Formatting is part of the gate — run `purs-tidy` before committing (`npm run format` in a
package, `npm run check` to verify; the `pre-push` hook runs the full suite).

Conventions for *what* to test (one `spec` per module, edge cases, the `unsafe` rule) are in
[`CLAUDE.md`](../../CLAUDE.md); a bug fix must carry a regression guard in the routinely-run
lane (unit / e2e), per [`CONTRIBUTING.md`](../../CONTRIBUTING.md).

## Benchmarks

The `bench` package builds three wasm bundles (`main`, `count-effect`, `curry`, each with
`--force`) and times them, comparing against a committed baseline.

```sh
cd bench
npm run snapshot     # build + run, write snapshots/<datetime>/{results.json,*.dat,*.png}, COMPARE to baseline
node run.mjs <dir>   # the comparison run alone (no rebuild), into snapshots/<dir>/
```

For an optimizer / lowering / runtime change, take a `snapshot` before and after and confirm
no regression.

> **⚠️ Treat `snapshots/baseline.json` as protected.** `npm run base` — and a bare
> `node run.mjs` with **no** directory argument — **overwrite** the committed baseline. Only
> update the baseline **deliberately**, for a real and explained performance change, and
> review the diff before committing it. Never overwrite it as a side effect of measuring; use
> `npm run snapshot` (or `node run.mjs <dir>`) to compare.

Absolute timings are machine-dependent, so the trustworthy signals are **relative deltas on
one machine** and **output determinism** (the emitted wasm is byte-deterministic — a behaviour
change shows as a checksum/size change, ADR
[0009](../design-decisions/0009-build-and-linking-model.md)). The graph helpers
(`npm run graph*`) render the snapshot `.dat` files with gnuplot.
