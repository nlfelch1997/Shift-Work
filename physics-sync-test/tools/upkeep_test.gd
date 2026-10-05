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

var _mode := ""

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--test="):
			_mode = a.substr(7)
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	main.opening_stock_fraction = 1.0
	main.cleanup_ceiling_override = 0.0
	match _mode:
		"customer-ride": _run_customer_ride.call_deferred()
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
