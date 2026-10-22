#!/bin/bash
# tools/cmp.sh max_events "keys"  : compare oracle and VM traces (logs go to /var/tmp, never /tmp which is RAM)
O=${LOGDIR:-/var/tmp}
luajit tools/oracle.lua $O/oracle.log $1 "$2" ${EVERY:-50000} >/dev/null
luajit tools/vmlog.lua $O/vm.log $1 "$2" ${EVERY:-50000} >/dev/null
python3 tools/cmplog.py $O/oracle.log $O/vm.log
