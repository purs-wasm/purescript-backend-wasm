#!/usr/bin/env bash
# Build the CountEffect (Effect-monad, cyclic instance dictionaries) benchmark on all
# three backends from the same PureScript source, sweep the iteration count, and render
# the 3-way comparison graph (js-naive vs js-es vs wasm, log-log time-vs-n) into
# bench/results/count-effect.png. Run inside `nix develop` (spago / node /
# purs-backend-es / gnuplot on PATH); the `bin` CLI must be built (output/Main).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.."

# 1. PureScript -> CoreFn + the stock JS backend output (js-naive, in bench/output)
spago build -p bench --output bench/output
# 2. the optimized JS backend (js-es)
purs-backend-es build --corefn-dir bench/output --output-dir bench/output-js-es --int-tags
# 3. our wasm backend (CountEffect entry)
node ./bin/index.dev.js build -I ./bench/output -O ./bench/output-wasm -e CountEffect

cd "$here"
node count-effect.mjs
gnuplot -e "datafile='results/count-effect.dat'; outfile='results/count-effect.png'" plot-count-effect.gp
echo "wrote bench/results/count-effect.png"
