# 0019. A faithful, uniform `Effect` lowering (correctness before collapse)

- Status: Accepted (implemented in `Impurify`; both Effect-collapse bugs fixed)
- Date: 2026-06-05

> **Implemented (2026-06) — both bugs fixed in `Impurify`, no lowering change needed.** The fix
> is *generalized effect reflection* (step 2): the `Impurify` pass now rewrites, to the same
> `perform`-thunk encoding `bind`/`pure` already use —
> - the `Effect` `Functor`/`Apply` method accessors `functorEffect.map`/`applyEffect.apply`
>   (`map f m → \$ev -> let a = perform m in f a`), and
> - **every fully-applied effectful *host* foreign** `log "a" → reflect (\_ -> Π(log "a")) =
>   \$ev -> perform(log "a")` (keyed by `effectfulForeignAritiesFromSigs`: a foreign applied to
>   exactly its value-param count is a complete `Effect`). A foreign already under a run stays
>   performed, so reflection is idempotent across rounds; a directly-performed reflected foreign
>   β-reduces back (`Π(reflect \_ -> Π(f)) → Π(f)`, Simplify ~130).
>
> So an effectful foreign in *value* position (a `void`/`map` argument, a `when`/`case` branch
> or scrutinee, a discarded statement) is a `$Clo` thunk — uniform with `pure`/`bind` — instead
> of an eager `RCallForeign`. This fixes **both** original bugs: the dropped `void`/`map` effect
> *and* `when b (Console.log …)`'s `illegal cast`. The full `examples/effect-ref` `main` (native
> `Ref` + `whenM` over a host foreign + `modify_` + `>>=`/`show`) now runs correctly. e2e 136 /
> unit 109 green, the `State`/`Effect` constant-stack collapse preserved; regression guards
> `voidTest`/`mapTest` in `effectPrim.mjs` and `effectRefMain.mjs` (the full example).
>
> The `perform(case)→case→perform` commuting conversion was tried and reverted (insufficient —
> the scrutinee was still eagerly evaluated; reflection makes it a thunk instead). The
> `~137`-strip / never-drop / `--no-opt`-oracle items below remain as the deeper uniform-rep
> programme, but are no longer needed for these two bugs.

## Context

ADR 0015 lowers `Effect` by *reflecting* its function-monad structure and **collapsing**
it to straight-line code / loops, driven by a whole-program purity analysis
(`Optimize/Purity.purs`) that decides which `Perform`s may be dropped/reordered. This is
fast (it beats purs-backend-es on `CountState`), but a cluster of correctness bugs has
shown the collapse is being trusted for *correctness*, and its model leaks. Two were
pinned to the middle-end (confirmed: with `--no-opt` the voided effect runs; with the
optimizer on it is dropped), with the optimized MIR as evidence:

- **A voided effect is dropped.** `do { void (Console.log "a"); Console.log "b" }`
  optimizes to `\$ev -> perform(Console.log "b")` — the `void (Console.log "a")` is gone.
  Root: the purity analysis treats `void`/`Data.Functor.map`-wrapped effects as pure
  (effectfulness does not propagate through the `Functor` combinator), so `Simplify`'s
  "drop a dead, pure `let` binding" rule removes it. The analysis conflates *value unused*
  with *computation droppable* — valid for pure code, wrong for `Effect`.
- **A conditional effect on a runtime boolean traps.** `when b act` optimizes to
  `perform(case b, act of { true, m -> m ; false, _ -> \$ev -> unit })`. The two branches
  have **inconsistent representation**: the `act` branch is the bare effectful-foreign
  application `Console.log("yes")` (lowered *eagerly* to a performed `RCallForeign`,
  yielding `Unit`), while the other branch is a thunk `\$ev -> unit` (`$Clo`). The outer
  `perform` then `applyClo`s the merged case result, casting the `Unit` branch to `$Clo`
  → `illegal cast`. (A *constant* `b` folds the `case` away, which is why constant `when`
  works and runtime `when` does not.)

### The precise mechanism of the dropped effect

`Optimize/Purity` is **head-based**: `runImpure (App (Var q) args) = headImpure q || any
(evalImpure ctx) args`. Note it consults `evalImpure` (does *constructing* an arg run an
effect?), never `runImpure`, on the arguments — because it cannot know *which* arguments a
higher-order function will perform. So for `void m` / `map dict m` / `when b act` — combinators
that perform an **argument** — the effect is invisible: `headImpure(Data.Functor.void)` is
false (it is not an effectful foreign), and `evalImpure(Console.log "a")` is false (building
the value is pure). Worse, these combinators are **dictionary-polymorphic**: whether
performing `void dict m` is effectful depends on `dict` (`functorEffect` ⇒ yes, `functorArray`
⇒ no), which a static head/fixpoint analysis cannot see. The analysis is therefore only
sound *after* dict elimination + inlining have fully specialised the combinator to its
concrete, `perform`-exposing body — so **correctness silently depends on the optimizer fully
firing**.

This was pinned by instrumentation. `Effect`'s `map`/`apply` are `liftA1`/`ap` (so `void`
goes `map (const unit)` → `liftA1` → `apply (pure …)` → `ap` → `bind`). Before that chain is
inlined, the simplifier hits `perform(liftA1 (const unit) (log "a"))` and applies the rule
`M.Perform e | runPure e → App e [unit]` (Simplify ~137) — which **strips the `perform`
marker**, turning the run into a plain application, *gated on `runPure`*. But `runPure` is the
unsound head-based predicate: `liftA1`/`void` are dict-polymorphic, judged pure-to-run, so the
gate passes and the marker is removed. From then on the effect is a bare application the
purity analysis cannot see, and `Simplify`'s dead `let` rule drops it. (Confirmed: disabling
the dead-`let` drop preserves `perform(log "a")`; the strip happens upstream of it.)

**A localized purity patch is a dead end.** Making the dead-`let` drop gate on a sound
"contains a `Perform`" check does not help — the marker is already gone (it is an `App`, not a
`Perform`) by the time the drop fires. Making `runImpure` conservatively count an
application's arguments as performed (`any runImpure args`) *would* catch `void`, but it also
flags `go(acc)` in the `State` worker (a local argument is `runImpure`-opaque ⇒ true), which
**kills the very collapse ADR 0015 exists for**. Without types, the analysis cannot tell a
performed `Effect` argument from a plain value argument. So the marker must not be lost in the
first place — i.e. the fix is the uniform representation below, not a smarter heuristic.

Both share one deeper cause: **`Effect a` has no uniform, faithful representation.**
Whether an effect is preserved depends on a leaky purity heuristic, and whether an `Effect`
value is a thunk (`$Clo`) or an eager host call (`RCallForeign`) depends on its *syntactic
position* — so effects do not compose through `void` / `case` / `if`. A third symptom
(ADR 0018): a top-level `Effect a` bound to a bare expression is a `$Clo` CAF the export
path fails to perform. And `--no-opt` cannot even *run* `Effect` (dict-elim off → the
`bind`/`discard` dictionaries are unresolved), i.e. there is **no correct baseline**: the
collapse is not an optimization layered on a faithful lowering — it *is* the lowering.

## Decision

**Re-establish a faithful, always-correct `Effect` lowering as the baseline, and demote
ADR 0015's collapse to a guarded optimization on top of it.** Correctness must not depend
on the optimizer.

1. **Uniform representation.** Every `Effect a` is a thunk (`$Clo`, `\$ev -> …`); the *only*
   thing that runs it is applying it to the perform-unit. `pure`, `bind`, `map`, `apply`,
   `void`, `discard`, `when`, `unless`, `if`-in-`Effect`, … all compose at the value level
   and **produce thunks** — none performs eagerly. So both branches of `when`'s `case` are
   thunks (no rep mismatch), and `void m` is a thunk whose body performs `m`.
2. **Effectful foreigns are thunks too.** `Console.log "x" :: Effect Unit` is a thunk that,
   *when performed*, makes the host call — not an eager `RCallForeign` in value position.
   This is what lets it flow through `case`/`void`/a `let` uniformly.
3. **Effects are never dropped/reordered/duplicated in the baseline.** No purity heuristic
   gates correctness: a performed computation stays, regardless of whether its result is
   used. (`void` works because nothing is dropped, not because the analysis got smarter.)
4. **Collapse becomes a separable, *conservative* optimization** (ADR 0015 machinery,
   retained): apply a rewrite only when it provably preserves the order and multiplicity of
   every `Perform`; otherwise leave the faithful form. The key fast path — *an
   effectful-foreign application syntactically directly under `perform`* → eager
   `RCallForeign` (no thunk allocation) — is kept, but **only** in that position; elsewhere
   the foreign is a thunk. The `State`-monad collapse (the measured win) is re-derived as
   one such safe rewrite, benchmarked against the faithful baseline so we can see its
   contribution rather than assume it.
5. **Make `--no-opt` a real correct mode.** The faithful lowering must run `Effect` without
   dict-elim/collapse (resolve `bind`/`discard`/`pure` structurally), so it can serve as the
   correctness oracle the optimization is differentially tested against.

The native primitives (ADR 0017 `Effect.Ref`, ADR 0018 loops/`EffectFn`) are unaffected —
they are wasm-native intrinsics and already correct; this ADR concerns the *monadic glue*
(`bind`/`pure`/`map`/`discard`/`when`/…) and effectful-foreign value representation.

**Narrowing from the first implementation attempts (2026-06, all reverted; tree green).**
Removing the `~137` strip alone does *not* fix `void` — and it breaks only the deep-loop
constant-stack test (the saturated tail-call `perform(go …)` → `go(…, unit)` it enables is
load-bearing). A sharper repro: with the strip removed,

```
voidKept = do { _ <- Console.log "a"; Console.log "b" }   -- ⇒ \$ev -> let $x = perform(log "a") in perform(log "b")   ✅ both kept
main     = do { void (Console.log "a"); Console.log "b" } -- ⇒ \$ev -> perform(log "b")                                ❌ void lost
```

So an **explicit `_ <- m` (via `bindE`) is preserved**, but the **`void`/`map` Functor path
(`map = liftA1`, `apply = ap`) loses the effect** — and not via `~137`. By hand the `ap`/`bind`
reduction *should* converge to the same `let a = perform(log "a") in …` that `voidKept` keeps,
so the drop is an actual pass interaction (Specialize / Inline / DictElim, not only Simplify)
that needs per-round MIR tracing to pin.

**Pinned by per-round MIR snapshots (temp `DumpRounds`, since deleted).** The drop is in
**round 2's `simplify`**, on the Functor path:

```
round 1 → simplify : bindEffect.bind(functorEffect.map(\v -> unit, log "a"), \_ -> log "b")
round 2 → simplify : \$ev -> perform(log "b")          -- log "a" dropped here
```

In round 2 the simplifier resolves the `bindEffect.bind` / `functorEffect.map` *accessors*
and inlines `map = liftA1` (= `apply (pure …)` = `ap` = `bind`-based). The first bind operand
— the `map`/`liftA1`-wrapped computation — is **discarded** by the `\_` continuation. While
it is still plain (pre-impurify) applications, the dead-code rules judge it pure (no `Perform`
exists yet; `liftA1` is dict-polymorphic-pure) and drop it. The contrast with `voidKept` is
decisive: `bind(log "a", \_ -> …)`'s first operand is `log "a"` *directly*, so impurify turns
it into `perform(log "a")` (a `Perform`, judged effectful) and it survives — but the Functor
**wrapper** (`map`/`liftA1`) is exactly what keeps a discarded effect looking pure to DCE
until impurification, which is too late. So: **DCE runs on `Effect` glue before it is
impurified, and pre-impurify `Effect` ops look pure.** The fix is to mark performing earlier —
impurify `map`/`apply` (not just `bind`/`pure`), or interleave impurify so no `Effect`
operation reaches DCE in plain-application form — i.e. step 2 below is the lever, not the
dead-`let`/strip gates.

**Implementation order (from the instrumentation above).**

1. **Stop losing the marker.** The `perform e → App e [unit]` strip (Simplify ~137) is the
   leak: it dissolves a `Perform` into a plain application gated on the unsound `runPure`.
   Either remove this rewrite (keep `Perform` as a node all the way to lowering, which
   already knows how to lower it) or gate it on a *sound* run-purity that defaults to
   effectful for any not-yet-resolved (dict-polymorphic) application. The recursive
   `perform(go(…))` → tail-call collapse it enables must be re-expressed as a rewrite that
   does not depend on stripping the marker (e.g. recognise the self-call shape directly).
2. **Cover all the glue.** `Impurify` rewrites only `pureE`/`bindE`/`unsafePerformEffect`;
   `map`/`apply` reach `bind` only via `liftA1`/`ap` inlining. Either rely on that inlining
   *before* any marker-affecting rule runs, or impurify the `Effect` `Functor`/`Apply`
   methods directly — so every performed sub-term is a `Perform`, never a bare `App`.
3. **Never drop a `Perform`.** Once the marker is reliable, the dead/single-use `let` rules
   gate on "contains a `Perform`" (sound), so an unused effect is kept.
4. Re-validate the `State`/`Effect` collapse against the `--no-opt` faithful oracle.

## Consequences

- The combinator-whack-a-mole ends: `void`, `when`, `unless`, `for_`, `traverse_`, … are
  correct by construction (uniform thunks + no effect dropping), not by enumerating cases in
  the purity analysis.
- A regression oracle exists: every `effectPrim`/`effect-ref` case can be checked against the
  `--no-opt` faithful build, and the collapse validated as *behaviour-preserving* + faster.
- The Effect-CAF-export gap (ADR 0018) falls out: a root `Effect a` is uniformly a thunk, so
  the export wrapper always performs it (apply the unit) — no special CAF case.
- Cost: effectful foreigns and monadic glue allocate thunks in the *unoptimized* baseline;
  the collapse must recover the performance the current always-on reflection already gets.
  Net perf should be neutral-to-better where the collapse proves safe, with a slower but
  correct fallback where it cannot — the right trade.
- This supersedes the *correctness* responsibility of ADR 0015; ADR 0015 stands as the
  optimization layer. (Mark 0015 accordingly when 0019 lands.)

## Alternatives considered

- **Keep patching the purity analysis / collapse** (the status quo). Rejected: each fix
  covers one combinator; the model is leaky at the root (position-dependent representation +
  value-unused⇒droppable), so new combinators keep breaking. The test suite is kept either
  way as the safety net.
- **Drop the JS foreign fallback.** Orthogonal — the bugs are in the monadic lowering, not
  the JS boundary; dropping it loses genuine host I/O (DOM/console/user JS) and fixes
  nothing. The per-foreign native-vs-JS split (native for pure/structural, JS for real host
  effects) stays.
- **Full backend rewrite.** Unwarranted — the IR, codegen, native primitives, and the
  collapse machinery are sound; only the `Effect` correctness foundation needs rebuilding.
- **CPS / explicit state-token threading for `Effect`.** A heavier representation than the
  thunk model; the thunk (`Unit -> a`) form matches PureScript's own and the existing
  `$Clo`/`perform` machinery, so it is the smaller, lower-risk change.
