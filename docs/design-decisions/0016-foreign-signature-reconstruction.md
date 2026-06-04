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

**Reconstruct foreign signatures by parsing the `.purs` source for the private foreigns
externs omit, and merge them under externs (externs-wins).**

- A new **pure pass** (`SourceForeigns.parseForeignSigs :: String -> Object ForeignSig`)
  parses a source module with `PureScript.CST.parseModule`, takes the module name from the
  header, and for each top-level `foreign import value :: type` (skipping `foreign import
  data`/kind) emits a `ForeignSig` keyed `Module.ident`. The CST `Type` is mapped to the
  **same `MarshalKind`** the externs path uses (function arrows → params; `Int`/`Char`→MI32,
  `Number`→MF64, `Boolean`→MBool, `String`→MStr, `Array`→MArray, `Record`→MRecord,
  `Effect`→MEffect; `forall`/parens/constraints peeled; otherwise MOpaque) — mirroring
  `Externs.marshalKind` over a different syntax tree. **Only canonical types are recognised:**
  the CST is *not* desugared, so a type synonym (`type Handler = …`) or an infix type
  operator (`TypeOp`) is not expanded — it falls through to `MOpaque`. Function arrows are
  the one structural form (`->` is a dedicated CST node, not a `TypeOp`), so arity is always
  recovered correctly; only the kind of an aliased/operator *position* degrades to opaque.
- Each module's source file is located via spago's **`cache-db.json`** (the build cache,
  sitting beside the artifacts in the `-I` dir): it maps every module to its source files,
  e.g. `"Data.Int": { ".spago/p/integers-…/src/Data/Int.purs": [timestamp, hash], … }`. The
  bin reads that one file and, per module, takes the `.purs` entry. The paths are clean and
  relative to the build's working directory (= the bin's cwd, where `-I`/`-O` are also
  relative), so they resolve directly — and because `cache-db.json` knows every linked
  module's source regardless of which package it lives in, this works in a spago **monorepo**
  with no source-root configuration. (The per-module sourcemap `index.js.map` was considered
  but its `sources` path is calibrated oddly under `--output` — many spurious `../` — whereas
  `cache-db.json`'s paths are clean and it additionally carries the hashes the staleness check
  below would use.)
- **Externs win over source; source only fills the private foreigns externs omit.** The
  merge is `externs ∪ source` (externs-biased): the externs type is already *desugared by
  `purs`* (synonyms expanded, operators resolved), so it is authoritative for any **exported**
  foreign — and using it avoids the CST's no-desugaring limitation regressing an exported
  foreign's marshal kinds to opaque. Source contributes only the keys externs lack, i.e. the
  private `*Impl` foreigns. This also reverses the original (source-wins) draft.
- **Source is parsed lazily, only when it can matter.** Before reading any `.purs`, the bin
  compares a module's CoreFn `foreignNames` against the externs sigs; it parses the source
  **only if some declared foreign is missing from externs** (a private one). A module whose
  foreigns are all exported never pays the parse cost — the common case is free.
- This is a **packaging-stage** concern: the compiler core stays agnostic, taking a merged
  `Object ForeignSig`; only the bin reads source and builds it. The effectful-foreign set
  (purity, ADR 0015) is derived from the merged signatures, so private effectful foreigns are
  covered too.
- Because foreign-import-into-wasm is resolved off the signature, a private foreign now
  emits a host import and its `foreign.js` is bundled by the existing loader path (which keys
  off the wasm's import section, not off externs). **Intrinsics thereby become a performance
  optimisation, not a correctness necessity** — a foreign without an intrinsic still runs via
  the JS ladder once its source signature is known.
- **Reconstruction failure degrades to opaque, it does not stop the build.** If a declared
  foreign still has no signature after the merge (source unparsable, cache-db absent, …),
  lowering — which knows the full set of CoreFn `foreignNames` — synthesises an **all-opaque**
  host import (`MOpaque` params/result, arity taken from the call site) instead of throwing
  `unknown callee`. The program builds and links; the foreign is callable but unmarshalled
  (bare `eqref` across the boundary), so a scalar foreign may then misbehave at runtime. This
  is the accepted trade-off: an opaque-but-built program over a hard build failure. The
  fallback is **gated on `foreignNames`** so a genuinely unknown callee (a real bug, not a
  foreign) still fails loudly rather than silently becoming a missing host import.

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
- Requires source availability at build time and that `cache-db.json` is present (spago writes
  it on every build); a module absent from the cache-db, or whose source file is unreadable,
  falls back to externs-only, and any private foreign then left without a signature degrades
  to the opaque host-import fallback above rather than failing the build.
- A type synonym or infix type operator in a **private** foreign's type is not desugared by
  the CST pass, so such a position becomes `MOpaque` (arity is still correct). Exported
  foreigns are unaffected — they take the desugared externs sig under the externs-wins merge.
  Accepted: the `*Impl` idiom overwhelmingly uses canonical scalar/`Effect`/function types.
- Introduces a source/compiled-output skew risk (the `.purs` must match the compiled
  `corefn.json`). Low in practice — PureScript has no macros/preprocessing, so source is
  truth — but real if a stale source tree is pointed at. *Future enhancement:* `cache-db.json`
  already records each source's `[timestamp, hash]`, so reconstruction can compare against the
  compiled artifact and skip (surfacing the skew rather than silently using a mismatched type)
  for a module whose source is newer; deferred — not needed for correctness in the normal
  build-then-bundle flow.
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
  caller-supplied root list is fragile and easy to get wrong. `cache-db.json` already pinpoints
  each module's source exactly, with zero configuration.
- **The per-module sourcemap (`index.js.map`, `sources[0]`).** Also zero-config, but under a
  custom `--output` its `sources` path is calibrated oddly (a long run of spurious `../`
  overshooting the repo root), needing a fragile strip-and-reanchor heuristic. `cache-db.json`
  gives clean working-dir-relative paths in one file and carries the hashes the staleness
  enhancement wants. Rejected in favour of the cache-db.
