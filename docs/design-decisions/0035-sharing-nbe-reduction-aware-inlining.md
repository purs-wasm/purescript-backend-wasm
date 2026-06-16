# 0035. Sharing/memoizing the NbE reducer, then reduction-aware inlining

- Status: Proposed
- Date: 2026-06-16

> Realizes **stage 3** of [ADR 0020](0020-reduction-aware-inliner.md) (whose NbE core landed as
> stages 1–2). [ADR 0020](0020-reduction-aware-inliner.md) motivated reduction-aware inlining from
> *fusion* programs; this record adds a second, independently sufficient motivation discovered by
> self-compilation — the NbE reducer is **itself exponential** for lack of sharing — and sequences
> the fix so the scalability gate is opened *before* the inline-policy rewrite.

## Context

Compiling `purs-wasm` with itself (806 modules in `output/`, 286 reachable from `Main` — vs the
`metatheory` bench's ~250 small modules) wedged the optimizer: the build hangs (100% reproducible,
high memory) inside `MiddleEnd.runOpt` while optimizing the **`Optimize.Specialize`** module
(module 261/286). Toggling `DictElim.useNbE = false` makes the hang vanish (it is then replaced by
an unrelated stack overflow in `Impurify` — a separate, tracked bug), which isolates the hang to
the **NbE reducer** (`MiddleEnd.Optimize.Semantics`, [ADR 0020](0020-reduction-aware-inliner.md)).
With a raised heap it does not OOM — it stops contracting and spins — so the defect is **time/work
exponential**, not a memory leak.

The root cause is a single property: **the NbE reducer never memoizes — it recomputes a value on
every traversal.** It surfaces along two paths.

- **M1 — `eval` re-evaluates an inline binding at every use site.** `Semantics.purs` `evalVar`:

  ```purescript
  | Just body <- Map.lookup k ctx.inline ->
      if Set.member k visited then SNeu (NTop q) else go (Set.insert k visited) Map.empty body
  ```

  Every reference to an inline-set top-level binding re-runs `eval` over its whole `body`. The
  inline set is acyclic by construction (`DictElim.buildCtx`: `acceptHelper` drops any candidate that
  references another candidate; `isCandidate` excludes self-recursion) but it **admits diamonds**
  `f → {g, h} → … → E`, so `E` is evaluated once per path = Θ(2^depth). A *neutral* `case`
  compounds this: `evalCase` evaluates **every** alternative (`map (evalAlt …) alts`), so with
  branching `k` the cost is Θ(k^depth) on nested-case-in-lambda — exactly the shape of the
  recursion-scheme code in `Optimize.Specialize` / `Impurify`.

- **M2 — `quote` re-evaluates shared values.** `quote (SLam ps fn)` reifies a lambda by *applying*
  it to fresh neutrals — `fn (map (SNeu <<< NLocal) ps')` — which runs `eval` over the body again;
  `SLet`/`SLetRec` likewise re-invoke their continuation. `quote` keeps no memo, so a value reached
  along *n* paths of the semantic DAG is re-quoted (and its lambda bodies re-evaluated) *n* times.

These compose: **memoizing eval (M1) alone is insufficient**, because even after eval produces a
shared DAG, `quote` still walks every path of that DAG and re-quotes the shared bottom node an
exponential number of times. Killing the exponential requires sharing in **both** eval and quote.

This is the same non-contraction [ADR 0020](0020-reduction-aware-inliner.md) found via CPS fusion,
seen from the other side: there the *inliner* duplicated a diamond's leaf `2^depth` times in the
**output**; here the *reducer* duplicates the **work** of building it. [ADR 0020](0020-reduction-aware-inliner.md)
already establishes that a size/use threshold cannot fix the inlining (the State/dict collapses and
the fusion explosion have identical size/use profiles; the discriminator is *whether the inline
reduces*). The present record takes that as given and focuses on **how** to realize the
sharing-and-reduction-awareness against the actual `Semantics` shapes.

`normalize` runs **per top-level declaration** (`DictElim.reduce`), twice in `localOpt`
(simplify-with-inline → impurify → simplify-without-inline) and once in `finalizeModule`. The
exponential lives entirely **within a single `normalize` of a single declaration**, so any memo
table is scoped to one `normalize` call; no cross-call sharing is needed.

## Decision

**Make the NbE reducer share rather than recompute, in two stages, and only then move the
inline-vs-share *decision* into `quote` (the [ADR 0020](0020-reduction-aware-inliner.md) stage-3
policy).** Separating *sharing* (a behaviour-neutral scalability fix) from *policy* (a deliberate
output change) lets the self-host gate open under the strong byte-equal guarantee, ahead of the
riskier policy rewrite.

### Layer A — memoized semantic environment (removes M1; behaviour-neutral)

Evaluate each inline-set binding **once** per `normalize` call and share the resulting `Sem` at all
use sites (a lazily-forced `Map String Sem` / memo table). An *in-progress* set replaces the
per-path `visited` set: a reference to a binding currently being forced stays `SNeu (NTop q)`
(a call), which breaks any residual self/mutual reference. Because the inline set is acyclic,
keying the memo by binding name alone is sound — a diamond returns the same shared `Sem` on every
path, independent of the path taken. The set of bindings that unfold is unchanged; they are merely
not recomputed. Expected output: byte-identical modulo binder naming.

### Layer B — sharing-preserving `quote` (removes M2): memo + join points

Memoize `quote` by **`Sem` value identity**: the first time a shared value is quoted it is bound
**once** to a fresh `let` and every further occurrence emits a reference (classic CSE); an `SLam`
is applied-to-neutrals and quoted a single time, its result fixed to that `let`. For a neutral
`NCase` whose **continuation** is shared across branches, the continuation is lifted to a *join
point* (`let`-bound, referenced from each branch) rather than duplicated — the MIR-level analogue
of the argument-position join points lowering already uses ([ADR 0022](0022-join-points-for-case-in-argument-position.md)).
A + B together make `normalize` polynomial; **this is the gate** — once it lands, the default
(`useNbE = true`) self-host path stops exploding.

The identity mechanism (reference equality vs. ids assigned during `eval`) is an implementation
choice settled at build time; the requirement is only that two references to the *same* evaluated
value quote to the *same* shared binding.

### Layer C — reduction-aware inline/share (the [ADR 0020](0020-reduction-aware-inliner.md) policy)

On the sharing base, replace the syntactic gates (`Semantics.inlineLet`, and the
unconditional unfold in `evalVar`) with the reduction-aware decision: **unfold/inline a reference
exactly when, in its continuation context, it reduces**; otherwise keep it shared (a retained
`SLet`, or for a top-level binding a plain call `NTop`, never a copy). "Reduces" is decided from
the use site's spine:

- a lambda applied to saturating arguments → β fires;
- a record/dictionary under an `Accessor` → projection fires;
- a known constructor under a `case` scrutinee → known-case fires;
- a variable alias / literal / a partial application that saturates to an intrinsic → trivial;
- otherwise (a closure or constructor used as a value, an under-application) → **does not reduce →
  share**.

This needs the use-site continuation threaded into `eval` (the purs-backend-es `shouldInline` /
spine approach). It both lands the fusion win [ADR 0020](0020-reduction-aware-inliner.md) targets
and prevents diamonds from forming in the first place (a leaf is inlined only where it fires,
called elsewhere), reducing the pressure on Layer B's sharing.

### Invariants carried over (the risk surface)

Per [ADR 0020](0020-reduction-aware-inliner.md) §"What must be carried over carefully", unchanged
here:

- **Effects ([ADR 0015](0015-effect-native-support.md) / [ADR 0019](0019-faithful-effect-lowering.md)).**
  `performSem` / `NPerform` stay barriers. Memoization only touches the *pure* inline set
  (effectful bindings are not inline candidates and stay neutral); a retained shared `let`
  preserves single evaluation, so no `Perform` is dropped, duplicated, or reordered.
- **TCE enablers.** `quote`'s `mergeAbs` and `floatAbsOutOfCase` still run; the reduction-aware
  path emits saturated applications, which must still quote into the merged, arity-correct form so
  lambda lifting + TCE fire.
- **Recursion.** Recursive bindings are never unfolded — the in-progress set (Layer A) plus the
  acyclic inline set guarantee it.
- **Capture.** `quote`'s `fresh` discipline is retained; shared `let`s use fresh names.

## Consequences

- **The default-path self-host scalability gate opens at the end of Layer B** — `normalize`
  becomes polynomial, so the `Optimize.Specialize`-class modules compile. This is the gating fix
  among the self-host blockers (the others — `Impurify` stack-safety, the whole-program memory
  floor, and lowering's super-linear passes — are independent and tracked separately).
- **Sharing is separable from policy.** Layers A+B are behaviour-neutral scalability fixes
  verifiable against the strict byte-equal gate; only Layer C deliberately changes output (and is
  guarded by the fusion-converges + collapses-intact criteria of
  [ADR 0020](0020-reduction-aware-inliner.md)).
- **Quote may introduce more `let`s** (shared values that were previously copied). This is the
  intended contraction; it interacts with lowering's own sharing and must not regress the tuned
  collapses, which the bench gate checks.
- It remains a central change to the optimizer core; staging keeps each step independently
  verifiable, and [ADR 0020](0020-reduction-aware-inliner.md)'s blast-radius caveat stands.

### Plan (each step gated: e2e + unit green, the 10-benchmark baseline — `countEffect` / `curry` /
`mapFoldArray` are the fragile ones — unchanged, and the bench wasm byte-equal modulo `$specN`/`$q`
renaming, the [ADR 0032](0032-caller-homed-specialization-for-incremental-builds.md) gate)

1. **Layer A** — memoize inline-binding evaluation. Behaviour-neutral. Added gate: the self-host
   `output/` build (286 modules from `Main`) reaches and **completes** the `Optimize.Specialize`
   module in polynomial time, and a synthetic depth-*d* diamond inline DAG normalizes in O(*d*),
   not O(2^*d*) (a new unit test, the exponential regression guard).
2. **Layer B** — memoized/sharing `quote` + join points. `normalize` is polynomial; the default
   self-host path no longer explodes.
3. **Layer C** — reduction-aware inline/share. Fusion converges and shrinks; the State / dictionary
   / comparison / Effect collapses stay intact.
4. Demote the round/pass caps to a pure backstop (largely already gone under
   [ADR 0021](0021-streaming-dependency-ordered-wpo.md)'s single-pass loop).

An interim **total-size budget backstop** (stop unfolding once a term exceeds N× its input) can be
landed before step 1 if the gate must open immediately; it is a safety net, not the fix, and is
removed once Layer B lands.

## Alternatives considered

- **Memoize `eval` only (Layer A alone).** Insufficient: `quote` still walks every path of the
  shared DAG and re-quotes the diamond leaf exponentially (M2). A is necessary, not sufficient.
- **Go straight to the reduction-aware policy (Layer C first).** It would also prevent the
  diamonds, but it is the largest, output-changing rewrite and needs the spine machinery; landing
  it first couples the scalability gate to a risky policy change. Sharing-first opens the gate under
  byte-equality and de-risks C. (Not chosen for the first cut.)
- **Size/use threshold instead of reduction-awareness.** Rejected in
  [ADR 0020](0020-reduction-aware-inliner.md): the collapses and the explosion share size/use
  profiles. (Retained only as the interim backstop above.)
- **Make the traversals iterative (stack-safe `descend`/`quote`).** Addresses a *stack-overflow*
  failure mode, not this *exponential-work* one; orthogonal (and the subject of the separate
  `Impurify` stack-safety fix). Deferred per [ADR 0020](0020-reduction-aware-inliner.md).

## References

- [ADR 0020](0020-reduction-aware-inliner.md) — reduction-aware inliner (parent; this realizes its stage 3)
- [ADR 0005](0005-high-level-optimization-ir.md) — the optimization IR and `Simplify`
- [ADR 0021](0021-streaming-dependency-ordered-wpo.md) — dependency-ordered single-pass optimization (the loop `normalize` runs in)
- [ADR 0022](0022-join-points-for-case-in-argument-position.md) — join points for case in argument position (the lowering analogue of Layer B's continuation sharing)
- [ADR 0015](0015-effect-native-support.md) / [ADR 0019](0019-faithful-effect-lowering.md) — the Effect barriers `eval`/`quote` must preserve
- [ADR 0032](0032-caller-homed-specialization-for-incremental-builds.md) — the byte-equal-modulo-rename verification gate reused here
