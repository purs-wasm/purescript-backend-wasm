"use strict";

// Fast, deterministic, non-cryptographic content hashing for the `.pmo` cache key.
// A build cache only needs collision resistance good enough that an accidental clash
// is astronomically unlikely, not adversarial resistance — so this is a single pass
// computing two independent 32-bit hashes (FNV-1a and djb2) concatenated to a 16-hex
// digest (~1 in 1.8e19 collision). Pure arithmetic, no Node/crypto API, so it runs in
// any JS host (including a future self-hosted wasm build) and stays referentially
// transparent for use inside the pure optimizer loop.

const textEncoder = new TextEncoder();

const hex8 = (x) => (x >>> 0).toString(16).padStart(8, "0");

const hashU8 = (u8) => {
  let fnv = 0x811c9dc5;
  let djb2 = 5381;
  for (let i = 0; i < u8.length; i++) {
    const b = u8[i];
    fnv ^= b;
    fnv = Math.imul(fnv, 0x01000193);
    djb2 = (Math.imul(djb2, 33) + b) | 0;
  }
  return hex8(fnv) + hex8(djb2);
};

export const hashBytes = (u8) => hashU8(u8);

export const hashString = (s) => hashU8(textEncoder.encode(s));
