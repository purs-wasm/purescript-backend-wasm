// FFI shim for spago JS codegen only; the purs-wasm build resolves these bare names to wasm intrinsics.
export const intAdd = (a) => (b) => a + b;
