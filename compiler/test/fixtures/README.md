# CoreFn decoder fixtures

`Sample.corefn.json` is real output from `purs 0.15.16`, used by the unit test
to guard the decoder against the actual compiler schema.

It was generated from `Sample.purs.sample` (a construct-rich module covering
every CoreFn node kind: literals, data/newtype/class declarations, records,
accessors/updates, lambdas, application, `let`/recursion, and `case` with
guards and every binder shape). The `.sample` extension keeps it out of the
`test/**/*.purs` build glob.

To regenerate after a compiler upgrade:

```sh
cp compiler/test/fixtures/Sample.purs.sample compiler/src/Sample.purs
cp compiler/test/fixtures/Sample.js.sample   compiler/src/Sample.js
spago build -p compiler
cp output/Sample/corefn.json compiler/test/fixtures/Sample.corefn.json
rm compiler/src/Sample.purs compiler/src/Sample.js output/Sample -r
```
