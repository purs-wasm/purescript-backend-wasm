# 0015. Effect reflection: collapsing function-represented monads to straight-line code

- Status: Proposed
- Date: 2026-06-04

## Context

`Effect` is PureScript's `IO`. In a strict language it is, operationally, a **nullary
thunk** — a deferred computation you run by calling it:

```purescript
Effect a  ≃  Unit -> a
```

This is exactly how `purs-backend-es` and the stock JS backend represent it: `pure a`
is `\_ -> a`, `bind m k` is `\_ -> k (m unit) unit`, and a `do` block is a tower of
such thunks. Compiled naively, every `pure` / `bind` / `discard` allocates a closure
and the `do` block applies them one after another — closure- and allocation-heavy.

`Effect` is not unique in this. A whole family of monads is a **`newtype` wrapping a
function** — the computation *is* a function you run by applying it:

```purescript
newtype State s a  = State  (s -> { state :: s, value :: a })
newtype Reader r a = Reader (r -> a)
-- RWSE, etc.: r -> s -> Either e { value :: a, state :: s, log :: w }
```

The `CountState` benchmark (a `State` monad) makes the shared cost concrete. With the
general known-function inlining of the optimization layer (ADR 0005) in place, the
per-step plumbing of the *non-recursive* combinators already collapses — but the
**recursive worker** that drives the loop does not: it stays ~68× slower than
`purs-backend-es` and overflows the stack past a few thousand iterations, because each
step still allocates a result record and a continuation closure and the bind chain
recurses O(n) deep rather than running as a loop. Inlining cannot help there: a
recursive function cannot be inlined into itself.

`purs-backend-es` closes this gap by *eliminating the monad* — fusing the thunk tower
into a tight loop with no per-step allocation. We want the same, as a **general**
transformation over function-represented monads (with `Effect` as the headline case),
not a hand-written special case per type.

This ADR proposes **effect reflection**. It builds on the optimization IR (ADR 0005),
reuses the runtime closure machinery (ADR 0010), and reuses the FFI marshalling
boundary (ADR 0014) for foreign effects.

## Decision

### The domain: monads whose representation is a function

Effect reflection applies to a monad `newtype M a = M (repr a)` whose **`repr a` is a
function type** `X -> Y`. "Running" such an effect is *applying* that function; building
one is *wrapping* a function. That is the whole basis of the collapse below, so the
criterion is precise — *the representation must be a function*:

| Monad | `repr a` | In scope? |
| - | - | - |
| `State s` | `s -> { state, value }` | yes — perform = apply to a state |
| `Reader r` | `r -> a` | yes — perform = apply to an environment |
| `RWSE` | `r -> s -> Either e {…}` | yes — perform = apply the (multi-arg) function |
| `Effect` | *opaque* → `Unit -> a` (see *impurification*) | yes |
| `Writer w` | `Tuple a w` — a **product**, not a function | no — collapsed by newtype transparency + tuple accessors, not by reflection |
| `Cont r` | `(a -> r) -> r` — a function, but CPS | unverified — perform applies a *continuation*, and `bind`/`callCC` interaction needs checking |

### Two ingredients, and what each does

The collapse has two parts, and it is worth separating them because the first already
exists:

1. **Make the representation transparent.** For a user `newtype` this is the newtype
   transparency already implemented in the simplifier (a transparent constructor *is*
   its payload, so `State f ≡ f` and `runState (State f) s ≡ f s`). Combined with
   inlining + beta, this collapses the **non-recursive** part of a `do` block on its own
   — the wrapper vanishes and the combinators fuse.

2. **Account for reify / perform, and fuse the recursive worker.** This is the new
   content of the ADR — the part transparency and inlining cannot reach.

### Reify / perform as an inverse pair

Add two constructors to the MIR, denoting the two halves of the function encoding (for
`Effect`, `repr` is nullary, so they specialise to the thunk form):

```
Reify   :: Expr -> Expr   -- "wrap a function as the monad"  ≈  M (\args -> e)
Perform :: Expr -> Expr   -- "run this effect now"           ≈  (unwrap m) args
```

They are introduced during translation, cancelled where possible by the laws below, and
*lowered back* to ordinary closures/applications for whatever does not cancel.

### Translation from CoreFn

`Effect`'s monadic operations translate to these constructors (with `μ = transl m`):

- `pure a`  →  `Reify a` — wrap a function that yields the already-evaluated `a`.
- `bind m (\x -> n)`  →  `Reify (Let x (Perform μ_m) (Perform μ_n))` — run `m`, bind, run `n`.
- `m >> n` (the `discard` of `do { m; n }`)  →  `Reify (Let _ (Perform μ_m) (Perform μ_n))`.

So a `do` block

```purescript
do
  a <- m1
  m2
```

becomes

```
Reify (Let a (Perform μ1) (Perform μ2))
```

— the IR for `\args -> { const a = run(μ1, args); return run(μ2, args); }` (for `Effect`,
`args = unit`; for `State`, `args` is the threaded state).

### The reduction laws — where the collapse happens

```
β:  Perform (Reify e)  →  e
η:  Reify  (Perform μ)  →  μ        (when μ is itself an effect)
```

**β is the engine.** In the `do` translation, `μ1` (= `transl m1`) is itself a `Reify
(…)`, so `Perform μ1 = Perform (Reify body1) → body1`. Applied repeatedly, β **cascades
through the whole `do` block**, flattening it into a single body with the statements
`let`-sequenced inline and *zero intermediate thunks or continuation closures*. That
flattened body is the prize.

**η** strips a redundant reify-of-perform (the valid η for the encoding, `\args -> run μ
args ≡ μ`); it cleans up wrappers such as those left by `m >>= pure`. β is the workhorse,
η a secondary simplification.

### Cracking the recursive worker

β cannot fire on `Perform (go a)` when `go` is a recursive worker: `go` is opaque to the
simplifier (it is not inlined), so `go a` does not *syntactically* reduce to a `Reify`,
even though its body is one. This is the residual that defeats plain transparency +
inlining, and it is where the per-step allocation and the O(n) stack live.

The fix is a **worker / wrapper split**. Given a recursive `go : A -> M B` whose body is
`Reify bodyₐ`, introduce a worker that takes the representation's arguments directly:

```
go#  a args  =  bodyₐ            -- with the Perform/Reify cancelled (β), args threaded
go   a       =  Reify (\args -> go# a args)
```

Now `Perform (go a) ≡ go# a`, and a *tail* `Perform (go a')` inside `bodyₐ` becomes a
direct tail call `go# a' args` — a loop in `(A, args)`. The intermediate `M`-values are
gone, and the loop is tail-recursive (see TCO below). This worker/wrapper of a performed
recursive definition is the mechanism that finally turns a monadic loop into the same
allocation-free loop `purs-backend-es` produces.

### Impurification: bringing opaque `Effect` into the framework

`Effect` is a *primitive, opaque* type — there is no user `newtype` for the simplifier to
see through, so ingredient (1) above does not apply directly. **Impurification** is the
bridge: rewrite `Effect a` to its function representation `Unit -> a` — recognising its
operations (`pure`/`bind`/`discard`, and foreign effects) and emitting the `Reify` /
`Perform` form above. This is sound by construction: a strict-language `Effect` *is* a
nullary thunk, which is precisely how the JS backends implement it. After impurification,
`Effect` is "just another function-represented monad" and the identical reflection
applies — so opaque `Effect` and transparent `State` converge on one optimization.

### The one invariant that makes it correct: `Perform` is impure

The translation reuses the pure `Let` to sequence performs (`Let x (Perform μ1) (Perform
μ2)`). For this to be sound, **the optimizer's effect analysis must know `Perform` is
side-effecting** and therefore must never:

- **eliminate** it when its result is unused (running the effect *is* the point);
- **duplicate** it — if `x` is used twice in the body, the single-use/inline rules must
  not substitute the `Perform` into both uses (that would run the effect twice);
- **reorder** it across another `Perform` (effects are ordered).

Reusing `Let` is the right call; the only thing it needs is a **purity tag** on the RHS.
With that, lambda lifting and codegen need no special handling — once reflection turns
`Reify` into a lambda and `Perform` into an application, the result is ordinary code the
existing passes already handle.

A natural worry is that a `Perform` whose result is unused might be deleted by Binaryen's
DCE. It largely self-resolves: every observable effect bottoms out in a **foreign/import
call**, which Binaryen does not remove unless told the import is side-effect-free (so: do
not annotate effectful imports as pure). A `Perform (Reify x)` with a *pure* `x` whose
result is unused *is* correctly removable — `pure x` has no effect. The MIR-level purity
tag (for our own Simplify) plus not-marking-imports-pure is sufficient; a regression test
that a result-discarded effect survives is cheap insurance.

### Interaction with tail-call elimination

A tail-recursive effect loop must still run in constant stack. After the worker/wrapper
split, the recursive call is a tail `Perform (go a')` → tail call `go# a' args`, which
rides the existing TCE (constant stack). This is the intended outcome and must be
asserted by test, since the whole point of cracking `CountState`-style loops is that they
stop overflowing the stack.

### FFI: foreign effects without host-closure marshalling

A foreign `Effect`-returning import is the common, important case, and it needs neither
the deferred JS→wasm closure direction of ADR 0014:

- **Fully applied** (`log "x" :: Effect Unit`): the JS side returns a thunk `() => …`.
  Rather than hand it to wasm, the marshalling glue **performs it on the JS side** and
  marshals only the result. The `MarshalKind` of `Effect a` is "call the foreign, run the
  returned thunk, marshal its result as `a`"; the thunk never crosses the boundary. In
  MIR this is `Perform (foreignCall …)`.
- **Partially applied as a value** (`ffi 42 :: String -> Effect Unit`, passed around
  rather than immediately performed): eta-expand to a closure `\s -> <the effect of (ffi
  42 s)>`. Rare. (And a bare `a -> Effect b` is, at the type level, just a function whose
  result is performed — the same way `a -> (b -> c)` collapses to uncurried `a -> b -> c`,
  observed in ADR 0014; there is no first-class "returns an effect" shape to special-case.)
- **`EffectFnN` / `Function.Uncurried`**: `EffectFn2 a b c` is `(a, b) => c` (effect on
  the uncurried call), *not* the curried-thunk shape of `a -> b -> Effect c`. Treat
  `runEffectFnN` / `mkEffectFnN` as recognized intrinsics that bridge the two. Deferrable.

### Recognizing the monad's operations

The fiddliest implementation point is **where** to hook the rewrite. For `Effect`, the
operations arrive as `Control.Bind.bind(monadEffect)`, `Control.Applicative.pure(
applicativeEffect)`, `Control.Bind.discard(discardUnit, monadEffect)`. Reflection (and
impurification) must recognize these against the relevant instance **before** dictionary
elimination (ADR 0005) dissolves them into anonymous intrinsics — or recognize the
dissolved forms. The `discard` case matters: `do { m; n }` (no binder) desugars through
`Control.Bind.discard`, not `bind`. This recognition step should be specified explicitly
when implementing.

## Consequences

- **Unblocks `Effect`** — the gateway to real IO (`Console`, `Ref`, `ST`, the effectful
  package long tail) — with straight-line code, not a thunk tower; and it is the *same*
  mechanism that finally beats `purs-backend-es` on `State`-shaped loops.
- **A new correctness obligation**: the optimizer must carry a purity tag for `Perform`
  (no eliminate / duplicate / reorder). A small, local addition to the Simplify analysis,
  but load-bearing — most of the testing effort is here, plus the TCO-of-effect-loops and
  discarded-effect-survival assertions.
- **Foreign effects are cheap and decoupled** — glue-performs-the-thunk means
  fully-applied effectful foreigns work without ADR 0014's deferred JS→wasm closures.
- **Best-effort, never wrong** — anything reflection cannot collapse degrades to an
  ordinary `$Clo` thunk, so partial support is always sound.
- **One technique, several monads** — the function-representation criterion makes the
  scope explicit (State / Reader / RWSE / `Effect`-via-impurification in; `Writer`'s
  product representation handled by transparency instead; `Cont` to be verified).

## Alternatives considered

- **A pure runtime-library `Effect` (thunks, no reflection).** The naive encoding we
  would otherwise ship: correct but slow — the `CountState` benchmark shows ~68× behind
  `purs-backend-es` on the equivalent `State` shape, with stack overflow on deep loops.
- **Per-monad special cases (a bespoke `State` pass, a bespoke `Effect` pass).** Rejected:
  does not generalize; the function-representation framing subsumes their common structure
  in one mechanism, and impurification folds opaque `Effect` into it.
- **Lean entirely on general inlining / newtype transparency.** Necessary and done first,
  but insufficient: they collapse the non-recursive plumbing yet cannot touch a recursive
  worker — exactly the residual the worker/wrapper split targets.
- **Full monad-law rewriting / supercompilation.** More general than reflection, but far
  more complex and harder to keep terminating and predictable. Reflection is the tractable
  subset that captures the win we need.
