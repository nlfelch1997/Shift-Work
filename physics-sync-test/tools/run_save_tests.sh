#!/bin/bash
# WEEK 24 — runs every save/load test in order (tools/save_test.gd). Each
# solo phase is a separate Godot process: a real quit and relaunch, reading
# the file the previous process wrote.
#   GODOT=/path/to/godot tools/run_save_tests.sh
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
SAVE="--save-file=user://save_test/save.json"
run() { echo "=== $*"; "$GODOT" --headless --path . --script res://tools/save_test.gd -- "$@" 2>&1 | grep -E "^(PASS|FAIL|RESULT)|\[Save\]|SCRIPT ERROR|ERROR:" ; return "${PIPESTATUS[0]}"; }
status=0
# OCT 2026 PHASE 2: 7 (relaunch past the old week) runs between 2 and 3, and
# 3/4 take the debug --endless route into the untouched Endless Mode.
for p in 1 2 7; do run --server $SAVE --prep-seconds=900 --test=save --phase=$p || status=1; done
for p in 3 4; do run --server $SAVE --endless --prep-seconds=900 --test=save --phase=$p || status=1; done
run --server $SAVE --prep-seconds=900 --test=save --phase=5 || status=1
run --server --day=3 --prep-seconds=900 --test=save --phase=6 || status=1
for t in net-save net-save-story; do
  echo "=== $t (host + client)"
  "$GODOT" --headless --path . --script res://tools/save_test.gd -- --server --port=8931 --prep-seconds=900 --save-file=user://save_test/host.json --test=$t > /tmp/sw_save_host.log 2>&1 &
  hp=$!
  "$GODOT" --headless --path . --script res://tools/save_test.gd -- --client --connect-port=8931 --save-file=user://save_test/client.json --test=$t > /tmp/sw_save_client.log 2>&1
  cs=$?
  wait $hp; hs=$?
  echo "--- host"; grep -E "^(PASS|FAIL|RESULT)|\[Save\]|SCRIPT ERROR|ERROR:" /tmp/sw_save_host.log
  echo "--- client"; grep -E "^(PASS|FAIL|RESULT)|SCRIPT ERROR|ERROR:" /tmp/sw_save_client.log
  [ $hs -eq 0 ] && [ $cs -eq 0 ] || status=1
done
echo "ALL: $([ $status -eq 0 ] && echo OK || echo FAILED)"
exit $status
