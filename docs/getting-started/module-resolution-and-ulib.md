# Module Resolution and `ulib`

It is worth understanding how purs-wasm decides which PureScript module files to build.

At a high level: starting from the entry modules you pass with `-e`, purs-wasm walks the
import graph to find the set of reachable modules, and for each one it picks the artifact to
use. A module covered by **ulib** is sourced from the precompiled library (its
wasm-optimized CoreFn and foreign); otherwise it is taken from your project's `purs` output.
For a foreign import that has no in-wasm (`foreign.wat`) provider, the build falls back to
that module's `foreign.js` through the JS loader — unless you pass `--no-js-fallback`. (See
*FFI: Writing Foreigns and Calling Exports* for the per-foreign side of this.)

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
