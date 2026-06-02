# One benchmark's time-vs-input curves: baseline (set by `npm run base`) overlaid
# with the current snapshot. Driven by -e variables:
#   datafile  the "size baseline-ms current-ms" data (<name>.dat)
#   outfile   the PNG to write
#   name      the benchmark name (title)
#   stamp     the snapshot timestamp (title)
set terminal pngcairo size 720,440 font "sans,11"
set output outfile
set title sprintf("%s   —   %s   (lower is better)", name, stamp)
set xlabel "input size"
set ylabel "time per op (ms)"
set grid lc rgb "#dddddd"
set yrange [0:*]
set key top left
set datafile missing "NaN"
plot datafile using 1:2 with linespoints lc rgb "#bbbbbb" lw 2 pt 6 ps 1.1 title "baseline", \
     datafile using 1:3 with linespoints lc rgb "#4072b4" lw 2 pt 7 ps 1.1 title "current"
