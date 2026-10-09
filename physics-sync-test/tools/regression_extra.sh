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
# OCT 2026 PHASE 3B (shopping lists + carts) — tools/shopping_test.gd. Real
# wall-clock time. shop-traffic is the regression this phase exists for (a
# fully stocked Bakery gets real traffic).
"shop-lists|shopping|0|0|0|--server --day=7 --no-save --test=lists|"
"shop-purchase|shopping|0|0|0|--server --day=7 --no-save --test=purchase|"
"shop-traffic|shopping|0|0|0|--server --day=7 --no-save --test=traffic --seconds=300|"
"shop-net|shopping|0|2|0|--server --players=3 --day=7 --no-save --test=net-shopping|"
# OCT 2026 SECOND OUTSIDE PLAYTEST — tools/playtest2_test.gd. Real
# wall-clock time: riding a pushed item, invisible walls at empty registers.
"p2-ride|playtest2|0|0|0|--server --day=5 --no-save --test=ride|"
"p2-cashier-walls|playtest2|0|0|0|--server --day=1 --no-save --test=cashier-walls|"
"p2-net-ride|playtest2|0|2|0|--server --day=5 --players=3 --no-save --test=net-ride|"
# OCT 2026 PHASE 3D (store upkeep + the store rating) — tools/upkeep_test.gd.
# Real wall-clock time throughout.
"up-customer-ride|upkeep|0|0|0|--server --day=5 --no-save --test=customer-ride|"
"up-trash|upkeep|0|0|0|--server --day=3 --no-save --test=trash|"
"up-tools|upkeep|0|0|0|--server --day=6 --no-save --test=tools|"
"up-rating|upkeep|0|0|0|--server --day=7 --no-save --test=rating|"
"up-earnings|upkeep|0|0|0|--server --day=3 --no-save --test=earnings|"
"up-bounce|upkeep|0|0|0|--server --day=3 --no-save --test=bounce|"
"up-net|upkeep|0|2|0|--server --players=3 --day=3 --no-save --test=net-upkeep|"
"save-upkeep-1|upkeep|0|0|0|--server --save-file=user://upkeep_test/save.json --test=save --phase=1|"
"save-upkeep-2|upkeep|0|0|0|--server --save-file=user://upkeep_test/save.json --test=save --phase=2|"
"save-upkeep-3|upkeep|0|0|0|--server --save-file=user://upkeep_test/save.json --test=save --phase=3|"
"save-upkeep-4|upkeep|0|0|0|--server --save-file=user://upkeep_test/save.json --test=save --phase=4|"
)
# OCT 2026 PHASE 4 (random events + the Break Room Shop; Endless Mode
# retired) — tools/events_test.gd. Real wall-clock time throughout. The
# FEASIBLE bot sim is a measurement, run on demand (see its header).
TESTS+=(
"ev-gating|events|0|0|0|--server --day=1 --no-save --test=gating|"
"ev-each|events|0|0|0|--server --day=7 --no-save --test=each|"
"ev-interactions|events|0|0|0|--server --day=7 --no-save --test=interactions|"
"ev-shop|events|0|0|0|--server --day=1 --no-save --test=shop|"
"ev-net|events|0|2|0|--server --players=3 --day=7 --no-save --test=net-events|"
)
# OCT 2026 PHASE 4B (the janitor) — tools/janitor_test.gd, and the staff
# hazards watch with the janitor on staff beside all three helpers. Real
# wall-clock time throughout (the income/event measurements are bot sims run
# on demand — see the file's header — not here).
TESTS+=(
"jan-hire|janitor|0|0|0|--server --no-save --test=jan-hire|"
"jan-chores|janitor|0|0|0|--server --day=5 --no-save --test=jan-chores|"
"jan-chores-d7|janitor|0|0|0|--server --day=7 --no-save --test=jan-chores|"
"jan-stuck|janitor|0|0|0|--server --day=5 --no-save --test=jan-stuck|"
"jan-reach|janitor|0|0|0|--server --day=7 --shift-seconds=4000 --no-save --test=jan-reach --n=6|"
"jan-events|janitor|0|0|0|--server --day=7 --shift-seconds=1200 --no-save --events=on --test=jan-events|"
"jan-net|janitor|0|2|0|--server --players=3 --day=5 --no-save --money=3000 --test=jan-net|"
"staff-hazards-jan|staff|0|0|0|--server --day=7 --no-save --test=hazards --hire=Produce:0:0,Dairy/Frozen:0:0,Bakery:0:0,Janitor:0|"
"save-jan-1|janitor|0|0|0|--server --save-file=user://jan_test/save.json --test=jan-save --phase=1|"
"save-jan-2|janitor|0|0|0|--server --save-file=user://jan_test/save.json --test=jan-save --phase=2|"
"save-jan-3|janitor|0|0|0|--server --save-file=user://jan_test/save.json --test=jan-save --phase=3|"
)
# OCT 2026 PHASE 4C (pause menu, settings, quitting) — tools/menu_test.gd.
# Real wall-clock time throughout. Each writes its settings to its own file.
TESTS+=(
"menu-pause|menu|0|0|0|--server --day=7 --no-save --money=20000 --events=on --test=pause|"
"menu-quit-solo|menu|0|0|0|--server --save-file=user://menu_test/save.json --test=quit-solo|"
"menu-settings|menu|0|0|0|--no-save --settings-file=user://menu_test/settings.cfg --test=settings|"
"menu-rebind-play|menu|0|0|0|--server --no-save --practice --settings-file=user://menu_test/keys.cfg --test=rebind-play|"
"menu-display|menu|0|0|1|--server --day=7 --no-save --settings-file=user://menu_test/fs.cfg --test=display|"
"menu-shots|menu|0|0|1|--no-save --settings-file=user://menu_test/ms.cfg --test=menu-shots|"
"menu-net-pause|menu|0|2|0|--server --players=3 --day=5 --no-save --test=net-pause|"
"menu-net-host-quit|menu|0|2|0|--server --players=3 --day=5 --save-file=user://menu_test/net_host.json --test=net-host-quit|"
)
# OCT 2026 PHASE 5 (polish) — tools/phase5_test.gd: the main menu, the demo
# cap, the open-early hint, the Cleaning Cart rename, the helper's escape from
# the forklift. Real wall-clock time throughout.
TESTS+=(
"p5-menu|phase5|0|0|0|--save-file=user://p5_menu/save.json --test=menu|"
"p5-menu-continue|phase5|0|0|0|--save-file=user://p5_cont/save.json --test=menu-continue|"
"p5-menu-host|phase5|0|0|0|--no-save --test=menu-host|"
"p5-menu-demo|phase5|0|0|0|--no-save --demo --test=menu-demo|"
"p5-demo-cap|phase5|0|0|0|--server --demo --day=4 --no-save --shift-seconds=4 --prep-seconds=0 --cleanup-seconds=0 --test=demo-cap|"
"p5-demo-off|phase5|0|0|0|--server --day=4 --no-save --shift-seconds=4 --prep-seconds=0 --cleanup-seconds=0 --test=demo-off|"
"p5-demo-save|phase5|0|0|0|--server --demo --save-file=user://p5_demo/save.json --test=demo-save|"
"p5-net-demo|phase5|0|1|0|--server --demo --day=4 --players=2 --no-save --shift-seconds=6 --prep-seconds=0 --cleanup-seconds=0 --test=net-demo|"
"p5-open-early|phase5|0|0|0|--server --day=1 --no-save --test=open-early|"
"p5-gear|phase5|0|0|0|--server --save-file=user://p5_gear/save.json --test=gear|"
"p5-fk-escape|phase5|0|0|0|--server --day=3 --no-save --prep-seconds=900 --test=fk-escape|"
"p5-fk-helpers|phase5|0|0|0|--server --day=7 --no-save --prep-seconds=0 --shift-seconds=300 --test=fk-helpers|"
"p5-shots|phase5|0|0|1|--save-file=user://p5_shots/save.json --test=shots|"
)
# OCT 2026 PHASE 5B PART 2A (the named-area registry) — tools/areas_test.gd:
# the layout table's snapshot + its fit to Main.tscn, and the scan that keeps
# screen-cell arithmetic out of the game scripts. Real wall-clock time.
TESTS+=(
"areas-snapshot|areas|0|0|0|--server --no-save --test=snapshot|"
"areas-no-cell-math|areas|0|0|0|--no-save --test=no-cell-math|"
)
TESTS+=(
"areas-net|areas|0|2|0|--server --players=3 --no-save --test=net|"
)
# PHASE 5B PART 2B (Plan B, the growing store) — tools/growth_test.gd. Real
# wall-clock time. net-growth: host + 2 clients, the second joining late
# (after every wing is bought). The save phases run in order, in one lane.
TESTS+=(
"growth|growth|0|0|0|--server --no-save --test=growth|"
"growth-net|growth|0|2|0|--server --players=2 --no-save --test=net-growth|"
"save-growth-1|growth|0|0|0|--server --save-file=user://growth_test/save.json --test=growth-save --phase=1|"
"save-growth-2|growth|0|0|0|--server --save-file=user://growth_test/save.json --test=growth-save --phase=2|"
"save-growth-3|growth|0|0|0|--server --save-file=user://growth_test/save.json --test=growth-save --phase=3|"
)
