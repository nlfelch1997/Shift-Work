extends SceneTree
## PHASE 5B PART 2B — screenshots of the Plan B store (greybox), for the
## report and for looking at a layout change. Not part of the game. Needs a
## display (xvfb-run). Seeded; stays in prep (store closed) unless --selling.
##   xvfb-run -a godot --path . --script res://tools/planb_shots.gd -- --server --no-save --port=9330 --day=7 --out=/abs/dir --tag=d7 [--selling=40] [--views=name:x:y:zoom,...] [--hud]
## Writes shot_<tag>_store.png (the whole world at a scale that fits 1200 px
## wide) and shot_<tag>_<name>.png for each --views entry (a 960 x 540 view,
## like a player's camera, at that zoom).

var main: Node
var out_dir := ""
var tag := "shot"
var views := []

func _initialize() -> void:
	seed(1)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
		elif a.begins_with("--tag="):
			tag = a.substr(6)
		elif a.begins_with("--views="):
			for v in a.substr(8).split(",", false):
				var f := v.split(":")
				views.append([f[0], Vector2(float(f[1]), float(f[2])), float(f[3]) if f.size() > 3 else 1.0])
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	main.events_on = false
	_run.call_deferred()

func _arg(prefix: String, dflt: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return a.substr(prefix.length())
	return dflt

func _run() -> void:
	while not (main.shift_active and main.players.has(1)):
		await physics_frame
	for i in 120:
		await physics_frame
	var selling := float(_arg("--selling=", "0"))
	if selling > 0.0:
		main.open_store(1)
		var t := 0.0
		while t < selling:
			await physics_frame
			t += 1.0 / 60.0
	main.debug_label.visible = false
	var hud := "--hud" in OS.get_cmdline_user_args()
	main.status_hud = hud
	var alerts := main.get_node_or_null("AlertLayer")
	if alerts:
		alerts.visible = hud
	var cam := Camera2D.new()
	main.add_child(cam)
	cam.limit_left = -100000
	cam.limit_top = -100000
	cam.make_current()
	var w: Rect2 = main.areas.world_rect()
	var mode := root.content_scale_mode
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var k := 1200.0 / w.size.x
	root.size = Vector2i(int(w.size.x * k), int(w.size.y * k))
	await _shot(cam, "store", w.get_center(), k)
	root.content_scale_mode = mode
	root.size = Vector2i(960, 540)
	for v in views:
		await _shot(cam, v[0], v[1], v[2])
	print("SHOTS done %s" % tag)
	quit()

func _shot(cam: Camera2D, name: String, at: Vector2, zoom: float) -> void:
	cam.global_position = at
	cam.zoom = Vector2.ONE * zoom
	for i in 10:
		await process_frame
	var path := out_dir.path_join("shot_%s_%s.png" % [tag, name])
	root.get_texture().get_image().save_png(path)
	print("SHOT  " + path)
