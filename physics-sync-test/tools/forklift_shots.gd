extends SceneTree
## WEEK 19 — renders the Produce (hazard) forklift and the Storage delivery
## forklift in each facing, to check they wear the same pack sprite:
##   xvfb-run -a godot --path . --script res://tools/forklift_shots.gd -- --server --day=3
## Frames land in user://forklift_shots/. Not part of the game.

var main: Node

func _initialize() -> void:
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	# OCT 2026 PHASE 4: random events (Events.gd) are off here — tools/events_test.gd
	# tests them; --events=on turns them on (the income runs measure both).
	main.events_on = "--events=on" in OS.get_cmdline_user_args()
	_run.call_deferred()

func _run() -> void:
	var t := 0.0
	while not (main.shift_active and main.players.has(1)) and t < 20.0:
		await create_timer(0.25).timeout
		t += 0.25
	await create_timer(0.5).timeout
	var p: Node2D = main.players[1]
	# Own camera, no room limits, so each forklift sits dead center.
	var cam := Camera2D.new()
	cam.zoom = Vector2(2.5, 2.5)
	main.add_child(cam)
	cam.make_current()
	main.debug_label.visible = false
	main.status_hud = false
	DirAccess.make_dir_recursive_absolute("user://forklift_shots")
	for f in [main.forklift, main.delivery_forklift]:
		# Freeze it in place (the delivery one drives during prep).
		f.set_physics_process(false)
		for facing in [["west", PI], ["east", 0.0], ["south", PI / 2.0], ["north", -PI / 2.0]]:
			f.rotation = facing[1]
			cam.global_position = f.global_position + Vector2(0, -20)
			cam.reset_smoothing()
			for i in 6:
				await process_frame
			var path := "user://forklift_shots/%s_%s.png" % [f.name, facing[0]]
			root.get_texture().get_image().save_png(path)
			print("SHOT  " + ProjectSettings.globalize_path(path))
	quit()
