// Host effectful FFI with module-level state (the e2e observes effect order/count via `readSum`).
let log = [];
export const record = (n) => () => {
  log.push(n);
};
export const readSum = () => log.reduce((a, b) => a + b, 0);
let t = 0;
export const tick = () => ++t;
