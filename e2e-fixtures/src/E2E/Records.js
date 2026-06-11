// FFI for `E2E.Records.intAdd`. Only `spago`'s JS codegen consumes this; the `purs-wasm` build
// resolves the bare name `intAdd` to the `IntAdd` wasm intrinsic, so the e2e artifact stays
// standalone and never calls it (it mirrors a user who declares a foreign with a JS impl).
export const intAdd = (a) => (b) => a + b;
