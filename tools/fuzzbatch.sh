#!/bin/bash
# tools/fuzzbatch.sh first_seed last_seed length max_events : run oracle-vs-VM comparisons, summarise
for seed in $(seq $1 $2); do
  K=$(python3 tools/fuzz.py $seed $3)
  O=/var/tmp/fz$seed
  luajit tools/oracle.lua $O.o.log $4 "$K" 50000 >/dev/null
  luajit tools/vmlog.lua $O.v.log $4 "$K" 50000 >/dev/null
  echo "seed $seed: $(python3 tools/cmplog.py $O.o.log $O.v.log | head -1)  ($(tail -1 $O.o.log | cut -c1-60))"
  rm -f $O.o.log $O.v.log
done
