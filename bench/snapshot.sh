#!/usr/bin/env bash
# Build the benchmarks, sweep each across its input sizes, and store the results
# (JSON + one gnuplot PNG per benchmark: time vs input) in a timestamped
# bench/snapshots/<datetime>/ directory, then repoint snapshots/latest at it (so
# README and other docs can reference a stable path). Run inside `nix develop` so
# spago / node / gnuplot are on PATH.
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

# point snapshots/latest at the new snapshot (relative target, so it is portable
# and git-trackable). -n: don't descend into the existing symlink's directory.
ln -sfn "$stamp" snapshots/latest

echo "snapshot -> bench/$dir  (snapshots/latest now points here)"
