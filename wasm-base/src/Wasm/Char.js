// JS provider for `Wasm.Char` — `purs` / purs-backend-es builds only; the wasm backend resolves
// these to the `CharCodeId` identity intrinsic and ignores this file. On JS a `Char` is a UTF-16
// code unit, so `toCodePoint` reads its code unit and `fromCodePoint` builds a one-unit string's
// char (the JS-hosted notion of `Char`).
export const toCodePoint = (c) => c.charCodeAt(0);
export const fromCodePoint = (n) => String.fromCharCode(n);
