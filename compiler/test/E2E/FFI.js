// The host imports for the FFI e2e fixtures (ADR 0014), keyed by source module.
export const addOneImports = { "Example.FFI": { addOne: (x) => x + 1 } };

// Raw (un-marshalled) JS for the String fixture; the harness wraps these with
// $Str <-> string marshalling per the externs-derived manifest.
export const strImports = {
  "Example.FFIStr": {
    strLength: (s) => s.length,
    shout: (s) => s.toUpperCase(),
  },
};
