// FFI shim for spago JS codegen only; the purs-wasm build resolves these bare names to wasm intrinsics.
export const eqI = (a) => (b) => a === b;
export const intToNum = (n) => n;
export const numToInt = (n) => n | 0;
