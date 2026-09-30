extends SceneTree
## Renders the whole store in one frame (user://overview.png):
##   xvfb-run -a godot --path . --script res://tools/overview_shot.gd -- --server --day=7
var main: Node
func _initialize() -> void:
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	_run.call_deferred()
func _run() -> void:
	while not (main.shift_active and main.players.has(1)):
		await create_timer(0.25).timeout
	root.size = Vector2i(1440, 810)
	var cam := Camera2D.new()
	cam.zoom = Vector2(0.5, 0.5)
	cam.global_position = Vector2(main.WORLD_WIDTH, main.WORLD_HEIGHT) * 0.5
	main.add_child(cam)
	cam.make_current()
	main.debug_label.visible = false
	for i in 8:
		await process_frame
	root.get_texture().get_image().save_png("user://overview.png")
	print("SHOT  " + ProjectSettings.globalize_path("user://overview.png"))
	quit()
