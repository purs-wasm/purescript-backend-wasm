# Module Resolution and `ulib`

It is worth understanding how purs-wasm decides which PureScript module files to build.

At a high level: starting from the entry modules you pass with `-e`, purs-wasm walks the
import graph to find the set of reachable modules, and for each one it picks the artifact to
use. A module covered by **ulib** is sourced from the precompiled library (its
wasm-optimized CoreFn and foreign); otherwise it is taken from your project's `purs` output.
For a foreign import that has no in-wasm (`foreign.wat`) provider, the build falls back to
that module's `foreign.js` through the JS loader — unless you pass `--no-js-fallback`. (See
*FFI: Writing Foreigns and Calling Exports* for the per-foreign side of this.)

The build model of purs-wasm is **incremental**, and on by default — pass `-f` / `--force` to
rebuild every module from scratch.

When you rebuild after changing a subset of modules, purs-wasm avoids re-optimizing the modules
whose result cannot have changed. The guiding principle is the same as ML's `.cmi`: if a module's
change preserves the *interface* it presents to its dependents, those dependents need not be
re-optimized — even though the changed module itself must be.

To make this possible, once a module has been optimized its result is written to a per-module cache
(under `<output>/_build`) as two files:

* `.pmi` — the module's **interface**: a cache key, its source hash, its dependency list, and the
  pruned optimized IR (its *summary*) that its dependents are optimized against.
* `.pmo` — the module's **object**: the full optimized IR handed to code generation.

On a rebuild, purs-wasm reads each module's source hash and its imports cheaply — without fully
decoding the CoreFn — to order the modules and decide what to reuse:

* A module whose source **and every transitive dependency's source** are unchanged is reused
  outright: it is never even decoded, and its optimized IR is loaded straight from its `.pmo`.
* A module that *is* decoded is still reused when its cache key still matches — i.e. its own source
  and every dependency *summary* it consumed are unchanged. This is where the interface-preserving
  change above pays off: a dependent is reused even though one of its dependencies was rebuilt.

Only genuine misses are re-optimized (with their `.pmi` / `.pmo` rewritten); everything else flows
straight into the lowering stage. The `.pmi` / `.pmo` split — and why it lets a rebuild skip
decoding and translation, not just optimization — is detailed in the
[compilation pipeline overview](../developers-guide/compilation-pipeline.md) and
[ADR 0034](../design-decisions/0034-pmi-interface-pmo-object-split.md).

The full resolution algorithm — how ulib shadowing, internal-module injection, and the
last-wins artifact merge interact — is specified in
[ADR 0031](../design-decisions/0031-ulib-unified-library-modules.md).

## ulib-supported packages

The following packages are fully supported by ulib. If a registry package you want to use is
not yet covered, please feel free to open an issue — or add ulib support yourself and send a
PR!

- arrays v7.3.0
- foldable-traversable v6.0.0
- integers v6.0.0
- prelude v6.0.2
- strings v6.0.1
