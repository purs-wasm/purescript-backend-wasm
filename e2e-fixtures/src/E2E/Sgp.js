// FFI for `E2E.Sgp` (spago JS codegen only; the purs-wasm build resolves these bare names to the
// `ArrayLength` / `ArrayIndex` intrinsics, so the e2e artifact stays standalone).
export const lengthA = (xs) => xs.length;
export const indexA = (xs) => (i) => xs[i];
