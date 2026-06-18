// The dotted import module names of a corefn.json, via a cheap transient `JSON.parse` (the tree
// is GC'd, only the small import-name list is kept) — for file-level reachability pruning before
// the expensive full decode. A real app's output dir holds far more modules than one entry needs.
export const corefnImports = (json) => {
  try {
    const j = JSON.parse(json);
    return (j.imports || []).map((i) => i.moduleName.join("."));
  } catch {
    return [];
  }
};

// The bare foreign-import names a corefn.json declares (its "foreign" list), via the same cheap
// transient parse — so the incremental (`--cache`) path can build lowering's qualified foreign set
// without a full decode of a cache-hit module (ADR 0034).
export const corefnForeignNames = (json) => {
  try {
    const j = JSON.parse(json);
    return j.foreign || [];
  } catch {
    return [];
  }
};
