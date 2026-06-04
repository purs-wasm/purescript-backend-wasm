# Design Decisions

This directory records significant architectural decisions for the
PureScript → WebAssembly backend, as lightweight
[ADRs](https://adr.github.io/) (Architecture Decision Records).

Each record captures **one** decision: the context that forced it, the
decision itself, its consequences, and the alternatives that were rejected
and why. Records are immutable once accepted — if a decision is later
reversed, add a new record that supersedes the old one rather than editing
history.

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

## Index

| # | Title | Status |
| - | - | - |
| 0001 | [Wasm GC substrate and value representation](0001-wasm-gc-substrate-and-value-representation.md) | Accepted |
| 0002 | [FFI via a code-generator intrinsics table](0002-ffi-intrinsics-strategy.md) | Accepted |
| 0003 | [Intermediate IR between CoreFn and Binaryen](0003-intermediate-ir.md) | Accepted |
| 0004 | [Uniform eqref calling convention (boxed values)](0004-uniform-eqref-calling-convention.md) | Accepted |
| 0005 | [A high-level optimization IR](0005-high-level-optimization-ir.md) | Proposed |
| 0006 | [Top-level value bindings (CAFs) as exported globals](0006-top-level-value-bindings-as-globals.md) | Proposed |
| 0007 | [Positional (tuple) type-class dictionary specialization](0007-positional-dictionary-specialization.md) | Proposed |
| 0008 | [Constructing recursive type-class dictionary groups](0008-recursive-dictionary-groups.md) | Proposed |
| 0009 | [Build and linking model: multi-module input, single-wasm output](0009-build-and-linking-model.md) | Proposed |
| 0010 | [The shared runtime as a separate, hand-written wasm module](0010-runtime-as-a-separate-wasm-module.md) | Accepted |
| 0011 | [Packaging, platform targets, and host imports](0011-packaging-platform-and-host-imports.md) | Proposed |
| 0012 | [A `ulib` directory for curated-package wasm FFI](0012-ulib-curated-package-ffi.md) | Proposed |
| 0013 | [Unboxing `Int` and `Number`](0013-int-number-unboxing.md) | Approved |
| 0014 | [User FFI: a foreign-provider ladder and the JS marshalling boundary](0014-user-ffi-resolution-and-marshalling.md) | Proposed |
| 0015 | [Effect reflection: collapsing function-represented monads to straight-line code](0015-effect-native-support.md) | Accepted |
| 0016 | [Reconstructing foreign signatures from `.purs` source](0016-foreign-signature-reconstruction.md) | Accepted |

## Scope

The current milestone is: **compile PureScript modules that depend only on
`Prelude` to a single wasm module.** `Effect` and other effectful
computations are deferred. Decisions here are framed against that scope.
