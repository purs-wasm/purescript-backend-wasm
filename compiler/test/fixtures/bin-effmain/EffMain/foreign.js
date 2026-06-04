export const emit = (n) => () => { (globalThis.__effmain ??= []).push(n); };
