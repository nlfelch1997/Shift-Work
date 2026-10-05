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
	main.opening_stock_fraction = 1.0
	if not _mode in ["earnings", "net-upkeep"]:
		main.cleanup_ceiling_override = 0.0
	var client := "--client" in args
	if OS.get_environment("SW_NET_DIR") == "":
		NET_DIR = NET_DIR_DEFAULT
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

const CUSTOMER_CAP_MULT := 1.3 # Customer.SPEED is 90; a frame of jitter on top, never a ride

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
		check(r[0] <= speed * CUSTOMER_CAP_MULT and r[1] <= speed * 1.05, "C%d customer pushing a %s %s: never rides it (peak %.0fpx/s, mean %.0f, walk %.0f; object moved %.0fpx)" % [i, cs[0], cs[1], r[0], r[1], speed, r[2]])
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
	steer(dir * 0.2)
	await physics_frame
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
	print("FAIL  not written yet")
	finish()

func _run_rating() -> void:
	print("FAIL  not written yet")
	finish()

func _run_earnings() -> void:
	print("FAIL  not written yet")
	finish()

func _run_bounce() -> void:
	print("FAIL  not written yet")
	finish()

func _run_save() -> void:
	print("FAIL  not written yet")
	finish()

func _run_shots() -> void:
	print("FAIL  not written yet")
	finish()

func _run_net_client() -> void:
	print("FAIL  not written yet")
	finish()

func _run_net_host() -> void:
	print("FAIL  not written yet")
	finish()

