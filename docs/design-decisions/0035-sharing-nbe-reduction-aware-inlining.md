# 0035. Sharing/memoizing the NbE reducer, then reduction-aware inlining

- Status: Accepted — **Layers A + B landed 2026-06-17** (the sharing/scalability gate); Layer C (reduction-aware policy) deferred
- Date: 2026-06-16

> Realizes **stage 3** of [ADR 0020](0020-reduction-aware-inliner.md) (whose NbE core landed as
> stages 1–2). [ADR 0020](0020-reduction-aware-inliner.md) motivated reduction-aware inlining from
> *fusion* programs; this record adds a second, independently sufficient motivation discovered by
> self-compilation — the NbE reducer is **itself exponential** for lack of sharing — and sequences
> the fix so the scalability gate is opened *before* the inline-policy rewrite.

> **Progress (2026-06-17, branch `feat/reduction-aware-inlining`).** Layers **A and B are
> implemented** in `MiddleEnd.Optimize.Semantics`. ~~The scalability gate is open: the
> optimized self-compile now compiles *through* `Optimize.Specialize` (the old hang point) — the
> exponential is gone (it then OOMs in a later module, which is the independent whole-program
> *memory* floor, not this defect).~~ **(Corrected below, 2026-06-17: A+B removed the NbE
> exponential but did *not* by themselves clear `Optimize.Specialize`; the "OOM" read was premature —
> the real remaining blocker there was *code size*, fixed by the canonicalKey + size-cap work.)**
> Layer A is a `Data.Lazy` memo (`Map String (Lazy Sem)`) keyed
> by inline-binding name; Layer B is an `SShared k Sem` tag that `unShared` strips at every
> reduction site (so it never blocks a redex) while `quote` CSEs it into a hoisted `let` (the Q
> state carries the CSE table). The identity mechanism (§Decision, "settled at build time") was
> chosen as **value-tagging**, *not* `unsafeRefEq` (rejected: not referentially transparent) nor
> ids-assigned-during-eval (rejected: would force the whole HOAS evaluator into a monad). **Byte
> equality was *not* required** — the current compiler is not yet a correct self-host reference, so
> the gate is *no regression in the test suite + benchmarks + `examples/`*, which holds: unit
> ~~160/160~~ **162/162** (the diamond O(d) guard plus the two Layer-C-lite cap guards, below),
> e2e 150/150, the `test:bin` examples, bench no
> regression (most benches 1.05–1.19× *faster* from the CSE sharing; baseline untouched), and
> `examples/metatheory` compiles and runs correctly. The exponential regression guard is
> `compiler/test/NbeStress.purs` (`Test.NbeStress.spec`, wired into `test:unit`): a depth-20 diamond
> inline DAG normalizes to **linear** size (≈ 4·d + 3) rather than 2^d.

> **Correction (2026-06-17).** Layers A+B were **necessary but not sufficient** to compile
> `Optimize.Specialize` / complete the optimized self-compile. With the NbE *recomputation*
> exponential gone, that module still hung on two **code-size** problems orthogonal to A/B's fix
> (A+B bound recomputation, not output size): **(1)** `Optimize.Specialize.canonicalKey` built its
> de-dup `Map` key by `show`-ing the substituted lambda body — multi-KB strings, *built and retained
> as keys* — now **hashed** (`Serialize.Hash.hashString`) over a single `substMany` pass; **(2)** NbE
> inlines the derived `genericShow` dictionary of the large IR ADTs into multi-million-node normal
> forms, now bounded by **`DictElim.normalFormSizeCap`** (a *Layer C lite* size guard — distinct from
> the deferred reduction-aware *policy* of §Layer C): a reduced declaration exceeding the cap is
> re-reduced with the inline context emptied (the binding stays a call — the `--no-opt`-correct
> shape). With **all three** (A, B, and (1)+(2)) the optimized self-compile of `PursWasm.CLI.Main`
> now **completes**, writing a valid 8 MB `index.wasm`. Two cap regression guards were added to
> `Test.NbeStress` (unit 160 → 162).

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
  becomes polynomial. ~~so the `Optimize.Specialize`-class modules compile.~~ _(Correction
  2026-06-17: polynomial `normalize` is necessary but not sufficient — `Optimize.Specialize`
  additionally needed the canonicalKey hashing + `normalFormSizeCap` code-size cap; see the
  Correction note up top.)_ This is the gating fix
  among the self-host blockers (the others — `Impurify` stack-safety, the whole-program memory
  floor, and lowering's super-linear passes — are independent and tracked separately).
- **Sharing is separable from policy.** Layers A+B are behaviour-neutral scalability fixes; only
  Layer C deliberately changes the inline *policy* (and is guarded by the fusion-converges +
  collapses-intact criteria of [ADR 0020](0020-reduction-aware-inliner.md)).
  - **Correction (2026-06-17):** this originally said A+B are "verifiable against the strict
    byte-equal gate". Only **Layer A** turned out byte-identical; **Layer B's CSE necessarily
    changes the IR** (it hoists shared values into `let`s — the "more `let`s" the next bullet
    predicts), so it is *behaviour*-neutral, not *byte*-neutral. The realized gate is therefore
    **test-suite + benchmark + `examples/` no-regression** (the current compiler is not yet a
    correct self-host reference, so byte-matching it has limited value), which A+B meet.
- **Quote may introduce more `let`s** (shared values that were previously copied). This is the
  intended contraction; it interacts with lowering's own sharing and must not regress the tuned
  collapses, which the bench gate checks.
- It remains a central change to the optimizer core; staging keeps each step independently
  verifiable, and [ADR 0020](0020-reduction-aware-inliner.md)'s blast-radius caveat stands.

### Plan

Each step is gated by: e2e + unit green; the 10-benchmark baseline unchanged (`countEffect` /
`curry` / `mapFoldArray` are the fragile ones); and the bench wasm byte-equal modulo `$specN`/`$q`
renaming (the [ADR 0032](0032-caller-homed-specialization-for-incremental-builds.md) gate).

1. **Layer A** — memoize inline-binding evaluation. Behaviour-neutral. Added gate: the self-host
   `output/` build (286 modules from `Main`) reaches and **completes** the `Optimize.Specialize`
   module in polynomial time, and a synthetic depth-*d* diamond inline DAG normalizes in O(*d*),
   not O(2^*d*) (a new unit test, the exponential regression guard).
   - ✅ **Landed 2026-06-17.** `Data.Lazy` memo in `Semantics.normalize`, byte-IDENTICAL (bench
     differential). **Correction to this step's gate:** Layer A *alone* does not make `normalize`
     O(*d*) — quote (M2) still re-walks the shared DAG, so the diamond stays exponential until
     Layer B. The O(*d*) guard (`Test.NbeStress`) therefore exercises **A + B together**, and the
     `Optimize.Specialize` completion likewise needs both.
2. **Layer B** — memoized/sharing `quote` + join points. `normalize` is polynomial; the default
   self-host path no longer explodes.
   - ✅ **Landed 2026-06-17.** `SShared k Sem` + `unShared` (strip at every reduction site) + a
     `quote` CSE table hoisting shared values to a top-of-decl `let`. *No `NCase`-continuation join
     point was needed* for the gate — value-level CSE alone made `normalize` linear on the diamond
     and on `Optimize.Specialize`; the join-point refinement remains available if a future case
     surfaces a shared *continuation* the value CSE misses. Gate met without byte-equality (see the
     Progress note up top): tests + bench + `examples/metatheory` no regression.
3. **Layer C** — reduction-aware inline/share. Fusion converges and shrinks; the State / dictionary
   / comparison / Effect collapses stay intact. *(Deferred — the scalability gate is already open
   after A + B, so C is now an optimization-quality improvement, not a scalability blocker.)*
4. Demote the round/pass caps to a pure backstop (largely already gone under
   [ADR 0021](0021-streaming-dependency-ordered-wpo.md)'s single-pass loop).

An interim **total-size budget backstop** (stop unfolding once a term exceeds N× its input) can be
landed before step 1 if the gate must open immediately; it is a safety net, not the fix, and is
removed once Layer B lands. *(Not needed — A + B landed together and opened the gate directly; no
interim backstop was introduced.)*

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
