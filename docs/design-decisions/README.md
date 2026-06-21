# Design Decisions

This directory records significant architectural decisions for the
PureScript → WebAssembly backend, as lightweight
[ADRs](https://adr.github.io/) (Architecture Decision Records).

Each record captures **one** decision: the context that forced it, the
decision itself, its consequences, and the alternatives that were rejected
and why. A record's original text is never deleted-and-replaced — history is
preserved in place (see [Maintaining records](#maintaining-records)). A
genuinely *reversed* decision is retired by a new record that supersedes it,
not by rewriting the old one.

## Format

```plain
# <NNNN>. <Title>

- Status: Proposed | Accepted | Superseded by <NNNN>
- Date: YYYY-MM-DD

## Context
## Decision
## Consequences
## Alternatives considered
```

## Maintaining records

When a record drifts from the implementation, **do not delete and replace the original
text.** Keep the original readable as history and mark the change in place:

- **Correction / progress addendum** — strike the obsolete text with `~~…~~` and append a
  dated note explaining the change, e.g.
  `> **Correction (YYYY-MM-DD):** …` or `> **Progress (YYYY-MM-DD):** …`.
- **Status promotion** — keep the old status struck through and add the new one with a dated
  rationale, e.g.
  `- Status: ~~Proposed~~ **Accepted** _(YYYY-MM-DD: promoted — implemented in …)_`.
- **Reversal** — a decision that is genuinely overturned (not merely refined) is retired by a
  new record that supersedes it (`Status: Superseded by <NNNN>`), not by rewriting it.
- **The index below is the exception**: it is edited by **direct overwrite** (no strikethrough),
  since it is a derived table that must always show each record's current effective status.

Permanent records here are written in **English**. (Ephemeral working notes may be in any
language and are kept out of version control.)

## Index

| # | Title | Status |
| - | - | - |
| 0001 | [Wasm GC substrate and value representation](0001-wasm-gc-substrate-and-value-representation.md) | Accepted |
| 0002 | [FFI via a code-generator intrinsics table](0002-ffi-intrinsics-strategy.md) | Accepted |
| 0003 | [Intermediate IR between CoreFn and Binaryen](0003-intermediate-ir.md) | Accepted |
| 0004 | [Uniform eqref calling convention (boxed values)](0004-uniform-eqref-calling-convention.md) | Accepted |
| 0005 | [A high-level optimization IR](0005-high-level-optimization-ir.md) | Accepted |
| 0006 | [Top-level value bindings (CAFs) as exported globals](0006-top-level-value-bindings-as-globals.md) | Accepted |
| 0007 | [Positional (tuple) type-class dictionary specialization](0007-positional-dictionary-specialization.md) | Accepted (positional layout deferred) |
| 0008 | [Constructing recursive type-class dictionary groups](0008-recursive-dictionary-groups.md) | Accepted |
| 0009 | [Build and linking model: multi-module input, single-wasm output](0009-build-and-linking-model.md) | Accepted |
| 0010 | [The shared runtime as a separate, hand-written wasm module](0010-runtime-as-a-separate-wasm-module.md) | Accepted |
| 0011 | [Packaging, platform targets, and host imports](0011-packaging-platform-and-host-imports.md) | Accepted |
| 0012 | [A `ulib` directory for curated-package wasm FFI](0012-ulib-curated-package-ffi.md) | Superseded by 0026, 0031 |
| 0013 | [Unboxing `Int` and `Number`](0013-int-number-unboxing.md) | Accepted |
| 0014 | [User FFI: a foreign-provider ladder and the JS marshalling boundary](0014-user-ffi-resolution-and-marshalling.md) | Accepted |
| 0015 | [Effect reflection: collapsing function-represented monads to straight-line code](0015-effect-native-support.md) | Accepted |
| 0016 | [Reconstructing foreign signatures from `.purs` source](0016-foreign-signature-reconstruction.md) | Accepted |
| 0017 | [Native `Effect.Ref` mutable references](0017-native-mutable-references.md) | Accepted |
| 0018 | [Native `effect`-package control-flow and `EffectFn` primitives](0018-native-effect-primitives.md) | Accepted |
| 0019 | [A faithful, uniform `Effect` lowering (correctness before collapse)](0019-faithful-effect-lowering.md) | Accepted |
| 0020 | [A reduction-aware inliner (inline when it reduces, share when it doesn't)](0020-reduction-aware-inliner.md) | Proposed (NbE core done; see 0021) |
| 0021 | [Streaming, dependency-ordered whole-program optimization](0021-streaming-dependency-ordered-wpo.md) | Proposed (Phase 1 done; see 0020) |
| 0022 | [Join points for `case` in argument position](0022-join-points-for-case-in-argument-position.md) | Accepted |
| 0023 | [Polymorphic record update via runtime copy-and-set](0023-polymorphic-record-update.md) | Accepted |
| 0024 | [Export-boundary arity reconciliation, and the transparent-types-only rule](0024-export-boundary-arity-and-transparent-types.md) | Accepted |
| 0025 | [Multi-platform packaging (`--platform`) and the fallback-JS toggle](0025-multi-platform-packaging.md) | Accepted (partial — `wasi` & browser-split pending) |
| 0026 | [WasmBase: a stable primitive layer between `Prim` and `Prelude`](0026-wasmbase-primitive-layer.md) | Accepted |
| 0027 | [Specialize after inlining: the `where`-worker / forwarder idiom](0027-specialize-after-inlining.md) | Accepted |
| 0028 | [ulib as a compiler-bundled library layer: lib-first shadowing of registry modules](0028-ulib-library-layer-shadowing.md) | Superseded by 0031 |
| 0029 | [ulib lib distribution and purs-compiler pinning](0029-ulib-lib-distribution-and-purs-pinning.md) | Accepted (refined by 0031) |
| 0030 | [`Data.String` over UTF-8: code-point semantics, byte access via `Wasm.String`](0030-data-string-over-utf8.md) | Accepted |
| 0031 | [ulib as a single library-module layer: last-wins artifact merge, retiring the shadow/wat duality](0031-ulib-unified-library-modules.md) | Superseded by 0039 |
| 0032 | [Caller-homed specialization for per-module, incremental builds](0032-caller-homed-specialization-for-incremental-builds.md) | Accepted |
| 0033 | [Shipping `ulib` as precompiled MIR (`.pmo`) artifacts](0033-precompiled-ulib-pmo-artifacts.md) | Superseded by 0040 |
| 0034 | [Split the module cache into `.pmi` interface and `.pmo` object](0034-pmi-interface-pmo-object-split.md) | Accepted |
| 0035 | [Sharing/memoizing the NbE reducer, then reduction-aware inlining](0035-sharing-nbe-reduction-aware-inlining.md) | Accepted (Layers A+B + a Layer-C-lite size cap + the Specialize dedup-key fix landed 2026-06-17 — the optimized self-compile completes; full reduction-aware Layer C policy deferred) |
| 0036 | [Parameterized join points for decision-tree leaves](0036-join-points-for-decision-tree-leaves.md) | Proposed (de-prioritized — measured duplication ~1.16×, not the `--no-opt` floor) |
| 0037 | [Separate per-module codegen and linking (per-module wasm + `wasm-merge`)](0037-separate-per-module-codegen-and-linking.md) | Accepted; implemented (Phases 0–2 + Phase-3 codegen restructure — single-module compilation behind `--per-module-codegen`, parity-verified; per-module wasm cache pending) |
| 0038 | [Separated compilation: the `purwc` worker, the `purs-wasm` orchestrator, and the shared `cli-lib`](0038-separated-compilation-purwc-worker-and-cli-lib.md) | Accepted; **Phase A implemented** (`cli-lib` extracted, three CLIs re-homed, behaviour-neutral); the standalone `purwc` worker (Phase B) + subprocess orchestrator (Phase C) designed, not yet implemented |
| 0039 | [ulib as a patch on registry packages, with content-based lenient versioning](0039-ulib-as-registry-package-patch.md) | Accepted — §1/§3/§4 implemented (foreign-only abolished, presence-driven resolution, lenient versioning; blocker ② fixed), §2 partial (full source-overlay deferred to 0040) |
| 0040 | [A global content-addressed library cache (`$PURS_WASM_LIB`)](0040-global-content-addressed-library-cache.md) | Proposed (supersedes 0033; depends on 0035 Layer C) |

## Scope

The backend compiles PureScript (CoreFn + `externs.cbor`) to a single WebAssembly-GC
module. Supported today: `Prelude`, higher-order functions with partial/over-application,
strings/arrays/records, ADTs and pattern matching, recursive let and cyclic type-class
instance groups, the `Effect` monad (with `Effect.Ref` and the `effect` package's
control-flow primitives), and user-defined FFI including effectful foreigns. The `Effect`
monad collapses like a transparent monad — constant-stack loops — while preserving effect
order and count. A non-trivial program (a System F type checker / evaluator) compiles to and
runs on wasm. See [`docs/developers-guide/supported-features.md`](../developers-guide/supported-features.md) and
[`docs/developers-guide/optimizations.md`](../developers-guide/optimizations.md) for the authoritative, up-to-date status.

Current frontiers, tracked by the records above: streaming / incremental codegen (ADR 0021
Phase 2 — reachability pruning and dependency-ordered single-pass optimization shipped; the
**`.pmi`/`.pmo` incremental build cache** — default-on, decode-free for unchanged modules —
shipped too, ADR 0032 phase 4 / ADR 0034); the reduction-aware inline-or-share selection (ADR
0020's NbE core is implemented; **ADR 0035 Layers A+B (NbE sharing — makes the reducer
non-exponential) + a Layer-C-lite `normalFormSizeCap` (bounds the `genericShow` code-size blow-up)
+ the `Optimize.Specialize` dedup-key fix (hash, not `show`) landed 2026-06-17, and the optimized
self-compile now *completes*** (writes an 8 MB wasm), where it used to hang at `Optimize.Specialize`;
A+B alone removed the recomputation exponential but did not clear that module — the code-size cap +
dedup-key fix were also required. The full reduction-driven inline *decision* (ADR 0035 Layer C
policy) is deferred — an optimization-quality improvement, not a remaining scalability blocker); the
`--no-opt` self-compilation *space*
gate — the front-half whole-program memory floor (decode + translate + lambda-lift holding all MIR
at once, ADR 0009) — addressed by **copy-reduction (landed: translate + lambda-lift are fused
per module and each module's CoreFn is dropped before the next, so the program is never resident
as CoreFn *and* MIR at once), with streaming as the future general solution** (decision-tree leaf
sharing, ADR 0036, was measured to be ~1.16× and is *not* this floor); `wasi` packaging
and the browser runtime/app split (ADR 0025 — `node` / `browser` / `standalone` packaging and `-E`
have shipped); precompiled-`ulib` distribution (ADR 0033); and monomorphization.
