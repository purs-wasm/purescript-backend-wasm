// JS provider for `Wasm.Int` — used by the `purs` / purs-backend-es builds only. The wasm
// backend resolves these to intrinsics and ignores this file.
export const add = (a) => (b) => (a + b) | 0;
export const sub = (a) => (b) => (a - b) | 0;
export const mul = (a) => (b) => Math.imul(a, b);
export const eq = (a) => (b) => a === b;
