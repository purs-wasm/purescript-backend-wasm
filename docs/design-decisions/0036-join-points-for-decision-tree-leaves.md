# 0036. Parameterized join points for decision-tree leaves (kill the match-compilation blowup)

- Status: **Proposed** (de-prioritized — see Update)
- Date: 2026-06-16

> **Update (2026-06-16): empirically NOT the `--no-opt` fix.** Direct measurement (a
> `lowerBody` call counter vs static `alternatives` count) found a duplication ratio of only
> **1.16×** on the 145-module subset that reaches lowering (`lowerBodyCalls=297 /
> staticAlts=257`, guards included) — no `(B+1)^k` blowup in practice. Decisively, the full
> `-e Main --no-opt -g` build **OOMs in the front half (decode + translate + MIR lambda-lift),
> before `lowerModules` runs** (its `setStaticAlts` log never appears), so lowering-internal
> duplication cannot be the `--no-opt` OOM cause — the process dies before any `AnfExpr` is
> built. The `--no-opt` blocker is the **front-half whole-program memory floor (the separate
> bug B)**, not this. This ADR may still matter for the *optimized* path's IR size / Binaryen
> `-O` input, but only if an actual blowup is measured there; until then it is **not pursued**.
> (The premise below was reasoned from the code mechanism before this measurement — kept for
> the record, but superseded by the data.)

## Context

Self-compiling `purs-wasm` with itself surfaced a memory blowup in **lowering** that survives
with *every* optimizer turned off — `--no-opt -g` (no middle-end, no Binaryen `-O`). Profiling
the front half (decode → translate → lambda-lift → lower → codegen) showed the live backend IR
(`Lower.IR.AnfExpr`) reaching **~250–270× the input corefn size** — far above the ~3-copy
linear floor of holding CoreFn + MIR + backend IR at once. The excess is a single structure:
the lowered program itself is super-linearly large.

The cause is the **decision-tree compiler** (`Lower.Match`, a Maranget-style matrix
compiler). It is a known weakness of naive Maranget compilation: **clause bodies are
re-emitted at every decision-tree leaf they reach**, and a clause whose switched column is a
variable/wildcard reaches *many* leaves.

### The mechanism (file:line)

- A leaf lowers its clause body by calling the continuation `ops.lowerBody`
  (`Lower/Match.purs:113`, and `:134` for a guard's `then` expression). `lowerBody` is the
  `finish` passed by `lowerCaseK` — in **tail** position it is `lowerTail` itself
  (`Lower.purs:406`, `:515`, `:520-522`). So each leaf **re-lowers the source body into a fresh
  `AnfExpr`**; there is no sharing of leaf actions.
- A variable/wildcard row is **copied into every sub-matrix** during specialization:
  `specializeCtor` keeps a `VarBinder`/`NullBinder` row in *every* constructor branch
  (`Lower/Match.purs:263-266`), and `defaultMatrix` keeps it in the default branch too
  (`:250-254`, `defaultRow` `:307-308`). With `B` constructors a wildcard row is duplicated into
  `B+1` sub-matrices; over `k` consecutive switched columns the clause appears in up to
  **`(B+1)^k` leaves**, each independently lowering the body.
- `lowerBody = lowerTail`, so when a duplicated body **itself contains a `case`** (exactly the
  deeply-`case`-nested ASTs a compiler is made of), its inner decision tree is re-expanded
  inside every duplicate — the duplication **multiplies with nesting**.
- A secondary axis: a guarded row recompiles the fallthrough matrix `rest` per row
  (`Lower/Match.purs:117-119`), so chained guards re-compile the residual matrix in a nest.

This is the same *class* of bug ADR 0022 measured for `genericShow` (one body lowered 18,616
times), on a different axis. It surfaces now because the compiler's own modules — the parser,
`Data.Variant`/`Run`, the CLI — match on wide, deeply-nested patterns; small programs and the
`metatheory` bench do not stress it.

### Why ADR 0022 does not cover it

[ADR 0022](0022-join-points-for-case-in-argument-position.md)'s `LetJoin` shares the **outer
continuation `k`** of a single *argument-position* `case` — it binds the case's result once so
`k` is not copied into branches. The duplication here is different in two ways:

1. it is the **inner clause bodies** duplicated across decision-tree *leaves*, not the outer
   continuation; and
2. it happens in **tail** position too (`lowerTail → lowerCaseK` never goes through `LetJoin`),
   which ADR 0022 deliberately left untouched.

Each leaf also binds **different** pattern variables (each leaf's occurrences), so a shared
clause body must be **parameterized** — ADR 0022's slot-only, argument-less join cannot express
it.

## Decision

Share each clause body the way Maranget/GHC do: **lower every clause body (and guard
expression) exactly once into a parameterized join point, and make each decision-tree leaf a
jump to it, passing that leaf's bound occurrence atoms.** The decision tree becomes a DAG over
a fixed set of join points instead of a tree of duplicated bodies.

### IR (`Lower.IR`)

Add a parameterized join — the natural generalization of ADR 0022's `LetJoin`:

```purescript
-- | A group of parameterized join points in scope over `body` (the decision tree). Each join
-- | `j` binds clause body `B_j` once; its `params` are canonical slots holding the clause's
-- | pattern variables. The tree reaches a clause via `JoinJump j atoms`, which sets
-- | `params_j := atoms` and runs `B_j`. `rep` is the value every `B_j` tail produces (the
-- | case's result rep — the function result in tail position, the ADR 0022 join slot in
-- | argument position).
| LetJoins (Array { params :: Array Slot, rep :: Rep, body :: AnfExpr }) AnfExpr
| JoinJump Int (Array Atom)   -- jump to the i-th join with these argument atoms
```

(ADR 0022's value-binding `LetJoin Slot Rep producer k` stays as-is for the argument-position
outer continuation; the two compose — an argument-position `case` is a `LetJoin` whose
*producer* is a `LetJoins` decision tree.)

### Lowering (`Lower.Match`)

`compile` lowers **each distinct clause once**, up front: bind its pattern variables to fresh
canonical slots, lower its body (or its guard chain) to an `AnfExpr` in the case's position via
the existing `finish`, and register it as a join. The matrix compiler then emits, at a leaf, a
`JoinJump i occs` (the occurrence atoms bound along that leaf's path) instead of calling
`lowerBody`. A guarded clause's fallthrough becomes a jump to the residual matrix's own join,
so a chain of guards no longer re-compiles the residual per row. Net: the body of clause `i`
is lowered **once**, regardless of how many leaves reach it.

### Codegen (`Codegen.purs`)

A `LetJoins` lowers to the standard nested-labeled-block join layout: one `block` label per
join enclosing the decision tree, with each join body emitted after its block and falling
through to a shared exit. `JoinJump i atoms` is `(local.set params_i atoms…) (br $join_i)` — a
jump, not a call, reusing the block/`br` machinery (no closure, no call overhead), consistent
with ADR 0022's block-based `LetJoin`. Tail position is preserved: a join body generated in
tail position keeps its `Return` / `return_call`, so the constant-stack tail-recursion
guarantee (ADR 0015) is unaffected — a `br` into a tail-positioned join body still tail-calls.

### Representation analysis (`Lower.Unbox`)

`LetJoins` / `JoinJump` add one case each to every `AnfExpr` walk (mechanical). Join `params`
slots start `Boxed` (the universal `eqref` an occurrence already crosses), matching ADR 0022's
join slot; unboxing them is a later refinement.

## Consequences

- **Decision-tree lowering becomes linear** in (number of clauses + decision-tree size)
  instead of `(B+1)^k × body`. The `--no-opt -g` backend-IR floor drops to the genuine
  ~3-copy linear level — the self-compilation memory gate for the `--no-opt` path.
- **It also shrinks the *optimized* path's backend IR**, so a future default (optimized)
  self-host hands Binaryen a smaller module — relevant to the separate Binaryen-`-O` memory
  cost on the single whole-program module ([ADR 0009](0009-build-and-linking-model.md)).
- **Output changes** (shared bodies via `br` instead of duplicated inline bodies), so this is
  **not** byte-identical to the prior codegen. Acceptance is the [ADR 0034](0034-pmi-interface-pmo-object-split.md)
  bar — **build determinism + e2e correctness + no benchmark regression** — not byte-identity.
- **Tail recursion preserved by construction** (join bodies stay tail-positioned), so the
  State/Effect/loop benches and ADR 0015's collapse are unaffected.
- **Independent of [ADR 0035](0035-sharing-nbe-reduction-aware-inlining.md) (NbE).** That fixes
  the optimizer's exponential *time*; this fixes lowering's exponential *space*. Both are
  self-compilation scaling gates on different axes.
- **New IR nodes** touched by every `AnfExpr` traversal (Codegen `genBody` / slot-rep
  collection, Unbox analyses + rewrite) — one mechanical case each, plus the non-trivial
  `LetJoins` codegen (nested block layout).

## Alternatives considered

- **Keep duplicating, cap the leaf count / bail.** Turns a blowup into a failed compile; does
  not compile valid programs.
- **Lift each clause body to a real (top-level or local) function and `call` it from leaves.**
  Reuses existing call nodes — no new IR — but a clause body is a `Lower`-level continuation
  over local occurrences and the surrounding env; lifting it with the right captures mid-match
  is far more invasive (the same reason ADR 0022 rejected a "join function"), and a `call` is
  heavier than `local.set` + `br`.
- **A non-duplicating match compiler** (backtracking automaton / DAG matrices, e.g.
  Pettersson-style). A larger rewrite of `Lower.Match`; the parameterized join point is the
  localized, well-understood fix that keeps the Maranget matrix compiler and only shares its
  leaf actions.
- **Deduplicate the bodies after lowering** (CSE over `AnfExpr`). The exponential `AnfExpr` is
  already built (and may not fit memory) before CSE could run — the duplication must be avoided
  at emission, not repaired after.
