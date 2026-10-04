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
# OCT 2026 PHASE 3 (hired helpers) — tools/staff_test.gd. Real wall-clock
# time; the income sim is a measurement, not a pass/fail regression, so it
# runs on demand (see its header), not here.
"staff-hire|staff|0|0|0|--server --no-save --test=hire|"
"staff-effect|staff|0|0|0|--server --day=3 --no-save --test=effect|"
"staff-hazards|staff|0|0|0|--server --day=7 --no-save --test=hazards|"
"staff-hazards-max|staff|0|0|0|--server --day=7 --no-save --test=hazards --hire=Produce:2:2,Dairy/Frozen:2:2,Bakery:2:2|"
"staff-net|staff|0|2|0|--server --players=3 --day=5 --no-save --money=3000 --test=net-staff|"
"save-staff-1|staff|0|0|0|--server --save-file=user://staff_test/save.json --test=save --phase=1|"
"save-staff-2|staff|0|0|0|--server --save-file=user://staff_test/save.json --test=save --phase=2|"
"save-staff-3|staff|0|0|0|--server --save-file=user://staff_test/save.json --test=save --phase=3|"
)
