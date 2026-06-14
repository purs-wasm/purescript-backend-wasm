# Compilation pipeline overview

What happens between the PureScript compiler's output and a runnable `.wasm`. Each
stage is described once here; the deep dives live in
[Optimizations](./optimizations.md), [Runtime representation](./runtime-representation.md),
[JS↔WASM interop](./interop.md), and the [ADRs](../design-decisions).

```text
purs (0.15.16)
  │   corefn.json + externs.cbor      (per module)
  ▼
[1] decode ─────────▶ CoreFn AST + ExternsFile
  ▼
[2] translate ──────▶ MIR  (uncurried middle IR)
  ▼
[3] optimize ───────▶ MIR  (lambda lift → specialize → per-module simplify/dict-elim/inline/impurify, in dependency order)
  ▼
[4] lower ──────────▶ backend IR  (representation analysis & unboxing, closure/apply lowering, foreign resolution, reachability DCE)
  ▼
[5] codegen ────────▶ Binaryen module ─ validate ─ emit ▶ app.wasm
  ▼
[6] link + runtime  ─ merge runtime.wasm (+ wasm/wat foreigns); emit JS loader for JS foreigns    ← stopgap, see note
  ▼
index.wasm   (+ index.mjs loader, only if there are JS foreigns)
```

- [Input: the PureScript compiler's artifacts](#input)
- [1. Decode](#1-decode)
- [2. Translate to the middle IR](#2-translate-to-the-middle-ir)
- [3. Optimize (whole-program middle-end)](#3-optimize)
- [4. Lower to the backend IR](#4-lower-to-the-backend-ir)
- [5. Code generation](#5-code-generation)
- [6. Linking and runtime integration](#6-linking-and-runtime-integration)
- [Module map](#module-map)

## Input

The backend consumes the **PureScript compiler's own artifacts** (purs 0.15.16), one
pair per module:

- **`corefn.json`** — the module's CoreFn AST (the desugared, typeclass-resolved core
  language). This is the program to compile.
- **`externs.cbor`** — the module's interface, including the **type information CoreFn
  erases**. It is what lets the backend make type-directed decisions CoreFn alone
  cannot: which ADT fields are concrete scalars (so they can be unboxed — ADR 0013),
  and the marshalling signature of each `foreign import` (ADR 0014).

The backend does not invoke `purs`; it reads what `purs` already emitted.

## 1. Decode

`corefn.json` is parsed into the CoreFn AST (`PureScript.CoreFn.FromJSON`), and
`externs.cbor` is decoded (CBOR → `Foreign` → a generic decoder) into an `ExternsFile`.
Both decoders are anchored to fixtures of real purs output.

## 2. Translate to the middle IR

`MiddleEnd.Transl` translates CoreFn to the **middle IR (MIR)** — a faithful, mechanical
mapping whose only structural change is **uncurrying**: an `Abs`/`App` carries a
parameter/argument *list*, so arity is explicit. Dictionaries and records stay ordinary
values (eliminating them is a later pass, not part of the IR); the `Meta` later passes
need (`IsTypeClassConstructor`, `IsNewtype`) is kept on the binding. This is the
boundary of the "front" — no optimization happens here.

## 3. Optimize

`MiddleEnd.optimizeProgram` builds its optimization context **whole-program** (a function
or dictionary used in one module is defined in another, so the inline / dictionary /
purity sets are gathered across all linked modules), but optimizes the modules **one at a
time in dependency order** (ADR 0021), not in repeated whole-program rounds: lambda
lifting (per module), then higher-order specialization (whole-program), then — for
each module, against its already-finalized dependencies — simplify (dictionary
elimination + inlining), impurify (the `Effect` rewrite), and simplify again; finally a
**second** whole-program specialization (ADR 0027, to catch the `where`-worker idiom that
inlining exposes) and a β/reduce-only simplify. The output is still MIR. See [Optimizations](./optimizations.md) for the individual transformations.

### The MIR cache: `.pmo` files (incremental rebuilds)

The optimized MIR of stage 3 is the unit the **incremental rebuild** caches. Once a
module's optimized output is a pure function of `(its corefn, its dependency summaries)`
(ADR 0032), a rebuild can skip the ~2 s middle-end for an unchanged module and reload its
MIR instead (ADR 0021 *Future: incremental compilation cache*; ADR 0032 phase 4). Each
module's optimized MIR is persisted to a **`.pmo`** file ("PureScript Module Object", by
analogy with the ML `.cmo` / `.cmi` whose interface-hash invalidation this mirrors), one
per module, in the build work directory:

```text
output-wasm/_build/<Qualified.Module.Name>.pmo     e.g. output-wasm/_build/Data.Maybe.pmo
```

A `.pmo` is **header + body**:

- **Header** — a magic number, a format version, and the **cache key**: the corefn hash
  ⊕ the hashes of the dependency summaries the module consumed. On a build the key is
  recomputed and compared to the header; a mismatch (the source changed, a dependency's
  summary changed, or the codec version moved) is a **miss** — the module is re-optimized
  and its `.pmo` rewritten. (`.pmo` over `.mir` deliberately: `.mir` collides with Rust's
  MIR dumps.)
- **Body** — the optimized MIR, encoded by `MiddleEnd.Serialize` (over the byte writer
  `MiddleEnd.Serialize.Bytes`). It is **not** Argonaut-generic JSON (measured ≈ the corefn
  decode cost — too slow to beat re-optimizing) but a compact *tagged tree*: a one-byte tag
  selects each node's constructor, then its fields in declaration order, mirroring
  `MiddleEnd.IR`. Leaves: `Int` is zigzag [LEB128](https://en.wikipedia.org/wiki/LEB128)
  (compact for the small magnitudes that dominate — tags, arities, lengths); `Number` is
  8-byte little-endian IEEE-754; `String` is a byte-length prefix then UTF-8; arrays are a
  length prefix then their elements; `Maybe` / `Either` are a one-byte discriminant then the
  payload.

`Serialize.encode` / `decode` round-trip the body exactly (`decode (encode m) == Right m`,
gated by unit tests over every node, both branches, and the leaf edge cases); the header
(magic, version, key) belongs to the cache layer that wraps them, not the codec. The codec
recurses naively, like the rest of the middle end; a pathologically deep tree (past a few
thousand frames) surfaces as a `decode` `Left` or a skipped write — a **safe cache miss
that recomputes**, never a corrupt tree. `.pmo` is binary only; the human-readable view of
MIR is the one-way `--dump-mir` dump (`MiddleEnd.Print`), not a re-parseable form.

## 4. Lower to the backend IR

`Lower.lowerModules` lowers MIR to the **backend IR** (an ANF-ish tree the code
generator consumes directly). This stage decides the *physical* shape of the program:

- **Representation analysis & unboxing** (ADR 0013) — when optimizing, assign each value slot
  a representation (`i32`/`f64`/`eqref`/closure) and unbox scalars where the `eqref` is
  unnecessary; read the per-constructor field representations from the externs. (Under
  `--no-opt` the slot analysis is skipped — every slot stays boxed `eqref` — though the
  constructor field reps are still threaded.)
- **Closure / application lowering** — closures become `$Clo` construction and arity-1
  `call_ref` application; a saturated call to a known top-level function is a direct
  call (lambda lifting in stage 3 already floated capturing/recursive closures out).
- **Foreign resolution** — a `foreign import` that maps to a built-in **intrinsic** is
  lowered inline (rung 1 of the [provider ladder](./interop.md) — `intAdd` and friends);
  any other becomes an import call (`RCallForeign`) carrying its marshalling signature,
  to be satisfied at link time (stage 6) by a wasm/wat provider (rung 2) or the JS loader
  (rung 3).
- **Reachability pruning (DCE)** — only functions reachable from the entry module's
  exports are lowered, tree-shaking the dictionaries and helpers optimization made dead
  (ADR 0009).
- Plus label interning for records and the export signatures.

## 5. Code generation

`Codegen.buildModule` turns the backend IR into a **Binaryen module** — the actual
wasm. It builds the value-type substrate (`Codegen.RuntimeTypes`; see
[Runtime representation](./runtime-representation.md)), emits each function body and
call, applies **tail-call elimination** (a tail call to a known top-level function — self-
*or* mutual recursion — becomes `return_call`, so deep recursion runs in constant stack), and
adds the host-facing export wrappers, the
foreign host imports, and the `internStr` resolver. The module is validated, then
emitted as a binary (or disassembled to WAT with `--text`).

## 6. Linking and runtime integration

> **Note — stopgap.** This final stage (how modules are loaded and linked, and how the
> shared runtime is integrated) is a provisional implementation; a proper one is about
> to be built. Treat the specifics below as the *current* mechanism, not the intended
> design. (Today the CLI enumerates the whole `output/` directory but, before the
> expensive decode, prunes to the modules reachable from the entry roots — reading each
> module's imports cheaply and full-decoding only the reachable set — and stitches the
> runtime in with `wasm-merge`. Demand-driven / streaming codegen — ADR 0021 — is the
> part still to come.)

The generated module imports the **shared runtime** (`$rt.*` helpers and the value
types, hand-written in `runtime/runtime.wat`; ADR 0010). To produce something runnable
the CLI (`purs-wasm`, `PursWasm.CLI.Main`):

- merges `runtime.wasm` into the app with `wasm-merge` (and merges any `foreign.wasm` /
  `foreign.wat` providers — ADR 0014 rung 2), resolving the imports into one wasm;
- if the program calls **JS foreigns**, emits a JavaScript **loader** (`index.mjs`) that
  supplies them from each module's `foreign.js` with the [marshalling glue](./interop.md);
- a program with no JS foreigns is a single self-contained `index.wasm`.

## Module map

| Stage | Where |
| - | - |
| 1. decode | `PureScript.CoreFn.FromJSON`, `PureScript.ExternsFile` (+ its CBOR decoder) |
| 2. translate | `MiddleEnd.Transl` |
| 3. optimize | `MiddleEnd` (`optimizeProgram`) and `MiddleEnd.Optimize.*` |
| MIR cache (codec) | `MiddleEnd.Serialize`, `MiddleEnd.Serialize.Bytes` |
| 4. lower | `Lower` (`lowerModules`), incl. `Lower.Unbox` (representation analysis) |
| 5. codegen | `Codegen` (`buildModule`), `Codegen.RuntimeTypes` |
| pipeline glue | `Compiler` (`parseModule` / `compileModules`) |
| 6. link + runtime (stopgap) | `purs-wasm/src/PursWasm/CLI/{Main,Build}.purs`, `runtime/runtime.wat` |
