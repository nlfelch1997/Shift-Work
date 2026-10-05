#!/bin/bash
# THE FULL REGRESSION SUITE — every --test= mode every tools/*_test.gd defines,
# solo and co-op (host + N clients, each its own process), one log per test
# and a one-line summary each. Real wall-clock time unless an entry says
# otherwise (only the bot SIMS that their own headers document under
# --fixed-fps 60 run that way — never a timing-sensitive check).
#   GODOT=/path/to/godot tools/run_regression.sh [OUT_DIR] [LANES] [NAME_REGEX]
# LANES (default 2) tests run at once; each gets its own port and SW_NET_DIR.
# PORT_BASE (default 9100): ports are PORT_BASE + 2 x the test's index — give
# two side-by-side runs different bases (e.g. 9100 and 9500) or they collide.
# XDG_DATA_HOME is moved under OUT_DIR, so two checkouts (e.g. this branch and
# a clean main) can run side by side without sharing user:// files.
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
OUT="${1:-/tmp/sw_regression}"
LANES="${2:-2}"
ONLY="${3:-.}"
mkdir -p "$OUT/logs"
export XDG_DATA_HOME="$OUT/xdg"
mkdir -p "$XDG_DATA_HOME"
export GODOT OUT PORT_BASE

# name | script | fps (0 = real time) | clients | xvfb | host args | client args (default: --no-save --test=<same as host>)
TESTS=(
"hz-interact|hazards|0|0|0|--server --day=5 --shift-seconds=400 --no-save --test=interact|"
"hz-orders|hazards|0|0|0|--server --day=5 --no-save --test=orders|"
"hz-net-orders|hazards|0|3|0|--server --day=5 --players=4 --no-save --test=net-orders|"
"hz-ambience|hazards|0|0|0|--server --day=5 --shift-seconds=400 --no-save --test=ambience|"
"hz-net-ambience-d6|hazards|0|2|0|--server --day=6 --players=3 --no-save --test=net-ambience|"
"hz-net-ambience-d7|hazards|0|2|0|--server --day=7 --players=3 --no-save --test=net-ambience|"
"hz-finale|hazards|0|0|1|--server --day=6 --shift-seconds=400 --no-save --test=finale|"
"hz-delivery|hazards|0|0|0|--server --day=3 --shift-seconds=600 --no-save --test=delivery|"
"hz-net-delivery|hazards|0|2|0|--server --day=3 --shift-seconds=600 --players=3 --no-save --test=net-delivery|"
"hz-net-boxsync|hazards|0|1|0|--server --day=1 --shift-seconds=600 --no-save --test=net-boxsync|"
"hz-prep|hazards|0|0|0|--server --day=5 --no-save --test=prep|"
"hz-net-prep|hazards|0|2|0|--server --day=1 --players=3 --no-save --test=net-prep|"
"hz-hazard-pause|hazards|0|0|0|--server --day=7 --no-save --test=hazard-pause|"
"hz-net-hazard-pause|hazards|0|1|0|--server --day=7 --players=2 --no-save --test=net-hazard-pause|"
"hz-cleanup|hazards|0|0|0|--server --day=6 --no-save --test=cleanup|"
"hz-net-cleanup|hazards|0|1|0|--server --day=6 --players=2 --no-save --test=net-cleanup|"
"hz-polish|hazards|0|0|0|--server --day=5 --no-save --test=polish|"
"hz-net-polish|hazards|0|1|0|--server --day=5 --players=2 --no-save --test=net-polish|"
"hz-endless-board|hazards|0|0|0|--server --day=7 --no-save --test=endless-board|"
"hz-endless|hazards|60|0|0|--server --day=7 --shifts=5 --no-save --test=endless|"
"hz-net-endless|hazards|60|2|0|--server --day=7 --players=3 --shifts=5 --no-save --test=net-endless|"
"hz-solo-sim|hazards|60|0|0|--server --day=3 --days=3,4,5,6,7 --no-save --test=solo|"
"hz-solo-sim-d12|hazards|60|0|0|--server --day=1 --days=1,2 --no-save --test=solo|"
"mgr-host|manager|0|0|0|--server --day=3 --shift-seconds=6 --cleanup-seconds=0 --no-save --test=host|"
"mgr-net|manager|0|1|0|--server --day=4 --shift-seconds=40 --no-save --test=net-host|--no-save --test=net-client"
"coffee|coffee|0|0|0|--server --day=6 --prep-seconds=900 --no-save --test=coffee|"
"coffee-net|coffee|0|2|0|--server --day=7 --prep-seconds=900 --players=3 --no-save --test=net-coffee|"
"hud|hud|0|0|0|--server --day=1 --no-save --test=hud|"
"hud-endless|hud|0|0|0|--server --day=7 --no-save --test=hud-endless|"
"hud-menu|hud|0|0|0|--no-save --test=hud-menu|"
"hud-net|hud|0|2|0|--server --day=3 --no-save --players=3 --test=net-hud|"
"sound-assets|sound|0|0|0|--no-save --test=sound-assets|"
"sound|sound|0|0|0|--server --day=7 --no-save --test=sound|"
"sound-net|sound|0|2|0|--server --day=7 --players=3 --no-save --test=net-sound|"
"juice|juice|0|0|0|--server --day=7 --no-save --test=juice|"
"juice-endless|juice|0|0|0|--server --day=7 --no-save --test=juice-endless|"
"juice-net|juice|0|2|0|--server --day=7 --no-save --players=3 --test=net-juice|"
"juice-perf|juice|0|0|1|--server --day=7 --no-save --test=juice-perf|"
"char-solo|character|0|0|0|--server --day=4 --shift-seconds=600 --prep-seconds=900 --no-save --test=characters|"
"char-net|character|0|2|0|--server --day=5 --players=3 --shift-seconds=600 --prep-seconds=900 --no-save --test=net-characters|"
"join-menu|join|0|0|0|--no-save --test=join-menu|"
"pf-practice|playtest_fixes|60|0|0|--server --no-save --practice --test=practice|"
"pf-practice-skip|playtest_fixes|60|0|0|--server --no-save --practice --test=practice-skip|"
"pf-trash|playtest_fixes|60|0|0|--server --day=2 --no-save --test=trash|"
"pf-pickup|playtest_fixes|60|0|0|--server --day=1 --no-save --test=pickup|"
"pf-shelf|playtest_fixes|60|0|0|--server --day=3 --no-save --test=shelf|"
"pf-disruptive-d2|playtest_fixes|60|0|0|--server --day=2 --no-save --test=disruptive|"
"pf-disruptive-d5|playtest_fixes|60|0|0|--server --day=5 --no-save --test=disruptive|"
"pf-disruptive-d7|playtest_fixes|60|0|0|--server --day=7 --no-save --test=disruptive|"
"pf-disruptive-long|playtest_fixes|60|0|0|--server --day=3 --no-save --test=disruptive --long|"
"pf-net-practice|playtest_fixes|60|1|0|--server --players=2 --no-save --practice --test=net-practice|"
"pf-net-shelf|playtest_fixes|60|2|0|--server --players=3 --day=3 --no-save --test=net-shelf|"
"pf-net-disruptive-d2|playtest_fixes|60|2|0|--server --players=3 --day=2 --no-save --test=net-disruptive|"
"pf-net-disruptive-d7|playtest_fixes|60|2|0|--server --players=3 --day=7 --no-save --test=net-disruptive|"
"pf-practice-render|playtest_fixes|0|0|1|--server --no-save --practice --test=practice|"
"save-p1|save|0|0|0|--server --save-file=user://save_test/save.json --prep-seconds=900 --test=save --phase=1|"
"save-p2|save|0|0|0|--server --save-file=user://save_test/save.json --prep-seconds=900 --test=save --phase=2|"
"save-p7|save|0|0|0|--server --save-file=user://save_test/save.json --prep-seconds=900 --test=save --phase=7|"
"save-p3|save|0|0|0|--server --save-file=user://save_test/save.json --endless --prep-seconds=900 --test=save --phase=3|"
"save-p4|save|0|0|0|--server --save-file=user://save_test/save.json --endless --prep-seconds=900 --test=save --phase=4|"
"save-p5|save|0|0|0|--server --save-file=user://save_test/save.json --prep-seconds=900 --test=save --phase=5|"
"save-p6|save|0|0|0|--server --day=3 --prep-seconds=900 --test=save --phase=6|"
"save-net|save|0|1|0|--server --prep-seconds=900 --save-file=user://save_test/host.json --test=net-save|--save-file=user://save_test/client.json --test=net-save"
"save-net-story|save|0|1|0|--server --prep-seconds=900 --save-file=user://save_test/host.json --test=net-save-story|--save-file=user://save_test/client.json --test=net-save-story"
)
# Extra entries (e.g. new test files) can be appended by a sibling file.
[ -f tools/regression_extra.sh ] && source tools/regression_extra.sh

# Only these lines of each process's output are kept (the full logs carry a
# DATA line per object per frame — hundreds of MB a test, enough to fill the
# disk over a suite). The exit code rides along as a last "EXITCODE n" line.
# A crash keeps its "Program crashed with signal" line and the numbered
# backtrace frames under it, so a segfault in the suite can be traced.
KEEP='^(PASS|FAIL|RESULT|INFO|TRAFFIC|TRACE|SOLO|SOAK|DISRUPTIVE|PRACTICE|PICKUP|TRASH|SHOT|BOARD|REPORT|NET|JUICE|PERF|PEAKS|IDENTITY|DENSITY|PREP|FIN|EXITCODE)|SCRIPT ERROR|ERROR|^[[:space:]]+at: |\[Main\]|\[Economy\]|\[Staff\]|\[Save\]|handle_crash|Program crashed|signal [0-9]|Dumping the backtrace|^\[[0-9]+\] |non-main thread'
export KEEP
launch() { # launch <out file> <command...>
  local out=$1; shift
  ( "$@" 2>&1; echo "EXITCODE $?" ) | grep -aE --line-buffered "$KEEP" > "$out"
}
exitcode() { # the exit code launch() recorded in a log ("124" if it never got one)
  local c; c=$(grep -a "^EXITCODE " "$1" | tail -1 | cut -d' ' -f2)
  echo "${c:-124}"
}
export -f launch exitcode

# The save phases are one sequence over one file: they must run in order, in
# one lane. Everything named save-* runs serially at the end.
run_one() {
  local idx=$1 line=$2
  IFS='|' read -r name script fps nclients xvfb hargs cargs <<< "$line"
  local port=$((${PORT_BASE:-9100} + idx * 2))
  local log="$OUT/logs/$name"
  export SW_NET_DIR="user://rr_net_$name/"
  local fpsflag=""; [ "$fps" != "0" ] && fpsflag="--fixed-fps $fps"
  local headless="--headless"; local pre=""
  if [ "$xvfb" = "1" ]; then headless=""; pre="xvfb-run -a"; fi
  local test_name; test_name=$(grep -oE -- '--test=[a-z0-9-]+' <<< "$hargs" | head -1)
  [ -z "$cargs" ] && cargs="--no-save $test_name"
  # Every hosting test gets its own port — solo ones too, or two in parallel
  # lanes both try Net.PORT and the second can't host at all.
  local portflag=""; [[ "$hargs" == *--server* ]] && portflag="--port=$port"
  local t0=$(date +%s)
  launch "$log.host.log" timeout 4500 $pre "$GODOT" $headless $fpsflag --path . --script "res://tools/${script}_test.gd" -- $hargs $portflag &
  local hp=$!
  local pids=()
  if [ "$nclients" != "0" ]; then
    sleep 2
    for i in $(seq 1 "$nclients"); do
      launch "$log.c$i.log" timeout 4500 "$GODOT" --headless $fpsflag --path . --script "res://tools/${script}_test.gd" -- --client --connect-port=$port $cargs &
      pids+=($!)
      sleep 0.5
    done
  fi
  wait $hp; local hs; hs=$(exitcode "$log.host.log")
  local cs=0
  for p in "${pids[@]}"; do wait "$p"; done
  for i in $(seq 1 "$nclients"); do
    local c; c=$(exitcode "$log.c$i.log")
    [ "$nclients" != "0" ] && [ "$c" != "0" ] && cs=$c
  done
  # Godot's own user://logs copy of the same output: not needed, and huge.
  rm -rf "$XDG_DATA_HOME"/godot/app_userdata/*/logs
  local fails; fails=$(cat "$log".*.log | grep -cE "^FAIL")
  local passes; passes=$(cat "$log".*.log | grep -cE "^PASS")
  local errs; errs=$(cat "$log".*.log | grep -cE "SCRIPT ERROR")
  local verdict="OK"
  [ $hs -ne 0 ] || [ $cs -ne 0 ] || [ "$fails" -gt 0 ] && verdict="FAILED"
  printf "%-26s %-6s host=%-3s clients=%-3s PASS=%-4s FAIL=%-3s SCRIPT_ERRORS=%-3s %4ss\n" "$name" "$verdict" "$hs" "$cs" "$passes" "$fails" "$errs" "$(( $(date +%s) - t0 ))" | tee -a "$OUT/summary.txt"
}
export -f run_one

: > "$OUT/summary.txt"
par=(); ser=()
for i in "${!TESTS[@]}"; do
  n="${TESTS[$i]%%|*}"
  grep -qE "$ONLY" <<< "$n" || continue
  if [[ "$n" == save-* ]]; then ser+=("$i"); else par+=("$i"); fi
done
for i in "${par[@]}"; do printf '%s\0%s\0' "$i" "${TESTS[$i]}"; done | xargs -0 -n 2 -P "$LANES" bash -c 'run_one "$0" "$1"'
for i in "${ser[@]}"; do run_one "$i" "${TESTS[$i]}"; done
echo "ALL: $(grep -c ' OK ' "$OUT/summary.txt") OK, $(grep -c ' FAILED ' "$OUT/summary.txt") FAILED" | tee -a "$OUT/summary.txt"
