#!/usr/bin/env bash
# Build all three backends from the bench sources, sweep each benchmark, and render
# the comparison graphs (js-naive vs js-es vs wasm, time vs input) into
# bench/results/ — the committed PNGs the README embeds. Run inside `nix develop`
# (spago / node / purs-backend-es / gnuplot on PATH).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.."

# 1. PureScript -> CoreFn + the stock JS backend output (js-naive, in ./output)
spago build -p bench --output bench/output
# 2. the optimized JS backend (js-es)
purs-backend-es build --corefn-dir bench/output --output-dir bench/output-js-es --int-tags
# 3. our wasm backend
node ./bin/index.dev.js build -I ./bench/output -O ./bench/output-wasm -e Bench.Main

cd "$here"
node graph.mjs
for dat in results/*.dat; do
  bench="$(basename "$dat" .dat)"
  gnuplot -e "datafile='$dat'; outfile='results/$bench.png'; name='$bench'" plot-compare.gp
done
echo "wrote bench/results/*.png"
