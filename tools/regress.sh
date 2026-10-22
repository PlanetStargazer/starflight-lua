#!/bin/bash
# Full regression: forced primitive/graphics/overlay tests plus a few fuzz runs, oracle vs Lua VM.
# usage: tools/regress.sh [snapdir]   (creates the snapshot if missing)
SNAP=${1:-/var/tmp/snap_port}
if [ ! -f $SNAP/state.lua ]; then
  SAVESNAP=$SNAP luajit tools/vmlog.lua /var/tmp/x.log 30000000 "5 ENTER 2 20*SP RIGHT RIGHT ENTER LEFT RIGHT RIGHT ENTER" 1000000 > /dev/null
fi
echo "== primitives";  python3 tools/primtests.py $SNAP | grep -v identical
echo "== graphics";    python3 tools/gfxtests2.py $SNAP | grep -v identical
echo "== overlays";    python3 tools/ovtests.py $SNAP | grep -v identical
echo "== fuzz";        tools/fuzzbatch.sh 1 3 400 30000000
echo "== done"
