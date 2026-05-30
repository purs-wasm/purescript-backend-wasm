import { readFileSync } from "node:fs";

export const readFixture = (path) => () => readFileSync(path, "utf8");

export const instantiate = (bytes) => () =>
  new WebAssembly.Instance(new WebAssembly.Module(bytes), {});

export const callI32x0 = (inst) => (name) => () => inst.exports[name]();

export const callI32x1 = (inst) => (name) => (a) => () => inst.exports[name](a);

export const callI32x2 = (inst) => (name) => (a) => (b) => () =>
  inst.exports[name](a, b);

export const callI32x3 = (inst) => (name) => (a) => (b) => (c) => () =>
  inst.exports[name](a, b, c);
