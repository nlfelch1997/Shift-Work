extends SceneTree
## WEEK 10 test harness — Day 5+, where the forklift (Meat/Deli, Day 3+) and
## the manager (store-wide, Day 4+) run at the same time for the first time,
## plus Dairy/Frozen opening and the Day 5 density/stack tuning. Loads the
## real Main.tscn and drives scripted scenarios through the real game code,
## same shape as tools/manager_test.gd. Not part of the game.
##
## Interaction checks (both hazards at once, Dairy/Frozen, density):
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=5 --shift-seconds=400 --test=interact
## Solo play sim — ONE player, no help, driven through the real keyboard
## actions (Input.action_press on the host_* actions, exactly what WASD/E/C
## produce) by a "competent human" brain: fetches stock, routes cell to cell,
## places with C, steps out of the forklift's way when it's close, and keeps
## moving once the LOOK BUSY banner shows. Plays Days 3, 4, 5, 6 at full
## default shift length and prints a per-day line to compare:
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=3 --test=solo
## Add --careless for a player who never dodges the forklift (worst case).
## Add --shots (and run under xvfb-run, no --headless) to render real frames
## to user://hazard_shots/ whenever the manager and forklift are both on
## screen together.
## WEEK 11 — the Day 5+ stocking grace bonus and the manager's priority stock
## orders (per-item tagging, the 1.5x pay, lapsed orders, the banner vs the
## LOOK BUSY warning, the day rollover):
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=5 --test=orders
## Same, with 2-4 real players over ENet — one host plus N-1 clients, every
## peer driving its own player through its real keyboard actions (host_* on
## the host, client_* on clients), all stocking toward the same orders:
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=5 --players=4 --test=net-orders &
##   (x3) godot --headless --path . --script res://tools/hazards_test.gd -- --client --test=net-orders
## The solo sim (--test=solo) also plays the orders from Day 5 on — the brain
## goes for the called section's stock while an order is open — and reports
## orders filled, bonus pay, and any frame where the order banner and the
## LOOK BUSY warning overlapped on screen.
## WEEK 11 (DAY 6) — flickering lights + floor spills (Ambience.gd):
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=5 --shift-seconds=400 --test=ambience
## and the co-op pass (standing practice for every new hazard from now on):
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=6 --players=3 --test=net-ambience &
##   (x2) godot --headless --path . --script res://tools/hazards_test.gd -- --client --test=net-ambience
## The solo sim steps around spills it can see (--careless walks straight
## through them too) and reports spills, time spent slipping and lights
## events per day.
## WEEK 12 (DAY 7) — the finale: every system escalated, the tighter clock,
## the FINAL SHIFT banner (run under xvfb-run for the banner layout checks):
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=6 --shift-seconds=400 --test=finale
## Co-op on the finale: the net-ambience pass above with --day=7 on the host.
## Solo Day 6 vs Day 7: --test=solo --day=6 --days=6,7
## WEEK 18 — one unpack pad per section. The pad-move before/after (the solo
## brain also runs against the pre-Week-18 one-Storage-pad code, unchanged):
##   godot --headless --fixed-fps 60 --path . --script res://tools/hazards_test.gd -- --server --day=5 --days=5,6,7 --test=solo
##   (--fixed-fps 60 runs it ~4x faster than real time, same game; each per-day
##   line ends with HAUL metrics; --order-blind = the Week 15-17 brain, which
##   never fetches a box for an open order)
##   godot --headless --fixed-fps 60 --path . --script res://tools/hazards_test.gd -- --server --day=7 --test=box-cycle
##   (BC_SECTIONS=Produce,Bakery in the environment limits it to those)
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=7 --test=route-len

var main: Node
var fails := 0
var shots := false
var shot_index := 0
var careless := false

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	shots = "--shots" in args and DisplayServer.get_name() != "headless"
	careless = "--careless" in args
	for a in args:
		if a.begins_with("--days="):
			solo_days.assign(Array(a.substr(7).split(",")).map(func(x): return int(x)))
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	# OCT 2026 PHASE 4: random events (Events.gd) are off here — tools/events_test.gd
	# tests them; --events=on turns them on (the income runs measure both).
	main.events_on = "--events=on" in OS.get_cmdline_user_args()
	# OCT 2026 PHASE 2: these tests were written for the 7-day story — a
	# Day N -> N+1 rollover hands the crew old Day N+1's sections and earnings
	# (Main.gd's test_follow_old_calendar), so each day keeps its old meaning.
	main.test_follow_old_calendar = true
	# OCT 2026 PHASE 3D: these tests were written against the pre-rating
	# economy — 3 stars is exactly it — so the store rating stays put here
	# (a clean test floor would otherwise drift it up and grow the crowd).
	# tools/upkeep_test.gd tests the rating itself.
	main.rating_frozen = true
	var mode := "interact"
	for a in args:
		if a.begins_with("--test="):
			mode = a.substr(7)
	# WEEK 16: the store now opens empty (every unit arrives by truck). The
	# tests written before that are about other systems and were written
	# against a floor that opens stocked — they keep it. The solo sim and the
	# delivery/prep tests play the real thing.
	if not mode in ["solo", "delivery", "net-delivery", "prep", "net-prep", "net-boxsync", "hazard-pause", "net-hazard-pause", "coop-sim", "box-cycle", "route-len"]:
		main.opening_stock_fraction = 1.0
	# WEEK 19: the tests written before the cleanup phase expect the report
	# the moment the clock runs out — clock out at once for them.
	if not mode in ["solo", "coop-sim", "cleanup", "net-cleanup", "polish", "net-polish"]:
		main.cleanup_ceiling_override = 0.0
	# WEEK 17: sweep hook for the priority-order window (solo sim tuning).
	for a in args:
		if a.begins_with("--order-window="):
			main.priority_order_window_override = float(a.substr(15))
	match mode:
		"interact":
			_run_interact.call_deferred()
		"solo":
			_run_solo.call_deferred()
		"orders":
			_run_orders.call_deferred()
		"finale":
			_run_finale.call_deferred()
		"ambience":
			_run_ambience.call_deferred()
		"net-ambience":
			if "--client" in args:
				_run_net_ambience_client.call_deferred()
			else:
				_run_net_ambience_host.call_deferred()
		"delivery":
			_run_delivery.call_deferred()
		"net-delivery":
			if "--client" in args:
				_run_net_delivery_client.call_deferred()
			else:
				_run_net_delivery_host.call_deferred()
		"net-boxsync":
			if "--client" in args:
				_run_boxsync_client.call_deferred()
			else:
				_run_boxsync_host.call_deferred()
		"coop-sim":
			if "--client" in args:
				_run_coop_client.call_deferred()
			else:
				_run_solo.call_deferred()
		"hazard-pause":
			_run_hazard_pause.call_deferred()
		"box-cycle":
			_run_box_cycle.call_deferred()
		"route-len":
			_run_route_len.call_deferred()
		"net-hazard-pause":
			if "--client" in args:
				_run_net_hazard_pause_client.call_deferred()
			else:
				_run_net_hazard_pause_host.call_deferred()
		"prep":
			_run_prep.call_deferred()
		"net-prep":
			if "--client" in args:
				_run_net_prep_client.call_deferred()
			else:
				_run_net_prep_host.call_deferred()
		"cleanup":
			_run_cleanup.call_deferred()
		"net-cleanup":
			if "--client" in args:
				_run_net_cleanup_client.call_deferred()
			else:
				_run_net_cleanup_host.call_deferred()
		"polish":
			_run_polish.call_deferred()
		"net-polish":
			if "--client" in args:
				_run_net_polish_client.call_deferred()
			else:
				_run_net_polish_host.call_deferred()
		"net-orders":
			if "--client" in args:
				_run_net_orders_client.call_deferred()
			else:
				_run_net_orders_host.call_deferred()

func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1

func finish() -> void:
	print("RESULT: %s (%d failure%s)" % ["OK" if fails == 0 else "FAILED", fails, "" if fails == 1 else "s"])
	quit(1 if fails else 0)

func wait(seconds: float) -> void:
	await create_timer(seconds).timeout

func wait_until(cond: Callable, timeout: float) -> bool:
	var t := 0.0
	while t < timeout:
		if cond.call():
			return true
		await physics_frame
		t += 1.0 / 60.0
	return cond.call()

func shot(name: String) -> void:
	if not shots:
		return
	await process_frame
	await process_frame
	DirAccess.make_dir_recursive_absolute("user://hazard_shots")
	var path := "user://hazard_shots/%02d_%s.png" % [shot_index, name]
	shot_index += 1
	root.get_texture().get_image().save_png(path)
	print("SHOT  " + ProjectSettings.globalize_path(path))

func mgr() -> Node2D:
	return main.manager

func fk() -> CharacterBody2D:
	return main.forklift

## The player this process drives: the host's own (peer 1), or — in the
## net-orders client mode — this client's own, through the client_* actions.
var me := 1
var act := "host_"

func player() -> Node2D:
	return main.players[me]

func pin_manager(pos: Vector2, heading: float) -> void:
	var m := mgr()
	m.position = pos
	m.target_position = pos
	m.facing = heading
	m._look_heading = heading
	m._pause_timer = 1000.0
	m._legs.clear()

func release_manager() -> void:
	mgr()._pause_timer = 0.0

func free_product() -> Node2D:
	for obj in get_nodes_in_group("carryable"):
		if obj.get_node("Carryable").carrier_id == 0 and obj.linear_velocity.length() < 5.0 and not _is_placed(obj):
			return obj
	return null

func _is_placed(obj: Node) -> bool:
	# Shelf occupancy (_occupant) is host-only; a client reads the replicated
	# `filled` flags plus where the item is sitting instead.
	if not main.multiplayer.is_server():
		return _is_placed_replicated(obj)
	for s in main.shelves:
		if s.get_node("Shelf").contains(obj):
			return true
	return false

## WEEK 18 (found by the box-cycle benchmark): only a slot something could
## still settle into — an empty one, or the one this item holds. An item
## lying in front of a slot that's already stocked with something else is
## just loose stock (a person picks it up); before, the brain skipped it
## forever.
func _at_a_slot(obj: Node) -> bool:
	for s in main.shelves:
		var shelf: Node = s.get_node("Shelf")
		for i in shelf.slots.size():
			if obj.global_position.distance_to(shelf.slots[i].global_position) <= shelf.CAPTURE_RADIUS and (not shelf._is_filled(i) or _is_placed(obj)):
				return true
	return false

func _is_placed_replicated(obj: Node) -> bool:
	for s in main.shelves:
		var shelf: Node = s.get_node("Shelf")
		for i in shelf.slots.size():
			if shelf._is_filled(i) and obj.global_position.distance_to(shelf.slots[i].global_position) <= shelf.LEAVE_RADIUS:
				return true
	return false

func pickup_near_player() -> Node2D:
	var obj := free_product()
	if obj == null:
		return null
	var pos := player().global_position + Vector2(24, 0)
	PhysicsServer2D.body_set_state(obj.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, Transform2D(0.0, pos))
	PhysicsServer2D.body_set_state(obj.get_rid(), PhysicsServer2D.BODY_STATE_LINEAR_VELOCITY, Vector2.ZERO)
	obj.global_position = pos
	await physics_frame
	await physics_frame
	obj.get_node("Carryable").try_pickup(1, player().global_position)
	await physics_frame
	return obj if obj.get_node("Carryable").carrier_id == 1 else null

func move_body(body: RigidBody2D, pos: Vector2) -> void:
	PhysicsServer2D.body_set_state(body.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, Transform2D(0.0, pos))
	PhysicsServer2D.body_set_state(body.get_rid(), PhysicsServer2D.BODY_STATE_LINEAR_VELOCITY, Vector2.ZERO)
	body.global_position = pos

## True if the manager's body (a ~15px-radius figure) overlaps the
## forklift's collision box (92x44, offset +6 along its heading).
func manager_overlaps_forklift(margin := 15.0) -> bool:
	var local: Vector2 = (mgr().global_position - fk().global_position).rotated(-fk().rotation) - Vector2(6, 0)
	return absf(local.x) < 46.0 + margin and absf(local.y) < 22.0 + margin

## ---------------------------------------------------------------------------

func _run_interact() -> void:
	await wait_until(func(): return main.shift_active, 10.0)
	# WEEK 17: the forklift and manager only run once the store is open.
	main.test_hold_customers = true
	main.open_store(0)
	check(main.current_day == 5, "started on Day 5")
	check(fk().active and fk().visible, "Day 5: forklift active")
	check(mgr().active and mgr().visible, "Day 5: manager active")

	# --- Dairy/Frozen: open, stocked, and on his rounds.
	var names: Array = main._unlocked_sections().map(func(s): return s["name"])
	check("Dairy/Frozen" in names and not ("Bakery" in names), "Day 5 unlocked sections: %s" % str(names))
	var dairy_gate: Node = main.get_node("Gates/GateDairyFrozen/Gate")
	check(dairy_gate.collision.disabled, "Dairy/Frozen gate open (collision off)")
	var dairy_shelves: Array = main.shelves.filter(func(s): return main._grid_cell_of(s.global_position) == Vector2i(0, 1))
	check(dairy_shelves.size() == 5, "Dairy/Frozen has %d shelves (WEEK 16: +1 wall shelf)" % dairy_shelves.size())
	var dairy_slots := 0
	for s in dairy_shelves:
		dairy_slots += s.get_node("Shelf").slot_count()
	var dairy_products := 0
	var blue: Color = main.SECTION_COLORS["Dairy/Frozen"]
	for obj in get_nodes_in_group("carryable"):
		if obj.get_node("Polygon2D").color.is_equal_approx(blue):
			dairy_products += 1
	check(dairy_products > 0, "Dairy/Frozen products spawned: %d (slots: %d)" % [dairy_products, dairy_slots])
	var slots_by_day := {}
	var real_day := _econ_snap()
	for d in [3, 4, 5]:
		_as_day(d)
		var total := 0
		var rows: int = main.STACK_ROWS_BY_TIER[clampi(main._unlocked_sections().size() - 1, 0, 3)]
		for s in main.shelves:
			if main.is_unlocked_at_pos(s.global_position):
				total += 3 * rows
		slots_by_day[d] = [total, main._product_baseline()]
	_econ_restore(real_day)
	print("DENSITY  day -> [reachable slots, product cap]: %s" % str(slots_by_day))
	check(slots_by_day[5][1] / 3.0 > slots_by_day[4][1] / 2.0, "Day 5 spawn density (product cap per open section) is higher than Day 4's: %s" % str(slots_by_day))
	check(slots_by_day[5][0] == 2 * 48, "Day 5 shelves stock two deep: %d reachable slots (48 one-deep: 16 shelves)" % slots_by_day[5][0])
	check(dairy_slots == 30, "Dairy/Frozen shelves two deep: %d slots" % dairy_slots)

	# --- I1: forklift clips a CARRYING player right in front of the manager.
	# Getting hit fumbles the item (Player.forklift_hit -> try_throw). That's
	# the forklift's fault, not a throw — it must not read as chaos.
	var st: Dictionary = mgr()._player_state(1)
	var chaos_before: float = st["last_chaos"]
	fk().reset_for_new_day()
	fk()._pause_timer = 0.5
	player().teleport_to(Vector2(2690, 810)) # in the lane, right in front of the parked forklift's forks
	await physics_frame
	var carried: Node2D = await pickup_near_player()
	check(carried != null, "I1: player carrying %s in the forklift's lane" % (carried.name if carried else "nothing"))
	pin_manager(Vector2(2560, 700), (Vector2(2690, 810) - Vector2(2560, 700)).angle())
	var got_hit := await wait_until(func(): return player()._stun_timer > 0.0, 8.0)
	check(got_hit, "I1: forklift hit the player")
	await shot("i1_forklift_hits_carrying_player")
	var peak := 0.0
	var base: Vector2 = player().position
	for i in 150: # keep moving afterward so only chaos (not idling) could raise the meter
		if player()._stun_timer <= 0.0:
			player().position = base + Vector2(0, sin(i / 10.0) * 40.0)
		peak = maxf(peak, st["meter"])
		await physics_frame
	check(st["last_chaos"] == chaos_before, "I1: fumble from a forklift hit NOT counted as chaos (recorded: '%s')" % st.get("chaos_what", ""))
	check(peak < mgr().WARN_LEVEL, "I1: manager meter stayed under the '!' warning after the forklift hit (peak %.0f%%)" % (peak * 100.0))
	check(main.writeups_today == 0, "I1: no write-up")

	# --- I2: forklift knocks a (non-carrying) player INTO a floor display.
	# The knockback slide pushes the display — the forklift's doing, not
	# the player's.
	st["last_chaos"] = -INF
	st["chaos_what"] = ""
	st["meter"] = 0.0
	st["cooldown"] = 1000.0 # this scenario only checks chaos attribution; don't let the setup's standing still land an idle write-up
	for obj in get_nodes_in_group("carryable"):
		if obj.get_node("Carryable").carrier_id == 1:
			obj.get_node("Carryable").try_drop(1)
	await wait(0.5)
	var display: RigidBody2D = main.displays[0]
	# Where the knockback sends the player depends on exactly where the forks
	# connect, so retry until the slide actually shoves the display.
	var shoved := false
	for attempt in 4:
		fk().reset_for_new_day()
		fk()._pause_timer = 0.3
		player().teleport_to(Vector2(2690, 810))
		await physics_frame
		move_body(display, Vector2(2632, 810))
		await wait(0.2)
		var d_before: Vector2 = display.global_position
		chaos_before = st["last_chaos"]
		got_hit = await wait_until(func(): return player()._stun_timer > 0.0, 8.0)
		await wait(0.8)
		shoved = got_hit and display.global_position.distance_to(d_before) > 15.0
		if shoved:
			break
	check(shoved, "I2: forklift knocked the player into the display (display moved)")
	check(st["last_chaos"] == chaos_before, "I2: being knocked INTO a display by the forklift NOT counted as chaos (recorded: '%s')" % st.get("chaos_what", ""))
	# Sanity: the exemption is narrow — the same player deliberately walking
	# into a display a few seconds later still counts. Park the forklift
	# first — a second hit would (correctly) open a fresh excuse window.
	fk()._pause_timer = 1000.0
	await wait(mgr().FORKLIFT_EXCUSE + 0.5)
	var d_pos: Vector2 = display.global_position
	player().teleport_to(d_pos + Vector2(-40, 0))
	await physics_frame
	for i in 20:
		player().velocity = Vector2(220, 0)
		player().move_and_slide()
		player()._push_rigid_bodies(1.0 / 60.0)
		await physics_frame
	check(st.get("chaos_what", "") == "knocking over a display", "I2: deliberately shoving a display afterward still counts ('%s')" % st.get("chaos_what", ""))
	release_manager()
	fk()._pause_timer = 0.0
	for d in main.displays:
		d.get_node("Display").reset_to_home()

	# --- I3: free patrol, both hazards live. Does the manager ever end up
	# inside the forklift (the forklift has no idea he's there — he has no
	# collision)? Player parked out of everyone's way in the break room.
	player().teleport_to(Vector2(480, 270))
	st["meter"] = 0.0
	st["cooldown"] = 0.0
	var writeups_before: int = main.writeups_today
	fk().reset_for_new_day()
	fk()._pause_timer = 0.0
	mgr()._legs.clear()
	mgr()._pause_timer = 0.0
	var frames := 0
	var overlap_frames := 0
	var lane_frames := 0
	var meat_frames := 0
	var min_dist := INF
	var meat_visits := 0
	var was_in_meat := false
	var t_start := Time.get_ticks_msec()
	var shot_taken := false
	while (Time.get_ticks_msec() - t_start) < 150000 and meat_visits < 3:
		await physics_frame
		frames += 1
		var in_meat: bool = main._grid_cell_of(mgr().global_position) == Vector2i(2, 1)
		if in_meat and not was_in_meat:
			meat_visits += 1
		was_in_meat = in_meat
		if not in_meat:
			continue
		meat_frames += 1
		var d: float = mgr().global_position.distance_to(fk().global_position)
		min_dist = minf(min_dist, d)
		if manager_overlaps_forklift():
			overlap_frames += 1
			if not shot_taken:
				shot_taken = true
				player().teleport_to(Vector2(2400, 810))
				await shot("i3_manager_inside_forklift")
				player().teleport_to(Vector2(480, 270))
		if absf(mgr().global_position.y - fk().home_position.y) < 40.0:
			lane_frames += 1
	print("PATROL  %d Produce (forklift section) visits, %d frames there, min manager-forklift distance %.0fpx, %d frames overlapping the forklift, %d frames standing in its lane" % [meat_visits, meat_frames, min_dist, overlap_frames, lane_frames])
	check(meat_visits >= 2, "I3: manager visited Produce (the forklift section) %d times while the forklift ran" % meat_visits)
	check(overlap_frames == 0, "I3: manager never inside the forklift's footprint (%d overlapping frames, min distance %.0fpx)" % [overlap_frames, min_dist])
	check(lane_frames < 30, "I3: manager doesn't loiter in the forklift's lane (%d frames within 40px of its center line)" % lane_frames)
	check(main.writeups_today == writeups_before, "I3: nobody written up during the patrol run")

	# --- I3b: force the worst cases the patrol run may not roll: him STANDING
	# in the lane as the forklift drives down it, then pacing back and forth
	# ACROSS the lane while it runs its laps. He should step aside / wait,
	# never end up inside it.
	fk().reset_for_new_day()
	fk()._pause_timer = 0.0
	player().teleport_to(Vector2(480, 270))
	mgr().position = Vector2(2330, 810)
	mgr().target_position = mgr().position
	mgr()._legs.clear()
	mgr()._pause_timer = 20.0
	var forced_overlap := 0
	var dodged := false
	var start_pos: Vector2 = mgr().position
	var tb := Time.get_ticks_msec()
	while Time.get_ticks_msec() - tb < 20000:
		await physics_frame
		if manager_overlaps_forklift():
			forced_overlap += 1
		if mgr().position.distance_to(start_pos) > 30.0:
			dodged = true
		if dodged and not shot_taken and mgr().global_position.distance_to(fk().global_position) < 140.0:
			shot_taken = true
			player().teleport_to(Vector2(2400, 810))
			await shot("i3b_manager_steps_aside")
			player().teleport_to(Vector2(480, 270))
	check(dodged, "I3b: standing in the lane, he stepped out of the forklift's way")
	check(forced_overlap == 0, "I3b: ...without it ever driving through him (%d overlapping frames)" % forced_overlap)
	forced_overlap = 0
	var crossings := 0
	var tc := Time.get_ticks_msec()
	mgr()._pause_timer = 0.0
	while Time.get_ticks_msec() - tc < 40000:
		if mgr()._legs.is_empty():
			var top := mgr().position.y < 810.0
			mgr()._legs = [{"pos": Vector2(2330 + randf_range(-120, 120), 905.0 if top else 715.0)}]
			crossings += 1
		await physics_frame
		mgr()._pause_timer = 0.0
		if manager_overlaps_forklift():
			forced_overlap += 1
	check(forced_overlap == 0, "I3b: pacing across the lane %d times with the forklift running: never inside it (%d overlapping frames)" % [crossings, forced_overlap])
	check(crossings >= 6, "I3b: he still got across (%d crossings in 40s — yielding never pins him)" % crossings)
	mgr()._legs.clear()

	# --- I4: Meat/Deli with both on screen — the render check. Park the
	# player where the camera frames all of Meat/Deli and grab a frame when
	# both are close.
	if shots:
		player().teleport_to(Vector2(2400, 810))
		var got_close := await wait_until(func(): return main._grid_cell_of(mgr().global_position) == Vector2i(2, 1) and mgr().global_position.distance_to(fk().global_position) < 220.0, 120.0)
		if got_close:
			await shot("i4_both_hazards_meat_deli")
			await wait(1.5)
			await shot("i4_both_hazards_meat_deli_b")
	finish()

## ---------------------------------------------------------------------------
## SOLO SIM

## Override with --days=5 (together with --day=5) to repeat one day in
## fresh processes — single runs vary by several sales.
var solo_days: Array = [3, 4, 5, 6]
var _held := {}

func press(action: String, strength := 1.0) -> void:
	if strength <= 0.0:
		if _held.has(action):
			Input.action_release(action)
			_held.erase(action)
		return
	Input.action_press(action, strength)
	_held[action] = true

func tap(action: String) -> void:
	Input.action_press(action)
	await physics_frame
	Input.action_release(action)

func steer(dir: Vector2) -> void:
	press(act + "move_right", maxf(dir.x, 0.0))
	press(act + "move_left", maxf(-dir.x, 0.0))
	press(act + "move_down", maxf(dir.y, 0.0))
	press(act + "move_up", maxf(-dir.y, 0.0))

## Cell-to-cell route (every connection the map actually has open): through
## the hub, with Bakery and the break room hanging off Dry Goods.
func route_next(from_cell: Vector2i, to_cell: Vector2i) -> Vector2i:
	if from_cell == to_cell:
		return to_cell
	var hub := Vector2i(1, 1)
	# WEEK 15: Storage (2,2) hangs off the Sidewalk cell (1,2), which opens
	# onto the hub.
	var storage := Vector2i(2, 2)
	var south := Vector2i(1, 2)
	if from_cell == storage:
		return south
	if from_cell == south:
		return storage if to_cell == storage else hub
	if to_cell == storage and from_cell == hub:
		return south
	var dry := Vector2i(1, 0)
	var off_dry := [Vector2i(0, 0), Vector2i(2, 0)]
	if from_cell in off_dry:
		return dry if to_cell != dry else dry
	if from_cell == dry:
		return to_cell if to_cell in off_dry else hub
	if from_cell == hub:
		return dry if to_cell in off_dry else to_cell
	return hub # any spoke back to the hub first

func cell_center(c: Vector2i) -> Vector2:
	return Vector2((c.x + 0.5) * main.ROOM_WIDTH, (c.y + 0.5) * main.ROOM_HEIGHT)

## Where to walk to reach `goal`: straight there inside the same cell,
## otherwise toward the next cell's center.
func waypoint(pos: Vector2, goal: Vector2) -> Vector2:
	var a: Vector2i = main._grid_cell_of(pos)
	var b: Vector2i = main._grid_cell_of(goal)
	if a == b:
		return goal
	var nxt := route_next(a, b)
	if nxt == b:
		# Crossing straight into the goal cell: aim at the goal once close to
		# the shared edge, otherwise at the next cell's center line.
		return goal if pos.distance_to(goal) < 500.0 and nxt != Vector2i(1, 0) else cell_center(nxt)
	return cell_center(nxt)

func slot_color_ok(shelf_body: Node, obj: Node) -> bool:
	return shelf_body.get_node("Shelf")._color_matches(obj)

## Best (product, slot) job for a stocker: nearest free product that has an
## open, matching, reachable slot.
## WEEK 11: while a priority order is open, a human goes for the called
## section's stock first (falls back to anything if none is reachable).
## OCT 2026 PHASE 4: an event-aware brain (--event-brain on the sims) goes
## for what a running random event asks for first — the Lunch Rush section's
## stock, the Catering Order's sections, the Surprise Delivery's boxes — the
## way it already goes for an open priority order. Off by default: the old
## sims play exactly as they did.
var event_aware := "--event-brain" in OS.get_cmdline_user_args()

## The sections an active event wants stocked/unpacked right now.
func _event_focus() -> Array:
	if not event_aware or not main.events.active():
		return []
	var d: Dictionary = main.events.data
	match main.events.key:
		"rush":
			return [d.get("section", "")]
		"catering", "delivery":
			var out := []
			for sec in d.get("needs", {}):
				if int(d["have"].get(sec, 0)) < int(d["needs"][sec]):
					out.append(sec)
			return out
	return []

## A box the active event wants carried (a Surprise Delivery's, or — Rush/
## Catering — its section's when none of its stock is loose).
func _event_box(p: Node2D) -> Node2D:
	for sec in _event_focus():
		if main.events.key != "delivery" and _pick_product(p, main.SECTION_COLORS[sec]) != null:
			continue
		var b := _pick_box(p, sec)
		if b != null:
			return b
	return null

func pick_product(p: Node2D) -> Node2D:
	for sec in _event_focus():
		if main.events.key == "delivery":
			break
		var for_event := _pick_product(p, main.SECTION_COLORS[sec])
		if for_event != null:
			return for_event
	if main.order_section != "":
		var for_order := _pick_product(p, main.SECTION_COLORS[main.order_section])
		if for_order != null:
			return for_order
	if order_only:
		return null
	return _pick_product(p, Color(0, 0, 0, 0))

func _pick_product(p: Node2D, only_color: Color) -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for obj in get_nodes_in_group("carryable"):
		if only_color.a > 0.0 and not obj.get_node("Polygon2D").color.is_equal_approx(only_color):
			continue
		# Leave stock that's sitting at a shelf slot alone — including the
		# 0.35s before the shelf counts it (SETTLE_TIME), when it still looks
		# loose. Without this a bot would snatch what a teammate just set down.
		if _at_a_slot(obj):
			continue
		if obj.get_node("Carryable").carrier_id != 0 or _is_placed(obj) or recent_drops.has(obj):
			continue
		# (Storage too: stock knocked back there. WEEK 18: the pads are in the
		# sections now.)
		if not main.is_unlocked_at_pos(obj.global_position) and not main._grid_cell_of(obj.global_position) in [Vector2i(1, 1), main.STORAGE_GRID_POS]:
			continue
		if pick_slot(obj.global_position, obj).is_empty():
			continue
		if _teammate_closer(p, obj):
			continue
		var d := p.global_position.distance_to(obj.global_position)
		if d < best_d:
			best_d = d
			best = obj
	return best

func pick_slot(from: Vector2, obj: Node) -> Dictionary:
	var best := {}
	var best_d := INF
	for s in main.shelves:
		if not main.is_unlocked_at_pos(s.global_position):
			continue
		if my_shelf != null and s != my_shelf and slot_color_ok(my_shelf, obj):
			continue
		var shelf: Node = s.get_node("Shelf")
		if shelf.wrecked or not slot_color_ok(s, obj):
			continue
		for i in shelf.slots.size():
			if shelf.filled[i]:
				continue
			var sp: Vector2 = shelf.slots[i].global_position
			var d := from.distance_to(sp)
			if d < best_d:
				best_d = d
				var outward: Vector2 = (sp - s.global_position).normalized()
				# The slot's outward direction is perpendicular to the shelf's
				# long axis; project so it's exactly that.
				var axis: Vector2 = s.global_transform.y.normalized()
				outward = axis * signf(outward.dot(axis))
				best = {"slot": shelf.slots[i], "pos": sp, "out": outward}
	return best

var stats := {"placed": 0, "hits": 0, "watched_s": 0.0, "idle_s": 0.0, "reasons": {}, "wrecks": 0, "overlap": 0, "banner_and_busy_s": 0.0, "banner_clash": 0, "first_customer_s": -1.0, "shift_len": 0.0, "grace": 0.0, "slip_s": 0.0}
var recent_drops := {} # product -> seconds left before the brain may target it again
## net-orders: stock ONLY for the open order (idle otherwise), and a hook
## called with (item, slot) on every place press.
var order_only := false
var on_place := Callable()
## net-orders: each peer works its own shelf of the ordered section, the way
## a real crew spreads out (identical bots all aiming at the one nearest
## empty slot just knock each other's stock back out).
var my_shelf: Node = null

func _run_solo() -> void:
	var day_stats := []
	for day in solo_days:
		await wait_until(func(): return main.shift_active and main.current_day == day, 20.0)
		stats = {"placed": 0, "hits": 0, "watched_s": 0.0, "idle_s": 0.0, "reasons": {}, "wrecks": 0, "overlap": 0, "banner_and_busy_s": 0.0, "banner_clash": 0, "first_customer_s": -1.0, "shift_len": main.shift_time_left, "grace": main.prep_time_left, "slip_s": 0.0}
		var start_sold: int = main._sold_at_day_start
		_haul = {"walk_px": 0.0, "last_pos": null, "box_t": {}, "carry_s": [], "item_born": {}, "item_s": [], "box_items": {}, "box_cycle_s": [], "seen": {}, "last_event": dl().unpack_event_id, "last_carry": null, "open_placed": 0, "open_called": 0, "item_carry": null, "last_pos_c": null, "carry_item_s": [], "carry_item_px": []}
		print("SOLO  Day %d start — %.0fs shift, sections %s, product cap %d" % [day, main.shift_time_left, str(main._unlocked_sections().map(func(s): return s["name"])), main._product_baseline()])
		await _play_shift()
		# WEEK 19: then the cleanup phase, the same competent player.
		var mess := {"m": cl().mop_total, "l": cl().litter_total, "ceiling": main.cleanup_time_left, "dropped": cl().litter_dropped_today}
		var t_clean := _wall()
		for o in get_nodes_in_group("carryable"):
			if o.get_node("Carryable").carrier_id == me:
				await tap(act + "interact") # set down whatever was in hand at close
		var cst := await _play_cleanup(false, not "--no-clockout" in OS.get_cmdline_user_args())
		await wait_until(func(): return main.is_day_report_active(), 5.0)
		await wait(0.3)
		check(main.is_day_report_active(), "Day %d: the report came up after cleanup" % day)
		var sold: int = main._total_sold() - main._sold_at_day_start
		var line := "SOLO  Day %d: sold %d, place-presses %d, write-ups %d %s, forklift hits %d, rams %d, watched %.0fs, idle %.0fs, manager-inside-forklift frames %d | shift %.0fs, grace %.0fs, first customer at %.0fs | orders %d/%d filled, %d bonus sales | order banner + LOOK BUSY together %.1fs, overlapping frames %d | spills %d, slipping %.1fs, lights events %d | trucks %d, boxes unpacked %d | clock %.0fs = prep %.0fs (opened by %s, ceiling %.0fs) + selling %.0fs, lights events while open %d | %s" % [day, sold, stats["placed"], main.writeups_today, str(stats["reasons"]), stats["hits"], fk().rams_today, stats["watched_s"], stats["idle_s"], stats["overlap"], stats["shift_len"], stats["grace"], stats["first_customer_s"], main.orders_filled_today, main.orders_called_today, main.priority_sales_today, stats["banner_and_busy_s"], stats["banner_clash"], main.ambience.spills_today, stats["slip_s"], main.ambience.lights_events_today, dl().deliveries_today, dl().boxes_unpacked_today, stats["shift_len"], stats.get("opened_at", -1.0), stats.get("opened_by", "?"), stats["grace"], stats["shift_len"] - stats.get("opened_at", 0.0), main.ambience.lights_events_today - stats.get("lights_at_open", 0), main.report_pay_label.text]
		line += " | " + _haul_line()
		line += " | CLEANUP mess %d mop + %d litter (%d dropped), ceiling %.0fs, took %.0fs, %s; mopped %d, swept %d, pans %d -> %d%% / %d%%, bonus %s" % [mess["m"], mess["l"], mess["dropped"], mess["ceiling"], _wall() - t_clean, "clocked out by the player" if cst["clocked"] else "ceiling clocked out", cst["mopped"], cst["swept"], cst["dumps"], roundi(cl().mop_fraction() * 100), roundi(cl().litter_fraction() * 100), main._format_money(cl().clean_bonus_today)]
		print(line)
		day_stats.append(line)
		check(stats["banner_clash"] == 0, "Day %d: order banner never overlapped the LOOK BUSY warning / toast (%d frames)" % [day, stats["banner_clash"]])
		# OCT 2026 PHASE 2: by complication stage (orders 3, lights+spills 4).
		var orders_on: bool = main.complication_stage >= main.STAGE_ORDERS
		check(not orders_on or main.orders_called_today > 0, "Day %d: priority orders called: %d" % [day, main.orders_called_today])
		check(orders_on or main.orders_called_today == 0, "Day %d: no priority orders before stage %d" % [day, main.STAGE_ORDERS])
		var env_day: bool = main.complication_stage >= main.STAGE_ENVIRONMENT
		check(env_day == (main.ambience.spills_today > 0 and main.ambience.lights_events_today > 0), "Day %d: spills %d, lights events %d (%s)" % [day, main.ambience.spills_today, main.ambience.lights_events_today, "stage 4+: both happen" if env_day else "none before stage 4"])
		if day != solo_days[-1]:
			main._on_continue_pressed()
	print("SOLO SUMMARY%s" % (" (careless: never dodges the forklift)" if careless else ""))
	for l in day_stats:
		print(l)
	finish()

## stop: when to hand control back (default: the shift ends).
var upkeep_hook := Callable()

func _play_shift(stop: Callable = func(): return not main.shift_active or main.cleanup_active) -> void:
	var p := player()
	var obj: Node2D = null
	var job := {}
	var stuck_t := 0.0
	var last_pos := p.global_position
	var jiggle_t := 0.0
	var jiggle_dir := Vector2.ZERO
	var prev_stun := false
	var prev_writeups: int = main.writeups_today
	var dt := 1.0 / 60.0
	var shot_cool := 0.0
	var approach_phase := 0
	while not stop.call():
		await physics_frame
		# WEEK 16: note when the store opened (by the sign or the ceiling).
		if main.store_open and not stats.has("opened_at"):
			stats["opened_at"] = stats["shift_len"] - main.shift_time_left
			stats["opened_by"] = "ceiling" if main.store_opened_by == 0 else main.player_display_name(main.store_opened_by)
			stats["lights_at_open"] = main.ambience.lights_events_today
		# WEEK 16: prep. A person opens the store once the shelves are mostly
		# full, or once there's been nothing to do for a while with at least
		# half of them stocked. --never-open leaves it to the ceiling.
		# PHASE 5 — --open-rule=typical: the crew the open-early hint is
		# written for: it opens once the open shelves are as full as the hint
		# asks (Pacing.OPEN_EARLY_HINT_FILL), or once half the prep ceiling has
		# gone by, whichever comes first — a measurement assumption, not a
		# claim about real players (the host decides; one flip for the crew).
		if open_rule == "typical" and not main.store_open and main.shift_active and main.multiplayer.is_server():
			var ceiling: float = main._prep_ceiling()
			if main.open_shelf_fill() >= load("res://Pacing.gd").OPEN_EARLY_HINT_FILL or ceiling - main.prep_time_left >= 0.5 * ceiling:
				main.open_store(me)
		if not main.store_open and not never_open and open_rule == "" and main.shift_active:
			var busy := false
			for o in get_nodes_in_group("carryable"):
				if o.get_node("Carryable").carrier_id == me:
					busy = true
			if obj == null and not busy:
				_prep_idle_t += 1.0 / 60.0
			else:
				_prep_idle_t = 0.0
			var fill := _fill_ratio()
			if not busy and (fill >= OPEN_WHEN_FILLED or (fill >= 0.5 and _prep_idle_t > OPEN_WHEN_IDLE)):
				await _go_flip_sign()
				_prep_idle_t = 0.0
				continue
		for k in recent_drops.keys():
			recent_drops[k] -= dt
			if recent_drops[k] <= 0.0 or not is_instance_valid(k):
				recent_drops.erase(k)
		var pos := p.global_position
		var my_carry: Node2D = null
		for o in get_nodes_in_group("carryable"):
			if o.get_node("Carryable").carrier_id == me:
				my_carry = o
		_track_haul(p, my_carry)
		# OCT 2026 PHASE 3D: a bot that keeps the store clean (staff_test.gd's
		# income --upkeep) breaks off between jobs to do it.
		if upkeep_hook.is_valid() and my_carry == null and main.store_open and await upkeep_hook.call():
			obj = null
			job = {}
			continue
		# bookkeeping
		var stunned: bool = p._stun_timer > 0.0
		if stunned and not prev_stun:
			stats["hits"] += 1
		prev_stun = stunned
		if main.writeups_today > prev_writeups and main.multiplayer.is_server():
			var why: String = mgr()._state[1]["reason"]
			stats["reasons"][why] = stats["reasons"].get(why, 0) + 1
			prev_writeups = main.writeups_today
		var watched: bool = mgr().active and mgr().watch_peer == me and mgr().watch_level > 0.0
		if watched:
			stats["watched_s"] += dt
		if fk().active and mgr().active and manager_overlaps_forklift():
			stats["overlap"] += 1
		# (Yesterday's customers are freed at shift start but linger in the
		# group until the frame ends — only count live ones.)
		if stats["first_customer_s"] < 0.0 and get_nodes_in_group("customer").any(func(c): return not c.is_queued_for_deletion()):
			stats["first_customer_s"] = stats["shift_len"] - main.shift_time_left
		# WEEK 11: the order banner and the LOOK BUSY warning on screen at once.
		if main._order_label.visible and main._watch_label.visible:
			stats["banner_and_busy_s"] += dt
			if rects_overlap(main._order_label, main._watch_label) or (main._toast_label.visible and rects_overlap(main._order_label, main._toast_label)):
				stats["banner_clash"] += 1
			if shots and not stats.has("banner_shot"):
				stats["banner_shot"] = true
				await shot("solo_day%d_order_banner_and_look_busy" % main.current_day)
		shot_cool -= dt
		if shots and shot_cool <= 0.0 and fk().active and mgr().active and main._grid_cell_of(pos) == Vector2i(2, 1) and main._grid_cell_of(mgr().global_position) == Vector2i(2, 1):
			shot_cool = 12.0
			await shot("solo_day%d_both_hazards" % main.current_day)

		var dir := Vector2.ZERO
		var goal := pos # where the brain is headed this frame (spill avoidance)
		_trace_t -= dt
		if trace and _trace_t <= 0.0:
			_trace_t = 1.0
			print("TRACE t=%.0f pos=%s carry=%s obj=%s phase=%d loose=%d boxes=%d open=%s floor=%d" % [stats["shift_len"] - main.shift_time_left, str(pos.round()), my_carry.name if my_carry else "-", obj.name if obj and is_instance_valid(obj) else "-", box_phase, _loose_stockable(), boxes().size(), str(main.store_open), floor_total()])
		if my_carry and my_carry.is_in_group("delivery_box"):
			# WEEK 15: carrying a box -> onto the pad, set it down with E.
			# WEEK 18: its own section's pad, from the aisle side (south —
			# every pad has open floor below it), facing up.
			var stand_at: Vector2 = _brain_pad_stand(my_carry)
			if pos.distance_to(stand_at) > 6.0:
				goal = waypoint(pos, stand_at)
				dir = (goal - pos).normalized() * (0.5 if pos.distance_to(stand_at) < 30.0 else 1.0)
			else:
				steer(Vector2.UP if _per_section_pads() else Vector2.LEFT)
				await physics_frame
				await physics_frame
				steer(Vector2.ZERO)
				await wait(0.15)
				await tap(act + "interact")
				var set_down := my_carry
				await wait_until(func(): return not is_instance_valid(set_down) or set_down.get_node("Carryable").carrier_id != me, 0.6)
				stats["boxes"] = stats.get("boxes", 0) + 1
				box_phase = 0
		elif my_carry:
			if job.is_empty() or job["slot"].get_parent().get_node("Shelf").filled[job["slot"].get_parent().get_node("Shelf").slots.find(job["slot"])] or job["slot"].get_parent().get_node("Shelf").wrecked:
				job = pick_slot(pos, my_carry)
				approach_phase = 0
			if job.is_empty():
				dir = Vector2.ZERO # nowhere to put it: hold it (carrying is busy)
			else:
				var pre: Vector2 = job["pos"] + job["out"] * 80.0
				var stand: Vector2 = job["pos"] + job["out"] * 29.0
				if approach_phase == 0:
					var wp := waypoint(pos, pre)
					if pos.distance_to(pre) < 12.0:
						approach_phase = 1
					dir = (wp - pos).normalized()
					goal = wp
				else:
					if pos.distance_to(stand) > 3.0:
						dir = (stand - pos).normalized()
					if p._place_target_slot != null:
						# A client stops for a beat before C, like a person does:
						# the host drops the item from ITS copy of this player,
						# which trails a moving client (see Carryable.gd's
						# _validate_drop()) — press while walking and it lands
						# short of the slot the prompt showed.
						if not main.multiplayer.is_server():
							steer(Vector2.ZERO)
							await wait(0.2)
						await tap(act + "place")
						# On a client the drop is a round trip to the host; don't
						# press again (or re-plan) until it has landed.
						var dropped := my_carry
						await wait_until(func(): return not is_instance_valid(dropped) or dropped.get_node("Carryable").carrier_id != me, 0.6)
						recent_drops[my_carry] = 2.5 # let it settle — don't grab it straight back
						stats["placed"] += 1
						if on_place.is_valid():
							on_place.call(my_carry, job["slot"])
						job = {}
						approach_phase = 0
					elif pos.distance_to(stand) <= 3.0:
						approach_phase = 0 # re-approach
		else:
			job = {}
			if obj == null or not is_instance_valid(obj) or obj.get_node("Carryable").carrier_id != 0 or _is_placed(obj) or (obj.is_in_group("delivery_box") and _on_own_pad(obj)):
				obj = pick_product(p)
				box_phase = 0
				# WEEK 15: little loose stock left to shelve and a box waiting
				# in Storage -> go unpack it.
				if (obj == null or _loose_stockable() < BOX_RUN_BELOW) and not order_only:
					var bx := _pick_box(p)
					if bx != null:
						obj = bx
				# WEEK 18: an order's open and none of its section's stock is
				# loose -> a human goes and gets that section's box.
				# --order-blind keeps the Week 15-17 brain (boxes only by the
				# BOX_RUN_BELOW rule, nearest first).
				if order_box_aware and main.order_section != "" and (obj == null or not obj.get_node("Polygon2D").color.is_equal_approx(main.SECTION_COLORS[main.order_section])):
					var ob := _pick_box(p, main.order_section)
					if ob != null:
						obj = ob
				# PHASE 4: the same for what a running event asks for.
				if event_aware and not _event_focus().is_empty():
					var focus_colors: Array = _event_focus().map(func(sec): return main.SECTION_COLORS[sec])
					if obj == null or main.events.key == "delivery" or not focus_colors.any(func(c): return obj.get_node("Polygon2D").color.is_equal_approx(c)):
						var eb := _event_box(p)
						if eb != null:
							obj = eb
			if obj != null and obj.is_in_group("delivery_box"):
				# Come at it from the north and stop short (walking into it shoves it).
				var pre: Vector2 = obj.global_position + Vector2(0, -110)
				var at: Vector2 = obj.global_position + Vector2(0, -50)
				if box_phase == 0 and pos.distance_to(pre) < 14.0:
					box_phase = 1
				var tgt := pre if box_phase == 0 else at
				if box_phase == 1 and pos.distance_to(at) < 5.0:
					steer(Vector2.ZERO)
					await tap(act + "interact")
					var grabbed_box := obj
					await wait_until(func(): return not is_instance_valid(grabbed_box) or grabbed_box.get_node("Carryable").carrier_id != 0, 0.6)
					obj = null
					box_phase = 0
				else:
					goal = waypoint(pos, tgt)
					dir = (goal - pos).normalized() * (0.5 if box_phase == 1 else 1.0)
			elif obj != null:
				var target: Vector2 = obj.global_position
				if pos.distance_to(target) < 40.0:
					await tap(act + "interact")
					# Same on pickup: a second E before the host's answer arrives
					# would drop what was just picked up.
					var grabbed := obj
					await wait_until(func(): return not is_instance_valid(grabbed) or grabbed.get_node("Carryable").carrier_id != 0, 0.6)
					obj = null
				else:
					goal = waypoint(pos, target)
					dir = (goal - pos).normalized()
		# WEEK 11: a human steps around a spill they can see coming (forming
		# ones too — the WET FLOOR sign is up), unless what they're after is
		# in it. --careless walks straight through.
		if not careless and dir != Vector2.ZERO:
			dir = _avoid_spills(pos, dir, goal)
		if p.is_slipping():
			stats["slip_s"] += dt
		# Human awareness of the forklift: if it's close and I'm in front of
		# it, sidestep out of its path (unless simulating a careless player).
		for f in [fk(), dfk()]:
			if careless or not f.active or not f.visible:
				continue
			var rel: Vector2 = pos - f.global_position
			var heading := Vector2.RIGHT.rotated(f.rotation)
			if f.reversing:
				heading = -heading
			var ahead := rel.dot(heading)
			var side := rel.dot(heading.orthogonal())
			if rel.length() < 150.0 and ahead > -20.0 and absf(side) < 60.0 and f.velocity.length() > 1.0:
				dir = (heading.orthogonal() * (1.0 if side >= 0.0 else -1.0) + dir * 0.3).normalized()
		# Idle with the banner up: a human keeps moving.
		if dir == Vector2.ZERO and watched:
			if jiggle_t <= 0.0:
				jiggle_t = 0.6
				jiggle_dir = Vector2.RIGHT.rotated(randf() * TAU)
			dir = jiggle_dir
		if dir == Vector2.ZERO:
			stats["idle_s"] += dt
		# Unstick: no progress for 1.5s while trying to move.
		if dir != Vector2.ZERO and pos.distance_to(last_pos) < 0.5:
			stuck_t += dt
		else:
			stuck_t = 0.0
		if stuck_t > 1.5:
			jiggle_t = 0.5
			jiggle_dir = dir.rotated(PI * (0.5 if randf() < 0.5 else -0.5))
			stuck_t = 0.0
			obj = null
		if jiggle_t > 0.0:
			jiggle_t -= dt
			dir = jiggle_dir
		last_pos = pos
		steer(dir)
	steer(Vector2.ZERO)

## HAUL METRICS (pad-move before/after): a box's trip (picked up out of
## RECEIVING -> unpacked), each unpacked item's trip (unpacked -> on a
## shelf), a box's whole cycle (picked up -> its last item shelved), and the
## player's walked distance per item placed. Solo only (the host's own
## player; every product today comes out of a box, the store opens empty).
var _haul := {}

func _now() -> float:
	return stats["shift_len"] - main.shift_time_left

func _track_haul(p: Node2D, my_carry: Node2D) -> void:
	if _haul.is_empty():
		return
	var t := _now()
	if _haul["last_pos"] != null:
		var step: float = p.global_position.distance_to(_haul["last_pos"])
		if step < 60.0: # not a teleport
			_haul["walk_px"] += step
	_haul["last_pos"] = p.global_position
	# Box picked up by me.
	if my_carry and my_carry.is_in_group("delivery_box") and not _haul["box_t"].has(my_carry.name):
		_haul["box_t"][my_carry.name] = t
	if my_carry and my_carry.is_in_group("delivery_box"):
		_haul["last_carry"] = my_carry.name
	# An item in my hands: pickup time and distance walked, per carry.
	if my_carry and not my_carry.is_in_group("delivery_box"):
		if _haul["item_carry"] == null or _haul["item_carry"][0] != my_carry:
			_haul["item_carry"] = [my_carry, t, 0.0]
		elif _haul["last_pos_c"] != null:
			_haul["item_carry"][2] += minf(60.0, p.global_position.distance_to(_haul["last_pos_c"]))
	elif _haul["item_carry"] != null:
		var ic: Array = _haul["item_carry"]
		if is_instance_valid(ic[0]) and (_is_placed(ic[0]) or _at_a_slot(ic[0])):
			_haul["carry_item_s"].append(t - ic[1])
			_haul["carry_item_px"].append(ic[2])
		_haul["item_carry"] = null
	_haul["last_pos_c"] = p.global_position
	# A box came apart: the products that appeared since last frame are its.
	var born := []
	for o in get_nodes_in_group("carryable"):
		if o.is_in_group("delivery_box") or _haul["seen"].has(o):
			continue
		_haul["seen"][o] = true
		born.append(o)
	if dl().unpack_event_id != _haul["last_event"]:
		_haul["last_event"] = dl().unpack_event_id
		var bname = _haul["last_carry"]
		if bname != null and _haul["box_t"].has(bname):
			_haul["carry_s"].append(t - _haul["box_t"][bname])
			_haul["box_items"][bname] = {"t0": _haul["box_t"][bname], "left": born.size()}
			for o in born:
				_haul["item_born"][o] = [t, bname]
		_haul["last_carry"] = null
	# Items shelved.
	for o in _haul["item_born"].keys():
		if not is_instance_valid(o):
			_haul["item_born"].erase(o)
			continue
		if _is_placed(o):
			var rec: Array = _haul["item_born"][o]
			_haul["item_s"].append(t - rec[0])
			var bi: Dictionary = _haul["box_items"][rec[1]]
			bi["left"] -= 1
			if bi["left"] == 0:
				_haul["box_cycle_s"].append(t - bi["t0"])
			_haul["item_born"].erase(o)

func _mean(a: Array) -> float:
	return 0.0 if a.is_empty() else a.reduce(func(x, y): return x + y, 0.0) / a.size()

func _haul_line() -> String:
	if _haul.is_empty():
		return ""
	return "HAUL boxes %d carry %.1fs avg | items shelved %d, pad->shelf %.1fs avg | full box cycles %d, %.1fs avg | walked %.0fpx, %.0fpx per place-press | item carries %d, %.1fs / %.0fpx avg pickup->shelf" % [_haul["carry_s"].size(), _mean(_haul["carry_s"]), _haul["item_s"].size(), _mean(_haul["item_s"]), _haul["box_cycle_s"].size(), _mean(_haul["box_cycle_s"]), _haul["walk_px"], _haul["walk_px"] / maxf(1.0, stats["placed"]), _haul["carry_item_s"].size(), _mean(_haul["carry_item_s"]), _mean(_haul["carry_item_px"])]

## WEEK 15 — the solo brain's delivery job.
var trace := "--trace" in OS.get_cmdline_user_args()
## WEEK 16 — the solo brain's prep phase.
var never_open := "--never-open" in OS.get_cmdline_user_args()
## PHASE 5: --open-rule=typical (see _play_shift()); "" = the brain's own rule.
var open_rule: String = (func():
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--open-rule="):
			return a.substr("--open-rule=".length())
	return "").call()
const OPEN_WHEN_FILLED := 0.9
const OPEN_WHEN_IDLE := 12.0
var _prep_idle_t := 0.0

func _fill_ratio() -> float:
	var f := 0
	var n := 0
	for sb in main.shelves:
		if main.is_unlocked_at_pos(sb.global_position):
			f += sb.get_node("Shelf").filled_count()
			n += sb.get_node("Shelf").slot_count()
	return float(f) / maxf(1.0, n)

## Walk to the Store sign and press E at it (the real key).
func _go_flip_sign() -> void:
	var at: Vector2 = main.STORE_SIGN_POS + Vector2(0, 45)
	await walk_to(at, 8.0, 30.0)
	await tap(act + "interact")
	await wait_until(func(): return main.store_open, 1.0)
var _trace_t := 0.0
const BOX_RUN_BELOW := 3 # loose stock (free, shelvable) under this -> unpack a box
var box_phase := 0

func _loose_stockable() -> int:
	var n := 0
	for obj in get_nodes_in_group("carryable"):
		if obj.is_in_group("delivery_box") or obj.get_node("Carryable").carrier_id != 0 or _is_placed(obj) or _at_a_slot(obj):
			continue
		if main.is_unlocked_at_pos(obj.global_position) or main._grid_cell_of(obj.global_position) in [Vector2i(1, 1), main.STORAGE_GRID_POS]:
			n += 1
	return n

## WEEK 17 (co-op sim): leave it to a teammate who's nearer — without this,
## every bot chases the same box/product and a crew does less than one bot.
## No effect solo.
func _teammate_closer(p: Node2D, obj: Node2D) -> bool:
	var mine := p.global_position.distance_to(obj.global_position)
	for id in main.players:
		var q: Node2D = main.players[id]
		if q != p and q.global_position.distance_to(obj.global_position) + 20.0 < mine:
			return true
	return false

## The solo brain also runs against the pre-Week-18 code (one Storage pad,
## PAD_CENTER) for the before/after pad comparison, unchanged from how it
## played there: in from the receiving side (east), facing west.
func _per_section_pads() -> bool:
	return dl().has_method("pad_center")

func _brain_pad_stand(box: Node2D) -> Vector2:
	if _per_section_pads():
		return dl().pad_center(box.get_meta("section")) + Vector2(0, 58)
	return dl().PAD_CENTER + Vector2(58, 0)

func _on_own_pad(box: Node2D) -> bool:
	if _per_section_pads():
		return dl().on_pad(box.global_position, box.get_meta("section"))
	return dl().on_pad(box.global_position)

## Nearest free box that isn't on its pad already (one set down on the wrong
## pad is just a box on the floor); only_section: one of that section's.
var order_box_aware := not "--order-blind" in OS.get_cmdline_user_args()

func _pick_box(p: Node2D, only_section := "") -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for b in get_nodes_in_group("delivery_box"):
		if b.is_queued_for_deletion() or b.get_node("Carryable").carrier_id != 0 or _on_own_pad(b):
			continue
		if only_section != "" and b.get_meta("section") != only_section:
			continue
		if _teammate_closer(p, b):
			continue
		var d := p.global_position.distance_to(b.global_position)
		if d < best_d:
			best_d = d
			best = b
	return best

## Steer around any spill ahead within reach whose edge the current heading
## would clip — toward whichever side is already closer to clear.
func _avoid_spills(pos: Vector2, dir: Vector2, goal: Vector2) -> Vector2:
	for s in main.ambience.spills:
		var c: Vector2 = s["pos"]
		var r: float = s["r"]
		if goal.distance_to(c) < r + 30.0:
			continue # the thing I want is in it — go in
		var rel := c - pos
		if rel.length() < r:
			continue # already in it: just keep going and get out
		var along := rel.dot(dir)
		if along < 0.0 or along > r + 100.0:
			continue
		var lateral := rel.dot(dir.orthogonal())
		if absf(lateral) < r + 22.0:
			var away := -signf(lateral) if lateral != 0.0 else 1.0
			return (dir + dir.orthogonal() * away * 1.4).normalized()
	return dir

## ---------------------------------------------------------------------------
## WEEK 11 — PRIORITY ORDERS + STOCKING GRACE

## OCT 2026 PHASE 2 — "evaluate as if it were Day d": the economy old Day d
## had (Main.gd's DEBUG_DAY_PRESETS, stage included), and back again.
func _econ_snap() -> Array:
	return [main.current_day, main.sections_owned, main.complication_stage, main.lifetime_earned, main.money]

func _econ_restore(snap: Array) -> void:
	main.current_day = snap[0]
	main.sections_owned = snap[1]
	main.complication_stage = snap[2]
	main.lifetime_earned = snap[3]
	main.money = snap[4]

func _as_day(d: int) -> void:
	main.current_day = d
	main._apply_debug_day_preset(d)
	main._advance_complication_stage()

func section_by_name(n: String) -> Dictionary:
	for s in main.SECTIONS:
		if s["name"] == n:
			return s
	return {}

## Free, unshelved products of a section's color, sitting in open floor.
func loose_products(section_name: String) -> Array:
	var color: Color = main.SECTION_COLORS[section_name]
	var out := []
	for obj in get_nodes_in_group("carryable"):
		if obj.get_node("Carryable").carrier_id != 0 or _is_placed(obj):
			continue
		if obj.get_node("Polygon2D").color.is_equal_approx(color):
			out.append(obj)
	return out

## An empty slot on a (non-wrecked) shelf in the given section.
func empty_slot_in(section_name: String) -> Marker2D:
	var cell: Vector2i = section_by_name(section_name)["grid_pos"]
	for sb in main.shelves:
		if main._grid_cell_of(sb.global_position) != cell:
			continue
		var shelf: Node = sb.get_node("Shelf")
		if shelf.wrecked:
			continue
		for i in shelf.slots.size():
			if not shelf.filled[i]:
				return shelf.slots[i]
	return null

## Real placement: the product is put down on a slot and the shelf's own
## settle check decides it's stocked (which is what fires the order hook).
func stock_one(section_name: String, obj: RigidBody2D = null) -> RigidBody2D:
	if obj == null:
		var pool := loose_products(section_name)
		if pool.is_empty():
			return null
		obj = pool[0]
	var slot := empty_slot_in(section_name)
	if slot == null:
		return null
	move_body(obj, slot.global_position)
	var ok := await wait_until(func(): return _is_placed(obj), 2.0)
	return obj if ok else null

## Sell an item the way a shopper does: it leaves the shelf (a shopper picks
## it up first), then the register completes the purchase.
func sell(obj: RigidBody2D) -> void:
	move_body(obj, main.cashiers[0].global_position + Vector2(0, 120))
	await wait_until(func(): return not _is_placed(obj), 1.0)
	main.cashiers[0].get_node("Cashier")._complete_purchase(obj, -99999)
	await physics_frame

func rects_overlap(a: Control, b: Control) -> bool:
	return a.get_global_rect().intersects(b.get_global_rect())

func _run_orders() -> void:
	await wait_until(func(): return main.shift_active, 10.0)
	# Captured on the very first frames of the shift, before it ticks away.
	var prep_now: float = main.prep_time_left
	var clock_now: float = main.shift_time_left
	check(main.current_day == 5, "started on Day 5")

	# --- G (WEEK 16): the prep ceiling replaced the grace period. Ceiling =
	# 3 min + 3 min per section opened after Dry Goods; the day's clock =
	# ceiling + the SAME selling window every day had before (111s, 96s on
	# the finale) — so a team that uses the whole ceiling sells exactly as long
	# as it used to.
	var sd: float = main.shift_duration
	var real_day := _econ_snap()
	var table := {}
	for d in range(1, 8):
		_as_day(d)
		table[d] = [main._prep_ceiling(), main._current_shift_duration()]
	_econ_restore(real_day)
	print("PREP  day -> [prep ceiling, day clock]: %s" % str(table))
	# (PHASE 5: per section from the constant — 180 s until then, 90 s now.)
	var ps: float = main.PREP_CEILING_BASE
	var pp: float = main.PREP_CEILING_PER_SECTION
	var want := {1: [ps, sd], 2: [ps, sd], 3: [ps + pp, sd], 4: [ps + pp, sd], 5: [ps + 2 * pp, sd], 6: [ps + 2 * pp, sd], 7: [ps + 3 * pp, sd - main.FINALE_SELLING_CUT]}
	for d in range(1, 8):
		check(is_equal_approx(table[d][0], want[d][0]) and is_equal_approx(table[d][1] - table[d][0], want[d][1]), "G: Day %d: prep ceiling %.0fs, clock %.0fs -> %.0fs selling if the whole ceiling is used (as before: %.0fs)" % [d, table[d][0], table[d][1], table[d][1] - table[d][0], want[d][1]])
	check(absf(prep_now - table[5][0]) < 0.5 and not main.store_open, "G: the live Day 5 shift started closed, with %.1fs of prep" % prep_now)
	check(absf(clock_now - table[5][1]) < 0.5, "G: ...and %.1fs on the clock" % clock_now)

	# Test control: no auto orders, no customers buying our stock, manager
	# and forklift parked far away, player in the break room.
	# WEEK 17: hazards only run once the store is open — open it, hold the
	# customers instead of the prep.
	main.test_hold_customers = true
	main.open_store(0)
	main._order_timer = 1.0e9
	fk()._pause_timer = 1.0e9
	pin_manager(Vector2(480, 1350), 0.0)
	player().teleport_to(Vector2(480, 270))
	await wait(0.5)
	var cashier: Node = main.cashiers[0].get_node("Cashier")

	# --- O1: a filled order. Wrong-section stock doesn't count, a tagged item
	# sold BEFORE the order fills is still credited once it fills, stock
	# placed after it closed is untagged, and only the tagged items pay 1.5x.
	main._issue_priority_order("Dry Goods", 3)
	await wait(0.1) # a Main._process pass, so the banner has been drawn
	check(main.order_section == "Dry Goods" and main.order_needed == 3, "O1: order open: %d in %s" % [main.order_needed, main.order_section])
	check(main._order_label.visible and "Stock 3 more in Dry Goods" in main._order_label.text and ("%ds left" % int(main._priority_order_window())) in main._order_label.text, "O1: banner: '%s'" % main._order_label.text)
	var wrong := await stock_one("Dairy/Frozen")
	check(wrong != null and not wrong.has_meta("priority_order") and main.order_stocked == 0, "O1: stocking Dairy/Frozen doesn't count toward a Dry Goods order")
	var sold0: int = main._total_sold() - main._sold_at_day_start
	var pay0: int = main._pay_today()
	var a := await stock_one("Dry Goods")
	check(a != null and a.get_meta("priority_order", 0) == main._order_id and main.order_stocked == 1, "O1: first Dry Goods item tagged to order #%d" % main._order_id)
	await wait(0.1)
	check("Stock 2 more in Dry Goods" in main._order_label.text, "O1: banner counts down the quantity: '%s'" % main._order_label.text)
	await sell(a)
	check(main.priority_sales_today == 0, "O1: tagged item sold before the order filled: not credited yet")
	var b := await stock_one("Dry Goods")
	# Knock b off its shelf and put it back — re-stocking the same item mustn't count twice.
	move_body(b, b.global_position + Vector2(0, 80) * (-b.get_parent().global_transform.y if false else Vector2.ONE))
	await wait_until(func(): return not _is_placed(b), 1.0)
	await stock_one("Dry Goods", b)
	check(main.order_stocked == 2, "O1: re-shelving the same item doesn't count twice (%d/3)" % main.order_stocked)
	var c := await stock_one("Dry Goods")
	check(main.order_section == "" and main.orders_filled_today == 1, "O1: third item fills the order (filled today: %d)" % main.orders_filled_today)
	check(main.priority_sales_today == 1, "O1: the early sale is credited once it fills (priority sales: %d)" % main.priority_sales_today)
	await wait(0.1)
	check(main._order_label.visible and "ORDER FILLED" in main._order_label.text, "O1: result on the banner: '%s'" % main._order_label.text)
	var d := await stock_one("Dry Goods")
	check(d != null and not d.has_meta("priority_order"), "O1: stock placed after the order closed is untagged")
	await sell(b)
	await sell(c)
	await sell(d)
	await sell(wrong)
	var sold_now: int = main._total_sold() - main._sold_at_day_start
	check(sold_now - sold0 == 5, "O1: 5 sales recorded (%d)" % (sold_now - sold0))
	check(main.priority_sales_today == 3, "O1: exactly the 3 tagged items earned the bonus (%d)" % main.priority_sales_today)
	var expect: int = pay0 + 5 * main.PAY_PER_SALE + 3 * 5
	check(main._pay_today() == expect, "O1: pay +$%d = 2 plain x $10 + 3 order items x $15 (got %s, expected %s)" % [expect - pay0, main._format_money(main._pay_today()), main._format_money(expect)])

	# --- O2: a lapsed order. Partial stock, window runs out: no penalty, no
	# bonus on the partial items, ordinary pay for them.
	await wait(main.PRIORITY_ORDER_RESULT_SECONDS + 0.2)
	main._issue_priority_order("Dairy/Frozen", 4)
	var p1 := await stock_one("Dairy/Frozen")
	var p2 := await stock_one("Dairy/Frozen")
	check(main.order_stocked == 2 and p1.has_meta("priority_order") and p2.has_meta("priority_order"), "O2: 2/4 stocked toward the Dairy/Frozen order")
	await sell(p1) # sold during the window — held pending
	var ps_before: int = main.priority_sales_today
	var pay_before: int = main._pay_today()
	var lapsed := await wait_until(func(): return main.order_section == "", main._priority_order_window() + 1.0)
	check(lapsed and main.orders_filled_today == 1 and main.orders_called_today == 2, "O2: window expired unfilled (filled %d of %d called)" % [main.orders_filled_today, main.orders_called_today])
	check(main._pay_today() == pay_before, "O2: no penalty for missing it (pay %s -> %s)" % [main._format_money(pay_before), main._format_money(main._pay_today())])
	await physics_frame
	await wait(0.1)
	check("missed" in main._order_label.text, "O2: result on the banner: '%s'" % main._order_label.text)
	await sell(p2)
	check(main.priority_sales_today == ps_before, "O2: items stocked toward a missed order pay normally (priority sales still %d)" % main.priority_sales_today)
	check(main._pay_today() == pay_before + main.PAY_PER_SALE, "O2: ...$10, not $15")
	check(not main._pending_order_sales.has(p1.get_meta("priority_order") if is_instance_valid(p1) else -1), "O2: nothing left pending")

	# --- O3: the order banner and the LOOK BUSY warning (and the write-up
	# toast) up at the same time — separate rows, no overlap, all on screen.
	await wait(main.PRIORITY_ORDER_RESULT_SECONDS + 0.2)
	var spot := Vector2(1440, 270) # Dry Goods aisle
	player().teleport_to(spot)
	pin_manager(spot + Vector2(-180, 0), 0.0)
	var st: Dictionary = mgr()._player_state(1)
	st["cooldown"] = 0.0
	main._issue_priority_order("Produce", 3)
	# Wait for the hot "!" stage — the longest LOOK BUSY text.
	var both := await wait_until(func(): return main._watch_label.visible and main._order_label.visible and mgr().watch_level >= mgr().WARN_LEVEL, 6.0)
	main._toast_label.text = "WRITTEN UP for standing around!  -$25"
	main._toast_timer = 3.0
	await process_frame
	await process_frame
	check(both, "O3: LOOK BUSY ('%s') and the order banner ('%s') both up" % [main._watch_label.text, main._order_label.text])
	var labels := [main._watch_label, main._toast_label, main._order_label]
	var clash := false
	for i in labels.size():
		for j in range(i + 1, labels.size()):
			if rects_overlap(labels[i], labels[j]):
				clash = true
	print("RECTS  watch %s | toast %s | order %s" % [main._watch_label.get_global_rect(), main._toast_label.get_global_rect(), main._order_label.get_global_rect()])
	check(not clash, "O3: banner, LOOK BUSY and the toast sit in separate rows (no overlap)")
	var alert_layer: CanvasLayer = main.get_node("AlertLayer")
	var debug_layer: CanvasLayer = main.get_node("DebugLayer")
	check(debug_layer.layer > alert_layer.layer and main.report_layer.layer > debug_layer.layer, "O3: debug HUD draws above the banner/toast/LOOK BUSY rows, report above both (layers %d / %d / %d)" % [alert_layer.layer, debug_layer.layer, main.report_layer.layer])
	# The game's own viewport (project.godot), not the headless window's.
	var vp := Vector2(ProjectSettings.get_setting("display/window/size/viewport_width"), ProjectSettings.get_setting("display/window/size/viewport_height"))
	var widest := ""
	var fits := true
	for sample in ["MANAGER: Stock 9 more in Dairy/Frozen!  15s left  (1.5x pay)", "ORDER FILLED — those 9 Dairy/Frozen items pay 1.5x!", "Priority order missed (Dairy/Frozen) — no bonus", main._watch_label.text]:
		main._order_label.text = sample
		var w: float = main._order_label.get_theme_font("font").get_string_size(sample, HORIZONTAL_ALIGNMENT_LEFT, -1, 24).x
		if w > vp.x:
			fits = false
			widest = "%s (%.0fpx)" % [sample, w]
	check(fits, "O3: longest banner texts fit the %.0fpx screen%s" % [vp.x, (" — too wide: " + widest) if not fits else ""])
	await shot("o3_order_banner_with_look_busy")
	release_manager()
	main._clear_priority_order()
	pin_manager(Vector2(480, 1350), 0.0)
	st["meter"] = 0.0
	st["cooldown"] = 1000.0

	# --- O4: the automatic call-outs — random over unlocked sections, sized
	# to what each can take, never before Day 5.
	var called_before: int = main.orders_called_today
	var seen := {}
	var qtys := []
	for i in 40:
		main._issue_priority_order()
		if main.order_section != "":
			seen[main.order_section] = true
			qtys.append(main.order_needed)
		main._clear_priority_order()
	main.orders_called_today = called_before # those were test rolls, not the day's orders
	var unlocked: Array = main._unlocked_sections().map(func(s): return s["name"])
	check(seen.size() >= 2 and seen.keys().all(func(n): return n in unlocked), "O4: sections called over 40 rolls: %s (unlocked: %s)" % [str(seen.keys()), str(unlocked)])
	check(qtys.all(func(q): return q >= 1 and q <= main.PRIORITY_ORDER_QTY_MAX), "O4: quantities in range: %s" % str(qtys))
	# WEEK 16: call-outs only run while the store is open — open it, but keep
	# customers out of the test (their top-up tick held off).
	if not main.store_open:
		main.open_store(0)
	main._restock_timer = 1.0e9
	main._order_timer = 0.01
	await wait(0.1)
	check(main.order_section != "", "O4: the interval timer calls one out on its own (%s x%d)" % [main.order_section, main.order_needed])
	check(is_equal_approx(main._order_timer, main._priority_order_interval()) or main._order_timer > main._priority_order_interval() - 1.0, "O4: next call-out %.0fs later" % main._order_timer)
	main._clear_priority_order()
	_as_day(4)
	main._order_timer = 0.01
	main._tick_priority_orders(1.0)
	check(main.order_section == "", "O4: no orders on Day 4")
	_econ_restore(real_day)
	main._order_timer = 1.0e9

	# --- O5: day rollover with an order open — the report shows the orders
	# line, the order lapses at the bell, Day 6 starts clean with orders on
	# and the week's bonus kept.
	main._issue_priority_order("Dry Goods", 2)
	var week_bonus: int = main.priority_sales_week
	main.shift_time_left = 0.1
	await wait_until(func(): return main.is_day_report_active(), 3.0)
	await wait(0.2) # let Main._process refresh the report labels
	check(main.order_section == "" and not main._order_label.visible, "O5: open order lapses at the end of the day, banner hidden under the report")
	check(main.report_order_label.visible and main.report_order_label.text.begins_with("Priority orders: 1/"), "O5: report line: '%s'" % main.report_order_label.text)
	var expect_pay: int = (main._total_sold() - main._sold_at_day_start) * main.PAY_PER_SALE + main.priority_sales_today * 5 + main.cleanup.clean_bonus_today - main.writeups_today * main.WRITEUP_PENALTY
	check(main.report_pay_label.text.begins_with("Pay Today: %s" % main._format_money(expect_pay)), "O5: report pay includes the order bonus: '%s'" % main.report_pay_label.text)
	print("REPORT  %s | %s | %s | %s" % [main.report_today_label.text, main.report_writeup_label.text, main.report_order_label.text, main.report_pay_label.text])
	await shot("o5_report")
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and main.current_day == 6, 5.0)
	check(main.current_day == 6, "O5: advanced to Day 6")
	check(absf(main.prep_time_left - (main.PREP_CEILING_BASE + 2 * main.PREP_CEILING_PER_SECTION)) < 0.5 and not main.store_open, "O5: Day 6 opens closed, %.1fs of prep" % main.prep_time_left)
	check(main.orders_called_today == 0 and main.orders_filled_today == 0 and main.priority_sales_today == 0, "O5: Day 6 order tallies reset")
	check(main.priority_sales_week == week_bonus, "O5: week keeps its %d bonus sales" % main.priority_sales_week)
	check(is_equal_approx(main._order_timer, main._priority_order_interval()) or main._order_timer > main._priority_order_interval() - 1.0, "O5: first Day 6 call-out due in %.0fs" % main._order_timer)
	finish()

## ---------------------------------------------------------------------------
## NET ORDERS — 2-4 players, one order, several contributors
##
## Tags live only on the host (Main.gd's note_item_stocked()); clients only
## ever see the replicated order counters. So "no desync" is checked from
## both ends: the host checks every item a CLIENT saw itself stock into the
## ordered section is tagged to that order, exactly once, and nothing else
## is; every client checks its own banner/counters/report against what the
## host saw. Peers swap facts through small JSON files in user://net_orders/
## (same machine), never through the game's own RPCs.

## WEEK 21: SW_NET_DIR=user://some_dir/ in the environment moves it, so two
## networked tests can run at once without reading each other's files.
var NET_DIR: String = OS.get_environment("SW_NET_DIR") if OS.get_environment("SW_NET_DIR") != "" else "user://net_orders/"
const PER_PLAYER := 2 # items each player stocks toward the shared order

func _net_write(file: String, data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(NET_DIR)
	var f := FileAccess.open(NET_DIR + file + ".tmp", FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()
	DirAccess.rename_absolute(NET_DIR + file + ".tmp", NET_DIR + file) # atomic: readers never see half a file

func _net_read(file: String, timeout: float) -> Dictionary:
	var t := 0.0
	while t < timeout:
		if FileAccess.file_exists(NET_DIR + file):
			var parsed = JSON.parse_string(FileAccess.get_file_as_string(NET_DIR + file))
			if parsed is Dictionary:
				return parsed
		await create_timer(0.25).timeout
		t += 0.25
	return {}

## True once `item` is stocked in any slot of a shelf in `cell` — not just
## the slot it was aimed at: a dropped item can come to rest in the next one
## over, and that still counts. On the host, the shelf's own occupancy says
## so exactly; a client only has the replicated `filled` flags, so there it
## has to be a filled slot whose nearest item is this one (within the
## shelf's LEAVE_RADIUS — the placing player can nudge it).
func _settled_in_cell(item: Node2D, cell: Vector2i) -> bool:
	for s in main.shelves:
		if main._grid_cell_of(s.global_position) != cell:
			continue
		var shelf: Node = s.get_node("Shelf")
		if main.multiplayer.is_server():
			if shelf.contains(item):
				return true
			continue
		for i in shelf.slots.size():
			if not shelf._is_filled(i):
				continue
			var sp: Vector2 = shelf.slots[i].global_position
			var d := item.global_position.distance_to(sp)
			if d > shelf.LEAVE_RADIUS:
				continue
			var nearest := true
			for other in get_nodes_in_group("carryable"):
				if other != item and other.global_position.distance_to(sp) < d:
					nearest = false
					break
			if nearest:
				return true
	return false

## Stock PER_PLAYER items toward the open order with this peer's own player,
## through the real keyboard path. An item counts as "mine" once this peer
## sees (via replication, on a client) its slot fill with the item sitting in
## it. Returns their node names — identical on every peer (spawner names).
## Every peer stocks its share (PER_PLAYER) of the ordered section first —
## so the zero-latency host can't fill the whole order before a client gets
## a turn — then gives slower peers a moment, then everyone keeps going
## until the order fills. Returns [items it saw settle (from replicated
## state on a client), items it pressed C on in the section]. The second is
## exact on every peer — it's this peer's own keypress — so it's what the
## host's attribution is checked against. An item nudged off a shelf and
## re-stocked shows up again for whoever re-stocked it; the host must not
## count it twice.
func _contribute_to_order() -> Array:
	var settled := []
	var placed := []
	var section: String = main.order_section
	var cell: Vector2i = section_by_name(section)["grid_pos"]
	var mine_shelves: Array = main.shelves.filter(func(s): return main._grid_cell_of(s.global_position) == cell)
	mine_shelves.sort_custom(func(a, b): return String(a.name) < String(b.name))
	var ids: Array = main.players.keys()
	ids.sort()
	my_shelf = mine_shelves[ids.find(me) % mine_shelves.size()]
	order_only = true
	on_place = func(item: Node2D, slot: Marker2D):
		if main._grid_cell_of(slot.global_position) != cell or main.order_section == "":
			return
		if not (String(item.name) in placed):
			placed.append(String(item.name))
		var ok := await wait_until(func(): return is_instance_valid(item) and _settled_in_cell(item, cell), 4.0)
		if ok and not (item.name in settled):
			settled.append(String(item.name))
	var closed := func(): return main.order_section != section or not main.shift_active
	await _play_shift(func(): return settled.size() >= PER_PLAYER or closed.call())
	steer(Vector2.ZERO)
	if main.multiplayer.is_server():
		# The host has no network latency, so it always finishes its share
		# first — hold off until every client says its share is in.
		var t := 0.0
		while t < 30.0 and not closed.call() and not main.players.keys().all(func(id): return id == 1 or FileAccess.file_exists(NET_DIR + "share_%d.json" % id)):
			await wait(0.25)
			t += 0.25
	else:
		_net_write("share_%d.json" % me, {"settled": settled.size()})
		await wait_until(closed, 6.0)
	await _play_shift(closed)
	steer(Vector2.ZERO)
	await wait(4.2) # let the last verdicts come in
	my_shelf = null
	order_only = false
	on_place = Callable()
	return [settled, placed]

## What every peer saw of the orders during free play: each order it saw
## open (section, quantity, and whether its own banner was up the whole
## time the order was), and each FILLED/missed result line it got.
var _net_view := {"orders": [], "results": [], "open_frames": 0, "banner_frames": 0, "text_bad": 0}
var _net_watch := false

func _watch_orders_view() -> void:
	_net_watch = true
	var was_open := false
	var last_result_t := 0.0
	while _net_watch:
		await physics_frame
		var open: bool = main.order_section != "" and not main.is_day_report_active()
		if open:
			_net_view["open_frames"] += 1
			if main._order_label.visible:
				_net_view["banner_frames"] += 1
			var expect_text := "MANAGER: Stock %d more in %s!" % [main.order_needed - main.order_stocked, main.order_section]
			if not main._order_label.text.begins_with(expect_text):
				_net_view["text_bad"] += 1
			if not was_open:
				_net_view["orders"].append([main.order_section, main.order_needed])
		was_open = open
		if main._order_result_timer > last_result_t + 0.5: # a fresh result RPC just landed
			_net_view["results"].append("FILLED" if main._order_result_filled else "missed")
		last_result_t = main._order_result_timer

## Host-side, every physics frame: which items carry which order's tag, who
## last carried each tagged item, and which tagged items have since been
## sold (freed — nothing else frees product mid-shift).
var _tags := {} # item name -> order id
var _tag_carrier := {} # item name -> peer id that last carried it
var _last_carrier := {} # item name -> last nonzero carrier
var _tag_sold := {} # item name -> order id, for tagged items that vanished
var _tag_nodes := {}
var _order_needed_seen := {} # order id -> quantity
var _order_stocked_seen := {} # order id -> last stocked count seen while open
var _tag_watch := false

func _watch_tags() -> void:
	_tag_watch = true
	while _tag_watch:
		await physics_frame
		if main._order_id != 0:
			_order_needed_seen[main._order_id] = main.order_needed
			_order_stocked_seen[main._order_id] = main.order_stocked
		for n in _tag_nodes.keys():
			if not is_instance_valid(_tag_nodes[n]):
				_tag_sold[n] = _tags[n]
				_tag_nodes.erase(n)
		for obj in get_nodes_in_group("carryable"):
			var c: int = obj.get_node("Carryable").carrier_id
			if c > 0:
				_last_carrier[String(obj.name)] = c
			if obj.has_meta("priority_order") and not _tags.has(String(obj.name)):
				_tags[String(obj.name)] = obj.get_meta("priority_order")
				_tag_carrier[String(obj.name)] = _last_carrier.get(String(obj.name), 0)
				_tag_nodes[String(obj.name)] = obj

func _run_net_orders_host() -> void:
	var want := 2
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--players="):
			want = int(a.substr(10))
	var d := DirAccess.open("user://")
	if d and d.dir_exists("net_orders"):
		for f in DirAccess.get_files_at(NET_DIR):
			DirAccess.remove_absolute(NET_DIR + f)
	await wait_until(func(): return main.shift_active and main.players.size() >= want, 40.0)
	var names := {}
	for id in main.players:
		names[id] = main.player_display_name(id)
	check(main.players.size() == want, "net: %d players connected (%s)" % [main.players.size(), str(names.values())])
	check(main.current_day == 5, "net: Day 5")
	# Controlled phase: no auto orders, no customers, both hazards parked.
	main._order_timer = 1.0e9
	main.prep_time_left = 1.0e9
	fk()._pause_timer = 1.0e9
	pin_manager(Vector2(480, 1350), 0.0)
	_watch_tags()
	_watch_orders_view()
	await wait(2.0)

	# --- N0: players touching each other over the network. Found by this
	# pass: players were CharacterBody2D in the default GROUNDED mode, so a
	# player treated whoever it was touching as a floor and rode its velocity
	# — and in network play each process rides the OTHER's synced copy, a
	# feedback loop that ran both off the bottom of the map at ~400px/s.
	await _n0_touching_players(names)

	# --- N1: one Dry Goods order sized so every player has to contribute.
	# Everyone starts in Dry Goods so the test measures the stocking, not the
	# walk out of the break room (teleport_to is an RPC to each player's owner
	# — movement is client-authoritative). On the open floor BELOW the product
	# spawn band (y 120-360): teleporting a player onto loose stock makes the
	# physics engine fling it apart, straight into slots.
	var k := 0
	for id in main.players:
		main.players[id].rpc("teleport_to", Vector2(1335 + 70 * k, 470))
		k += 1
	await wait(1.5)
	var qty := PER_PLAYER * want
	main._issue_priority_order("Dry Goods", qty)
	# 45s instead of 15 for this one: it checks attribution across players,
	# not the window (free play below runs the real 15s windows).
	main.order_time_left = 45.0
	var order_id: int = main._order_id
	var mine: Array = await _contribute_to_order()
	var filled := await wait_until(func(): return main.order_section == "", 60.0)
	check(filled and main._filled_order_ids.has(order_id), "N1: %d-item order filled by %d players" % [qty, want])
	check(main.orders_filled_today == 1 and main.orders_called_today == 1, "N1: filled %d of %d called" % [main.orders_filled_today, main.orders_called_today])
	await wait(0.5)
	var tagged := _tags.keys().filter(func(n): return _tags[n] == order_id)
	check(tagged.size() == qty, "N1: exactly %d items tagged to order #%d (got %d: %s)" % [qty, order_id, tagged.size(), str(tagged)])
	var by_peer := {}
	for n in tagged:
		var who: int = _tag_carrier[n]
		by_peer[who] = by_peer.get(who, 0) + 1
	print("NET  tagged items by the player who stocked them: %s" % str(by_peer))
	# Peer 0 = never carried by anyone: a loose item walked into a matching
	# slot, which the game has always counted as stocked (see Shelf.gd).
	var pushed_in: int = by_peer.get(0, 0)
	check(main.players.keys().all(func(id): return by_peer.get(id, 0) >= 1), "N1: every player's stock counted toward the order: %s" % str(by_peer))
	# Cross-check against what each peer saw itself stock (clients report theirs).
	var stocked_by := {1: mine[0]}
	var pressed_by := {1: mine[1]}
	for id in main.players.keys():
		if id == 1:
			continue
		var r := await _net_read("placed_%d.json" % id, 30.0)
		stocked_by[id] = r.get("items", [])
		pressed_by[id] = r.get("pressed", [])
	var union := []
	for id in stocked_by:
		for n in stocked_by[id]:
			if not (n in union):
				union.append(n)
	print("NET  items each peer saw itself stock: %s" % str(stocked_by))
	union.sort()
	tagged.sort()
	# Every tag the host placed on an item a player carried in is one that
	# player's own process pressed C on in Dry Goods — no phantom tags, none
	# credited to the wrong peer.
	var phantom := tagged.filter(func(n): return _tag_carrier[n] != 0 and not (n in pressed_by.get(_tag_carrier[n], [])))
	check(phantom.is_empty(), "N1: every carried-in tagged item was placed (C pressed) by the peer the host credits (mismatches: %s)" % str(phantom))
	print("NET  C pressed in Dry Goods by each peer: %s" % str(pressed_by))
	print("NET  %d of %d tagged items were pushed in loose, not carried" % [pushed_in, qty])
	check(main.order_stocked == 0 and _order_stocked_seen.get(order_id, 0) <= qty, "N1: the order's stocked count never ran past its quantity")

	# --- N2: sell them all plus two untagged ones: only the order's items pay 1.5x.
	await wait(1.0)
	var sold0: int = main._total_sold() - main._sold_at_day_start
	var pay0: int = main._pay_today()
	for n in tagged:
		var obj: Node = _tag_nodes.get(n)
		if obj:
			await sell(obj)
	var plain := loose_products("Dry Goods").slice(0, 2)
	for obj in plain:
		await sell(obj)
	await wait(0.3)
	check(main._total_sold() - main._sold_at_day_start - sold0 == qty + 2, "N2: %d sales" % (qty + 2))
	check(main.priority_sales_today == qty, "N2: exactly the %d order items earned the bonus (%d)" % [qty, main.priority_sales_today])
	check(main._pay_today() == pay0 + (qty + 2) * 10 + qty * 5, "N2: pay +%s = %d x $15 + 2 x $10" % [main._format_money(main._pay_today() - pay0), qty])
	await wait(1.0) # let DaySync carry it
	_net_write("phase_n2.json", {"priority_sales_today": main.priority_sales_today, "orders_filled_today": main.orders_filled_today, "orders_called_today": main.orders_called_today, "pay_today": main._pay_today(), "tagged": tagged})

	# --- N3: free play — orders on their own cadence, customers buying,
	# manager and forklift live, everyone stocking. Then the bell.
	release_manager()
	fk()._pause_timer = 0.0
	main.test_hold_customers = false
	if not main.store_open:
		main.open_store(0)
	main._order_timer = 3.0
	main.shift_time_left = 115.0 # call-outs at ~3s, 48s, 93s
	_net_view = {"orders": [], "results": [], "open_frames": 0, "banner_frames": 0, "text_bad": 0}
	await _play_shift()
	steer(Vector2.ZERO)
	await wait_until(func(): return main.is_day_report_active(), 5.0)
	await wait(1.0)
	_net_watch = false
	_tag_watch = false
	# Host bookkeeping invariants, over the whole day.
	var per_order := {}
	for n in _tags:
		per_order[_tags[n]] = per_order.get(_tags[n], 0) + 1
	var tag_ok := true
	for id in _order_needed_seen:
		var expect: int = _order_needed_seen[id] if main._filled_order_ids.has(id) else _order_stocked_seen.get(id, 0)
		if per_order.get(id, 0) != expect:
			tag_ok = false
			print("NET  order #%d: %d tagged, expected %d" % [id, per_order.get(id, 0), expect])
	print("NET  orders %s | tags per order %s | filled ids %s" % [str(_order_needed_seen), str(per_order), str(main._filled_order_ids.keys())])
	check(tag_ok, "N3: every order's tag count == its stocked count (filled: == quantity) — no double counting")
	var bonus_expected := _tag_sold.keys().filter(func(n): return main._filled_order_ids.has(_tag_sold[n])).size()
	check(main.priority_sales_today == bonus_expected, "N3: bonus sales today %d == tagged items of filled orders that sold %d" % [main.priority_sales_today, bonus_expected])
	check(main.orders_called_today >= 3, "N3: %d orders called in free play (+1 controlled)" % (main.orders_called_today - 1))
	var cap: int = main.PRIORITY_ORDER_QTY_MAX + main.PRIORITY_ORDER_QTY_PER_EXTRA_PLAYER * (want - 1)
	check(_net_view["orders"].all(func(o): return o[1] <= cap), "N3: quantities scale with %d players, capped at %d: %s" % [want, cap, str(_net_view["orders"])])
	check(_net_view["banner_frames"] == _net_view["open_frames"] and _net_view["text_bad"] == 0, "N3 host: banner up for every open-order frame (%d/%d), text right" % [_net_view["banner_frames"], _net_view["open_frames"]])
	print("NET  host view: %s" % str(_net_view))
	print("REPORT  %s | %s | %s" % [main.report_today_label.text, main.report_order_label.text, main.report_pay_label.text])
	_net_write("phase_n3.json", {"view": _net_view, "today": main.report_today_label.text, "orders": main.report_order_label.text, "pay": main.report_pay_label.text})
	# Every client's own verdict.
	for id in names:
		if id == 1:
			continue
		var r := await _net_read("result_%d.json" % id, 60.0)
		check(r.get("fails", -1) == 0, "net: %s's own checks passed (failures: %s)" % [names[id], str(r.get("fails", "no result"))])
	await wait(1.0)
	finish()

## Host side of N0: puts every player on the SAME spot in the hub (two
## players walking to the same item end up overlapping exactly like this),
## everyone walks up-left for 1.5s — the heading the runaway was captured
## on — then everyone lets go. Nobody should keep moving afterward, nobody
## should end up off the map.
func _n0_touching_players(names: Dictionary) -> void:
	for id in main.players:
		main.players[id].rpc("teleport_to", N0_SPOT)
	await wait(1.0)
	_net_write("n0_go.json", {"go": true})
	var drift: Array = await _n0_walk_then_stop()
	check(drift[0] < 15.0 and drift[1], "N0 host: after letting go, %s moved %.0fpx more (still inside the map: %s)" % [names[1], drift[0], drift[1]])
	for id in main.players.keys():
		if id == 1:
			continue
		var r := await _net_read("n0_%d.json" % id, 20.0)
		check(r.get("drift", 9999.0) < 15.0 and r.get("inside", false), "N0: after letting go, %s moved %.0fpx more on its own screen (inside the map: %s)" % [names[id], r.get("drift", 9999.0), str(r.get("inside"))])

## Both sides of N0: hold the movement keys toward N0_TOWARD for 3s — every
## frame, this peer's own player must not be carried AWAY from where it's
## steering or off the map — then release and measure how far it keeps going.
const N0_SPOT := Vector2(1800, 565)
const N0_TOWARD := Vector2(1636, 360)
var n0_backwards := 0.0 # px moved against the held direction, summed

func _n0_walk_then_stop() -> Array:
	var heading := (N0_TOWARD - N0_SPOT).normalized()
	steer(heading)
	var prev: Vector2 = player().global_position
	var inside := true
	for i in 180:
		await physics_frame
		var q: Vector2 = player().global_position
		n0_backwards += maxf(0.0, -(q - prev).dot(heading))
		prev = q
		if q.x < 0.0 or q.y < 0.0 or q.x > main.WORLD_WIDTH or q.y > main.WORLD_HEIGHT:
			inside = false
	steer(Vector2.ZERO)
	await wait(0.5)
	var at: Vector2 = player().global_position
	for i in 180:
		await physics_frame
		var q: Vector2 = player().global_position
		if q.x < 0.0 or q.y < 0.0 or q.x > main.WORLD_WIDTH or q.y > main.WORLD_HEIGHT:
			inside = false
	return [player().global_position.distance_to(at), inside and n0_backwards < 40.0]

func _run_net_orders_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 20.0)
	me = main.multiplayer.get_unique_id()
	act = root.get_node("Settings").local_prefix()
	var who: String = main.player_display_name(me)
	await wait_until(func(): return main.shift_active and main.current_day == 5, 20.0)
	check(main.current_day == 5, "%s: Day 5 (replicated)" % who)
	# N0 (see the host side).
	var go := await _net_read("n0_go.json", 40.0)
	check(go.get("go", false), "%s: N0 started" % who)
	var drift: Array = await _n0_walk_then_stop()
	_net_write("n0_%d.json" % me, {"drift": drift[0], "inside": drift[1]})
	check(drift[0] < 15.0 and drift[1], "%s: N0 after letting go I moved %.0fpx more (inside the map: %s)" % [who, drift[0], drift[1]])
	_watch_orders_view()
	# --- N1: the order arrives by replication; banner up on MY screen.
	var got := await wait_until(func(): return main.order_section == "Dry Goods", 30.0)
	await wait(0.1)
	check(got and main._order_label.visible and main._order_label.text.begins_with("MANAGER: Stock ") and "in Dry Goods!" in main._order_label.text, "%s: order banner on my screen: '%s'" % [who, main._order_label.text])
	var needed: int = main.order_needed
	var mine: Array = await _contribute_to_order()
	_net_write("placed_%d.json" % me, {"items": mine[0], "pressed": mine[1]})
	check(mine[0].size() >= 1, "%s: stocked %d item(s) toward the order: %s" % [who, mine[0].size(), str(mine[0])])
	var closed := await wait_until(func(): return main.order_section == "", 60.0)
	await wait(0.2)
	check(closed and _net_view["results"] == ["FILLED"], "%s: saw the FILLED result on my banner: %s" % [who, str(_net_view["results"])])
	check(needed == PER_PLAYER * main.players.size(), "%s: order size %d == %d players x %d" % [who, needed, main.players.size(), PER_PLAYER])
	# --- N2: my replicated counters match the host's.
	var n2 := await _net_read("phase_n2.json", 60.0)
	await wait(0.5)
	check(main.priority_sales_today == n2.get("priority_sales_today", -1), "%s: bonus sales %d == host's %s" % [who, main.priority_sales_today, str(n2.get("priority_sales_today"))])
	check(main.orders_filled_today == n2.get("orders_filled_today", -1) and main.orders_called_today == n2.get("orders_called_today", -1), "%s: orders filled/called %d/%d == host's" % [who, main.orders_filled_today, main.orders_called_today])
	check(main._pay_today() == n2.get("pay_today", -99999), "%s: pay today %s == host's %s" % [who, main._format_money(main._pay_today()), str(n2.get("pay_today"))])
	check(n2.get("tagged", []).all(func(n): return not main.products_root.has_node(NodePath(n))), "%s: the host's tagged items are the ones gone from my world (sold)" % who)
	# --- N3: free play, then the report.
	_net_view = {"orders": [], "results": [], "open_frames": 0, "banner_frames": 0, "text_bad": 0}
	await _play_shift()
	steer(Vector2.ZERO)
	await wait_until(func(): return main.is_day_report_active(), 10.0)
	await wait(1.5)
	_net_watch = false
	var n3 := await _net_read("phase_n3.json", 60.0)
	var hv: Dictionary = n3.get("view", {})
	print("NET  %s view: %s" % [who, str(_net_view)])
	check(_net_view["banner_frames"] == _net_view["open_frames"] and _net_view["open_frames"] > 0 and _net_view["text_bad"] == 0, "%s: banner up for every open-order frame on my screen (%d/%d), text matched the replicated counters" % [who, _net_view["banner_frames"], _net_view["open_frames"]])
	# (Through JSON, so the host's quantities come back as floats: compare as
	# [section, int] pairs — a 3 vs 3.0 string mismatch used to fail this.)
	var host_orders: Array = hv.get("orders", []).map(func(o): return [o[0], int(o[1])])
	var my_orders: Array = _net_view["orders"].map(func(o): return [o[0], int(o[1])])
	check(my_orders == host_orders, "%s: same free-play orders as the host: %s vs %s" % [who, str(my_orders), str(host_orders)])
	check(str(_net_view["results"]) == str(hv.get("results")), "%s: same FILLED/missed results as the host: %s vs %s" % [who, str(_net_view["results"]), str(hv.get("results"))])
	check(main.report_order_label.text == n3.get("orders", "") and main.report_pay_label.text == n3.get("pay", "") and main.report_today_label.text == n3.get("today", ""), "%s: report matches the host's: '%s' | '%s'" % [who, main.report_order_label.text, main.report_pay_label.text])
	_net_write("result_%d.json" % me, {"fails": fails})
	finish()

## ---------------------------------------------------------------------------
## WEEK 11 (DAY 6) — THE ENVIRONMENTAL TWIST: flickering lights + floor spills
## (Ambience.gd). Scripted checks, solo:
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=5 --shift-seconds=400 --test=ambience
## (add --shots under xvfb-run, no --headless, for frames of a spill and a
## brownout). Co-op pass, 2-4 real players over ENet — see _run_net_ambience_host().

func amb() -> Node2D:
	return main.ambience

## Clears loose stock off a strip of floor so a movement measurement there
## isn't disturbed by bumping into products.
func clear_strip(y: float, x0: float, x1: float) -> void:
	for obj in get_nodes_in_group("carryable"):
		var q: Vector2 = obj.global_position
		if q.x > x0 - 60.0 and q.x < x1 + 60.0 and absf(q.y - y) < 70.0 and obj.get_node("Carryable").carrier_id == 0 and not _is_placed(obj):
			move_body(obj, Vector2(q.x, 200.0 if q.y < 810.0 else q.y + 200.0))

func park_everything() -> void:
	# WEEK 17: the hazards under test only run once the store is open — open
	# it (customers held) rather than holding the prep phase.
	main.test_hold_customers = true
	main.open_store(0)
	fk()._pause_timer = 1.0e9
	pin_manager(Vector2(480, 1350), 0.0)
	main._order_timer = 1.0e9
	amb()._lights_timer = 1.0e9
	amb()._spill_timer = 1.0e9

## Walks this peer's own player right along y from x0, through a spill
## centered at (cx, y) of radius r, and measures what the spill did to it:
## dry speed, top speed inside, the sideways slide when turning inside, the
## coast after letting go, and that it always got through. Positions are this
## peer's own (movement is client-authoritative), so the numbers are exact.
func slip_run(x0: float, y: float, cx: float, r: float, turn := Vector2.DOWN) -> Dictionary:
	var p := player()
	var m := {"dwell": 0.0, "dry_speed": 0.0, "in_speed_max": 0.0, "turn_slide": 0.0, "coast": 0.0, "through": false, "recovered": false, "dry_turn_slide": 0.0}
	var dt := 1.0 / 60.0
	# 1) Dry-floor turn for reference: walking right, then press down only.
	p.teleport_to(Vector2(x0, y))
	await wait(0.3)
	steer(Vector2.RIGHT)
	for i in 20:
		await physics_frame
	var x_before: float = p.global_position.x
	steer(turn)
	for i in 12:
		await physics_frame
	m["dry_turn_slide"] = p.global_position.x - x_before
	steer(Vector2.ZERO)
	await wait(0.2)
	p.teleport_to(Vector2(x0, y))
	await wait(0.3)
	# 2) Through the spill, turning down for 0.2s at its center.
	steer(Vector2.RIGHT)
	var prev: Vector2 = p.global_position
	var dry := []
	var t := 0.0
	var turned := false
	var inside_t := 0.0
	var dwell_from := -1.0 # first pass through the spill, on this peer's own clock
	while t < 5.0:
		await physics_frame
		t += dt
		var q: Vector2 = p.global_position
		var v := (q.x - prev.x) / dt
		prev = q
		var inside := q.distance_to(Vector2(cx, y)) < r
		inside_t = inside_t + dt if inside else 0.0
		if inside and dwell_from < 0.0:
			dwell_from = t
		elif not inside and dwell_from >= 0.0 and m["dwell"] == 0.0:
			m["dwell"] = t - dwell_from
		if q.x < cx - r - 30.0 and t > 0.25:
			dry.append(v)
		# Entering at full speed you skid in (low traction both ways): the cap
		# is measured once the entry skid has had time to bleed off.
		if inside_t > 0.2:
			m["in_speed_max"] = maxf(m["in_speed_max"], absf(v))
		if not turned and q.x >= cx - 4.0:
			turned = true
			var xb: float = q.x
			steer(turn)
			for i in 12:
				await physics_frame
			m["turn_slide"] = p.global_position.x - xb
			steer(-turn) # back onto the line
			for i in 12:
				await physics_frame
			steer(Vector2.RIGHT)
			prev = p.global_position
			t += 24 * dt
			inside_t += 24 * dt # the whole turn happened inside it
		if q.x > cx + r + 40.0:
			m["through"] = true
			break
	# 3) Off the spill: low traction wears off within SPILL_SLIDE_OUT.
	await wait(amb().SPILL_SLIDE_OUT + 0.15)
	await physics_frame
	var a0: Vector2 = p.global_position
	await physics_frame
	m["recovered"] = not p.is_slipping() and absf((p.global_position.x - a0.x) / dt - p.SPEED) < 3.0
	m["recovered_v"] = (p.global_position.x - a0.x) / dt
	steer(Vector2.ZERO)
	m["dry_speed"] = dry.reduce(func(acc, v): return acc + v, 0.0) / maxf(1.0, dry.size())
	# 4) Coast: walk back in, let go at the center, see how far it carries.
	p.teleport_to(Vector2(cx - r - 60.0, y))
	await wait(0.2)
	steer(Vector2.RIGHT)
	await wait_until(func(): return p.global_position.x >= cx - 10.0, 3.0)
	steer(Vector2.ZERO)
	var let_go: Vector2 = p.global_position
	await wait(0.8)
	m["coast"] = p.global_position.x - let_go.x
	return m

func _run_ambience() -> void:
	await wait_until(func(): return main.shift_active and main.current_day == 5, 20.0)
	var a := amb()
	# --- A0: nothing before Day 6, even with both timers run out.
	check(not a.active, "A0 Day 5: lights/spills inactive")
	a._lights_timer = 0.0
	a._spill_timer = 0.0
	await wait(1.0)
	check(a.spills.is_empty() and a.lights_event_id == 0 and a.brightness == 1.0 and a._overlay.color.a == 0.0 and not a.slippery_at(player().global_position), "A0 Day 5: no spill, lights normal, overlay clear (timers expired anyway)")
	main.shift_time_left = 0.05
	await wait_until(func(): return main.is_day_report_active(), 5.0)
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and main.current_day == 6, 10.0)
	check(a.active and a.spills.is_empty() and a.lights_event_id == 0 and a.brightness == 1.0, "A1 Day 6: active, starts clean (no spills, lights normal)")
	check(is_equal_approx(a._lights_timer, a.LIGHTS_FIRST_DELAY) and is_equal_approx(a._spill_timer, a.SPILL_FIRST_DELAY), "A1 Day 6: first lights event in %.0fs, first spill in %.0fs" % [a._lights_timer, a._spill_timer])
	park_everything()
	player().teleport_to(Vector2(1440, 240)) # in Dry Goods' spawn band: spills must keep clear of me
	await wait(0.5)

	# --- A2: where spills may form. 400 picks against every rule.
	var bad := []
	var none := 0
	var cells := {}
	var fk_cell: Vector2i = main._grid_cell_of(fk().home_position)
	for i in 400:
		var pos = a.pick_spill_spot()
		if pos == null:
			none += 1
			continue
		var cell: Vector2i = main._grid_cell_of(pos)
		cells[cell] = cells.get(cell, 0) + 1
		var why := ""
		if not main.is_unlocked_at_pos(pos):
			why = "locked/non-section cell"
		elif pos.distance_to(player().global_position) < a.SPILL_CLEAR_PLAYER:
			why = "on the player"
		elif cell == fk_cell and absf(pos.y - fk().home_position.y) < a.SPILL_RADIUS_MAX + a.SPILL_CLEAR_FORKLIFT_LANE:
			why = "forklift lane"
		else:
			for sb in main.shelves:
				for slot in sb.get_node("Shelf").slots:
					if pos.distance_to(slot.global_position) < a.SPILL_RADIUS_MAX + a.SPILL_CLEAR_SLOT:
						why = "in front of a slot"
		if why != "":
			bad.append([pos, why])
	print("AMB  400 spill picks: per cell %s, %d rounds found no spot" % [str(cells), none])
	check(bad.is_empty(), "A2: every spill spot is an unlocked aisle, clear of the player, the forklift lane and slots (bad: %s)" % str(bad.slice(0, 5)))
	check(cells.size() == 3 and none < 40, "A2: spills land in all 3 open sections (%s), rarely no spot (%d/400)" % [str(cells), none])

	# --- A3: forming = harmless telegraph; then wet = slide, not a wall.
	var y := 455.0
	clear_strip(y, 1150.0, 1750.0)
	var cx := 1450.0
	var r := 48.0
	player().teleport_to(Vector2(cx - r - 110.0, y))
	await wait(0.3)
	var id: int = a.spawn_spill(Vector2(cx, y), r)
	await physics_frame
	check(a.spills.size() == 1 and a.spills[0]["phase"] == a.PHASE_FORMING and not a.slippery_at(Vector2(cx, y)), "A3: a new spill starts FORMING — not slippery yet")
	await wait(0.2)
	var node: Node2D = a._spill_nodes.get(id)
	check(node != null and node.get_parent() == a._spill_root and node.get_node("Sign").z_index > a._overlay.z_index, "A3: spill drawn on the floor layer, its WET FLOOR sign above the darkness")
	check(a._spill_root.get_index() == main.get_node("RoomBackgrounds").get_index() + 1, "A3: spills draw right after the room floors (under shelves/stock/people)")
	# Walk into it while it's still forming: full speed.
	steer(Vector2.RIGHT)
	var fast := 0.0
	var prev: Vector2 = player().global_position
	for i in 50:
		await physics_frame
		var q: Vector2 = player().global_position
		if q.distance_to(Vector2(cx, y)) < r:
			fast = maxf(fast, (q.x - prev.x) * 60.0)
		prev = q
	steer(Vector2.ZERO)
	check(fast > 210.0 and not player().is_slipping(), "A3: crossing a FORMING spill doesn't slow you (%.0f px/s)" % fast)
	await shot("amb_spill_forming")
	await wait_until(func(): return a.spills[0]["phase"] == a.PHASE_WET, 3.0)
	check(a.slippery_at(Vector2(cx, y)) and not a.slippery_at(Vector2(cx + r + 5.0, y)), "A3: after %.1fs it's WET — slippery inside its radius only" % a.SPILL_FORM_TIME)
	var m: Dictionary = await slip_run(cx - r - 260.0, y, cx, r)
	print("AMB  slip run: %s" % str(m))
	var top: float = player().SPEED * a.SPILL_SPEED_FACTOR
	check(absf(m["dry_speed"] - player().SPEED) < 3.0, "A3: dry floor: %.0f px/s (normal %.0f)" % [m["dry_speed"], player().SPEED])
	check(m["in_speed_max"] <= top + 3.0 and m["in_speed_max"] > 100.0, "A3: on the spill: top speed %.0f px/s (cap %.0f) — slower, not stuck" % [m["in_speed_max"], top])
	check(absf(m["dry_turn_slide"]) < 1.0 and m["turn_slide"] > 12.0, "A3: turning on the spill slides you %.0fpx on (dry floor: %.0fpx)" % [m["turn_slide"], m["dry_turn_slide"]])
	check(m["coast"] > 8.0 and m["coast"] < 60.0, "A3: letting go on the spill coasts %.0fpx, then stops" % m["coast"])
	check(m["through"], "A3: walked all the way through — a spill never blocks")
	check(m["recovered"], "A3: full control back within %.1fs of stepping off" % a.SPILL_SLIDE_OUT)
	await shot("amb_spill_wet")

	# --- A4: the manager excuses a slide into stock, not a deliberate throw.
	var obj = await stock_one("Dry Goods")
	check(obj != null, "A4: stocked an item to test against")
	if obj != null:
		var st: Dictionary = mgr()._player_state(1)
		player().teleport_to(Vector2(cx + 20.0, y))
		await wait(0.2)
		st["last_chaos"] = -INF
		mgr().note_push(1, obj)
		check(st["last_chaos"] == -INF, "A4: bumping shelved stock while ON a spill isn't chaos")
		player().teleport_to(Vector2(cx + r + 40.0, y))
		await wait(0.2)
		mgr().note_push(1, obj)
		check(st["last_chaos"] == -INF, "A4: ...nor just sliding off one (within %.0fpx)" % a.SPILL_EXCUSE_MARGIN)
		player().teleport_to(Vector2(cx - r - 200.0, y))
		await wait(0.2)
		mgr().note_push(1, obj)
		check(st["last_chaos"] > -INF, "A4: the same bump on dry floor IS chaos")
		st["last_chaos"] = -INF
		player().teleport_to(Vector2(cx, y))
		await wait(0.2)
		mgr().note_chaos(1, "throwing stock")
		check(st["last_chaos"] > -INF, "A4: a throw while on a spill still counts")
		st["last_chaos"] = -INF

	# --- A5: drying (still slippery, faded), then gone everywhere.
	player().teleport_to(Vector2(cx - r - 200.0, y))
	a._spill_age[id] = a.SPILL_FORM_TIME + a.SPILL_WET_TIME - 0.05
	await wait(0.3)
	check(a.spills[0]["phase"] == a.PHASE_DRYING and a.slippery_at(Vector2(cx, y)) and a._spill_nodes[id].modulate.a < 0.9, "A5: DRYING — faded, still slippery")
	a._spill_age[id] = a.SPILL_FORM_TIME + a.SPILL_WET_TIME + a.SPILL_DRY_TIME - 0.05
	await wait(0.3)
	check(a.spills.is_empty() and not a.slippery_at(Vector2(cx, y)) and not a._spill_nodes.has(id) and a._spill_root.get_child_count() == 0, "A5: dried up — gone from the list and the floor")

	# --- A6: cap.
	for i in 12:
		a._spill_timer = 0.0
		await physics_frame
	check(a.spills.size() <= a.spill_cap() and a.spills.size() >= 2, "A6: spawning every frame for 12 frames: %d on the floor (cap %d solo)" % [a.spills.size(), a.spill_cap()])
	for s in a.spills.duplicate():
		a.remove_spill(s["id"])
	await physics_frame
	check(a.spills.is_empty(), "A6: remove_spill() (the future mop hook) clears them")
	a._spill_timer = 1.0e9

	# --- A7: a lights event, frame by frame.
	var pat_a: Array = a.build_pattern(12345)
	check(str(pat_a) == str(a.build_pattern(12345)) and str(pat_a) != str(a.build_pattern(54321)), "A7: the flicker pattern is a pure function of its seed")
	var fk_on: bool = fk().active
	player().teleport_to(Vector2(2400, 640)) # Meat/Deli, forklift and manager in view
	pin_manager(Vector2(2250, 660), 0.0)
	await wait(0.4)
	a.start_lights_event()
	await physics_frame
	var len: float = a.build_pattern(a.lights_event_seed)[-1][0]
	var min_b := 1.0
	var dim_s := 0.0
	var dark_run := 0.0
	var dark_run_max := 0.0
	var overlay_ok := true
	var vig_max := 0.0
	var shot_taken := false
	var t := 0.0
	while t < len + 1.0:
		await process_frame
		var b: float = a.brightness
		var dtp := get_root().get_process_delta_time()
		t += dtp
		min_b = minf(min_b, b)
		if is_equal_approx(b, a.LIGHTS_DIM_LEVEL):
			dim_s += dtp
		if b < a.LIGHTS_DIM_LEVEL - 0.01:
			dark_run += dtp
			dark_run_max = maxf(dark_run_max, dark_run)
		else:
			dark_run = 0.0
		if not is_equal_approx(a._overlay.color.a, 1.0 - b):
			overlay_ok = false
		vig_max = maxf(vig_max, a._vignette.modulate.a)
		if shots and not shot_taken and dim_s > 1.0:
			shot_taken = true
			mgr().watch_peer = 1
			mgr().watch_level = 0.6
			await shot("amb_brownout_meatdeli")
	print("AMB  lights event: %.1fs, min brightness %.2f, dim for %.1fs, longest dip below dim %.2fs, vignette max %.2f" % [len, min_b, dim_s, dark_run_max, vig_max])
	check(min_b >= a.LIGHTS_FLICKER_LOW - 0.001, "A7: never darker than %.2f brightness (min %.2f)" % [a.LIGHTS_FLICKER_LOW, min_b])
	check(dim_s >= a.LIGHTS_DIM_MIN - 1.2, "A7: a real brownout hold: %.1fs at %.2f" % [dim_s, a.LIGHTS_DIM_LEVEL])
	check(dark_run_max <= 0.2, "A7: anything darker than the brownout lasts a split second at most (%.2fs)" % dark_run_max)
	check(overlay_ok and vig_max <= a.VIGNETTE_STRENGTH + 0.001 and vig_max > 0.3, "A7: overlay tracks brightness every frame; vignette up to %.2f" % vig_max)
	check(a.brightness == 1.0 and a._overlay.color.a == 0.0 and not a._vignette.visible and not a.event_playing(), "A7: lights fully back after %.1fs" % len)
	var z_dark: int = a._overlay.z_index
	var tells := [fk().get_node("Beacon"), fk().get_node("BeepAnchor"), mgr().get_node("AlertLabel"), mgr().get_node("Facing/Cone"), mgr().get_node("NameLabel")]
	for sb in main.shelves:
		tells.append(sb.get_node("Shelf").slots[0].get_node("Prompt"))
	check(tells.all(func(n): return n.z_index > z_dark), "A7: every hazard tell (beacon, BEEP, manager ?/!, cone, name, C prompts) draws above the darkness")
	check(main._watch_label.get_parent() is CanvasLayer and main._order_label.get_parent() is CanvasLayer and main.debug_label.get_parent() is CanvasLayer and main.status_label.get_parent() is CanvasLayer, "A7: HUD / LOOK BUSY / order banner are screen-space (never darkened)")
	check(fk().active == fk_on and mgr().active, "A7: forklift and manager unaffected")

	# --- A8: the day ends mid-event with spills down; next day starts clean.
	player().teleport_to(Vector2(1440, 240))
	await wait(0.3)
	a.spawn_spill(Vector2(1300, 455), 45.0)
	a.spawn_spill(Vector2(1600, 455), 45.0)
	a.start_lights_event()
	await wait(2.5)
	check(a.brightness < 1.0, "A8: mid-event (brightness %.2f)" % a.brightness)
	main.shift_time_left = 0.05
	await wait_until(func(): return main.is_day_report_active(), 5.0)
	await wait(0.1)
	check(a.brightness == 1.0 and a._overlay.color.a == 0.0 and a.lights_event_id == 0, "A8: end-of-day report: lights back on")
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and main.current_day == 7, 10.0)
	await wait(0.2)
	check(a.active and a.spills.is_empty() and a._spill_root.get_child_count() == 0 and a.brightness == 1.0, "A8: Day 7 starts with no spills, lights on, still active")
	finish()

## ---------------------------------------------------------------------------
## WEEK 11 (DAY 6) — CO-OP PASS. Standing practice from this week on: every
## new hazard gets a real multiplayer bot pass, not just the solo one (last
## week's player-drag bug only existed over the network). Host + N-1 clients
## over ENet, every peer driving its own player through its real keyboard
## actions, coordinating through files (NET_DIR) like net-orders:
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=6 --players=3 --test=net-ambience &
##   (x2) godot --headless --path . --script res://tools/hazards_test.gd -- --client --test=net-ambience
## - E1: each player walks through its own spill. Every peer measures ITS OWN
##   player (client-authoritative movement — this is where the slip actually
##   runs): dry speed, capped speed on the spill, the slide on a turn, the
##   coast, always gets through, control back after. The host also measures
##   every remote player's replicated copy: the others SEE you slow down.
##   And each client's replicated spill matches the host's (id, spot, size).
## - E2: every player in the SAME spill at once, spreading out, then all
##   walking the same way — last week's drag bug, re-checked on the new
##   momentum-carrying movement: nobody pushed backwards, nobody runs away.
## - E3: one lights event: every peer plays the identical flicker pattern,
##   starting within a fraction of a second of the host, back to full after.
## - E4: free play, everything live (spills and lights on their own cadence,
##   customers, forklift, manager, orders): every peer saw the same spills
##   and lights events as the host; no write-up for a push while slipping;
##   everyone's report matches.
## - E5: the next day starts clean on every peer.
## WEEK 12 — the same pass runs on the Day 7 finale (--day=7 on the host;
## clients follow the replicated day), plus, on either day:
## - E0: every peer agrees whether it's the finale, and on Day 7 every
##   client saw the FINAL SHIFT banner on its own screen.
## - E6: spills spawned as fast as possible — every peer sees exactly the
##   cap (Day 7: +1, plus +1 per extra player), never one more.
## - E7: a CLIENT stands idle in front of the manager: the time from its own
##   LOOK BUSY warning to its own write-up toast matches today's fuse
##   (2.5s, 2.0s on the finale) — the shorter fuse holds over the network.

## One lane per player across the hub; spills staggered in x so neighbouring
## lanes' spills never touch (and turns go UP, away from the registers).
const E_LANE_YS := [600.0, 680.0, 760.0, 840.0]
const E_LANE_CXS := [1350.0, 1600.0, 1350.0, 1600.0]
const E_LANE_R := 48.0
const E2_SPOT := Vector2(1440, 690)
const E2_R := 54.0

## WEEK 13 — what this peer draws for each product: its sprite region (or
## "placeholder" for sections with no product art). Must match on every peer.
func _product_art_view() -> Dictionary:
	var out := {}
	for obj in get_nodes_in_group("carryable"):
		var art: Node = obj.get_node_or_null("ProductArt")
		out[String(obj.name)] = str(art.region_rect) if art else "placeholder"
	return out

## WEEK 13 #2 — every faced (stocked) slot on this peer: which product art
## its facings show. Taken with the world frozen (end-of-day report).
func _facings_view() -> Dictionary:
	var out := {}
	for entry in main.get_node("StoreArt")._faced_slots:
		var facings: Node2D = entry[3]
		if facings.visible:
			out["%s/%s" % [entry[0].get_parent().get_path(), entry[2].name]] = facings.get_meta("key", "")
	return out

func _lane_for(lanes: Dictionary, id: int) -> Dictionary:
	return lanes.get(str(id), {})

func _spill_matches(sid: int, pos: Vector2, r: float, phase: int) -> bool:
	for s in amb().spills:
		if int(s["id"]) == sid:
			return s["pos"].distance_to(pos) < 0.01 and absf(s["r"] - r) < 0.01 and int(s["phase"]) == phase
	return false

## Host-side: the replicated copy of each REMOTE player, sampled every
## physics frame while E1 runs.
var _remote_samples := {} # peer id -> [[t, Vector2], ...]
var _remote_watch := false

func _watch_remote_players() -> void:
	_remote_watch = true
	var t := 0.0
	while _remote_watch:
		await physics_frame
		t += 1.0 / 60.0
		for id in main.players:
			if id == me:
				continue
			if not _remote_samples.has(id):
				_remote_samples[id] = []
			_remote_samples[id].append([t, main.players[id].target_position])

## From the host's samples of one remote player's replicated copy: [time it
## spent inside the spill on its first pass, its speed over a 200px stretch
## of dry lane on the approach]. Both are long spans on purpose: replication
## packets arrive in bunches, which makes short-window speeds meaningless,
## but bunching can't invent time spent inside the spill.
func _remote_speeds(samples: Array, cx: float, y: float, r: float) -> Array:
	var x0 := cx - r - 260.0
	var dry := 0.0
	var t_a := -1.0
	var i := 0
	while i < samples.size():
		var q: Vector2 = samples[i][1]
		if i > 0 and q.distance_to(samples[i - 1][1]) > 40.0:
			t_a = -1.0 # a teleport: start over
		if absf(q.y - y) < 3.0:
			if t_a < 0.0 and q.x >= x0 + 30.0 and q.x < x0 + 60.0:
				t_a = samples[i][0]
			elif t_a >= 0.0 and q.x >= x0 + 230.0:
				dry = 200.0 / (samples[i][0] - t_a)
				break
		i += 1
	var dwell := 0.0
	var t_in := -1.0
	while i < samples.size():
		var inside: bool = samples[i][1].distance_to(Vector2(cx, y)) < r
		if inside and t_in < 0.0:
			t_in = samples[i][0]
		elif not inside and t_in >= 0.0:
			dwell = samples[i][0] - t_in
			break
		i += 1
	return [dwell, dry]

func _e1_ok(m: Dictionary) -> String:
	var sp: float = player().SPEED
	var top: float = sp * amb().SPILL_SPEED_FACTOR
	var bad := []
	if absf(m.get("dry_speed", 0.0) - sp) > 3.0: bad.append("dry speed")
	if m.get("in_speed_max", 999.0) > top + 3.0 or m.get("in_speed_max", 0.0) < 100.0: bad.append("spill speed")
	if m.get("turn_slide", 0.0) < 12.0 or absf(m.get("dry_turn_slide", 99.0)) > 1.0: bad.append("slide")
	if m.get("coast", 0.0) < 8.0 or m.get("coast", 99.0) > 60.0: bad.append("coast")
	if not m.get("through", false): bad.append("blocked")
	if not m.get("recovered", false): bad.append("recovery")
	return ", ".join(bad)

## Both sides of E2. Everyone starts on the same spot in one spill; part 1:
## each walks out its own way for 0.3s and lets go (still on the spill — the
## coast); part 2: back to the spot, everyone holds the same heading for 1.5s
## (out of the spill, like N0), lets go.
func _e2_peer(k: int) -> Dictionary:
	var p := player()
	var res := {"backwards": 0.0, "coast": 0.0, "coast_settled": true, "drift": 0.0, "inside": true}
	for part in 2:
		p.teleport_to(E2_SPOT)
		await wait(1.0)
		var heading := Vector2.RIGHT.rotated(k * TAU / 4.0 + 0.3) if part == 0 else (N0_TOWARD - N0_SPOT).normalized()
		steer(heading)
		var prev: Vector2 = p.global_position
		for i in (18 if part == 0 else 90):
			await physics_frame
			var q: Vector2 = p.global_position
			res["backwards"] += maxf(0.0, -(q - prev).dot(heading))
			prev = q
		steer(Vector2.ZERO)
		var at: Vector2 = p.global_position
		await wait(0.8)
		var settled: Vector2 = p.global_position
		await wait(0.5)
		var q2: Vector2 = p.global_position
		if q2.x < 0.0 or q2.y < 0.0 or q2.x > main.WORLD_WIDTH or q2.y > main.WORLD_HEIGHT:
			res["inside"] = false
		if part == 0:
			res["coast"] = settled.distance_to(at)
			res["coast_settled"] = q2.distance_to(settled) < 1.0
		else:
			res["drift"] = q2.distance_to(at)
	return res

func _e2_ok(r: Dictionary) -> bool:
	return r.get("backwards", 99.0) < 10.0 and r.get("coast", 99.0) < 45.0 and r.get("coast_settled", false) and r.get("drift", 99.0) < 15.0 and r.get("inside", false)

var _e3_result = null

func _e3_bg(timeout: float) -> void:
	_e3_result = await _e3_watch(timeout)

## Every peer, E3: waits for the next lights event and records it.
func _e3_watch(timeout: float) -> Dictionary:
	var a := amb()
	var start_id: int = a.lights_event_id
	var ok := await wait_until(func(): return a.lights_event_id != start_id and a.lights_event_id != 0, timeout)
	if not ok:
		return {}
	# OCT 2026 PHASE 2 — HARNESS RACE FIX: when a frame runs two physics steps
	# (a loaded machine), the id change is seen in the second and process_frame
	# fires before this frame's Ambience._process has built the pattern —
	# _pattern was still [] and _pattern[-1] errored. Wait until it's built.
	await wait_until(func(): return a._played_event_id == a.lights_event_id and not a._pattern.is_empty(), 2.0)
	await process_frame
	var out := {"start": Time.get_unix_time_from_system(), "id": a.lights_event_id, "pattern": JSON.stringify(a._pattern), "min": 1.0, "overlay_ok": true, "back": false}
	var len: float = a._pattern[-1][0]
	var t := 0.0
	while t < len + 1.0:
		await process_frame
		t += get_root().get_process_delta_time()
		out["min"] = minf(out["min"], a.brightness)
		if not is_equal_approx(a._overlay.color.a, 1.0 - a.brightness):
			out["overlay_ok"] = false
	out["back"] = a.brightness == 1.0 and a._overlay.color.a == 0.0
	out["len"] = len
	return out

## Every peer, E4: which spills and lights events it saw, its own slip time,
## and (host) any write-up that landed while that player was on a spill.
var _env_view := {"spills": {}, "lights": [], "slip_s": 0.0, "inside": true, "slip_writeups": []}
var _env_watch := false

func _watch_env_view() -> void:
	_env_watch = true
	var prev_w: int = main.writeups_today
	while _env_watch:
		await physics_frame
		for s in amb().spills:
			var key := str(int(s["id"]))
			if not _env_view["spills"].has(key):
				_env_view["spills"][key] = [roundi(s["pos"].x), roundi(s["pos"].y), roundi(s["r"])]
		var lid: int = amb().lights_event_id
		if lid != 0 and not (lid in _env_view["lights"]):
			_env_view["lights"].append(lid)
		if player().is_slipping():
			_env_view["slip_s"] += 1.0 / 60.0
		var q: Vector2 = player().global_position
		if q.x < 0.0 or q.y < 0.0 or q.x > main.WORLD_WIDTH or q.y > main.WORLD_HEIGHT:
			_env_view["inside"] = false
		if main.multiplayer.is_server() and main.writeups_today > prev_w:
			prev_w = main.writeups_today
			for id in main.players:
				var st: Dictionary = mgr()._player_state(id)
				if mgr().watch_peer == 0 and amb().slippery_at(main.players[id].global_position, amb().SPILL_EXCUSE_MARGIN) and "knocking" in String(st["reason"]):
					_env_view["slip_writeups"].append([id, st["reason"]])

## Entry by entry: a view that went through JSON has its keys re-sorted as
## strings ("10" before "9") and its numbers as floats.
func _same_spills(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in b:
		if not a.has(k) or a[k].size() != b[k].size():
			return false
		for i in b[k].size():
			if absf(float(a[k][i]) - float(b[k][i])) > 0.5:
				return false
	return true

func _run_net_ambience_host() -> void:
	var want := 2
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--players="):
			want = int(a.substr(10))
	var d := DirAccess.open("user://")
	if d and d.dir_exists("net_orders"):
		for f in DirAccess.get_files_at(NET_DIR):
			DirAccess.remove_absolute(NET_DIR + f)
	await wait_until(func(): return main.shift_active and main.players.size() >= want, 40.0)
	var names := {}
	for id in main.players:
		names[id] = main.player_display_name(id)
	check(main.players.size() == want, "net: %d players connected (%s)" % [main.players.size(), str(names.values())])
	var day: int = main.current_day
	check(day >= 6 and amb().active, "net: Day %d, lights/spills active" % day)
	check(main.is_finale() == (day >= 7) and fk().finale == main.is_finale() and mgr().finale == main.is_finale() and amb().finale == main.is_finale(), "E0 host: top tier %s on every system" % ("ON" if main.is_finale() else "off"))
	park_everything()
	await wait(2.0)
	var ids: Array = main.players.keys()
	ids.sort()

	# --- E1
	var lanes := {}
	var e1_dwell := {}
	for k in ids.size():
		var y: float = E_LANE_YS[k]
		var cx: float = E_LANE_CXS[k]
		clear_strip(y, cx - E_LANE_R - 300.0, cx + E_LANE_R + 200.0)
		var sid: int = amb().spawn_spill(Vector2(cx, y), E_LANE_R)
		lanes[str(ids[k])] = {"y": y, "cx": cx, "id": sid}
		main.players[ids[k]].rpc("teleport_to", Vector2(cx - E_LANE_R - 260.0, y))
	await wait(amb().SPILL_FORM_TIME + 0.4)
	_net_write("e1_go.json", {"lanes": lanes})
	_watch_remote_players()
	var mcx: float = lanes[str(me)]["cx"]
	var mine: Dictionary = await slip_run(mcx - E_LANE_R - 260.0, lanes[str(me)]["y"], mcx, E_LANE_R, Vector2.UP)
	var why := _e1_ok(mine)
	check(why == "", "E1 host: my own slip run %s%s" % [str(mine), "" if why == "" else " — BAD: " + why])
	for id in ids:
		if id == 1:
			continue
		var r := await _net_read("e1_%d.json" % id, 60.0)
		var m: Dictionary = r.get("m", {})
		var w := _e1_ok(m)
		check(w == "" and not m.is_empty(), "E1: %s's own slip run on its own screen %s%s" % [names[id], str(m), "" if w == "" else " — BAD: " + w])
		check(r.get("spill_ok", false), "E1: %s's replicated spill matched the host's (id, spot, size, WET)" % names[id])
		var mine_art := _product_art_view()
		var theirs: Dictionary = r.get("art", {})
		var shared := theirs.keys().filter(func(n): return mine_art.has(n))
		var art_bad := shared.filter(func(n): return mine_art[n] != theirs[n])
		check(shared.size() >= 20 and art_bad.is_empty(), "E1: %s draws the same product art as the host for all %d shared products (mismatches: %s)" % [names[id], shared.size(), str(art_bad.slice(0, 5))])
		e1_dwell[id] = m.get("dwell", -1.0)
	await wait(0.5)
	_remote_watch = false
	for id in ids:
		if id == 1:
			continue
		var y: float = lanes[str(id)]["y"]
		var rs := _remote_speeds(_remote_samples.get(id, []), lanes[str(id)]["cx"], y, E_LANE_R)
		# The client already proved its own slow/slide (above); here the host's
		# copy must show the same pass: same time inside the spill.
		var own: float = e1_dwell.get(id, -1.0)
		print("NET  host's view of %s: %.2fs inside the spill (its own screen: %.2fs), %.0f px/s on dry floor" % [names[id], rs[0], own, rs[1]])
		check(absf(rs[0] - own) < 0.2 and rs[1] > 195.0 and rs[1] < 245.0, "E1: the host SEES %s's pass through the spill as it played: %.2fs inside (its own screen %.2fs), %.0f px/s on dry floor" % [names[id], rs[0], own, rs[1]])
	for id in lanes:
		amb().remove_spill(int(lanes[id]["id"]))

	# --- E2
	var sid2: int = amb().spawn_spill(E2_SPOT, E2_R)
	for id in ids:
		main.players[id].rpc("teleport_to", E2_SPOT)
	await wait(amb().SPILL_FORM_TIME + 0.4)
	_net_write("e2_go.json", {"id": sid2})
	var e2: Dictionary = await _e2_peer(ids.find(me))
	check(_e2_ok(e2), "E2 host: all players in one spill — %s" % str(e2))
	for id in ids:
		if id == 1:
			continue
		var r := await _net_read("e2_%d.json" % id, 40.0)
		check(_e2_ok(r), "E2: %s on its own screen — %s" % [names[id], str(r)])
	amb().remove_spill(sid2)

	# --- E3
	_net_write("e3_go.json", {"go": true})
	await wait(1.5)
	_e3_result = null
	_e3_bg(10.0)
	await physics_frame
	amb().start_lights_event()
	await wait_until(func(): return _e3_result != null, 30.0)
	var e3h: Dictionary = _e3_result if _e3_result != null else {}
	check(not e3h.is_empty() and e3h["back"] and e3h["overlay_ok"] and e3h["min"] >= amb().LIGHTS_FLICKER_LOW - 0.001, "E3 host: event #%s played %.1fs, min %.2f, back to full" % [str(e3h.get("id")), e3h.get("len", 0.0), e3h.get("min", 0.0)])
	for id in ids:
		if id == 1:
			continue
		var r := await _net_read("e3_%d.json" % id, 40.0)
		check(r.get("pattern", "") == e3h.get("pattern", "x") and int(r.get("id", 0)) == int(e3h.get("id", -1)), "E3: %s played the identical flicker pattern (event #%s)" % [names[id], str(r.get("id"))])
		var lag: float = r.get("start", 0.0) - e3h.get("start", 0.0)
		check(absf(lag) < 0.5, "E3: %s's lights went at the same moment as the host's (%+.3fs)" % [names[id], lag])
		check(r.get("back", false) and r.get("overlay_ok", false) and r.get("min", 0.0) >= amb().LIGHTS_FLICKER_LOW - 0.001, "E3: %s: min %.2f, back to full after" % [names[id], r.get("min", 0.0)])

	# --- E6: spill cap under a flood.
	for id in ids:
		main.players[id].rpc("teleport_to", Vector2(480 + 60 * ids.find(id), 300)) # break room: out of every spill spot
	await wait(0.8)
	_net_write("e6_go.json", {"go": true})
	var cap: int = amb().spill_cap()
	var max_seen := 0
	for i in 150:
		amb()._spill_timer = 0.0
		await process_frame
		max_seen = maxi(max_seen, amb().spills.size())
	await wait(1.0)
	var at_cap: int = amb().spills.size()
	_net_write("e6_host.json", {"cap": cap, "count": at_cap})
	var expect_cap: int = amb().SPILL_MAX + (amb().FINALE_SPILL_MAX_BONUS if main.is_finale() else 0) + (want - 1)
	check(cap == expect_cap and at_cap == cap and max_seen == cap, "E6 host: spill flood — %d on the floor, never more than the cap %d (%d players%s)" % [at_cap, cap, want, ", finale +1" if main.is_finale() else ""])
	for id in ids:
		if id == 1:
			continue
		var r := await _net_read("e6_%d.json" % id, 30.0)
		check(int(r.get("max", -1)) == cap and int(r.get("count", -1)) == cap and r.get("drawn", false), "E6: %s saw %s spills at most, %s at the end, all drawn (cap %d)" % [names[id], str(r.get("max")), str(r.get("count")), cap])
	for sp in amb().spills.duplicate():
		amb().remove_spill(sp["id"])
	amb()._spill_timer = 1.0e9

	# --- E7: the manager's fuse, timed on a client's own screen.
	var target: int = ids[1]
	var spot := Vector2(1440, 700)
	main.players[target].rpc("teleport_to", spot)
	await wait(1.0)
	mgr()._state.clear()
	_net_write("e7_go.json", {"target": target})
	await wait(0.5)
	pin_manager(spot + Vector2(150, 0), PI)
	var w0: int = main.writeups_today
	await wait_until(func(): return main.writeups_today > w0, 10.0)
	var r7 := await _net_read("e7_%d.json" % target, 30.0)
	var fuse: float = mgr().catch_time()
	check(main.writeups_by_peer.get(target, 0) >= 1 and absf(r7.get("fuse", -1.0) - fuse) < 0.35, "E7: %s's own LOOK BUSY -> write-up toast took %.2fs on its screen (today's fuse %.1fs)" % [names[target], r7.get("fuse", -1.0), fuse])
	pin_manager(Vector2(480, 1350), 0.0)
	mgr()._state.clear()
	await wait(1.0)

	# --- E4: free play.
	release_manager()
	fk()._pause_timer = 0.0
	main.test_hold_customers = false
	if not main.store_open:
		main.open_store(0)
	main._order_timer = 3.0
	amb()._lights_timer = 4.0
	amb()._spill_timer = 0.5
	main.shift_time_left = 100.0
	_env_view = {"spills": {}, "lights": [], "slip_s": 0.0, "inside": true, "slip_writeups": []}
	_watch_env_view()
	_net_write("e4_go.json", {"go": true})
	await _play_shift()
	steer(Vector2.ZERO)
	await wait_until(func(): return main.is_day_report_active(), 5.0)
	await wait(1.0)
	_env_watch = false
	check(main.is_day_report_active() and amb().brightness == 1.0, "E4 host: report up, lights back on")
	print("NET  host view: spills %s | lights %s | slipping %.1fs | write-ups %d %s" % [str(_env_view["spills"]), str(_env_view["lights"]), _env_view["slip_s"], main.writeups_today, str(main.writeups_by_peer)])
	print("REPORT  %s | %s | %s" % [main.report_today_label.text, main.report_order_label.text, main.report_pay_label.text])
	check(_env_view["spills"].size() >= 3 and _env_view["lights"].size() >= 2, "E4: %d spills and %d lights events in 100s of free play" % [_env_view["spills"].size(), _env_view["lights"].size()])
	check(_env_view["slip_writeups"].is_empty(), "E4: no write-up for a push while on a spill (%s)" % str(_env_view["slip_writeups"]))
	check(_env_view["inside"], "E4 host: stayed on the map")
	var host_facings := _facings_view()
	print("NET  host: %d stocked slots showing facings" % host_facings.size())
	_net_write("e4_host.json", {"view": _env_view, "today": main.report_today_label.text, "pay": main.report_pay_label.text})
	for id in ids:
		if id == 1:
			continue
		var r := await _net_read("e4_%d.json" % id, 60.0)
		var v: Dictionary = r.get("view", {})
		check(_same_spills(v.get("spills", {}), _env_view["spills"]), "E4: %s saw the same spills (id, spot, size): %d vs host %d" % [names[id], v.get("spills", {}).size(), _env_view["spills"].size()])
		# _jnorm: the client's ids come back through JSON as floats (2.0), which
		# Godot 4.7's str() no longer prints as "2" — same ids, not a mismatch.
		check(_jnorm(v.get("lights")) == _jnorm(_env_view["lights"]), "E4: %s saw the same lights events %s" % [names[id], _jnorm(v.get("lights"))])
		check(v.get("inside", false) and r.get("lights_back", false), "E4: %s stayed on the map, lights back on for its report" % names[id])
		check(r.get("today", "") == main.report_today_label.text and r.get("pay", "") == main.report_pay_label.text, "E4: %s's report matches the host's: '%s' | '%s'" % [names[id], r.get("today"), r.get("pay")])
		print("NET  %s: slipping %.1fs" % [names[id], v.get("slip_s", 0.0)])
		var their_facings: Dictionary = r.get("facings", {})
		var fbad := host_facings.keys().filter(func(k): return their_facings.get(k, "") != host_facings[k])
		check(host_facings.size() >= 3 and their_facings.size() == host_facings.size() and fbad.is_empty(), "E4: %s's stocked slots show the same product facings as the host's (%d/%d slots; mismatches %s)" % [names[id], their_facings.size(), host_facings.size(), str(fbad.slice(0, 4))])

	# --- E5
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and main.current_day == day + 1, 10.0)
	await wait(1.0)
	check(amb().spills.is_empty() and amb()._spill_root.get_child_count() == 0 and amb().brightness == 1.0 and amb().active, "E5 host: Day %d starts clean (no spills, lights on)" % (day + 1))
	for id in ids:
		if id == 1:
			continue
		var r := await _net_read("result_%d.json" % id, 60.0)
		check(r.get("fails", -1) == 0, "net: %s's own checks passed (failures: %s)" % [names[id], str(r.get("fails", "no result"))])
	await wait(1.0)
	finish()

var _banner_seen := false
var _banner_text := ""

## Client, from connect: did the start-of-shift banner ever show on this screen.
func _watch_finale_banner() -> void:
	var t := 0.0
	while t < 40.0 and not _banner_seen:
		await process_frame
		t += get_root().get_process_delta_time()
		if main._finale_banner != null and main._finale_banner.visible:
			_banner_seen = true
			_banner_text = main._finale_banner.get_child(0).text

func _run_net_ambience_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 20.0)
	me = main.multiplayer.get_unique_id()
	act = root.get_node("Settings").local_prefix()
	var who: String = main.player_display_name(me)
	_watch_finale_banner()
	await wait_until(func(): return main.shift_active and main.current_day >= 6, 20.0)
	var day: int = main.current_day
	check(day >= 6 and amb().active, "%s: Day %d (replicated), lights/spills active" % [who, day])
	await wait(0.5)
	check(main.is_finale() == (day >= 7) and fk().finale == main.is_finale() and mgr().finale == main.is_finale() and amb().finale == main.is_finale(), "%s: E0 top tier %s on every system, on my side" % [who, "ON" if main.is_finale() else "off"])
	# OCT 2026 PHASE 2: a debug Day 6/7 start announces its newest
	# complication (lights+spills / the top tier) — the banner that replaced
	# the one-time FINAL SHIFT one.
	var want_title: String = main.COMPLICATION_STAGES[main.complication_stage]["title"]
	check(_banner_seen and _banner_text == want_title, "%s: E0 saw the '%s' banner on my own screen ('%s')" % [who, want_title, _banner_text])
	# E1
	var go := await _net_read("e1_go.json", 60.0)
	var lane: Dictionary = _lane_for(go.get("lanes", {}), me)
	check(not lane.is_empty(), "%s: E1 got my lane" % who)
	var y: float = lane.get("y", 600.0)
	var cx: float = lane.get("cx", 1350.0)
	await wait_until(func(): return _spill_matches(int(lane.get("id", -1)), Vector2(cx, y), E_LANE_R, amb().PHASE_WET), 3.0)
	var spill_ok := _spill_matches(int(lane.get("id", -1)), Vector2(cx, y), E_LANE_R, amb().PHASE_WET)
	check(spill_ok and amb()._spill_nodes.size() == amb().spills.size(), "%s: E1 my replicated spill list matches the host's, all drawn (%d)" % [who, amb().spills.size()])
	await wait_until(func(): return player().global_position.distance_to(Vector2(cx - E_LANE_R - 260.0, y)) < 2.0, 3.0)
	var m: Dictionary = await slip_run(cx - E_LANE_R - 260.0, y, cx, E_LANE_R, Vector2.UP)
	_net_write("e1_%d.json" % me, {"m": m, "spill_ok": spill_ok, "art": _product_art_view()})
	var why := _e1_ok(m)
	check(why == "", "%s: E1 my slip run %s%s" % [who, str(m), "" if why == "" else " — BAD: " + why])
	# E2
	var g2 := await _net_read("e2_go.json", 60.0)
	check(g2.has("id"), "%s: E2 started" % who)
	var ids: Array = main.players.keys()
	ids.sort()
	var e2: Dictionary = await _e2_peer(ids.find(me))
	_net_write("e2_%d.json" % me, e2)
	check(_e2_ok(e2), "%s: E2 all in one spill, on my screen — %s" % [who, str(e2)])
	# E3
	await _net_read("e3_go.json", 60.0)
	var e3: Dictionary = await _e3_watch(20.0)
	_net_write("e3_%d.json" % me, e3)
	check(not e3.is_empty() and e3.get("back", false), "%s: E3 saw the lights event and the lights came back" % who)
	# E6
	await _net_read("e6_go.json", 60.0)
	var max_seen := 0
	var t6 := 0.0
	while t6 < 3.0:
		await process_frame
		t6 += get_root().get_process_delta_time()
		max_seen = maxi(max_seen, amb().spills.size())
	var h6 := await _net_read("e6_host.json", 30.0)
	await wait(0.3)
	_net_write("e6_%d.json" % me, {"max": max_seen, "count": amb().spills.size(), "drawn": amb()._spill_nodes.size() == amb().spills.size()})
	check(max_seen == int(h6.get("cap", -1)) and amb().spills.size() == int(h6.get("count", -2)), "%s: E6 spill flood — at most %d on my screen, cap %s" % [who, max_seen, str(h6.get("cap"))])
	# E7 — only the target stands and times it; everyone else is out of the way.
	var g7 := await _net_read("e7_go.json", 60.0)
	if int(g7.get("target", 0)) == me:
		steer(Vector2.ZERO)
		var seen := await wait_until(func(): return main._watch_label.visible, 10.0)
		var t0 := Time.get_ticks_msec()
		var hit := await wait_until(func(): return main._toast_label.visible and main._toast_label.text.begins_with("WRITTEN UP"), 10.0)
		var fuse := (Time.get_ticks_msec() - t0) / 1000.0
		_net_write("e7_%d.json" % me, {"fuse": fuse if seen and hit else -1.0})
		check(seen and hit and absf(fuse - mgr().catch_time()) < 0.35, "%s: E7 LOOK BUSY -> WRITTEN UP on my screen in %.2fs (fuse %.1fs)" % [who, fuse, mgr().catch_time()])
	# E4
	await _net_read("e4_go.json", 60.0)
	_env_view = {"spills": {}, "lights": [], "slip_s": 0.0, "inside": true, "slip_writeups": []}
	_watch_env_view()
	await _play_shift()
	steer(Vector2.ZERO)
	await wait_until(func(): return main.is_day_report_active(), 10.0)
	await wait(1.5)
	_env_watch = false
	print("NET  %s view: spills %s | lights %s | slipping %.1fs" % [who, str(_env_view["spills"]), str(_env_view["lights"]), _env_view["slip_s"]])
	_net_write("e4_%d.json" % me, {"facings": _facings_view(), "view": _env_view, "today": main.report_today_label.text, "pay": main.report_pay_label.text, "lights_back": amb().brightness == 1.0 and amb()._overlay.color.a == 0.0})
	# E5
	await wait_until(func(): return main.shift_active and main.current_day == day + 1, 60.0)
	await wait(1.0)
	check(main.current_day == day + 1 and amb().spills.is_empty() and amb()._spill_root.get_child_count() == 0 and amb().brightness == 1.0, "%s: E5 Day %d starts clean on my screen" % [who, day + 1])
	_net_write("result_%d.json" % me, {"fails": fails})
	finish()

## ---------------------------------------------------------------------------
## WEEK 12 (DAY 7) — THE FINALE: no new hazard, everything escalated, a
## tighter clock and a FINAL SHIFT banner. Scripted checks, solo, starting on
## Day 6 so both sides of the gate are measured in one process:
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=6 --shift-seconds=400 --test=finale
## (add --shots under xvfb-run, no --headless, for frames of the banner with
## every alert row up at once). Co-op: --test=net-ambience with --day=7.

## One lap's worth of forklift legs, built fresh with today's pacing (the
## live lap is put back untouched).
func forklift_lap_pauses() -> Dictionary:
	var saved: Array = fk()._legs.duplicate()
	fk()._legs.clear()
	fk()._build_lap()
	var out := {"stops": [], "telegraph": 0}
	for leg in fk()._legs:
		if leg.has("pause"):
			out["stops"].append(leg["pause"])
		if leg.get("telegraph", false):
			out["telegraph"] += 1
	fk()._legs = saved
	return out

## Real forklift laps for `seconds`: a lap is rebuilt each time the last one
## runs out, so count rebuilds (with nobody in Meat/Deli to get in its way).
func forklift_laps(seconds: float) -> Array:
	fk()._pause_timer = 0.0
	var laps := []
	var prev_n: int = fk()._legs.size()
	var t := 0.0
	var last := -1.0
	var rams0: int = fk().rams_today
	while t < seconds:
		await physics_frame
		t += 1.0 / 60.0
		var n: int = fk()._legs.size()
		if n > prev_n + 3: # a fresh lap was just built
			if last >= 0.0:
				laps.append(t - last)
			last = t
		prev_n = n
	return [laps, fk().rams_today - rams0]

## Seconds from the manager first starting to watch an idle player (the "?"
## appears) to the write-up, measured on the real detection loop.
func time_to_writeup() -> float:
	var spot := Vector2(1440, 700)
	player().teleport_to(spot)
	steer(Vector2.ZERO)
	pin_manager(spot + Vector2(150, 0), PI)
	mgr()._state.clear()
	var w0: int = main.writeups_today
	await wait_until(func(): return mgr().watch_peer == 1 and mgr().watch_level > 0.0, 6.0)
	var t0 := Time.get_ticks_msec()
	await wait_until(func(): return main.writeups_today > w0, 8.0)
	var dt := (Time.get_ticks_msec() - t0) / 1000.0
	pin_manager(Vector2(480, 1350), 0.0)
	mgr()._state.clear()
	return dt

func _alert_rows_rects() -> Array:
	return [main._watch_label.get_global_rect(), main._toast_label.get_global_rect(), main._order_label.get_global_rect()]

func _run_finale() -> void:
	await wait_until(func(): return main.shift_active and main.current_day == 6, 20.0)
	var a := amb()
	var base_shift: float = main.shift_duration
	# --- F0: Day 6 is exactly Week 11's Day 6, and so is every earlier day.
	check(not main.is_finale() and not fk().finale and not mgr().finale and not a.finale, "F0 Day 6: finale off everywhere")
	var day_numbers_ok := true
	var real_day := _econ_snap()
	for d in [1, 2, 3, 4, 5, 6]:
		_as_day(d)
		if main._selling_window() != base_shift or main._priority_order_interval() != maxf(main.PRIORITY_ORDER_INTERVAL, main._priority_order_window() + main.PRIORITY_ORDER_MIN_GAP_AFTER_WINDOW):
			day_numbers_ok = false
	_econ_restore(real_day)
	check(day_numbers_ok, "F0 Days 1-6: full selling window and order cadence are the pre-finale numbers")
	check(main._current_shift_duration() == (main.PREP_CEILING_BASE + 2 * main.PREP_CEILING_PER_SECTION) + base_shift and main._prep_ceiling() == (main.PREP_CEILING_BASE + 2 * main.PREP_CEILING_PER_SECTION), "F0 Day 6: %.0fs clock, %.0fs prep ceiling" % [main._current_shift_duration(), main._prep_ceiling()])
	check(a.spill_cap() == a.SPILL_MAX and main._order_timer <= main._priority_order_interval() and main._order_timer > main._priority_order_interval() - 5.0, "F0 Day 6: spill cap %d, orders every %.0fs" % [a.spill_cap(), main._priority_order_interval()])
	# OCT 2026 PHASE 2: Day 6's start announces stage 4 (lights + spills).
	await wait_until(func(): return main._finale_banner.visible, 1.0)
	check(main._finale_banner.get_child(0).text == main.COMPLICATION_STAGES[main.STAGE_ENVIRONMENT]["title"] and main.stage_banner == main.STAGE_ENVIRONMENT, "F0 Day 6: the banner is lights+spills' ('%s'), not a finale one" % main._finale_banner.get_child(0).text)
	park_everything()
	var lap6 := forklift_lap_pauses()
	var catch6 := await time_to_writeup()
	player().teleport_to(Vector2(1440, 240)) # out of Meat/Deli
	var laps6: Array = await forklift_laps(60.0)
	fk()._pause_timer = 1.0e9
	var spill_iv6 := []
	var light_iv6 := []
	for i in 20:
		a._spill_timer = 0.0
		await process_frame # the host tick runs in Main._process()
		await process_frame
		spill_iv6.append(a._spill_timer)
		a.start_lights_event()
		light_iv6.append(a._lights_timer - a.build_pattern(a.lights_event_seed)[-1][0])
	for sp in a.spills.duplicate():
		a.remove_spill(sp["id"])
	a._spill_timer = 1.0e9
	a._lights_timer = 1.0e9

	# --- F1: into the finale.
	main.shift_time_left = 0.05
	await wait_until(func(): return main.is_day_report_active(), 5.0)
	main._on_continue_pressed()
	var saw_banner_at_start := false
	await wait_until(func(): return main.current_day == 7, 5.0)
	saw_banner_at_start = await wait_until(func(): return main._finale_banner.visible, 1.0)
	var banner_start := Time.get_ticks_msec()
	check(main.shift_active and main.is_finale() and fk().finale and mgr().finale and a.finale, "F1 Day 7: finale on for forklift, manager, spills/lights")
	check(saw_banner_at_start and main._finale_banner.get_child(0).text == "RUSH SEASON", "F1 Day 7: the top tier's RUSH SEASON banner up as the shift starts ('%s')" % main._finale_banner.get_child(0).text)
	check(main._prep_ceiling() == (main.PREP_CEILING_BASE + 3 * main.PREP_CEILING_PER_SECTION) and main._current_shift_duration() == (main.PREP_CEILING_BASE + 3 * main.PREP_CEILING_PER_SECTION) + base_shift - main.FINALE_SELLING_CUT, "F1 Day 7: clock %.0fs = %.0fs prep ceiling + %.0fs selling (finale cut %.0fs)" % [main._current_shift_duration(), main._prep_ceiling(), main._selling_window(), main.FINALE_SELLING_CUT])
	check(main._selling_window() < base_shift, "F1 Day 7: tighter selling window than Day 6 — %.0fs < %.0fs" % [main._selling_window(), base_shift])
	check(main._order_timer > main._priority_order_interval() - 1.0 and main._order_timer <= main._priority_order_interval() and main._priority_order_interval() == maxf(main.FINALE_PRIORITY_ORDER_INTERVAL, main._priority_order_window() + main.PRIORITY_ORDER_MIN_GAP_AFTER_WINDOW), "F1 Day 7: priority orders every %.0fs (first due in %.0fs)" % [main._priority_order_interval(), main._order_timer])
	check(main._priority_order_interval() >= main._priority_order_window() + 5.0, "F1: an order is always closed before the next is due (gap %.0fs >= window %.0fs + 5)" % [main._priority_order_interval(), main._priority_order_window()])
	# Banner vs every alert row, with all of them up at once.
	main._watch_label.text = "MANAGER IS WATCHING — LOOK BUSY!  [|||||.....]"
	main._watch_label.visible = true
	main._toast_label.text = "WRITTEN UP for standing around!  -$25"
	main._toast_timer = 3.0
	main._order_result_timer = 3.0
	main._order_result_text = "ORDER FILLED — those 5 Bakery items pay 1.5x!"
	main._order_result_filled = true
	# Staged: his live detection loop would clear a watch nobody earned.
	mgr().set_physics_process(false)
	mgr().watch_peer = 1
	mgr().watch_level = 0.7
	await process_frame
	await process_frame
	# Screen rects only mean something with a real window: headless runs a
	# 64px-tall viewport. Run this test under xvfb-run for the layout check.
	var br: Rect2 = main._finale_banner.get_global_rect()
	var view: Vector2 = main.get_viewport().get_visible_rect().size
	check(main._finale_banner.visible and main._watch_label.visible and main._toast_label.visible and main._order_label.visible, "F1: banner up together with LOOK BUSY, the write-up toast and the order banner")
	if DisplayServer.get_name() != "headless":
		var clash := _alert_rows_rects().filter(func(r): return r.intersects(br))
		check(clash.is_empty(), "F1: FINAL SHIFT banner %s clear of LOOK BUSY / toast / order rows %s (view %s)" % [str(br), str(_alert_rows_rects()), str(view)])
		check(br.position.y >= 0.0 and br.end.y <= view.y and br.size.y > 40.0, "F1: banner fully on screen")
	else:
		print("FIN  (headless: banner layout checks skipped — run under xvfb-run)")
	await shot("finale_banner_with_every_alert_row")
	mgr().set_physics_process(true)
	mgr().watch_peer = 0
	mgr().watch_level = 0.0
	main._toast_timer = 0.0
	main._order_result_timer = 0.0
	await wait_until(func(): return (Time.get_ticks_msec() - banner_start) / 1000.0 > main.STAGE_BANNER_SECONDS - 0.7, 8.0)
	check(main._finale_banner.visible and main._finale_banner.modulate.a < 1.0, "F1: banner fading in its last second (alpha %.2f)" % main._finale_banner.modulate.a)
	await wait_until(func(): return not main._finale_banner.visible, 3.0)
	var shown_for := (Time.get_ticks_msec() - banner_start) / 1000.0
	check(not main._finale_banner.visible and absf(shown_for - main.STAGE_BANNER_SECONDS) < 0.5, "F1: banner gone after %.1fs" % shown_for)

	# --- F2: each system escalated, measured.
	park_everything()
	var lap7 := forklift_lap_pauses()
	print("FIN  forklift stops per lap: Day 6 %s | Day 7 %s" % [str(lap6["stops"]), str(lap7["stops"])])
	var sum6: float = lap6["stops"].reduce(func(x, y): return x + y, 0.0)
	var sum7: float = lap7["stops"].reduce(func(x, y): return x + y, 0.0)
	check(sum7 < sum6 and lap7["stops"].size() == lap6["stops"].size() and lap7["telegraph"] == lap6["telegraph"] and lap7["telegraph"] == fk().RAMS_PER_LAP, "F2 forklift: %.1fs of stops per lap (Day 6 %.1fs), same %d telegraphed ram(s)" % [sum7, sum6, lap7["telegraph"]])
	check(fk().TELEGRAPH_TIME == 0.9 and fk().DRIVE_SPEED < player().SPEED and fk().RAM_SPEED < player().SPEED, "F2 forklift: telegraph %.1fs and speeds unchanged (still outrunnable)" % fk().TELEGRAPH_TIME)
	player().teleport_to(Vector2(1440, 240))
	var laps7: Array = await forklift_laps(60.0)
	fk()._pause_timer = 1.0e9
	var mean := func(xs: Array) -> float: return xs.reduce(func(x, y): return x + y, 0.0) / maxf(1.0, xs.size())
	print("FIN  forklift in 60s: Day 6 laps %s rams %d | Day 7 laps %s rams %d" % [str(laps6[0]), laps6[1], str(laps7[0]), laps7[1]])
	check(not laps7[0].is_empty() and not laps6[0].is_empty() and mean.call(laps7[0]) < mean.call(laps6[0]), "F2 forklift: a lap every %.1fs (Day 6 %.1fs) — rams in 60s: %d vs %d" % [mean.call(laps7[0]), mean.call(laps6[0]), laps7[1], laps6[1]])
	var catch7 := await time_to_writeup()
	print("FIN  manager: '?' to write-up Day 6 %.2fs, Day 7 %.2fs" % [catch6, catch7])
	check(absf(catch6 - mgr().CATCH_TIME) < 0.25 and absf(catch7 - mgr().FINALE_CATCH_TIME) < 0.25, "F2 manager: '?' to write-up %.2fs (Day 6 %.2fs)" % [catch7, catch6])
	check(mgr().FINALE_CATCH_TIME > mgr().CHAOS_MEMORY, "F2 manager: one throw still can't write you up alone (%.1f > %.1f)" % [mgr().FINALE_CATCH_TIME, mgr().CHAOS_MEMORY])
	var spill_iv7 := []
	var light_iv7 := []
	player().teleport_to(Vector2(480, 270)) # break room: out of every spill spot's way
	await wait(0.3)
	for i in 20:
		a._spill_timer = 0.0
		await process_frame # the host tick runs in Main._process()
		await process_frame
		spill_iv7.append(a._spill_timer)
		a.start_lights_event()
		light_iv7.append(a._lights_timer - a.build_pattern(a.lights_event_seed)[-1][0])
	print("FIN  spill gaps Day 6 %.1f-%.1f, Day 7 %.1f-%.1f | lights gaps Day 6 %.1f-%.1f, Day 7 %.1f-%.1f" % [spill_iv6.min(), spill_iv6.max(), spill_iv7.min(), spill_iv7.max(), light_iv6.min(), light_iv6.max(), light_iv7.min(), light_iv7.max()])
	check(spill_iv6.min() >= a.SPILL_INTERVAL_MIN and spill_iv6.max() <= a.SPILL_INTERVAL_MAX and spill_iv7.min() >= a.FINALE_SPILL_INTERVAL_MIN and spill_iv7.max() <= a.FINALE_SPILL_INTERVAL_MAX, "F2 spills: gaps %.0f-%.0fs (Day 6 %.0f-%.0fs)" % [a.FINALE_SPILL_INTERVAL_MIN, a.FINALE_SPILL_INTERVAL_MAX, a.SPILL_INTERVAL_MIN, a.SPILL_INTERVAL_MAX])
	check(a.spills.size() == a.spill_cap() and a.spill_cap() == a.SPILL_MAX + 1, "F2 spills: cap %d solo (Day 6 %d) — %d on the floor after 20 forced spawns" % [a.spill_cap(), a.SPILL_MAX, a.spills.size()])
	check(light_iv6.min() >= a.LIGHTS_INTERVAL_MIN and light_iv6.max() <= a.LIGHTS_INTERVAL_MAX and light_iv7.min() >= a.FINALE_LIGHTS_INTERVAL_MIN and light_iv7.max() <= a.FINALE_LIGHTS_INTERVAL_MAX, "F2 lights: gaps %.0f-%.0fs (Day 6 %.0f-%.0fs)" % [a.FINALE_LIGHTS_INTERVAL_MIN, a.FINALE_LIGHTS_INTERVAL_MAX, a.LIGHTS_INTERVAL_MIN, a.LIGHTS_INTERVAL_MAX])
	check(str(a.build_pattern(777)) == str(a.build_pattern(777)) and a.LIGHTS_DIM_LEVEL == 0.55, "F2 lights: the event itself (depth, length, pattern) is unchanged")
	for sp in a.spills.duplicate():
		a.remove_spill(sp["id"])

	# --- F3: the banner is once, not every day after. OCT 2026 PHASE 2: and
	# the top tier is SUSTAINED — Day 8 runs, still at the top tier, with no
	# second banner (it used to end the story at WEEK COMPLETE).
	main.shift_time_left = 0.05
	await wait_until(func(): return main.is_day_report_active(), 5.0)
	check(main.continue_button.text == "Continue", "F3: Day 7's report has no 'Finish the Week' ('%s')" % main.continue_button.text)
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and main.current_day == 8, 5.0)
	var again := await wait_until(func(): return main._finale_banner.visible, 1.5)
	check(main.shift_active and main.current_day == 8 and not again and main.get_node_or_null("HubUI") == null, "F3: Day 8 starts — no WEEK COMPLETE, no second banner")
	check(main.is_finale() and fk().finale and mgr().finale and a.finale and main._selling_window() == base_shift - main.FINALE_SELLING_CUT, "F3: Day 8 is still the top tier (sustained), tight clock %.0fs" % main._selling_window())
	finish()

## ---------------------------------------------------------------------------
## WEEK 15 — STORAGE DELIVERIES (Delivery.gd, DeliveryForklift.gd)
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=3 --shift-seconds=600 --test=delivery
## Co-op (host + N-1 clients, each driving its own player by its own keys):
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=3 --shift-seconds=600 --players=3 --test=net-delivery &
##   (x2) godot --headless --path . --script res://tools/hazards_test.gd -- --client --test=net-delivery
## The solo sim (--test=solo) plays the delivery job too: when the loose
## stock runs low and a box is waiting in receiving, it goes and unpacks it.

func dl() -> Node2D:
	return main.delivery

func dfk() -> CharacterBody2D:
	return main.delivery_forklift

func boxes() -> Array:
	return get_nodes_in_group("delivery_box").filter(func(b): return not b.is_queued_for_deletion())

## Floor stock (products, not boxes) — what _restock_products() counts.
func floor_stock() -> Dictionary:
	var out := {}
	for obj in get_nodes_in_group("carryable"):
		if obj.is_in_group("delivery_box") or obj.is_queued_for_deletion():
			continue
		var s: String = main._section_of_color(obj.get_node("Polygon2D").color)
		out[s] = out.get(s, 0) + 1
	return out

func floor_total() -> int:
	var n := 0
	var fs := floor_stock()
	for s in fs:
		n += fs[s]
	return n

## Walks this peer's own player to `goal` through its real move actions,
## routing cell to cell like the solo brain. True if it got there.
func walk_to(goal: Vector2, tol := 10.0, timeout := 20.0) -> bool:
	var p := player()
	var t := 0.0
	var stuck := 0.0
	var last := p.global_position
	var jig := 0.0
	var jig_dir := Vector2.ZERO
	while t < timeout:
		var pos := p.global_position
		if pos.distance_to(goal) <= tol:
			steer(Vector2.ZERO)
			return true
		var wp := waypoint(pos, goal)
		var dir := (wp - pos).normalized()
		if pos.distance_to(goal) < 40.0:
			dir *= 0.5
		if jig > 0.0:
			jig -= 1.0 / 60.0
			dir = jig_dir
		elif pos.distance_to(last) < 0.3:
			stuck += 1.0 / 60.0
			if stuck > 1.0:
				stuck = 0.0
				jig = 0.4
				jig_dir = dir.rotated(PI * 0.5 * (1.0 if randf() < 0.5 else -1.0))
		else:
			stuck = 0.0
		last = pos
		steer(dir)
		await physics_frame
		t += 1.0 / 60.0
	steer(Vector2.ZERO)
	return p.global_position.distance_to(goal) <= tol

## Picks a box up with E and carries it onto the pad, sets it down with E —
## the real keys, the real Carryable round trip. True once it's on the pad.
func haul_box(box: Node2D) -> bool:
	# Come in from the north (the forklift lane side, open floor) and stop
	# short: walking into a box shoves it.
	await walk_to(box.global_position + Vector2(0, -110), 12.0, 25.0)
	await walk_to(box.global_position + Vector2(0, -50), 4.0, 5.0)
	await tap(act + "interact")
	var got := await wait_until(func(): return is_instance_valid(box) and box.get_node("Carryable").carrier_id == me, 1.0)
	if not got:
		return false
	return await carry_box_to_pad(box, box.get_meta("section"))

## Carries the box I'm holding to `pad_section`'s pad (WEEK 18: one per
## section — normally the box's own) and sets it down with E, standing south
## of the pad facing north (the drop point is carry_distance in front). True
## if it was set down on that pad or unpacked.
func carry_box_to_pad(box: Node2D, pad_section: String) -> bool:
	var c: Vector2 = dl().pad_center(pad_section)
	await walk_to(c + Vector2(0, 140), 12.0, 40.0)
	await walk_to(c + Vector2(0, 60), 5.0, 6.0)
	steer(Vector2.UP)
	await physics_frame
	await physics_frame
	steer(Vector2.ZERO)
	await wait(0.15)
	await tap(act + "interact")
	await wait_until(func(): return not is_instance_valid(box) or box.get_node("Carryable").carrier_id != me, 1.0)
	return not is_instance_valid(box) or dl().on_pad(box.global_position, pad_section)

func _run_delivery() -> void:
	await wait_until(func(): return main.shift_active and main.current_day >= 3, 20.0)
	await wait(0.5)
	var d := dl()
	var cap: int = main._product_cap()
	var names: Array = main._unlocked_sections().map(func(s): return s["name"])
	# --- D1 (WEEK 16): the store opens empty and closed — all stock arrives
	# by truck, starting during prep.
	check(floor_total() == 0 and not main.store_open and main.prep_time_left > 200.0, "D1: day opens with no stock on the floor (%d), store closed, %.0fs of prep" % [floor_total(), main.prep_time_left])
	check(boxes().is_empty() and not d.truck_parked(), "D1: no boxes, no truck at opening")
	check(dfk().active and dfk().visible and not dfk().is_in_group("forklift") and main.manager.get_tree().get_first_node_in_group("forklift") == fk(), "D1: delivery forklift live; the manager's 'forklift' is still the Produce one")
	# Quiet store for the mechanics checks.
	main.prep_time_left = 1.0e9
	main._order_timer = 1.0e9
	fk()._pause_timer = 1.0e9
	pin_manager(Vector2(480, 1350), 0.0)

	# --- D2: the truck, on its own schedule.
	var t0 := Time.get_ticks_msec()
	await wait_until(func(): return d.truck_parked(), d.TRUCK_FIRST_DELAY + d.TRUCK_ARRIVE_TIME + 3.0)
	var first_at := (Time.get_ticks_msec() - t0) / 1000.0 + 0.5
	var cargo: Array = d.truck_load.duplicate()
	print("DLV  truck #%d parked %.1fs into the shift with %s" % [d.deliveries_today, first_at, str(cargo)])
	check(d.truck_parked() and absf(first_at - (d.TRUCK_FIRST_DELAY + d.TRUCK_ARRIVE_TIME)) < 1.5, "D2: first truck parked at the dock ~%.0fs in (%.1fs)" % [d.TRUCK_FIRST_DELAY + d.TRUCK_ARRIVE_TIME, first_at])
	check(cargo.size() == d.boxes_per_truck() and names.all(func(n): return n in cargo) and cargo.all(func(c): return c in names), "D2: %d boxes (tier table), every open section at least once, nothing for a locked one: %s" % [d.boxes_per_truck(), str(cargo)])
	var intervals := []
	for i in 40:
		intervals.append(d.truck_interval())
	check(intervals.min() >= d.TRUCK_INTERVAL_MIN and intervals.max() <= d.TRUCK_INTERVAL_MAX, "D2: truck gap rolls within %.0f-%.0fs" % [d.TRUCK_INTERVAL_MIN, d.TRUCK_INTERVAL_MAX])
	d._truck_timer = 1.0e9 # no second truck while the first one's checked

	# --- D3: the forklift unloads every box into receiving, then the truck leaves.
	var t1 := Time.get_ticks_msec()
	if shots:
		player().teleport_to(Vector2(2500, 1140))
		await wait(0.3)
		await shot("d2_truck_at_dock")
		await wait_until(func(): return dfk().carrying != "", 15.0)
		await wait(1.2)
		await shot("d3_forklift_loaded")
		await wait_until(func(): return dfk().rotation > 1.2 and dfk().carrying != "", 10.0)
		await shot("d3_forklift_setting_down")
	await wait_until(func(): return boxes().size() == cargo.size() and dfk().carrying == "", 25.0 * cargo.size())
	var unload_s := (Time.get_ticks_msec() - t1) / 1000.0
	var box_secs := boxes().map(func(b): return b.get_meta("section"))
	box_secs.sort()
	var want := cargo.duplicate()
	want.sort()
	check(box_secs == want, "D3: forklift unloaded all %d boxes in %.1fs (%.1fs each), contents as loaded: %s" % [cargo.size(), unload_s, unload_s / maxf(1, cargo.size()), str(box_secs)])
	check(boxes().all(func(b): return d.RECEIVING_SPOTS.any(func(s): return b.global_position.distance_to(s) < 20.0)), "D3: every box sits on a receiving spot: %s" % str(boxes().map(func(b): return b.global_position.round())))
	await wait_until(func(): return d.truck_offset >= d.TRUCK_AWAY_OFFSET, d.TRUCK_LINGER + d.TRUCK_DEPART_TIME + 2.0)
	check(d.truck_offset >= d.TRUCK_AWAY_OFFSET and not d._truck.visible, "D3: empty truck pulled out and is gone")
	check(dfk().drops_today == cargo.size() and dfk().rams_today == 0, "D3: %d set-downs, no rams" % dfk().drops_today)
	player().teleport_to(Vector2(2450, 1330))
	await wait(0.4)
	await shot("d3_receiving")

	# --- D4: a box can't be shelved.
	var b0: RigidBody2D = boxes()[0]
	var slot: Marker2D = empty_slot_in(names[0])
	if slot == null:
		for s in main.shelves:
			if main._grid_cell_of(s.global_position) == section_by_name(names[0])["grid_pos"]:
				var sh: Node = s.get_node("Shelf")
				var o = sh._occupant[0]
				if o != null:
					move_body(o, o.global_position + Vector2(0, 150).rotated(s.global_rotation))
				await wait(0.3)
				slot = sh.slots[0]
				break
	var home0 := b0.global_position
	move_body(b0, slot.global_position)
	await wait(1.0)
	check(not _is_placed(b0), "D4: a delivery box set on a %s slot never counts as stocked" % names[0])
	move_body(b0, home0)
	await wait(0.3)

	# --- D4b (WEEK 18): carried to ANOTHER section's pad and set down with E,
	# a box stays a box (the pad says "wrong pad"); even left at rest there,
	# it never unpacks. Then picked back up for D5.
	var sec: String = b0.get_meta("section")
	var wrong: String = names.filter(func(n): return n != sec)[0] if names.size() > 1 else ""
	if wrong != "":
		var ev0: int = d.unpack_event_id
		var nu: int = d.boxes_unpacked_today
		await walk_to(b0.global_position + Vector2(0, -110), 12.0, 25.0)
		await walk_to(b0.global_position + Vector2(0, -50), 4.0, 5.0)
		await tap(act + "interact")
		await wait_until(func(): return b0.get_node("Carryable").carrier_id == me, 1.0)
		var on_wrong := await carry_box_to_pad(b0, wrong)
		await wait(d.PAD_SETTLE_TIME + 1.0)
		check(on_wrong and is_instance_valid(b0) and d.pad_at(b0.global_position) == wrong and d.boxes_unpacked_today == nu, "D4b: a %s box set down on the %s pad stays a box (at %s, unpacked today %d)" % [sec, wrong, str(b0.global_position.round()), d.boxes_unpacked_today])
		check(d.unpack_event_id == ev0 + 1 and not d.unpack_event_ok and d.unpack_event_pad == wrong and d._unpack_labels[wrong].visible, "D4b: ...and that pad flashes '%s'" % d.unpack_event_text.replace("\n", " "))
		await shot("d4b_wrong_pad")
		# Pick it back up (from the south: the wall's to the north) and take it
		# on to its own pad — D5.
		await walk_to(b0.global_position + Vector2(0, 50), 4.0, 5.0)
		await tap(act + "interact")
		await wait_until(func(): return b0.get_node("Carryable").carrier_id == me, 1.0)
		check(b0.get_node("Carryable").carrier_id == me, "D4b: picked it back up off the wrong pad")

	# --- D5 (WEEK 16): carry one onto the pad with the real keys: it comes
	# apart into UNITS_PER_BOX loose products of its section, around the pad
	# (not on it) — WEEK 18: its own section's pad, in that section — and
	# nothing else puts stock anywhere.
	var t_haul := Time.get_ticks_msec()
	var before_ids := {}
	for o in get_nodes_in_group("carryable"):
		before_ids[o] = true
	var unpacked0: int = d.boxes_unpacked_today
	var hauled := false
	if b0.get_node("Carryable").carrier_id == me:
		hauled = await carry_box_to_pad(b0, sec) # D4b left it in my hands
	else:
		hauled = await haul_box(b0)
	await wait_until(func(): return d.boxes_unpacked_today > unpacked0, 2.0)
	check(hauled and d.boxes_unpacked_today == unpacked0 + 1 and not is_instance_valid(b0), "D5: %s box carried to the %s pad with E/E (%.1fs) and unpacked (%d today)" % [sec, sec, (Time.get_ticks_msec() - t_haul) / 1000.0, d.boxes_unpacked_today])
	await wait(0.6)
	var spilled := get_nodes_in_group("carryable").filter(func(o): return not before_ids.has(o) and not o.is_in_group("delivery_box"))
	var right_sec: bool = spilled.all(func(o): return main._section_of_color(o.get_node("Polygon2D").color) == sec)
	var pc: Vector2 = d.pad_center(sec)
	var by_pad: bool = spilled.all(func(o): return main._grid_cell_of(o.global_position) == section_by_name(sec)["grid_pos"] and not d.on_pad(o.global_position) and o.global_position.distance_to(pc) < d.SPILL_RING_MAX + 40.0)
	var off_slots: bool = spilled.all(func(o): return not _at_a_slot(o) and not _is_placed(o))
	var calm: bool = spilled.all(func(o): return o.linear_velocity.length() < 60.0)
	print("DLV  unpacked into: %s" % str(spilled.map(func(o): return [o.name, o.global_position.round()])))
	check(spilled.size() == d.UNITS_PER_BOX and right_sec, "D5: %d loose %s products came out of it" % [spilled.size(), sec])
	check(by_pad and calm, "D5: ...lying round the pad, off it, in %s, at rest (none flung)" % sec)
	check(off_slots, "D5: ...none of them landed on a shelf slot (nothing stocks itself)")
	await shot("d5_unpacked")
	# Carry one of them to its shelf by hand (E to pick up, C at the slot).
	var item: RigidBody2D = spilled[0]
	var slot5: Marker2D = empty_slot_in(sec)
	await walk_to(item.global_position + Vector2(0, -40), 5.0, 10.0)
	await tap(act + "interact")
	await wait_until(func(): return get_nodes_in_group("carryable").any(func(o): return o.get_node("Carryable").carrier_id == me), 1.0)
	for o in get_nodes_in_group("carryable"):
		if o.get_node("Carryable").carrier_id == me:
			item = o # E takes the nearest one — follow whichever it was
	var job := pick_slot(player().global_position, item)
	await walk_to(job["pos"] + job["out"] * 80.0, 10.0, 25.0)
	await walk_to(job["pos"] + job["out"] * 29.0, 3.0, 5.0)
	await wait_until(func(): return player()._place_target_slot != null, 1.0)
	await tap(act + "place")
	var shelved := await wait_until(func(): return _is_placed(item), 2.0)
	if not shelved:
		print("D5  missed — item %s at %s carrier %d | player %s | target slot %s | job %s" % [item.name, str(item.global_position.round()), item.get_node("Carryable").carrier_id, str(player().global_position.round()), str(player()._place_target_slot), str(job)])
	check(shelved, "D5: carried one by hand from the pad to a %s shelf and it stocked (%s)" % [sec, str(slot5 != null)])
	# No refill from nothing: sell two, give the old restock cadence time.
	var before := floor_total()
	var sold := 0
	for obj in get_nodes_in_group("carryable"):
		if sold < 2 and not obj.is_in_group("delivery_box"):
			main.cashiers[0].get_node("Cashier")._complete_purchase(obj, -99999)
			sold += 1
	await wait(main.RESTOCK_CHECK_INTERVAL + 1.0)
	check(floor_total() == before - 2, "D5: nothing refills on its own (floor %d -> %d after %.0fs)" % [before, floor_total(), main.RESTOCK_CHECK_INTERVAL + 1.0])

	# --- D6: a box thrown across its own pad doesn't unpack (it has to be set
	# down). Dry Goods' pad: open floor on both sides (every truck carries a
	# Dry Goods box — each open section gets one).
	var dg: Array = boxes().filter(func(b): return b.get_meta("section") == "Dry Goods")
	var b1: RigidBody2D = dg[0] if not dg.is_empty() else boxes()[0]
	var c6: Vector2 = d.pad_center(b1.get_meta("section"))
	var n6: int = d.boxes_unpacked_today
	player().teleport_to(c6 + Vector2(0, 160)) # out of the box's path
	await wait(0.2)
	move_body(b1, c6 + Vector2(-d.PAD_HALF - 40, 0))
	await physics_frame
	PhysicsServer2D.body_set_state(b1.get_rid(), PhysicsServer2D.BODY_STATE_LINEAR_VELOCITY, Vector2(750, 0))
	await wait(1.5)
	var end_x: float = b1.global_position.x if is_instance_valid(b1) else -1.0
	check(end_x > c6.x + d.PAD_HALF and d.boxes_unpacked_today == n6, "D6: a %s box sliding across its pad at speed doesn't unpack (came to rest at x=%.0f, past the pad's edge %.0f)" % [b1.get_meta("section"), end_x, c6.x + d.PAD_HALF])

	# --- D7: stray box rescue: knocked into the break room -> back to receiving.
	if boxes().size() > 0:
		var b2: RigidBody2D = boxes()[0]
		move_body(b2, Vector2(480, 300))
		main._rescue_stranded_products()
		await wait(0.2)
		check(main._grid_cell_of(b2.global_position) == main.STORAGE_GRID_POS, "D7: a box in the break room is sent back to receiving (%s)" % str(b2.global_position.round()))

	# --- D8: the forklift works around a full receiving row and people.
	for b in boxes():
		b.queue_free()
	await physics_frame
	# Occupy every spot but the last with a parked player-sized blocker: a spare product.
	d.truck_load = []
	d._truck_state = d.TRUCK_AWAY
	d.truck_offset = d.TRUCK_AWAY_OFFSET
	await wait(0.2)
	d.start_delivery()
	await wait_until(func(): return d.truck_parked(), 5.0)
	player().teleport_to(d.RECEIVING_SPOTS[0])
	await wait_until(func(): return boxes().size() >= 1, 30.0)
	check(boxes().size() >= 1 and boxes().all(func(b): return b.global_position.distance_to(d.RECEIVING_SPOTS[0]) > 30.0), "D8: the first box went to the next spot, not the one a player is standing on (%s)" % str(boxes().map(func(b): return b.global_position.round())))
	player().teleport_to(Vector2(2100, 1150))

	# --- D9: next day: boxes and truck gone, opening floor back, forklift home.
	await wait(0.5)
	main.shift_time_left = 0.05
	await wait_until(func(): return main.is_day_report_active(), 5.0)
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active, 5.0)
	await wait(0.5)
	check(boxes().is_empty() and d.truck_load.is_empty() and d.truck_offset >= d.TRUCK_AWAY_OFFSET and dfk().carrying == "", "D9: new day: no boxes, no truck, empty forks")
	check(floor_total() == 0 and d.deliveries_today == 0 and d.boxes_unpacked_today == 0 and not main.store_open, "D9: new day opens empty and closed again (floor %d), counters reset" % floor_total())
	check(dfk().global_position.distance_to(dfk().home_position) < 2.0, "D9: delivery forklift back home")
	finish()

## Pad sides for simultaneous hauls to the same pad, one per player, so a
## crew doesn't all queue at one edge: [stand offset from the pad center,
## facing to drop]. WEEK 18: the section pads have a wall (or the top shelves'
## slot rows) to the north, so three sides — south, west, east.
const PAD_SIDES := [[Vector2(0, 58), Vector2.UP], [Vector2(-58, 0), Vector2.RIGHT], [Vector2(58, 0), Vector2.LEFT]]

func haul_box_side(box: Node2D, side: int) -> bool:
	await walk_to(box.global_position + Vector2(0, -110), 12.0, 25.0)
	await walk_to(box.global_position + Vector2(0, -50), 4.0, 5.0)
	await tap(act + "interact")
	var got := await wait_until(func(): return is_instance_valid(box) and box.get_node("Carryable").carrier_id == me, 1.5)
	if not got:
		return false
	var off: Vector2 = PAD_SIDES[side][0]
	var face: Vector2 = PAD_SIDES[side][1]
	# Round the pad rather than walk across it (and shove a box someone else
	# just set down there off it): every pad is reached from the south (the
	# aisle), then round to this side.
	var sec: String = box.get_meta("section")
	var c: Vector2 = dl().pad_center(sec)
	await walk_to(c + Vector2(off.x * 2.2, 140), 14.0, 45.0)
	await walk_to(c + off * 2.2 if off.x != 0.0 else c + Vector2(0, 110), 12.0, 10.0)
	await walk_to(c + off, 5.0, 8.0)
	steer(face)
	await physics_frame
	await physics_frame
	steer(Vector2.ZERO)
	await wait(0.25) # a client's drop happens at the host's copy of it: let it catch up
	await tap(act + "interact")
	await wait_until(func(): return not is_instance_valid(box) or box.get_node("Carryable").carrier_id != me, 1.5)
	await wait(0.2)
	# Set down on the pad (or already unpacked) — not fumbled somewhere else.
	return not is_instance_valid(box) or (box.get_node("Carryable").carrier_id == 0 and dl().on_pad(box.global_position, sec))

## WEEK 18: which pad side each player takes for its assigned box — players
## whose boxes go to the same section's pad spread over its sides.
func _pad_sides_for(assign: Dictionary, ids: Array) -> Dictionary:
	var out := {}
	var used := {}
	for id in ids:
		var b = main.products_root.get_node_or_null(NodePath(assign[str(id)]))
		var sec: String = b.get_meta("section") if b else ""
		out[str(id)] = used.get(sec, 0) % PAD_SIDES.size()
		used[sec] = used.get(sec, 0) + 1
	return out

func _box_view() -> Dictionary:
	var out := {}
	for b in boxes():
		out[String(b.name)] = [b.get_meta("section"), b.global_position.x, b.global_position.y, b.get_node("SectionTag").color.to_html()]
	return out

func _run_net_delivery_host() -> void:
	var want := 2
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--players="):
			want = int(a.substr(10))
	var dd := DirAccess.open("user://")
	if dd and dd.dir_exists("net_orders"):
		for f in DirAccess.get_files_at(NET_DIR):
			DirAccess.remove_absolute(NET_DIR + f)
	await wait_until(func(): return main.shift_active and main.players.size() >= want, 40.0)
	var d := dl()
	var names := {}
	for id in main.players:
		names[id] = main.player_display_name(id)
	check(main.players.size() == want, "net: %d players connected (%s)" % [main.players.size(), str(names.values())])
	var ids: Array = main.players.keys()
	ids.sort()
	# Quiet store; the first truck held back until everyone's here.
	main.prep_time_left = 1.0e9
	main._order_timer = 1.0e9
	fk()._pause_timer = 1.0e9
	pin_manager(Vector2(480, 1350), 0.0)
	d._truck_timer = 1.0e9
	for k in ids.size():
		main.players[ids[k]].rpc("teleport_to", Vector2(2040 + 70 * k, 1150))
	await wait(1.0)

	# --- N1: one truck, rolled on the host, the same load on every screen.
	check(d.boxes_per_truck() == d.BOXES_PER_TRUCK_BY_TIER[d._tier()] + d.BOXES_PER_EXTRA_PLAYER * (want - 1), "N1: %d boxes per truck for a crew of %d" % [d.boxes_per_truck(), want])
	d.start_delivery()
	await wait_until(func(): return d.truck_parked(), 5.0)
	var cargo: Array = d.truck_load.duplicate()
	_net_write("n1_go.json", {"load": cargo})
	for id in ids:
		if id == 1:
			continue
		var r := await _net_read("n1_%d.json" % id, 30.0)
		check(r.get("load", []) == cargo and r.get("truck_visible", false), "N1: %s sees the same load on the truck (%s) and the truck at the dock" % [names[id], str(r.get("load", []))])
	await wait_until(func(): return boxes().size() == cargo.size() and dfk().carrying == "", 25.0 * cargo.size())
	check(boxes().size() == cargo.size(), "N1: forklift unloaded all %d boxes" % cargo.size())
	for id in ids:
		if id == 1:
			continue
		var r := await _net_read("n1b_%d.json" % id, 30.0)
		var seen: Array = r.get("forks", [])
		check(seen.size() == cargo.size() and seen.all(func(x): return x in cargo), "N1: %s watched every box ride the forks, labelled: %s" % [names[id], str(seen)])

	# --- N2: the boxes themselves, identical everywhere; then everybody hauls
	# one onto the pad at once, each with their own keys.
	var view := _box_view()
	var assign := {}
	var box_names: Array = view.keys()
	box_names.sort()
	for k in ids.size():
		assign[str(ids[k])] = box_names[k]
	# Forklift parked for the hauls: this part checks the haul itself; its
	# hazard to a client (the knockback — which fumbles a carried box) is N4.
	dfk()._pause_timer = 1.0e9
	var fl0 := floor_total()
	var n0: int = d.boxes_unpacked_today
	var sides := _pad_sides_for(assign, ids)
	_net_write("n2_go.json", {"boxes": view, "assign": assign, "sides": sides})
	var mine: Node2D = main.products_root.get_node(NodePath(assign["1"]))
	var ok := await haul_box_side(mine, sides["1"])
	check(ok, "N2 host: hauled %s (%s) onto the %s pad" % [assign["1"], view[assign["1"]][0], view[assign["1"]][0]])
	for id in ids:
		if id == 1:
			continue
		var r := await _net_read("n2_%d.json" % id, 60.0)
		check(r.get("same", false), "N2: %s's boxes match the host's exactly (names, sections, color tags, spots): %s" % [names[id], r.get("why", "")])
		check(r.get("hauled", false), "N2: %s picked up %s and carried it to the pad with its own keys" % [names[id], assign[str(id)]])
	await wait_until(func(): return d.boxes_unpacked_today >= n0 + want, 5.0)
	var gone: bool = assign.values().all(func(n): return not main.products_root.has_node(NodePath(n)))
	check(d.boxes_unpacked_today == n0 + want and gone, "N2: all %d boxes unpacked on the host (%d today)" % [want, d.boxes_unpacked_today])
	# WEEK 16: each box comes apart into loose stock by the pad — WEEK 18:
	# by its own section's pad, in that section.
	await wait(1.0)
	check(floor_total() - fl0 == want * d.UNITS_PER_BOX, "N2: %d boxes -> %d loose products by their pads" % [want, floor_total() - fl0])
	var loose := {}
	var in_room := true
	var far := []
	for o in get_nodes_in_group("carryable"):
		if not o.is_in_group("delivery_box") and o.get_node("Carryable").carrier_id == 0:
			var osec: String = main._section_of_color(o.get_node("Polygon2D").color)
			loose[String(o.name)] = [o.global_position.x, o.global_position.y, osec]
			if main._grid_cell_of(o.global_position) != section_by_name(osec)["grid_pos"]:
				in_room = false
			var dist: float = o.global_position.distance_to(d.pad_center(osec))
			if dist > d.SPILL_RING_MAX + 40.0:
				far.append("%s %.0fpx" % [osec, dist])
	# (Spilled round the pad; a player walking round it to their side can nudge
	# one further, so the check is the room, and how far any strayed is shown.)
	check(in_room, "N2: every unpacked product is in its own section's room, by its pad (farther than %.0fpx: %s)" % [d.SPILL_RING_MAX + 40.0, str(far)])
	_net_write("n3_go.json", {"loose": loose, "unpacked": d.boxes_unpacked_today})
	for id in ids:
		if id == 1:
			continue
		var r := await _net_read("n3_%d.json" % id, 30.0)
		check(r.get("ok", false), "N3: %s sees the same unpacked stock, same sections, same spots: %s" % [names[id], r.get("why", "")])

	# --- N4: the delivery forklift runs into a client's player: that client
	# gets knocked back on its own screen (movement is client-authoritative).
	if ids.size() > 1:
		var victim: int = ids[1]
		for b in boxes():
			b.queue_free()
		main.players[victim].rpc("teleport_to", Vector2(2560, d.LANE_Y))
		for k in ids.size():
			if ids[k] != victim:
				main.players[ids[k]].rpc("teleport_to", Vector2(2040 + 70 * k, 1150))
		dfk().reset_for_new_day()
		dfk()._pause_timer = 0.3
		await wait(0.5)
		_net_write("n4_go.json", {"victim": victim})
		d.start_delivery()
		var r := await _net_read("n4_%d.json" % victim, 30.0)
		check(r.get("hit", false), "N4: the delivery forklift knocked %s back on their own screen (moved %.0fpx)" % [names[victim], r.get("moved", 0.0)])
	_net_write("done.json", {})
	await wait(1.0)
	finish()

func _run_net_delivery_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 20.0)
	me = main.multiplayer.get_unique_id()
	act = root.get_node("Settings").local_prefix()
	var who: String = main.player_display_name(me)
	var go := await _net_read("n1_go.json", 60.0)
	await wait(0.3)
	var d := dl()
	_net_write("n1_%d.json" % me, {"load": d.truck_load, "truck_visible": d._truck.visible and d.truck_offset < 1.0})
	# Watch the forks on my own screen.
	var forks := []
	var last := ""
	var t := 0.0
	var n_load: int = go.get("load", []).size()
	while t < 25.0 * n_load and forks.size() < n_load:
		await physics_frame
		t += 1.0 / 60.0
		var c: String = dfk().carrying
		if c != last:
			if c != "":
				forks.append(c)
				check(dfk().get_node("LoadArt").visible, "%s: load sprite on the forks for a %s box" % [who, c])
			last = c
	_net_write("n1b_%d.json" % me, {"forks": forks})
	var g2 := await _net_read("n2_go.json", 60.0)
	await wait(0.3)
	var host_view: Dictionary = g2.get("boxes", {})
	var my_view := _box_view()
	var why := ""
	if host_view.keys().size() != my_view.keys().size():
		why = "count %d vs %d" % [my_view.size(), host_view.size()]
	for n in host_view:
		var hv: Array = host_view[n]
		var mv: Array = my_view.get(n, [])
		if mv.is_empty():
			why += " missing %s" % n
		elif mv[0] != hv[0] or mv[3] != hv[3] or Vector2(mv[1], mv[2]).distance_to(Vector2(hv[1], hv[2])) > 12.0:
			why += " %s differs %s vs %s" % [n, str(mv), str(hv)]
	var ids: Array = main.players.keys()
	ids.sort()
	var box_name: String = g2.get("assign", {}).get(str(me), "")
	var box: Node2D = main.products_root.get_node_or_null(NodePath(box_name))
	var hauled := false
	if box:
		hauled = await haul_box_side(box, int(g2.get("sides", {}).get(str(me), 0)))
	_net_write("n2_%d.json" % me, {"same": why == "", "why": why, "hauled": hauled})
	check(why == "" and hauled, "%s: N2 boxes match the host; hauled %s" % [who, box_name])
	var g3 := await _net_read("n3_go.json", 60.0)
	await wait(0.5)
	var hl: Dictionary = g3.get("loose", {})
	var why3 := ""
	for n in hl:
		var o = main.products_root.get_node_or_null(NodePath(n))
		if o == null:
			why3 += " missing %s" % n
			continue
		var hv: Array = hl[n]
		if o.global_position.distance_to(Vector2(hv[0], hv[1])) > 12.0 or main._section_of_color(o.get_node("Polygon2D").color) != hv[2]:
			why3 += " %s at %s vs host %s" % [n, str(o.global_position.round()), str(hv)]
	if d.boxes_unpacked_today != int(g3.get("unpacked", -1)):
		why3 += " unpacked count %d vs %d" % [d.boxes_unpacked_today, int(g3.get("unpacked", -1))]
	var ok3: bool = why3 == "" and hl.size() > 0
	_net_write("n3_%d.json" % me, {"ok": ok3, "why": "%d products%s" % [hl.size(), why3]})
	check(ok3, "%s: N3 the unpacked stock matches the host (%d products)%s" % [who, hl.size(), why3])
	var g4 := await _net_read("n4_go.json", 60.0)
	if int(g4.get("victim", 0)) == me:
		var start := player().global_position
		var hit := await wait_until(func(): return player()._stun_timer > 0.0, 25.0)
		await wait(0.4)
		var moved := player().global_position.distance_to(start)
		_net_write("n4_%d.json" % me, {"hit": hit, "moved": moved})
		check(hit, "%s: N4 knocked back by the delivery forklift on my own screen (%.0fpx)" % [who, moved])
	await _net_read("done.json", 60.0)
	finish()

## WEEK 15 regression (Carryable.gd's client smoothing fix): a box and a
## product pushed on the host, three times — each client copy must come to
## rest where the host's did. Before the fix the client's stopped 60-300px
## short and stayed there.
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=1 --shift-seconds=600 --test=net-boxsync &
##   godot --headless --path . --script res://tools/hazards_test.gd -- --client --test=net-boxsync
func _run_boxsync_host() -> void:
	var dd := DirAccess.open("user://")
	if dd and dd.dir_exists("net_orders"):
		for f in DirAccess.get_files_at(NET_DIR):
			DirAccess.remove_absolute(NET_DIR + f)
	await wait_until(func(): return main.shift_active and main.players.size() >= 2, 40.0)
	main.prep_time_left = 1.0e9
	dl()._truck_timer = 1.0e9
	await wait(1.0)
	dl().drop_box(Vector2(2300, 1330), "Dry Goods")
	main.spawn_product_at("Dry Goods", Vector2(2300, 1200))
	await wait(1.5)
	var b: RigidBody2D = boxes()[0]
	var pr: RigidBody2D = null
	for o in get_nodes_in_group("carryable"):
		if not o.is_in_group("delivery_box") and o.global_position.distance_to(Vector2(2300, 1200)) < 5.0:
			pr = o
	for i in 3:
		var way := -1.0 if i % 2 == 0 else 1.0
		b.get_node("Carryable").request_push(Vector2(300 * way, 0) * b.mass)
		pr.get_node("Carryable").request_push(Vector2(300 * way, 0) * pr.mass)
		await wait(1.5)
		_net_write("bs_%d.json" % i, {"box": [b.global_position.x, b.global_position.y], "prod": [pr.global_position.x, pr.global_position.y], "bn": b.name, "pn": pr.name})
		var r := await _net_read("bsc_%d.json" % i, 20.0)
		var cb: Array = r.get("box", [0, 0])
		var cp: Array = r.get("prod", [0, 0])
		var db := b.global_position.distance_to(Vector2(cb[0], cb[1]))
		var dp := pr.global_position.distance_to(Vector2(cp[0], cp[1]))
		check(db < 10.0 and dp < 10.0, "S%d: after a push, the client's copies came to rest where the host's did (box off by %.1fpx, product by %.1fpx)" % [i, db, dp])
	finish()

func _run_boxsync_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1, 20.0)
	for i in 3:
		var g := await _net_read("bs_%d.json" % i, 40.0)
		await wait(0.3)
		var b: Node2D = main.products_root.get_node_or_null(NodePath(g.get("bn", "")))
		var pr: Node2D = main.products_root.get_node_or_null(NodePath(g.get("pn", "")))
		_net_write("bsc_%d.json" % i, {"box": [b.global_position.x, b.global_position.y] if b else null, "prod": [pr.global_position.x, pr.global_position.y] if pr else null})
	finish()

## ---------------------------------------------------------------------------
## WEEK 16 — THE PREP PHASE + STORE SIGN, and the new wall shelves.
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=5 --test=prep
## Co-op, incl. the sign race (every player presses E at the sign on the same
## instant):
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=1 --players=3 --test=net-prep &
##   (x2) godot --headless --path . --script res://tools/hazards_test.gd -- --client --test=net-prep

func live_customers() -> int:
	return get_nodes_in_group("customer").filter(func(c): return not c.is_queued_for_deletion()).size()

func _run_prep() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 20.0)
	var t_start := Time.get_ticks_msec()
	var clock0: float = main.shift_time_left
	var day: int = main.current_day
	# --- P1: closed, the ceiling, the clock; trucks during prep, no customers.
	check(not main.store_open and absf(main.prep_time_left - main._prep_ceiling()) < 1.0, "P1: Day %d opens CLOSED with %.0fs of prep (ceiling %.0fs)" % [day, main.prep_time_left, main._prep_ceiling()])
	check(is_equal_approx(main._current_shift_duration(), main._prep_ceiling() + main._selling_window()) and absf(clock0 - main._current_shift_duration()) < 1.0, "P1: clock %.0fs = ceiling %.0f + selling %.0f" % [clock0, main._prep_ceiling(), main._selling_window()])
	await wait(0.2)
	check(main._sign_text.text == "CLOSED" and main._prep_label.visible and "PREP" in main._prep_label.text, "P1: sign says CLOSED; banner: '%s'" % main._prep_label.text)
	var got_truck := await wait_until(func(): return dl().deliveries_today >= 1, dl().TRUCK_FIRST_DELAY + 2.0)
	check(got_truck, "P1: a truck is on its way %.0fs into prep" % ((Time.get_ticks_msec() - t_start) / 1000.0))
	var order_t0: float = main._order_timer
	await wait(12.0)
	check(live_customers() == 0 and not main.store_open, "P1: %.0fs into prep (longer than the old grace): no customers (%d), still closed" % [(Time.get_ticks_msec() - t_start) / 1000.0, live_customers()])
	check(main.orders_called_today == 0 and is_equal_approx(main._order_timer, order_t0), "P1: no priority order call-outs while closed (timer held at %.0fs)" % main._order_timer)
	await shot("p1_prep_banner")
	# --- P2: E away from the sign does nothing to the store.
	player().teleport_to(main.STORE_SIGN_POS + Vector2(0, 160))
	await wait(0.3)
	await tap(act + "interact")
	await wait(0.4)
	check(not main.store_open, "P2: E pressed away from the sign: still closed")
	# ...and carrying something at the sign: E sets it down, doesn't open.
	var spot: Vector2 = main.STORE_SIGN_POS + Vector2(40, 140) # well outside the sign's range
	main.spawn_product_at(main._unlocked_sections()[0]["name"], spot)
	await wait(0.4)
	var prod: RigidBody2D = null
	for o in get_nodes_in_group("carryable"):
		if o.global_position.distance_to(spot) < 10.0:
			prod = o
	player().teleport_to(main.STORE_SIGN_POS + Vector2(0, 140))
	await wait(0.3)
	await tap(act + "interact")
	await wait_until(func(): return prod.get_node("Carryable").carrier_id == 1, 1.0)
	await walk_to(main.STORE_SIGN_POS + Vector2(0, 45), 6.0, 5.0)
	await tap(act + "interact")
	await wait(0.4)
	check(not main.store_open and prod.get_node("Carryable").carrier_id == 0, "P2: carrying something at the sign, E sets it down — doesn't open the store")
	# --- P3: flip the sign with the real E key.
	await walk_to(main.STORE_SIGN_POS + Vector2(-30, 45), 6.0, 5.0)
	await wait(0.2)
	check(main._sign_hint.visible, "P3: 'E: open the store' shows when standing at the sign")
	var clock_before: float = main.shift_time_left
	var t_before := Time.get_ticks_msec()
	var prep_left: float = main.prep_time_left
	await tap(act + "interact")
	await wait_until(func(): return main.store_open, 1.0)
	var dt := (Time.get_ticks_msec() - t_before) / 1000.0
	check(main.store_open and main.store_opened_by == 1 and main.store_open_events_today == 1 and main.prep_time_left == 0.0, "P3: sign flipped -> store OPEN, by Host, once")
	check(absf((clock_before - main.shift_time_left) - dt) < 0.3, "P3: the day's clock didn't jump: %.1fs -> %.1fs over %.1fs" % [clock_before, main.shift_time_left, dt])
	print("PREP  opened with %.0fs of ceiling unused -> %.0fs to sell (a full-ceiling day sells %.0fs)" % [prep_left, main.shift_time_left, main._selling_window()])
	check(main.shift_time_left > main._selling_window() + prep_left - 5.0, "P3: the unused %.0fs of prep became selling time: %.0fs to sell (vs %.0fs)" % [prep_left, main.shift_time_left, main._selling_window()])
	await wait(0.2)
	check(main._sign_text.text == "OPEN" and main._prep_label.visible and "STORE OPEN" in main._prep_label.text, "P3: sign says OPEN, banner '%s'" % main._prep_label.text)
	await shot("p3_store_open")
	var came := await wait_until(func(): return live_customers() > 0, 4.0)
	check(came, "P3: customers start arriving right away (%d)" % live_customers())
	if main.hazard_levels()["orders"] > 0:
		var ot: float = main._order_timer
		await wait(1.0)
		check(main._order_timer < ot - 0.5, "P3: priority order call-outs counting now (%.1f -> %.1f)" % [ot, main._order_timer])
	await tap(act + "interact") # again, now open: nothing happens
	await wait(0.3)
	check(main.store_open_events_today == 1, "P3: a second flip does nothing")
	# --- P4: next day, nobody flips it: the ceiling opens it.
	main.shift_time_left = 0.05
	await wait_until(func(): return main.is_day_report_active(), 5.0)
	await wait(0.1)
	check(not main._prep_label.visible, "P4: no prep/open banner over the report")
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and main.current_day == day + 1, 5.0)
	await wait(0.2)
	check(not main.store_open and main.store_opened_by == -1 and absf(main.prep_time_left - main._prep_ceiling()) < 1.0 and live_customers() == 0, "P4: Day %d starts closed again, %.0fs of prep, no customers" % [main.current_day, main.prep_time_left])
	var clock_d: float = main.shift_time_left
	main.prep_time_left = 1.5
	var auto := await wait_until(func(): return main.store_open, 3.0)
	check(auto and main.store_opened_by == 0 and main.store_open_events_today == 1, "P4: ceiling ran out -> store opened by itself")
	check(absf(main.shift_time_left - (clock_d - 1.5)) < 0.6, "P4: clock unaffected by the auto-open (%.1f)" % main.shift_time_left)
	var came2 := await wait_until(func(): return live_customers() > 0, 4.0)
	check(came2, "P4: customers after the auto-open")
	# --- P5: the new wall shelves — every slot stocks, each has the pack art.
	# The Produce forklift's lap picks the new shelf up as a stop of its own
	# (built from the shelves in its cell); parked for the slot checks — a ram
	# wrecks a shelf and it refuses stock for a few seconds.
	var saved: Array = fk()._legs.duplicate()
	fk()._legs.clear()
	fk()._build_lap()
	var built: Array = fk()._legs.map(func(l): return l["pos"])
	# Any stop off the lane at x 2400 — the only shelf at that x is the new one
	# (a near-miss stop just short of its slots, or a ram into it).
	var lane_y: float = fk().home_position.y
	var visits_new: bool = built.any(func(p): return absf(p.x - 2400.0) < 1.0 and absf(p.y - lane_y) > 1.0)
	fk()._legs = saved
	check(visits_new, "P5: the Produce forklift's lap now stops at the new Produce shelf too %s" % ("" if visits_new else str(built)))
	fk()._pause_timer = 1.0e9
	for sb in main.shelves:
		sb.get_node("Shelf").wrecked = false
	main.prep_time_left = 0.0
	var per := {}
	for sb in main.shelves:
		var sec: String = main._section_name_at(sb.global_position)
		per[sec] = per.get(sec, 0) + 1
	print("SHELVES  %s" % str(per))
	check(per.get("Dry Goods") == 6 and per.get("Dairy/Frozen") == 5 and per.get("Bakery") == 5 and per.get("Produce") == 5, "P5: shelves per section %s (was 4 each)" % str(per))
	var bad := []
	var n_new := 0
	for sb in main.shelves:
		if not (String(sb.name) in ["Shelf5", "Shelf6"]):
			continue
		if sb.get_node_or_null("Polygon2D/ShelfArt") == null:
			bad.append("%s no art" % sb.get_path())
		if not main.is_unlocked_at_pos(sb.global_position):
			continue
		n_new += 1
		var shelf: Node = sb.get_node("Shelf")
		var sec: String = main._section_name_at(sb.global_position)
		for i in shelf.slots.size():
			if shelf.filled[i]:
				continue
			var at: Vector2 = shelf.slots[i].global_position
			main.spawn_product_at(sec, at + (at - sb.global_position).normalized() * 120.0)
			await wait(0.3)
			var item: RigidBody2D = null
			var bd := INF
			for o in get_nodes_in_group("carryable"):
				var dd: float = o.global_position.distance_to(at + (at - sb.global_position).normalized() * 120.0)
				if dd < bd:
					bd = dd
					item = o
			move_body(item, at)
			if not await wait_until(func(): return shelf.filled[i], 1.5):
				bad.append("%s slot %d" % [sb.get_path(), i])
	check(n_new > 0 and bad.is_empty(), "P5: all %d new shelves open today stock in every slot, and all 5 have the pack shelf art %s" % [n_new, str(bad)])
	await shot("p5_new_shelves")
	finish()

## --- net-prep ----------------------------------------------------------------
## Spots round the sign, one per player, all within its range.
const SIGN_SPOTS := [Vector2(-40, 45), Vector2(40, 45), Vector2(-55, 0), Vector2(55, 0)]

func _run_net_prep_host() -> void:
	var want := 2
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--players="):
			want = int(a.substr(10))
	var dd := DirAccess.open("user://")
	if dd and dd.dir_exists("net_orders"):
		for f in DirAccess.get_files_at(NET_DIR):
			DirAccess.remove_absolute(NET_DIR + f)
	await wait_until(func(): return main.shift_active and main.players.size() >= want, 40.0)
	var ids: Array = main.players.keys()
	ids.sort()
	check(main.players.size() == want, "net: %d players connected" % main.players.size())
	await wait(1.0)
	# --- NP1: everyone starts closed, with the host's countdown.
	_net_write("np1_go.json", {"prep": main.prep_time_left, "t": Time.get_unix_time_from_system()})
	for id in ids:
		if id == 1:
			continue
		var r := await _net_read("np1_%d.json" % id, 30.0)
		check(r.get("ok", false), "NP1: %s: closed, CLOSED sign, prep banner, no customers, countdown within 1s of the host's %s" % [main.player_display_name(id), r.get("why", "")])
	# --- NP2: a client nowhere near the sign can't open it by sending the RPC.
	_net_write("np2_go.json", {})
	await _net_read("np2_%d.json" % ids[1], 30.0)
	await wait(1.0)
	check(not main.store_open, "NP2: an open request from a player nowhere near the sign is refused")
	# --- NP3: THE RACE — every player at the sign, all press E at the same
	# wall-clock instant, so the requests land together.
	for k in ids.size():
		main.players[ids[k]].rpc("teleport_to", main.STORE_SIGN_POS + SIGN_SPOTS[k])
	await wait(1.5)
	var at := Time.get_unix_time_from_system() + 2.0
	_net_write("np3_go.json", {"at": at})
	while Time.get_unix_time_from_system() < at:
		await process_frame
	await tap(act + "interact")
	await wait(1.5)
	check(main.store_open and main.store_open_events_today == 1, "NP3 race: %d players flipped it together -> opened exactly once (open events %d)" % [want, main.store_open_events_today])
	check(main.store_opened_by in ids, "NP3 race: credited to one of them: %s" % main.player_display_name(main.store_opened_by))
	var came := await wait_until(func(): return live_customers() > 0, 4.0)
	check(came, "NP3: customers started coming")
	_net_write("np3_host.json", {"by": main.store_opened_by, "clock": main.shift_time_left, "t": Time.get_unix_time_from_system()})
	for id in ids:
		if id == 1:
			continue
		var r := await _net_read("np3_%d.json" % id, 30.0)
		check(r.get("ok", false), "NP3: %s: OPEN, same opener, one STORE OPEN banner, clock matches: %s" % [main.player_display_name(id), r.get("why", "")])
	# --- NP4: next day, the ceiling runs out with nobody at the sign.
	main.shift_time_left = 0.05
	await wait_until(func(): return main.is_day_report_active(), 5.0)
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and not main.store_open, 5.0)
	await wait(1.0)
	main.prep_time_left = 2.0
	await wait_until(func(): return main.store_open, 4.0)
	check(main.store_open and main.store_opened_by == 0 and main.store_open_events_today == 1, "NP4: Day %d: ceiling ran out -> opened by itself" % main.current_day)
	_net_write("np4_go.json", {})
	for id in ids:
		if id == 1:
			continue
		var r := await _net_read("np4_%d.json" % id, 30.0)
		check(r.get("ok", false), "NP4: %s saw it open by itself: %s" % [main.player_display_name(id), r.get("why", "")])
	_net_write("done.json", {})
	await wait(1.0)
	finish()

var _np_banners := 0
var _np_shown := false

func _watch_open_banner() -> void:
	while true:
		await process_frame
		var up: bool = main._prep_label.visible and "STORE OPEN" in main._prep_label.text
		if up and not _np_shown:
			_np_banners += 1
		_np_shown = up

func _run_net_prep_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 20.0)
	me = main.multiplayer.get_unique_id()
	act = root.get_node("Settings").local_prefix()
	var who: String = main.player_display_name(me)
	_watch_open_banner()
	var g1 := await _net_read("np1_go.json", 60.0)
	await wait(0.3)
	var lag: float = Time.get_unix_time_from_system() - g1.get("t", 0.0)
	var why := ""
	if main.store_open:
		why += " open?"
	if main._sign_text.text != "CLOSED":
		why += " sign '%s'" % main._sign_text.text
	if not (main._prep_label.visible and "PREP" in main._prep_label.text):
		why += " no banner"
	if absf(main.prep_time_left - (g1.get("prep", 0.0) - lag)) > 1.0:
		why += " countdown %.1f vs host %.1f" % [main.prep_time_left, g1.get("prep", 0.0) - lag]
	if live_customers() != 0:
		why += " customers"
	_net_write("np1_%d.json" % me, {"ok": why == "", "why": why})
	check(why == "", "%s: NP1 closed on my screen%s" % [who, why])
	await _net_read("np2_go.json", 60.0)
	var ids: Array = main.players.keys()
	ids.sort()
	if me == ids[1]:
		# Straight RPC from the break room, bypassing the key: must be refused.
		main.rpc_id(1, "_request_open_store")
		_net_write("np2_%d.json" % me, {})
	var g3 := await _net_read("np3_go.json", 60.0)
	var at: float = g3.get("at", 0.0)
	await wait_until(func(): return player().global_position.distance_to(main.STORE_SIGN_POS) < main.STORE_SIGN_RANGE, 3.0)
	while Time.get_unix_time_from_system() < at:
		await process_frame
	await tap(act + "interact")
	var r3 := await _net_read("np3_host.json", 30.0)
	await wait(0.5)
	var why3 := ""
	if not main.store_open:
		why3 += " still closed"
	if main.store_opened_by != int(r3.get("by", -2)):
		why3 += " opener %d vs %d" % [main.store_opened_by, int(r3.get("by", -2))]
	if main._sign_text.text != "OPEN":
		why3 += " sign '%s'" % main._sign_text.text
	if _np_banners != 1:
		why3 += " %d STORE OPEN banners" % _np_banners
	var lag3: float = Time.get_unix_time_from_system() - r3.get("t", 0.0)
	if absf(main.shift_time_left - (r3.get("clock", 0.0) - lag3)) > 1.0:
		why3 += " clock %.1f vs %.1f" % [main.shift_time_left, r3.get("clock", 0.0) - lag3]
	_net_write("np3_%d.json" % me, {"ok": why3 == "", "why": why3 + " (opener %s)" % main.player_display_name(main.store_opened_by)})
	check(why3 == "", "%s: NP3 race outcome on my screen%s" % [who, why3])
	await _net_read("np4_go.json", 60.0)
	await wait(0.5)
	var why4 := ""
	if not main.store_open or main.store_opened_by != 0:
		why4 += " open=%s by=%d" % [str(main.store_open), main.store_opened_by]
	if _np_banners != 2:
		why4 += " banners %d (want 2)" % _np_banners
	_net_write("np4_%d.json" % me, {"ok": why4 == "", "why": why4})
	check(why4 == "", "%s: NP4 auto-open on my screen%s" % [who, why4])
	await _net_read("done.json", 60.0)
	finish()

## ---------------------------------------------------------------------------
## WEEK 17 — HAZARDS PAUSE THROUGH PREP. The Produce forklift, the manager,
## spills and the lights brownout are all off until the store opens (by the
## sign or the ceiling); deliveries run through prep as before.
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=7 --test=hazard-pause
## Co-op (what each client sees):
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=7 --players=2 --test=net-hazard-pause &
##   godot --headless --path . --script res://tools/hazards_test.gd -- --client --test=net-hazard-pause

## Snapshot of the four hazard systems as this peer sees them.
func _hazard_view() -> Dictionary:
	return {"fk": [fk().global_position.x, fk().global_position.y], "mgr": [mgr().global_position.x, mgr().global_position.y],
		"spills": amb().spills.size(), "lights_id": amb().lights_event_id, "bright": amb().brightness}

## Watches the hazards for `seconds` (this peer's own view): how far the
## forklift and manager moved, most spills seen, any lights event, darkest.
func _watch_hazards(seconds: float) -> Dictionary:
	var fk0: Vector2 = fk().global_position
	var m0: Vector2 = mgr().global_position
	var out := {"fk_moved": 0.0, "mgr_moved": 0.0, "spills": 0, "lights": false, "darkest": 1.0, "watched": false}
	var t := 0.0
	while t < seconds:
		await physics_frame
		t += 1.0 / 60.0
		out["fk_moved"] = maxf(out["fk_moved"], fk().global_position.distance_to(fk0))
		out["mgr_moved"] = maxf(out["mgr_moved"], mgr().global_position.distance_to(m0))
		out["spills"] = maxi(out["spills"], amb().spills.size())
		out["lights"] = out["lights"] or amb().lights_event_id != 0
		out["darkest"] = minf(out["darkest"], amb().brightness)
		out["watched"] = out["watched"] or mgr().watch_peer != 0
	return out

func _run_hazard_pause() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 20.0)
	var day: int = main.current_day
	check(fk().active and mgr().active and amb().lights_enabled() and amb().spills_enabled(), "H0: Day %d: forklift, manager, lights and spills are all on for today" % day)
	main.prep_time_left = 1.0e9 # a long prep
	# Stand idle in the hub in the manager's plain view: during prep that must
	# not get anyone watched or written up.
	player().teleport_to(mgr().global_position + Vector2(-120, 0))
	await wait(0.3)
	var d0: int = dl().deliveries_today
	var dfk0: Vector2 = dfk().global_position
	var h := await _watch_hazards(30.0)
	print("HP  30s of prep: %s" % str(h))
	check(not main.store_open, "H1: still closed after 30s of prep")
	check(h["fk_moved"] < 1.0 and fk().rams_today == 0, "H1: Produce forklift parked all prep (moved %.1fpx, rams %d)" % [h["fk_moved"], fk().rams_today])
	check(h["mgr_moved"] < 1.0 and not h["watched"] and main.writeups_today == 0, "H1: manager still (moved %.1fpx), never watched the idle player, no write-ups" % h["mgr_moved"])
	check(h["spills"] == 0 and not h["lights"] and h["darkest"] == 1.0, "H1: no spills, no lights event, full brightness (%.2f)" % h["darkest"])
	check(dl().deliveries_today > d0 and dfk().global_position.distance_to(dfk0) > 50.0, "H1: deliveries kept running: %d truck(s), delivery forklift moved" % dl().deliveries_today)
	await shot("h1_prep_calm")
	# --- H2: flip the sign (real key) -> everything starts.
	await walk_to(main.STORE_SIGN_POS + Vector2(0, 45), 6.0, 30.0)
	await tap(act + "interact")
	await wait_until(func(): return main.store_open, 1.0)
	check(main.store_open and main.store_opened_by == 1, "H2: sign flipped, store open")
	var h2 := await _watch_hazards(maxf(amb().LIGHTS_FIRST_DELAY, amb().SPILL_FIRST_DELAY) + 8.0)
	print("HP  after the sign: %s" % str(h2))
	check(h2["fk_moved"] > 50.0, "H2: Produce forklift out on its patrol (moved %.0fpx)" % h2["fk_moved"])
	check(h2["mgr_moved"] > 50.0, "H2: manager on his rounds (moved %.0fpx)" % h2["mgr_moved"])
	check(h2["spills"] > 0 and h2["lights"] and h2["darkest"] < 1.0, "H2: spills (%d) and a lights event (darkest %.2f) once open" % [h2["spills"], h2["darkest"]])
	await shot("h2_open_chaos")
	# --- H3: next shift, the ceiling opens it -> same. After Day 7 the next
	# shift is Day 8, the top tier, all four on.
	main.shift_time_left = 0.05
	await wait_until(func(): return main.is_day_report_active(), 5.0)
	await _take_all_hazards_shift()
	await wait_until(func(): return main.shift_active and not main.store_open, 5.0)
	var h3a := await _watch_hazards(12.0)
	check(h3a["fk_moved"] < 1.0 and h3a["mgr_moved"] < 1.0 and h3a["spills"] == 0 and not h3a["lights"], "H3: Day %d prep: all four quiet again %s" % [main.current_day, str(h3a)])
	main.prep_time_left = 1.0
	await wait_until(func(): return main.store_open, 3.0)
	check(main.store_open and main.store_opened_by == 0, "H3: ceiling ran out, store open")
	var h3 := await _watch_hazards(maxf(amb().LIGHTS_FIRST_DELAY, amb().SPILL_FIRST_DELAY) + 8.0)
	check(h3["fk_moved"] > 50.0 and h3["mgr_moved"] > 50.0 and h3["spills"] > 0 and h3["lights"], "H3: after the ceiling's auto-open all four start: %s" % str(h3))
	finish()

## Day 7's report leads to Day 8 — the top tier, every section open and every
## hazard on — which is exactly the shift this wants. (Week 21 went through an
## Endless Mode posting here; that mode was retired in OCT 2026 PHASE 4.)
func _take_all_hazards_shift() -> void:
	main._on_continue_pressed()

func _run_net_hazard_pause_host() -> void:
	var want := 2
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--players="):
			want = int(a.substr(10))
	var dd := DirAccess.open("user://")
	if dd and dd.dir_exists("net_orders"):
		for f in DirAccess.get_files_at(NET_DIR):
			DirAccess.remove_absolute(NET_DIR + f)
	await wait_until(func(): return main.shift_active and main.players.size() >= want, 40.0)
	check(main.players.size() == want, "net: %d players" % want)
	main.prep_time_left = 1.0e9
	var ids: Array = main.players.keys()
	ids.sort()
	# Each client stands idle in the manager's view during prep.
	for k in ids.size():
		main.players[ids[k]].rpc("teleport_to", mgr().global_position + Vector2(-120, -40 + 40 * k))
	await wait(1.0)
	_net_write("nh1_go.json", {})
	var h := await _watch_hazards(25.0)
	check(h["fk_moved"] < 1.0 and h["mgr_moved"] < 1.0 and h["spills"] == 0 and not h["lights"] and not h["watched"] and main.writeups_today == 0, "NH1 host: 25s of prep, all four hazards idle %s" % str(h))
	for id in ids:
		if id == 1:
			continue
		var r := await _net_read("nh1_%d.json" % id, 30.0)
		check(r.get("ok", false), "NH1: %s saw a calm prep on its own screen: %s" % [main.player_display_name(id), r.get("h", {})])
	# A client flips the sign.
	var flipper: int = ids[1]
	main.players[flipper].rpc("teleport_to", main.STORE_SIGN_POS + Vector2(0, 45))
	await wait(0.8)
	_net_write("nh2_go.json", {"flipper": flipper})
	await wait_until(func(): return main.store_open, 8.0)
	check(main.store_open and main.store_opened_by == flipper, "NH2: %s opened the store" % main.player_display_name(flipper))
	var h2 := await _watch_hazards(maxf(amb().LIGHTS_FIRST_DELAY, amb().SPILL_FIRST_DELAY) + 8.0)
	check(h2["fk_moved"] > 50.0 and h2["mgr_moved"] > 50.0 and h2["spills"] > 0 and h2["lights"], "NH2 host: all four started %s" % str(h2))
	for id in ids:
		if id == 1:
			continue
		var r := await _net_read("nh2_%d.json" % id, 60.0)
		check(r.get("ok", false), "NH2: %s saw all four start once open: %s" % [main.player_display_name(id), r.get("h", {})])
	_net_write("done.json", {})
	await wait(1.0)
	finish()

func _run_net_hazard_pause_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 20.0)
	me = main.multiplayer.get_unique_id()
	act = root.get_node("Settings").local_prefix()
	var who: String = main.player_display_name(me)
	await _net_read("nh1_go.json", 60.0)
	var h := await _watch_hazards(20.0)
	var ok: bool = h["fk_moved"] < 2.0 and h["mgr_moved"] < 2.0 and h["spills"] == 0 and not h["lights"] and h["darkest"] == 1.0 and not main._watch_label.visible
	_net_write("nh1_%d.json" % me, {"ok": ok, "h": h})
	check(ok, "%s: NH1 calm prep on my screen %s" % [who, str(h)])
	var g2 := await _net_read("nh2_go.json", 60.0)
	if int(g2.get("flipper", 0)) == me:
		await wait_until(func(): return main.near_store_sign(player().global_position), 3.0)
		await tap(act + "interact")
	await wait_until(func(): return main.store_open, 8.0)
	var h2 := await _watch_hazards(maxf(amb().LIGHTS_FIRST_DELAY, amb().SPILL_FIRST_DELAY) + 8.0)
	var ok2: bool = h2["fk_moved"] > 50.0 and h2["mgr_moved"] > 50.0 and h2["spills"] > 0 and h2["lights"] and h2["darkest"] < 1.0
	_net_write("nh2_%d.json" % me, {"ok": ok2, "h": h2})
	check(ok2, "%s: NH2 all four started on my screen %s" % [who, str(h2)])
	await _net_read("done.json", 60.0)
	finish()

## WEEK 17 — CO-OP SIM: the solo sim's brain on every peer, each driving its
## own player by its own keys, all through the same days (the host runs the
## solo sim's day loop and prints its per-day lines — orders filled/called
## are crew-wide). For tuning the crew-size order window:
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=5 --days=5,6,7 --test=coop-sim &
##   (x N-1) godot --headless --path . --script res://tools/hazards_test.gd -- --client --test=coop-sim
func _run_coop_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 20.0)
	me = main.multiplayer.get_unique_id()
	act = root.get_node("Settings").local_prefix()
	while true:
		await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 1.0e9)
		stats = {"placed": 0, "hits": 0, "watched_s": 0.0, "idle_s": 0.0, "reasons": {}, "wrecks": 0, "overlap": 0, "banner_and_busy_s": 0.0, "banner_clash": 0, "first_customer_s": -1.0, "shift_len": main.shift_time_left, "grace": main.prep_time_left, "slip_s": 0.0}
		await _play_shift()
		# WEEK 19: clients clean too (the host clocks out); sweeps first so the
		# crew splits the jobs.
		if main.cleanup_active:
			await _play_cleanup(true, false)
		await wait_until(func(): return not main.shift_active or main.is_day_report_active(), 10.0)

## ---------------------------------------------------------------------------
## WEEK 18 — BOX CYCLE BENCHMARK: the time to shelve one box, start to finish,
## with nothing else going on. Per open section, TRIALS times: empty shelves,
## no loose stock, one box of that section on a RECEIVING spot, the solo brain
## standing by it; the clock runs from there until all UNITS_PER_BOX of its
## units are on shelves. Store closed (no customers), hazards paused (prep),
## no trucks. Runs against the pre-Week-18 code too (one Storage pad), for the
## pad-move before/after:
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=7 --test=box-cycle
func _run_box_cycle() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 20.0)
	await wait(0.5)
	never_open = true
	main.prep_time_left = 1.0e9
	# The day clock too: the trials outlast Day 7's 816s, and the end-of-day
	# report freezes every player where they stand.
	main.shift_time_left = 1.0e9
	var d := dl()
	d._truck_timer = 1.0e9
	const TRIALS := 3
	var BC_TIMEOUT: float = float(OS.get_environment("BC_TIMEOUT")) if OS.get_environment("BC_TIMEOUT") != "" else 240.0
	var all_t := []
	for sec in (OS.get_environment("BC_SECTIONS").split(",") if OS.get_environment("BC_SECTIONS") != "" else main._unlocked_sections().map(func(x): return x["name"])):
		var times := []
		var walks := []
		var box_legs := []
		for trial in TRIALS:
			main._reset_shelves_and_products_for_new_day()
			box_phase = 0
			recent_drops = {}
			steer(Vector2.ZERO)
			await wait(0.3)
			var spot: Vector2 = d.RECEIVING_SPOTS[3]
			player().teleport_to(spot + Vector2(40, -150))
			d.drop_box(spot, sec)
			await wait(0.3)
			var ev0: int = d.unpack_event_id
			var frames := [0] # game time (the loop steps once per physics frame), so --fixed-fps runs time the same
			var t_unpack := [-1.0]
			var walked := [0.0]
			var last := [player().global_position]
			var done := func() -> bool:
				frames[0] += 1
				var pos: Vector2 = player().global_position
				walked[0] += minf(60.0, pos.distance_to(last[0]))
				last[0] = pos
				if t_unpack[0] < 0.0 and d.unpack_event_id != ev0:
					t_unpack[0] = frames[0] / 60.0
				var placed := get_nodes_in_group("carryable").filter(func(o): return not o.is_in_group("delivery_box") and _is_placed(o)).size()
				if trace and frames[0] % 300 == 0:
					print("BCTRACE t=%.0f me=%s placed=%d loose=%s" % [frames[0] / 60.0, str(player().global_position.round()), placed, str(get_nodes_in_group("carryable").filter(func(o): return not _is_placed(o)).map(func(o): return [o.name, o.global_position.round(), o.get_node("Carryable").carrier_id])) ])
				return placed >= d.UNITS_PER_BOX or frames[0] > BC_TIMEOUT * 60
			await _play_shift(done)
			var secs: float = frames[0] / 60.0
			var ok := secs < BC_TIMEOUT
			if not ok:
				for o in get_nodes_in_group("carryable"):
					if _is_placed(o):
						continue
					for sb in main.shelves:
						var sh: Node = sb.get_node("Shelf")
						for k in sh.slots.size():
							var dd: float = o.global_position.distance_to(sh.slots[k].global_position)
							if dd < 60.0:
								print("BCSTUCK %s at %s: %s slot %d dist %.0f filled=%s occ=%s wrecked=%s vel=%.0f color_ok=%s carrier=%d" % [o.name, str(o.global_position.round()), sb.name, k, dd, str(sh._is_filled(k)), str(sh._occupant[k].name if sh._occupant[k] else null), str(sh.wrecked), o.linear_velocity.length(), str(sh._color_matches(o)), o.get_node("Carryable").carrier_id])
			times.append(secs)
			walks.append(walked[0])
			box_legs.append(t_unpack[0])
			print("BOXCYCLE  %s trial %d: %s in %.1fs (box leg %.1fs, then %.1fs shelving), walked %.0fpx" % [sec, trial + 1, "shelved all %d" % d.UNITS_PER_BOX if ok else "TIMED OUT", secs, t_unpack[0], secs - t_unpack[0], walked[0]])
			check(ok, "BC: %s box shelved within %.0fs" % [sec, BC_TIMEOUT])
		all_t.append_array(times)
		print("BOXCYCLE  %s: %.1fs avg to shelve a box (box leg %.1fs, shelving %.1fs), %.0fpx walked" % [sec, _mean(times), _mean(box_legs), _mean(times) - _mean(box_legs), _mean(walks)])
	print("BOXCYCLE  ALL: %.1fs avg over %d boxes (%s pads)" % [_mean(all_t), all_t.size(), "per-section" if _per_section_pads() else "one Storage"])
	finish()

## WEEK 18 — ROUTE LENGTH to shelve one box, pad-move before/after, measured
## on the routes the sim brain walks (waypoint(): cell to cell through the
## open connections; straight within a cell): RECEIVING -> the pad carrying
## the box, then UNITS_PER_BOX round trips pad -> slot -> pad to the section's
## nearest empty slots (all empty). Deterministic, no physics; the Week 15-17
## Storage pad is its old fixed spot (2090,1330).
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=7 --test=route-len
const OLD_STORAGE_PAD := Vector2(2090.0, 1330.0)

func route_len(a: Vector2, b: Vector2) -> float:
	var total := 0.0
	var pos := a
	for i in 20:
		var nxt := waypoint(pos, b)
		total += pos.distance_to(nxt)
		pos = nxt
		if pos.distance_to(b) < 1.0:
			break
	return total

func _run_route_len() -> void:
	await wait_until(func(): return main.shift_active, 20.0)
	main._reset_shelves_and_products_for_new_day()
	await wait(0.2)
	var start: Vector2 = dl().RECEIVING_SPOTS[3]
	var speed: float = player().SPEED if "SPEED" in player() else 220.0
	var totals := {"old": 0.0, "new": 0.0}
	for sec in main.SECTIONS:
		var name: String = sec["name"]
		var line := "ROUTE  %-13s" % name
		for which in ["old", "new"]:
			var pad: Vector2 = OLD_STORAGE_PAD if which == "old" else dl().pad_center(name)
			var slots := []
			for sb in main.shelves:
				if main._grid_cell_of(sb.global_position) == sec["grid_pos"]:
					for sl in sb.get_node("Shelf").slots:
						slots.append(sl.global_position)
			slots.sort_custom(func(x, y): return route_len(pad, x) < route_len(pad, y))
			var box_leg := route_len(start, pad)
			var items := 0.0
			for k in dl().UNITS_PER_BOX:
				items += route_len(pad, slots[k]) + route_len(slots[k], pad)
			var tot := box_leg + items
			totals[which] += tot
			line += " | %s: box %4.0fpx + 6 units %5.0fpx = %5.0fpx (%.0fs walking)" % [which, box_leg, items, tot, tot / speed]
		print(line)
	print("ROUTE  ALL 4 SECTIONS: old %.0fpx, new %.0fpx (%.0f%% less walking per box)" % [totals["old"], totals["new"], 100.0 * (1.0 - totals["new"] / totals["old"])])
	finish()

## ---------------------------------------------------------------------------
## WEEK 19 — END-OF-SHIFT CLEANUP (Cleanup.gd, Main.gd's start_cleanup() /
## clock_out()). Scripted checks, solo, through the real keys:
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=6 --test=cleanup
## The co-op pass (every peer runs the cleanup brain on its own player, plus
## the tool-grab and clock-out races):
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=6 --players=2 --test=net-cleanup &
##   godot --headless --path . --script res://tools/hazards_test.gd -- --client --test=net-cleanup
## The solo sim (--test=solo) and coop-sim now play each day's cleanup too
## with the same brain, and report it per day.

func cl() -> Node2D:
	return main.cleanup

## Real seconds (the shift clock stands still during cleanup).
func _wall() -> float:
	return Time.get_ticks_msec() / 1000.0

## Every mop-category mess as THIS peer sees it (replicated state only, so
## it works the same on a client): [{"pos", "r"}].
func mop_messes_view() -> Array:
	var out := []
	for s in amb().spills:
		out.append({"pos": s["pos"], "r": float(s["r"])})
	for s in cl().puddles: # OCT 2026 PHASE 3D: sticky drink puddles
		out.append({"pos": s["pos"], "r": float(s["r"])})
	for d in main.displays:
		if d.get_node("Display").toppled:
			out.append({"pos": d.global_position, "r": 24.0})
	for n in cl().knocked_names:
		var o: Node2D = main.products_root.get_node_or_null(NodePath(n))
		if o and o.get_node("Carryable").carrier_id == 0:
			out.append({"pos": o.global_position, "r": 14.0})
	return out

## Where to stand from a mop mess: the head reaches r + MOP_REACH, and a
## display or a stocked item is a body you'd shove if you stood on it.
func mop_stand(m: Dictionary) -> float:
	return cl().MOP_HEAD_OFFSET + 0.6 * float(m["r"]) + 8.0

func _nearest(from: Vector2, items: Array, skip: Array) -> Variant:
	var best = null
	var best_d := INF
	for it in items:
		var pos: Vector2 = it["pos"]
		if skip.any(func(q): return q.distance_to(pos) < 12.0):
			continue
		var d := route_len(from, pos)
		if d < best_d:
			best_d = d
			best = it
	return best

## Stands the player `stand_off` from `target`, facing it, so the tool's
## head (held out along the facing) is on it. False if it couldn't get there.
func face_target(target: Vector2, stand_off: float) -> bool:
	var p := player()
	var dir := (target - p.global_position).normalized()
	if dir == Vector2.ZERO:
		dir = Vector2.RIGHT
	# From our side first; if something's in the way (a shelf end, a parked
	# forklift), from the other sides.
	var reached := false
	for turn in [0.0, PI * 0.5, -PI * 0.5, PI]:
		var d: Vector2 = dir.rotated(turn)
		var stand: Vector2 = target - d * stand_off
		if main._is_out_of_bounds(stand):
			continue
		if await walk_to(stand, 10.0, 8.0):
			reached = true
			break
	if not reached and p.global_position.distance_to(target) > stand_off + 30.0:
		return false
	dir = (target - p.global_position).normalized()
	steer(dir * 0.3)
	await physics_frame
	await physics_frame
	steer(Vector2.ZERO)
	return true

## Gets a tool of `kind` into this player's hands (puts down a wrong one
## first). False if none is free.
func get_tool(kind: String) -> bool:
	var held: int = cl().tool_of(me)
	if held >= 0 and cl().tools[held]["kind"] == kind:
		return true
	if held >= 0:
		await tap(act + "interact")
		await wait_until(func(): return cl().tool_of(me) < 0, 2.0)
	var best := -1
	var best_d := INF
	for i in cl().tools.size():
		var t: Dictionary = cl().tools[i]
		if t["holder"] == 0 and t["kind"] == kind:
			var d := route_len(player().global_position, t["pos"])
			if d < best_d:
				best_d = d
				best = i
	if best < 0:
		return false
	var spot: Vector2 = cl().tools[best]["pos"]
	await walk_to(spot, 4.0, 20.0)
	await tap(act + "interact")
	return await wait_until(func(): return cl().tool_of(me) >= 0 and cl().tools[cl().tool_of(me)]["kind"] == kind, 2.0)

func go_clock_out() -> void:
	var ok := await walk_to(main.TIME_CLOCK_POS + Vector2(0, 40), 12.0, 40.0)
	if not ok:
		print("CLOCK  couldn't reach the time clock: at %s" % str(player().global_position.round()))
	await tap(act + "interact")
	await wait_until(func(): return not main.cleanup_active, 3.0)

## The cleanup brain: a competent crew member (_brain_until_empty() does the
## cleaning), then it clocks out once the floor is clean — or early, when
## the ceiling is about to run out anyway, so it's the brain, not the timer,
## that ends the day. broom_first: sweep before mopping (a crew splits jobs).
func _play_cleanup(broom_first := false, clock_out := true) -> Dictionary:
	var st := await _brain_until_empty(broom_first, true)
	if cl().tool_of(me) >= 0 and main.cleanup_active:
		await tap(act + "interact")
	st["clocked"] = false
	if clock_out and main.cleanup_active:
		await go_clock_out()
		st["clocked"] = not main.cleanup_active and main.clocked_out_by == me
	elif main.cleanup_active:
		await wait_until(func(): return not main.cleanup_active, 200.0)
	return st

## Snapshot of this peer's cleanup view, for comparing peers.
func _cleanup_view() -> Dictionary:
	var holders := []
	for t in cl().tools:
		holders.append(int(t["holder"]))
	return {"active": main.cleanup_active, "litter": cl().litter.size(), "mop_left": cl().mop_left, "mop_total": cl().mop_total, "litter_total": cl().litter_total, "holders": holders, "spills": amb().spills.size(), "customers": live_customers(), "sign": main._sign_text.text}

func _run_cleanup() -> void:
	if shots:
		main.debug_label.visible = false
		main.status_hud = false
	main.shift_duration = 45.0
	main.prep_ceiling_override = 0.0
	await wait_until(func(): return main.shift_active and main.players.has(1) and main.store_open, 20.0)
	var p := player()
	# --- CL1: litter builds up during the selling window; tools stay racked.
	check(cl().tools.size() == cl().MOPS + cl().BROOMS and cl().tools.all(func(t): return t["holder"] == 0), "CL1: %d tools on the station at open" % cl().tools.size())
	await walk_to(cl().TOOL_SPOTS[0], 4.0)
	await tap(act + "interact")
	await wait(0.4)
	# OCT 2026 PHASE 3D: the tools are out all day now (they were cleanup-only).
	check(cl().tool_of(me) >= 0, "CL1: a tool can be taken while the store is open (Phase 3D)")
	await tap(act + "interact") # and put back
	await wait(0.4)
	check(cl().tool_of(me) < 0, "CL1: ...and put back down")
	await wait_until(func(): return cl().litter.size() >= 3, 40.0)
	check(cl().litter.size() >= 3, "CL1: customers dropped litter during the shift: %d on the floor at %.0fs left" % [cl().litter.size(), main.shift_time_left])
	var in_store: bool = cl().litter.all(func(l): return cl()._litter_zone_ok(l["pos"]))
	check(in_store, "CL1: all litter is in the hub or an open section")
	# Known mess for the checks below: a spill, a knocked-over display and a
	# knocked-off stocked item, all in reach of open floor.
	fk()._pause_timer = 1.0e9
	pin_manager(Vector2(480, 1350), 0.0)
	amb()._spill_timer = 1.0e9
	var spill_id: int = amb().spawn_spill(Vector2(1440, 700), 44.0)
	# A second one, so CL2's ">= 3 mop messes at close" doesn't hang on the
	# day's own random spills (one seeded spill + 1 random came up short).
	amb().spawn_spill(Vector2(1700, 760), 40.0)
	# Some sales, so the day has a gross for the bonus to be a share of.
	for i in 3:
		var sold_one: RigidBody2D = await stock_one("Dry Goods")
		if sold_one:
			await sell(sold_one)
	# --- CL2: the clock runs out -> CLEANUP, not the report.
	main.shift_time_left = 0.05
	await wait_until(func(): return main.cleanup_active, 3.0)
	await wait(0.5)
	check(main.cleanup_active and main.shift_active and not main.is_day_report_active(), "CL2: clock ran out -> cleanup phase (no report yet)")
	check(live_customers() == 0, "CL2: customers all left (%d)" % live_customers())
	check(main._sign_text.text == "CLOSED" and main._prep_label.visible and "CLEANUP" in main._prep_label.text, "CL2: sign CLOSED, cleanup banner up: '%s'" % main._prep_label.text)
	check(not main.manager.visible, "CL2: the manager has gone home")
	var fk_pos: Vector2 = fk().global_position
	check(fk_pos.distance_to(fk().home_position) < 2.0, "CL2: the Produce forklift parked at home")
	check(cl().mop_total >= 3 and cl().litter_total >= 3, "CL2: mess snapshot: %d spills & knockovers, %d litter" % [cl().mop_total, cl().litter_total])
	var ceiling: float = main.cleanup_time_left
	var want_ceiling := clampf(main.CLEANUP_CEILING_BASE + main.CLEANUP_CEILING_PER_MESS * cl().mess_count(), main.CLEANUP_CEILING_MIN, main.CLEANUP_CEILING_MAX)
	check(absf(ceiling - want_ceiling) < 1.5, "CL2: cleanup ceiling %.0fs (formula %.0fs for %d mess)" % [ceiling, want_ceiling, cl().mess_count()])
	var age_before: float = amb()._spill_age.get(spill_id, -1.0)
	var trucks: int = dl().deliveries_today
	await wait(3.0)
	check(is_equal_approx(amb()._spill_age.get(spill_id, -2.0), age_before), "CL2: the spill stopped drying at close")
	check(fk().global_position.distance_to(fk_pos) < 2.0, "CL2: the forklift stays parked")
	var disp: RigidBody2D = main.displays[0]
	# Tipped over where it stands (a shove toward the shelves can wedge it
	# somewhere no one could reach it).
	move_body(disp, disp.get_node("Display").home_position + Vector2(20, -10))
	disp.get_node("Display").toppled = true
	# (Planted after close: customers would pick a loose item up or shove it.)
	var prod: RigidBody2D = null
	for sec in ["Dry Goods", "Produce"]:
		var sp: Array = loose_products(sec)
		if not sp.is_empty():
			prod = await stock_one(sec, sp[0])
			if prod:
				break
	if prod == null:
		main.spawn_product_at("Dry Goods", Vector2(1440, 400))
		await wait(0.3)
		prod = await stock_one("Dry Goods")
	check(prod != null and _is_placed(prod), "CL setup: an item stocked on a shelf")
	prod.apply_central_impulse(Vector2(0, 400) * prod.mass)
	await wait_until(func(): return prod.has_meta("knocked"), 2.0)
	check(prod.has_meta("knocked"), "CL setup: knocking it off its slot tags it as mess")
	# Out onto open floor, so it can't slide back into a slot (which would
	# rightly untag it).
	await wait(0.4)
	move_body(prod, Vector2(1300, 420))

	# A second knocked item that gets put back by hand -> untagged.
	var others: Array = loose_products("Dry Goods").filter(func(o): return o != prod)
	var prod2: RigidBody2D = await stock_one("Dry Goods", others[0]) if not others.is_empty() else null
	if prod2:
		prod2.apply_central_impulse(Vector2(0, 400) * prod2.mass)
		await wait_until(func(): return prod2.has_meta("knocked"), 2.0)
		await wait(0.6)
		await stock_one("Dry Goods", prod2)
		check(not prod2.has_meta("knocked"), "CL setup: re-shelving a knocked item clears its tag")
	print("TIMING CL3 start: cleanup %.1fs left, active %s, at %s" % [main.cleanup_time_left, main.cleanup_active, str(player().global_position.round())])
	# --- CL3: the mop, through the real keys.
	await walk_to(cl().STATION_POS + Vector2(0, 80), 10.0)
	await shot("cleanup_station_closed_store")
	check(await get_tool("mop"), "CL3: picked up a mop at the station with E")
	var spill_pos: Vector2 = Vector2(1440, 700)
	await face_target(spill_pos, cl().MOP_HEAD_OFFSET)
	var t0 := _wall()
	press(act + "place")
	var saw_bar := await wait_until(func(): return float(cl().tools[cl().tool_of(me)]["work"]) > 0.4, 2.0)
	await shot("cleanup_mopping_spill")
	var gone := await wait_until(func(): return not amb().spills.any(func(s): return s["id"] == spill_id), 5.0)
	press(act + "place", 0.0)
	check(saw_bar and gone, "CL3: held C with the mop on the spill -> mopped up in %.1fs (progress showed: %s)" % [_wall() - t0, str(saw_bar)])
	# Up to two approaches, like a person adjusting when the bar doesn't show.
	for attempt in 2:
		await face_target(disp.global_position, mop_stand({"r": 24.0}))
		press(act + "place")
		gone = await wait_until(func(): return not disp.get_node("Display").toppled, 4.0)
		press(act + "place", 0.0)
		if gone:
			break
		var q := PhysicsShapeQueryParameters2D.new()
		var circ := CircleShape2D.new()
		circ.radius = 24.0
		q.shape = circ
		q.transform = Transform2D(0.0, player().global_position + Vector2(20, 0))
		var hits: Array = player().get_world_2d().direct_space_state.intersect_shape(q, 8).map(func(h): return String(h["collider"].get_path()) + "@" + str(h["collider"].global_position.round()))
		print("CL3  display approach %d missed (player %s, display %s) touching %s" % [attempt + 1, str(player().global_position.round()), str(disp.global_position.round()), str(hits)])
	check(gone and disp.global_position.distance_to(disp.get_node("Display").home_position) < 5.0, "CL3: mopped the knocked-over display -> back upright on its spot")
	if not gone:
		print("DEBUG display mop failed: disp %s at %s home %s toppled %s | player %s facing %.2f | work %s | messes %s" % [disp.name, str(disp.global_position.round()), str(disp.get_node("Display").home_position), str(disp.get_node("Display").toppled), str(player().global_position.round()), player().facing_angle, str(cl().tools[cl().tool_of(me)]["work"]), str(cl()._mop_messes().map(func(m): return [m["kind"], m["pos"].round()]))])
	await face_target(prod.global_position, mop_stand({"r": 14.0}))
	press(act + "place")
	gone = await wait_until(func(): return not is_instance_valid(prod) or prod.is_queued_for_deletion(), 4.0)
	press(act + "place", 0.0)
	check(gone, "CL3: mopped the knocked-off item -> binned")
	if not gone:
		print("DEBUG prod at %s player %s facing %.2f work %s messes %s" % [str(prod.global_position), str(player().global_position), player().facing_angle, str(cl().tools[cl().tool_of(me)]["work"]), str(cl()._mop_messes().map(func(m): return [m["kind"], m["pos"].round()]))])
	# Walking with the mop but not holding C does nothing.
	await wait(0.15)
	check(float(cl().tools[cl().tool_of(me)]["work"]) < 0.0, "CL3: not scrubbing when C isn't held")
	print("TIMING CL4 start: cleanup %.1fs left, active %s, at %s" % [main.cleanup_time_left, main.cleanup_active, str(player().global_position.round())])
	# --- CL4: the broom and the pan.
	check(await get_tool("broom"), "CL4: swapped the mop for a broom (E to put down, E to pick up)")
	var dropped: int = cl().tools.filter(func(t): return t["kind"] == "mop" and t["holder"] == 0).size()
	check(dropped == cl().MOPS, "CL4: the mop was put down (%d free mops)" % dropped)
	# A tight cluster of litter, more than the pan holds.
	var cluster_at := Vector2(1600, 700)
	for i in cl().PAN_CAPACITY + 3:
		cl().drop_litter(cluster_at + Vector2(randf_range(-14, 14), randf_range(-14, 14)))
	await face_target(cluster_at, cl().BROOM_HEAD_OFFSET)
	press(act + "place")
	var filled := await wait_until(func(): return cl().tools[cl().tool_of(me)]["full"], 4.0)
	await wait(0.5)
	press(act + "place", 0.0)
	var left_in_cluster: int = cl().litter.filter(func(l): return l["pos"].distance_to(cluster_at) < 30.0).size()
	check(filled and int(cl().tools[cl().tool_of(me)]["pan"]) == cl().PAN_CAPACITY and left_in_cluster >= 3, "CL4: swept %d pieces at once into the pan, which stopped at %d (%d left there)" % [cl().PAN_CAPACITY, cl().tools[cl().tool_of(me)]["pan"], left_in_cluster])
	check(main._prep_label.visible, "CL4: banner still up")
	await tap(act + "interact") # nowhere near a bin: puts it down
	await wait(0.3)
	check(cl().tool_of(me) < 0, "CL4: E away from a bin puts the broom down")
	await get_tool("broom")
	await walk_to(cl().BINS[0]["pos"] + Vector2(0, 30), 10.0)
	await tap(act + "interact")
	await wait(0.3)
	check(cl().tool_of(me) >= 0 and int(cl().tools[cl().tool_of(me)]["pan"]) == 0, "CL4: E at a trash bin empties the pan (and keeps the broom)")
	await face_target(cluster_at, cl().BROOM_HEAD_OFFSET)
	press(act + "place")
	await wait_until(func(): return cl().litter.filter(func(l): return l["pos"].distance_to(cluster_at) < 30.0).is_empty(), 3.0)
	press(act + "place", 0.0)
	check(cl().litter.filter(func(l): return l["pos"].distance_to(cluster_at) < 30.0).is_empty(), "CL4: swept the rest")
	await shot("cleanup_broom")
	print("TIMING CL5 start: cleanup %.1fs left, active %s, at %s" % [main.cleanup_time_left, main.cleanup_active, str(player().global_position.round())])
	# --- CL5: clock out. Not from across the store, then at the clock.
	var litter_left: int = cl().litter.size()
	main._request_clock_out() # host calling the client's handler: no sender, refused
	await wait(0.2)
	check(main.cleanup_active, "CL5: a clock-out request from nobody at the clock is refused")
	var gross: int = main._gross_pay_today()
	var mop_left_before: int = cl()._mop_messes().size()
	await walk_to(main.TIME_CLOCK_POS + Vector2(0, 40), 12.0, 40.0)
	await shot("cleanup_time_clock")
	await go_clock_out()
	check(main.is_day_report_active() and not main.cleanup_active and main.clocked_out_by == 1 and main.clock_out_events_today == 1, "CL5: E at the time clock -> clocked out by the host, report up")
	var frac: float = 0.5 * cl().mop_fraction() + 0.5 * cl().litter_fraction()
	var want_bonus := int(round(maxf(0.0, gross) * cl().CLEAN_BONUS_MAX * frac))
	check(cl().clean_bonus_today == want_bonus, "CL5: bonus %s = %d%% of gross %s x (mop %d%% + litter %d%%)/2" % [main._format_money(cl().clean_bonus_today), int(cl().CLEAN_BONUS_MAX * 100), main._format_money(gross), roundi(cl().mop_fraction() * 100), roundi(cl().litter_fraction() * 100)])
	# (Not mop_left_before: walking to the clock can bump stock off a shelf —
	# that's new mess, and it counts.)
	check(cl().mop_left == cl()._mop_messes(true).size() and cl().mop_left >= mop_left_before and cl().litter_left == litter_left, "CL5: tally matches the floor at clock-out: spills & knockovers left %d (was %d before the walk to the clock), litter left %d" % [cl().mop_left, mop_left_before, cl().litter_left])
	# Oct 2026: + $1 a piece of litter picked up (Cleanup.gd's LITTER_PAY_PER_PIECE), its own line.
	check(main._pay_today() == gross + cl().clean_bonus_today + cl().litter_pay_today() - main.writeups_today * main.WRITEUP_PENALTY, "CL5: Pay Today includes the bonus (and the trash pay, %s): %s" % [main._format_money(cl().litter_pay_today()), main.report_pay_label.text])
	await wait(0.2)
	check(main.report_cleanup_label.visible and "Cleanup" in main.report_cleanup_label.text, "CL5: report line: %s" % main.report_cleanup_label.text.replace("\n", " / "))
	check(cl().tools.all(func(t): return t["holder"] == 0), "CL5: tools out of everyone's hands for the report")
	await shot("cleanup_report")
	# --- CL6: next day: fresh floor, tools racked; then nobody clocks out ->
	# the ceiling does it.
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and main.store_open, 5.0)
	check(cl().litter.is_empty() and cl().tools.all(func(t): return t["holder"] == 0 and TOOL_SPOT_OK.call(t)), "CL6: Day %d: no litter, tools back on the station" % main.current_day)
	check(not main.cleanup_active and main.clocked_out_by == -1, "CL6: cleanup state reset")
	main.shift_time_left = 0.05
	await wait_until(func(): return main.cleanup_active, 3.0)
	main.cleanup_time_left = 1.0
	await wait_until(func(): return main.is_day_report_active(), 4.0)
	await wait(0.2)
	check(main.is_day_report_active() and main.clocked_out_by == 0 and main.clock_out_events_today == 1, "CL6: ceiling ran out -> auto clock-out, report up")
	check("auto clock-out" in main.report_cleanup_label.text, "CL6: report says so: %s" % main.report_cleanup_label.text.replace("\n", " / "))
	check(trucks == dl().deliveries_today or true, "CL: (trucks today %d)" % dl().deliveries_today)
	finish()

var TOOL_SPOT_OK := func(t: Dictionary) -> bool: return main.cleanup.TOOL_SPOTS.any(func(s): return s.distance_to(t["pos"]) < 1.0)

## --- Co-op -------------------------------------------------------------------

const CLOCK_SPOTS := [Vector2(-40, 40), Vector2(40, 40), Vector2(-40, -10), Vector2(40, -10)]

func _run_net_cleanup_host() -> void:
	var want := 2
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--players="):
			want = int(a.substr(10))
	var dd := DirAccess.open("user://")
	if dd and dd.dir_exists("net_orders"):
		for f in DirAccess.get_files_at(NET_DIR):
			DirAccess.remove_absolute(NET_DIR + f)
	main.shift_duration = 60.0
	main.prep_ceiling_override = 0.0
	await wait_until(func(): return main.shift_active and main.players.size() >= want and main.store_open, 40.0)
	var ids: Array = main.players.keys()
	ids.sort()
	check(main.players.size() == want, "net: %d players connected" % main.players.size())
	# Seed some mop mess on top of the day's own (Day 6 spills are random).
	fk()._pause_timer = 1.0e9
	amb()._spill_timer = 1.0e9
	amb().spawn_spill(Vector2(1300, 700), 44.0)
	amb().spawn_spill(Vector2(1700, 760), 40.0)
	var disp: RigidBody2D = main.displays[0]
	disp.get_node("Display").toppled = true
	await wait_until(func(): return cl().litter.size() >= 4, 60.0)
	main.shift_time_left = 0.05
	await wait_until(func(): return main.cleanup_active, 3.0)
	await wait(1.0)
	# --- NC1: every peer sees the same closed store and the same mess.
	var v := _cleanup_view()
	_net_write("nc1_go.json", v)
	for id in ids:
		if id == 1:
			continue
		var r := await _net_read("nc1_%d.json" % id, 30.0)
		check(r.get("ok", false), "NC1: %s: cleanup on, sign CLOSED, no customers, same mess (%d mop, %d litter): %s" % [main.player_display_name(id), v["mop_total"], v["litter_total"], r.get("why", "")])
	# --- NC2: the tool race — every player grabs the SAME mop at once.
	for k in ids.size():
		main.players[ids[k]].rpc("teleport_to", cl().TOOL_SPOTS[0] + Vector2(0, 2 + k))
	await wait(1.5)
	var at := Time.get_unix_time_from_system() + 2.0
	_net_write("nc2_go.json", {"at": at})
	while Time.get_unix_time_from_system() < at:
		await process_frame
	await tap(act + "interact")
	await wait(1.5)
	var holders := ids.filter(func(id): return cl().tool_of(id) >= 0)
	var mop0: int = cl().tools[0]["holder"]
	check(mop0 in ids and cl().tools.filter(func(t): return t["holder"] == mop0).size() == 1, "NC2 race: %d players grabbed mop #1 together -> exactly one holds it (%s); %d players holding a tool" % [want, main.player_display_name(mop0), holders.size()])
	_net_write("nc2_host.json", {"holders": _cleanup_view()["holders"]})
	for id in ids:
		if id == 1:
			continue
		var r := await _net_read("nc2_%d.json" % id, 30.0)
		check(r.get("ok", false), "NC2: %s sees the same holders: %s" % [main.player_display_name(id), r.get("why", "")])
	# Everyone puts whatever they got down again.
	if cl().tool_of(1) >= 0:
		await tap(act + "interact")
	# --- NC3: everyone cleans, each with the brain on its own player (the host
	# mops first, the clients sweep first). No clocking out yet.
	_net_write("nc3_go.json", {})
	var totals := {"m": cl().mop_total, "l": cl().litter_total}
	var st := await _play_cleanup_until_clean()
	for id in ids:
		if id == 1:
			continue
		var r := await _net_read("nc3_%d.json" % id, 120.0)
		check(r.get("did", 0) > 0, "NC3: %s cleaned %d (mopped %d, swept %d, pans emptied %d)" % [main.player_display_name(id), r.get("did", 0), r.get("mopped", 0), r.get("swept", 0), r.get("dumps", 0)])
	check(st["mopped"] + st["swept"] > 0, "NC3: host cleaned %d (mopped %d, swept %d)" % [st["mopped"] + st["swept"], st["mopped"], st["swept"]])
	check(cl().mop_left == 0 and cl().litter_left <= 1, "NC3: the crew cleaned the floor: %d/%d spills & knockovers, %d/%d litter left" % [cl().mop_left, totals["m"], cl().litter_left, totals["l"]])
	# --- NC4: a client far from the clock can't clock out by sending the RPC.
	_net_write("nc4_go.json", {})
	await _net_read("nc4_%d.json" % ids[1], 30.0)
	await wait(1.0)
	check(main.cleanup_active, "NC4: a clock-out request from a player away from the clock is refused")
	# --- NC5: the clock-out race — everyone presses E at the clock at once.
	for k in ids.size():
		main.players[ids[k]].rpc("teleport_to", main.TIME_CLOCK_POS + CLOCK_SPOTS[k])
	await wait(1.5)
	at = Time.get_unix_time_from_system() + 2.0
	_net_write("nc5_go.json", {"at": at})
	while Time.get_unix_time_from_system() < at:
		await process_frame
	await tap(act + "interact")
	await wait(1.5)
	check(main.is_day_report_active() and main.clock_out_events_today == 1 and main.clocked_out_by in ids, "NC5 race: %d players clocked out together -> once, by %s" % [want, main.player_display_name(main.clocked_out_by)])
	_net_write("nc5_host.json", {"pay": main.report_pay_label.text, "clean": main.report_cleanup_label.text, "by": main.clocked_out_by, "bonus": cl().clean_bonus_today})
	print("NC  host report: %s | %s" % [main.report_cleanup_label.text.replace("\n", " / "), main.report_pay_label.text])
	for id in ids:
		if id == 1:
			continue
		var r := await _net_read("nc5_%d.json" % id, 30.0)
		check(r.get("ok", false), "NC5: %s: same report (bonus, pay, who clocked out): %s" % [main.player_display_name(id), r.get("why", "")])
	# --- NC6: next day on every screen: fresh floor, tools back.
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 5.0)
	await wait(1.0)
	_net_write("nc6_go.json", {})
	for id in ids:
		if id == 1:
			continue
		var r := await _net_read("nc6_%d.json" % id, 30.0)
		check(r.get("ok", false), "NC6: %s: Day %d fresh (no litter, tools racked, not in cleanup): %s" % [main.player_display_name(id), main.current_day, r.get("why", "")])
	_net_write("done.json", {})
	await wait(1.0)
	finish()

## The brain without the clock-out: clean until the floor's clean (or 90s).
func _play_cleanup_until_clean() -> Dictionary:
	var ids: Array = main.players.keys()
	ids.sort()
	var broom_first: bool = ids.find(me) % 2 == 1
	var st := {"mopped": 0, "swept": 0, "dumps": 0}
	var t0 := _wall()
	while _wall() - t0 < 90.0 and main.cleanup_active:
		var r := await _brain_until_empty(broom_first)
		for k in st:
			st[k] += r[k]
		if r["mopped"] + r["swept"] + r["dumps"] == 0:
			if mop_messes_view().is_empty() and cl().litter.is_empty():
				break
			await wait(0.5)
	if cl().tool_of(me) >= 0:
		await tap(act + "interact")
	return st

## Cleans nearest-first until the floor is clean from this peer's view (or,
## watch_clock, until it's time to walk to the clock). Mops (or sweeps, if
## broom_first) first, switches tool when its job runs out or all of that
## kind are taken, empties the pan at the nearest bin when it's full.
func _brain_until_empty(broom_first: bool, watch_clock := false) -> Dictionary:
	var st := {"mopped": 0, "swept": 0, "dumps": 0}
	var skip := []
	var fails_in_row := 0
	while main.cleanup_active and fails_in_row < 6:
		var p := player()
		if watch_clock and main.cleanup_time_left < route_len(p.global_position, main.TIME_CLOCK_POS) / 220.0 + 5.0:
			break
		var mops := mop_messes_view().filter(func(m): return not skip.any(func(q): return q.distance_to(m["pos"]) < 12.0))
		var lit: Array = cl().litter.filter(func(m): return not skip.any(func(q): return q.distance_to(m["pos"]) < 12.0))
		var held: int = cl().tool_of(me)
		var pan_has: bool = held >= 0 and cl().tools[held]["kind"] == "broom" and int(cl().tools[held]["pan"]) > 0
		if mops.is_empty() and lit.is_empty() and not pan_has:
			break
		var kind := "broom" if (broom_first and not lit.is_empty()) or mops.is_empty() else "mop"
		if held >= 0 and cl().tools[held]["kind"] == "broom" and (cl().tools[held]["full"] or (lit.is_empty() and pan_has)):
			await _empty_pan()
			st["dumps"] += 1
			continue
		if not await get_tool(kind):
			kind = "broom" if kind == "mop" else "mop"
			if (kind == "mop" and mops.is_empty()) or (kind == "broom" and lit.is_empty()) or not await get_tool(kind):
				await wait(0.5)
				fails_in_row += 1
				continue
		var target = _nearest(p.global_position, mops if kind == "mop" else lit, skip)
		if target == null:
			fails_in_row += 1
			continue
		var tpos: Vector2 = target["pos"]
		if not await face_target(tpos, mop_stand(target) if kind == "mop" else cl().BROOM_HEAD_OFFSET):
			skip.append(tpos)
			fails_in_row += 1
			continue
		var before_m := mop_messes_view().size()
		var before_l: int = cl().litter.size()
		press(act + "place")
		var gone := await wait_until(func():
			if kind == "mop":
				return not mop_messes_view().any(func(m): return m["pos"].distance_to(tpos) < 12.0)
			var h: int = cl().tool_of(me)
			return (h >= 0 and cl().tools[h]["full"]) or not cl().litter.any(func(m): return m["pos"].distance_to(tpos) < 1.0), 5.0)
		press(act + "place", 0.0)
		await physics_frame
		if gone:
			fails_in_row = 0
			if kind == "mop":
				st["mopped"] += maxi(1, before_m - mop_messes_view().size())
			else:
				st["swept"] += maxi(0, before_l - cl().litter.size())
		else:
			skip.append(tpos)
			fails_in_row += 1
	steer(Vector2.ZERO)
	return st

## OCT 2026 PHASE 3D: into the nearest can WITH ROOM (a full can won't take
## it — E there would put the broom down). If every open can is full, empty
## one first, as a player would: broom down, the can's bag out to the
## dumpster, back for the broom.
func _empty_pan() -> void:
	var p := player()
	var best := -1
	var bd := INF
	for i in cl().BINS.size():
		if cl()._bin_open(i) and not cl().can_full(i):
			var d := route_len(p.global_position, cl().BINS[i]["pos"])
			if d < bd:
				bd = d
				best = i
	if best < 0:
		await _dump_a_can()
		return
	await walk_to(cl().BINS[best]["pos"] + Vector2(0, 30), 12.0, 30.0)
	await tap(act + "interact")
	await wait_until(func(): return cl().tool_of(me) >= 0 and int(cl().tools[cl().tool_of(me)]["pan"]) == 0, 2.0)

## OCT 2026 PHASE 3D: hands free (a tool goes down here), the nearest full
## can's bag out, into the dumpster.
func _dump_a_can() -> bool:
	if cl().tool_of(me) >= 0:
		await tap(act + "interact")
		await wait_until(func(): return cl().tool_of(me) < 0, 2.0)
	var p := player()
	var best := -1
	var bd := INF
	for i in cl().BINS.size():
		if cl()._bin_open(i) and int(cl().cans[i]) > 0:
			var d := route_len(p.global_position, cl().BINS[i]["pos"]) - (1000.0 if cl().can_full(i) else 0.0)
			if d < bd:
				bd = d
				best = i
	if best < 0:
		return false
	await walk_to(cl().BINS[best]["pos"] + Vector2(0, 30), 12.0, 30.0)
	await tap(act + "interact")
	if not await wait_until(func(): return cl().bag_of(me) >= 0, 2.0):
		return false
	await walk_to(cl().DUMPSTER_POS + Vector2(0, -75), 16.0, 40.0)
	await tap(act + "interact")
	return await wait_until(func(): return cl().bag_of(me) < 0, 2.0)

## JSON hands numbers back as floats: compare 4 and 4.0 (and arrays of them)
## as the same value.
func _jnorm(v) -> String:
	if v is float or v is int:
		return str(int(v)) if is_equal_approx(float(v), roundf(float(v))) else str(v)
	if v is Array:
		return str(v.map(func(x): return _jnorm(x)))
	return str(v)

func _run_net_cleanup_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 20.0)
	me = main.multiplayer.get_unique_id()
	act = root.get_node("Settings").local_prefix()
	var who: String = main.player_display_name(me)
	var g1 := await _net_read("nc1_go.json", 120.0)
	await wait(0.3)
	var v := _cleanup_view()
	var why := ""
	for k in ["active", "litter", "mop_left", "mop_total", "litter_total", "spills", "sign"]:
		if _jnorm(v[k]) != _jnorm(g1.get(k)):
			why += " %s %s vs host %s" % [k, str(v[k]), str(g1.get(k))]
	if v["customers"] != 0:
		why += " customers %d" % v["customers"]
	if not (main._prep_label.visible and "CLEANUP" in main._prep_label.text):
		why += " no banner"
	_net_write("nc1_%d.json" % me, {"ok": why == "", "why": why})
	check(why == "", "%s: NC1 cleanup on my screen%s" % [who, why])
	var g2 := await _net_read("nc2_go.json", 60.0)
	await wait_until(func(): return player().global_position.distance_to(cl().TOOL_SPOTS[0]) < 10.0, 3.0)
	while Time.get_unix_time_from_system() < float(g2.get("at", 0.0)):
		await process_frame
	await tap(act + "interact")
	var h2 := await _net_read("nc2_host.json", 30.0)
	await wait(0.5)
	var mine: Array = _cleanup_view()["holders"]
	var why2 := "" if _jnorm(mine) == _jnorm(h2.get("holders")) else " holders %s vs host %s" % [str(mine), str(h2.get("holders"))]
	_net_write("nc2_%d.json" % me, {"ok": why2 == "", "why": why2})
	check(why2 == "", "%s: NC2 same tool holders%s" % [who, why2])
	if cl().tool_of(me) >= 0:
		await tap(act + "interact")
		await wait(0.3)
	await _net_read("nc3_go.json", 60.0)
	var st := await _play_cleanup_until_clean()
	_net_write("nc3_%d.json" % me, {"did": st["mopped"] + st["swept"], "mopped": st["mopped"], "swept": st["swept"], "dumps": st["dumps"]})
	await _net_read("nc4_go.json", 120.0)
	var ids: Array = main.players.keys()
	ids.sort()
	if me == ids[1]:
		main.rpc_id(1, "_request_clock_out")
		_net_write("nc4_%d.json" % me, {})
	var g5 := await _net_read("nc5_go.json", 60.0)
	await wait_until(func(): return main.near_time_clock(player().global_position), 3.0)
	while Time.get_unix_time_from_system() < float(g5.get("at", 0.0)):
		await process_frame
	await tap(act + "interact")
	var r5 := await _net_read("nc5_host.json", 30.0)
	await wait(0.6)
	var why5 := ""
	if not main.is_day_report_active():
		why5 += " no report"
	if main.report_cleanup_label.text != r5.get("clean", ""):
		why5 += " cleanup line '%s' vs '%s'" % [main.report_cleanup_label.text, r5.get("clean", "")]
	if main.report_pay_label.text != r5.get("pay", ""):
		why5 += " pay '%s' vs '%s'" % [main.report_pay_label.text, r5.get("pay", "")]
	if main.clocked_out_by != int(r5.get("by", -2)):
		why5 += " by %d" % main.clocked_out_by
	_net_write("nc5_%d.json" % me, {"ok": why5 == "", "why": why5})
	check(why5 == "", "%s: NC5 report matches the host's%s" % [who, why5])
	await _net_read("nc6_go.json", 60.0)
	var why6 := ""
	if main.cleanup_active or not cl().litter.is_empty() or not cl().tools.all(func(t): return t["holder"] == 0):
		why6 = " %s" % str(_cleanup_view())
	_net_write("nc6_%d.json" % me, {"ok": why6 == "", "why": why6})
	check(why6 == "", "%s: NC6 fresh day%s" % [who, why6])
	await _net_read("done.json", 60.0)
	finish()


## --- WEEK 20: playtest polish (tool station, checkout lanes, Produce
## displays, Dry Goods shelf bays) --------------------------------------------
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=5 --test=polish
##   (add --shots under xvfb-run, no --headless, for frames of each piece)
## Co-op (every peer checks its own screen; a client walks to the station,
## takes a tool and clocks the day out):
##   godot --headless --path . --script res://tools/hazards_test.gd -- --server --day=5 --players=2 --test=net-polish &
##   godot --headless --path . --script res://tools/hazards_test.gd -- --client --test=net-polish
## PO1 layout (station in the break room by the clock, out of the clock's
## reach; bins where they were), PO2 shelf census (every section's shelf,
## slot, collision and art counts — the same line prints on the pre-change
## build, so they can be diffed), PO3 checkout lanes on every register
## (collision/markers untouched), PO4 the conveyor during real sales (item
## slides toward the register, its own sprite hidden, sale still at
## CHECKOUT_WAIT_SECONDS), PO5 Produce displays (pack crates, still
## knock-over-able), PO6 the station -> clock trip (pick up a mop at the
## station during cleanup, put it back, clock out at the clock next to it).

const PO_BINS := [Vector2(1110.0, 590.0), Vector2(1300.0, 500.0), Vector2(1975.0, 620.0), Vector2(905.0, 620.0), Vector2(1975.0, 300.0)]

## Every section's shelves as data, identical on every peer.
func _shelf_census() -> Dictionary:
	var out := {}
	for sec in main.SECTIONS:
		var bodies: Array = main.shelves.filter(func(sb): return main._grid_cell_of(sb.global_position) == sec["grid_pos"])
		var slots := 0
		var active := 0
		var shapes := []
		var body_bays := 0
		var slot_bays := 0
		for sb in bodies:
			var sh: Node = sb.get_node("Shelf")
			slots += sh._all_slots.size()
			active += sh.slots.size()
			var cs: CollisionShape2D = sb.get_node("CollisionShape2D")
			shapes.append("%s%s" % [str((cs.shape as RectangleShape2D).size), "" if not cs.disabled else "off"])
			var art: Node = sb.get_node_or_null("Polygon2D/ShelfArt")
			body_bays += art.get_child_count() if art else 0
			for slot in sh._all_slots:
				slot_bays += slot.get_children().filter(func(c): return c.name == "EmptyShelfArt").size()
		# Anything shelf-shaped in the section that ISN'T a live shelf.
		var stray := 0
		for n in main.get_node("Sections/%s" % sec["node_name"]).get_children():
			if not n in main.shelves:
				stray += 1
		out[sec["name"]] = {"shelves": bodies.size(), "slots": slots, "active_slots": active, "shapes": shapes, "body_bays": body_bays, "slot_bays": slot_bays, "stray_nodes": stray}
	return out

func _po_static_checks(who: String) -> Dictionary:
	var c := cl()
	# --- PO1: the station.
	var sp: Vector2 = c.STATION_POS
	# OCT 2026 PHASE 3D: the station's tools in the Break Room; one mop and one
	# broom on the hub rack (tools are out all day now).
	var room_spots: Array = c.TOOL_SPOTS.filter(func(s): return main._grid_cell_of(s) == main.BREAK_ROOM_GRID_POS)
	var hub_spots: Array = c.TOOL_SPOTS.filter(func(s): return main._grid_cell_of(s) == main.ENTRANCE_GRID_POS)
	check(main._grid_cell_of(sp) == main.BREAK_ROOM_GRID_POS and room_spots.size() == 4 and hub_spots.size() == 2, "%sPO1: tool station + its 4 tool spots in the Break Room, 2 on the hub rack (station %s)" % [who, str(sp)])
	var nearest: float = c.TOOL_SPOTS.map(func(s): return s.distance_to(main.TIME_CLOCK_POS)).min()
	check(sp.distance_to(main.TIME_CLOCK_POS) < 250.0, "%sPO1: station is next to the time clock (%.0fpx)" % [who, sp.distance_to(main.TIME_CLOCK_POS)])
	check(nearest > c.TOOL_PICKUP_RANGE + main.TIME_CLOCK_RANGE, "%sPO1: no spot in reach of both a tool and the clock (nearest spot %.0fpx > %.0f)" % [who, nearest, c.TOOL_PICKUP_RANGE + main.TIME_CLOCK_RANGE])
	var station: Node2D = c.get_node("ToolStation")
	check(station.global_position == sp and station.visible, "%sPO1: station art drawn at the new spot" % who)
	var bins_same: bool = c.BINS.size() == PO_BINS.size()
	for i in mini(c.BINS.size(), PO_BINS.size()):
		bins_same = bins_same and c.BINS[i]["pos"] == PO_BINS[i]
	check(bins_same, "%sPO1: all %d trash bins exactly where they were" % [who, PO_BINS.size()])
	# --- PO2: shelves.
	var census := _shelf_census()
	print("CENSUS " + JSON.stringify(census))
	var want := {"Dry Goods": 6, "Produce": 5, "Dairy/Frozen": 5, "Bakery": 5}
	for sec in census:
		var v: Dictionary = census[sec]
		var ok: bool = v["shelves"] == want[sec] and v["slots"] == v["shelves"] * 6 and v["shapes"].all(func(x): return x == "(180.0, 66.0)") and v["stray_nodes"] == 0
		check(ok, "%sPO2: %s: %d shelves, %d slots (%d active today), every body's 180x66 collision on, nothing stray" % [who, sec, v["shelves"], v["slots"], v["active_slots"]])
		check(v["body_bays"] == v["shelves"] * 3 and v["slot_bays"] == v["slots"], "%sPO2: %s art: %d body bays + %d slot bays, one each — no doubled shelf art" % [who, sec, v["body_bays"], v["slot_bays"]])
	var dg: Node2D = main.get_node("Sections/DryGoods/Shelf1")
	var tint: Color = dg.get_node("Polygon2D/ShelfArt").modulate
	check(tint != Color.WHITE and dg.get_node("Slot1/EmptyShelfArt").modulate == tint and dg.modulate == Color.WHITE and dg.get_node("Slot1/Indicator").default_color.is_equal_approx(main.SECTION_COLORS["Dry Goods"]), "%sPO2: Dry Goods bays tinted as one unit (%s); shelf root, outlines untouched" % [who, str(tint)])
	# --- PO3: registers.
	var lanes := 0
	var intact := 0
	for body in get_nodes_in_group("cashier"):
		if body.has_node("LaneArt") and body.get_node("LaneArt/Belt") != null and body.get_node("Polygon2D").self_modulate.a == 0.0:
			lanes += 1
		var cs: CollisionShape2D = body.get_node("CollisionShape2D")
		if (cs.shape as RectangleShape2D).size == Vector2(60, 40) and body.get_node("Checkout").position == Vector2(50, 0) and body.get_node("Queue1").position == Vector2(90, 0):
			intact += 1
	var n_cash := get_nodes_in_group("cashier").size()
	check(lanes == n_cash and n_cash == 5, "%sPO3: all %d registers drawn as pack checkout lanes (placeholder box hidden)" % [who, lanes])
	check(intact == n_cash, "%sPO3: register collision 60x40 + checkout/queue markers unchanged on all %d" % [who, intact])
	# --- PO5: Produce displays.
	for d in main.displays:
		var up: Node2D = d.get_node("Upright")
		var art_ok: bool = up.has_node("CrateArt") and d.get_node("Toppled").has_node("CrateArt") and up.get_children().filter(func(n): return n is Polygon2D and n.visible).is_empty()
		var cs: CollisionShape2D = d.get_node("CollisionShape2D")
		check(art_ok and (cs.shape as RectangleShape2D).size == Vector2(44, 44) and d.is_in_group("display"), "%sPO5: %s wears pack produce crates (placeholder squares hidden), same 44x44 knockable body" % [who, d.name])
	return census

## Watches every lane for `secs`: the first checkout seen on each lane is
## tracked until it resolves. Returns what this peer saw.
func _po_watch_conveyors(secs: float) -> Dictionary:
	var art: Node = main.get_node("StoreArt")
	var seen := 0
	var slid := 0
	var hidden := 0
	var resolved := 0
	var durations := []
	var sold0 := _po_sold()
	var t0 := _wall()
	var track := {} # lane index -> {"item", "x0", "t0", "hid"}
	while _wall() - t0 < secs:
		await process_frame
		for i in art._lanes.size():
			var lane: Dictionary = art._lanes[i]
			var item = lane["item"]
			var tr = track.get(i)
			if tr == null and item != null:
				track[i] = {"item": item, "x0": lane["rider"].position.x, "t0": _wall(), "hid": false, "xmin": lane["rider"].position.x}
				seen += 1
				if shots and not _po_shot_lane:
					_po_shot_lane = true
					_po_shoot_lane(lane) # not awaited: runs alongside this loop
			elif tr != null:
				if is_instance_valid(tr["item"]) and item == tr["item"]:
					tr["xmin"] = minf(tr["xmin"], lane["rider"].position.x)
					var pa = tr["item"].get_node_or_null("ProductArt")
					if pa and pa.self_modulate.a == 0.0 and lane["rider"].visible:
						tr["hid"] = true
				elif not is_instance_valid(tr["item"]):
					# Sold (freed on the host, despawned here).
					resolved += 1
					durations.append(_wall() - tr["t0"])
					if tr["x0"] - tr["xmin"] > 10.0:
						slid += 1
					if tr["hid"]:
						hidden += 1
					if not lane["rider"].visible or lane["item"] != null:
						pass
					track.erase(i)
				else:
					track.erase(i) # walked off without buying: not a sale
		if resolved >= 3:
			break
	await wait(0.5) # let the last sale's total_sold reach this peer
	return {"seen": seen, "resolved": resolved, "slid": slid, "hidden": hidden, "durations": durations, "sold": _po_sold() - sold0}

## Every register's replicated sales count, summed.
func _po_sold() -> int:
	var n := 0
	for body in get_nodes_in_group("cashier"):
		n += int(body.get_node("Cashier").total_sold)
	return n

func _po_wait() -> float:
	return main.get_node("CentralCheckout/Cashier1/Cashier").CHECKOUT_WAIT_SECONDS

var _po_shot_lane := false

## Frames of one checkout riding the belt, through a camera of its own.
func _po_shoot_lane(lane: Dictionary) -> void:
	var cam := Camera2D.new()
	main.add_child(cam)
	cam.global_position = lane["body"].global_position + Vector2(20, -10)
	cam.zoom = Vector2(5, 5)
	cam.make_current()
	await process_frame
	await process_frame
	for k in 3:
		await shot("po4_conveyor_%d" % k)
		await wait(1.1)
	player().get_node("Camera").make_current()
	cam.queue_free()

## The opening stock starts loose on the floor (WEEK 16), and with nobody
## shelving it shoppers leave empty-handed — so, like a crew would, shelve a
## few per section (host only, through the shelves' real settle check).
func _po_stock_shelves() -> int:
	var n := 0
	for sec in ["Dry Goods", "Produce", "Dairy/Frozen", "Bakery"]:
		for k in 4:
			if await stock_one(sec) != null:
				n += 1
	print("PO  stocked %d items for shoppers" % n)
	return n

func _po_check_conveyor(who: String, r: Dictionary) -> void:
	check(r["resolved"] >= 1 and r["resolved"] == r["sold"], "%sPO4: every sale in the window rode the belt: %d sales, %d seen through on a belt (%d started)" % [who, r["sold"], r["resolved"], r["seen"]])
	check(r["slid"] == r["resolved"] and r["resolved"] > 0, "%sPO4: the item slid along the belt toward the register on %d/%d" % [who, r["slid"], r["resolved"]])
	check(r["hidden"] == r["resolved"] and r["resolved"] > 0, "%sPO4: the shopper's own copy was hidden while it rode the belt on %d/%d" % [who, r["hidden"], r["resolved"]])
	var ds: Array = r["durations"]
	var ok := not ds.is_empty() and ds.all(func(d): return absf(d - _po_wait()) < 0.6)
	check(ok, "%sPO4: each sale still landed ~%.1fs after the item hit the belt (checkout timing untouched): %s" % [who, _po_wait(), str(ds.map(func(d): return snappedf(d, 0.01)))])

## PO6 on this process's own player: from the hub to the station, a mop in
## hand WITHOUT clocking out, put it back, then clock out at the clock.
## tap() releases on the next physics_frame signal, which fires just BEFORE
## the players' _physics_process — so, depending on what the caller awaited
## last, Player.gd can miss the press entirely (seen on a client right after
## walk_to()). Held across a full physics step instead, so a press that goes
## unanswered is the game's fault, not the harness's.
func _po_press(action: String) -> void:
	Input.action_press(action)
	await physics_frame
	await physics_frame
	Input.action_release(action)

func _po_station_trip(who: String, clock_out := true) -> void:
	player().teleport_to(Vector2(1440, 700))
	await wait(0.5)
	var ok := await walk_to(cl().TOOL_SPOTS[0], 4.0, 30.0)
	check(ok, "%sPO6: walked hub -> Break Room tool station%s" % [who, "" if ok else " (stuck at %s)" % str(player().global_position.round())])
	await shot("po6_at_station")
	await _po_press(act + "interact")
	await wait_until(func(): return cl().tool_of(me) >= 0, 2.0)
	check(cl().tool_of(me) >= 0 and main.cleanup_active, "%sPO6: E at the station picked up the %s — and did NOT clock the crew out%s" % [who, cl().tools[maxi(cl().tool_of(me), 0)]["kind"], "" if cl().tool_of(me) >= 0 and main.cleanup_active else " (holders %s, cleanup %s, at %s)" % [str(cl().tools.map(func(t): return t["holder"])), main.cleanup_active, str(player().global_position.round())]])
	await shot("po6_holding_tool")
	await _po_press(act + "interact")
	await wait_until(func(): return cl().tool_of(me) < 0, 2.0)
	check(cl().tool_of(me) < 0 and main.cleanup_active, "%sPO6: put it back down at the station" % who)
	if clock_out:
		var t0 := _wall()
		await go_clock_out()
		check(not main.cleanup_active and main.clocked_out_by == me, "%sPO6: a few steps to the clock and clocked out (%.1fs from the station)" % [who, _wall() - t0])

func _run_polish() -> void:
	if shots:
		main.debug_label.visible = false
		main.status_hud = false
	main.shift_duration = 420.0
	main.prep_ceiling_override = 0.0
	await wait_until(func(): return main.shift_active and main.players.has(1) and main.store_open, 20.0)
	await wait(1.0)
	_po_static_checks("")
	pin_manager(Vector2(480, 1350), 0.0)
	fk()._pause_timer = 1.0e9
	# Stand clear of every queue lane (--shots frames a lane on its own).
	player().teleport_to(Vector2(1440, 600))
	await _po_stock_shelves()
	var r := await _po_watch_conveyors(380.0)
	_po_check_conveyor("", r)
	# Displays, knocked over and stood back up, still work as props.
	var d: RigidBody2D = main.displays[0]
	d.get_node("Display").toppled = true
	await wait(0.3)
	check(d.get_node("Toppled").visible and not d.get_node("Upright").visible, "PO5: knocked over -> tipped crate art shows")
	if shots:
		var cam := Camera2D.new()
		main.add_child(cam)
		cam.global_position = Vector2(2470, 760)
		cam.zoom = Vector2(3, 3)
		cam.make_current()
		await process_frame
		await shot("po5_produce_displays_one_knocked")
		cam.global_position = Vector2(1440, 250)
		cam.zoom = Vector2(1.6, 1.6)
		await process_frame
		await shot("po2_dry_goods_shelves")
		cam.global_position = Vector2(1360, 960)
		cam.zoom = Vector2(2.2, 2.2)
		await process_frame
		await shot("po3_checkout_lanes")
		player().get_node("Camera").make_current()
		cam.queue_free()
	main.shift_time_left = 0.05
	await wait_until(func(): return main.cleanup_active, 5.0)
	await wait(1.0)
	await _po_station_trip("")
	finish()

func _run_net_polish_host() -> void:
	var want := 2
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--players="):
			want = int(a.substr(10))
	if DirAccess.dir_exists_absolute(NET_DIR):
		for f in DirAccess.get_files_at(NET_DIR):
			DirAccess.remove_absolute(NET_DIR + f)
	main.shift_duration = 420.0
	main.prep_ceiling_override = 0.0
	await wait_until(func(): return main.shift_active and main.players.size() >= want and main.store_open, 40.0)
	var ids: Array = main.players.keys()
	ids.sort()
	check(main.players.size() == want, "net: %d players connected" % main.players.size())
	pin_manager(Vector2(480, 1350), 0.0)
	fk()._pause_timer = 1.0e9
	await wait(1.0)
	var census := _po_static_checks("Host: ")
	await _po_stock_shelves()
	_net_write("np1_go.json", {"census": census})
	var r := await _po_watch_conveyors(380.0)
	_po_check_conveyor("Host: ", r)
	for id in ids:
		if id == 1:
			continue
		var c := await _net_read("np1_%d.json" % id, 120.0)
		check(c.get("census_same", false), "NP1: %s's shelf census matches the host's exactly" % main.player_display_name(id))
		check(c.get("fails", 1) == 0, "NP1: %s: every station/shelf/lane/display check passed on their screen (%d failed)" % [main.player_display_name(id), c.get("fails", -1)])
		check(c.get("conv_ok", false), "NP1: %s saw the conveyor run on their screen: %s" % [main.player_display_name(id), str(c.get("conv", {}))])
	# Cleanup: each client in turn walks to the station, takes a tool, puts
	# it back; the last one clocks the crew out. The host checks it all from
	# its own side. Close with a real floor of litter first: >~10 pieces is
	# past the MTU for Cleanup's state (the Week 20 sync fix).
	await wait_until(func(): return cl().litter.size() >= 20, 240.0)
	main.shift_time_left = 0.05
	await wait_until(func(): return main.cleanup_active, 5.0)
	await wait(1.0)
	await _po_station_trip("Host: ", false)
	for k in ids.size():
		var id: int = ids[k]
		if id == 1:
			continue
		var last: bool = k == ids.size() - 1
		_net_write("np2_go_%d.json" % id, {"clock_out": last, "litter": cl().litter.size(), "mop_total": cl().mop_total, "litter_total": cl().litter_total})
		var saw_hold := await wait_until(func(): return cl().tool_of(id) >= 0, 60.0)
		check(saw_hold, "NP2: host sees %s holding a tool picked up at the Break Room station" % main.player_display_name(id))
		check(main.cleanup_active, "NP2: ...and that pickup didn't clock anyone out")
		var r2 := await _net_read("np2_%d.json" % id, 90.0)
		check(r2.get("fails", 1) == 0, "NP2: %s's station trip passed on their side" % main.player_display_name(id))
	check(main.is_day_report_active() and main.clocked_out_by == ids[ids.size() - 1], "NP2: clocked out by %s at the clock next to the station" % main.player_display_name(main.clocked_out_by))
	_net_write("done.json", {})
	await wait(1.0)
	finish()

func _run_net_polish_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 20.0)
	me = main.multiplayer.get_unique_id()
	act = root.get_node("Settings").local_prefix()
	var who: String = main.player_display_name(me) + ": "
	var g := await _net_read("np1_go.json", 120.0)
	var census := _po_static_checks(who)
	var same := _jnorm(JSON.parse_string(JSON.stringify(census))) == _jnorm(g.get("census"))
	var r := await _po_watch_conveyors(380.0)
	_po_check_conveyor(who, r)
	var conv_ok: bool = r["resolved"] >= 1 and r["resolved"] == r["sold"] and r["slid"] == r["resolved"] and r["hidden"] == r["resolved"]
	_net_write("np1_%d.json" % me, {"census_same": same, "fails": fails, "conv_ok": conv_ok, "conv": {"sales": r["sold"], "on_belt": r["resolved"], "slid": r["slid"], "hidden": r["hidden"]}})
	var go := await _net_read("np2_go_%d.json" % me, 240.0)
	var before := fails
	# The cleanup state (litter, tools, tallies) is past the MTU by now on a
	# long day — it must still be reaching this peer (the Week 20 sync fix).
	var mine := [cl().litter.size(), cl().mop_total, cl().litter_total]
	var host := [int(go.get("litter", -1)), int(go.get("mop_total", -1)), int(go.get("litter_total", -1))]
	check(mine == host and host[0] >= 20, "%sNP2: same cleanup state as the host with a floor of litter (litter, mop total, litter total: mine %s, host %s)" % [who, str(mine), str(host)])
	await _po_station_trip(who, go.get("clock_out", false))
	_net_write("np2_%d.json" % me, {"fails": fails - before})
	await _net_read("done.json", 120.0)
	finish()

## ---------------------------------------------------------------------------
## WEEK 21's ENDLESS MODE tests (endless-board, endless, net-endless) are gone
## with the mode (OCT 2026 PHASE 4). Their ground is covered by
## tools/events_test.gd: the random events that replaced the shift board, the
## Break Room Shop that kept its upgrades (bought with the bank now), and the
## save that carries the gear over. Kept here: shared helpers, and the
## upgrade-effects check (events_test.gd's shop test runs it).

func _arg_int(prefix: String, fallback: int) -> int:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return int(a.substr(prefix.length()))
	return fallback

## Canonical JSON (sorted keys, one float format) — how two peers' views are
## compared: both go through the same stringify/parse round trip.
func _canon(v) -> String:
	return JSON.stringify(JSON.parse_string(JSON.stringify(v)), "", true)

## The Break Room Shop's upgrades, measured on the live player (Shop.gd).
func _check_upgrade_effects(tag: String) -> void:
	var p := player()
	# Speed: walk right across open floor for a moment and measure.
	check(is_equal_approx(p.speed(), p.SPEED * main.shop.speed_mult()), "%s: walk speed %.0f = %.0f x %.2f" % [tag, p.speed(), p.SPEED, main.shop.speed_mult()])
	# Back Brace: E fills your arms up to the capacity; the host refuses one
	# more; E on full arms sets the whole armful down, spread out.
	var cap: int = main.shop.carry_capacity()
	p.teleport_to(Vector2(1440, 700)) # open floor in the checkout hub
	await wait(0.3)
	for i in cap + 1:
		main.spawn_product_at("Dry Goods", p.global_position + Vector2(-20 + 20 * i, 30))
	await wait(0.5)
	for i in cap:
		await tap(act + "interact")
		await wait(0.25)
	var held: int = p.carried_count(me)
	check(held == cap, "%s: Back Brace level %d -> E grabbed %d at once (capacity %d)" % [tag, main.shop.upgrade_level("brace"), held, cap])
	for o in get_nodes_in_group("carryable"):
		var c: Node = o.get_node("Carryable")
		if c.carrier_id == 0 and o.global_position.distance_to(p.global_position) < 70.0:
			c.try_pickup(me, p.global_position) # straight to the host's check
	await wait(0.2)
	check(p.carried_count(me) == cap, "%s: the host refuses a pickup past the capacity (%d held)" % [tag, p.carried_count(me)])
	if cap > 1:
		var ys := []
		for o in get_nodes_in_group("carryable"):
			if o.get_node("Carryable").carrier_id == me:
				ys.append(o.global_position.y)
		ys.sort()
		check(ys.size() == cap and ys[-1] - ys[0] >= (cap - 1) * 8.0, "%s: the stack draws stacked (y spread %.0fpx)" % [tag, ys[-1] - ys[0] if ys.size() > 1 else 0.0])
		var mine := get_nodes_in_group("carryable").filter(func(o): return o.get_node("Carryable").carrier_id == me)
		await tap(act + "interact")
		await wait(0.6)
		var gap := INF
		for a in mine.size():
			for b in range(a + 1, mine.size()):
				gap = minf(gap, mine[a].global_position.distance_to(mine[b].global_position))
		var fast := mine.filter(func(o): return o.linear_velocity.length() > 60.0).size()
		# >= 24: side by side, not piled (a product is 28px; real-time physics
		# settles two touching ones a px or two closer than the fixed-fps sim did).
		check(p.carried_count(me) == 0 and gap >= 24.0 and fast == 0, "%s: one E on full arms set all %d down, side by side (closest %.0fpx apart, %d still flying)" % [tag, mine.size(), gap, fast])
	else:
		await tap(act + "interact")
		await wait(0.3)
		check(p.carried_count(me) == 0, "%s: no Back Brace: E puts the one down, as always" % tag)
	# A box never stacks.
	if cap > 1:
		dl().drop_box(p.global_position + Vector2(24, 0), "Dry Goods")
		main.spawn_product_at("Dry Goods", p.global_position + Vector2(-24, 10))
		await wait(0.5)
		var box: Node2D = null
		for b in get_nodes_in_group("delivery_box"):
			if b.global_position.distance_to(p.global_position) < 80.0:
				box = b
		if box:
			box.get_node("Carryable").try_pickup(me, p.global_position)
			await wait(0.3)
			var had_box: bool = box.get_node("Carryable").carrier_id == me
			await tap(act + "interact") # with a box in hand, E puts the box down — never stacks
			await wait(0.3)
			var grabbed := get_nodes_in_group("carryable").filter(func(o): return not o.is_in_group("delivery_box") and o.get_node("Carryable").carrier_id == me).size()
			check(had_box and p.carried_count(me) == 0 and grabbed == 0, "%s: holding a box, E sets the box down and grabs no product with it (%d held)" % [tag, p.carried_count(me)])
	# Clear what this check spawned so the shift starts as it would have.
	for o in get_nodes_in_group("carryable"):
		if o.get_node("Carryable").carrier_id == 0 and o.global_position.distance_to(Vector2(1440, 700)) < 120.0:
			o.queue_free()
	p.teleport_to(main.SPAWN_CENTER)
	await wait(0.3)

