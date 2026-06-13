# 0030. `Data.String` over UTF-8: code-point semantics, byte access via `Wasm.String`

- Status: ~~Proposed~~ **Accepted** _(2026-06-13: implemented. The ulib `Data.String.*` shadows (`CodeUnits` / `CodePoints` / `Common` / `Unsafe`, over the private `Data.String.Internal.Utf8` codec) give code-point semantics over the UTF-8 `$Str`; byte-level access lives in `Wasm.String` (`byteLength` / `byteAt`); `Char` is a Unicode code point.)_
- Date: 2026-06-10
- Builds on: [0001](0001-wasm-gc-substrate-and-value-representation.md) (`$Str` = UTF-8 bytes), [0026](0026-wasmbase-primitive-layer.md) (WasmBase `Wasm.*`), [0028](0028-ulib-library-layer-shadowing.md) (lib-first shadowing)

## Context

A `$Str` is a **UTF-8 byte array** (ADR 0001). The `strings` package's `Data.String.*`
modules are almost entirely `foreign import`s (CodeUnits 15, Common 8, CodePoints 7, Regex
11); only three (`singleton`/`toCharArray`/`fromCharArray`) have a curated wasm provider
(the hand-written `ulib/Data.String.CodeUnits/foreign.wat`). Every other string operation
(`length`, `take`, `drop`, `slice`, `indexOf`, `split`, `joinWith`, `trim`, `toLower`, …)
falls back to a **host JS import**, so any program that uses them is *not* standalone wasm —
it needs the JS loader. For the self-hosting goal (and for standalone library code generally)
these must run on wasm.

The shadow mechanism (ADR 0028) over WasmBase primitives (ADR 0026) is the established way to
move a registry module's foreigns into PureScript. But unlike the array HOFs already shadowed
(`Data.Functor`/`Foldable`/`Array`/`Control.Apply`/`Bind`/`Data.Eq`/`Ord`), `Data.String`
carries a **semantic** question, not just a specialization one: stock `Data.String.CodeUnits`
is defined over **UTF-16 code units** (a JavaScript-string artifact — `length` counts UTF-16
units, `charAt`/`take`/`drop` index them, astral characters count as two and can be split into
lone surrogates). That model does not fit a UTF-8 `$Str`, and emulating it faithfully over
UTF-8 (surrogate-pair-correct, O(n) byte→unit mapping) is complex and buys nothing here.

How do other systems that store strings as **UTF-8 byte sequences** resolve this?

- **Rust `str`/`String`** — `len()` is the **byte** count (documented: "not chars or
  graphemes"). Integer indexing into a `str` is forbidden; slicing must land on a UTF-8
  **char boundary** (`is_char_boundary`) or it panics / returns `None`. Character access is an
  explicit *code-point* iteration (`.chars()` / `.char_indices()`), bytes are `.bytes()` /
  `.as_bytes()`, and `char` is a **Unicode scalar value (code point)**, never a UTF-16 unit.
  Rust exposes the encoding, and that is safe *because the API refuses `Int → char`
  indexing*.
- **Haskell `Data.Text` 2.0+** — stores **UTF-8 internally** (`Word8` array), yet its public
  API (`length`, `take`, `drop`, `splitAt`, `index`) operates in **`Char` (code point)**
  units, with `length` therefore **O(n)**. `Char` is a code point. The encoding is hidden;
  the API is code-point level.

Both agree on the decisive point: **`Char` = code point** (Rust `char`, Haskell `Char`) —
neither uses UTF-16 units. They differ only on what an integer index/length *counts*: Rust =
bytes (because it forbids char-indexing), Haskell text = code points (because its API is
`Char`-indexed).

PureScript's `Data.String` API is shaped like Haskell's — `charAt :: Int -> String -> Maybe
Char`, `toCharArray :: String -> Array Char`, `take :: Int -> String -> String` — i.e. integer
indices that yield/relate to `Char`s. Grafting Rust's *byte* length onto this shape breaks the
naive invariant `length s == Array.length (toCharArray s)` and lets `take`/`drop` split a
multi-byte character into invalid UTF-8 — precisely the hazards Rust avoids by forbidding
`Int → char` indexing, an escape hatch PureScript's API does not have.

## Decision

1. **`Char` = Unicode code point** (scalar value), as in Rust `char` and Haskell `Char`. This
   is already what the existing `toCharArray`/`singleton`/`fromCharArray` wat providers do
   (UTF-8 ↔ code point), so it is a confirmation, not a change.

2. **`Data.String.CodeUnits` and `Data.String.CodePoints` both adopt code-point semantics**
   over the UTF-8 `$Str` in this backend — `length`/`charAt`/`take`/`drop`/`slice`/`splitAt`/
   `indexOf`/… count and index **code points** (O(n), as in Haskell `Data.Text`). UTF-16 code
   units — a JavaScript concept — are dropped. The two modules keep their distinct names and
   interfaces (for source compatibility) but converge to one meaning here. This preserves
   `length s == Array.length (toCharArray s)` and never produces invalid UTF-8.

3. **Byte-level access lives in `Wasm.String`** (a new WasmBase module, ADR 0026), the analog
   of Rust's `.as_bytes()` / `.bytes()`: `byteLength`/`byteAt` plus the unsafe builders
   (`unsafeNew`/`unsafeSetByte`) resolving to the runtime `$Str` intrinsics. "Code unit =
   byte" belongs here, not in `Data.String`. The `Data.String.*` shadows are implemented in
   PureScript over `Wasm.String` (UTF-8 decode/encode in PureScript), replacing the
   hand-written `.wat`.

4. **Scope.** Shadow `Data.String.CodeUnits` and `Data.String.Common` (the operations programs
   actually use); `Data.String.CodePoints` follows (it largely coincides once CodeUnits is
   code-point-based). **`Data.String.Regex` stays a JS host fallback** — a regex engine is out
   of scope for v0.1.

5. **UTF-16 escape hatch.** A program that genuinely needs JavaScript's UTF-16 code-unit
   semantics keeps the **foreign JS fallback** (it will be running under the JS loader anyway).
   If a first-class need emerges, it is a *separate package* (e.g. a `js-string`) that ports
   PureScript's UTF-16 `Data.String.CodeUnits` over foreign JS — deliberately **not** folded
   into the wasm-native `Data.String`. Recorded as a future option only.

## Consequences

- **Documented divergence from the JS backend** (consistent with ADR 0001's already-accepted
  UTF-8 consequences, e.g. `strCmp`'s code-point ordering): astral characters count as **1**,
  not 2; a `Char` may hold a code point above U+FFFF; UTF-16 code-unit indexing is gone. For
  ASCII (the overwhelming common case) behaviour is identical to the JS backend.
- **O(n) `length`/indexing** (as in Haskell `Data.Text` 2.0). Acceptable; byte-level O(1)
  access remains available via `Wasm.String` for hot paths that want it.
- **Standalone wasm string programs** become possible (no JS host needed for the common string
  ops), advancing the self-hosting goal.
- **Maintainability**: PureScript-over-`Wasm.String` replaces growing the hand-written `.wat`
  foreign layer; the conversion logic is type-checked and visible to the MIR middle-end.
- `ulib check` continues to guard each shadow's *interface* against the registry; a new
  CLI-path test guards the *runtime semantics* of the hand-written UTF-8 codecs.

## Sources

- Rust `str`: <https://doc.rust-lang.org/std/primitive.str.html>, `String`:
  <https://doc.rust-lang.org/std/string/struct.String.html>
- Haskell `Data.Text.Internal` (text 2.0, UTF-8):
  <https://hackage.haskell.org/package/text-2.0/docs/Data-Text-Internal.html>
