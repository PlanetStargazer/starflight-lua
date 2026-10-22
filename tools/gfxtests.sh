#!/bin/bash
# forced-thread comparisons of the graphics primitives (oracle = original driver code)
SNAP=${SNAP:-/var/tmp/snap_port}
t() { printf "%-50s " "$1"; tools/forced.sh $SNAP "$2" ${3:-3000000} | head -1; }
t "LPLOT"       "7 COLOR ! 3 4 LPLOT 8 COLOR ! 159 199 LPLOT 12 COLOR ! 0 0 LPLOT 15 COLOR ! 77 100 LPLOT 1 COLOR ! 5 5 LPLOT"
t "LXPLOT"      "9 COLOR ! 3 4 LXPLOT 9 COLOR ! 3 4 LXPLOT 6 COLOR ! 100 100 LXPLOT"
t "SQLPLOT"     "5 COLOR ! 30 40 SQLPLOT 11 COLOR ! 159 198 SQLPLOT"
t "LLINE diag"  "4 COLOR ! 10 10 100 60 LLINE"
t "LLINE steep" "6 COLOR ! 20 190 40 5 LLINE"
t "LLINE horiz" "2 COLOR ! 10 80 150 80 LLINE"
t "LLINE vert"  "3 COLOR ! 70 10 70 150 LLINE"
t "LLINE rev"   "10 COLOR ! 150 150 10 20 LLINE"
t "BFILL"       "13 COLOR ! BFILL"
