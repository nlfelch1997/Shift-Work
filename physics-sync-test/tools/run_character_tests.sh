#!/bin/bash
# WEEK 25 — runs every character-art test (tools/character_test.gd): the solo
# suite twice (two separate sessions — their IDENTITY lines must match, i.e.
# the same cashier at the same register and the same manager every session),
# then a real 3-player ENet session (host + 2 clients).
#   GODOT=/path/to/godot tools/run_character_tests.sh
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
LOG="${TMPDIR:-/tmp}/sw_chars"
mkdir -p "$LOG"
pick() { grep -E "^(PASS|FAIL|RESULT|IDENTITY)|SCRIPT ERROR|ERROR:.*(load|texture|res://)" "$1"; }
status=0
for s in 1 2; do
  echo "=== solo session $s"
  "$GODOT" --headless --path . --script res://tools/character_test.gd -- --server --day=4 --shift-seconds=600 --prep-seconds=900 --save-file=user://char_test/save$s.json --test=characters > "$LOG/solo$s.log" 2>&1 || status=1
  pick "$LOG/solo$s.log"
done
if diff <(grep ^IDENTITY "$LOG/solo1.log") <(grep ^IDENTITY "$LOG/solo2.log") > /dev/null && [ "$(grep -c ^IDENTITY "$LOG/solo1.log")" -ge 4 ]; then
  echo "PASS  identities identical across two separate sessions ($(grep -c ^IDENTITY "$LOG/solo1.log") days each)"
else
  echo "FAIL  identities differ between sessions"; status=1
fi
echo "=== net-characters (host + 2 clients)"
"$GODOT" --headless --path . --script res://tools/character_test.gd -- --server --port=8941 --day=5 --players=3 --shift-seconds=600 --prep-seconds=900 --save-file=user://char_test/host.json --test=net-characters > "$LOG/host.log" 2>&1 &
hp=$!
sleep 2
"$GODOT" --headless --path . --script res://tools/character_test.gd -- --client --connect-port=8941 --save-file=user://char_test/c1.json --test=net-characters > "$LOG/c1.log" 2>&1 &
c1=$!
sleep 1
"$GODOT" --headless --path . --script res://tools/character_test.gd -- --client --connect-port=8941 --save-file=user://char_test/c2.json --test=net-characters > "$LOG/c2.log" 2>&1
c2s=$?
wait $c1; c1s=$?
wait $hp; hs=$?
for f in host c1 c2; do echo "--- $f"; pick "$LOG/$f.log"; done
[ $hs -eq 0 ] && [ $c1s -eq 0 ] && [ $c2s -eq 0 ] || status=1
echo "ALL: $([ $status -eq 0 ] && echo OK || echo FAILED)"
exit $status
