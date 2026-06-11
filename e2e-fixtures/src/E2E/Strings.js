// FFI shim for spago JS codegen only; the purs-wasm build resolves these bare names to wasm intrinsics.
export const concatS = (a) => (b) => a + b;
export const lenS = (s) => s.length;
export const eqS = (a) => (b) => a === b;
