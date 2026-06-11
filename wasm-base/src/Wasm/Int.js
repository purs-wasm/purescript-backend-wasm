// JS provider for `Wasm.Int` — used by the `purs` / purs-backend-es builds only. The wasm
// backend resolves these to intrinsics and ignores this file.
export const add = (a) => (b) => (a + b) | 0;
export const sub = (a) => (b) => (a - b) | 0;
export const mul = (a) => (b) => Math.imul(a, b);
export const eq = (a) => (b) => a === b;
export const lt = (a) => (b) => a < b;
// Euclidean div/mod matching the IntDiv/IntMod intrinsics: non-negative remainder, 0 when b === 0.
const euclMod = (a, b) => {
  const yy = Math.abs(b);
  return yy === 0 ? 0 : ((a % yy) + yy) % yy;
};
export const div = (a) => (b) => (b === 0 ? 0 : ((a - euclMod(a, b)) / b) | 0);
export const mod = (a) => (b) => euclMod(a, b);
