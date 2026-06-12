# 0006. Top-level value bindings (CAFs) as exported globals

- Status: ~~Proposed~~ **Accepted** _(2026-06-07: implemented. Phase A — non-Effect, pure, acyclic CAFs become init-set globals that references read; computed once at instantiation. See the addenda below for the export treatment and the `Effect` gating.)_
- Date: 2026-05-31

## Context

A nullary top-level binding such as `five = addN 2 3` currently lowers to a
function: an internal `(func (result eqref))` that runs the computation, plus an
`$export` wrapper, so the host calls `five()` → `5` rather than reading
`five` → `5`. The same shape applies to every nullary top-level value (`even4`,
`count3`, `add3`, …).

Such a binding is a **CAF** (constant applicative form): it takes no arguments
and has no free variables, so it denotes a single value — but computing that
value requires *running code* (here, calling `addN`). Two facts shape the design:

- **Wasm can export values.** A `global` can be exported and is read host-side as
  `WebAssembly.Global.value` (e.g. `instance.exports.five.value === 5`). So a
  value-like host interface is available in principle.
- **A CAF's value is not a constant expression.** Wasm `global` initializers must
  be constant expressions: `t.const`, `global.get` (of an imported immutable
  global), `ref.func`, `ref.null`, plus `i32.add/sub/mul` (extended-const) and
  `struct.new`/`array.new_fixed` (GC). **Function calls are never allowed.**
  Since a CAF generally calls functions (`addN 2 3`), it cannot be a constant
  `global` initializer; it must be evaluated by executing code.

So `five()` is **not** a Wasm limitation. It is the consequence of (a) the value
being computed by code rather than a constant expression, combined with (b) the
uniform "every binding → an `eqref`-returning function + i32 export wrapper"
lowering (ADR 0004). Getting `five` → `5` (host-side `five.value`) is therefore a
**code-generation choice**: evaluate the CAF once and store it in a global.

## Decision (proposed)

Compile **acyclic** top-level *value* bindings (CAFs) to Wasm **globals**,
initialized once by a synthesized **init function** (the `start` section, or an
exported `_init`) that evaluates them in **dependency (topological) order**.
Function bindings stay as functions. For a host-exported `Int` value, store the
unboxed `i32` in an exported `i32` global (export binds a global directly, so the
unboxed value must live in its own global; the init function boxes/unboxes as
needed and writes it).

> **Addendum (2026-06-07):** The first implementation (Phase A) globalises CAFs
> **internally** — every reference reads the global and the value is computed once at
> instantiation — but keeps each *export* as its existing function wrapper (now reading
> the global rather than recomputing), so the host ABI is unchanged: `x()` still works on
> both the loader and standalone paths, without recomputation. Exposing the export as a
> host-readable `global` (`x.value`) is a deliberate follow-up — it changes the host
> surface and the loader — and is deferred.

Cyclic value-binding groups are **out of scope** for this decision: a genuine
value-level cycle requires laziness (PureScript-JS inserts `$runtime_lazy` for
exactly these, typically recursive instance dictionaries) and is deferred to the
same work that introduces lazy thunks. Until then, only non-recursive CAFs are
globalized; recursive non-function values remain unsupported.

## Consequences

- The host reads `five.value` instead of calling `five()`, matching the intuition
  that a value is a value; it is also computed once at instantiation rather than
  recomputed on every call.
- Concrete motivation after Slice 3: instance dictionaries and instance-specialized
  methods (`addableInt`, `double1 = double addableInt`) are CAFs, and as nullary
  getter functions they are **re-evaluated on every reference** — re-allocating the
  dictionary `$Rec` struct/arrays and re-doing the label projection on each dispatch
  (see `docs/developers-guide/supported-features.md`). Globalizing CAFs gives the same evaluate-once
  sharing the JS backend gets from `const double1 = double(addableInt)`, removing
  that per-call allocation from the dictionary hot path. (Eliminating the dictionary
  entirely is the separate ADR 0005 optimization.)
- Requires a topological sort of value-binding dependencies and a synthesized
  init function. Evaluation moves to instantiation time; since current CAFs are
  pure (`Effect` is deferred, ADR scope), eager initialization is observationally
  safe. When `Effect` lands, effectful module-level initialization will need
  revisiting.
  > **Addendum (2026-06-07):** `Effect` has since landed. Globalisation is gated to
  > **arity-0 CAFs** (plus acyclic + reachable): after ADR-0015 impurification an
  > `Effect a` value is an arity-≥1 thunk (`\$ev -> …`), so an `Effect`-typed top-level
  > is naturally excluded and stays a deferred thunk (`() => a`) — never run at
  > instantiation, guarded by `examples/helloworld` in the e2e suite. Eager load-time
  > evaluation of a pure CAF that traps/diverges is accepted as observationally
  > equivalent (the JS backend's `foo = unsafeThrow "…"` throws on import too).
- Composes with ADR 0004: internal globals may hold boxed `eqref`; the
  host-facing export is an unboxed `i32` global set during init.
- Bounds the cyclic-value problem cleanly: the globalization pass handles only
  acyclic CAFs, and the cyclic case is explicitly handed to the future laziness
  (`$runtime_lazy`) work rather than being half-solved here.

## Alternatives considered

- **Keep nullary getter functions (status quo).** Simplest, and uniform with the
  rest of lowering, but ergonomically the host writes `five()` and the value is
  recomputed on each call. Rejected as the long-term shape for pure values.
- **Constant-expression globals (extended-const / GC const exprs).** Works only
  for the narrow subset whose initializer is itself a constant expression
  (`five = intAdd 2 3` could become `(i32.add (i32.const 2) (i32.const 3))`), since
  no function call is permitted. Too special-case to be the general mechanism;
  the init-function approach subsumes it.
- **Lazy thunks for all CAFs.** More general — it also handles cyclic value
  groups — but heavier (a thunk + force per value). Deferred to when laziness is
  needed anyway (`$runtime_lazy`); eager init of acyclic CAFs is the cheaper
  first step.

## References

- ADR 0004 — uniform `eqref` calling convention (why bindings currently become
  `eqref`-returning functions with i32 export wrappers).
- WebAssembly constant expressions (what a `global` initializer may contain):
  <https://webassembly.github.io/spec/core/valid/instructions.html#constant-expressions>
- GHC's treatment of CAFs (origin of the term and the laziness/cycle concern).
