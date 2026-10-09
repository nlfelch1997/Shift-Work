extends "res://tools/hazards_test.gd"
## PHASE 5B PART 2B — THE GROWING STORE (Plan B): every growth stage, before
## and after its purchase. Drives the real Main.tscn through the real game
## code. Not part of the game. Real wall-clock time throughout.
##
##   --test=growth     solo, from a brand-new shop, buying each section in
##                     turn at prep. At every stage (1-4 sections): each lot's
##                     look (StoreGrowth.lot_state), its barrier pieces' collision,
##                     areas.area_opened firing for exactly the new wing (and
##                     its lane), the knock-out playing once; and the three
##                     nav grids — every open shelf slot reachable from the
##                     door, nothing in a closed lot reachable, no open pocket
##                     of shop floor cut off from the door (stuck points), every
##                     open can and the dumpster reachable for the janitor,
##                     every hired helper's slots, pad and home reachable in
##                     its own grid. Also: buying from the wrong side of a
##                     barrier or from Storage's side of a back door isn't
##                     possible.
##   --test=net-growth host + 2 clients (a 3rd process joins late): the host
##                     and the first client press E at Produce's wall at the
##                     same moment (it's bought once); then Dairy/Frozen and
##                     Bakery; every peer sees each lot close -> knock-out ->
##                     open, once, with the barriers gone and the same registry
##                     answers. The late joiner arrives after everything is
##                     bought: every wing open, no knock-out played, the same
##                     answers.
##   --test=checkout   the north-facing checkout at every tier (1-4 sections):
##                     the open lanes are the ones nearest the door (2/3/4/5),
##                     every queue runs north on open floor (its 4 spots and 6
##                     overflow places past them), clear of the other lanes'
##                     counters and cashiers, and a real crowd checks out
##                     through them (sales rung at every open register, no
##                     shopper stuck).
##   --test=events     every random event at every growth stage it can run in
##                     (2, 3, 4 sections): it starts, and what it puts in the
##                     world lands in the open store — the rush's section is an
##                     open wing, every leak is on open shop floor a player can
##                     reach, a delivery's / catering order's sections are open.
##   --test=growth-save --phase=1|2|3  phase 1 buys Produce and Dairy/Frozen
##                     and saves (still version 6); phase 2 reloads it: those
##                     two wings open with no knock-out, Bakery's lot closed;
##                     phase 3 loads a v6 save written by the OLD (Part 2A)
##                     layout's code (tools/fixtures/v6_old_layout_save.json):
##                     its sections are all there in the new store.
##   --test=demo-path  the demo's growth moment: in the demo (--demo, Shift 3,
##                     the progression sim's typical buy), Produce is bought at
##                     prep — knock-out, wing open — and the demo still ends as
##                     before: Shift 4's report says Finish Demo and the thanks
##                     screen shows, over the grown store.
##   godot --headless --path . --script res://tools/growth_test.gd -- --server --no-save --test=growth
##   godot --headless --path . --script res://tools/growth_test.gd -- --server --demo --day=4 --no-save --shift-seconds=4 --prep-seconds=20 --cleanup-seconds=0 --test=demo-path
##   godot --headless --path . --script res://tools/growth_test.gd -- --server --port=P --players=2 --no-save --test=net-growth
##   (x2) godot --headless --path . --script res://tools/growth_test.gd -- --client --connect-port=P --no-save --test=net-growth
##   godot --headless --path . --script res://tools/growth_test.gd -- --server --save-file=user://growth_test/save.json --test=growth-save --phase=N

const Layout := preload("res://StoreLayout.gd")
const OLD_SAVE_FIXTURE := "res://tools/fixtures/v6_old_layout_save.json"
const WINGS := ["Produce", "Dairy/Frozen", "Bakery"]

var _mode := ""
var _opened: Array = []

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--test="):
			_mode = a.substr(7)
	if _mode == "growth-save":
		_prepare_save_phase()
	if _mode == "net-growth" and "--client" in args:
		_client_role.call_deferred()
		return
	_start_main()
	match _mode:
		"growth": _run_growth.call_deferred()
		"net-growth": _run_net_host.call_deferred()
		"growth-save": _run_save.call_deferred()
		"checkout": _run_checkout.call_deferred()
		"events": _run_events.call_deferred()
		"demo-path": _run_demo_path.call_deferred()
		_:
			print("FAIL  unknown --test=%s" % _mode)
			quit(1)

func _start_main() -> void:
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	main.events_on = false
	main.cleanup_ceiling_override = 0.0

func _arg(prefix: String, dflt: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return a.substr(prefix.length())
	return dflt

## --- what a stage looks like ------------------------------------------------

## Every lot's look, every barrier piece's collision, and the registry's open
## state agree with `owned` sections owned. "" if so, else what's wrong.
func _stage_wrong(owned: int) -> String:
	var out := []
	for i in range(1, main.SECTIONS.size()):
		var sec: String = main.SECTIONS[i]["name"]
		var want_open := i < owned
		var look: String = main.growth.lot_state(sec)
		if (look == "closed") == want_open:
			out.append("%s look %s" % [sec, look])
		for g in main.gates_of(sec):
			if g.get_node("CollisionShape2D").disabled != want_open:
				out.append("%s barrier %s solid=%s" % [sec, g.name, str(not g.get_node("CollisionShape2D").disabled)])
		if main.areas.is_open(main.SECTIONS[i]["area"]) != want_open:
			out.append("%s registry open=%s" % [sec, str(not want_open)])
	return ", ".join(out)

## The digest of every registry answer (tools/areas_test.gd's, over this
## world).
func _answers() -> String:
	var areas: RefCounted = main.areas
	var parts := PackedStringArray()
	parts.append("owned=%d" % main.sections_owned)
	for id in areas.room_ids() + Layout.FEATURES.map(func(f): return f["id"]):
		parts.append("%s:%s" % [id, str(areas.is_open(id))])
	var w: Rect2 = areas.world_rect()
	var y := w.position.y - 30.0
	while y < w.end.y + 30.0:
		var x := w.position.x - 30.0
		while x < w.end.x + 30.0:
			var p := Vector2(x, y)
			parts.append("%s|%s|%d%d%d%d" % [areas.area_at(p), areas.section_of(p), int(areas.is_section_open_at(p)), int(areas.is_open_shop_floor_at(p)), int(areas.shoppers_allowed_at(p)), int(main.is_unlocked_at_pos(p))])
			x += 30.0
		y += 30.0
	for g in main.get_node("Gates").get_children():
		parts.append("%s:%s" % [g.name, str(g.get_node("CollisionShape2D").disabled)])
	return "\n".join(parts).md5_text()

## --- the nav grids at a stage ------------------------------------------------

func _door_inside() -> Vector2:
	return main.areas.anchor("front_door") + Vector2(0.0, -40.0)

## [reachable slots, total slots, unreachable list] for every open shelf's
## stand points (a shopper stands SLOT_STAND past the slot).
func _slots_reachable(nav: RefCounted, from: Vector2) -> Array:
	var ok := 0
	var total := 0
	var bad := []
	for sb in main.shelves:
		if not main.is_unlocked_at_pos(sb.global_position):
			continue
		var shelf: Node = sb.get_node("Shelf")
		var outward: Vector2 = -sb.global_transform.y.normalized()
		for slot in shelf.slots:
			var stand: Vector2 = slot.global_position + outward * 29.0
			total += 1
			if nav.reachable(from, stand):
				ok += 1
			else:
				bad.append("%s@%s" % [main.areas.area_at(sb.global_position), str(stand.round())])
	return [ok, total, bad]

## Open cells of the shopper grid inside open shop floor that the door can't
## reach (pockets a shopper could be pushed into and never leave).
func _pockets(nav: RefCounted) -> Array:
	var a: AStarGrid2D = nav._astar
	var start: Vector2i = nav._open_cell_near(nav._to_cell(_door_inside()))
	var seen := {start: true}
	var q := [start]
	while not q.is_empty():
		var c: Vector2i = q.pop_back()
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + d
			if a.is_in_boundsv(n) and not seen.has(n) and not a.is_point_solid(n):
				seen[n] = true
				q.append(n)
	var out := []
	for x in a.region.size.x:
		for y in a.region.size.y:
			var c := Vector2i(x, y)
			if a.is_point_solid(c) or seen.has(c):
				continue
			var p: Vector2 = nav._cell_center(c)
			if main.areas.is_open_shop_floor_at(p) and not _near_loose(p):
				out.append(main.areas.area_at(p) + str(p))
	return out

## Loose stock on the floor is a nav obstacle for shoppers (they walk round
## it); a cell it boxes in is a moment, not a stuck point in the layout.
func _near_loose(p: Vector2) -> bool:
	for obj in get_nodes_in_group("carryable"):
		if obj.global_position.distance_to(p) < 70.0:
			return true
	return false

func _check_nav(stage: String) -> void:
	main.customer_path(_door_inside(), _door_inside()) # builds the grid
	var nav: RefCounted = main._customer_nav
	nav.invalidate()
	main.customer_path(_door_inside(), _door_inside())
	var r := _slots_reachable(nav, _door_inside())
	check(r[0] == r[1] and r[1] > 0, "G-%s nav1: every open shelf slot is reachable from the door (%d/%d) %s" % [stage, r[0], r[1], str(r[2].slice(0, 6))])
	var leaks := []
	for i in range(main.sections_owned, main.SECTIONS.size()):
		var c: Vector2 = main.areas.center_of(main.SECTIONS[i]["area"])
		if nav.reachable(_door_inside(), c):
			leaks.append(main.SECTIONS[i]["name"])
	check(leaks.is_empty(), "G-%s nav2: no closed lot is reachable from the door %s" % [stage, str(leaks)])
	var pockets := _pockets(nav)
	check(pockets.is_empty(), "G-%s nav3: no open shop floor is cut off from the door (%d pocket cells) %s" % [stage, pockets.size(), str(pockets.slice(0, 6))])
	# The janitor: his grid (Storage allowed, its forklift floor not) from the
	# dumpster to every open can and to his home.
	var jn: RefCounted = main._jnav()
	jn.invalidate()
	main.janitor_nav_path(main.cleanup.DUMPSTER_POS, main.cleanup.DUMPSTER_POS)
	var jbad := []
	for c in main.cleanup.BINS:
		var sec: String = c["section"]
		if sec != "" and not main.is_section_open(main.SECTIONS[main.section_index(sec)]):
			continue
		if not main.janitor_nav_reachable(main.cleanup.DUMPSTER_POS + Vector2(0, -50), c["pos"]):
			jbad.append(str(c["pos"]))
	if not main.janitor_nav_reachable(main.cleanup.DUMPSTER_POS + Vector2(0, -50), main.areas.anchor("janitor_home")):
		jbad.append("home")
	check(jbad.is_empty(), "G-%s nav4: the janitor reaches every open can and his home from the dumpster %s" % [stage, str(jbad)])
	# Every helper of an open wing: its slots, its pad and its home, in its
	# own grid (the room, its real walls and closed barriers).
	var hbad := []
	var hn := 0
	for sec in WINGS:
		if not main.is_section_open(main.SECTIONS[main.section_index(sec)]):
			continue
		var h: Node2D = main.staff.helpers.get(sec)
		if h == null:
			continue
		hn += 1
		var goals := [main.delivery.pad_center(sec)]
		for s in h._empty_slots():
			goals.append(s["stand"])
		for g in goals:
			h._plan(g)
			var a: Vector2i = h._open_cell_near(h._to_cell(h.home()))
			var b: Vector2i = h._open_cell_near(h._to_cell(g))
			if a == Vector2i(-1, -1) or b == Vector2i(-1, -1) or h._astar.get_id_path(a, b).is_empty():
				hbad.append("%s->%s" % [sec, str(g.round())])
	check(hbad.is_empty(), "G-%s nav5: %d helper(s) reach every slot and their pad in their own grid %s" % [stage, hn, str(hbad.slice(0, 6))])

## Legs (pairs of points) of the manager's rounds to every open section that
## a ray hits a static body on: [] if none.
func _manager_leg_hits() -> Array:
	var m: Node2D = main.manager
	var space := m.get_world_2d().direct_space_state
	var out := []
	var seen := {}
	for n in 40:
		m._legs.clear()
		m._plan_visit(main)
		var pts := [main.areas.waypoint_of("hub")]
		for leg in m._legs:
			pts.append(leg["pos"])
		for i in range(1, pts.size()):
			var key := "%s>%s" % [str(pts[i - 1].round()), str(pts[i].round())]
			if seen.has(key):
				continue
			seen[key] = true
			var q := PhysicsRayQueryParameters2D.create(pts[i - 1], pts[i])
			q.collide_with_areas = false
			var hit := space.intersect_ray(q)
			if not hit.is_empty() and hit["collider"] is StaticBody2D:
				out.append("%s (%s)" % [key, String(hit["collider"].name)])
	m._legs.clear()
	return out

## --- SOLO --------------------------------------------------------------------

func _run_growth() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 30.0)
	await wait(0.5)
	main.areas.area_opened.connect(func(id): _opened.append(id))
	check(main.sections_owned == 1, "G0: a brand-new shop owns Dry Goods only")
	check(_stage_wrong(1) == "", "G-1 look: every wing is a closed lot behind a solid wall %s" % _stage_wrong(1))
	check(main.growth.animations_played.is_empty(), "G-1: no knock-out has played (nothing was bought)")
	# Everyone on staff for the helper checks (they work only in open wings).
	main.staff.staff = {"Produce": {"speed": 0, "carry": 0}, "Dairy/Frozen": {"speed": 0, "carry": 0}, "Bakery": {"speed": 0, "carry": 0}}
	await wait(0.5)
	_check_nav("1")
	# Buying: only from the shop side of the knock-out wall, not from the lot
	# or from Storage's side of Produce's back door.
	var wall: Node2D = main.gate_of("Produce")
	check(main.for_sale_gate_at(wall.global_position + Vector2(-40, 0)) == "Produce", "G-buy1: standing in the shop by Produce's wall offers it")
	var back: Node2D = main.gates_of("Produce")[1]
	check(back.get_node("Gate").back_door and main.for_sale_gate_at(back.global_position + Vector2(0, -40)) == "", "G-buy2: Storage's side of Produce's back door doesn't sell it")
	var bk: Vector2 = main.gate_of("Bakery").global_position + Vector2(40, 0)
	check(main.for_sale_gate_at(bk) == "Bakery" and main.purchase_blocker("Bakery") == "buy Produce first", "G-buy3: Bakery's wall says what it is, and that the sections before it come first ('%s')" % main.purchase_blocker("Bakery"))
	for stage in range(2, 5):
		var sec: Dictionary = main.SECTIONS[stage - 1]
		_opened.clear()
		main.money = main.section_price(sec["name"]) + 100
		var bank: int = main.money
		check(main.buy_section(sec["name"], 1), "G-%d buy: %s bought at prep" % [stage, sec["name"]])
		check(main.money == bank - main.section_price(sec["name"]), "G-%d buy: the bank paid %s once" % [stage, main._format_money(main.section_price(sec["name"]))])
		var want := [sec["area"]]
		if sec["name"] == "Produce":
			want.append("produce_forklift_lane")
		check(_opened == want, "G-%d hook: area_opened fired for %s (and only that) %s" % [stage, str(want), str(_opened)])
		await wait(0.1)
		check(main.growth.lot_state(sec["name"]) == "opening", "G-%d look: the knock-out is playing (%s)" % [stage, main.growth.lot_state(sec["name"])])
		await wait(main.growth.KNOCK_SECONDS + 0.3)
		check(_stage_wrong(stage) == "", "G-%d look: %d sections — bought wings open, the rest closed lots %s" % [stage, stage, _stage_wrong(stage)])
		check(int(main.growth.animations_played.get(sec["name"], 0)) == 1, "G-%d look: the knock-out played once for %s" % [stage, sec["name"]])
		_check_nav(str(stage))
	# The manager walks straight between his stops with no collision (he
	# drifts through whatever's between): every leg of every round, in the
	# full store, must clear the walls, shelves, registers and barriers.
	var hits := _manager_leg_hits()
	check(hits.is_empty(), "G-mgr: every straight leg of the manager's rounds (each section) clears walls, shelves and registers %s" % str(hits.slice(0, 6)))
	# A wing that opens with no purchase moment (the practice shift ending,
	# a reload) snaps: shut everything, then open it again.
	var played: Dictionary = main.growth.animations_played.duplicate()
	main.sections_owned = 1
	main._reconfigure_world()
	await wait(0.2)
	check(_stage_wrong(1) == "", "G-snap: back to one section, every lot is closed again %s" % _stage_wrong(1))
	main.sections_owned = 4
	main._reconfigure_world()
	await wait(0.2)
	check(_stage_wrong(4) == "" and main.growth.animations_played == played, "G-snap: opened with no purchase, every wing is simply open — no knock-out %s" % _stage_wrong(4))
	finish()

## --- THE DEMO ----------------------------------------------------------------

func _run_demo_path() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 30.0)
	# --day=4 (the demo's last shift's setup, as phase5_test's demo-cap),
	# wound back to Shift 3 and the corner shop alone.
	main.current_day = 3
	main.sections_owned = 1
	main._reconfigure_world()
	await wait(0.5)
	check(main.demo_mode and main.current_day == 3 and main.sections_owned == 1, "DP1: the demo's Shift 3, one section (day %d, owned %d)" % [main.current_day, main.sections_owned])
	check(main.section_price("Produce") <= 600, "DP1: the first wing costs %s — reachable in the demo (the progression sim's solo crew banks it by Shift 3)" % main._format_money(main.section_price("Produce")))
	main.money = main.section_price("Produce")
	var wall: Node2D = main.gate_of("Produce")
	check(main.for_sale_gate_at(wall.global_position + Vector2(-40, 0)) == "Produce" and main.purchase_blocker("Produce") == "", "DP2: Produce's wall offers it, nothing in the way ('%s')" % main.purchase_blocker("Produce"))
	check(main.buy_section("Produce", 1) and main.sections_owned == 2 and main.money == 0, "DP2: bought at prep")
	await wait(0.1)
	check(main.growth.lot_state("Produce") == "opening", "DP2: the knock-out plays")
	await wait(main.growth.KNOCK_SECONDS + 0.3)
	check(_stage_wrong(2) == "", "DP2: the Produce wing is open %s" % _stage_wrong(2))
	main.open_store(1)
	await wait_until(func(): return main.is_day_report_active(), 60.0)
	await wait(0.3)
	check(main.is_day_report_active() and not main.demo_cap_reached() and main.continue_button.text == "Continue", "DP3: Shift 3's report: Continue ('%s', report up %s)" % [main.continue_button.text, str(main.is_day_report_active())])
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 10.0)
	await wait(0.5)
	check(main.current_day == 4 and _stage_wrong(2) == "" and int(main.growth.animations_played.get("Produce", 0)) == 1, "DP4: Shift 4 opens on the grown store, no second knock-out (day %d, played %s) %s" % [main.current_day, str(main.growth.animations_played), _stage_wrong(2)])
	main.open_store(1)
	await wait_until(func(): return main.is_day_report_active(), 60.0)
	await wait(0.3)
	check(main.demo_cap_reached() and main.continue_button.text == "Finish Demo", "DP5: Shift 4's report: Finish Demo ('%s')" % main.continue_button.text)
	main.continue_button.pressed.emit()
	await wait(0.3)
	check(main.demo_over and main._demo_end.visible and main.current_day == 4 and not main.shift_active, "DP5: the thanks screen, nothing advanced")
	check(main.growth.lot_state("Produce") == "open" and main.sections_owned == 2, "DP5: the store behind it is still the grown one")
	finish()

## --- CO-OP -------------------------------------------------------------------

## Clients: the first to start is the early one, a later one waits until the
## host has bought everything before it even joins (its Main isn't built
## until then).
func _client_role() -> void:
	var pid := OS.get_process_id()
	_net_write("growth_claim_%d.json" % pid, {"pid": pid})
	await create_timer(2.0).timeout
	var pids := []
	var d := DirAccess.open(NET_DIR)
	for f in d.get_files():
		if f.begins_with("growth_claim_") and f.ends_with(".json"):
			pids.append(int(f.trim_prefix("growth_claim_").trim_suffix(".json")))
	pids.sort()
	if pids.find(pid) == 0:
		_start_main()
		_run_net_client(false)
	else:
		print("INFO  late joiner: waiting for the host to buy everything")
		await _net_read("growth_all_bought.json", 300.0)
		_start_main()
		_run_net_client(true)

func _run_net_host() -> void:
	DirAccess.make_dir_recursive_absolute(NET_DIR)
	await wait_until(func(): return main.players.size() >= 2 and main.shift_active, 60.0)
	check(main.players.size() >= 2, "NG0: host + a client in at prep")
	await wait(1.0)
	_net_write("growth_closed.json", {"hash": _answers()})
	await _net_read("growth_closed_ok.json", 60.0)
	# Produce: the host and the client press E at its wall at the same moment.
	main.money = 5000
	var wall: Node2D = main.gate_of("Produce")
	player().teleport_to(wall.global_position + Vector2(-40, -120))
	var at := Time.get_unix_time_from_system() + 3.0
	_net_write("growth_buy_produce.json", {"at": at, "spot": [wall.global_position.x - 40.0, wall.global_position.y + 120.0]})
	var made0: int = main.purchases_made
	var refused0: int = main.purchases_refused
	while Time.get_unix_time_from_system() < at:
		await process_frame
	main.try_buy_section("Produce")
	await wait(2.0)
	check(main.sections_owned == 2 and main.purchases_made == made0 + 1 and main.money == 5000 - main.section_price("Produce"), "NG1: two players buying Produce at once bought it once (owned %d, purchases %d, bank %s)" % [main.sections_owned, main.purchases_made - made0, main._format_money(main.money)])
	check(main.purchases_refused >= refused0 + 1, "NG1: ...the second press was refused (%d refused)" % (main.purchases_refused - refused0))
	await wait(main.growth.KNOCK_SECONDS)
	_net_write("growth_stage_2.json", {"hash": _answers(), "owned": main.sections_owned})
	await _net_read("growth_stage_2_ok.json", 60.0)
	for stage in [3, 4]:
		var sec: String = main.SECTIONS[stage - 1]["name"]
		main.money = main.section_price(sec)
		check(main.buy_section(sec, 1), "NG%d: the host buys %s" % [stage - 1, sec])
		await wait(main.growth.KNOCK_SECONDS + 0.5)
		check(_stage_wrong(stage) == "", "NG%d: host: %d sections open, the rest closed %s" % [stage - 1, stage, _stage_wrong(stage)])
		_net_write("growth_stage_%d.json" % stage, {"hash": _answers(), "owned": main.sections_owned})
		await _net_read("growth_stage_%d_ok.json" % stage, 60.0)
	check(main.growth.animations_played == {"Produce": 1, "Dairy/Frozen": 1, "Bakery": 1}, "NG4: host: each knock-out played once %s" % str(main.growth.animations_played))
	# The late joiner.
	_net_write("growth_all_bought.json", {"hash": _answers(), "owned": main.sections_owned})
	var joined := await wait_until(func(): return main.players.size() >= 3, 120.0)
	check(joined, "NG5: a third player joined late (%d players)" % main.players.size())
	var late := await _net_read("growth_late_done.json", 120.0)
	check(late.get("ok", false), "NG5: the late joiner saw the grown store (%s)" % str(late))
	_net_write("growth_done.json", {"done": true})
	await _net_read("growth_bye_early.json", 60.0)
	await wait(1.0)
	finish()

func _run_net_client(is_late: bool) -> void:
	await wait_until(func(): return main.shift_active and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 60.0)
	me = main.multiplayer.get_unique_id()
	act = "client_"
	if is_late:
		var h := await _net_read("growth_all_bought.json", 30.0)
		await wait_until(func(): return main.sections_owned == int(h.get("owned", -1)), 20.0)
		await wait(1.0)
		var ok: bool = _stage_wrong(4) == "" and main.growth.animations_played.is_empty() and _answers() == h.get("hash", "")
		check(_stage_wrong(4) == "", "NG5 late: every wing is open on arrival %s" % _stage_wrong(4))
		check(main.growth.animations_played.is_empty(), "NG5 late: no knock-out played for a store that was already grown %s" % str(main.growth.animations_played))
		check(_answers() == h.get("hash", ""), "NG5 late: its registry answers match the host's")
		_net_write("growth_late_done.json", {"ok": ok})
		await _net_read("growth_done.json", 60.0)
		finish()
		return
	var c := await _net_read("growth_closed.json", 60.0)
	await wait(0.5)
	check(_stage_wrong(1) == "" and _answers() == c.get("hash", ""), "NG0 client: every wing is a closed lot, as on the host %s" % _stage_wrong(1))
	_net_write("growth_closed_ok.json", {"ok": true})
	var b := await _net_read("growth_buy_produce.json", 60.0)
	var spot := Vector2(b["spot"][0], b["spot"][1])
	player().teleport_to(spot)
	while Time.get_unix_time_from_system() < float(b["at"]):
		await process_frame
	main.try_buy_section("Produce")
	for stage in [2, 3, 4]:
		var h := await _net_read("growth_stage_%d.json" % stage, 120.0)
		await wait_until(func(): return main.sections_owned == int(h.get("owned", -1)), 20.0)
		await wait(main.growth.KNOCK_SECONDS + 0.5)
		var sec: String = main.SECTIONS[stage - 1]["name"]
		check(_stage_wrong(stage) == "", "NG%d client: %d sections open, the rest closed lots %s" % [stage - 1, stage, _stage_wrong(stage)])
		check(int(main.growth.animations_played.get(sec, 0)) == 1, "NG%d client: the %s knock-out played here too, once (%s)" % [stage - 1, sec, str(main.growth.animations_played)])
		check(_answers() == h.get("hash", ""), "NG%d client: registry answers and barriers match the host's" % [stage - 1])
		_net_write("growth_stage_%d_ok.json" % stage, {"ok": true})
	await _net_read("growth_done.json", 180.0)
	_net_write("growth_bye_early.json", {"fails": fails})
	finish()

## --- THE CHECKOUT ---------------------------------------------------------------

func _run_checkout() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 30.0)
	await wait(0.5)
	player().teleport_to(main.areas.anchor("player_spawn"))
	var door: Vector2 = main.areas.anchor("front_door")
	var q_dir: Vector2 = Layout.CHECKOUT["queue_dir"]
	var bn: RefCounted = Spots.nav(main)
	for tier in range(1, 5):
		main.sections_owned = tier
		main._reconfigure_world()
		await wait(0.3)
		var active: Array = main.cashiers.filter(func(c): return c.get_node("Cashier").active)
		var want: int = Layout.CHECKOUT["registers_by_tier"][tier - 1]
		var by_door: Array = main.cashiers.duplicate()
		by_door.sort_custom(func(a, b): return a.global_position.distance_to(door) < b.global_position.distance_to(door))
		check(active.size() == want and active == by_door.slice(0, want), "C%d tiers: %d of 5 lanes open, the %d nearest the door" % [tier, active.size(), want])
		bn.invalidate()
		bn.path(door, door)
		var bad := []
		for c in active:
			var cash: Node = c.get_node("Cashier")
			var pts: Array = [cash.checkout.global_position]
			for m in cash.queue_slots:
				pts.append(m.global_position)
			var last: Vector2 = pts[-1]
			for k in 6:
				pts.append(last + q_dir * 40.0 * (k + 1)) # Cashier.queue_slot_position()'s overflow
			for i in pts.size():
				var p: Vector2 = pts[i]
				# The checkout spot itself is beside the counter, within its
				# clearance: a shopper stands at the nearest open cell (within
				# Customer.CHECKOUT_STOP_RANGE of it).
				var cell: Vector2i = bn._to_cell(p)
				var ok: bool = not bn._astar.is_point_solid(cell) if i > 0 else bn._cell_center(bn._open_cell_near(cell)).distance_to(p) <= 25.0
				if not ok:
					bad.append("%s#%d%s" % [c.name, i, str(p.round())])
		check(bad.is_empty(), "C%d queues: every open lane's checkout spot, 4 queue spots and 6 overflow places are open floor %s" % [tier, str(bad.slice(0, 6))])
		var reach := []
		main.customer_path(door, door)
		for c in active:
			if not main._customer_nav.reachable(door + Vector2(0, -60), c.get_node("Cashier").checkout.global_position):
				reach.append(String(c.name))
		check(reach.is_empty(), "C%d reach: shoppers can walk from the door to every open register %s" % [tier, str(reach)])
	# A real crowd through the checkout at the top tier, everything stocked.
	main.sections_owned = 4
	main._reconfigure_world()
	await wait(0.3)
	main.open_store(1)
	var sold0 := {}
	for c in main.cashiers:
		sold0[c.name] = c.get_node("Cashier").total_sold
	var t := 0.0
	var max_q := 0
	while t < 150.0:
		for sb in main.shelves:
			var shelf: Node = sb.get_node("Shelf")
			if shelf.filled_count() < shelf.slot_count() / 2 and main.is_unlocked_at_pos(sb.global_position):
				var sec: String = main.areas.section_of(sb.global_position)
				main.spawn_product_at(sec, open_floor_near(sb.global_position - sb.global_transform.y.normalized() * 110.0))
		for c in main.cashiers:
			max_q = maxi(max_q, c.get_node("Cashier").queue_length())
		await wait(3.0)
		t += 3.0
	var rung := []
	for c in main.cashiers:
		if c.get_node("Cashier").total_sold > sold0[c.name]:
			rung.append(String(c.name))
	print("INFO  checkout run: sales by register %s, longest queue %d" % [str(main.cashiers.map(func(c): return c.get_node("Cashier").total_sold - sold0[c.name])), max_q])
	check(rung.size() >= 4, "C5: with a full crowd, sales rang at %d of 5 registers %s" % [rung.size(), str(rung)])
	finish()

## --- EVENTS AT EVERY STAGE ------------------------------------------------------

func _run_events() -> void:
	main.events_on = true
	await wait_until(func(): return main.shift_active and main.players.has(1), 30.0)
	await wait(0.5)
	player().teleport_to(main.areas.anchor("player_spawn"))
	pin_manager(out_of_the_way(), 0.0)
	main.lifetime_earned = 1000000
	var ev: Node = main.events
	for stage in range(2, 5):
		main.sections_owned = stage
		main._reconfigure_world()
		await wait(0.3)
		if not main.store_open:
			main.open_store(1)
		var open_names: Array = main._unlocked_sections().map(func(x): return x["name"])
		for k in ev.EVENT_ORDER:
			if not ev.unlocked(k):
				continue
			main.shift_time_left = 2000.0
			# Stock on every open shelf's floor so a rush / catering order can plan.
			for sec in open_names:
				for i in 6:
					main.spawn_product_at(sec, main._spawn_pos_in_section(main.SECTIONS[main.section_index(sec)]))
			ev.force_next(k, 0.1)
			var started := await wait_until(func(): return ev.active() and ev.key == k, 30.0)
			check(started, "GE%d %s: starts with %d sections open" % [stage, ev.name_of(k), stage])
			if not started:
				continue
			var d: Dictionary = ev.data
			match k:
				"rush":
					check(d["section"] in open_names, "GE%d rush: its section %s is an open wing" % [stage, d["section"]])
				"leak":
					await wait(ev.LEAK_DROP_GAP * 2.5)
					var bad := []
					var door: Vector2 = main.areas.anchor("front_door") + Vector2(0, -40)
					var bn: RefCounted = Spots.nav(main)
					bn.invalidate()
					for pd in main.cleanup.puddles:
						var pos: Vector2 = pd["pos"]
						if not main.areas.is_open_shop_floor_at(pos) or not bn.reachable(door, pos):
							bad.append(str(pos.round()))
					check(not main.cleanup.puddles.is_empty() and bad.is_empty(), "GE%d leak: %d leaks, all on open shop floor a player can reach %s" % [stage, main.cleanup.puddles.size(), str(bad)])
				"delivery", "catering":
					var secs: Array = d.get("needs", {}).keys()
					check(not secs.is_empty() and secs.all(func(x): return x in open_names), "GE%d %s: wants only open wings %s" % [stage, k, str(secs)])
				"inspection":
					check(true, "GE%d inspection: running" % stage)
			ev._on_time_up()
			await wait_until(func(): return not ev.busy(), 10.0)
			for pd in main.cleanup.puddles.duplicate():
				main.cleanup.remove_puddle(int(pd["id"]))
	finish()

## --- SAVE / RELOAD -------------------------------------------------------------

func _save_path() -> String:
	return _arg("--save-file=", "user://growth_test/save.json")

func _prepare_save_phase() -> void:
	var path := _save_path()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var phase := int(_arg("--phase=", "1"))
	if phase == 1:
		for f in [path, path + ".tmp", path + ".bad", path + ".v1.bak"]:
			if FileAccess.file_exists(f):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	elif phase == 3:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(FileAccess.get_file_as_string(OLD_SAVE_FIXTURE))
		f.close()

func _run_save() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 30.0)
	await wait(0.5)
	var phase := int(_arg("--phase=", "1"))
	match phase:
		1:
			check(main.sections_owned == 1, "GS1: a new game owns Dry Goods only")
			main.money = 10000
			check(main.buy_section("Produce", 1) and main.buy_section("Dairy/Frozen", 1), "GS1: bought Produce and Dairy/Frozen at prep")
			await wait(main.growth.KNOCK_SECONDS + 0.3)
			check(main.save_progress("growth test"), "GS1: saved")
			var data = JSON.parse_string(FileAccess.get_file_as_string(_save_path()))
			check(data is Dictionary and int(data.get("version", 0)) == 6, "GS1: the save is still version 6 (no format change) — %s" % str(data.get("version", "?") if data is Dictionary else "unreadable"))
		2:
			check(main.sections_owned == 3, "GS2: the reloaded crew owns 3 sections (%d)" % main.sections_owned)
			check(_stage_wrong(3) == "", "GS2: Produce and Dairy/Frozen are open wings, Bakery a closed lot %s" % _stage_wrong(3))
			check(main.growth.animations_played.is_empty(), "GS2: no knock-out on reload — the store is simply grown %s" % str(main.growth.animations_played))
			_check_nav("reload")
		3:
			var data = JSON.parse_string(FileAccess.get_file_as_string(OLD_SAVE_FIXTURE))
			var want: int = int(data["shop"]["sections_owned"])
			check(main.load_status == load("res://SaveGame.gd").LOAD_OK, "GS3: a v6 save written by the old layout's code loads (status %d)" % main.load_status)
			check(main.sections_owned == want and want >= 2, "GS3: its %d bought sections are intact (%d)" % [want, main.sections_owned])
			check(_stage_wrong(want) == "", "GS3: ...and they're open wings in the new store %s" % _stage_wrong(want))
			var want_cans: Array = data["upkeep"]["cans"]
			var got: Array = main.cleanup.cans.map(func(c): return int(c))
			check(got == want_cans.map(func(c): return int(c)), "GS3: trash-can fills land by index in the new cans %s (saved %s)" % [str(got), str(want_cans)])
	finish()
