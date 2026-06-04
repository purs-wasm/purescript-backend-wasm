// Host imports + spy for the host-effectful-FFI e2e (ADR 0015). `record` is the real
// curried Effect foreign `n => () => …`; the marshalling glue runs the returned thunk
// on the JS side, so the push happens exactly when wasm performs it. `readSpy`/`resetSpy`
// let the test observe the order and count of the runs.
let spy = [];
export const recordImports = {
  HostEff: {
    record: (n) => () => { spy.push(n); },
    // the real console.log shape (String -> Effect Unit); the glue runs the `()`
    log: (s) => () => { console.log(s); },
    // nullary Effect foreign (the `random` shape): the foreign IS the `() => value` thunk
    tick: () => 99,
  },
};
export const resetSpy = () => { spy = []; };
export const readSpy = () => spy.join(",");
