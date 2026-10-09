extends "res://tools/hazards_test.gd"
## OCT 2026 PHASE 3D — STORE UPKEEP AND THE LIVE STORE RATING. Regression tests
## for trash cans, the dumpster, mop/broom roles, the store rating and its
## economy levers, throwing out troublemakers, the live earnings counter and
## the save's v4 fields. Reuses tools/hazards_test.gd's helpers and drives the
## real Main.tscn. Real wall-clock time (no --fixed-fps). Not part of the game.
##
## CUSTOMER RIDE (Phase 3C carry-over): a customer walking DOWN into a product,
## a delivery box and a floor display must not ride it (Player.gd's fix, see
## its _ready()):
##   godot --headless --path . --script res://tools/upkeep_test.gd -- --server --day=5 --no-save --test=customer-ride
## TRASH (hand pickup, cans, overflow, bags, the dumpster), solo, real keys:
##   godot ... -- --server --day=3 --no-save --test=trash
## TOOLS (mop-only spills/puddles, the broom's piles, tools all day):
##   godot ... -- --server --day=6 --no-save --test=tools
## RATING (the formula, its smoothing, and its MEASURED effect on the crowd
## and on what a sale pays):
##   godot ... -- --server --day=7 --no-save --test=rating
## EARNINGS (the HUD's "Today" counter = Pay Today, all shift and at clock-out):
##   godot ... -- --server --day=3 --no-save --test=earnings
## BOUNCE (throwing a troublemaker out: success, refusals, toss, wriggle):
##   godot ... -- --server --day=3 --no-save --test=bounce
## SAVE (v4 round trip; a v3 save; a damaged upkeep block), in order:
##   godot ... -- --server --save-file=user://upkeep_test/save.json --test=save --phase=1   (then 2, 3, 4)
## CO-OP (host + 2 clients: races on cans, bags and a customer; forged
## requests; everyone sees the same cans, rating and counter):
##   godot ... -- --server --port=8975 --day=3 --players=3 --no-save --test=net-upkeep &
##   (x2) godot ... -- --client --connect-port=8975 --no-save --test=net-upkeep
## SHOTS (xvfb, not headless): screenshots for the report:
##   xvfb-run -a godot --path . --script res://tools/upkeep_test.gd -- --server --day=7 --no-save --test=shots

var _mode := ""
const NET_DIR_DEFAULT := "user://net_upkeep/"

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--test="):
			_mode = a.substr(7)
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	# OCT 2026 PHASE 4: random events (Events.gd) are off here — tools/events_test.gd
	# tests them; --events=on turns them on (the income runs measure both).
	main.events_on = "--events=on" in OS.get_cmdline_user_args()
	main.opening_stock_fraction = 1.0
	if not _mode in ["earnings", "net-upkeep"]:
		main.cleanup_ceiling_override = 0.0
	if _mode == "income-crew":
		main.opening_stock_fraction = 0.0
	var client := "--client" in args
	if OS.get_environment("SW_NET_DIR") == "":
		NET_DIR = NET_DIR_DEFAULT
	if _mode == "save":
		_prepare_save_phase()
	if _mode == "net-upkeep" and not client:
		var d := DirAccess.open(NET_DIR)
		if d:
			for f in d.get_files():
				d.remove(f)
	match _mode:
		"customer-ride": _run_customer_ride.call_deferred()
		"trash": _run_trash.call_deferred()
		"tools": _run_tools.call_deferred()
		"rating": _run_rating.call_deferred()
		"earnings": _run_earnings.call_deferred()
		"bounce": _run_bounce.call_deferred()
		"save": _run_save.call_deferred()
		"shots": _run_shots.call_deferred()
		"income-crew": _run_income_crew.call_deferred()
		"net-upkeep": (_run_net_client if client else _run_net_host).call_deferred()
		_:
			print("FAIL  unknown --test=%s" % _mode)
			quit(1)

## --- helpers --------------------------------------------------------------------

func park_world() -> void:
	main.test_hold_customers = true
	main.forklift._pause_timer = 1.0e9
	pin_manager(Vector2(480, 1350), 0.0)
	main._order_timer = 1.0e9
	main.ambience._spill_timer = 1.0e9
	main.ambience._lights_timer = 1.0e9
	for sp in main.ambience.spills.duplicate():
		main.ambience.remove_spill(int(sp["id"]))
	for c in get_nodes_in_group("customer"):
		c.force_leave()

## A fresh customer of `role` at `pos`, its AI pinned to walk toward `goal`.
func pinned_customer(role: String, pos: Vector2) -> Node2D:
	var before := get_nodes_in_group("customer").size()
	main._spawn_customer(role)
	await wait_until(func(): return get_nodes_in_group("customer").size() > before, 2.0)
	var all := get_nodes_in_group("customer")
	var c: Node2D = all[all.size() - 1]
	c.position = pos
	c.target_position = pos
	c._lifetime_budget = 1.0e9
	c.reset_physics_interpolation()
	return c

## Walks a disruptive customer `dir` into `obj` for `seconds`; returns its peak
## and mean speed (px/s, from real per-frame movement).
func customer_push(c: Node2D, obj: RigidBody2D, dir: Vector2, seconds: float) -> Array:
	var start: Vector2 = c.global_position
	move_body(obj, start + dir * 34.0)
	await physics_frame
	var prev: Vector2 = c.global_position
	var peak := 0.0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		c._retarget_pos = c.global_position + dir * 400.0
		c._retarget_timer = 1.0e9
		var tf := Time.get_ticks_msec()
		await physics_frame
		var dt: float = maxf((Time.get_ticks_msec() - tf) / 1000.0, 1.0 / 60.0)
		peak = maxf(peak, (c.global_position - prev).length() / dt)
		prev = c.global_position
	var secs: float = maxf((Time.get_ticks_msec() - t0) / 1000.0, 1.0 / 60.0)
	return [peak, c.global_position.distance_to(start) / secs, obj.global_position.distance_to(start + dir * 34.0)]

## --- customer ride ---------------------------------------------------------------

## Customer.SPEED is 90. The ride bug: a SUSTAINED 1.4-2x mean and ~1000px/s
## peaks. A single frame's depenetration on first contact can read ~3x (seen
## once under load, mean still 89), so the peak cap only catches the ride.
const CUSTOMER_PEAK_MULT := 4.0

func _run_customer_ride() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 15.0)
	park_world()
	player().teleport_to(Vector2(480, 270))
	await wait(0.5)
	var speed: float = 90.0
	var cases := []
	for obj_kind in ["product", "box", "display"]:
		for dir_name in ["down", "up", "left", "right"]:
			cases.append([obj_kind, dir_name])
	var i := 0
	for cs in cases:
		var dir: Vector2 = {"down": Vector2.DOWN, "up": Vector2.UP, "left": Vector2.LEFT, "right": Vector2.RIGHT}[cs[1]]
		var start := Vector2(1100 + (i % 4) * 160, 560) if cs[1] == "down" else (Vector2(1100 + (i % 4) * 160, 860) if cs[1] == "up" else Vector2(1500 if cs[1] == "left" else 1100, 600 + (i % 4) * 60))
		var obj: RigidBody2D = null
		match cs[0]:
			"product": obj = _loose_product()
			"box":
				var before := get_nodes_in_group("delivery_box").size()
				main.delivery.drop_box(Vector2(1300, 640), "Dry Goods")
				await wait_until(func(): return get_nodes_in_group("delivery_box").size() > before, 2.0)
				var boxes := get_nodes_in_group("delivery_box")
				obj = boxes[boxes.size() - 1]
			"display":
				obj = main.displays[0]
				obj.get_node("Display").reset_to_home()
		if obj == null:
			check(false, "C%d %s %s: nothing to push" % [i, cs[0], cs[1]])
			continue
		var c := await pinned_customer("disruptive", start)
		await physics_frame
		var r: Array = await customer_push(c, obj, dir, 1.5)
		check(r[0] <= speed * CUSTOMER_PEAK_MULT and r[1] <= speed * 1.05, "C%d customer pushing a %s %s: never rides it (peak %.0fpx/s, mean %.0f, walk %.0f; object moved %.0fpx)" % [i, cs[0], cs[1], r[0], r[1], speed, r[2]])
		c.force_leave()
		if cs[0] == "product":
			move_body(obj, Vector2(1400 + i * 30, 1300))
		elif cs[0] == "box":
			obj.queue_free()
		else:
			obj.get_node("Display").reset_to_home()
		await wait(0.2)
		i += 1
	finish()

func _loose_product() -> RigidBody2D:
	for obj in get_nodes_in_group("carryable"):
		if obj.is_in_group("delivery_box") or obj.get_node("Carryable").carrier_id != 0 or obj.get_node("Carryable").shelved or obj.has_meta("ride_used"):
			continue
		if _is_placed(obj):
			continue
		obj.set_meta("ride_used", true)
		return obj
	return null


## --- shared upkeep helpers --------------------------------------------------------

func cl() -> Node2D:
	return main.cleanup

func rt() -> Node:
	return main.store_rating

func me_id() -> int:
	return main.multiplayer.get_unique_id()

## Puts the player somewhere and lets a frame of physics settle it.
func at(pos: Vector2, facing := 0.0) -> void:
	player().teleport_to(pos)
	if me == 1:
		player().facing_angle = facing
	await physics_frame
	await physics_frame

## One real E press, then a moment for the host (and replication) to answer.
func press_e(settle := 0.25) -> void:
	await tap(act + "interact")
	await wait(settle)

func press_f(settle := 0.25) -> void:
	await tap(act + "throw")
	await wait(settle)

## Clears loose stock out of the hub (so E isn't about stock unless a check
## wants it to be) — host only.
func clear_hub_stock() -> void:
	for obj in get_nodes_in_group("carryable"):
		if main._grid_cell_of(obj.global_position) == main.ENTRANCE_GRID_POS and obj.get_node("Carryable").carrier_id == 0:
			move_body(obj, Vector2(2300 + randf() * 300, 1500))

func clear_floor() -> void:
	cl().litter = []
	cl().puddles = []

## Faces a direction by tapping toward it.
func face(dir: Vector2) -> void:
	if me == 1:
		player().facing_angle = dir.angle()
		await physics_frame
		return
	steer(dir)
	await physics_frame
	steer(Vector2.ZERO)
	await physics_frame

## --- TRASH ----------------------------------------------------------------------

func _run_trash() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 15.0)
	park_world()
	clear_hub_stock()
	clear_floor()
	cl().set_cans([0, 0, 0, 0, 0])
	await wait(0.3)
	var spot := Vector2(1400, 720)
	await at(spot)
	# T1: by hand, one piece at a time, into the hand — not paid yet.
	for k in 4:
		cl().drop_litter(spot + Vector2(10 + k * 6, 4))
	await wait(0.2)
	var pay0: int = main._pay_today()
	await press_e()
	check(cl().hand_count(1) == 1 and cl().litter.size() == 3, "T1: E on litter puts ONE piece in hand (hand %d, floor %d)" % [cl().hand_count(1), cl().litter.size()])
	check(main._pay_today() == pay0, "T1: not paid until it's in a can (pay %s -> %s)" % [main._format_money(pay0), main._format_money(main._pay_today())])
	await press_e()
	await press_e()
	check(cl().hand_count(1) == cl().HAND_MAX, "T1: up to HAND_MAX (%d) in hand" % cl().hand_count(1))
	await press_e()
	check(cl().hand_count(1) == cl().HAND_MAX and cl().litter.size() == 1, "T1: hands full + more litter in reach: E does nothing (no drop) — hint '%s'" % cl().hint_text)
	# T2: holding trash, stock can't be picked up.
	var prod := _loose_product()
	move_body(prod, player().global_position + Vector2(24, 0))
	await wait(0.2)
	await press_e()
	check(prod.get_node("Carryable").carrier_id == 0 and cl().hand_count(1) == cl().HAND_MAX, "T2: trash in hand, E never grabs stock")
	move_body(prod, Vector2(2400, 1500))
	cl().litter = []
	# T3: binned at a can: paid then, can fills, counter matches.
	await at(cl().BINS[0]["pos"] + Vector2(0, 30))
	await press_e()
	check(cl().hand_count(1) == 0 and int(cl().cans[0]) == 3, "T3: E at a can bins the handful (hand %d, can %d)" % [cl().hand_count(1), cl().cans[0]])
	check(cl().litter_pay_today() == 3 and main._pay_today() == pay0 + 3, "T3: +$3 when it went in the can (trash pay %s, pay %s)" % [main._format_money(cl().litter_pay_today()), main._format_money(main._pay_today())])
	check(cl().stat(1, "binned") == 3, "T3: per-player tally (binned %d)" % cl().stat(1, "binned"))
	await wait(0.2)
	check(rt().today_text == "TODAY  %s" % main._format_money(main._pay_today()), "T3: the HUD counter says it: '%s'" % rt().today_text)
	# T4: a can nearly full takes what fits; the rest stays in hand; a full
	# can refuses.
	cl().set_can(0, cl().CAN_CAPACITY - 1)
	for k in 3:
		cl().drop_litter(spot + Vector2(k * 8, 0))
	await at(spot)
	for k in 3:
		await press_e(0.15)
	await at(cl().BINS[0]["pos"] + Vector2(0, 30))
	await press_e()
	check(int(cl().cans[0]) == cl().CAN_CAPACITY and cl().hand_count(1) == 2, "T4: one fit, two stay in hand (can %d, hand %d)" % [cl().cans[0], cl().hand_count(1)])
	await press_e()
	check(cl().hand_count(1) == 2 and cl().action_for(1, player().global_position, false) == "can_full", "T4: a FULL can takes nothing; hint '%s'" % cl().hint_text)
	# T5: a full can overflows: counted against the rating.
	check(cl().full_cans() == 1 and rt()._mess_parts_now()[2] == 1, "T5: a full can counts against the rating (full %d)" % cl().full_cans())
	check(_can_heap_visible(0), "T5: the full can shows its overflow heap")
	# T6: E away from cans and litter drops the handful back on the floor.
	await at(spot + Vector2(0, 120))
	await press_e()
	check(cl().hand_count(1) == 0 and cl().litter.size() == 2, "T6: E with nowhere to put it drops it back (floor %d)" % cl().litter.size())
	cl().litter = []
	# T7: a bag out of the full can: the can's empty, you carry n pieces, slower.
	await at(cl().BINS[0]["pos"] + Vector2(0, 30))
	await press_e()
	var b: int = cl().bag_of(1)
	check(b >= 0 and int(cl().bags[b]["n"]) == cl().CAN_CAPACITY and int(cl().cans[0]) == 0, "T7: E at a full can lifts its bag out (bag %s, can %d)" % [str(cl().bags[b]) if b >= 0 else "none", cl().cans[0]])
	check(cl().full_cans() == 0, "T7: no full can any more")
	check(is_equal_approx(cl().speed_mult(1), cl().BAG_SPEED_MULT) and player().speed() < 220.0 * 0.9, "T7: carrying it slows you (%.0fpx/s)" % player().speed())
	# T8: set down = a mess; picked back up.
	await at(Vector2(1500, 900))
	await press_e()
	check(cl().bag_of(1) < 0 and cl().loose_bags() == 1 and rt()._mess_parts_now()[2] == 1, "T8: E away from the dumpster sets it down — a bag on the floor counts like a full can")
	await press_e()
	check(cl().bag_of(1) >= 0, "T8: E picks it back up")
	# T9: walked out back to the dumpster, tipped in.
	var walked := await walk_to(cl().DUMPSTER_POS + Vector2(0, -70), 12.0, 40.0)
	check(walked, "T9: walked the bag out back to the dumpster (at %s)" % str(player().global_position.round()))
	await press_e()
	check(cl().bags.is_empty() and cl().bags_dumped_today == 1 and cl().stat(1, "dumped") == 1, "T9: E at the dumpster tips it in (dumped %d)" % cl().bags_dumped_today)
	# T10: the dumpster is solid and on the shoppers' grid.
	check(_dumpster_blocks(), "T10: the dumpster is solid (a body can't walk through it)")
	var nav: RefCounted = main._customer_nav
	if nav == null:
		main.customer_path(Vector2(1440, 1000), Vector2(1440, 700))
		nav = main._customer_nav
	nav.invalidate()
	main.customer_path(Vector2(1440, 1000), Vector2(1440, 700))
	check(nav._astar.is_point_solid(nav._to_cell(cl().DUMPSTER_POS)), "T10: and marked solid on the shoppers' navigation grid")
	# T11: cans keep their trash into the next shift; bags go back in their can.
	cl().set_can(1, 7)
	await at(cl().BINS[1]["pos"] + Vector2(0, 30))
	await press_e()
	check(cl().bag_of(1) >= 0 and int(cl().cans[1]) == 0, "T11: took Dry Goods' bag (7)")
	cl().set_can(0, 4)
	main.shift_time_left = 0.5
	await wait_until(func(): return main.is_day_report_active(), 10.0)
	check(int(cl().cans[0]) == 4 and int(cl().cans[1]) == 7 and cl().bags.is_empty(), "T11: at clock-out a bag still out goes back in its can; cans keep their trash (cans %s)" % str(cl().cans))
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 10.0)
	check(int(cl().cans[0]) == 4 and int(cl().cans[1]) == 7, "T11: still there next shift (cans %s)" % str(cl().cans))
	finish()

## Drops `n` pieces in a tight pile at `pile`, then clears it by hand, HAND_MAX
## a trip, into the hub can. Returns the seconds it took.
func _clear_by_hand(pile: Vector2, n: int) -> float:
	cl().litter = []
	for k in n:
		cl().drop_litter(pile + Vector2((k % 4) * 12 - 18, (k / 4) * 12 - 12))
	var can_spot: Vector2 = cl().BINS[0]["pos"] + Vector2(0, 30)
	await at(pile + Vector2(0, -120))
	var t0 := Time.get_ticks_msec()
	while not cl().litter.is_empty() or cl().hand_count(1) > 0:
		if cl().hand_count(1) < cl().HAND_MAX and not cl().litter.is_empty():
			var nxt: Vector2 = cl().litter[0]["pos"]
			if player().global_position.distance_to(nxt) > 40.0:
				await walk_to(nxt, 20.0, 15.0)
			await press_e(0.1)
		else:
			await walk_to(can_spot, 14.0, 15.0)
			_make_room()
			await press_e(0.1)
		if Time.get_ticks_msec() - t0 > 60000:
			break
	return (Time.get_ticks_msec() - t0) / 1000.0

## The timed runs measure picking up, not the dumpster run: a teammate's
## taken the hub can's bag whenever it's full.
func _make_room() -> void:
	if cl().can_full(0):
		cl().set_can(0, 0)

## Same pile, with the broom (fetched from the hub rack first if `fetch`):
## sweep (HOLD place), empty the pan at the can, repeat until it's gone.
func _clear_by_broom(pile: Vector2, n: int, fetch: bool) -> float:
	if fetch:
		cl().litter = []
		for k in n:
			cl().drop_litter(pile + Vector2((k % 4) * 12 - 18, (k / 4) * 12 - 12))
	elif cl().litter.is_empty():
		for k in n:
			cl().drop_litter(pile + Vector2((k % 3) * 14 - 14, (k / 3) * 14 - 7))
	var can_spot: Vector2 = cl().BINS[0]["pos"] + Vector2(0, 30)
	var t0 := Time.get_ticks_msec()
	if fetch:
		await walk_to(cl().TOOL_SPOTS[5] + Vector2(0, 26), 12.0, 15.0)
		await press_e(0.1)
	while not cl().litter.is_empty() or (cl().tool_of(1) >= 0 and int(cl().tools[cl().tool_of(1)]["pan"]) > 0):
		var held: int = cl().tool_of(1)
		if held < 0:
			break
		if not cl().litter.is_empty() and not cl().tools[held]["full"]:
			await walk_to(pile - Vector2(cl().BROOM_HEAD_OFFSET, 0), 10.0, 15.0)
			await face(Vector2.RIGHT)
			press("host_place")
			await wait_until(func(): return cl().litter.is_empty() or cl().tools[cl().tool_of(1)]["full"], 3.0)
			press("host_place", 0.0)
		else:
			await walk_to(can_spot, 14.0, 15.0)
			_make_room()
			await press_e(0.1)
		if Time.get_ticks_msec() - t0 > 60000:
			break
	return (Time.get_ticks_msec() - t0) / 1000.0

func _can_heap_visible(i: int) -> bool:
	return cl()._can_fx[i].get_node("Heap").visible

## A test body pushed into the dumpster stops at its edge.
func _dumpster_blocks() -> bool:
	var space: PhysicsDirectSpaceState2D = main.get_world_2d().direct_space_state
	var q := PhysicsPointQueryParameters2D.new()
	q.position = cl().DUMPSTER_POS
	q.collide_with_bodies = true
	for hit in space.intersect_point(q):
		if hit["collider"] == cl()._dumpster:
			return true
	return false

## --- (stubs filled in below) ---
func _run_tools() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 15.0)
	park_world()
	clear_hub_stock()
	clear_floor()
	cl().set_cans([0, 0, 0, 0, 0])
	await wait(0.3)
	# M0: tools are out during prep (they were cleanup-only).
	check(not main.store_open and not main.cleanup_active, "M0: prep, store closed")
	await at(cl().TOOL_SPOTS[2] + Vector2(0, 26))
	await press_e()
	var held: int = cl().tool_of(1)
	check(held == 2 and cl().tools[held]["kind"] == "mop", "M0: E at the hub rack picks up its mop during prep (holding %d)" % held)
	main.open_store(1)
	await wait(0.3)
	main.test_hold_customers = true
	# M1: a sticky puddle: hands can't take it.
	await press_e() # put the mop down
	check(cl().tool_of(1) < 0, "M1: E puts the mop down")
	var ppos := Vector2(1500, 760)
	cl().drop_puddle(ppos, 18.0)
	await at(ppos + Vector2(-20, 0))
	await press_e()
	check(cl().puddles.size() == 1 and cl().hand_count(1) == 0 and not cl().holds_anything(1), "M1: E on a puddle with empty hands does nothing — liquids need the mop")
	# M2: the mop takes it, mid-shift, by holding the place key.
	await at(cl().TOOL_SPOTS[2] + Vector2(0, 26))
	await press_e()
	check(cl().tool_of(1) >= 0, "M2: mop back in hand (store open)")
	await at(ppos - Vector2(cl().MOP_HEAD_OFFSET, 0), 0.0)
	await face(Vector2.RIGHT)
	var t0 := Time.get_ticks_msec()
	press("host_place")
	var gone := await wait_until(func(): return cl().puddles.is_empty(), 5.0)
	press("host_place", 0.0)
	check(gone and cl().stat(1, "mopped") == 1, "M2: held C on it: mopped up in %.1fs" % ((Time.get_ticks_msec() - t0) / 1000.0))
	check(main.manager._is_carrying(1), "M2: holding a mop counts as busy for the manager")
	# M3: a floor spill (stage 4) too.
	var sid: int = main.ambience.spawn_spill(Vector2(1500, 640), 40.0)
	await wait(0.2)
	await at(Vector2(1500, 640) - Vector2(cl().MOP_HEAD_OFFSET + 20, 0), 0.0)
	await face(Vector2.RIGHT)
	press("host_place")
	gone = await wait_until(func(): return not main.ambience.spills.any(func(sp): return sp["id"] == sid), 6.0)
	press("host_place", 0.0)
	check(gone, "M3: a floor spill mopped mid-shift")
	# M4: knocked stock mid-shift is just stock to put back — the mop leaves it.
	var prod := _loose_product()
	move_body(prod, player().global_position + Vector2(cl().MOP_HEAD_OFFSET, 0))
	prod.set_meta("knocked", true)
	press("host_place")
	await wait(1.6)
	press("host_place", 0.0)
	check(is_instance_valid(prod) and not prod.is_queued_for_deletion(), "M4: the mop doesn't bin knocked stock mid-shift")
	if is_instance_valid(prod):
		prod.remove_meta("knocked")
		move_body(prod, Vector2(2400, 1500))
	await press_e() # mop down
	# B1: a pile — the broom takes it all in one pass; hands take three a trip.
	# Two timed cases, real keys, the hub can ~260px from the pile:
	# (a) 6 pieces, broom already in hand vs by hand (2 trips);
	# (b) 12 pieces, broom FETCHED from the hub rack vs by hand (4 trips).
	var pile := Vector2(1300, 820)
	var can_spot: Vector2 = cl().BINS[0]["pos"] + Vector2(0, 30)
	var hand6 := await _clear_by_hand(pile, 6)
	check(cl().litter.is_empty() and cl().stat(1, "binned") >= 6, "B1: by hand: 6 pieces, 2 trips, %.1fs" % hand6)
	await walk_to(cl().TOOL_SPOTS[5] + Vector2(0, 26), 12.0, 15.0)
	await press_e(0.12)
	var b_held: int = cl().tool_of(1)
	check(b_held >= 0 and cl().tools[b_held]["kind"] == "broom", "B2: broom from the hub rack")
	cl().set_can(0, 0)
	var pay_before: int = cl().litter_pay_today()
	var can_before: int = cl().cans[0]
	var broom6 := await _clear_by_broom(pile, 6, false)
	check(cl().stat(1, "swept") == 6 and int(cl().cans[0]) == can_before + 6 and cl().litter_pay_today() == pay_before + 6, "B2: one pass swept all 6 into the pan; emptied into the can, paid then (+$%d)" % (cl().litter_pay_today() - pay_before))
	check(broom6 < hand6, "B2: broom in hand beats hands on a 6-piece pile (%.1fs vs %.1fs)" % [broom6, hand6])
	await at(cl().TOOL_SPOTS[5] + Vector2(0, 26))
	await press_e() # broom down at the rack
	cl().tools = cl()._fresh_tools()
	cl().set_can(0, 0)
	var hand12 := await _clear_by_hand(pile, 12)
	cl().set_can(0, 0)
	await at(Vector2(1300, 700))
	var broom12 := await _clear_by_broom(pile, 12, true)
	print("INFO  BROOM VS HANDS (pile 260px from the can, rack ~540px away): 6 pieces — hands %.1fs, broom in hand %.1fs; 12 pieces — hands %.1fs, broom fetched from the rack %.1fs" % [hand6, broom6, hand12, broom12])
	check(broom12 < hand12, "B3: a 12-piece mess: fetching the broom still wins (%.1fs vs %.1fs by hand)" % [broom12, hand12])
	await at(cl().TOOL_SPOTS[5] + Vector2(0, 60))
	if cl().tool_of(1) < 0:
		await walk_to(cl().TOOL_SPOTS[5] + Vector2(0, 26), 12.0, 15.0)
		await press_e(0.12)
	# B4: the pan won't go into a full can.
	cl().set_can(0, cl().CAN_CAPACITY)
	cl().drop_litter(pile)
	await walk_to(pile - Vector2(cl().BROOM_HEAD_OFFSET, 0), 10.0, 15.0)
	await face(Vector2.RIGHT)
	press("host_place")
	await wait_until(func(): return cl().litter.is_empty(), 3.0)
	press("host_place", 0.0)
	await walk_to(can_spot, 12.0, 15.0)
	check(cl().action_for(1, player().global_position, false) == "tool_put", "B4: at a full can the pan can't be emptied (E would put the broom down)")
	await press_e()
	# S1: loose stock beside the rack: E is about the stock, not the tool.
	await at(cl().TOOL_SPOTS[2] + Vector2(0, 26))
	var p2 := _loose_product()
	move_body(p2, player().global_position + Vector2(0, 40))
	await wait(0.2)
	await press_e()
	check(p2.get_node("Carryable").carrier_id == 1 and cl().tool_of(1) < 0, "S1: loose stock in reach of the rack: E grabs the stock, not a tool")
	finish()

func _run_rating() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 15.0)
	park_world()
	clear_floor()
	cl().set_cans([0, 0, 0, 0, 0])
	await at(Vector2(480, 270))
	var n_sec: int = main._unlocked_sections().size()
	var per_star: float = rt().mess_per_star()
	check(n_sec == 4 and is_equal_approx(per_star, rt().MESS_PER_STAR_BASE + rt().MESS_PER_STAR_PER_SECTION * 3), "R1: whole store open: %.0f mess points a star" % per_star)
	# R0: the rating doesn't move in prep (no customers to judge it).
	rt().set_rating(4.0)
	for k in 30:
		cl().drop_litter(Vector2(1100 + k * 20, 700))
	await wait(2.0)
	check(is_equal_approx(rt().rating, 4.0), "R0: prep: 30 litter on the floor, the rating holds (%.2f)" % rt().rating)
	main.open_store(1)
	main.test_hold_customers = true
	await wait(0.2)
	# R1: the target formula, piece by piece.
	clear_floor()
	await wait(0.2)
	check(is_equal_approx(rt().target_for(rt().mess_points()), 5.0), "R1: a clean store targets 5 stars")
	for k in 12:
		cl().drop_litter(Vector2(1100 + k * 30, 700))
	cl().drop_puddle(Vector2(1300, 820), 18.0)
	cl().set_can(0, cl().CAN_CAPACITY)
	await wait(0.2)
	var mess: float = rt().mess_points()
	check(is_equal_approx(mess, 12.0 + 3.0 + 4.0), "R1: 12 litter + a puddle + a full can = %.0f points (1 / 3 / 4 each)" % mess)
	check(is_equal_approx(rt().target, 5.0 - mess / per_star), "R1: target %.2f = 5 - %.0f / %.0f" % [rt().target, mess, per_star])
	# R2: smoothing — falls at most a star a minute, rises slower.
	rt().set_rating(5.0)
	clear_floor()
	for k in 40:
		cl().drop_litter(Vector2(1000 + (k % 20) * 40, 640 + (k / 20) * 40))
	var t0 := Time.get_ticks_msec()
	await wait(6.0)
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	var fell: float = 5.0 - rt().rating
	check(fell > 0.0 and fell <= secs * rt().FALL_PER_SEC + 0.02, "R2: a big mess: fell %.3f in %.1fs (cap %.3f) — no whiplash" % [fell, secs, secs * rt().FALL_PER_SEC])
	check(rt().trend() == -1, "R2: trend arrow: falling")
	clear_floor()
	cl().set_cans([0, 0, 0, 0, 0])
	rt().set_rating(2.0)
	t0 = Time.get_ticks_msec()
	await wait(6.0)
	secs = (Time.get_ticks_msec() - t0) / 1000.0
	var rose: float = rt().rating - 2.0
	check(rose > 0.0 and rose <= secs * rt().RISE_PER_SEC + 0.02 and rt().RISE_PER_SEC < rt().FALL_PER_SEC, "R2: clean again: rose %.3f in %.1fs (slower than it falls)" % [rose, secs])
	check(rt().trend() == 1, "R2: trend arrow: rising")
	# R3/R4: what it DOES — the crowd and the price, measured with real
	# shoppers buying off stocked shelves (rating frozen at each level).
	main.rating_frozen = true
	main.test_hold_customers = false
	var results := {}
	for r in [1.0, 3.0, 5.0]:
		rt().set_rating(r)
		for c in get_nodes_in_group("customer"):
			c.force_leave()
		await wait(0.5)
		var sold0: int = main._total_sold()
		var gross0: int = main._gross_pay_today()
		var prio0: int = main.priority_sales_today
		var peak := 0
		var samples := 0
		var total := 0
		var t := 0.0
		while t < 40.0:
			if fmod(t, 3.0) < 0.5:
				_stock_all()
			await wait(0.5)
			t += 0.5
			var live := get_nodes_in_group("customer").filter(func(c): return not c.is_queued_for_deletion()).size()
			peak = maxi(peak, live)
			if t > 6.0:
				samples += 1
				total += live
		var sold: int = main._total_sold() - sold0
		var paid: int = main._gross_pay_today() - gross0 - main._priority_bonus(main.priority_sales_today - prio0)
		results[r] = {"cap": main.customer_cap(), "peak": peak, "avg": float(total) / maxi(1, samples), "sold": sold, "per_sale": float(paid) / maxi(1, sold)}
		print("INFO  RATING %.0f★: cap %d, customers in store peak %d avg %.1f, %d sales paid $%d ($%.2f each)" % [r, main.customer_cap(), peak, results[r]["avg"], sold, paid, results[r]["per_sale"]])
	var base: int = main._customer_baseline()
	for r in results:
		var want_cap := roundi(base * rt().lerp3(r, main.RATING_CROWD_MULT))
		check(results[r]["cap"] == want_cap and results[r]["peak"] == want_cap, "R3: %.0f★: the store fills to %d customers (cap %d = %d x %.2f)" % [r, results[r]["peak"], results[r]["cap"], base, rt().lerp3(r, main.RATING_CROWD_MULT)])
		check(results[r]["sold"] > 0 and is_equal_approx(results[r]["per_sale"], float(roundi(main.PAY_PER_SALE * rt().lerp3(r, main.RATING_PRICE_MULT)))), "R4: %.0f★: every sale paid $%.2f (%d sales)" % [r, results[r]["per_sale"], results[r]["sold"]])
	main.rating_frozen = false
	# R5: it carries into the next shift.
	rt().set_rating(4.3)
	main.shift_time_left = 0.3
	await wait_until(func(): return main.is_day_report_active(), 10.0)
	var at_close: float = rt().rating
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 10.0)
	check(is_equal_approx(rt().rating, at_close) and absf(at_close - 4.3) < 0.05, "R5: the rating carries into the next shift (%.3f at close, %.3f now)" % [at_close, rt().rating])
	finish()

## Every empty slot of every open section gets a fresh unit (a perfect crew).
func _stock_all() -> void:
	for sec in main._unlocked_sections():
		for sb in main.shelves:
			if main._grid_cell_of(sb.global_position) != sec["grid_pos"]:
				continue
			var shelf: Node = sb.get_node("Shelf")
			if shelf.wrecked:
				continue
			for i in shelf.slots.size():
				var occ = shelf._occupant[i]
				if occ == null or not is_instance_valid(occ) or occ.is_queued_for_deletion():
					main.spawn_product_at(sec["name"], shelf.slots[i].global_position)

func _run_earnings() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 15.0)
	await at(Vector2(1440, 700))
	_stock_all()
	await wait(0.5)
	main.open_store(1)
	main.forklift._pause_timer = 1.0e9
	await wait(0.5)
	check(rt().hud_visible and rt().today_text == "TODAY  $0", "N1: the HUD counter is up from the start: '%s'" % rt().today_text)
	# N2: a live shift — sales, trash binned, a bounce — and the counter
	# equals Pay Today on every frame.
	var mismatches := 0
	var samples := 0
	var rises := 0
	var last := 0
	var t := 0.0
	var bounced := false
	var lagged := 0
	var t_start := Time.get_ticks_msec()
	var next_stock := 0.0
	while t < 45.0:
		t = (Time.get_ticks_msec() - t_start) / 1000.0
		if t >= next_stock:
			next_stock = t + 2.0
			_stock_all()
		if t > 6.0 and not bounced and cl().hand_count(1) == 0:
			bounced = true
			var red := await pinned_customer("disruptive", Vector2(1440, 1030))
			_pin_ai(red)
			await at(Vector2(1440, 994), PI * 0.5)
			red.position = player().global_position + Vector2(0, 40)
			await press_e(0.1)
			await wait_until(func(): return red.escorted_by == 1, 2.0)
			await face(Vector2.DOWN)
			await press_f(0.1)
			await wait_until(func(): return main.bounced_today > 0, 3.0)
		elif t > 10.0 and cl().hand_count(1) == 0 and cl().litter.size() < 3:
			cl().drop_litter(cl().BINS[0]["pos"] + Vector2(40, 30))
			await at(cl().BINS[0]["pos"] + Vector2(40, 30))
			await press_e(0.05)
			await at(cl().BINS[0]["pos"] + Vector2(0, 30))
			await press_e(0.05)
		await process_frame
		await process_frame
		samples += 1
		var shown: String = rt().today_text
		var pay: int = main._pay_today()
		# The HUD redraws in _process; a sale can land in the physics step
		# after it. One frame behind is a redraw, two in a row is a wrong
		# number.
		if shown != "TODAY  %s" % main._format_money(pay):
			await process_frame
			if rt().today_text != "TODAY  %s" % main._format_money(main._pay_today()):
				mismatches += 1
			else:
				lagged += 1
		if pay > last:
			rises += 1
		last = pay
	check(samples > 100 and mismatches == 0, "N2: counter == Pay Today on all %d samples of a live shift (pay %s; went up %d times; %d samples a frame behind, caught up the next frame)" % [samples, main._format_money(main._pay_today()), rises, lagged])
	check(main.bounced_today >= 1 and cl().trash_binned_today >= 1 and main._total_sold() - main._sold_at_day_start > 0, "N2: ...with sales (%d), trash binned (%d) and a bounce (%d) in it" % [main._total_sold() - main._sold_at_day_start, cl().trash_binned_today, main.bounced_today])
	# N3: cleanup: the counter carries the bonus the floor would earn now.
	for k in 4:
		cl().drop_litter(Vector2(1300 + k * 30, 760))
	main.shift_time_left = 0.2
	await wait_until(func(): return main.cleanup_active, 5.0)
	await wait(0.4)
	var gross: int = main._gross_pay_today()
	var live_bonus: int = cl().bonus_for(gross)
	check(rt().today_text == "TODAY  %s" % main._format_money(main._pay_today() + live_bonus), "N3: during cleanup the counter shows pay + the cleanliness bonus so far (%s, bonus %s)" % [rt().today_text, main._format_money(live_bonus)])
	# Clean some up: the counter climbs.
	await at(Vector2(1300, 760))
	await press_e(0.1)
	await press_e(0.1)
	await at(cl().BINS[0]["pos"] + Vector2(0, 30))
	await press_e(0.3)
	var shown_before_out: String = rt().today_text
	var money0: int = main.money
	main.clock_out(1)
	await wait_until(func(): return main.is_day_report_active(), 5.0)
	await process_frame
	await process_frame
	var report_pay: int = main._pay_today()
	check(shown_before_out == "TODAY  %s" % main._format_money(report_pay), "N4: the last counter before clock-out (%s) == the report's Pay Today (%s)" % [shown_before_out, main._format_money(report_pay)])
	check(main.money - money0 == report_pay - main.staff.wages_today, "N4: and that's what went in the bank (+%s, wages %s)" % [main._format_money(main.money - money0), main._format_money(main.staff.wages_today)])
	check(not rt().hud_visible, "N4: the counter steps aside for the report")
	finish()

func _run_bounce() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 15.0)
	park_world()
	clear_hub_stock()
	main.open_store(1)
	await wait(0.3)
	main.test_hold_customers = true
	for c in get_nodes_in_group("customer"):
		c.force_leave()
	await wait(0.3)
	var spot := Vector2(1440, 700)
	# E1: refusals. A shopper can't be grabbed (paying customers stay).
	var shopper := await pinned_customer("shopper", spot + Vector2(40, 0))
	await at(spot)
	check(player().grabbable_customer() == null, "E1: a shopper isn't grabbable (E does nothing to them)")
	await press_e()
	check(shopper.escorted_by == 0, "E1: E next to a shopper: not grabbed")
	check(not main.grab_customer(1, shopper.name), "E1: the host refuses a grab on a shopper (a forged request)")
	shopper.force_leave()
	var red := await pinned_customer("disruptive", spot + Vector2(40, 0))
	_pin_ai(red)
	# Out of reach (host check, forged).
	red.position = spot + Vector2(200, 0)
	await physics_frame
	check(not main.grab_customer(1, red.name), "E1: out of reach (200px): refused")
	red.position = spot + Vector2(40, 0)
	await physics_frame
	# Hands full (stock): refused.
	var prod := _loose_product()
	move_body(prod, spot + Vector2(0, 40))
	await wait(0.1)
	prod.get_node("Carryable").try_pickup(1, player().global_position)
	await wait(0.2)
	check(not main.grab_customer(1, red.name) and red.escorted_by == 0, "E1: holding stock: refused")
	prod.get_node("Carryable").try_drop(1)
	await wait(0.1)
	move_body(prod, Vector2(2400, 1500))
	# E2: grabbed by real E.
	red.position = player().global_position + Vector2(40, 0)
	await wait(0.1)
	await press_e()
	check(red.escorted_by == 1, "E2: E on a red-ringed customer grabs them")
	check(player().escorting() and main.manager._is_carrying(1), "E2: hauling counts as carrying (manager)")
	check(player().speed() < 220.0 * 0.85, "E2: hauling slows you (%.0fpx/s)" % player().speed())
	# Pinned in front of us as we walk.
	await walk_to(spot + Vector2(0, 120), 10.0, 6.0)
	await wait(0.2)
	var off: float = red.global_position.distance_to(player().global_position)
	check(off < red.ESCORT_OFFSET + 12.0, "E2: they come along, held in front (%.0fpx away)" % off)
	check(main.cleanup.action_for(1, player().global_position, false) == "" and not main.cleanup._hands_free(1), "E2: hands are full while hauling")
	# E3: E lets go — stunned, then they carry on.
	await press_e()
	check(red.escorted_by == 0 and red._stun_timer > 0.0, "E3: E lets go (stunned %.1fs)" % red._stun_timer)
	await wait(1.0)
	# E4: walked out the front door: bounced, paid, gone.
	await at(red.global_position + Vector2(0, -36), PI * 0.5)
	await press_e()
	check(red.escorted_by == 1, "E4: grabbed again")
	var pay0: int = main._pay_today()
	var name_before := String(red.name)
	var walked := await walk_to(Vector2(1440, 1060), 12.0, 15.0)
	steer(Vector2.DOWN)
	var out := await wait_until(func(): return main.bounced_today >= 1, 6.0)
	steer(Vector2.ZERO)
	check(walked and out, "E4: walked them out the front door: BOUNCED (bounced %d)" % main.bounced_today)
	check(main._pay_today() == pay0 + main.BOUNCE_PAY and cl().stat(1, "bounced") == 1, "E4: +$%d on Pay Today (%s -> %s)" % [main.BOUNCE_PAY, main._format_money(pay0), main._format_money(main._pay_today())])
	await wait(0.3)
	check(customers_root_has(name_before) == false, "E4: they're gone")
	# E5: the next one through the door is a shopper.
	check(main.recent_bounces() == 1, "E5: the bounce is remembered for %.0fs" % main.BOUNCE_CALM_SECONDS)
	main.test_hold_customers = false
	main._restock_customers()
	var cap: int = main.customer_cap()
	var want: int = roundi(cap * main.CUSTOMER_DISRUPTIVE_RATIO)
	await wait(0.3)
	var reds := get_nodes_in_group("customer").filter(func(c): return c.role == "disruptive" and not c.is_queued_for_deletion()).size()
	check(reds == maxi(0, want - 1), "E5: restock let in %d troublemaker(s), one fewer than usual (%d)" % [reds, want])
	main.test_hold_customers = true
	for c in get_nodes_in_group("customer"):
		c.force_leave()
	await wait(0.3)
	# E6: tossed (F) through the door from just inside it counts too.
	await at(Vector2(1440, 1020), PI * 0.5)
	red = await pinned_customer("disruptive", Vector2(1440, 1050))
	_pin_ai(red)
	await press_e()
	check(red.escorted_by == 1, "E6: grabbed one by the door")
	await face(Vector2.DOWN)
	var b0: int = main.bounced_today
	await press_f()
	var tossed := await wait_until(func(): return main.bounced_today > b0, 3.0)
	check(tossed, "E6: F tossed them out the door: BOUNCED (bounced %d)" % main.bounced_today)
	# E7: held too long, they wriggle free.
	red = await pinned_customer("disruptive", Vector2(1300, 700))
	_pin_ai(red)
	await at(Vector2(1300, 664), PI * 0.5)
	await press_e()
	check(red.escorted_by == 1, "E7: grabbed")
	red._escort_t = red.ESCORT_MAX_TIME - 0.2
	await wait(0.5)
	check(red.escorted_by == 0 and not player().escorting(), "E7: past ESCORT_MAX_TIME (%.0fs) they wriggle free" % red.ESCORT_MAX_TIME)
	# E8: dragged behind a shelf corner — pulled loose, never through it.
	await wait(1.0)
	var shelf_body: Node2D = main.shelves.filter(func(sb): return main._grid_cell_of(sb.global_position) == Vector2i(1, 0))[0]
	await at(red.global_position + Vector2(0, -36), PI * 0.5)
	await press_e()
	player().teleport_to(shelf_body.global_position + Vector2(0, 0) + Vector2(140, 0))
	await wait(0.4)
	check(red.escorted_by == 0, "E8: yanked far away (teleport): they're pulled loose, not dragged through walls")
	# E9: a shove (Space) on someone being hauled doesn't knock them free.
	finish()

func customers_root_has(n: String) -> bool:
	var c: Node = main.customers_root.get_node_or_null(NodePath(n))
	return c != null and not c.is_queued_for_deletion()

## Keeps a disruptive customer's own AI still (it would chase players and
## shelves) — between grabs it just stands.
func _pin_ai(c: Node2D) -> void:
	c._retarget_pos = c.global_position
	c._retarget_timer = 1.0e9

## SAVES (v4: the store rating and the cans' fill):
## 1: a fresh file; set the rating and the cans, save -> on disk as v4.
## 2: relaunch -> the same rating and cans.
## 3: a version-3 save (pre-3D) -> loads, 3 stars, every can empty, the rest
##    of the shop intact.
## 4: a v4 save with a damaged upkeep block -> cleaned up on load; and the
##    rating/cans written back out are sane.
const V3_SAVE := {
	"version": 3, "saved_at": "2026-10-04T20:00:00",
	"shop": {"completed_day": 4, "money": 640, "lifetime_earned": 1300, "sections_owned": 2, "stage": 2, "lifetime_sold": 180},
	"staff": {},
	"endless": {"unlocked": false, "wallet": 0, "upgrades": {}, "shift_number": 0, "run_stats": {"shifts": 0, "sold": 0, "bucks": 0, "medals": [0, 0, 0, 0]}, "week_summary": {}},
}

func _save_file() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--save-file="):
			return a.substr(12)
	return "user://upkeep_test/save.json"

func _save_phase() -> int:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--phase="):
			return int(a.substr(8))
	return 1

func _prepare_save_phase() -> void:
	var path := _save_file()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	match _save_phase():
		1:
			for f in [path, path + ".tmp", path + ".bad"]:
				if FileAccess.file_exists(f):
					DirAccess.remove_absolute(f)
		3, 4:
			var data: Dictionary = V3_SAVE.duplicate(true)
			if _save_phase() == 4:
				data["version"] = 4
				data["upkeep"] = {"rating": "five", "cans": [99, -5, "x", 4.6]}
			var f := FileAccess.open(path, FileAccess.WRITE)
			f.store_string(JSON.stringify(data, "\t"))
			f.close()

func _disk() -> Dictionary:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(_save_file()))
	return parsed if parsed is Dictionary else {}

func _run_save() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 20.0)
	await wait(0.5)
	var SG = load("res://SaveGame.gd")
	match _save_phase():
		1:
			check(main.load_status == SG.LOAD_NONE and is_equal_approx(rt().rating, main.RATING_START), "S1: a new shop starts at %.1f stars" % rt().rating)
			rt().set_rating(4.25)
			cl().set_cans([3, 10, 0, 7, 0])
			main.save_progress("upkeep test")
			var d := _disk()
			check(int(d.get("version", 0)) == SG.VERSION and SG.VERSION >= 4, "S1: the save on disk is version %d (current; 4 added the upkeep block)" % int(d.get("version", 0)))
			var up: Dictionary = d.get("upkeep", {})
			check(is_equal_approx(float(up.get("rating", 0)), 4.25) and (up.get("cans", []) as Array).map(func(v): return int(v)) == [3, 10, 0, 7, 0], "S1: with the rating and the cans in it (%s)" % str(up))
		2:
			check(main.load_status == SG.LOAD_OK and is_equal_approx(rt().rating, 4.25), "S2: relaunch: the rating is back (%.2f)" % rt().rating)
			check(cl().cans == [3, 10, 0, 7, 0], "S2: the cans are as full as they were (%s)" % str(cl().cans))
		3:
			check(main.load_status == SG.LOAD_OK and main.money == 640 and main.sections_owned == 2 and main.current_day == 5, "S3: a version-3 (pre-3D) save loads: Day %d, bank %s, %d sections" % [main.current_day, main._format_money(main.money), main.sections_owned])
			check(is_equal_approx(rt().rating, 3.0) and cl().cans == [0, 0, 0, 0, 0], "S3: ...at 3 stars (the old economy exactly) with every can empty (%.1f, %s)" % [rt().rating, str(cl().cans)])
			check(is_equal_approx(rt().crowd_mult(), 1.0) and main.sale_price() == main.PAY_PER_SALE, "S3: 3 stars = crowd x1.00, $%d a sale" % main.sale_price())
		4:
			check(main.load_status == SG.LOAD_OK, "S4: a damaged upkeep block doesn't stop the save loading")
			check(is_equal_approx(rt().rating, 3.0), "S4: a rating that isn't a number -> 3 stars (%.2f)" % rt().rating)
			check(cl().cans == [cl().CAN_CAPACITY, 0, 0, 4, 0], "S4: cans clamped to 0..%d, junk -> 0 (%s)" % [cl().CAN_CAPACITY, str(cl().cans)])
			main.save_progress("upkeep test")
			var up: Dictionary = _disk().get("upkeep", {})
			check(float(up.get("rating", 0)) >= 1.0 and float(up.get("rating", 0)) <= 5.0 and (up.get("cans", []) as Array).size() == 5, "S4: written back out clean (%s)" % str(up))
	finish()

func _shot(name: String) -> void:
	await process_frame
	await process_frame
	await process_frame
	DirAccess.make_dir_recursive_absolute("user://upkeep_shots")
	var path := "user://upkeep_shots/%s.png" % name
	root.get_texture().get_image().save_png(path)
	print("SHOT  " + ProjectSettings.globalize_path(path))

func _run_shots() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 15.0)
	root.size = Vector2i(1280, 720)
	park_world()
	main.open_store(1)
	main.test_hold_customers = true
	main.debug_label.visible = false
	await wait(0.5)
	clear_floor()
	rt().set_rating(4.2)
	# 1: two cans — one normal (4/10), one overflowing — and trash in hand.
	cl().set_cans([cl().CAN_CAPACITY, 4, 0, 4, 0])
	for k in 5:
		cl().drop_litter(Vector2(1180 + k * 26, 700 + (k % 2) * 18))
	await at(Vector2(1180, 700))
	await press_e(0.1)
	await press_e(0.1)
	await at(Vector2(1040, 650), 0.0)
	await wait(1.2)
	await _shot("01_cans_normal_and_full_trash_in_hand")
	# 2: the dumpster, a bag on its way in.
	cl().hands = {}
	await at(cl().BINS[0]["pos"] + Vector2(0, 30))
	await press_e(0.2)
	await at(cl().DUMPSTER_POS + Vector2(-20, -80), PI * 0.5)
	await wait(0.6)
	await _shot("02_dumpster_with_a_bag")
	cl().bags = []
	# 3: a puddle being mopped (mid-shift), the rating falling.
	cl().drop_puddle(Vector2(1500, 760), 20.0)
	for k in 14:
		cl().drop_litter(Vector2(1300 + (k % 7) * 50, 650 + (k / 7) * 160))
	rt().set_rating(3.6)
	cl().tools = cl()._fresh_tools()
	await at(cl().TOOL_SPOTS[2] + Vector2(0, 26))
	await press_e(0.2)
	await at(Vector2(1500 - cl().MOP_HEAD_OFFSET, 760), 0.0)
	press("host_place")
	await wait(0.6)
	await _shot("03_mopping_a_puddle_rating_falling")
	press("host_place", 0.0)
	await wait(0.2)
	cl().tools = cl()._fresh_tools()
	clear_floor()
	# 4: a troublemaker hauled to the front door.
	var red := await pinned_customer("disruptive", Vector2(1440, 800))
	_pin_ai(red)
	await at(Vector2(1440, 764), PI * 0.5)
	await press_e(0.2)
	steer(Vector2.DOWN)
	await wait(0.7)
	steer(Vector2.ZERO)
	await _shot("04_throwing_out_a_troublemaker")
	steer(Vector2.DOWN)
	await wait_until(func(): return main.bounced_today > 0, 5.0)
	steer(Vector2.ZERO)
	await wait(0.15)
	await _shot("05_bounced")
	# 6: a clean store climbing, the counter up.
	cl().set_cans([0, 2, 0, 1, 0])
	rt().set_rating(4.6)
	await at(Vector2(1440, 700))
	await wait(1.0)
	await _shot("06_hud_rating_rising_and_today")
	finish()


## --- CO-OP ------------------------------------------------------------------------
## The host stages each round (props, positions) and writes "go_<round>" with
## a wall-clock moment; each client gets into place, then presses at that
## exact moment — a real race through the real RPCs. Afterwards every peer
## writes what it sees, and the host checks they agree.

func _now_s() -> float:
	return Time.get_unix_time_from_system()

func _client_ids() -> Array:
	var ids: Array = main.players.keys().filter(func(i): return i != 1)
	ids.sort()
	return ids

func _view() -> Dictionary:
	return {"cans": cl().cans.duplicate(), "bags": cl().bags.size(), "bag_n": cl().bags.map(func(b): return int(b["n"])), "rating": snappedf(rt().rating, 0.01), "pay": main._pay_today(), "today": rt().today_text, "hands": cl().hands.keys().map(func(k): return "%d:%d" % [k, cl().hands[k]]), "escorts": get_nodes_in_group("customer").filter(func(c): return c.escorted_by != 0).map(func(c): return int(c.escorted_by)), "bounced": main.bounced_today, "litter": cl().litter.size()}

func _run_net_host() -> void:
	var want := 3
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--players="):
			want = int(a.substr(10))
	await wait_until(func(): return main.shift_active and main.players.size() >= want, 60.0)
	check(main.players.size() >= want, "NET crew connected (%d/%d)" % [main.players.size(), want])
	park_world()
	clear_hub_stock()
	clear_floor()
	cl().set_cans([0, 0, 0, 0, 0])
	main.open_store(1)
	main.test_hold_customers = true
	await wait(1.0)
	var ids := _client_ids()
	var c1: int = ids[0]
	var c2: int = ids[1]
	player().teleport_to(Vector2(480, 270))
	# ROUND 1: both clients take the hub can's bag at the same instant.
	cl().set_can(0, 6)
	await wait(0.3)
	_net_write("go_1", {"t": _now_s() + 2.5})
	await wait(4.5)
	var holders: Array = cl().bags.map(func(b): return int(b["holder"]))
	check(cl().bags.size() == 1 and int(cl().bags[0]["n"]) == 6 and int(cl().cans[0]) == 0 and (holders[0] in [c1, c2] if not holders.is_empty() else false), "NR1 race: two players took the same can's bag at once -> exactly one bag, 6 pieces, held by %s; can empty" % (str(holders)))
	await _compare_views("NR1", ids)
	# The holder sets it down; clean slate.
	cl().bags = []
	await wait(0.3)
	# ROUND 2: both bin 2 pieces into a can with room for 2.
	cl().set_can(0, cl().CAN_CAPACITY - 2)
	var nh := {}
	nh[c1] = 2
	nh[c2] = 2
	cl().hands = nh
	await wait(0.3)
	var binned0: int = cl().trash_binned_today
	_net_write("go_2", {"t": _now_s() + 2.5})
	await wait(4.5)
	var left: int = cl().hand_count(c1) + cl().hand_count(c2)
	check(int(cl().cans[0]) == cl().CAN_CAPACITY and cl().trash_binned_today - binned0 == 2 and left == 2, "NR2 race: two binned 2 each into a can with room for 2 -> can full (%d), 2 paid, 2 still in hands" % cl().cans[0])
	await _compare_views("NR2", ids)
	cl().hands = {}
	cl().set_can(0, 0)
	# ROUND 3: both grab the same troublemaker.
	var red := await pinned_customer("disruptive", Vector2(1440, 760))
	_pin_ai(red)
	_net_write("red", {"name": String(red.name)})
	_net_write("go_3", {"t": _now_s() + 3.0})
	await wait(5.0)
	var haulers := get_nodes_in_group("customer").filter(func(c): return c.escorted_by != 0).map(func(c): return int(c.escorted_by))
	check(haulers.size() == 1 and haulers[0] in [c1, c2], "NR3 race: two players grabbed the same troublemaker -> exactly one hauls them (%s)" % str(haulers))
	await _compare_views("NR3", ids)
	# ROUND 4: the hauler walks them out; everyone sees the bounce and the pay.
	var hauler: int = haulers[0] if not haulers.is_empty() else c1
	var pay0: int = main._pay_today()
	_net_write("go_4", {"hauler": hauler})
	var out := await wait_until(func(): return main.bounced_today >= 1, 30.0)
	check(out and main._pay_today() == pay0 + main.BOUNCE_PAY and cl().stat(hauler, "bounced") == 1, "NR4: a client walked the troublemaker out the door: BOUNCED, +$%d on the crew's pay" % main.BOUNCE_PAY)
	await wait(1.0)
	await _compare_views("NR4", ids)
	# ROUND 5: forged requests from a client — the host says no to each.
	var shopper := await pinned_customer("shopper", Vector2(1300, 760))
	var bait: int = cl().drop_litter(Vector2(1200, 640))
	cl().bags = [{"id": 900, "holder": c1, "pos": Vector2.ZERO, "n": 5, "can": 0}]
	await wait(0.4)
	_net_write("go_5", {"shopper": String(shopper.name)})
	await _net_read("done_5_%d" % c1, 30.0)
	await wait(1.0)
	check(cl().bag_of(c1) >= 0, "NF1: forged 'bag_dump' from across the store: refused (still holding the bag)")
	check(shopper.escorted_by == 0, "NF2: forged grab on a shopper: refused")
	check(cl().litter.any(func(l): return l["id"] == bait) and cl().hand_count(c1) == 0, "NF3: forged 'pick_trash' far from any litter: refused")
	check(cl().trash_binned_today == binned0 + 2, "NF4: forged 'bin_trash' with empty hands: refused (nothing binned)")
	check(int(cl().cans[0]) == 0, "NF5: forged 'bag_take' at an empty can far away: refused")
	shopper.force_leave()
	cl().bags = []
	cl().litter = []
	await wait(0.5)
	# ROUND 6: the rating and the counter — the store gets dirty, every peer
	# sees the same stars and the same TODAY.
	for k in 15:
		cl().drop_litter(Vector2(1000 + k * 40, 700))
	await wait(4.0)
	await _compare_views("NR6", ids)
	_net_write("all_done", {"ok": true})
	await wait(2.0)
	finish()

## Every client writes its view; the host checks each against its own.
var _view_round := 0
func _compare_views(tag: String, ids: Array) -> void:
	_view_round += 1
	await wait(0.6)
	_net_write("view_req_%d" % _view_round, {"tag": tag})
	var mine := _view()
	for id in ids:
		var v := await _net_read("view_%d_%d" % [_view_round, id], 20.0)
		var same: bool = not v.is_empty() and str(v.get("cans")) == str(mine["cans"].map(func(x): return float(x))) and int(v.get("bags", -1)) == mine["bags"] and absf(float(v.get("rating", -1)) - mine["rating"]) < 0.03 and int(v.get("pay", -9999)) == mine["pay"] and String(v.get("today", "")) == mine["today"] and int(v.get("bounced", -1)) == mine["bounced"] and int(v.get("litter", -1)) == mine["litter"]
		check(same, "%s: client %d sees what the host sees (cans %s, bags %d, rating %.2f, %s, litter %d)%s" % [tag, id, str(mine["cans"]), mine["bags"], mine["rating"], mine["today"], mine["litter"], "" if same else "  — client saw %s" % str(v)])

func _run_net_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()) and main.shift_active, 60.0)
	me = main.multiplayer.get_unique_id()
	act = root.get_node("Settings").local_prefix()
	var ids := _client_ids()
	var slot: int = ids.find(me)
	var t0 := Time.get_ticks_msec()
	var round := 1
	var view_round := 1
	while Time.get_ticks_msec() - t0 < 300000:
		if FileAccess.file_exists(NET_DIR + "view_req_%d" % view_round):
			await wait(0.3)
			_net_write("view_%d_%d" % [view_round, me], _view())
			view_round += 1
			continue
		if FileAccess.file_exists(NET_DIR + "all_done"):
			break
		if not FileAccess.file_exists(NET_DIR + "go_%d" % round):
			await wait(0.1)
			continue
		var go := await _net_read("go_%d" % round, 5.0)
		match round:
			1, 2:
				var can: Vector2 = cl().BINS[0]["pos"]
				await at(can + (Vector2(-30, 30) if slot == 0 else Vector2(30, 30)))
				await _press_at(float(go.get("t", 0)))
			3:
				var info := await _net_read("red", 5.0)
				var red: Node2D = main.customers_root.get_node_or_null(NodePath(info.get("name", "")))
				var from := Vector2(1440, 760) + (Vector2(-45, 0) if slot == 0 else Vector2(45, 0))
				await at(from)
				await _press_at(float(go.get("t", 0)))
				print("INFO  client %d pressed E on %s: escorting %s" % [me, info.get("name", "?"), player().escorting()])
			4:
				if int(go.get("hauler", 0)) == me:
					var ok := await walk_to(Vector2(1440, 1060), 14.0, 20.0)
					steer(Vector2.DOWN)
					await wait_until(func(): return not player().escorting(), 8.0)
					steer(Vector2.ZERO)
					print("INFO  client %d hauled them to the door: %s" % [me, ok])
			5:
				if slot == 0:
					# Forgeries, straight at the host's RPCs.
					await at(Vector2(700, 500))
					cl()._request.rpc_id(1, "bag_dump")
					main._request_grab.rpc_id(1, String(go.get("shopper", "")))
					cl()._request.rpc_id(1, "pick_trash")
					cl()._request.rpc_id(1, "bin_trash")
					cl()._request.rpc_id(1, "bag_take")
					await wait(0.5)
					_net_write("done_5_%d" % me, {"ok": true})
		round += 1
	finish()

## Presses E at wall-clock moment `t` (both clients press together).
func _press_at(t: float) -> void:
	while _now_s() < t:
		await process_frame
	await press_e(0.3)

## --- INCOME (crew) -----------------------------------------------------------------
## What the store rating is worth when stocking ISN'T the bottleneck: a perfect
## crew refills every open shelf every 2s from the moment the shift starts
## (spawned straight onto the slots), and the store opens at once — so sales
## are bound by the crowd and the price, the two things the rating moves.
## --clean=instant: an invisible cleaner clears every piece of litter and
## puddle and empties every can every 3s (a store kept spotless, its time cost
## not counted); --clean=none: nobody ever cleans, not even at close.
## Combine with --rating=X --rating-frozen to measure one level. One CREW line
## per shift:
##   godot --headless --path . --script res://tools/upkeep_test.gd -- --server --no-save --day=7 --prep-seconds=1 --test=income-crew --shifts=6 --clean=none [--rating=5 --rating-frozen]
func _run_income_crew() -> void:
	var shifts := 3
	var clean := "none"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shifts="):
			shifts = int(a.substr(9))
		if a.begins_with("--clean="):
			clean = a.substr(8)
	await wait_until(func(): return main.players.has(1), 20.0)
	me = 1
	var pays := []
	for n in shifts:
		await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 60.0)
		player().teleport_to(Vector2(480, 270))
		main.forklift._pause_timer = 0.0
		_stock_all()
		await wait(0.5)
		if not main.store_open:
			main.open_store(1)
		var r0: float = rt().rating
		var sold0: int = main._sold_at_day_start
		var samples := 0
		var crowd := 0
		var next_clean := 0.0
		var t0 := Time.get_ticks_msec()
		while main.shift_active and not main.cleanup_active:
			_stock_all()
			var t := (Time.get_ticks_msec() - t0) / 1000.0
			if clean == "instant" and t >= next_clean:
				next_clean = t + 3.0
				cl().litter = []
				cl().puddles = []
				cl().set_cans([0, 0, 0, 0, 0])
				for sp in main.ambience.spills.duplicate():
					main.ambience.remove_spill(int(sp["id"]))
			await wait(2.0)
			samples += 1
			crowd += get_nodes_in_group("customer").filter(func(c): return not c.is_queued_for_deletion()).size()
		var mess_close: float = rt().mess_points()
		await wait_until(func(): return main.is_day_report_active(), 60.0)
		await wait(0.3)
		var sold: int = main._total_sold() - sold0
		var pay: int = main._pay_today()
		pays.append(pay)
		print("CREW day=%d clean=%s frozen=%d shift=%d | rating %.2f -> %.2f | crowd avg %.1f (cap %d) | sold %d, price-adjust %s, trash %s, bonus %s | mess at close %.0f, cans %s | pay %s" % [main.debug_day, clean, 1 if main.rating_frozen else 0, n + 1, r0, rt().rating, float(crowd) / maxi(1, samples), main.customer_cap(), sold, main._format_money(main.rating_sales_today), main._format_money(cl().litter_pay_today()), main._format_money(cl().clean_bonus_today), mess_close, str(cl().cans), main._format_money(pay)])
		if n < shifts - 1:
			main._on_continue_pressed()
	print("CREW SUMMARY clean=%s frozen=%d: avg pay $%.0f over %d shifts %s" % [clean, 1 if main.rating_frozen else 0, float(pays.reduce(func(a, b): return a + b, 0)) / maxi(1, pays.size()), pays.size(), str(pays)])
	finish()
