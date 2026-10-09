extends SceneTree
## Renders the Break Room (grid cell 0,0) at 1:1 to user://breakroom.png:
##   xvfb-run -a godot --path . --script res://tools/breakroom_shot.gd -- --server --day=1 --no-banner
## Writes breakroom.png (the whole room), breakroom_kitchen.png and
## breakroom_photo.png (close-ups), then breakroom_coffee.png: the host at the
## machine (its prompt up), then after a cup (the cup icon, the toast).
var main: Node

## PHASE 5B PART 2A: a spot in a named room of the layout table — its centre,
## plus an offset — so a test says WHICH room it means instead of repeating
## raw world coordinates (main.areas; StoreLayout.gd).
func area_spot(id: String, offset := Vector2.ZERO) -> Vector2:
	return main.areas.center_of(id) + offset

func _initialize() -> void:
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	# OCT 2026 PHASE 4: random events (Events.gd) are off here — tools/events_test.gd
	# tests them; --events=on turns them on (the income runs measure both).
	main.events_on = "--events=on" in OS.get_cmdline_user_args()
	_run.call_deferred()
func _run() -> void:
	while not (main.shift_active and main.players.has(1)):
		await create_timer(0.25).timeout
	var cam := Camera2D.new()
	cam.global_position = area_spot("break_room")
	main.add_child(cam)
	cam.make_current()
	main.debug_label.visible = false
	main.status_hud = false
	var alerts := main.get_node_or_null("AlertLayer")
	if alerts and "--no-banner" in OS.get_cmdline_user_args():
		alerts.visible = false
	await _save(cam, "breakroom", area_spot("break_room"), 1.0)
	# Close-ups: the kitchen run (coffee machine), the photo, the vending machine.
	await _save(cam, "breakroom_kitchen", area_spot("break_room", Vector2(-280, -160)), 3.0)
	await _save(cam, "breakroom_photo", area_spot("break_room", Vector2(80, -150)), 2.5)
	var p: Node2D = main.players[1]
	p.teleport_to(area_spot("break_room", Vector2(-310, -160)))
	await _save(cam, "breakroom_prompt", area_spot("break_room", Vector2(-220, -130)), 2.0)
	main.break_room.try_buy_coffee()
	if alerts:
		alerts.visible = true
	await _save(cam, "breakroom_coffee", area_spot("break_room"), 1.0)
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
