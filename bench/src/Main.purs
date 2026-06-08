-- | Benchmark programs for the wasm backend. Each entry is an `Int -> Int` (the
-- | i32 export ABI) taking a workload size and returning a checksum / result, so the
-- | runner can both time it and sanity-check correctness.
-- |
-- | These use the **package set** (`Data.List` / `Data.Array`) rather than hand-rolled
-- | ADTs — idiomatic PureScript, which also exercises the curated `ulib` foreigns
-- | (e.g. `Data.Array`'s `map` / `foldl`) end-to-end. Only `fib` / `sumLoop` stay pure
-- | `Int`, and the binary tree is a local ADT (the package set has no tree type).
module Bench.Main where

import Prelude

import Data.Array as Array
import Data.Foldable (foldl)
import Data.List (List(..), (:))
import Data.List as List
import Wasm.Array as WA

-- 1. fib — tree recursion + Int arithmetic.
fib :: Int -> Int
fib n = if n < 2 then n else fib (n - 1) + fib (n - 2)

-- 2. sumLoop — a tight numeric loop whose `+` / `*` / `>` all go through Prelude
--    dictionaries (the prime target for dictionary elimination). Tail-recursive.
sumLoop :: Int -> Int
sumLoop n = go 0 1
  where
  go acc i = if i > n then acc else go (acc + i * i) (i + 1)

-- 3. quicksort — `Data.List`: `filter` predicate closures, `Ord` comparisons, `<>`
--    append, heavy Cons allocation. Returns 1 iff the result is sorted.
quicksort :: List Int -> List Int
quicksort = case _ of
  Nil -> Nil
  p : rest ->
    quicksort (List.filter (_ <= p) rest) <> (p : quicksort (List.filter (_ > p) rest))

buildList :: Int -> Int -> List Int
buildList k s = if k == 0 then Nil else s : buildList (k - 1) (s * 1103515245 + 12345)

isSorted :: List Int -> Boolean
isSorted = case _ of
  Nil -> true
  _ : Nil -> true
  x : y : rest -> if x <= y then isSorted (y : rest) else false

qsort :: Int -> Int
qsort n = if isSorted (quicksort (buildList n 1)) then 1 else 0

-- 4. N-Queens — backtracking; the placed columns are a `Data.List`. Returns the
--    number of solutions on an n×n board.
nqueens :: Int -> Int
nqueens n = go Nil 0
  where
  go placed row = if row == n then 1 else tryCols 0 placed row
  tryCols col placed row =
    if col == n then 0
    else placeAt col placed row + tryCols (col + 1) placed row
  placeAt col placed row =
    if safe col placed 1 then go (col : placed) (row + 1) else 0
  safe col placed dist = case placed of
    Nil -> true
    c : rest ->
      if c == col || c == col - dist || c == col + dist then false
      else safe col rest (dist + 1)

-- 5/6. Binary tree traversals. The tree is a local ADT (no tree in the package set);
--      the BFS queue is a `Data.List`.
data Tree = Leaf | Node Int Tree Tree

mkTree :: Int -> Int -> Tree
mkTree depth v = if depth == 0 then Leaf else Node v (mkTree (depth - 1) (v + v)) (mkTree (depth - 1) (v + v + 1))

dfsSum :: Tree -> Int
dfsSum = case _ of
  Leaf -> 0
  Node v l r -> v + dfsSum l + dfsSum r

-- depth-first traversal of a balanced tree of the given depth; sums node values.
bintreeDfs :: Int -> Int
bintreeDfs depth = dfsSum (mkTree depth 1)

bfsSum :: List Tree -> Int
bfsSum = case _ of
  Nil -> 0
  t : rest -> case t of
    Leaf -> bfsSum rest
    Node v l r -> v + bfsSum (rest <> (l : r : Nil))

-- breadth-first traversal (list-queue) of a balanced tree of the given depth.
bintreeBfs :: Int -> Int
bintreeBfs depth = bfsSum (mkTree depth 1 : Nil)

-- 7a. mapFold — higher-order processing over a `Data.List`. `map` / `foldl` here are
--     **pure-PureScript** class methods (`functorList` / `foldableList`), so the optimizer
--     can specialize the closures away into a direct, non-allocating loop.
mapFold :: Int -> Int
mapFold iters = loop iters 0
  where
  base = map (\x -> x + 1) (List.range 1 2000)
  loop k acc = if k == 0 then acc else loop (k - 1) (foldl (\a x -> a + x) acc base)

-- 7b. mapFoldArray — the same computation over a `Data.Array`. Here `map` (the `ulib`
--     `arrayMap` foreign) and `foldl` (`foldlArray`) are **foreign** higher-order
--     functions: the optimizer cannot specialize the closure *into* a foreign, so each
--     element is applied via `call_ref` on a boxed `eqref`. The contrast with `mapFold`
--     measures the cost of foreign-backed library HOFs (a current optimization frontier).
mapFoldArray :: Int -> Int
mapFoldArray iters = loop iters 0
  where
  base = map (\x -> x + 1) (Array.range 1 2000)
  loop k acc = if k == 0 then acc else loop (k - 1) (foldl (\a x -> a + x) acc base)

-- `waMap` / `waFoldl` — the higher-order array combinators, written as ordinary PureScript
-- over `Wasm.Array`'s first-order primitives (so their closures **specialize**, ADR 0027 — no
-- per-element `call_ref`). NOTE (ADR 0026): these are the **library layer** and belong in the
-- repositioned `ulib`'s `Data.Array` (PureScript over `Wasm.Array`), NOT in `Wasm.Array` itself
-- (first-order primitives only). They live here only as a PoC stand-in until `ulib`'s
-- `Data.Array` is repositioned to shadow the registry one; then idiomatic `Data.Array.map` /
-- `foldl` get this directly. Being above `Prelude`, they use ordinary `+` / `>=`.
waMap :: forall a b. (a -> b) -> Array a -> Array b
waMap f xs = go 0 (WA.unsafeNew n)
  where
  n = WA.length xs
  go i out = if i >= n then out else go (i + 1) (WA.unsafeSet out i (f (WA.unsafeIndex xs i)))

waFoldl :: forall a b. (b -> a -> b) -> b -> Array a -> b
waFoldl f z xs = go 0 z
  where
  n = WA.length xs
  go i acc = if i >= n then acc else go (i + 1) (f acc (WA.unsafeIndex xs i))

-- 7c. mapFoldWasmArray — identical computation to `mapFoldArray`, but `map` / `foldl` are the
--     PureScript-over-`Wasm.Array` combinators above: the closures **specialize** (ADR
--     0026 + 0027) into a direct loop — no per-element `call_ref`. The contrast with
--     `mapFoldArray` (foreign `ulib` HOFs) isolates the win from moving the higher-order layer
--     out of foreign `.wat` and into PureScript.
mapFoldWasmArray :: Int -> Int
mapFoldWasmArray iters = loop iters 0
  where
  base = waMap (\x -> x + 1) (Array.range 1 2000)
  loop k acc = if k == 0 then acc else loop (k - 1) (waFoldl (\a x -> a + x) acc base)