import { execFileSync } from "node:child_process";

// Run a tool synchronously, inheriting stdio; throws on a non-zero exit.
export const execFileImpl = (cmd) => (args) => () => {
  execFileSync(cmd, args, { stdio: "inherit" });
};

// The distinct host-import module names a wasm binary declares (excluding the
// internal "rt" runtime), i.e. the user `foreign import` modules a JS loader must
// satisfy (ADR 0014). Reads the import section via WebAssembly.Module.imports.
export const importModulesImpl = (bytes) => () => {
  const mod = new WebAssembly.Module(bytes);
  const set = new Set();
  for (const { module } of WebAssembly.Module.imports(mod)) {
    if (module !== "rt") set.add(module);
  }
  return Array.from(set);
};
