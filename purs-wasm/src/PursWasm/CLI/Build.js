// The dotted import module names of a corefn.json, via a cheap transient `JSON.parse` (the tree
// is GC'd, only the small import-name list is kept) — for file-level reachability pruning before
// the expensive full decode. A real app's output dir holds far more modules than one entry needs.
export const corefnImportsImpl = (json) => {
  try {
    const j = JSON.parse(json);
    return (j.imports || []).map((i) => i.moduleName.join("."));
  } catch {
    return [];
  }
};

// A monotonic clock in milliseconds, for the build's elapsed-time report.
export const nowMsImpl = () => performance.now();

// The distinct host-import module names a wasm binary declares (excluding the internal "rt"
// runtime), i.e. the user `foreign import` modules a JS loader must satisfy (ADR 0014).
export const importModulesImpl = (bytes) => () => {
  const mod = new WebAssembly.Module(bytes);
  const set = new Set();
  for (const { module } of WebAssembly.Module.imports(mod)) {
    if (module !== "rt") set.add(module);
  }
  return Array.from(set);
};
