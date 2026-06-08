#!/usr/bin/env bash
# Build the curry-vs-uncurry benchmark on all three backends from the same PureScript
# source, sweep the iteration count, and render the currying-tax graph (curried /
# uncurried time per backend) into bench/results/curry.png. Run inside `nix develop`
# (spago / node / purs-backend-es / gnuplot on PATH).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.."

# 1. PureScript -> CoreFn + the stock JS backend output (js-naive, in bench/output)
spago build -p bench --output bench/output
# 2. the optimized JS backend (js-es). purs-backend-es does not copy FFI modules, so
#    mirror the foreign.js files its output still imports (e.g. Data.Array's unsafeIndex)
#    from the spago output.
purs-backend-es build --corefn-dir bench/output --output-dir bench/output-js-es --int-tags
( cd bench/output && find . -name foreign.js ) | while read -r f; do
  f="${f#./}"; mkdir -p "bench/output-js-es/$(dirname "$f")"; cp "bench/output/$f" "bench/output-js-es/$f"
done
# 3. our wasm backend (BenchCurry entry)
node ./bin/index.dev.js build -I ./bench/output -O ./bench/output-wasm -e BenchCurry

cd "$here"
node curry.mjs
gnuplot -e "datafile='results/curry.dat'; outfile='results/curry.png'" plot-curry.gp
echo "wrote bench/results/curry.png"
