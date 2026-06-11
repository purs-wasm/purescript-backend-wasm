import { pathToFileURL } from "node:url";
import { join } from "node:path";

// Dynamic-import a fixture's generated loader (`index.mjs`) and hand back its marshalled `exports`
// (ADR 0031 phase 5). `EffectFnAff`: `(onError, onSuccess) => canceler` — the import is async, so
// this is the one Aff boundary; once loaded, the call helpers below are synchronous. Path is
// repo-root-relative (spago test runs from the repo root).
export const loadExportsImpl = (mod) => (onError, onSuccess) => {
  const url = pathToFileURL(join(process.cwd(), "compiler/test/e2e-build", mod, "index.mjs")).href;
  import(url).then(
    (m) => onSuccess(m.exports),
    (err) => onError(err),
  );
  return (cancelError, onCancelerError, onCancelerSuccess) => onCancelerSuccess();
};

export const callI32x0 = (exp) => (name) => () => exp[name]();
export const callI32x1 = (exp) => (name) => (a) => () => exp[name](a);

export const callJson = (exp) => (name) => (argsJson) => () =>
  JSON.stringify(exp[name](...JSON.parse(argsJson)));

export const runUnit = (exp) => (name) => () => {
  exp[name](); // an exported `Effect Unit` is a deferred thunk
};
