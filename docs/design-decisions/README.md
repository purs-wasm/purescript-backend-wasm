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

## Scope

The current milestone is: **compile PureScript modules that depend only on
`Prelude` to a single wasm module.** `Effect` and other effectful
computations are deferred. Decisions here are framed against that scope.
