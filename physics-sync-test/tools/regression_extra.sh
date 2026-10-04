# Sourced by tools/run_regression.sh — the OCT 2026 PHASE 2 (shopkeeper
# economy) entries, in the same "name|script|fps|clients|xvfb|host args|client
# args" format. Real wall-clock time throughout.
TESTS+=(
"econ-economy|economy|0|0|0|--server --no-save --test=economy|"
"econ-thresholds|economy|0|0|0|--server --no-save --test=thresholds|"
"econ-net|economy|0|2|0|--server --players=3 --no-save --money=2000 --test=net-economy|"
"save-econ-legacy-1|economy|0|0|0|--server --save-file=user://econ_test/save.json --test=legacy-save --phase=1|"
"save-econ-legacy-2|economy|0|0|0|--server --save-file=user://econ_test/save.json --test=legacy-save --phase=2|"
"save-econ-legacy-3|economy|0|0|0|--server --save-file=user://econ_test/save.json --test=legacy-save --phase=3|"
"save-econ-legacy-4|economy|0|0|0|--server --save-file=user://econ_test/save.json --test=legacy-save --phase=4|"
)
