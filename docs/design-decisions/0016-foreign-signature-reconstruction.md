# 0016. Reconstructing foreign signatures from `.purs` source

- Status: Accepted
- Date: 2026-06-04

## Context

ADR 0014 resolves a `foreign import` that is not a compiler intrinsic by looking up its
**signature** (parameter/result marshal kinds, arity) in the module's externs
(`Externs.foreignSigs :: Array ExternsFile -> Object ForeignSig`, built from each
`EDValue`'s type). That signature is what lets the backend emit a host import and the JS
loader marshal values across the boundary.

The problem: **`externs.cbor` contains only a module's *exported* declarations** — its
public interface, which is all downstream typechecking needs. But the dominant PureScript
FFI idiom wraps a **private** foreign in an exported pure function:

```purescript
-- Data.Int
fromNumber :: Number -> Maybe Int
fromNumber = fromNumberImpl Just Nothing
foreign import fromNumberImpl                 -- NOT exported
  :: (forall a. a -> Maybe a) -> (forall a. Maybe a) -> Number -> Maybe Int
```

CoreFn (not type-erased of references) calls `Data.Int.fromNumberImpl`, but the externs
omit it, so the backend has no signature and lowering fails with `UnsupportedExpr "unknown
callee: Data.Int.fromNumberImpl"` — even though `Data.Int/foreign.js` provides the
implementation. Confirmed empirically: decoding `Data.Int.externs.cbor` lists `fromNumber`,
`floor`, `toNumber`, … but **not** `fromNumberImpl`.

So the JS provider ladder (ADR 0014) covers an application's **own exported** foreigns
(binding a JS library, the DOM, …) but **not the library internals** that real programs
transitively depend on — exactly the `*Impl` foreigns. Per-foreign **intrinsics** (ADR
0002) or **ulib** wat/wasm (ADR 0012) can cover the *hot* internals, but neither is a
general answer: it is whack-a-mole, one foreign at a time.

The type we are missing **does exist** — in the original `.purs`, which is the single
source of truth for a foreign's type and which *does* contain private foreigns. And
`language-cst-parser` is already a dependency.

## Decision

**Reconstruct foreign signatures by parsing the `.purs` source, and merge them
(source-wins) with the externs-derived ones.**

- A new **pure pass** (`SourceForeigns.parseForeignSigs :: String -> Object ForeignSig`)
  parses a source module with `PureScript.CST.parseModule`, takes the module name from the
  header, and for each top-level `foreign import value :: type` (skipping `foreign import
  data`/kind) emits a `ForeignSig` keyed `Module.ident`. The CST `Type` is mapped to the
  **same `MarshalKind`** the externs path uses (function arrows → params; `Int`/`Char`→MI32,
  `Number`→MF64, `Boolean`→MBool, `String`→MStr, `Array`→MArray, `Record`→MRecord,
  `Effect`→MEffect; `forall`/parens/constraints peeled; otherwise MOpaque) — mirroring
  `Externs.marshalKind` over a different syntax tree.
- The source file is located via the **sourcemap already emitted beside the other
  artifacts**: `output/<Module>/index.js.map` carries `sources[0]` = the original `.purs`
  path (relative to the map). So the bin reads it from the *same `-I` input dir* it already
  scans for `corefn.json`/`externs.cbor` — no separate source-root flag. This is what makes
  it work in a spago **monorepo**, where each package's sources live in different trees: the
  per-module map pins each module's source wherever it is. Source signatures **override**
  externs (source is complete and authoritative — it has private foreigns); externs fills any
  module whose map/source is absent. If a module has no sourcemap, it silently falls back to
  externs-only, so the change is backward compatible.
- This is a **packaging-stage** concern: the compiler core stays agnostic, taking a merged
  `Object ForeignSig`; only the bin reads source and builds it. The effectful-foreign set
  (purity, ADR 0015) is derived from the merged signatures, so private effectful foreigns are
  covered too.
- Because foreign-import-into-wasm is resolved off the signature, a private foreign now
  emits a host import and its `foreign.js` is bundled by the existing loader path (which keys
  off the wasm's import section, not off externs). **Intrinsics thereby become a performance
  optimisation, not a correctness necessity** — a foreign without an intrinsic still runs via
  the JS ladder once its source signature is known.

Why source rather than fixing externs: externs are the public interface by design (omitting
private declarations is correct for typechecking), and we cannot change `purs`. CoreFn knows
the foreign *names* (`foreignNames`) but is type-erased. The `.purs` source is the only
artifact carrying private foreigns' **types**. If PureScript ever exposes private foreign
types (a typed IR, or fuller externs), this pass can be retired — but we will not block on
that.

## Consequences

- Private/internal foreigns (the `*Impl` idiom) resolve, so real library code (`Data.Int`,
  `Data.String`, …) works through the JS ladder without bespoke intrinsics — the gating
  limitation found while running an `Effect.Random.randomInt` example.
- Higher-order private foreigns marshal correctly: their function-typed parameters become
  `MFunc` from the source type (impossible without the type).
- The pass is pure and unit-testable (`String -> Object ForeignSig`), independent of the
  build pipeline.
- Requires source availability at build time and that sourcemaps were emitted (`purs`
  `-g sourcemaps`, spago's default); a module lacking a sourcemap falls back to externs-only.
- Introduces a source/compiled-output skew risk (the `.purs` must match the compiled
  `corefn.json`). Low in practice — PureScript has no macros/preprocessing, so source is
  truth — but real if a stale source tree is pointed at. *Future enhancement:* consult
  spago's `output/cache-db.json` and skip reconstruction for a module whose source is newer
  than its compiled artifact (surfacing the skew rather than silently using a mismatched
  type); deferred — not needed for correctness in the normal build-then-bundle flow.
- Adds a second parser path (CST) beside the externs decoder; the CST→`MarshalKind` map must
  evolve in lockstep with the marshal-kind set (kept a mirror of `Externs.marshalKind`).
- Parsing all `.purs` under the roots adds some build time — cheap, since only foreign
  declarations are extracted and most modules have none.

## Alternatives considered

- **An intrinsic for every internal `*Impl`** (ADR 0002). Whack-a-mole; does not scale to
  arbitrary library internals. Retained for genuinely hot paths only (e.g. `fromNumberImpl`
  landed as an intrinsic for speed), but not as the general resolution mechanism.
- **Hand-written ulib wat/wasm for library foreigns** (ADR 0012). Viable for a curated
  package set, but heavy per-foreign authoring; complementary to, not a replacement for, a
  general signature source.
- **Infer signatures from CoreFn `foreignNames` + arity-from-use, all-`Boxed`.** Gives the
  name and arity but not the marshal *kinds*; a host JS foreign needs real JS values, so a
  Boxed/opaque fallback breaks even scalars, and higher-order foreigns need `MFunc`. Rejected.
- **Wait for PureScript to expose private foreign types** (typed IR, or richer externs).
  Out of our control and indefinite. Rejected.
- **Synthesise `ExternsFile` entries from source.** Roundabout — the compiler already
  consumes `Object ForeignSig`, so feed that representation directly.
- **An explicit `-S/--src` source-root flag.** Rejected: in a spago monorepo the sources of
  the linked modules are scattered across packages (`.spago/p/*/src`, each app's `src`), so a
  caller-supplied root list is fragile and easy to get wrong. The per-module `index.js.map`
  already pinpoints each source exactly, with zero configuration.
