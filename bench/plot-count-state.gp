# The CountState (State-monad) sweep on three backends built from the same
# PureScript source. Log-log axes: js-es eliminates the monad to a tight loop
# (~0.5us, scales to large n), while wasm / js-naive keep the abstraction (per-step
# record + closure allocation, O(n) recursion) — ~120x slower and stack-overflowing
# past a few thousand iterations, so those curves stop. Driven by -e variables:
#   datafile  the "size  js-naive-ms  js-es-ms  wasm-ms" data (results/count-state.dat)
#   outfile   the PNG to write
set terminal pngcairo size 760,470 font "sans,11"
set output outfile
set title "CountState: State-monad iterations   (log-log, lower is better)"
set xlabel "iterations (n)"
set ylabel "time per op (ms)"
set grid lc rgb "#dddddd"
set logscale xy
set key top left
set datafile missing "NaN"
plot datafile using 1:2 with linespoints lc rgb "#c0c0c0" lw 2 pt 6 ps 1.1 title "JS (purs backend)", \
     datafile using 1:3 with linespoints lc rgb "#e8a33d" lw 2 pt 4 ps 1.1 title "JS (purs-backend-es)", \
     datafile using 1:4 with linespoints lc rgb "#4072b4" lw 2.5 pt 7 ps 1.2 title "wasm (this backend)"
