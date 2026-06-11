// FFI for `E2E.LinkB.intAdd` (spago JS codegen only; the purs-wasm build resolves the bare name
// `intAdd` to the `IntAdd` intrinsic, so the e2e artifact stays standalone).
export const intAdd = (a) => (b) => a + b;
