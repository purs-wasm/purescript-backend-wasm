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

// Raw JS for the Array fixture; the harness wraps these with recursive
// $Vals <-> JS-array (and element) marshalling per the manifest.
export const arrImports = {
  "Example.FFIArr": {
    sumArr: (xs) => xs.reduce((a, b) => a + b, 0),
    range: (n) => Array.from({ length: n }, (_, i) => i),
    sumNested: (xss) => xss.reduce((a, xs) => a + xs.reduce((p, q) => p + q, 0), 0),
    totalLen: (xs) => xs.reduce((a, s) => a + s.length, 0),
  },
};

// Raw JS for the Record fixture; the harness wraps these with $Rec <-> JS-object
// marshalling (field-by-field, recursing into each field's kind) per the manifest.
export const recImports = {
  "Example.FFIRec": {
    descLen: (r) => r.name.length + r.age,
    mkPoint: (n) => ({ x: n, y: n + 1 }),
  },
};

// Raw JS for the Boolean / nested-Number fixture; the harness wraps these with
// i31ref <-> boolean and boxed-$Num <-> number marshalling per the manifest.
export const scalarImports = {
  "Example.FFIScalar": {
    notF: (b) => !b,
    countPos: (xs) => xs.filter((x) => x > 0).length,
    mkNums: (n) => [-2.0, 3.5, -1.0, n],
  },
};
