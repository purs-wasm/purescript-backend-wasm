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
| 0006 | [Top-level value bindings (CAFs) as exported globals](0006-top-level-value-bindings-as-globals.md) | Proposed |
| 0007 | [Positional (tuple) type-class dictionary specialization](0007-positional-dictionary-specialization.md) | Proposed |
| 0008 | [Constructing recursive type-class dictionary groups](0008-recursive-dictionary-groups.md) | Accepted |
| 0009 | [Build and linking model: multi-module input, single-wasm output](0009-build-and-linking-model.md) | Accepted |
| 0010 | [The shared runtime as a separate, hand-written wasm module](0010-runtime-as-a-separate-wasm-module.md) | Accepted |
| 0011 | [Packaging, platform targets, and host imports](0011-packaging-platform-and-host-imports.md) | Accepted |
| 0012 | [A `ulib` directory for curated-package wasm FFI](0012-ulib-curated-package-ffi.md) | Accepted |
| 0013 | [Unboxing `Int` and `Number`](0013-int-number-unboxing.md) | Accepted |
| 0014 | [User FFI: a foreign-provider ladder and the JS marshalling boundary](0014-user-ffi-resolution-and-marshalling.md) | Accepted |
| 0015 | [Effect reflection: collapsing function-represented monads to straight-line code](0015-effect-native-support.md) | Accepted |
| 0016 | [Reconstructing foreign signatures from `.purs` source](0016-foreign-signature-reconstruction.md) | Accepted |
| 0017 | [Native `Effect.Ref` mutable references](0017-native-mutable-references.md) | Accepted |
| 0018 | [Native `effect`-package control-flow and `EffectFn` primitives](0018-native-effect-primitives.md) | Accepted |
| 0019 | [A faithful, uniform `Effect` lowering (correctness before collapse)](0019-faithful-effect-lowering.md) | Accepted |
| 0020 | [A reduction-aware inliner (inline when it reduces, share when it doesn't)](0020-reduction-aware-inliner.md) | Proposed |
| 0021 | [Streaming, dependency-ordered whole-program optimization](0021-streaming-dependency-ordered-wpo.md) | Proposed |
| 0022 | [Join points for `case` in argument position](0022-join-points-for-case-in-argument-position.md) | Accepted |
| 0023 | [Polymorphic record update via runtime copy-and-set](0023-polymorphic-record-update.md) | Accepted |
| 0024 | [Export-boundary arity reconciliation, and the transparent-types-only rule](0024-export-boundary-arity-and-transparent-types.md) | Accepted |
| 0025 | [Multi-platform packaging (`--platform`) and the fallback-JS toggle](0025-multi-platform-packaging.md) | Proposed |
| 0027 | [Specialize after inlining: the `where`-worker / forwarder idiom](0027-specialize-after-inlining.md) | Proposed |

## Scope

The backend compiles PureScript (CoreFn + `externs.cbor`) to a single WebAssembly-GC
module. Supported today: `Prelude`, higher-order functions with partial/over-application,
strings/arrays/records, ADTs and pattern matching, recursive let and cyclic type-class
instance groups, the `Effect` monad (with `Effect.Ref` and the `effect` package's
control-flow primitives), and user-defined FFI including effectful foreigns. The `Effect`
monad collapses like a transparent monad — constant-stack loops — while preserving effect
order and count. A non-trivial program (a System F type checker / evaluator) compiles to and
runs on wasm. See [`docs/supported-features.md`](../supported-features.md) and
[`docs/optimizations.md`](../optimizations.md) for the authoritative, up-to-date status.

Current frontiers, tracked by the records above: the real `bin` linker (reachability
pruning and streaming, dependency-ordered optimization — ADR 0021), multi-platform packaging
(ADR 0025), a reduction-aware inliner (ADR 0020), top-level CAFs as globals (ADR 0006), and
monomorphization.
