"use strict";

// The interned id of a record label: FNV-1a over the label's UTF-8 bytes, masked to
// 31 bits. This MUST stay identical to `runtime.wat`'s `$rt.internStr` (the JS
// marshalling glue resolves a host field name to its id via that wasm export, so the
// compile-time id and the runtime-computed id have to agree). `Math.imul` gives the
// 32-bit wrapping multiply that matches wasm `i32.mul`; `& 0x7fffffff` keeps the id
// non-negative so it fits a PureScript `Int` and orders the same signed or unsigned.
const textEncoder = new TextEncoder();

export const labelHash = (s) => {
  const u8 = textEncoder.encode(s);
  let fnv = 0x811c9dc5;
  for (let i = 0; i < u8.length; i++) {
    fnv ^= u8[i];
    fnv = Math.imul(fnv, 0x01000193);
  }
  return (fnv >>> 0) & 0x7fffffff;
};
