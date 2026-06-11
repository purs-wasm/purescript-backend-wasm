// FFI stubs so spago's JS codegen accepts the foreign imports; the purs-wasm build resolves
// `incrCtr`/`readCtr` to the `IncrCtr`/`ReadCtr` intrinsics (a mutable wasm global), so this JS
// never runs in the standalone e2e artifact.
export const incrCtr = () => {};
export const readCtr = () => 0;
