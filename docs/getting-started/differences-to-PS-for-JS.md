# Differences from JavaScript-backend PureScript

PureScript is fundamentally a backend-agnostic language, but that does not mean you can
ignore the backend entirely. When you write PureScript for the JS backend, you are, more or
less, always aware of what JavaScript it compiles to.

The same is true for the Wasm backend. To get the most out of purs-wasm's aggressive
optimizations and compile your PureScript app to blazing-fast wasm, there are a few
important differences from JS-backend PureScript that you should know.

## Avoid Writing Foreign Modules for the Sake of Performance

PureScript lets you depend on JavaScript code through the FFI. In JS-backend PureScript,
the FFI seems to be used for two distinct purposes:

1. To perform JavaScript-native side effects — e.g. `console.log`, `Math.random`.
2. For performance.

The first purpose cannot be expressed without the FFI, and it is equally justified in
Wasm-backend PureScript.

The second purpose is different: the same behaviour could be written in pure PureScript, but
JavaScript can express a faster version. A typical example is code that mutates an `Array`
destructively while iterating with a for-loop.

In Wasm-backend PureScript, the second purpose is usually ineffective — or even
counterproductive.

For example, the JS-backend `Functor` instance for `Array` implements `map` by calling the
supplied function inside a loop. That closure-call cost is not negligible, and it is exactly
what purs-wasm's **Higher-order Specialization** optimization is meant to eliminate. But the
FFI is an *insurmountable barrier* to the optimizer: a `foreign import` is, to purs-wasm,
merely an opaque reference whose body it cannot see. As a result, an FFI into a faithful
wasm port of `mapArray` pays a closure allocation on every iteration.

**Turning a function you could have written in PureScript into an FFI throws away every
opportunity for purs-wasm to optimize it!**

To address this, we ship a set of curated packages reimplemented for wasm (**ulib**)
alongside purs-wasm; some core packages are resolved to their ulib counterparts at build
time. For instance, the ulib `Data.Array` defines its `Functor` instance like this:

```purs
import Wasm.Array as WA
import Wasm.Int as WI

arrayMap :: forall a b. (a -> b) -> Array a -> Array b
arrayMap f xs = go 0 (WA.unsafeNew n)
  where
  n = WA.length xs
  go i out = if WI.eq i n then out else go (WI.add i 1) (WA.unsafeSet out i (f (WA.unsafeIndex xs i)))
```

Note that it depends on the `Wasm.Array` and `Wasm.Int` modules instead of an FFI. `Wasm.*`
are modules from the `wasm-base` package that expose a low-level API over the Wasm-GC
runtime representation.

Application developers rarely need to use wasm-base directly. If you are a library author,
you may need to write low-level code that touches the Wasm-GC runtime representation
directly; in that case, **never write an FFI — use the `Wasm.*` modules instead.**

## Uncurrying: Probably Not Worth It

Because every function in PureScript is curried, a seemingly two-argument function such as

```purs
add :: Int -> Int -> Int
```

is really a one-argument function returning a function, so partial application is expressed
naturally. This is intuitive and pleasant for functional programmers, but generating a
function per applied argument can affect performance.

So, in performance-sensitive spots, people often sacrifice the benefits of currying and
write ugly uncurried functions (especially library authors):

```purs
add :: Fn2 Int Int Int
```

On the Wasm backend, the situation changes completely. In purs-wasm, curried and uncurried
functions compile to the *same* representation (`mkFnN` = identity, `runFnN` = saturated
application), so currying creates no intermediate closures. This means you get the
performance of an uncurried function while keeping the function curried.

In other words, when compiling with purs-wasm, **you do not need to sacrifice readability
for performance by writing uncurried functions!**

![Curry vs. uncurry: curried/uncurried time ratio across backends — flat ~1.0 on wasm](https://purs-wasm.github.io/documentation/images/bench/curry.png)

## Effect is Stack-safe

As is well known, the `Effect` monad in PureScript is stack-unsafe: every `>>=` consumes
call stack. Recursion over functions returning an `Effect` is therefore generally unsafe,
and people work around it with `MonadRec` (at some readability cost) or by using `Aff`
instead of `Effect` (yes, `Aff` is always stack-safe).

> **Note** `Aff`, however, is not supported by purs-wasm.

purs-wasm's optimizer uses a technique we call *Generalized Effect Reflection /
Impurification* to compile an `Effect` into a plain nullary thunk that preserves effect
semantics. As a result it becomes a target for ordinary function optimizations (inlining /
specialization / TCE), and `Effect`'s stack safety is preserved.

This is backed by the CountEffect benchmark — the wasm curve runs the full sweep flat while
the JS backends overflow:

![CountEffect: Effect-monad iterations across backends (log-log)](https://purs-wasm.github.io/documentation/images/bench/count-effect.png)

## String is an Array of UTF-8 Code Units

Strings in PureScript are UTF-16 encoded. This is a direct consequence of JavaScript strings
being UTF-16, and we concluded that we need not follow suit on wasm. The string runtime
representation is therefore **(intentionally diverging from JS-backend PureScript) UTF-8
encoded**. This has the non-obvious effect that code using `Data.String.CodeUnits` behaves
differently when compiled to wasm versus JS.

> **Note** Among scalar values, only `String` diverges in representation; `Int` / `Char` /
> `Number` keep the same semantics as the JS backend (in particular, `Int`'s 32-bit wrapping
> matches JS).

## Dual Support of FFI

In JS-backend PureScript, the FFI is the mechanism for calling JavaScript code from
PureScript. In Wasm-backend PureScript, the FFI is primarily an interface to code defined in
wasm, but JavaScript-defined code can also be called from PureScript through the FFI (with
some restrictions). This lets you migrate your existing PureScript app's codebase from the
JS target to the wasm target incrementally.

> **Note**
>
> - For the JS fallback in FFI module resolution, see *Module Resolution and `ulib`*.
> - For the restrictions on the JS FFI, see *Performance and Limitations*.
