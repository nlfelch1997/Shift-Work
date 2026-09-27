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
	# Whole store: camera limits off, zoomed out, centered on the map.
	cam.limit_left = -10000
	cam.limit_top = -10000
	cam.limit_right = 10000
	cam.limit_bottom = 10000
	cam.zoom = Vector2(0.33, 0.33)
	p.teleport_to(Vector2(1440, 810))
	await shot("overview")
	quit(0)
