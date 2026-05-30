export const instantiate = (bytes) => () => {
  const module = new WebAssembly.Module(bytes);
  return new WebAssembly.Instance(module, {});
};

export const callI32x2 = (instance) => (name) => (a) => (b) => () =>
  instance.exports[name](a, b);
