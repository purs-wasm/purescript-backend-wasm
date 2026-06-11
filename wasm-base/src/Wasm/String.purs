-- | WasmBase `Wasm.String` (ADR 0026 / 0030): the **first-order, byte-level** `$Str` primitives the
-- | higher-level `Data.String.*` code-point operations are built on. A `String` is a UTF-8 byte
-- | array (ADR 0001); these expose it as bytes — the Rust `.as_bytes()` / `.bytes()` analog — so the
-- | code-point layer (`length` / `charAt` / `take` / …, written as PureScript that decodes UTF-8)
-- | can run standalone on wasm and *specialize* (ADR 0027), instead of falling back to a host JS
-- | import. Per ADR 0026, `Wasm.*` is first-order only — no HOFs, no `Prelude`. All types are `Prim`
-- | (`String` / `Int`).
-- |
-- | "Code unit = byte" lives here, deliberately NOT in `Data.String.CodeUnits` (which adopts
-- | code-point semantics on this backend; ADR 0030). The `foreign import`s resolve to **intrinsics**
-- | on the wasm backend (`Intrinsics.qualifiedIntrinsic` — `Wasm.String.*`); the accompanying
-- | `Wasm/String.js` provides them for stock `purs` / `purs-backend-es` so a `wasm-base`-using
-- | project also compiles and runs on the JS backends (there a "byte" is a UTF-16 code unit — the
-- | JS-side encoding — which is correct for JS-hosted code).
module Wasm.String
  ( byteLength
  , byteAt
  , unsafeNew
  , unsafeSetByte
  ) where

-- | The UTF-8 byte length. On wasm: the `StrLen` intrinsic (`array.len` on the `$Bytes`).
foreign import byteLength :: String -> Int

-- | The byte (0-255) at index `i`, **unchecked** (out of range traps). On wasm: the `StrByteAt`
-- | intrinsic (`array.get` on the `$Bytes`).
foreign import byteAt :: String -> Int -> Int

-- | Allocate a `String` of `n` **zeroed** bytes, to be filled with `unsafeSetByte`. On wasm: the
-- | `StrNew` intrinsic (a zeroed `$Str`).
foreign import unsafeNew :: Int -> String

-- | Write byte `b` (0-255) at index `i`, **mutating the string in place**, and return that same
-- | string, so a builder loop threads it — keeping the write live (not dead-code-eliminated) and
-- | ordered by the data dependency, without needing an effect. Unchecked (out of range traps). On
-- | wasm: the `StrSetByte` intrinsic (`array.set`, then yields the string).
foreign import unsafeSetByte :: String -> Int -> Int -> String
