// Shared FFI marshalling glue (ADR 0014 / 0015), factored out of the generated loader and the e2e
// test harness so the conversion logic lives in ONE checked-in place (Issue #10). `makeMarshal(E)`
// closes over `E` — the wasm exports accessor providing the $Str/$Vals/$Int read & build primitives
// (`strLen`/`strNew`/`boxInt`/`proj`/…). Callers pass `E` as a *lazy* view so the factory can run
// before instantiation (the glue is needed while wiring the importObject): the loader uses
// `new Proxy({}, { get: (_, p) => inst.exports[p] })`; the harness merges the separately
// instantiated runtime with `inst.exports`.
//
// A parsed marshal kind `k` is a string leaf ("i"/"f"/"b"/"s"/"o"), {a:k} (array),
// {fn:[pk,rk]} (function), {r:{field:k}} (record), or {eff:k} (Effect).
export const makeMarshal = (E) => {
  const enc = new TextEncoder();
  const dec = new TextDecoder();
  const strToJs = (ref) => {
    const n = E.strLen(ref);
    const b = new Uint8Array(n);
    for (let i = 0; i < n; i++) b[i] = E.strByteAt(ref, i);
    return dec.decode(b);
  };
  const strFromJs = (s) => {
    const b = enc.encode(s);
    const ref = E.strNew(b.length);
    for (let i = 0; i < b.length; i++) E.strSetByte(ref, i, b[i]);
    return ref;
  };
  // eqref (a boxed, nested value) → JS, by kind.
  const eqrefToJs = (k, ref) => {
    if (typeof k === "string") {
      if (k === "i") return E.unboxInt(ref);
      if (k === "f") return E.unboxNum(ref); // boxed $Num element/field
      if (k === "b") return !!E.unboxBool(ref); // i31ref 0/1 → boolean
      if (k === "s") return strToJs(ref);
      return ref;
    }
    if (k.a !== undefined) {
      const n = E.arrayLen(ref);
      const out = new Array(n);
      for (let i = 0; i < n; i++) out[i] = eqrefToJs(k.a, E.arrayGet(ref, i));
      return out;
    }
    if (k.fn !== undefined) {
      // a wasm $Clo → a JS function: marshal the arg in, apply via the trampoline, marshal out
      const [pk, rk] = k.fn;
      return (a) => eqrefToJs(rk, E.applyClo(ref, eqrefFromJs(pk, a)));
    }
    // Effect a (export side): wasm already performed it, so the value IS the inner result
    if (k.eff !== undefined) return eqrefToJs(k.eff, ref);
    // record: read each known field by its interned label id
    const out = {};
    for (const name of Object.keys(k.r)) {
      out[name] = eqrefToJs(k.r[name], E.proj(ref, E.internStr(strFromJs(name))));
    }
    return out;
  };
  // JS → eqref (a boxed, nested value), by kind.
  const eqrefFromJs = (k, val) => {
    if (typeof k === "string") {
      if (k === "i") return E.boxInt(val);
      if (k === "f") return E.boxNum(val);
      if (k === "b") return E.boxBool(val ? 1 : 0);
      if (k === "s") return strFromJs(val);
      return val;
    }
    if (k.a !== undefined) {
      const ref = E.arrayNew(val.length);
      for (let i = 0; i < val.length; i++) E.arraySet(ref, i, eqrefFromJs(k.a, val[i]));
      return ref;
    }
    if (k.fn !== undefined) {
      // a JS function → a wasm $Clo: needs a JS-side function registry + a host import
      // trampoline; ADR 0014 phase 2 (closure direction 2).
      throw new Error("FFI: marshalling a JS function into wasm is not yet supported (ADR 0014, closure direction 2)");
    }
    // record: recSet each field onto an empty record, keyed by interned label id
    let ref = E.recEmpty();
    for (const name of Object.keys(k.r)) {
      ref = E.recSet(ref, E.internStr(strFromJs(name)), eqrefFromJs(k.r[name], val[name]));
    }
    return ref;
  };
  const isRaw = (k) => k === "i" || k === "f";
  // PureScript FFI foreigns are *curried* (`a => b => c`), so apply one argument at a time —
  // `fn(...xs)` would pass only the first to a curried foreign (a multi-arg foreign like
  // `unfoldrArrayImpl` would return a function, not its result).
  const applyCurried = (fn, xs) => xs.reduce((g, x) => g(x), fn);
  // import direction: wasm calls the JS foreign — args wasm→JS, result JS→wasm
  const wrap = (fn, sig) => (...args) => {
    const xs = args.map((a, i) => (isRaw(sig.params[i]) ? a : eqrefToJs(sig.params[i], a)));
    // an effectful foreign (`{eff:k}` result): applying the value args yields the Effect thunk,
    // which we RUN here (the perform is on the JS side), then marshal the inner result by `k`
    // (ADR 0015). A *nullary* Effect foreign (`Effect a`, no value args, e.g. `random`) IS the
    // thunk, so we must not pre-call it. Unit (undefined) → boxed 0.
    if (sig.result && sig.result.eff !== undefined) {
      const thunk = applyCurried(fn, xs);
      const ran = thunk();
      const k = sig.result.eff;
      if (ran === undefined || ran === null) return E.boxInt(0);
      return isRaw(k) ? ran : eqrefFromJs(k, ran);
    }
    const r = applyCurried(fn, xs);
    return isRaw(sig.result) ? r : eqrefFromJs(sig.result, r);
  };
  // export direction: JS calls the wasm export — args JS→wasm, result wasm→JS
  const wrapExport = (fn, sig) => (...args) => {
    const xs = args.map((a, i) => (isRaw(sig.params[i]) ? a : eqrefFromJs(sig.params[i], a)));
    const r = fn(...xs);
    return isRaw(sig.result) ? r : eqrefToJs(sig.result, r);
  };
  return { strToJs, strFromJs, eqrefToJs, eqrefFromJs, isRaw, applyCurried, wrap, wrapExport };
};
