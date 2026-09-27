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
	var mode := "interact"
	for a in args:
		if a.begins_with("--test="):
			mode = a.substr(7)
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

func _at_a_slot(obj: Node) -> bool:
	for s in main.shelves:
		var shelf: Node = s.get_node("Shelf")
		for slot in shelf.slots:
			if obj.global_position.distance_to(slot.global_position) <= shelf.CAPTURE_RADIUS:
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
	check(main.current_day == 5, "started on Day 5")
	check(fk().active and fk().visible, "Day 5: forklift active")
	check(mgr().active and mgr().visible, "Day 5: manager active")

	# --- Dairy/Frozen: open, stocked, and on his rounds.
	var names: Array = main._unlocked_sections().map(func(s): return s["name"])
	check("Dairy/Frozen" in names and not ("Bakery" in names), "Day 5 unlocked sections: %s" % str(names))
	var dairy_gate: Node = main.get_node("Gates/GateDairyFrozen/Gate")
	check(dairy_gate.collision.disabled, "Dairy/Frozen gate open (collision off)")
	var dairy_shelves: Array = main.shelves.filter(func(s): return main._grid_cell_of(s.global_position) == Vector2i(0, 1))
	check(dairy_shelves.size() == 4, "Dairy/Frozen has %d shelves" % dairy_shelves.size())
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
	var real_day: int = main.current_day
	for d in [3, 4, 5]:
		main.current_day = d
		var total := 0
		var rows: int = main.STACK_ROWS_BY_TIER[clampi(main._unlocked_sections().size() - 1, 0, 3)]
		for s in main.shelves:
			if main.is_unlocked_at_pos(s.global_position):
				total += 3 * rows
		slots_by_day[d] = [total, main._product_baseline()]
	main.current_day = real_day
	print("DENSITY  day -> [reachable slots, product cap]: %s" % str(slots_by_day))
	check(slots_by_day[5][1] / 3.0 > slots_by_day[4][1] / 2.0, "Day 5 spawn density (product cap per open section) is higher than Day 4's: %s" % str(slots_by_day))
	check(slots_by_day[5][0] == 2 * 36, "Day 5 shelves stock two deep: %d reachable slots (36 one-deep)" % slots_by_day[5][0])
	check(dairy_slots == 24, "Dairy/Frozen shelves two deep: %d slots" % dairy_slots)

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
	print("PATROL  %d Meat/Deli visits, %d frames there, min manager-forklift distance %.0fpx, %d frames overlapping the forklift, %d frames standing in its lane" % [meat_visits, meat_frames, min_dist, overlap_frames, lane_frames])
	check(meat_visits >= 2, "I3: manager visited Meat/Deli %d times while the forklift ran" % meat_visits)
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
func pick_product(p: Node2D) -> Node2D:
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
		if not main.is_unlocked_at_pos(obj.global_position) and main._grid_cell_of(obj.global_position) != Vector2i(1, 1):
			continue
		if pick_slot(obj.global_position, obj).is_empty():
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
		stats = {"placed": 0, "hits": 0, "watched_s": 0.0, "idle_s": 0.0, "reasons": {}, "wrecks": 0, "overlap": 0, "banner_and_busy_s": 0.0, "banner_clash": 0, "first_customer_s": -1.0, "shift_len": main.shift_time_left, "grace": main._customer_grace_timer, "slip_s": 0.0}
		var start_sold: int = main._sold_at_day_start
		print("SOLO  Day %d start — %.0fs shift, sections %s, product cap %d" % [day, main.shift_time_left, str(main._unlocked_sections().map(func(s): return s["name"])), main._product_baseline()])
		await _play_shift()
		await wait_until(func(): return main.is_day_report_active(), 5.0)
		await wait(0.3)
		var sold: int = main._total_sold() - main._sold_at_day_start
		var line := "SOLO  Day %d: sold %d, place-presses %d, write-ups %d %s, forklift hits %d, rams %d, watched %.0fs, idle %.0fs, manager-inside-forklift frames %d | shift %.0fs, grace %.0fs, first customer at %.0fs | orders %d/%d filled, %d bonus sales | order banner + LOOK BUSY together %.1fs, overlapping frames %d | spills %d, slipping %.1fs, lights events %d | %s" % [day, sold, stats["placed"], main.writeups_today, str(stats["reasons"]), stats["hits"], fk().rams_today, stats["watched_s"], stats["idle_s"], stats["overlap"], stats["shift_len"], stats["grace"], stats["first_customer_s"], main.orders_filled_today, main.orders_called_today, main.priority_sales_today, stats["banner_and_busy_s"], stats["banner_clash"], main.ambience.spills_today, stats["slip_s"], main.ambience.lights_events_today, main.report_pay_label.text]
		print(line)
		day_stats.append(line)
		check(stats["banner_clash"] == 0, "Day %d: order banner never overlapped the LOOK BUSY warning / toast (%d frames)" % [day, stats["banner_clash"]])
		check(day < main.PRIORITY_ORDER_START_DAY or main.orders_called_today > 0, "Day %d: priority orders called: %d" % [day, main.orders_called_today])
		check(day >= main.PRIORITY_ORDER_START_DAY or main.orders_called_today == 0, "Day %d: no priority orders before Day %d" % [day, main.PRIORITY_ORDER_START_DAY])
		var env_day: bool = day >= main.ambience.LIGHTS_START_DAY
		check(env_day == (main.ambience.spills_today > 0 and main.ambience.lights_events_today > 0), "Day %d: spills %d, lights events %d (%s)" % [day, main.ambience.spills_today, main.ambience.lights_events_today, "Day 6+: both happen" if env_day else "none before Day 6"])
		if day != solo_days[-1]:
			main._on_continue_pressed()
	print("SOLO SUMMARY%s" % (" (careless: never dodges the forklift)" if careless else ""))
	for l in day_stats:
		print(l)
	finish()

## stop: when to hand control back (default: the shift ends).
func _play_shift(stop: Callable = func(): return not main.shift_active) -> void:
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
		for k in recent_drops.keys():
			recent_drops[k] -= dt
			if recent_drops[k] <= 0.0 or not is_instance_valid(k):
				recent_drops.erase(k)
		var pos := p.global_position
		var my_carry: Node2D = null
		for o in get_nodes_in_group("carryable"):
			if o.get_node("Carryable").carrier_id == me:
				my_carry = o
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
		if my_carry:
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
			if obj == null or not is_instance_valid(obj) or obj.get_node("Carryable").carrier_id != 0 or _is_placed(obj):
				obj = pick_product(p)
			if obj != null:
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
		if not careless and fk().active and fk().visible:
			var rel: Vector2 = pos - fk().global_position
			var heading := Vector2.RIGHT.rotated(fk().rotation)
			if fk().reversing:
				heading = -heading
			var ahead := rel.dot(heading)
			var side := rel.dot(heading.orthogonal())
			if rel.length() < 150.0 and ahead > -20.0 and absf(side) < 60.0:
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
	var grace_now: float = main._customer_grace_timer
	var clock_now: float = main.shift_time_left
	check(main.current_day == 5, "started on Day 5")

	# --- G: grace period. Existing per-section scaling intact, +15s flat on
	# top from Day 5; Days 1-4 unchanged.
	var base: float = main.CUSTOMER_GRACE_PERIOD
	var bonus: float = main.SECTION_TIME_BONUS
	var real_day: int = main.current_day
	var table := {}
	for d in range(1, 8):
		main.current_day = d
		table[d] = [main._current_customer_grace_period(), main._current_shift_duration()]
	main.current_day = real_day
	print("GRACE  day -> [grace, shift clock]: %s" % str(table))
	var sd: float = main.shift_duration
	for d in [1, 2]:
		check(is_equal_approx(table[d][0], base) and is_equal_approx(table[d][1], sd), "G: Day %d unchanged: %.0fs grace, %.0fs clock" % [d, table[d][0], table[d][1]])
	for d in [3, 4]:
		check(is_equal_approx(table[d][0], base + bonus) and is_equal_approx(table[d][1], sd + bonus), "G: Day %d unchanged: %.0fs grace, %.0fs clock" % [d, table[d][0], table[d][1]])
	for d in [5, 6]:
		check(is_equal_approx(table[d][0], base + 2 * bonus + 15.0) and is_equal_approx(table[d][1], sd + 2 * bonus + 15.0), "G: Day %d = per-section %.0fs + flat 15s: %.0fs grace, %.0fs clock" % [d, base + 2 * bonus, table[d][0], table[d][1]])
	check(is_equal_approx(table[7][0], base + 3 * bonus + 15.0), "G: Day 7 (Bakery opens) keeps both: %.0fs grace" % table[7][0])
	check(absf(grace_now - table[5][0]) < 0.5, "G: the live Day 5 shift actually started with %.1fs of grace" % grace_now)
	check(absf(clock_now - table[5][1]) < 0.5, "G: ...and %.1fs on the clock" % clock_now)

	# Test control: no auto orders, no customers buying our stock, manager
	# and forklift parked far away, player in the break room.
	main._order_timer = 1.0e9
	main._customer_grace_timer = 1.0e9
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
	check(main._order_label.visible and "Stock 3 more in Dry Goods" in main._order_label.text and "15s left" in main._order_label.text, "O1: banner: '%s'" % main._order_label.text)
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
	var lapsed := await wait_until(func(): return main.order_section == "", main.PRIORITY_ORDER_WINDOW + 1.0)
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
	main._issue_priority_order("Meat/Deli", 3)
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
	main._order_timer = 0.01
	await wait(0.1)
	check(main.order_section != "", "O4: the interval timer calls one out on its own (%s x%d)" % [main.order_section, main.order_needed])
	check(is_equal_approx(main._order_timer, main.PRIORITY_ORDER_INTERVAL) or main._order_timer > main.PRIORITY_ORDER_INTERVAL - 1.0, "O4: next call-out %.0fs later" % main._order_timer)
	main._clear_priority_order()
	main.current_day = 4
	main._order_timer = 0.01
	main._tick_priority_orders(1.0)
	check(main.order_section == "", "O4: no orders on Day 4")
	main.current_day = real_day
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
	var expect_pay: int = (main._total_sold() - main._sold_at_day_start) * main.PAY_PER_SALE + main.priority_sales_today * 5 - main.writeups_today * main.WRITEUP_PENALTY
	check(main.report_pay_label.text.begins_with("Pay Today: %s" % main._format_money(expect_pay)), "O5: report pay includes the order bonus: '%s'" % main.report_pay_label.text)
	print("REPORT  %s | %s | %s | %s" % [main.report_today_label.text, main.report_writeup_label.text, main.report_order_label.text, main.report_pay_label.text])
	await shot("o5_report")
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and main.current_day == 6, 5.0)
	check(main.current_day == 6, "O5: advanced to Day 6")
	check(absf(main._customer_grace_timer - (base + 2 * bonus + 15.0)) < 0.5, "O5: Day 6 grace %.1fs (per-section + 15)" % main._customer_grace_timer)
	check(main.orders_called_today == 0 and main.orders_filled_today == 0 and main.priority_sales_today == 0, "O5: Day 6 order tallies reset")
	check(main.priority_sales_week == week_bonus, "O5: week keeps its %d bonus sales" % main.priority_sales_week)
	check(is_equal_approx(main._order_timer, main.PRIORITY_ORDER_INTERVAL) or main._order_timer > main.PRIORITY_ORDER_INTERVAL - 1.0, "O5: first Day 6 call-out due in %.0fs" % main._order_timer)
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

const NET_DIR := "user://net_orders/"
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
	main._customer_grace_timer = 1.0e9
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
	main._customer_grace_timer = 0.0
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
	act = "client_"
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
	check(str(_net_view["orders"]) == str(hv.get("orders")), "%s: same free-play orders as the host: %s vs %s" % [who, str(_net_view["orders"]), str(hv.get("orders"))])
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
	fk()._pause_timer = 1.0e9
	pin_manager(Vector2(480, 1350), 0.0)
	main._customer_grace_timer = 1.0e9
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
	var m := {"dry_speed": 0.0, "in_speed_max": 0.0, "turn_slide": 0.0, "coast": 0.0, "through": false, "recovered": false, "dry_turn_slide": 0.0}
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
	while t < 5.0:
		await physics_frame
		t += dt
		var q: Vector2 = p.global_position
		var v := (q.x - prev.x) / dt
		prev = q
		var inside := q.distance_to(Vector2(cx, y)) < r
		inside_t = inside_t + dt if inside else 0.0
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
	check(main._watch_label.get_parent() is CanvasLayer and main._order_label.get_parent() is CanvasLayer and main.debug_label.get_parent() is CanvasLayer, "A7: HUD / LOOK BUSY / order banner are screen-space (never darkened)")
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

## From the host's samples of one remote player: [max speed over any 0.25s
## window spent entirely inside the spill, mean speed over dry-floor windows
## on the approach]. Teleports (big one-step jumps) break a window.
func _remote_speeds(samples: Array, cx: float, y: float, r: float) -> Array:
	var in_max := 0.0
	var dry := []
	var j := 0
	for i in samples.size():
		var ti: float = samples[i][0]
		while j < samples.size() and samples[j][0] - ti < 0.25:
			j += 1
		if j >= samples.size():
			break
		var ok := true
		for k in range(i + 1, j + 1):
			if samples[k][1].distance_to(samples[k - 1][1]) > 40.0:
				ok = false
				break
		if not ok:
			continue
		var a: Vector2 = samples[i][1]
		var b: Vector2 = samples[j][1]
		var v: float = a.distance_to(b) / (samples[j][0] - ti)
		var c := Vector2(cx, y)
		if a.distance_to(c) < r - 4.0 and b.distance_to(c) < r - 4.0:
			in_max = maxf(in_max, v)
		elif a.x < cx - r - 30.0 and b.x < cx - r - 30.0 and absf(a.y - y) < 3.0 and absf(b.y - y) < 3.0 and b.x > a.x + 1.0:
			dry.append(v)
	# Fastest dry window: the approach includes the start from a standstill.
	return [in_max, dry.max() if not dry.is_empty() else 0.0, dry.size()]

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
	check(main.is_finale() == (day >= main.FINALE_START_DAY) and fk().finale == main.is_finale() and mgr().finale == main.is_finale() and amb().finale == main.is_finale(), "E0 host: finale %s on every system" % ("ON" if main.is_finale() else "off"))
	park_everything()
	await wait(2.0)
	var ids: Array = main.players.keys()
	ids.sort()

	# --- E1
	var lanes := {}
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
	await wait(0.5)
	_remote_watch = false
	for id in ids:
		if id == 1:
			continue
		var y: float = lanes[str(id)]["y"]
		var rs := _remote_speeds(_remote_samples.get(id, []), lanes[str(id)]["cx"], y, E_LANE_R)
		print("NET  host's view of %s: in-spill max %.0f px/s, dry %.0f px/s (%d windows)" % [names[id], rs[0], rs[1], rs[2]])
		var top: float = player().SPEED * amb().SPILL_SPEED_FACTOR
		check(rs[0] > 80.0 and rs[0] < top * 1.12 and rs[1] > 195.0, "E1: the host SEES %s slowed on the spill (%.0f px/s in it vs %.0f dry; cap %.0f)" % [names[id], rs[0], rs[1], top])
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
	main._customer_grace_timer = 0.0
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
	_net_write("e4_host.json", {"view": _env_view, "today": main.report_today_label.text, "pay": main.report_pay_label.text})
	for id in ids:
		if id == 1:
			continue
		var r := await _net_read("e4_%d.json" % id, 60.0)
		var v: Dictionary = r.get("view", {})
		check(_same_spills(v.get("spills", {}), _env_view["spills"]), "E4: %s saw the same spills (id, spot, size): %d vs host %d" % [names[id], v.get("spills", {}).size(), _env_view["spills"].size()])
		check(str(v.get("lights")) == str(_env_view["lights"]), "E4: %s saw the same lights events %s" % [names[id], str(v.get("lights"))])
		check(v.get("inside", false) and r.get("lights_back", false), "E4: %s stayed on the map, lights back on for its report" % names[id])
		check(r.get("today", "") == main.report_today_label.text and r.get("pay", "") == main.report_pay_label.text, "E4: %s's report matches the host's: '%s' | '%s'" % [names[id], r.get("today"), r.get("pay")])
		print("NET  %s: slipping %.1fs" % [names[id], v.get("slip_s", 0.0)])

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

## Client, from connect: did the FINAL SHIFT banner ever show on this screen.
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
	act = "client_"
	var who: String = main.player_display_name(me)
	_watch_finale_banner()
	await wait_until(func(): return main.shift_active and main.current_day >= 6, 20.0)
	var day: int = main.current_day
	check(day >= 6 and amb().active, "%s: Day %d (replicated), lights/spills active" % [who, day])
	await wait(0.5)
	check(main.is_finale() == (day >= main.FINALE_START_DAY) and fk().finale == main.is_finale() and mgr().finale == main.is_finale() and amb().finale == main.is_finale(), "%s: E0 finale %s on every system, on my side" % [who, "ON" if main.is_finale() else "off"])
	if day == main.FINALE_START_DAY:
		check(_banner_seen and _banner_text == "FINAL SHIFT", "%s: E0 saw the FINAL SHIFT banner on my own screen" % who)
	else:
		check(not _banner_seen, "%s: E0 no finale banner on Day %d" % [who, day])
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
	_net_write("e1_%d.json" % me, {"m": m, "spill_ok": spill_ok})
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
	_net_write("e4_%d.json" % me, {"view": _env_view, "today": main.report_today_label.text, "pay": main.report_pay_label.text, "lights_back": amb().brightness == 1.0 and amb()._overlay.color.a == 0.0})
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
	var real_day: int = main.current_day
	for d in [1, 2, 3, 4, 5, 6]:
		main.current_day = d
		var expect_clock: float = base_shift + main._extra_day_time()
		var expect_grace: float = main.CUSTOMER_GRACE_PERIOD + main._extra_day_time()
		if main._current_shift_duration() != expect_clock or main._current_customer_grace_period() != expect_grace or main._priority_order_interval() != main.PRIORITY_ORDER_INTERVAL:
			day_numbers_ok = false
	main.current_day = real_day
	check(day_numbers_ok, "F0 Days 1-6: clock, grace and order cadence are the pre-finale numbers")
	check(is_equal_approx(main.shift_time_left + 0.0, main.shift_time_left) and main._current_shift_duration() == base_shift + 35.0 and main._current_customer_grace_period() == 44.0, "F0 Day 6: %.0fs clock, %.0fs grace" % [main._current_shift_duration(), main._current_customer_grace_period()])
	check(a.spill_cap() == a.SPILL_MAX and main._order_timer <= main.PRIORITY_ORDER_INTERVAL and main._order_timer > main.PRIORITY_ORDER_INTERVAL - 5.0, "F0 Day 6: spill cap %d, orders every %.0fs" % [a.spill_cap(), main.PRIORITY_ORDER_INTERVAL])
	check(not main._finale_banner.visible and main.finale_banner_left == 0.0, "F0 Day 6: no FINAL SHIFT banner")
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
	check(saw_banner_at_start and main._finale_banner.get_child(0).text == "FINAL SHIFT", "F1 Day 7: FINAL SHIFT banner up as the shift starts")
	check(main._current_shift_duration() == base_shift + 45.0 - main.FINALE_CLOCK_CUT and main._current_customer_grace_period() == main.CUSTOMER_GRACE_PERIOD + 45.0 - main.FINALE_GRACE_CUT, "F1 Day 7: clock %.0fs (uncut %.0f), grace %.0fs (uncut %.0f)" % [main._current_shift_duration(), base_shift + 45.0, main._current_customer_grace_period(), main.CUSTOMER_GRACE_PERIOD + 45.0])
	check(main._current_shift_duration() < base_shift + 35.0 and main._current_shift_duration() - main._current_customer_grace_period() < (base_shift + 35.0) - 44.0, "F1 Day 7: tighter than Day 6 — clock %.0f < %.0f, selling window %.0fs < %.0fs" % [main._current_shift_duration(), base_shift + 35.0, main._current_shift_duration() - main._current_customer_grace_period(), base_shift + 35.0 - 44.0])
	check(main._order_timer > main.FINALE_PRIORITY_ORDER_INTERVAL - 1.0 and main._order_timer <= main.FINALE_PRIORITY_ORDER_INTERVAL, "F1 Day 7: priority orders every %.0fs (first due in %.0fs)" % [main.FINALE_PRIORITY_ORDER_INTERVAL, main._order_timer])
	check(main.FINALE_PRIORITY_ORDER_INTERVAL > main.PRIORITY_ORDER_WINDOW + 5.0, "F1: an order is always closed before the next is due (%.0f > %.0f)" % [main.FINALE_PRIORITY_ORDER_INTERVAL, main.PRIORITY_ORDER_WINDOW])
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
	await wait_until(func(): return (Time.get_ticks_msec() - banner_start) / 1000.0 > main.FINALE_BANNER_SECONDS - 0.7, 6.0)
	check(main._finale_banner.visible and main._finale_banner.modulate.a < 1.0, "F1: banner fading in its last second (alpha %.2f)" % main._finale_banner.modulate.a)
	await wait_until(func(): return not main._finale_banner.visible, 3.0)
	var shown_for := (Time.get_ticks_msec() - banner_start) / 1000.0
	check(not main._finale_banner.visible and absf(shown_for - main.FINALE_BANNER_SECONDS) < 0.5, "F1: banner gone after %.1fs" % shown_for)

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

	# --- F3: the banner is once, not every day after.
	main.shift_time_left = 0.05
	await wait_until(func(): return main.is_day_report_active(), 5.0)
	main._on_continue_pressed()
	await wait_until(func(): return main.current_day == 8 and main.shift_active, 5.0)
	var again := await wait_until(func(): return main._finale_banner.visible, 1.5)
	check(not again and main.is_finale(), "F3 Day 8: still at finale intensity, no second banner")
	finish()
