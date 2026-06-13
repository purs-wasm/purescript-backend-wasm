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
