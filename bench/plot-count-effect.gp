# The CountEffect (Effect-monad, mutually-recursive instance dictionaries) sweep on
# three backends built from the same PureScript source. Log-log axes: wasm collapses
# the cyclic-dict Effect do-block to a constant-stack loop, while js-naive keeps the
# bind chain (O(n) recursion) and overflows past a few thousand iterations, so its
# curve stops. Driven by -e variables:
#   datafile  the "size  js-naive-ms  js-es-ms  wasm-ms" data (results/count-effect.dat)
#   outfile   the PNG to write
set terminal pngcairo size 760,470 font "sans,11"
set output outfile
set title "CountEffect: Effect-monad iterations   (log-log, lower is better)"
set xlabel "iterations (n)"
set ylabel "time per op (ms)"
set grid lc rgb "#dddddd"
set logscale xy
set key top left
set datafile missing "NaN"
plot datafile using 1:2 with linespoints lc rgb "#c0c0c0" lw 2 pt 6 ps 1.1 title "JS (purs backend)", \
     datafile using 1:3 with linespoints lc rgb "#e8a33d" lw 2 pt 4 ps 1.1 title "JS (purs-backend-es)", \
     datafile using 1:4 with linespoints lc rgb "#4072b4" lw 2.5 pt 7 ps 1.2 title "wasm (this backend)"
