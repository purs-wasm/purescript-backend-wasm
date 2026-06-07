# 0020. A reduction-aware inliner (inline when it reduces, share when it doesn't)

- Status: Proposed
- Date: 2026-06-05

> **Progress (2026-06-07):** The NbE core (`Semantics`'s `Sem`/`eval`/`quote`) is implemented and is **the default reducer** (`DictElim.useNbE = true`), plus a stack-safe `IR.Eq` (migration step 1). The main goal — **reduction-aware inlining decisions (step 3) — is not yet started** (currently stage 2: NbE merely reproduces the existing inline set `Inline.inlineCandidates`). Kept Proposed.

## Context

Building the purs-backend-optimizer README *overview* examples surfaced the first
real-closure failures of the middle-end. The array/list **fusion** programs
(`Snapshot.Fusion01`/`02`, using a CPS `Fold` newtype) made `optimizeProgram` either
overflow the native stack or spin for minutes building a gigantic term.

Two things were found and one was fixed along the way; the third is what this ADR is about.

### Fixed already, orthogonal: stack-safe convergence equality

The optimizer used the derived `Eq` as its fixed-point convergence check (`Simplify`'s
per-expression `e' == e`, `MiddleEnd`'s whole-program `prog' == prog`), which recurses on
the native stack and overflows on deep terms. Replaced with a stack-safe structural
equality (`MiddleEnd.IR.Eq`, an explicit work-stack). Correct on its own merits and kept
regardless of this ADR.

### The real problem: the optimizer is not contracting — and why

Instrumenting `runOpt` to report the total printed size of the whole program after each
sub-stage (with the round/pass caps lowered so it completes) showed the program growing
~1.5× **per simplify pass without ever converging** — at the real caps (`maxPasses = 1000`)
a single round builds a term on the order of `1.5^k`. It *terminates* (the loops are
clamped; every tree walk is finite-tree recursion — there is no missing-base-case infinite
recursion) but it is **non-contracting**, which is as good as non-terminating in practice.

A first hypothesis — that β-reduction duplicates subterms via `substMany` — was **tested and
falsified**:

- Rewriting β to bind arguments with `let` instead of substituting (so the gated
  let-inliner shares non-linear arguments) **barely moved the sizes** (4.85M → 5.24M at one
  pass) and **regressed 10 e2e tests** (a `let`-ordering/capture bug surfacing as
  `UnknownVariable`, plus a `genericShow` overflow). Reverted.
- Disabling the `smallLambda` multi-use let-inline: still explodes.
- **Disabling the top-level inline rule** (`Simplify`: `Var q → ctx.inline[key]`): the Fusion
  simplify **converges and shrinks** (2.81M → 2.73M, ~14 s) instead of exploding to 11.2M.

So the duplication is the **top-level inliner**. `Inline.inlineCandidates` selects a binding
when

```purescript
exprSize rhs <= generalInlineCap{-24-} || useCount key <= 1
```

i.e. a **small, multi-use** top-level binding is inlined at *every* use site. The inline set
is acyclic (so the fixpoint terminates), but acyclic is not enough: a diamond `f → {g, h} →
k` expands `k` `2^depth` times. CPS fusion is exactly this shape — `mapF`/`filterMapF`/`<<<`/
the `Fold` wrappers are each small and used several times, so inlining them compounds.

### Why a size/use threshold cannot fix it

The same "small multi-use top-level inline" is **load-bearing for the wins we already have**:
the State-monad collapse (`bench/CountState`) works because `bind`/`pure`/`get`/`modify` are
small, multi-use user combinators that get inlined and then **collapse to straight-line
arithmetic**; dictionary methods inline at every site and **saturate to intrinsics**. Those
are net *shrinks*. The fusion combinators are the same size and use-count but inlining them
produces *more* CPS — a net *grow*.

The discriminator is **whether the inline reduces**, not how big the binding is or how often
it is used. A static size/occurrence heuristic is blind to it: restrict to single-use and the
State/dict collapses regress; allow small multi-use and fusion explodes. This is the wall.

## Decision

**Replace the rule-based, bottom-up `simplifyExpr` fixed point with a normalisation-by-
evaluation (NbE) core whose inlining is reduction-aware: a binding is inlined exactly when
inlining leads to reduction (β, projection, known-case, saturation), and a value that does
*not* reduce at a multi-use site is retained as a shared `let` instead of being copied.**

This is the architecture purs-backend-es uses (`BackendSemantics`/`eval`/`quote`). Inlining
stops being a *pre-selected set fed to a rewriter* and becomes a *consequence of evaluation*:
references unfold into the semantic domain, redexes fire in the meta-language, and only the
quote-back step decides — per binding, from its actual residual usage and complexity —
whether to inline or share.

### Shape

- **A semantic domain `Sem`** with values (`SemLam (Sem -> Sem)` — β is a host-language
  application; `SemLit`, `SemCtor name args`, `SemRecord fields`, …) and **neutrals** for
  stuck computations (`NeutVar`, `NeutApp neutral args`, `NeutCase`, `NeutAccessor`, …). A
  neutral is a term whose head is unknown (a parameter, a recursive self-reference, an opaque
  foreign), so it cannot reduce further.
- **`eval :: Env -> Expr -> Sem`** interprets an expression. The reductions the current
  `Simplify` does as rewrite rules become evaluation steps that fire *only when the operands
  are known*:
  - inline: a `Var` bound to a known top-level/let value evaluates to that value;
  - β: `App (SemLam f) args` is `f args` (meta application) — fires only when the head is a
    known lambda;
  - projection: `Accessor l (SemRecord fs)` / instance-field projection → the field;
  - known-case: `Case (SemCtor c as) alts` selects and binds the matching alternative; an
    unknown (neutral) scrutinee stays a `NeutCase`;
  - boolean short-circuit, curried-app flattening, etc. — likewise, on known operands.
  When an operand is neutral, the construct stays neutral (no rewrite, no duplication).
- **`quote :: Sem -> Expr`** reifies a `Sem` back to IR. Quote carries **usage information**
  gathered during evaluation and decides, for each binding it must reintroduce:
  - **inline** if the value reduced / is used at most once / is trivial (a reference,
    literal, projection, or a saturating partial application);
  - **retain as a shared `let`** if it is used more than once and did not reduce (a closure, a
    constructor of new work) — so it is computed/allocated once and referenced, never copied.
  This is the single decision that the size/use heuristic could not make, now made from the
  *residual* program rather than guessed up front.

### Invariants this establishes (and tests must assert)

1. **Contraction.** Normalisation never copies a non-reducing multi-use value; each binding is
   inlined only when it reduces. So `Fusion01` converges to a small fused loop, and the
   whole-program fixed point is reached by *convergence*, not by hitting `maxRounds`/`maxPasses`
   (which revert to a pathological backstop).
2. **Behaviour preservation.** The existing collapses must be unchanged: the State and Effect
   monads still collapse to straight-line/constant-stack code, dictionaries still erase,
   comparison still saturates to intrinsics, and the deep-loop stack-safety guard
   (`Test.E2E.StackSafe`, `count-effect`) still holds. e2e 136 / unit 109 stay green and the
   7 benches + count-state/count-effect do not regress.

### What must be carried over carefully (the risk surface)

The current `Simplify` has accreted behaviour that the NbE core must reproduce, not lose:

- **Effects (ADR 0015 / 0019).** `Perform` of an effectful producer is a **barrier**: it must
  never be dropped, duplicated, or reordered. `eval` must keep an effectful `Perform` neutral
  (consulting `Purity`), while still collapsing a *pure* `Effect` thunk. The impurification of
  `pureE`/`bindE`/`map`/`apply`/effectful foreigns (ADR 0019) interleaves with this and must
  keep working.
- **TCE enablers.** `Abs`-merge (`\n -> \s -> …` → `\n s -> …`), `floatAbsOutOfCase`, and the
  commuting conversion exist so a buried self-call becomes a saturated *tail* call (constant
  stack). NbE naturally produces saturated applications, which should *subsume* these — but the
  quote step must emit the merged/arity-correct form so lambda lifting + TCE still fire.
- **Recursion / termination.** `eval` must **not** unfold a recursive binding into itself
  (that is the infinite loop the user rightly worried about). Recursive self-references stay
  neutral; only non-recursive (or already-specialised) bindings unfold. The acyclicity
  machinery in `Inline`/`DictElim` is replaced by "don't evaluate through a back-edge."
- **Capture.** `quote` introduces fresh names where needed (the capture-avoiding discipline the
  current `substMany` has); evaluating into a host closure sidesteps most capture, but
  quote-time name generation must stay sound.

### Migration plan (incremental, each step e2e-green)

1. Land the stack-safe `IR.Eq` (done) — independent.
2. Introduce `Sem`/`eval`/`quote` behind `simplifyExpr`'s signature, first reproducing the
   *current* rule set (no reduction-aware inlining yet) and proving behaviour-neutrality (e2e
   136, benches unchanged).
3. Move the inline decision into `quote` (usage-driven), retiring the `exprSize ≤ cap ||
   useCount ≤ 1` pre-selection in `Inline`/`DictElim`. Verify Fusion converges *and* the
   State/dict/comparison/Effect collapses are intact.
4. Demote the round/pass caps to a pure backstop (convergence is the normal exit).

## Consequences

- Fusion-style code builds and fuses; the optimizer becomes genuinely contracting, so larger
  real programs (the heavier overview examples, eventually real Prelude-dependent projects)
  stop hitting the explosion.
- It is a **large, central rewrite** of the optimizer's core with a wide blast radius (every
  current `Simplify` behaviour, the Effect machinery, the benches). It is staged so each step
  is verifiable; the risk is regressing a tuned collapse, which the e2e/bench guards catch.
- The traversal stack-safety question (making `descend`/`FreeVars`/`substMany` iterative) is
  **deferred and likely moot**: once the term stops exploding, the genuine expression depth is
  modest and native-stack recursion over it is fine. If a legitimately deep program later
  overflows, that becomes its own task.
- `Inline.purs`/`DictElim`'s candidate *selection* shrinks to "what may unfold" (non-recursive,
  not a bare constructor); the *inline-or-share* decision leaves them entirely and moves to
  quote.

## Alternatives considered

- **A total-size budget backstop.** Cap multi-use inlining once the program exceeds N× its
  input. Small change; Fusion would *build* (no explosion) but possibly un-fused (slower), and
  it is a crude knob, not a fix — it does not make the right inline/share decision, it just
  stops the wrong one from running away. Viable as an interim safety net if the NbE work needs
  staging, but not the destination. (Not chosen.)
- **A shape heuristic** — inline multi-use only for "non-growing" shapes (references,
  projections, partial applications), single-use otherwise. Matches some cases but still
  guesses reducibility from syntax; risks regressing the State/comparison collapses that rely
  on inlining genuine lambdas that then reduce. (Not chosen.)
- **β binds with `let`** (the previous draft of this ADR). Necessary-looking but neither
  sufficient (β is not the dominant duplicator) nor free (regressed 10 e2e). Reverted.
- **Keep the rule engine, add a "trial inline if it shrinks" check.** A local cost check that
  inlines a multi-use binding only when the inlined-then-simplified result is not larger. This
  is reduction-awareness bolted onto the bottom-up engine; it approximates NbE but
  re-simplifies speculatively per site (expensive and fiddly). NbE is the cleaner expression of
  the same idea.
