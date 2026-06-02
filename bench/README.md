# Benchmarks

A baseline for measuring backend optimizations. Each entry in `Bench.Main` is an
`Int -> Int` (the i32 export ABI) taking a workload size and returning a checksum,
so the runner both times it and confirms the result is unchanged across a
before/after comparison. Every benchmark is **self-contained** (user-defined ADTs +
`Prelude` only — no external packages), so it runs on the current backend.

| benchmark    | stresses                                                        |
| ------------ | -------------------------------------------------------------- |
| `fib`        | tree recursion + `Int` arithmetic                              |
| `sumLoop`    | a tail loop whose `+` / `*` / `>` go through Prelude dictionaries (prime target for dictionary elimination) |
| `qsort`      | list quicksort: predicate closures, `Ord` comparisons, `Cons` allocation |
| `nqueens`    | backtracking; mutual local recursion                          |
| `bintreeDfs` | depth-first traversal of a balanced tree                      |
| `bintreeBfs` | breadth-first traversal (list queue) of a tree                |

## Running

```sh
cd bench
npm run base       # build + measure → results/baseline.json (the reference; run once)
npm run snapshot   # build + measure + per-benchmark graph (baseline overlaid with now)
```

Each benchmark is **swept across a range of input sizes** (configured in `run.mjs`),
timing every point — so the result is a time-vs-input *curve* per benchmark, not a
single number. `npm run base` records, per benchmark, every `{ size, nsPerOp, result }`
point to `results/baseline.json` (tracked) — the canonical before-optimization state;
run it once, before optimizing. Timing is adaptive (warm up, calibrate reps, min over
several trials); requires Node 22+ (Wasm GC + tail calls).

`npm run snapshot` (build + measure + charts) writes `snapshots/<datetime>/` with
`results.json` and, **per benchmark, a `<name>.dat` and a `<name>.png`** — a line
graph of time per op (y) against input size (x), with the **baseline overlaid** (gray)
against the current run (blue), so the improvement is visible at a glance; the console
also prints the speedup at the largest input. Rendered by **gnuplot** (provided by the
nix devShell). It then repoints **`snapshots/latest`** (a committed symlink) at the new
snapshot, so docs can reference a stable path, e.g.
`![fib](bench/snapshots/latest/fib.png)`. Run inside `nix develop` so `gnuplot` is
on `PATH`.

Snapshots are tracked (so `latest`'s images render in the README); commit the ones
you want as a perf history and prune the rest.

## Notes

- Compiled with the default pipeline (codegen + Binaryen `optimize()`), so the
  numbers are *our* baseline on top of Binaryen — the delta a high-level
  optimization layer (ADR 0005) adds is what re-running will show. The current
  baseline is deliberately slow (dictionary / closure / allocation overhead): that
  is the headroom.
- The whole suite is one wasm bundle (`wasmBytes` is the bundle size); per-benchmark
  sizes can come later if useful.
