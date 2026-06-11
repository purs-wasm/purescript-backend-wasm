// Module name -> its `.purs` source path, parsed from spago's `cache-db.json` (ADR 0016).
// Each entry maps source files (`.purs`/`.js`) to [timestamp, hash]; we take the `.purs`.
// Paths are relative to the build's working directory. Returns a plain object (= Object).
export const cacheDbSourcesImpl = (json) => {
  const out = {};
  try {
    const db = JSON.parse(json);
    for (const mod of Object.keys(db)) {
      const purs = Object.keys(db[mod]).find((k) => k.endsWith(".purs"));
      if (purs) out[mod] = purs;
    }
  } catch {
    /* no/!valid cache-db → no source reconstruction (externs-only fallback) */
  }
  return out;
};
