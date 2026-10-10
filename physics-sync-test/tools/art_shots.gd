extends SceneTree
## WEEK 13 — renders real frames of the art pass (StoreArt.gd): each zone in
## scope, a whole-store overview, and (on an early day) the locked-section
## dimming on the new floors. Needs a real renderer — run under xvfb:
##   xvfb-run -a godot --path . --script res://tools/art_shots.gd -- --server --day=7
## Frames land in user://art_shots/. Not part of the game.

var main: Node

## A spot in a named room of the layout table (tools/spots.gd).
func area_spot(id: String, offset := Vector2.ZERO) -> Vector2:
	return preload("res://tools/spots.gd").area_spot(main, id, offset)

func out_of_the_way(offset := Vector2.ZERO) -> Vector2:
	return preload("res://tools/spots.gd").out_of_the_way(main, offset)

func _initialize() -> void:
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	# OCT 2026 PHASE 4: random events (Events.gd) are off here — tools/events_test.gd
	# tests them; --events=on turns them on (the income runs measure both).
	main.events_on = "--events=on" in OS.get_cmdline_user_args()
	main.opening_stock_fraction = 1.0 # stocked shelves to photograph (WEEK 16: the store opens empty)
	_run.call_deferred()

func shot(name: String) -> void:
	for i in 4:
		await process_frame
	DirAccess.make_dir_recursive_absolute("user://art_shots")
	var path := "user://art_shots/day%d_%s.png" % [main.current_day, name]
	root.get_texture().get_image().save_png(path)
	print("SHOT  " + ProjectSettings.globalize_path(path))

func _run() -> void:
	var t := 0.0
	while not (main.shift_active and main.players.has(1)) and t < 20.0:
		await create_timer(0.25).timeout
		t += 0.25
	await create_timer(1.5).timeout # let the first stock spawn and settle
	var p: Node2D = main.players[1]
	var cam: Camera2D = p.get_node("Camera")
	main.debug_label.visible = false
	main.status_hud = false
	# WEEK 16 — the Store sign at the entrance, closed during prep (standing
	# at it, so the E hint shows), then open.
	p.teleport_to(main.STORE_SIGN_POS + Vector2(-20, 45))
	await shot("entrance_sign_closed")
	main.open_store(1)
	await create_timer(0.3).timeout
	await shot("entrance_sign_open")
	var spots := {
		"dry_goods": main.areas.pad_of("Dry Goods"), "meat_deli": area_spot("produce", Vector2(0, -110)), "dairy_frozen": area_spot("dairy_frozen"),
		"bakery": area_spot("bakery"), "checkout_hub": area_spot("hub"), "storage": area_spot("storage", Vector2(0, -50)),
	}
	for zone in spots:
		p.teleport_to(spots[zone])
		await shot(zone)
	# Shelf close-ups: in every section, stock two slots of one shelf
	# through the real settle check (placed exactly on the slot), leave the
	# rest empty, and frame it zoomed in.
	cam.zoom = Vector2(1.6, 1.6)
	for sec in main.SECTIONS:
		var color: Color = main.SECTION_COLORS[sec["name"]]
		var sec_shelves: Array = main.shelves.filter(func(sb): return main.areas.area_at(sb.global_position) == sec["area"])
		sec_shelves.sort_custom(func(a, b): return String(a.name) < String(b.name))
		var shelf_body: Node2D = sec_shelves[0]
		var shelf: Node = shelf_body.get_node("Shelf")
		var loose: Array = get_nodes_in_group("carryable").filter(func(o): return o.get_node("Polygon2D").color.is_equal_approx(color) and not main.shelves.any(func(sb): return sb.get_node("Shelf").contains(o)))
		for i in mini(2, loose.size()):
			var obj: RigidBody2D = loose[i]
			var at: Vector2 = shelf.slots[i].global_position
			PhysicsServer2D.body_set_state(obj.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, Transform2D(0.0, at))
			PhysicsServer2D.body_set_state(obj.get_rid(), PhysicsServer2D.BODY_STATE_LINEAR_VELOCITY, Vector2.ZERO)
			obj.global_position = at
		await create_timer(0.8).timeout
		var stocked := []
		for i in shelf.slots.size():
			stocked.append(shelf.filled[i])
		print("SHELF  %s %s: slots filled %s" % [sec["name"], shelf_body.name, str(stocked)])
		p.teleport_to(shelf_body.global_position + (shelf.slots[1].global_position - shelf_body.global_position) * 1.6)
		await shot("shelf_" + String(sec["node_name"]).to_lower())
		# And at the normal gameplay zoom — what a player actually sees.
		cam.zoom = Vector2.ONE
		await shot("shelf_" + String(sec["node_name"]).to_lower() + "_zoom1")
		cam.zoom = Vector2(1.6, 1.6)
	cam.zoom = Vector2.ONE
	# A priority order for the section that's sold as Produce since Week 13
	# #4 — the banner builds its text from the section's name.
	# PHASE 5: was `current_day >= PRIORITY_ORDER_START_DAY`, a constant the
	# Oct 2026 pivot removed (orders come with complication stage 3 now).
	if main.hazard_levels()["orders"] > 0:
		main._issue_priority_order("Produce", 3)
		p.teleport_to(area_spot("produce", Vector2(0, -110)))
		await shot("order_banner_produce")
		print("BANNER  " + main._order_label.text)
		main._clear_priority_order()
	# WEEK 15 — Storage deliveries: the truck at the dock, the delivery
	# forklift (side view loaded, front view setting down), receiving, the
	# pad mid-unpack. Frames where they happen, at gameplay zoom.
	await _delivery_shots(p, cam)
	# Whole store: camera limits off, zoomed out, centered on the map.
	cam.limit_left = -10000
	cam.limit_top = -10000
	cam.limit_right = 10000
	cam.limit_bottom = 10000
	cam.zoom = Vector2(0.33, 0.33)
	p.teleport_to(area_spot("hub"))
	await shot("overview")
	quit(0)

func _until(cond: Callable, timeout: float) -> void:
	var t := 0.0
	while not cond.call() and t < timeout:
		await physics_frame
		t += 1.0 / 60.0

func _delivery_shots(p: Node2D, cam: Camera2D) -> void:
	var d: Node = main.delivery
	var f: Node = main.delivery_forklift
	main.prep_time_left = 1.0e9
	p.teleport_to(area_spot("storage", Vector2(120, -230)))
	if not d.truck_parked():
		d._truck_state = d.TRUCK_AWAY
		d.start_delivery()
	await _until(func(): return d.truck_offset > 60.0 and d.truck_offset < 250.0, 6.0)
	await shot("storage_truck_backing_in")
	await _until(func(): return d.truck_parked(), 6.0)
	await shot("storage_truck_at_dock")
	await _until(func(): return f.carrying != "", 20.0)
	await create_timer(1.0).timeout
	await shot("storage_forklift_loaded")
	cam.zoom = Vector2(1.8, 1.8)
	p.teleport_to(f.global_position + Vector2(0, -100))
	await shot("storage_forklift_loaded_closeup")
	await _until(func(): return f.carrying != "" and f.rotation > 1.3, 12.0)
	p.teleport_to(f.global_position + Vector2(0, -60))
	await create_timer(0.4).timeout
	await shot("storage_forklift_front_view_closeup")
	cam.zoom = Vector2.ONE
	await _until(func(): return d.truck_load.is_empty() and f.carrying == "", 60.0)
	p.teleport_to(area_spot("storage", Vector2(0, -20)))
	await shot("storage_receiving")
	# WEEK 18: a pad in every section. Each open section: its box set down on
	# its pad, the unpack, and a close-up; then a box on the wrong pad.
	for sec in d.PAD_CENTERS:
		if not main.is_unlocked_at_pos(d.pad_center(sec)):
			continue
		var c: Vector2 = d.pad_center(sec)
		var tag := String(sec).to_lower().replace("/", "_").replace(" ", "_")
		p.teleport_to(c + Vector2(0, 170))
		await create_timer(0.3).timeout
		await shot("pad_%s" % tag)
		var b = await _box_for(sec) # untyped: checked with is_instance_valid() after it is freed
		if b == null:
			continue
		PhysicsServer2D.body_set_state(b.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, Transform2D(0.0, c))
		b.global_position = c
		await create_timer(0.1).timeout
		await shot("pad_%s_box_on_pad" % tag)
		await _until(func(): return not is_instance_valid(b), 2.0)
		await create_timer(0.3).timeout
		await shot("pad_%s_unpacked" % tag)
		cam.zoom = Vector2(1.6, 1.6)
		await shot("pad_%s_closeup" % tag)
		cam.zoom = Vector2.ONE
	# The wrong pad: a box for another section set down on Dry Goods'.
	var other = null
	for b in get_nodes_in_group("delivery_box"):
		if b.get_meta("section") != "Dry Goods":
			other = b
	if other != null:
		var c: Vector2 = d.pad_center("Dry Goods")
		PhysicsServer2D.body_set_state(other.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, Transform2D(0.0, c))
		other.global_position = c
		p.teleport_to(c + Vector2(0, 170))
		d._on_box_set_down(other)
		await create_timer(0.4).timeout
		await shot("pad_dry_goods_wrong_box")

## A box for `sec` — off receiving if one's there, else a fresh one on the
## next truck's worth of data (so every section gets its frame).
func _box_for(sec: String):
	for b in get_nodes_in_group("delivery_box"):
		if b.get_meta("section") == sec and not b.is_queued_for_deletion():
			return b
	main.delivery.drop_box(main.delivery.RECEIVING_SPOTS[6], sec)
	await create_timer(0.2).timeout
	for b in get_nodes_in_group("delivery_box"):
		if b.get_meta("section") == sec and not b.is_queued_for_deletion():
			return b
	return null
