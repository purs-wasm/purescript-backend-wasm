"use strict";

// A growable little-endian byte writer / cursor reader, the low-level substrate
// for the MIR cache codec. Hand-written (rather than Argonaut-generic) because the
// cache exists to make a rebuild cheaper than re-optimizing: deserialize must be far
// faster than the ~2s middle-end it replaces, which the generic decoder was not
// (measured ≈ the corefn decode cost). Uint8Array + DataView so the same code runs
// under Node and the browser (and, eventually, a self-hosted wasm host).

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

const ensure = (w, n) => {
  const need = w.len + n;
  if (need <= w.buf.length) return;
  let cap = w.buf.length * 2;
  while (cap < need) cap *= 2;
  const next = new Uint8Array(cap);
  next.set(w.buf.subarray(0, w.len));
  w.buf = next;
};

const putByte = (w, b) => {
  ensure(w, 1);
  w.buf[w.len++] = b;
};

// Unsigned LEB128. Uses arithmetic (not bitwise) so it stays correct for the full
// uint32 range produced by zigzag below — `& 0x7f` would coerce to int32 and break.
const putVarU = (w, n) => {
  while (n >= 0x80) {
    putByte(w, (n % 128) + 128);
    n = Math.floor(n / 128);
  }
  putByte(w, n);
};

const getVarU = (r) => {
  let result = 0;
  let scale = 1;
  for (;;) {
    const b = r.buf[r.pos++];
    result += (b & 0x7f) * scale;
    if ((b & 0x80) === 0) return result;
    scale *= 128;
  }
};

export const newWriter = () => ({ buf: new Uint8Array(1024), len: 0 });

export const putU8 = (w) => (b) => () => putByte(w, b & 0xff);

// Zigzag-encode the signed 32-bit Int, then LEB128. Compact for the small
// magnitudes that dominate MIR (tags, arities, lengths, most LitInts).
export const putInt = (w) => (n) => () => putVarU(w, (((n << 1) ^ (n >> 31)) >>> 0));

export const putNumber = (w) => (x) => () => {
  ensure(w, 8);
  // Writer buffers always have byteOffset 0 (each grow allocates a fresh array).
  new DataView(w.buf.buffer).setFloat64(w.len, x, true);
  w.len += 8;
};

export const putString = (w) => (s) => () => {
  const bytes = textEncoder.encode(s);
  putVarU(w, bytes.length);
  ensure(w, bytes.length);
  w.buf.set(bytes, w.len);
  w.len += bytes.length;
};

// A length-prefixed raw byte blob — lets a container (the `.pmo` file) embed an
// already-encoded sub-document (a module body) and split it back out on read.
export const putBytes = (w) => (u8) => () => {
  putVarU(w, u8.length);
  ensure(w, u8.length);
  w.buf.set(u8, w.len);
  w.len += u8.length;
};

export const finish = (w) => () => w.buf.slice(0, w.len);

export const newReader = (u8) => () => ({ buf: u8, pos: 0 });

export const getU8 = (r) => () => r.buf[r.pos++];

export const getInt = (r) => () => {
  const u = getVarU(r);
  return (u >>> 1) ^ -(u & 1);
};

export const getNumber = (r) => () => {
  const dv = new DataView(r.buf.buffer, r.buf.byteOffset);
  const x = dv.getFloat64(r.pos, true);
  r.pos += 8;
  return x;
};

export const getString = (r) => () => {
  const len = getVarU(r);
  const slice = r.buf.subarray(r.pos, r.pos + len);
  r.pos += len;
  return textDecoder.decode(slice);
};

export const getBytes = (r) => () => {
  const len = getVarU(r);
  // Copy out, so the returned blob is independent of the reader's backing buffer.
  const slice = r.buf.slice(r.pos, r.pos + len);
  r.pos += len;
  return slice;
};

export const atEnd = (r) => () => r.pos >= r.buf.length;
