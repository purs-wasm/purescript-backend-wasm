-- | The deterministic interned id of a record/dictionary label: a hash of the
-- | label's bytes, so any module can assign a label's id from the name alone — no
-- | whole-program label-numbering pass — and records built in one module project
-- | correctly in another (ADR 0037 barrier ④, the per-module-codegen enabler).
-- |
-- | The id MUST match `runtime.wat`'s `$rt.internStr` byte-for-byte: the JS
-- | marshalling glue resolves a host field name to its id by calling that export
-- | (`runtime/marshal.js`), so the compile-time id and the runtime-computed id have to
-- | agree. Both are FNV-1a over the label's UTF-8 bytes, masked to 31 bits.
-- |
-- | Masked to 31 bits (non-negative) on purpose: a record's label-id array is kept
-- | sorted, but statically-built records sort the (signed) PureScript `Int` while the
-- | runtime's `recSet` sorts unsigned (`i32.ge_u`); a negative id would order the two
-- | differently and corrupt the record. A non-negative id makes the orders coincide.
-- |
-- | Hashing is a many-to-one map, so two distinct labels *can* collide on one id (which
-- | would merge two record fields). The lowering checks the whole program's label set
-- | for a collision and fails the build loudly rather than emit a corrupt record
-- | (`Lower.lowerModules`); at realistic label counts a collision is astronomically
-- | unlikely, and the check guarantees it can never pass silently.
module PureScript.Backend.Wasm.Lower.LabelHash
  ( labelHash
  ) where

-- | The 31-bit FNV-1a hash of the label's UTF-8 bytes. Pure (no host state), so it can
-- | run inside the lowering. Must stay in lockstep with `runtime.wat`'s `$rt.internStr`.
foreign import labelHash :: String -> Int
