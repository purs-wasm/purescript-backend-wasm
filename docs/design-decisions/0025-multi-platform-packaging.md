# 0025. Multi-platform packaging (`--platform`) and the fallback-JS toggle

- Status: ~~Proposed~~ **Accepted** _(2026-06-13: `--platform` node/browser/standalone + `-E` shipped in #34; `wasi` and the browser runtime/app split remain future work)_
- Date: 2026-06-07

> **Update (2026-06-12):** the CLI that hard-codes the current standalone packaging is now
> `purs-wasm` (the `bin` prototype was retired/reimplemented; ADR 0031). ~~The `--platform` design
> below is unchanged and still unimplemented~~ — read every `bin` reference as `purs-wasm`.
>
> **Update (2026-06-13):** `--platform` **shipped** (commit 3eba9f7 / PR #34) — the Decision
> sketch below is now implemented, with the following deviations, which are authoritative over the
> original sketch:
>
> - The flag accepts `node | browser | standalone` (`PursWasm.CLI.Options.parsePlatform`), plus
>   `-E/--executable`, `--no-js-fallback`, and `--no-chunks`; `PursWasm.CLI.Build` dispatches
>   packaging on it. **`wasi` is not implemented** (deferred — issue #36).
> - **The default is `node`, not `standalone`.** `standalone` is a *distinct* target (always a
>   self-contained `.wasm`, no loader) that rejects `--executable` and forbids any JS-fallback
>   foreign. `node`/`browser` emit a JS loader **only when needed** (`needLoader`: JS foreigns,
>   non-scalar marshalled exports, or `-E`); an `i32`-only program with no JS foreigns is itself a
>   single self-contained `.wasm` even under `node`.
> - **`browser` still emits a single merged `.wasm`** (runtime `wasm-merge`d into the app; the
>   loader differs from `node` only in `fetch`-vs-file-read). The separate cacheable
>   `runtime.wasm` + `app.wasm` split (Decision table row `browser`) and `browser-split` chunking
>   remain **unimplemented future work**.
> - The **fallback-JS toggle is settled**: `--no-js-fallback` enforces wasm-only resolution, and
>   `standalone` forbids JS-fallback foreigns unconditionally.

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

> _(The Context above describes the state as of 2026-06-07. Most of that future work has since
> landed — `--platform` node/browser/standalone + `-E`, and the fallback-JS toggle; see the dated
> **Update (2026-06-13)** at the top. Only `wasi` and the browser runtime/app split remain.)_

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
- ~~Placeholder only. Implementation waits on the real `bin`. Until then, the current
  (hard-coded standalone) packaging is the sole target.~~ _(2026-06-13: superseded — `--platform`
  shipped; see the dated update at the top. `node` / `browser` / `standalone` are selectable, with
  `node` the default; only `wasi` and the browser runtime/app split remain.)_

## References

- [ADR 0010](0010-runtime-as-a-separate-wasm-module.md) — runtime as a separate wasm module
- [ADR 0011](0011-packaging-platform-and-host-imports.md) — packaging / platform / host-import principles (this ADR's parent)
- [ADR 0014](0014-user-ffi-resolution-and-marshalling.md) — the foreign-resolution ladder and marshalling
- [ADR 0021](0021-streaming-dependency-ordered-wpo.md) — streaming codegen (a prerequisite for the real impl)
- [ADR 0024](0024-export-boundary-arity-and-transparent-types.md) — `emitLoader` / the export boundary
