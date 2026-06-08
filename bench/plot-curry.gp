# The curry-vs-uncurry tax on three backends built from the same PureScript source.
# y = curried / uncurried time: ~1.0 means currying is free, >1.0 means the backend
# pays a per-call closure-allocation tax for curried application. wasm hugs 1.0 *by
# construction* (mkFnN = identity, runFnN = saturated apply — curried ≡ uncurried). In
# JS it depends on the codegen + JIT: V8's escape analysis frees the stock purs
# backend's curried closures (~1.0), but purs-backend-es still pays ~3x. So the wasm
# guarantee is robust; the JS outcome is not. Driven by:
#   datafile  the "size  wasm-ratio  naive-ratio  es-ratio" data (results/curry.dat)
#   outfile   the PNG to write
set terminal pngcairo size 760,470 font "sans,11"
set output outfile
set title "Curry tax: curried / uncurried time   (log-x, lower is better; 1.0 = free)"
set xlabel "iterations (n)"
set ylabel "curried / uncurried time"
set grid lc rgb "#dddddd"
set logscale x
set yrange [0:3.5]
set key top left
# reference: currying is free
set arrow from graph 0, first 1 to graph 1, first 1 nohead lc rgb "#999999" dt 2 lw 1.5
plot datafile using 1:3 with linespoints lc rgb "#c0c0c0" lw 2 pt 6 ps 1.1 title "JS (purs backend)", \
     datafile using 1:4 with linespoints lc rgb "#e8a33d" lw 2 pt 4 ps 1.1 title "JS (purs-backend-es)", \
     datafile using 1:2 with linespoints lc rgb "#4072b4" lw 2.5 pt 7 ps 1.2 title "wasm (this backend)"
