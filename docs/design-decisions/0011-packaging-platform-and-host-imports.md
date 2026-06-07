# 0011. Packaging, platform targets, and host imports

- Status: Accepted
- Date: 2026-06-01

> **Status reaffirmed (2026-06-07):** The current implementation does **not yet** use the `--platform` flag scheme. Codegen always imports `$rt.*` ([ADR 0010](0010-runtime-as-a-separate-wasm-module.md)), and `bin` hard-codes a single packaging: a **standalone bundle (wasm-merge) plus a JS loader only when JS foreigns are present (`emitLoader`/`needLoader`)** — effectively the `standalone`/`node` target. `--platform` (`browser`/`browser-split`/the fallback-JS toggle, …) is split out as future work after the real `bin` implementation — see [ADR 0025](0025-multi-platform-packaging.md). This record's core (packaging is platform-specific, codegen is not) still holds.

## Context

ADR 0010 makes the shared runtime a separate wasm module that generated code
**imports** (`$rt.*`), with two consumer paths: `wasm-merge` into one self-contained
file, or instantiate-time wiring. That raised two broader questions the team worked
through and wants on record:

1. Does committing to a single bundled wasm preclude **split-module output** (which
   matters for browser load time)? Is splitting a fundamental limitation of our
   substrate (wasm GC, uniform `eqref`/`i31ref`) or a future feature?
2. Other toolchains (e.g. `wasm_of_ocaml`) ship a thin JS loader that **injects host
   functions** (`Math.cos`, `x => console.log(x)`, …) as wasm imports. Is that option
   open to us, and have we decided whether to use it?

## Decision

### Packaging is decoupled from code generation

The generated module **always** imports `$rt.*` (one codegen path, ADR 0010). How
those imports — and any host imports — are satisfied is a **packaging-stage**
choice, ~~selected by a CLI `--platform` flag~~. Codegen never changes per platform.

| `--platform` | runtime | packaging |
| --- | --- | --- |
| `standalone` / `node` / `wasi` (default) | bundled | `wasm-merge app + runtime` → one self-contained `.wasm` |
| `browser` | separate | emit `runtime.wasm` (shared, HTTP-cacheable) + `app.wasm` + a thin JS loader that instantiates and wires `{ rt: runtime.exports }` |
| `browser-split` (future) | separate | additionally chunk the app for lazy loading |

### Module splitting is a supported future feature, not a limitation

Two levels, distinguished:

- **Runtime / app split** — *already available*: it is the ADR 0010 import boundary
  minus the merge. `--platform browser` emits a cacheable `runtime.wasm` plus a
  smaller `app.wasm`. No new mechanism.
- **Application code-splitting** (lazy per-chunk loading) — a *future feature*, and
  **not blocked by our substrate**. The same two properties that make the runtime
  split safe carry over: (a) the uniform `eqref`/`i32`/`f64` calling convention
  (ADR 0004) keeps cross-chunk function signatures free of concrete types; (b)
  structurally-identical GC rec groups canonicalize across modules (spike-verified in
  ADR 0010), so a `$Str`/closure built in one chunk is usable in another. Closures
  use `ref.func` + `call_ref` (typed function references), avoiding the shared-table
  machinery of classic wasm dynamic linking. The remaining work is ordinary
  engineering, not a redesign: a dependency-aware **chunker** (built on the deferred
  `bin` reachability/tree-shaking rework), a **JS dynamic-link loader**, and handling
  of cross-chunk cyclic dependencies; each chunk re-declares the (~10-type) rec-group
  preamble. Mitigation order for binary size: first dead-code elimination
  (reachability) shrinks even the single binary; browsers stream-compile; then split
  when an app is genuinely large.

### Host imports: a deliberate spectrum, not all-or-nothing

Injecting JS host functions as wasm imports is technically available to us (it is the
same import mechanism as `$rt.*`; the JS loader just adds entries to the import
object). Note that importing `$rt.*` from *our* `runtime.wasm` is **not** a host
import — that runtime is pure wasm. Host imports are JS values/functions. The
decision, by category:

- **Internal runtime helpers** (`$rt.proj`/`strEq`/`showInt`/…): **pure wasm**, never
  host. Decided (ADR 0010).
- **Effects and user `foreign import`** (`console.log`, DOM, fetch, a user's JS FFI):
  host imports are **mandatory and correct** — there is no in-wasm alternative to a
  host call. Not in scope yet (Effect is deferred), but when Effect / user FFI land,
  the backend **will** emit host imports for them.
- **Heavy *pure* primitives** (`Number.toString` ⇒ Ryū, `Math.cos`/`sin`/`exp`, …):
  a genuine choice. Default is **self-contained** (implement in wasm; ADR 0002), with
  host import held as a `--platform`-gated escape hatch — e.g. `browser` imports
  `Math.cos`, `standalone` supplies a wasm `libm` or traps. Judged per primitive;
  this is the same call already made for `showNumber` (deferred to in-wasm Ryū rather
  than a host import).

The ADR 0002 **`ForeignProvider`** seam is exactly where this resolves: a foreign
identifier maps to an intrinsic, a runtime helper, **or** a host import, and that
mapping may depend on `--platform`.

## Consequences

- A `--platform` flag belongs on the `bin` CLI; it selects packaging only.
- `browser` output (cacheable runtime + small app + JS loader) is essentially free
  once ADR 0010 lands — it is the un-merged path.
- Host imports are an explicit, scoped capability, not the default. Standalone targets
  stay pure wasm; browser targets may slide toward a host-glue model when effects /
  user FFI / hard primitives require it.
- Code-splitting, when pursued, extends ADR 0009 (build & linking) and rides on the
  deferred `bin` reachability rework; it needs no change to the value representation.

## Alternatives considered

- **Commit only to a single self-contained binary.** Simplest, best for
  wasm runtimes / containers, but a poor fit for large browser apps (load time) and
  for effects that inherently need the host. Rejected as the *only* mode; kept as the
  default.
- **Follow `wasm_of_ocaml` wholesale** (JS runtime + many host imports + code
  splitting). Great browser integration, but sacrifices portability/self-containment
  by default. Rejected as the default; reachable per `--platform` when warranted.

## References

- ADR 0002 — FFI / runtime strategy; the `ForeignProvider` seam; self-contained goal.
- ADR 0004 — uniform `eqref` calling convention (why cross-module boundaries are
  type-clean).
- ADR 0009 — build & linking model (the chunker rides on its deferred rework).
- ADR 0010 — runtime as a separate wasm module (the import boundary this builds on).
