#!/bin/bash
# PHASE 5B PART 2A — runs tools/layout_proof.gd at several store states into
# OUT_DIR (one probe/nav/tree file per state, plus screenshots), so a clean
# main checkout and the refactored one can be compared with diff/cmp:
#   GODOT=/path/to/godot tools/run_layout_proof.sh OUT_DIR [PORT]
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
OUT="$1"; PORT="${2:-9320}"
mkdir -p "$OUT"
export XDG_DATA_HOME="$OUT/xdg"
run() { # tag, args...
  local tag=$1; shift
  timeout 900 xvfb-run -a "$GODOT" --fixed-fps 60 --path . --script res://tools/layout_proof.gd -- --server --no-save --port=$PORT --out="$OUT" --tag=$tag --shots "$@" 2>&1 | grep -aE "^(PROOF|SHOT)|SCRIPT ERROR" > "$OUT/log_$tag.txt"
}
run d1 --day=1
run d3 --day=3
run d5 --day=5
run d7 --day=7
run practice --practice
rm -rf "$OUT/xdg"
grep -h "SCRIPT ERROR" "$OUT"/log_*.txt && echo "PROOF had script errors" || echo "PROOF ok: $(ls "$OUT" | wc -l) files"
