# One benchmark's time-vs-input curves for the three backends built from the same
# PureScript source. Driven by -e variables:
#   datafile  the "size  js-naive-ms  js-es-ms  wasm-ms" data (results/<name>.dat)
#   outfile   the PNG to write
#   name      the benchmark name (title)
set terminal pngcairo size 720,440 font "sans,11"
set output outfile
set title sprintf("%s   (lower is better)", name)
set xlabel "input size"
set ylabel "time per op (ms)"
set grid lc rgb "#dddddd"
set yrange [0:*]
set key top left
set datafile missing "NaN"
plot datafile using 1:2 with linespoints lc rgb "#c0c0c0" lw 2 pt 6 ps 1.1 title "JS (purs backend)", \
     datafile using 1:3 with linespoints lc rgb "#e8a33d" lw 2 pt 4 ps 1.1 title "JS (purs-backend-es)", \
     datafile using 1:4 with linespoints lc rgb "#4072b4" lw 2.5 pt 7 ps 1.2 title "wasm (this backend)"
