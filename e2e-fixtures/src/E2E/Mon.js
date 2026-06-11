// FFI for `E2E.Mon` (spago JS codegen only; the purs-wasm build resolves these bare names to the
// `StrLen` / `ArrayLength` intrinsics, so the e2e artifact stays standalone).
export const lenS = (s) => s.length;
export const lengthA = (xs) => xs.length;
