// Memoize a function of an `M.Expr` by reference identity (a `WeakMap`), so the
// bound-agnostic free-variable computation visits each shared MIR node at most once
// across all callers (lambda lifting and the lowering's closure conversion both
// re-query it). Keys are GC'd with the expressions, so the cache adds no retention.
export const unsafeMemoExpr = (f) => {
  const cache = new WeakMap();
  return (x) => {
    const hit = cache.get(x);
    if (hit !== undefined) return hit;
    const v = f(x);
    cache.set(x, v);
    return v;
  };
};
