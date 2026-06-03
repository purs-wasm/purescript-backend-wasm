# Compilation pipeline overview

What happens between the PureScript compiler's output and a runnable `.wasm`. Each
stage is described once here; the deep dives live in
[Optimizations](./optimizations.md), [Runtime representation](./runtime-representation.md),
[JS↔WASM interop](./interop.md), and the [ADRs](./design-decisions).

```text
purs (0.15.16)
  │   corefn.json + externs.cbor      (per module)
  ▼
[1] decode ─────────▶ CoreFn AST + ExternsFile
  ▼
[2] translate ──────▶ MIR  (uncurried middle IR)
  ▼
[3] optimize ───────▶ MIR  (whole-program: lambda lift → specialize / dict-elim / inline, to a fixed point)
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

`MiddleEnd.optimizeProgram` runs the optimization passes **whole-program** (a function
or dictionary used in one module is defined in another, so the passes see all linked
modules at once) and to a **fixed point**: lambda lifting, then rounds of higher-order
specialization and dictionary-elimination/inlining simplification until the program
stops changing. The output is still MIR. See [Optimizations](./optimizations.md) for the
individual transformations.

## 4. Lower to the backend IR

`Lower.lowerModules` lowers MIR to the **backend IR** (an ANF-ish tree the code
generator consumes directly). This stage decides the *physical* shape of the program:

- **Representation analysis & unboxing** (ADR 0013) — assign each value slot a
  representation (`i32`/`f64`/`eqref`/closure) and unbox scalars where the `eqref` is
  unnecessary; read the per-constructor field representations from the externs.
- **Closure / application lowering** — closures become `$Clo` construction and arity-1
  `call_ref` application; a saturated call to a known top-level function is a direct
  call (lambda lifting in stage 3 already floated capturing/recursive closures out).
- **Foreign resolution** — a `foreign import` becomes a host-import call carrying its
  marshalling signature (the first rung of the [provider ladder](./interop.md)).
- **Reachability pruning (DCE)** — only functions reachable from the entry module's
  exports are lowered, tree-shaking the dictionaries and helpers optimization made dead
  (ADR 0009).
- Plus label interning for records and the export signatures.

## 5. Code generation

`Codegen.buildModule` turns the backend IR into a **Binaryen module** — the actual
wasm. It builds the value-type substrate (`Codegen.RuntimeTypes`; see
[Runtime representation](./runtime-representation.md)), emits each function body and
call, applies **tail-call elimination** (a tail self-call becomes `return_call`, so
deep recursion runs in constant stack), and adds the host-facing export wrappers, the
foreign host imports, and the `internStr` resolver. The module is validated, then
emitted as a binary (or disassembled to WAT with `--text`).

## 6. Linking and runtime integration

> **Note — stopgap.** This final stage (how modules are loaded and linked, and how the
> shared runtime is integrated) is a provisional implementation; a proper one is about
> to be built. Treat the specifics below as the *current* mechanism, not the intended
> design. (Today the CLI loads the whole `output/` directory and all module ASTs up
> front rather than demand-driven, and the runtime is stitched in with `wasm-merge`.)

The generated module imports the **shared runtime** (`$rt.*` helpers and the value
types, hand-written in `runtime/runtime.wat`; ADR 0010). To produce something runnable
the CLI (`bin`, `Main.purs`):

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
| 4. lower | `Lower` (`lowerModules`), incl. `Lower.Unbox` (representation analysis) |
| 5. codegen | `Codegen` (`buildModule`), `Codegen.RuntimeTypes` |
| pipeline glue | `Compiler` (`parseModule` / `compileModules`) |
| 6. link + runtime (stopgap) | `bin/src/Main.purs`, `runtime/runtime.wat` |
