#!/usr/bin/env bash
# Build the CountState (State-monad) benchmark on all three backends from the same
# PureScript source, sweep the iteration count, and render the 3-way comparison graph
# (js-naive vs js-es vs wasm, log-log time-vs-n) into bench/results/count-state.png.
# Run inside `nix develop` (spago / node / purs-backend-es / gnuplot on PATH).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.."

# 1. PureScript -> CoreFn + the stock JS backend output (js-naive, in bench/output)
spago build -p bench --output bench/output
# 2. the optimized JS backend (js-es)
purs-backend-es build --corefn-dir bench/output --output-dir bench/output-js-es --int-tags
# 3. our wasm backend (CountState entry; the loader marshals its String result)
node ./purs-wasm/index.dev.js build -I ./bench/output -O ./bench/output-wasm -e CountState

cd "$here"
node count-state.mjs
gnuplot -e "datafile='results/count-state.dat'; outfile='results/count-state.png'" plot-count-state.gp
echo "wrote bench/results/count-state.png"
