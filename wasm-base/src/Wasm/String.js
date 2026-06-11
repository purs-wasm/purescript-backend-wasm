// JS provider for `Wasm.String`'s byte primitives — used by the `purs` / purs-backend-es builds
// only. The wasm backend resolves these to intrinsics and ignores this file. On wasm a "byte" is a
// UTF-8 byte of the `$Str`; here it is the host string's native code unit (a UTF-16 unit), which is
// the right notion for JS-hosted code. The `Data.String.*` UTF-8 code-point layer (ADR 0030) is
// built for wasm; on the JS backends the registry `Data.String` is used, not the shadow, so these
// primitives are only exercised by code that imports `Wasm.String` directly. Strings are immutable,
// so `unsafeSetByte` rebuilds — callers thread the returned value, so this is observably the same.
export const byteLength = (s) => s.length;
export const byteAt = (s) => (i) => s.charCodeAt(i);
export const unsafeNew = (n) => "\0".repeat(n);
export const unsafeSetByte = (s) => (i) => (b) => s.slice(0, i) + String.fromCharCode(b) + s.slice(i + 1);
