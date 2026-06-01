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
