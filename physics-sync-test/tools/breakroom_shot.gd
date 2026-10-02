extends SceneTree
## Renders the Break Room (grid cell 0,0) at 1:1 to user://breakroom.png:
##   xvfb-run -a godot --path . --script res://tools/breakroom_shot.gd -- --server --day=1 --no-banner
## Writes breakroom.png (the whole room), breakroom_kitchen.png and
## breakroom_photo.png (close-ups), then breakroom_coffee.png: the host at the
## machine (its prompt up), then after a cup (the cup icon, the toast).
var main: Node
func _initialize() -> void:
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	_run.call_deferred()
func _run() -> void:
	while not (main.shift_active and main.players.has(1)):
		await create_timer(0.25).timeout
	var cam := Camera2D.new()
	cam.global_position = Vector2(480, 270)
	main.add_child(cam)
	cam.make_current()
	main.debug_label.visible = false
	var alerts := main.get_node_or_null("AlertLayer")
	if alerts and "--no-banner" in OS.get_cmdline_user_args():
		alerts.visible = false
	await _save(cam, "breakroom", Vector2(480, 270), 1.0)
	# Close-ups: the kitchen run (coffee machine), the photo, the vending machine.
	await _save(cam, "breakroom_kitchen", Vector2(200, 110), 3.0)
	await _save(cam, "breakroom_photo", Vector2(560, 120), 2.5)
	var p: Node2D = main.players[1]
	p.teleport_to(Vector2(170, 110))
	await _save(cam, "breakroom_prompt", Vector2(260, 140), 2.0)
	main.break_room.try_buy_coffee()
	if alerts:
		alerts.visible = true
	await _save(cam, "breakroom_coffee", Vector2(480, 270), 1.0)
	quit()

func _save(cam: Camera2D, name: String, at: Vector2, zoom: float) -> void:
	cam.global_position = at
	cam.zoom = Vector2.ONE * zoom
	cam.limit_left = -100000
	cam.limit_top = -100000
	for i in 8:
		await process_frame
	var path := "user://%s.png" % name
	root.get_texture().get_image().save_png(path)
	print("SHOT  " + ProjectSettings.globalize_path(path))
