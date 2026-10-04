#!/bin/bash
# PLAYTEST PREP — runs every Host-IP-field test (tools/join_test.gd): the
# menu defaults and input fallback, a host + a client that types this
# machine's non-loopback address into the field and clicks Join, the same
# through --client --connect-ip=, and (if xvfb-run exists) menu screenshots.
#   GODOT=/path/to/godot tools/run_join_tests.sh [non-loopback-ip]
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
IP="${1:-$( (hostname -I 2>/dev/null || true) | tr ' ' '\n' | grep -v '^127\.' | grep -m1 '\.')}"
FILTER="^(PASS|FAIL|RESULT|INFO|SHOT)|SCRIPT ERROR"
status=0
echo "=== join-menu"
"$GODOT" --headless --path . --script res://tools/join_test.gd -- --no-save --test=join-menu 2>&1 | grep -E "$FILTER"
[ "${PIPESTATUS[0]}" -eq 0 ] || status=1
if [ -z "$IP" ]; then
  echo "SKIP net-join: no non-loopback IPv4 found (pass one as \$1)"; status=1
else
  for mode in typed cli; do
    echo "=== net-join ($mode, $IP)"
    "$GODOT" --headless --path . --script res://tools/join_test.gd -- --server --port=8951 --no-save --test=net-join > /tmp/sw_join_host.log 2>&1 &
    hp=$!
    sleep 2
    if [ $mode = typed ]; then
      "$GODOT" --headless --path . --script res://tools/join_test.gd -- --connect-port=8951 --no-save --type-ip="$IP" --test=net-join > /tmp/sw_join_c.log 2>&1
    else
      "$GODOT" --headless --path . --script res://tools/join_test.gd -- --client --connect-port=8951 --connect-ip="$IP" --no-save --test=net-join-cli > /tmp/sw_join_c.log 2>&1
    fi
    cs=$?
    wait $hp; hs=$?
    echo "--- host"; grep -E "$FILTER" /tmp/sw_join_host.log
    echo "--- client"; grep -E "$FILTER" /tmp/sw_join_c.log
    [ $hs -eq 0 ] && [ $cs -eq 0 ] || status=1
  done
fi
if command -v xvfb-run >/dev/null; then
  echo "=== join-shot (rendered, xvfb)"
  xvfb-run -a "$GODOT" --path . --script res://tools/join_test.gd -- --no-save --test=join-shot 2>&1 | grep -E "$FILTER"
  [ "${PIPESTATUS[0]}" -eq 0 ] || status=1
fi
echo "ALL: $([ $status -eq 0 ] && echo OK || echo FAILED)"
exit $status
