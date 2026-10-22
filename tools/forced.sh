#!/bin/bash
# tools/forced.sh <snapdir> "<thread tokens>" [max_events] : run a forced thread in oracle and VM and compare
SNAP=$1; TH="$2"; MAX=${3:-2000000}
O=${LOGDIR:-/var/tmp}
SNAP=$SNAP THREAD="$TH" luajit tools/oracle.lua $O/oracle.log $MAX "" ${EVERY:-20000} >/dev/null
SNAP=$SNAP THREAD="$TH" luajit tools/vmlog.lua $O/vm.log $MAX "" ${EVERY:-20000} >/dev/null
python3 tools/cmplog.py $O/oracle.log $O/vm.log
