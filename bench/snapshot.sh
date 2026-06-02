#!/usr/bin/env bash
# Build the benchmarks, sweep each across its input sizes, and store the results
# (JSON + one gnuplot PNG per benchmark: time vs input) in a timestamped
# bench/snapshots/<datetime>/ directory — the dev workflow for tracking an
# optimization against the `npm run base` baseline. (The README's published
# comparison graphs are a separate committed artifact: `npm run graph`.) Run inside
# `nix develop` so spago / node / gnuplot are on PATH.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.."

spago build -p bench --output bench/output
node ./bin/index.dev.js build -I ./bench/output -O ./bench/output-wasm -e Bench.Main

cd "$here"
stamp="$(date +%Y%m%d-%H%M%S)"
dir="snapshots/$stamp"
mkdir -p "$dir"
node run.mjs "$dir"

for dat in "$dir"/*.dat; do
  bench="$(basename "$dat" .dat)"
  gnuplot -e "datafile='$dat'; outfile='$dir/$bench.png'; name='$bench'; stamp='$stamp'" plot-one.gp
done

echo "snapshot -> bench/$dir"
