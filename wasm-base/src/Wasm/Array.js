// JS provider for `Wasm.Array`'s first-order primitives — used by the `purs` / purs-backend-es
// builds only. The wasm backend resolves these to intrinsics and ignores this file.
export const length = (a) => a.length;
export const unsafeIndex = (a) => (i) => a[i];
export const unsafeNew = (n) => new Array(n);
export const unsafeSet = (a) => (i) => (v) => {
  a[i] = v;
  return a;
};
