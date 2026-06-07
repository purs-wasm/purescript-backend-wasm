# 0022. Join points for `case` in argument position (kill the commuting-conversion blowup)

- Status: ~~Proposed~~ **Accepted** _(2026-06-07: promoted — implemented (`LetJoin` across Lower/Codegen/Unbox).)_
- Date: 2026-06-06

## Context

The first "real big app" target — `examples/metatheory`, a transformer-heavy typechecker
— builds every module except `Examples.Metatheory.Typecheck`, which appears to hang. It was
widely assumed to be an optimizer problem (the same subsystem ADR 0020 / 0021 addressed).

Instrumentation proved otherwise. The optimizer terminates and the MIR it produces is
**finite and small**: every reachable function is ≤ ~8,300 nodes and none is cyclic (a
fuel-bounded node count never hit its cap). The hang is in **lowering** (`Lower.purs`).

The culprit is the **commuting conversion** for a `case` in *argument* position:

```purescript
-- lowerArg
M.Case scrutinees alternatives ->
  lowerCaseK env scrutinees alternatives \env' body -> lowerArg env' body k
```

This duplicates the continuation `k` into **every branch** of the case (the classic
"case-of-case" duplication). When `case` expressions nest deeply *as arguments*, `k` is
copied `2^depth` times.

### What triggers it

`genericShow` (`Data.Show.Generic`) on a **recursive, multi-constructor** type —
`Syntax.Type_` (`TyInt | TyBool | TyVar | TyArr | TyAbs | TyApp`). Its generic `Rep` is a
deep nested `Sum`/`Product`, walked by nested `case x of Inl … / Inr …`, and every one of
those `case`s sits in an *argument* position (operands of `concatArray` / `concatString`).

Measured during the lowering of `showTypedExpr` / `showTypeError`: **70,753** body-lowerings
but only **232 distinct** bodies — one body lowered **18,616** times. That is exponential
re-lowering. It *terminates* in principle (the input is a finite tree), but at ~`2^N` it is a
hang in practice. Shallow / non-recursive `genericShow` (the e2e `PreludeGenericShowCompare`
fixture) stays small, which is why this was never hit before metatheory.

### Why duplication happens at all

`Switch` / `LitSwitch` are **tail** forms in the IR: each branch is a full `AnfExpr` that
produces the enclosing function's result (codegen's `genSwitch` emits an `if`-chain whose
value is `genBody branch`, sealed to `ctx.funcResult`). So the only way for an
argument-position case to "produce a value that flows into the rest of the computation" is to
push that rest (`k`) into each branch. There is no IR node for *"run this switch as a
value-producing block, bind its result once, then continue."*

In **tail** position this duplication is exactly what we want — each branch ends in a
`Return` / tail call, giving constant-stack tail recursion (ADR 0015's collapse relies on
it). The problem is strictly the **argument-position** path.

## Decision

Introduce **join points**: a single new IR node that binds the value produced by an inner
control-flow block to one slot, so the continuation runs **once** instead of being
duplicated per branch.

### IR (`Lower.IR`)

```purescript
-- | A join point: run `producer` (whose every tail `Return v` yields the join value),
-- | bind that value to `slot` at `rep`, then run `k` once. Lowers to
-- | `(local.set slot (block (result rep) <producer>)); <k>`. This is how a `case`
-- | in *argument* position is lowered without duplicating the continuation into branches.
| LetJoin Slot Rep AnfExpr AnfExpr
```

### Lowering (`Lower.purs`)

Only the **argument-position** `case` changes. Instead of duplicating `k`, lower the case
into a *producer* (each leaf `Return`s its value), then bind once:

```purescript
M.Case scrutinees alternatives -> do
  slot <- fresh
  producer <- lowerCaseK env scrutinees alternatives \env' body ->
                lowerArg env' body (\atom -> pure (Return atom))
  rest <- k (AVar (Local slot))
  pure (LetJoin slot Boxed producer rest)
```

`lowerTail`'s `case` path is **unchanged** — tail branches keep ending in `Return` / tail
calls (the desired constant-stack form). Because `let x = case …` in argument position also
funnels through `lowerArg`, it is covered automatically.

### Codegen (`Codegen.purs`)

`genBody` is currently hard-wired to seal each tail to `ctx.funcResult` and to emit
`return_call` for a tail call. A join *producer* is **not** in function-tail position: its
tails must yield the join slot's `rep` (not the function result), and it must **not** emit
`return_call` (that would return from the whole function, skipping `k`).

Thread two values through the body generator (via `ctx`): `resultRep` (the rep the current
tail must produce) and `tailPos` (whether `return_call` is legal). The function top sets
`resultRep = fn.result`, `tailPos = true`; a `LetJoin` producer is generated with
`resultRep = rep`, `tailPos = false`, wrapped in a `block (result rep)` and stored with
`local.set slot`. `genSwitch` / `genLitSwitch` propagate the current `ctx` to their branches
(a tail switch's branches stay tail; a producer switch's branches inherit `tailPos = false`).

### Representation analysis (`Lower.Unbox`)

`LetJoin` adds one case to each `AnfExpr` walk (producer + continuation recursed; the join
slot kept `Boxed`). Keeping the join slot boxed is behaviour-safe — it matches the universal
`eqref` box an argument-position case result already crosses today.

## Consequences

- **The metatheory hang is removed at the root.** Argument-position `case` lowering becomes
  linear in the term size instead of `2^depth`; the duplicated-continuation explosion cannot
  recur for any input shape, not just `genericShow`.
- **Tail position is untouched**, so the constant-stack tail-recursion guarantees (ADR 0015,
  the State/Effect benches) are preserved by construction.
- **Slightly more correct.** The old path could inline a tail-calling `k` into a branch that
  is *not* actually in tail position; the join point keeps argument-position evaluation
  non-tail, as it must be.
- **Minor representational cost.** An argument-position case now binds its result through a
  boxed join slot (one extra local + block) rather than handing an unboxed atom straight to
  `k`. This can change generated wasm for any program with a case/if in argument position; the
  bench deltas will be checked (the hot benches are tail-recursive loops, which do not use the
  argument-position path).
- **New IR node** touched by every `AnfExpr` traversal (Codegen `foldProgramRhs`,
  `collectSlotReps`, `genBody`; Unbox's analyses and rewrite). Mechanical, one case each.

## Alternatives considered

- **Keep duplicating, but cap depth / bail out.** Does not compile valid programs; only turns
  a hang into a failure.

- **Reify `k` as a real lifted function and `call` it from each branch** (a "join function").
  Reuses existing call nodes — no new IR — but `k` is a `Lower`-level continuation
  (`Atom -> Lower AnfExpr`), not an `M.Expr`; lifting it with the right captures mid-lowering
  is far more invasive than one IR node, and a real call is heavier than a block + `local.set`.

- **ANF-normalize at the MIR level** so a `case` never appears in argument position
  (`let x = case … in … x …`). The bound `case` still flows through `lowerArg` and needs the
  same join-point machinery to bind its result — this moves the work without removing the
  need for the node.

- **Make `Switch`/`LitSwitch` usable as an `Rhs`.** `Rhs` nodes have no `AnfExpr` children
  and model trivial single-step computes; embedding a branching `AnfExpr`-valued switch there
  breaks that invariant. `LetJoin` keeps the branching control flow in `AnfExpr` where it
  belongs.
