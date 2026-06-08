# wasm-base

The **WasmBase** primitive layer: a thin PureScript bridge to the low-level operations the `purs-wasm` backend provides as intrinsics. It should contain only *first-order* definitions and not depend on other packages.

## Notes

- **Intended to be used with the `purs-wasm` backend.** The `Wasm.*` modules expose, on the
  PureScript side, the first-order primitives the compiler resolves to **wasm intrinsics**
  (e.g. `Wasm.Array.unsafeNew` → `array.new`, `unsafeIndex` → `array.get`). It is a thin
  bridge, not a library.

- **Compatibility via JS foreigns.** Each primitive also ships a corresponding JS
  implementation (`Wasm/*.js`), so a project depending on `wasm-base` still **compiles and
  runs on stock `purs` / `purs-backend-es`** — it is not locked to `purs-wasm`.
  On the wasm backend the JS foreigns are ignored (the intrinsic wins in the provider ladder;
  see [ADR-0014](../docs/design-decisions/0014-user-ffi-resolution-and-marshalling.md) for more information about the foreign provider ladder).

- **Application authors should avoid using this API directly**, except in special cases. It
  is deliberately `unsafe` and low-level — unchecked indexing, manual allocation and in-place
  mutation. Its purpose is to let *library* higher-order combinators (`Data.Array`'s `map` /
  `foldl` / `filter`, …) be written in PureScript over it so their closures specialize on
  wasm. Prefer those library functions; reach for `Wasm.*` only when you must.
