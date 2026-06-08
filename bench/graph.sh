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
# 2. the optimized JS backend (js-es). purs-backend-es optimizes corefn → JS but does
#    not copy FFI modules, so mirror the foreign.js files its output still imports
#    (e.g. `Data.Functor`'s `arrayMap`, now that the benches use the package set) from
#    the spago output. Inlined foreigns (Int arithmetic under `--int-tags`) need none.
purs-backend-es build --corefn-dir bench/output --output-dir bench/output-js-es --int-tags
( cd bench/output && find . -name foreign.js ) | while read -r f; do
  f="${f#./}"; mkdir -p "bench/output-js-es/$(dirname "$f")"; cp "bench/output/$f" "bench/output-js-es/$f"
done
# 3. our wasm backend
node ./bin/index.dev.js build -I ./bench/output -O ./bench/output-wasm -e Bench.Main

cd "$here"
node graph.mjs
# Render only the algorithm benchmarks (graph.mjs's output), which use plot-compare.gp's
# `size  js-naive  js-es  wasm` schema. curry / count-state / count-effect have a DIFFERENT
# dat schema and their own plot templates (rendered by their dedicated *-graph.sh scripts) —
# rendering them here with plot-compare.gp mismaps the columns (e.g. curry's es-ratio would be
# drawn as the wasm line), so skip them.
for dat in results/*.dat; do
  bench="$(basename "$dat" .dat)"
  case "$bench" in
    curry | count-state | count-effect) continue ;;
  esac
  gnuplot -e "datafile='$dat'; outfile='results/$bench.png'; name='$bench'" plot-compare.gp
done
echo "wrote bench/results/*.png"
