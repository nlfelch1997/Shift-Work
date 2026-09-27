extends SceneTree
## WEEK 13 — renders real frames of the art pass (StoreArt.gd): each zone in
## scope, a whole-store overview, and (on an early day) the locked-section
## dimming on the new floors. Needs a real renderer — run under xvfb:
##   xvfb-run -a godot --path . --script res://tools/art_shots.gd -- --server --day=7
## Frames land in user://art_shots/. Not part of the game.

var main: Node

func _initialize() -> void:
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
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
	var spots := {
		"dry_goods": Vector2(1440, 300), "meat_deli": Vector2(2400, 700), "dairy_frozen": Vector2(480, 810),
		"bakery": Vector2(2400, 270), "checkout_hub": Vector2(1440, 810), "storage": Vector2(2400, 1300),
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
		var sec_shelves: Array = main.shelves.filter(func(sb): return main._grid_cell_of(sb.global_position) == sec["grid_pos"])
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
	cam.zoom = Vector2.ONE
	# Whole store: camera limits off, zoomed out, centered on the map.
	cam.limit_left = -10000
	cam.limit_top = -10000
	cam.limit_right = 10000
	cam.limit_bottom = 10000
	cam.zoom = Vector2(0.33, 0.33)
	p.teleport_to(Vector2(1440, 810))
	await shot("overview")
	quit(0)
