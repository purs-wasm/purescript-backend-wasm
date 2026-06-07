# 0025. Multi-platform packaging (`--platform`) and the fallback-JS toggle

- Status: Proposed
- Date: 2026-06-07

## Context

[ADR 0011](0011-packaging-platform-and-host-imports.md) decided that packaging is
decoupled from code generation: the platform is chosen by a CLI flag and codegen never
changes per platform. As of 2026-06-07, however, the implementation does **not** yet have
that flag — `bin` hard-codes a single packaging:

- Codegen always imports `$rt.*` from the `runtime` module ([ADR 0010](0010-runtime-as-a-separate-wasm-module.md)).
- `bin` emits a **standalone bundle**: `wasm-merge` (app + `runtime.wasm` + the used
  `ulib/*.wasm`) → one self-contained `.wasm`.
- A thin JS loader is emitted **only** when the program uses JS foreigns
  (`emitLoader` / `needLoader`, [ADR 0024](0024-export-boundary-arity-and-transparent-types.md)).
  Otherwise the `.wasm` runs on its own.

This is the `standalone` / `node` target of ADR 0011. The fuller multi-platform packaging —
`browser` / `browser-split`, and a toggle for whether unresolved foreigns fall back to JS —
is to be tackled once the real `bin` implementation (reachability pruning, streaming codegen
[ADR 0021](0021-streaming-dependency-ordered-wpo.md), …) has settled. This ADR carves that
future work out of ADR 0011 and **files it as a placeholder** (the detailed design is still open).

## Decision (sketch — design still open)

Add a `--platform` flag to `bin` that switches only packaging (codegen unchanged, following
ADR 0011's core):

| `--platform` | runtime | packaging |
| --- | --- | --- |
| `standalone` / `node` (default — **the current implementation**) | bundled | `wasm-merge app + runtime (+ ulib)` → one self-contained `.wasm` (plus the loader only when JS foreigns are used) |
| `wasi` | bundled | like standalone, but host imports are bound to a WASI shim |
| `browser` | separate | emit `runtime.wasm` (shared, HTTP-cacheable) + `app.wasm` + a thin JS loader that wires `{ rt: runtime.exports }` |
| `browser-split` (further out) | separate | additionally chunk the app for lazy loading |

Axes to settle alongside this:

- **fallback-JS toggle**: whether an unresolvable foreign falls back to a JS host import
  (the provider ladder of [ADR 0014](0014-user-ffi-resolution-and-marshalling.md)) or whether
  pure wasm is required and it traps. `browser` may borrow `Math.cos` etc. from the host while
  `standalone` supplies a wasm `libm` or traps — decided per primitive (ADR 0011 §host imports).
- generalize the current `emitLoader` into per-platform loader templates.

## Consequences

- ADR 0011 stays as "status reaffirmed (Accepted)"; the `--platform` future work is owned by this ADR.
- Placeholder only. Implementation waits on the real `bin`. Until then, the current
  (hard-coded standalone) packaging is the sole target.

## References

- [ADR 0010](0010-runtime-as-a-separate-wasm-module.md) — runtime as a separate wasm module
- [ADR 0011](0011-packaging-platform-and-host-imports.md) — packaging / platform / host-import principles (this ADR's parent)
- [ADR 0014](0014-user-ffi-resolution-and-marshalling.md) — the foreign-resolution ladder and marshalling
- [ADR 0021](0021-streaming-dependency-ordered-wpo.md) — streaming codegen (a prerequisite for the real impl)
- [ADR 0024](0024-export-boundary-arity-and-transparent-types.md) — `emitLoader` / the export boundary
