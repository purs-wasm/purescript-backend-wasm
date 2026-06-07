# 0024. Export-boundary arity reconciliation, and the transparent-types-only rule

- Status: ~~Proposed~~ **Accepted** _(2026-06-07: promoted — implemented (`addExportWrapper` + `emitLoader`).)_
- Date: 2026-06-06

## Context

Compiling `examples/metatheory` to a callable wasm surfaced two failures at the **export
boundary** — where a PureScript top-level binding is exposed to a host (the JS loader, ADR
0014, or a standalone wasm consumer). Both come from a single underlying fact:

> A binding's **compiled arity** (`C` = the number of wasm parameters the lowered function
> actually takes = its leading `Abs` count) can differ from its **source-type arity**
> (`T` = the number of `->` in its declared type, recovered from externs).

`C` and `T` diverge in two opposite directions, and the export boundary must reconcile them:

| relation | example | why |
| - | - | - |
| `C = T` | `f x y = …` | fully η-expanded — the common case |
| **`C < T`** | `inc = add 1` (`Int -> Int`) | **point-free / partial application**: the body is a value (a closure); the remaining `T-C` args are consumed by *applying* that closure |
| **`C > T`** | `foo :: SafeAPI` where `newtype SafeAPI = SafeAPI (Int -> Int)` | a **function newtype** (opaque at the surface, a function at runtime after newtype erasure). The transformer/monad values of ADR 0015 are the same shape (`TypingM a` is ultimately a function newtype), so `freshMeta :: TypingM _` → `C=1, T=0` |

Observed before the fix:

- **`C > T`**: `freshMeta :: TypingM _` (T=0, C=1). The loader eagerly calls every nullary
  export to expose CAFs as values; calling a 1-ary function with 0 args read the missing
  argument and trapped — `illegal cast` at module instantiation.
- **`C < T`**: `inc = add 1` (T=1, C=0) compiled to a nullary function returning a closure.
  Internal call sites already worked (over-application), but the export wrapper read the
  returned *closure* as the i32 result → `illegal cast` / `unreachable`.

## Decision

Reconcile `C` and `T` at the boundary, leaning on the uniform arity-1 closure calling
convention (ADR 0004) so the rules are general, not shape-specific. And make explicit the
limit of what can be exported at all.

### 1. Export wrapper handles `C ≤ T` generally (the `C < T` fix)

`Codegen.addExportWrapper` accepts the externs marshal sig when its arity is **`≥` the
compiled arity** (was `==`). It then:

1. calls the compiled function with the **leading `C`** external params (each coerced to the
   compiled param rep), then
2. applies the **remaining `T-C`** external params to the returned value one at a time via the
   runtime closure trampoline (`$callClo1`), then
3. coerces the final result to the external result rep.

This is **principled, not a patch**: by type soundness, a binding of type `a₁→…→a_T→r`
compiled to `C < T` params returns, after `C` applications, a value of type
`a_{C+1}→…→a_T→r` — necessarily a closure (`eqref`). Applying the rest via `$callClo1` is
exactly the over-application the rest of the program performs internally. It is general over
`C` (incl. 0), `T`, and every JS-safe argument/result kind. It **requires externs** (you
cannot know `T` without the type) — fundamental, and always available in the bin build.

### 2. Loader guards the eager CAF-call by real arity (the `C > T` fix)

The generated loader (`bin/src/Main.purs` `emitLoader`) eagerly evaluates a nullary export
to present a CAF as a *value* (not a thunk). It now does so **only when the real wasm arity is
also 0** (`sig.params.length === 0 && e.length === 0`). When the source type is nullary (`T=0`)
but the binding compiled to a function (`C > 0` — a function newtype / collapsed monad), it
exposes the raw wasm export instead of evaluating it at load, so there is no trap.

### 3. Transparent-types-only: opaque newtypes are not safely exportable

The export marshaller (ADR 0014) maps each **type leaf** to an ABI: `Int`/`Char` → `i32`,
`Number` → `f64`, `Boolean`/`String`/`Array`/`Record`/function → `eqref` with a known kind.
An **opaque type constructor** (a `newtype`/`data` whose definition the marshaller does not
unfold — including a *function* newtype) marshals as the catch-all opaque kind `"o"`, which
carries **no information about what it wraps**.

Therefore a binding whose **surface type is opaque cannot be marshalled correctly**, and the
`C > T` path is *inherently* not JS-safely exportable. The system is **fail-safe** here, never
silently corrupting:

- it does not crash at load (rule 2), and
- the `i32` fallback either *coincidentally* matches (e.g. `SafeAPI = (Int -> Int)` →
  `foo(5)` returns `6`) or *cleanly traps* (`StrAPI = (String -> Int)` → `strApi("ok")` →
  `illegal cast`, because the `String` arg is marshalled as `i32`).

The supported way to export such a value is the **bridge**: surface a *transparent* JS-safe
type through a runner, e.g.

```purescript
foo   :: SafeAPI            -- not exported directly (opaque)
fooJS :: Int -> Int         -- exported: transparent, JS-safe
fooJS = runSafe foo
```

`fooJS` has `T = 1` with JS-safe leaves and `C ≤ T`, so rule 1 marshals it correctly on both
the JS-runtime and standalone paths (`fooJS(5) = 6`; an analogous `strJS("ok") = 100`). This is
exactly the discipline the PureScript JS backend encourages: export only JS-safe values —
`Int`/`Number`/`Boolean`/`String`, functions over them, and (for `Aff`) a `Promise` — and the
wasm backend rewards it identically.

## Consequences

- Point-free top-levels export as proper n-ary functions; the `illegal cast` at metatheory
  instantiation is gone. `examples/metatheory`'s `Typecheck` compiles, validates, and
  instantiates; `typecheck`/`typing` are callable, `emptyEnv` reads as a value.
- The boundary is **fail-safe**: no `(T, C)` combination silently corrupts. `C ≤ T` is fully
  correct; `C > T` over an opaque type is coincidentally-correct (`i32`) or a clean trap,
  steering authors to the bridge.
- Regression coverage: e2e `Test.E2E.PointFree` (+ `Example.PointFree` fixture). Unit 110 /
  e2e 139, benches unaffected.
- A genuine value-vs-function parity between standalone and JS-runtime for true CAFs (so a
  standalone consumer sees a value without calling) still wants CAF-as-exported-global
  (ADR 0006) — deferred; the loader-side value exposure is accepted for now.

## Alternatives considered

- **Unfold newtypes in the marshaller** so a function newtype's wrapped type is visible
  (`SafeAPI` → `Int -> Int`). Possible in principle, but it would peel *all* exported
  newtypes, leaking representation choices across the boundary and entangling marshalling with
  newtype resolution and instance coherence. The bridge keeps the author in control of exactly
  what crosses, which matches the JS-backend convention; rejected.

- **Eta-expand every point-free top-level to its type arity during lowering/optimization** (so
  `C = T` always). Uniform, but needs type arity for *all* top-levels (not just exports),
  touches far more code, and pessimizes internal uses that the over-application path already
  handles for free. The boundary-local fix (rule 1) is sufficient and cheaper.

- **Keep eager-calling every nullary export** (pre-fix). Crashes on any `C > T` value
  (function newtype / collapsed monad) — turns a fail-safe into a hard load-time failure.
