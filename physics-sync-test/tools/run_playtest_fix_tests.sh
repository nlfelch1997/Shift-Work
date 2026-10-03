#!/bin/bash
# OCT 2026 OUTSIDE-PLAYTEST FIXES — runs every test in tools/playtest_fixes_test.gd:
# the practice shift (solo, skip, co-op), trash pickup pay + popups, the
# forgiving pickup radius, shelf stock vs bumps (solo + 3-player co-op) and
# the disruptive-customer rate (Days 2/5/7 + a 600s shift, solo + 3-player
# co-op). --fixed-fps 60 runs the sims faster than real time.
#   GODOT=/path/to/godot tools/run_playtest_fix_tests.sh
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
FILTER="^(PASS|FAIL|RESULT|DISRUPTIVE|PRACTICE|PICKUP|TRASH|SHOT)|SCRIPT ERROR|ERROR:"
T="--script res://tools/playtest_fixes_test.gd --"
run() { echo "=== $*"; "$GODOT" --headless --fixed-fps 60 --path . $T "$@" 2>&1 | grep -E "$FILTER"; return "${PIPESTATUS[0]}"; }
status=0
run --server --no-save --practice --test=practice || status=1
run --server --no-save --practice --test=practice-skip || status=1
run --server --day=2 --no-save --test=trash || status=1
run --server --day=1 --no-save --test=pickup || status=1
run --server --day=3 --no-save --test=shelf || status=1
for d in 2 5 7; do run --server --day=$d --no-save --test=disruptive || status=1; done
run --server --day=3 --no-save --test=disruptive --long || status=1
# Co-op: host + N-1 clients, each its own process (and its own player).
net() { # net <test> <port> <clients> <host args...>
  local t=$1 port=$2 n=$3; shift 3
  echo "=== $t (host + $n client(s))"
  export SW_NET_DIR="user://net_$t/"
  "$GODOT" --headless --fixed-fps 60 --path . $T --server --port=$port --players=$((n + 1)) --no-save --test=$t "$@" > /tmp/sw_pf_host.log 2>&1 &
  local hp=$!
  sleep 2
  local pids=()
  for i in $(seq 1 $n); do
    "$GODOT" --headless --fixed-fps 60 --path . $T --client --connect-port=$port --no-save --test=$t > /tmp/sw_pf_c$i.log 2>&1 &
    pids+=($!)
  done
  wait $hp; local hs=$?
  local cs=0
  for p in "${pids[@]}"; do wait $p || cs=1; done
  echo "--- host"; grep -E "$FILTER" /tmp/sw_pf_host.log
  for i in $(seq 1 $n); do echo "--- client $i"; grep -E "$FILTER" /tmp/sw_pf_c$i.log; done
  [ $hs -eq 0 ] && [ $cs -eq 0 ] || status=1
}
net net-practice 8961 1 --practice
net net-shelf 8962 2 --day=3
net net-disruptive 8963 2 --day=2
net net-disruptive 8964 2 --day=7
if command -v xvfb-run >/dev/null; then
  echo "=== practice (rendered, xvfb — frames in user://hazard_shots/)"
  xvfb-run -a "$GODOT" --path . $T --server --no-save --practice --test=practice 2>&1 | grep -E "$FILTER"
  [ "${PIPESTATUS[0]}" -eq 0 ] || status=1
fi
echo "ALL: $([ $status -eq 0 ] && echo OK || echo FAILED)"
exit $status
