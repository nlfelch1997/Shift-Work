#!/bin/bash
# WEEK 27 — runs every juice test (tools/juice_test.gd): solo Day 7, the
# endless medal flow, a 3-player co-op session, and (if xvfb-run exists) the
# rendered load test.
#   GODOT=/path/to/godot tools/run_juice_tests.sh
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
FILTER="^(PASS|FAIL|RESULT|INFO|PERF|PEAKS|JUICE|SHOT)|SCRIPT ERROR|ERROR:"
run() { echo "=== $*"; "$GODOT" --headless --path . --script res://tools/juice_test.gd -- "$@" 2>&1 | grep -E "$FILTER"; return "${PIPESTATUS[0]}"; }
status=0
run --server --day=7 --no-save --test=juice || status=1
run --server --day=7 --no-save --test=juice-endless || status=1
echo "=== net-juice (host + 2 clients)"
"$GODOT" --headless --path . --script res://tools/juice_test.gd -- --server --port=8941 --day=7 --no-save --players=3 --test=net-juice > /tmp/sw_juice_host.log 2>&1 &
hp=$!
sleep 2
"$GODOT" --headless --path . --script res://tools/juice_test.gd -- --client --connect-port=8941 --no-save --test=net-juice > /tmp/sw_juice_c1.log 2>&1 &
c1=$!
"$GODOT" --headless --path . --script res://tools/juice_test.gd -- --client --connect-port=8941 --no-save --test=net-juice > /tmp/sw_juice_c2.log 2>&1
c2s=$?
wait $c1; c1s=$?
wait $hp; hs=$?
echo "--- host"; grep -E "$FILTER" /tmp/sw_juice_host.log
for c in c1 c2; do echo "--- client $c"; grep -E "^(JUICE|RESULT)|SCRIPT ERROR|ERROR:" /tmp/sw_juice_$c.log; done
[ $hs -eq 0 ] && [ $c1s -eq 0 ] && [ $c2s -eq 0 ] || status=1
if command -v xvfb-run >/dev/null; then
  echo "=== juice-perf (rendered, xvfb)"
  xvfb-run -a "$GODOT" --path . --script res://tools/juice_test.gd -- --server --day=7 --no-save --test=juice-perf 2>&1 | grep -E "$FILTER"
  [ "${PIPESTATUS[0]}" -eq 0 ] || status=1
fi
echo "ALL: $([ $status -eq 0 ] && echo OK || echo FAILED)"
exit $status
