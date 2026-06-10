# Optimizations

How the backend turns PureScript into fast WebAssembly. The uniform value model
(ADR 0001 / 0004) boxes *every* value as an `eqref` so that polymorphism and the
heap shapes work; on its own that would be slow. The optimizer's job is to **remove
the boxing and the abstraction** wherever it can prove it safe, so the emitted code
is close to what you would write by hand. This document is descriptive — the design
rationale lives in the [ADRs](./design-decisions); the mechanism lives in
`compiler/src/PureScript/Backend/Wasm/MiddleEnd/`.

- [Where optimization happens](#where-optimization-happens)
- [The reduction kernel: local reductions](#the-reduction-kernel-local-reductions)
  - [Capture-avoiding substitution](#capture-avoiding-substitution)
  - [Inlining](#inlining)
  - [Beta reduction and currying normalization](#beta-reduction-and-currying-normalization)
  - [Record-accessor projection](#record-accessor-projection)
  - [Case of known constructor](#case-of-known-constructor)
  - [Let-binding inlining and record scalarization](#let-binding-inlining-and-record-scalarization)
  - [Boolean short-circuiting](#boolean-short-circuiting)
  - [Lambda merging](#lambda-merging)
  - [Commuting conversion](#commuting-conversion)
- [The policies that drive it](#the-policies-that-drive-it)
  - [Dictionary elimination](#dictionary-elimination)
  - [General known-function inlining](#general-known-function-inlining)
  - [Newtype transparency](#newtype-transparency)
  - [Higher-order specialization](#higher-order-specialization)
  - [Effect: impurification, reflection, and purity](#effect-impurification-reflection-and-purity)
- [Structural transformations](#structural-transformations)
  - [Lambda lifting](#lambda-lifting)
  - [Representation analysis and unboxing](#representation-analysis-and-unboxing)
  - [Tail-call elimination](#tail-call-elimination)
  - [Dead-code elimination](#dead-code-elimination)
- [Worked example: collapsing the State monad](#worked-example-collapsing-the-state-monad)
- [Worked example: the Effect monad](#worked-example-the-effect-monad)
- [Known gaps](#known-gaps)

## Where optimization happens

Optimization is a **middle end** (ADR 0005) operating on a high-level IR (MIR) that
sits between CoreFn and the backend lowering:

```
CoreFn ── Transl ──▶ MIR ── optimizeProgram ──▶ MIR ── lowerModules ──▶ backend IR ──▶ Codegen ──▶ wasm
```

- `Transl.purs` translates CoreFn to MIR faithfully — the only structural change is
  **uncurrying** (an `Abs`/`App` carries a parameter/argument *list*, so arity is
  explicit). Dictionaries and records stay ordinary values; the `Meta` a later pass
  needs (`IsTypeClassConstructor`, `IsNewtype`) is kept on the binding.
- `MiddleEnd.optimizeProgram` builds its optimization **context** (the inline set,
  transparent constructors, purity) **whole-program** — a dictionary or function used in
  one module is defined in another — but then optimizes modules **one at a time, in
  dependency order**, each against the already-finalized form of its dependencies, rather
  than re-running the whole program to a fixed point (ADR 0021):

  ```
  lambda-lift each module                          (per module)
  specialize higher-order calls                    (whole-program, once)
  for each module, in dependency order:
    build the inline context from the finalized dependencies + this module
    simplify → impurify → simplify                 (this module, once)
  ```

  Dependency order is what removes the need for repeated rounds: eliminating a dictionary
  turns a method binding into a fresh inlinable alias (`add = Data.Semiring.add(semiringInt)`
  becomes `add = intAdd`), and because a dependency is finalized before its dependents, a
  dependent inlines the already-reduced alias directly. (This replaced an older
  whole-program fixed-point loop that re-ran inlining to convergence and blew up on
  transformer-heavy code.)

Per-module optimization drives each binding to a normal form under the local reductions
below; inlining happens there, which is why the inline set must be acyclic (see
[inlining](#inlining)). The reducer has two implementations behind a toggle
(`DictElim.useNbE`, default the first): a normalisation-by-evaluation pass
(`Optimize/Semantics.purs`, ADR 0020) and the original rule-based fixpoint
(`Optimize/Simplify.purs`). They perform the **same** reductions — described next.

`purs-wasm build -I <output> -e <Entry> --dump-mir <Module>` writes that module's MIR after
every optimizer sub-stage to `<output>/<Module>.mir.txt` — the way to watch a pass rewrite the
tree (it sees the real reachable closure, unlike the retired `dump-mir.mjs`/`dump-opt.mjs` scripts,
which only linked the fixtures you named).

## The reduction kernel: local reductions

The reduction kernel performs the local, semantics-preserving rewrites below; the
*policies* in the next section decide which bindings and constructors they may fire on.
As noted above it has two implementations: the default NbE normaliser
(`Optimize/Semantics.purs`) evaluates an expression into a semantic domain and quotes it
back, reducing where operands are known; `Optimize/Simplify.purs` rebuilds the expression
bottom-up and applies one reduction per node until nothing changes. Both reach the same
normal form, so the rules below describe either.

### Capture-avoiding substitution

The foundation everything else stands on. Substituting a term under a binder must not
let the term's free variables be captured. This genuinely arises here: inlining and
beta compose scopes that were named independently, and PureScript's names are not
globally unique (every `State` step is a `\s -> …`, so they nest). The substitution
carries an **in-scope set** (the free variables of the replacement terms) and, when it
descends under a binder whose name is in that set, **clones the binder to a fresh
name** (GHC's approach) rather than capturing. A binder that merely shadows a
substituted name is dropped from the map. Without this, the inlining and scalarization
below would be unsound.

### Inlining

A name in the *inline set* is replaced by its body (the policies below populate the
set). The inline set is kept **acyclic**: because the reducer unfolds inline bindings
transitively, a cycle (`f` inlines `g` inlines `f`) would not converge, so candidates
that lie on a call cycle are excluded — a one-way chain `f → g → h` is fine.

### Beta reduction and currying normalization

`(\ps -> b)(args)` reduces by binding `ps` to `args` (with extra arguments re-applied,
missing ones leaving a residual lambda). A curried application spine `f(a)(b)` is first
flattened to the canonical n-ary `f(a, b)`, so a partially applied function saturates
once its remaining arguments arrive and is recognized as the underlying primitive
rather than staying a heap closure.

### Record-accessor projection

`{ …, l: v, … }.l → v`. It fires when the accessor is applied directly to a record
literal, and also when applied to a top-level **plain-record instance** (a dictionary
that is a bare record literal, e.g. `heytingAlgebraBoolean`) — the field is projected
by name without materializing the whole record, so a record that references itself
through another field never expands.

### Case of known constructor

A `case` whose scrutinee's constructor is known selects the matching alternative and
binds its sub-patterns. Two sub-rules:

- **Transparent constructors** (a `newtype`, or a type-class dictionary, which is a
  newtype-identity): `case x of NT(a) -> b` → `b[a := x]`, for *any* scrutinee, because
  the constructor is the identity on its single payload. This is newtype/dictionary
  *unwrap*.
- **Rigid data constructors**: `case C(as) of … C(bs) -> b …` → `b[bs := as]`, but only
  when the scrutinee is a *statically known* constructor application `C(…)`. This is
  the classic constant-folding of a pattern match.

The rule is **multi-scrutinee**: PureScript desugars a multi-argument pattern equation
(`runState (State f) s = f s`) to `case v, s of State(f), s1 -> f(s1)`, so reducing the
multi-scrutinee form is what unwraps a function-represented monad's combinators.

### Let-binding inlining and record scalarization

- **Single-use / dead let**: `let x = e in body` with `x` used at most once is inlined,
  so a partial application a dictionary method resolved to flows into its one use and
  saturates instead of staying a heap closure.
- **Trivial-record scalarization**: a let-bound *record literal whose fields are all
  trivial* (a variable or a scalar literal) is inlined even when used several times.
  Duplicating trivial fields is free, and it lets the accessor rule project each `.l`
  directly — so an intermediate record (a `State` step's `{ state, value }`) never
  allocates. (The triviality gate is about avoiding *work duplication*, not the field
  type — a variable field of any type qualifies.)
- A multi-binding non-recursive `let` is split into nested single-binding lets so the
  single-use rule can reach each one.

### Boolean short-circuiting

`a || b` / `a && b` evaluate `b` only when needed, matching PureScript/JS semantics —
the `Boolean` `disj`/`conj` resolve to foreign intrinsics that the backend would
otherwise emit as the *strict* `i32.or` / `i32.and`. The simplifier rewrites them to
`case a of true -> … ; _ -> …` control flow.

### Lambda merging

`\n -> \s -> b` → `\n s -> b` (when the parameter lists are disjoint). A curried lambda
introduced by optimization is merged into one parameter list, so a saturated self-call
becomes a direct (tail-callable) call rather than a call that returns a closure which
is then applied.

### Commuting conversion

`(case s of … -> body)(args)` → `case s of … -> body(args)` (when `args` are trivial
and no branch binder would capture their free variables). Pushing the application into
the branches turns a branch ending in a self-call into a *tail* call instead of the
result of an applied `case` — which is what lets tail-call elimination then fire.

## The policies that drive it

The simplifier is mechanism; these decide what it may fire on.

### Dictionary elimination

`Optimize/DictElim.purs` is the whole-program policy that collapses type-class
plumbing. It scans every module for the transparent dictionary constructors
(`IsTypeClassConstructor`), the method accessors that destructure them, the instance
dictionaries that construct them, and the small **derived helpers** (`lessThan`,
`notEq`, …) that consume them, and feeds them to the simplifier as its inline set and
transparent-constructor set. A use site `Data.Eq.eq(eqInt)` then collapses to the
intrinsic `Data.Eq.eqIntImpl`; `compare` to `ordIntImpl(LT, EQ, GT)`. Two guards keep
it cheap and terminating: a **size cap** (large instances such as the `Generic`
`to`/`from` records are not inlined) and **acyclicity**.

### General known-function inlining

`Optimize/Inline.purs` extends the inline set beyond dictionary plumbing to *ordinary*
top-level bindings that are **small or used at most once**, and **not on a call cycle**
(a transitive-closure check excludes mutual recursion but keeps one-way chains). Data
constructor bindings are left alone (inlining them to their `Constructor` value would
defeat case-of-known-constructor). Single-use inlining never grows code; small-binding
inlining is bounded by the size cap.

### Newtype transparency

User `newtype` constructors are the identity on their payload, so the simplifier treats
them as transparent (the same as dictionaries) — `State f ≡ f`, and `case x of State(a)
-> …` unwraps. `Inline.newtypeCtorNames` collects them. *Subtlety:* a `newtype`
constructor's `IsNewtype` meta sits on its defining *expression*, not the binding, so
`Transl` promotes it onto the binding; without that, user newtypes were never
transparent and a `newtype`-wrapped abstraction never collapsed.

### Higher-order specialization

`Optimize/Specialize.purs` is the static-argument transformation. A recursive
higher-order function with a **static function parameter** (applied in the body and
passed unchanged at the same index in every self-call — `filterBy`, `mapList`,
`foldlList`) called with a **lambda** gets a specialized copy: the function parameter
is removed, the lambda's body inlined, its free variables threaded as leading
parameters (as in lambda lifting), and self-calls rewritten to the specialization.
The closure allocation and the per-element indirect (`call_ref`) application with boxed
arguments vanish, leaving a direct inlined operation. Specializations are de-duplicated
by callee and lambda *shape*, so `filterBy(\x -> x <= p)` and `filterBy(\x -> x > p)`
produce two specializations each taking `p`.

### Effect: impurification, reflection, and purity

`Effect` is opaque, so it cannot collapse the way a transparent `newtype` monad does
(see the State example). Two passes make it transparent — observing the whole `Effect`
surface, *foreigns included*, as nullary thunks (`Effect a ≃ Unit -> a`) so the ordinary
pipeline can crush them — and a third keeps that sound.

**Impurification** (`Optimize/Impurify.purs`, ADR 0015) reifies the monad primitives
`pureE` / `bindE` / `unsafePerformEffect` into thunk lambdas (`\$ev -> …`) and a distinct
`Perform` node (`perform e ≃ e(unit)`).

**Generalized effect reflection** (GER, ADR 0019) extends that to the rest of the `Effect`
surface, so that *every* `Effect` value is uniformly a nullary thunk rather than an eager
call. The `Functor`/`Apply` methods `functorEffect.map` / `applyEffect.apply` (which are
`liftA1` / `ap`) are rewritten to the same `perform`-thunk form (`map f m → \$ev -> let a =
perform m in f a`), and a fully-applied effectful **foreign** is *reflected* to a thunk that
performs it: `log "a" → \$ev -> perform(log "a")` (`reflect (\_ -> Π(log "a"))`, keyed by the
foreign's arity). It is idempotent — a foreign already under a `perform` stays performed, and
a thunk performed directly β-reduces straight back (`perform(\$ev -> perform e) → perform e`).
Without it, an effectful foreign sitting in *value* position (a `void`/`map` argument, a
`when`/`case` branch, a discarded statement) would lower to an eager call that runs out of
order — or, when discarded, looks pure and is dropped.

Now that `Effect` — foreigns and all — is just nullary thunks, the **ordinary** pipeline
(beta, inlining, lambda merging, [commuting conversion](#commuting-conversion), TCE)
**crushes the thunks** with no Effect-specific machinery: a pure `Effect` do-block collapses
exactly like `State`, to the same allocation-free **constant-stack tail loop** — so the
`Effect` monad's stack safety is *preserved* through optimization, not lost. Two simplifier
rules earn their keep: **floating a single-parameter lambda out of a `case`'s branches**, so
the vestigial `\$ev` thunk merges into a recursive worker and its self-call TCEs; and
**floating a `let` out of an application head**, so `map`/`apply` saturate.

**Purity** (`Optimize/Purity.purs`) is the safety belt. Once `Effect` is just functions, the
pure-code rules would happily drop, reorder, or duplicate a *genuinely effectful* run (a host
`console.log`) — the type that said "this is an effect" is gone. So a whole-program
least-fixpoint tags which bindings are **effectful to run** (they perform a known effectful
foreign — `log`, `record` — directly, transitively, or via an opaque/local producer, treated
conservatively; the seed is the foreigns whose result type is `Effect _`), and the simplifier
gates on the tag: a `Perform` of a *pure* run collapses, while a `Perform` of an effectful one
is a **barrier** the drop/reorder/duplicate rules must respect. Together with GER making every
effect a visible `Perform`, this is what keeps an accidentally-discarded effect — `void (log
"a")`, a `when` branch — running, in order, instead of being DCE'd; while a self-recursive
`Effect` loop that only performs itself stays pure and still collapses.

## Structural transformations

These are not local reductions but whole-function rewrites (or backend choices).

### Lambda lifting

`Optimize/LambdaLift.purs` floats a nested function that captures free variables out to
a top-level supercombinator, passing the captured variables as leading parameters. It
also handles **mutually-recursive groups that capture free variables** (the `nqueens`
`go`/`tryCols`/`placeAt`, which all capture the board size `n`): each member is lifted
with the group's shared free variables prepended, and every reference — sibling and use
site — is rewritten to the lifted name. The result is a direct `call` with unboxed
arguments instead of closures invoked by `call_ref` with boxed arguments. Lambda
lifting always runs (even with other optimization disabled), because it is what makes
deep tail recursion run in constant stack.

### Representation analysis and unboxing

The backend lowering (ADR 0013) chooses a **representation** for each value slot and
unboxes where it avoids allocation:

- `Int` / `Char` flow as raw `i32`, `Number` as raw `f64`, where the value does not
  need to be an `eqref`. `Boolean` is an unboxed `i31ref`.
- **ADT field unboxing** (front-B): an ADT is an open base struct `$Data` (the
  constructor tag) plus a per-signature struct subtype, with concrete *scalar* fields
  (`Int`/`Number`/`Char`) stored unboxed in the struct rather than as boxed `eqref`
  elements. Field representations come from the externs (`externs.cbor`).

Polymorphic fields stay boxed (a `List a`'s element is an `eqref`) — this is the
deliberate residual; see [known gaps](#known-gaps).

### Tail-call elimination

A direct call whose result is immediately returned, and whose result representation
matches the caller's, is emitted as a `return_call` — so a tail-recursive chain (or a
tail-recursive lambda-lifted closure) runs in constant stack. This is what stops deep
loops from overflowing; it is also the final step that makes a collapsed monadic loop
constant-stack (see the worked example).

### Dead-code elimination

Linking is whole-program with **reachability pruning** (ADR 0009): only functions
reachable from the entry module's exports are lowered, so dictionaries and helpers that
optimization made dead are tree-shaken, and a self-contained program is one wasm with
no leftover plumbing.

## Worked example: collapsing the State monad

A `State` monad is a `newtype` over a function (`State (Int -> { state, value })`).
Written naively it is a tower of closures and per-step record allocations, recursing
O(n) deep — the shape that makes a JavaScript backend slow and stack-bound. The passes
above compose to collapse it entirely. For `countTo n` (count the state from 0 to n):

1. **Dictionary elimination + general inlining** bring `bind`/`pure`/`get`/`put` to
   their use sites.
2. **Newtype transparency** makes `State f ≡ f`, and **multi-scrutinee
   case-of-known-constructor** unwraps the combinators (`case v, f of State(g), f1 ->
   …`), so `g` becomes the concrete state function.
3. **Capture-avoiding substitution** keeps that sound while the independently-named
   `\s` binders nest.
4. **Trivial-record scalarization** removes the per-step `{ state, value }` allocation.
5. **Lambda merging** makes the worker arity-2 (`\n s -> …`), and **commuting
   conversion** surfaces the recursive call from under the applied `case`.
6. **Tail-call elimination** turns the now-tail self-call into a constant-stack loop.

The result is exactly the loop you would hope for, with no allocation and no growing
stack:

```
countTo n s = case s == n of
  true -> n
  _    -> countTo n (s + 1)
```

The collapsed wasm runs in constant stack with no allocation; the e2e
`Test.E2E.StackSafe` runs it for a million iterations as a regression guard (a missing
optimization would overflow, which a value-only test could not detect).

## Worked example: the Effect monad

`Effect` is the opaque counterpart to `State`. Its instances are *mutually recursive*
(`functorEffect` = `liftA1` → apply/pure; `applyEffect` = `ap` → bind), exactly the
"cyclic dictionaries" a dictionary-passing backend pays for per step. Impurification +
the simplifier collapse them all. For a pure counting loop in `Effect`:

```
countTo n = unsafePerformEffect (go 0)
  where go acc = if acc >= n then pure acc else pure (acc + 1) >>= go
```

`pureE`/`bindE`/`unsafePerformEffect` reify to thunks; the `do` collapses; the `\$ev`
thunk floats out of the loop's `case` and merges into the worker; and TCE closes it —
giving the same allocation-free, constant-stack loop as `State`. The cyclic-dict overhead
vanishes: `mapEff`/`applyEff` reduce to plain `intAdd`. A *genuinely* effectful do-block
instead keeps its runs: the e2e `Test.E2E.HostEff` performs two host effects and checks
they ran in order, exactly
once each — and prints a real `console.log "Hello, World!"` through the whole pipeline.

## Known gaps

- **Polymorphic-container boxing.** A polymorphic container (`List a`) stores its
  elements boxed, because field unboxing applies only to *concrete* scalar fields.
  Removing this needs monomorphization, deliberately out of scope (ADR 0013) — and it
  is the fair case anyway (a JavaScript backend stores the number in the cell too).
- **Higher-order effects.** An effect hidden behind an opaque function or data parameter
  is treated conservatively as a barrier (never dropped, but not optimized). Effects
  reached directly or through known bindings are handled precisely.
- **`Effect`-typed entry points.** An `Effect`-typed export is exposed by the loader as a
  callable thunk `() => a` (run when called, ADR 0015) — *auto*-running `main` on import is
  still a possible loader flag. One edge remains: a top-level `Effect a` bound to a bare
  *expression* is a thunk CAF the export wrapper does not perform (ADR 0018); writing it as a
  do-block works. (`Effect.Ref`, `forE`/`whileE`/`untilE`/`foreachE`, `EffectFnN` and
  `unsafePerformEffect` are now provided wasm-natively — ADR 0017 / 0018 — not gaps; `ST`
  shares `Effect.Ref`'s representation and is the remaining follow-up.)
- **`Free` / `Run` interpreter performance.** Programs over the `Free` monad or
  `purescript-run`'s `Run` (extensible effects) **compile and run correctly**, but are currently
  slow on wasm. A `Run`-over-`State` counter (`bench/count-run.mjs`) measures ~1.65–1.70× the time
  of `purs-backend-es` — i.e. ~685× a hand-rolled `State` monad, which by contrast collapses to a
  tail loop and *beats* `purs-backend-es` at ~0.73×. The dominant cost is the `Free`/`VariantF`
  machinery's per-step allocation (boxed variant cells, bind closures), allocation-heavy in a way
  wasm-GC handles less efficiently than V8, which the optimizer does not yet specialize away. A
  smaller, secondary contributor: `purescript-run`'s interpreter loops are *point-free* recursive
  bindings (`loop = resume f pure`); the backend requires a recursive binding to be a syntactic
  function, so it **eta-expands** them to `loop = \x -> resume f pure x` (`Lower.lowerRecBind`,
  sound by the eta law for a binding of positive residual arity) — correct, but it recomputes the
  `resume f pure` closure per call instead of sharing it once. Planned post-v0.1: specialize/inline
  the `Run`/`Free` interpreter to remove the per-step allocation (the dominant cost); recovering the
  eta sharing-loss (a recursive-value knot-tying lowering) is a minor follow-up.
