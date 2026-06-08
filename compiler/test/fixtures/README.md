# Fixtures

Real `purs 0.15.16` output, checked in so the decoder and backend test against
the actual compiler schema rather than a hand-written approximation. Every
`*.corefn.json` has its generating PureScript next to it as `*.purs.sample`
(plus `*.js.sample` when the module has foreign imports). The `.sample`
extension keeps these sources out of the `test/**/*.purs` build glob — they are
documentation/regeneration inputs, not compiled with the suite.

| corefn fixture        | source                | used by                       | exercises                                                            |
| --------------------- | --------------------- | ----------------------------- | -------------------------------------------------------------------- |
| `Sample.corefn.json`  | `Sample.purs.sample`  | `Test.Unit.PureScript.CoreFn` | every CoreFn node kind (decoder schema guard)                        |
| `Slice0.corefn.json`  | `Slice0.purs.sample`  | `Test.E2E.Slice0`             | scalar `Int`: top-level fns, saturated calls, foreign i32 intrinsics |
| `Slice1.corefn.json`  | `Slice1.purs.sample`  | `Test.E2E.Slice1`             | ADTs: construction + single-scrutinee pattern matching               |
| `Slice2.corefn.json`  | `Slice2.purs.sample`  | `Test.E2E.Slice2`             | closures: free-variable capture + exact higher-order application     |
| `Slice2b.corefn.json` | `Slice2b.purs.sample` | `Test.E2E.Slice2b`            | partial application; top-level mutual recursion; self-recursive `let` |
| `Slice3.corefn.json`  | `Slice3.purs.sample`  | `Test.E2E.Slice3`             | type-class dictionaries: instance CAFs, method dispatch via label search |
| `Slice3b.corefn.json` | `Slice3b.purs.sample` | `Test.E2E.Slice3`             | superclass dictionaries: thunked `<Class><n>` fields, one/two-level access |
| `Slice4a.corefn.json` | `Slice4a.purs.sample` | `Test.E2E.Slice4a`            | scalar literals (`Char`/`Number`/`Boolean`) + literal-pattern matching (`if`, `case n of 0 ->`) |
| `Slice4b.corefn.json` | `Slice4b.purs.sample` | `Test.E2E.Slice4b`            | strings: UTF-8 literals, concat / byte-length / equality runtime helpers, string literal patterns |
| `Slice4c.corefn.json` | `Slice4c.purs.sample` | `Test.E2E.Slice4c`            | arrays: `$Vals` literals, `length`/`index` intrinsics, nested arrays |
| `Records.corefn.json` | `Records.purs.sample` | `Test.E2E.Records`            | general records: construction, access, update (`r { x = … }`), `{ x } ->` patterns |
| `LinkA.corefn.json`   | `LinkA.purs.sample`   | `Test.E2E.Link`               | multi-module linking: `LinkA` imports `LinkB` (compiled together) |
| `LinkB.corefn.json`   | `LinkB.purs.sample`   | `Test.E2E.Link`               | the imported module: a function + an ADT used across the boundary |
| `Arith.corefn.json`   | `Arith.purs.sample`   | `Test.E2E.PreludeArith`       | real Prelude `+`/`*`/`-` on `Int` (Semiring/Ring dictionaries) |
| `Data.Semiring.corefn.json` | (real Prelude) | `Test.E2E.PreludeArith`       | linked for `semiringInt` / `add` / `mul` / `intAdd` / `intMul` |
| `Data.Ring.corefn.json`     | (real Prelude) | `Test.E2E.PreludeArith`       | linked for `ringInt` / `sub` / `intSub` |

| `Cmp.corefn.json`     | `Cmp.purs.sample`     | `Test.E2E.PreludeCompare`     | real Prelude `==` / `<` / `compare` on `Int` (Eq/Ord dictionaries) |
| `Data.Eq.corefn.json`       | (real Prelude) | `Test.E2E.PreludeCompare`     | linked for `eqInt` / `eqIntImpl` |
| `Data.Ord.corefn.json`      | (real Prelude) | `Test.E2E.PreludeCompare`     | linked for `ordInt` / `compare` / `lessThan` / `ordIntImpl` |
| `Data.Ordering.corefn.json` | (real Prelude) | `Test.E2E.PreludeCompare`     | the `Ordering` ADT (`LT`/`EQ`/`GT`) |
| `Bool.corefn.json`    | `Bool.purs.sample`    | `Test.E2E.PreludeBool`        | real Prelude `&&` / `\|\|` / `not` (HeytingAlgebra) |
| `Data.HeytingAlgebra.corefn.json` | (real Prelude) | `Test.E2E.PreludeBool`   | linked for `heytingAlgebraBoolean` / `conj` / `disj` / `not` / `boolConj` … |
| `Num.corefn.json`     | `Num.purs.sample`     | `Test.E2E.PreludeNumber`      | real Prelude `Number` `+`/`*`/`-`/`/` + `Int.toNumber` |
| `Data.CommutativeRing.corefn.json` | (real Prelude) | `Test.E2E.PreludeNumber` | `EuclideanRing`'s superclass (for `numDiv`) |
| `Data.EuclideanRing.corefn.json`   | (real Prelude) | `Test.E2E.PreludeNumber` | `euclideanRingNumber` / `div` / `numDiv` |
| `Data.Int.corefn.json`             | (real Prelude) | `Test.E2E.PreludeNumber` | `toNumber` (Int → Number) |

| `Guards.corefn.json`  | `Guards.purs.sample`  | `Test.E2E.PreludeGuards`      | **case guards**: multiple guards in one alternative + fallthrough to a later alternative; guarded constructor patterns (linked with `Data.Eq` / `Data.Ord` / `Data.Ordering` for `>`) |
| `AsPattern.corefn.json` | `AsPattern.purs.sample` | `Test.E2E.AsPattern`        | **as-patterns** (`name@pat`, regression for #4): a head as-pattern over a 3-deep cons (binds the whole value), an as-pattern on a constructor sub-binder, and a named scalar — all were silently dropped before the `Lower.Match` peel fix. Links `Data.{Eq,Ring,Semiring}` |
| `NestedRecordPat.corefn.json` | `NestedRecordPat.purs.sample` | `Test.E2E.NestedRecordPat` | **nested record field patterns** (`{ x: Just y }`): a record-pattern field whose sub-binder is a constructor, a literal, an inner record, or a constructor wrapping a record. These were rejected by the single-record fast path (`UnsupportedBinder`) until it was narrowed to trivial (var/wildcard) fields, routing the rest to `Lower.Match`. Links `Data.Maybe` / `Data.{Eq,Ring,Semiring}` |
| `GenSC.corefn.json`   | `GenSC.purs.sample`   | `Test.E2E.PreludeGenericShowCompare` | **`genericCompare` + `genericShow`**: folds the `Generic` rep to `Ordering` / a rendered `String` (`reflectSymbol` is already a value-level string in the synthesised `IsSymbol` dict; `intercalate` → `$rt.intercalate`). Links `Data.{Ord,Show}.Generic` / `Data.Symbol` / `Type.Proxy` / `Data.{Show,Ring,Semiring,Semigroup}` on top of the genericEq set |
| `Data.Ord.Generic.corefn.json`   | (real Prelude) | `Test.E2E.PreludeGenericShowCompare` | `genericCompare` over the rep |
| `Data.Show.Generic.corefn.json`  | (real Prelude) | `Test.E2E.PreludeGenericShowCompare` | `genericShow` + the `intercalate` foreign |
| `Data.Symbol.corefn.json`        | (real Prelude) | `Test.E2E.PreludeGenericShowCompare` | the `reflectSymbol` class-method accessor |
| `Type.Proxy.corefn.json`         | (real Prelude) | `Test.E2E.PreludeGenericShowCompare` | the `Proxy` value passed to `reflectSymbol` |
| `Expr.corefn.json`    | `Expr.purs.sample`    | `Test.E2E.ExprEval`           | **integration** (mirrors `example/src/Main.purs`): an arithmetic-expression evaluator + pretty-printer — ADTs, nested decision-tree matching, a case guard, recursion, `show` / `<>` / `negate` / `+` / `*` / `>`. Links `Data.{Boolean,Eq,Ord,Ordering,Ring,Semigroup,Semiring,Show}` |
| `Erased.corefn.json`  | `Erased.purs.sample`  | `Test.E2E.PreludeErased`      | **erased foreigns**: `Data.Unit.unit` (a nullary boxed constant) and `unsafeCoerce` (erased during lowering — `unsafeCoerce x` *is* `x`). Links `Data.Function` (`const`) / `Data.Semiring` (`add`) |
| `Rec.corefn.json`     | `Rec.purs.sample`     | `Test.E2E.RecordUnsafe`       | **`Record.Unsafe`**: `unsafeGet` / `unsafeSet` (replace + insert) / `unsafeHas` / `unsafeDelete` — the runtime `String` key resolved via the emitted `internStr`, then the id-keyed `$rt.rec*` helpers. Foreigns are intrinsics, so only `Rec` is linked |
| `RecInst.corefn.json` | `RecInst.purs.sample` | `Test.E2E.RecordInstances`    | **record instances**: real `Eq (Record r)` / `Show (Record r)` (`reflectSymbol` label + `unsafeGet` value over the row). Links `Data.{Eq,Show,Symbol,Semigroup,HeytingAlgebra}` / `Type.Proxy` |
| `TailRec.corefn.json` | `TailRec.purs.sample` | `Test.E2E.TailCall`           | **tail-call elimination**: direct top-level tail recursion (`return_call`) and `where go = …` closure self-recursion (lambda-lifted to top level). Deep loops (1_000_000) run in constant stack. Links `Data.{Eq,Ring,Semiring}` |
| `IntConv.corefn.json` | `IntConv.purs.sample` | `Test.E2E.IntConv`            | **`Data.Int.fromNumberImpl` intrinsic**: the private foreign behind `fromNumber`/`floor`/… — applies the `Just` closure to the truncated Int when the Number is integral & in range, else `Nothing`. `roundtrip k = fromMaybe (-1) (fromNumber (toNumber k))` recovers `k`. Links `Data.Int`/`Data.Maybe`/`Data.Ring`/`Data.Semiring`/`Control.Category`/`Control.Semigroupoid` |
| `HostEff.corefn.json` | `HostEff.purs.sample` (+`.js`, +`.externs.cbor`) | `Test.E2E.HostEff` | **Host effectful FFI** (ADR 0015): real `foreign import record :: Int -> Effect Unit` / `log :: String -> Effect Unit` (JS `n => () => …`). Verifies externs `Effect`-result → `MEffect`, purity keeps the runs, `Perform` lowers to a host call, and the glue runs the thunk on the JS side. `runRec` ⇒ spy `[1,2]`; `greet` ⇒ a real `console.log "Hello, World!"`. Also guards **ADR 0006**: an exported top-level `Effect Unit` (`mainEff`/`deadEff`) is never performed at load (the spy is empty right after instantiation, so CAF globalization does not eager-run effects) and `mainEff` runs only when called ⇒ spy `[7]`. Links the Effect/prelude set; needs externs (`instantiateForeignStr`) |
| `Counter.corefn.json` | `Counter.purs.sample` (+`.js`) | `Test.E2E.Counter`       | **Effect purity** (ADR 0015): two effectful primitives (`incrCtr`/`readCtr`, resolved to the `IncrCtr`/`ReadCtr` intrinsics over a mutable wasm global) make effect order/count observable. `countThree` (three result-unused `incrCtr`) must read 3/6/9 — a purity-blind optimizer would drop them; `order` interleaves reads ⇒ 12. The `.js` stub is only so `purs` accepts the foreigns. Links the same Effect/prelude set as `Eff` |
| `Eff.corefn.json`     | `Eff.purs.sample`     | `Test.E2E.Eff`                | **Effect impurification** (ADR 0015): pure `Effect` computations run via `unsafePerformEffect` must collapse + run — `do`/bind (`runEff`), `Functor` (`mapEff`), `Apply`/`Applicative` (`applyEff`), `Bind` (`bindEff`), and a deep recursive loop (`countEff`, must be constant-stack). Exercises Effect's mutually-recursive instance dicts. Links `Effect{,.Unsafe}` / `Control.{Applicative,Apply,Bind,Monad}` / `Data.{Functor,Semiring,Unit,Function,Ord,Ordering,Eq,Ring}` |
| `FibAnd.corefn.json`  | `FibAnd.purs.sample`  | `Test.E2E.FibAnd`             | **cyclic top-level CAF** (ADR 0006): a self-referential arity-0 value (`data Fib = Fib String (Int -> Int)`, `fibAnd` referencing itself) — globalization must **exclude** it (value-level cycle, stays a getter), and `fib` still computes Fibonacci through it (`fib 10 = 55`). Links `Data.{Boolean,Eq,Ord,Ordering,Ring,Semiring}` |
| `EffP.corefn.json`    | `EffP.purs.sample`    | `Test.E2E.EffectPrim`         | **Effect regression guard in the fast lane** (post-mortem 2026-06-07): native `Effect.Ref` (`new`/`modify`/`read`) + `Effect.forE` + `void`-over-Effect, linked with the real `Effect`/`Effect.Ref` closure. `voidTest` is the dedicated guard for the discarded-effect-drop bug (`Purity.runImpure` redex-arg rule). Links the full Effect/Prelude closure incl `Effect.Ref` / `Record.Unsafe` / `Data.{Void,BooleanAlgebra,NaturalTransformation}` / `Prelude` (the 6 corefn added with it; real `purs` output) |

`Data.Semiring` / `Data.Ring` / `Data.Eq` / `Data.Ord` / `Data.Ordering` are
**real `purs`-compiled Prelude output** (copied verbatim from a build's
`output/<Module>/corefn.json`); regenerate them from the package set's `prelude`
if it is bumped.

## Regenerating

Each fixture is built by temporarily dropping its source into `compiler/src`,
compiling to CoreFn, copying the result back, and cleaning up. For `Slice1`
(no foreign module) omit the `.js` lines.

```sh
# Example: Slice0 (has an FFI module)
cp compiler/test/fixtures/Slice0.purs.sample compiler/src/Slice0.purs
cp compiler/test/fixtures/Slice0.js.sample   compiler/src/Slice0.js
spago build -p compiler
cp output/Slice0/corefn.json compiler/test/fixtures/Slice0.corefn.json
rm compiler/src/Slice0.purs compiler/src/Slice0.js
rm -rf output/Slice0
```

The same recipe regenerates `Sample` and `Slice1` (swap the names; for `Slice1`
drop the two `.js` lines).
