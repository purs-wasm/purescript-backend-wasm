// The host imports for the FFI e2e fixture (ADR 0014): the JS implementation of
// `Example.FFI`'s `addOne`, keyed by the foreign's source module.
export const addOneImports = { "Example.FFI": { addOne: (x) => x + 1 } };
