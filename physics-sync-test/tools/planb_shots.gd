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
	main.events_on = "--event=" in " ".join(OS.get_cmdline_user_args())
	if "--client" in OS.get_cmdline_user_args():
		_run_client.call_deferred()
	else:
		_run.call_deferred()

## --client: just a crew member for the host's clip shots (it moves where the
## host puts it), until the host says it's done.
func _run_client() -> void:
	var t := 0.0
	while t < float(_arg("--client-seconds=", "240")):
		await create_timer(1.0).timeout
		t += 1.0
		if FileAccess.file_exists(_arg("--done-file=", "user://planb_shots_done")):
			break
	quit()

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
	# --players=N: wait for the clients (tools/planb_shots.gd --client).
	var want := int(_arg("--players=", "1"))
	while main.players.size() < want:
		await physics_frame
	# --hire=all: every helper and the janitor on the books.
	if _arg("--hire=", "") == "all":
		main.staff.staff = {"Produce": {"speed": 0, "carry": 0}, "Dairy/Frozen": {"speed": 0, "carry": 0}, "Bakery": {"speed": 0, "carry": 0}, "Janitor": {"speed": 0}}
	var selling := float(_arg("--selling=", "0"))
	var stock := "--stock" in OS.get_cmdline_user_args()
	if stock:
		_restock()
		for i in 60:
			await physics_frame
	if selling > 0.0:
		main.open_store(1)
		var t := 0.0
		var k := 0
		while t < selling:
			await physics_frame
			t += 1.0 / 60.0
			k += 1
			if stock and k % 300 == 0:
				_restock()
	# --event=key: force a random event to start (Events.gd) and run 8 s.
	var ev := _arg("--event=", "")
	if ev != "":
		main.events.force_next(ev, 0.1)
		var te := 0.0
		while te < 8.0:
			await physics_frame
			te += 1.0 / 60.0
	main.debug_label.visible = false
	# --clip=x:y,...: THE CLIP TEST — the host's own camera (960 x 540, zoom 1,
	# HUD on) with every player standing round that spot, mid-shift.
	for c in _arg("--clip=", "").split(",", false):
		var f := c.split(":")
		var at := Vector2(float(f[0]), float(f[1]))
		var k := 0
		for id in main.players:
			main.players[id].rpc("teleport_to", at + Vector2(-70 + 70 * k, 30 * (k % 2)))
			k += 1
		main.status_hud = true
		for i in 45:
			await physics_frame
		var path := out_dir.path_join("shot_%s_clip_%s.png" % [tag, c.replace(":", "_")])
		root.get_texture().get_image().save_png(path)
		print("SHOT  " + path)
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
	# --buy: buy the next section now and film the wall coming down
	# (--buy-view=x:y:zoom, frames at --buy-frames=t1,t2,... seconds).
	if "--buy" in OS.get_cmdline_user_args():
		var bv := _arg("--buy-view=", "%f:%f:1" % [w.get_center().x, w.get_center().y]).split(":")
		var at := Vector2(float(bv[0]), float(bv[1]))
		var z := float(bv[2])
		var sec: Dictionary = main.next_section_for_sale()
		main.money = 100000
		if z < 0.9:
			root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
			root.size = Vector2i(int(960 * 1.25), int(540 * 1.25))
		cam.global_position = at
		cam.zoom = Vector2.ONE * z
		print("BUY %s -> %s" % [sec["name"], str(main.buy_section(sec["name"], 1))])
		var t0 := Time.get_ticks_msec()
		for ft in _arg("--buy-frames=", "0.1,0.4,0.8,1.2,2.2").split(","):
			while (Time.get_ticks_msec() - t0) / 1000.0 < float(ft):
				await process_frame
			var path := out_dir.path_join("shot_%s_buy_%s.png" % [tag, ft])
			root.get_texture().get_image().save_png(path)
			print("SHOT  " + path)
	print("SHOTS done %s" % tag)
	var df := FileAccess.open(_arg("--done-file=", "user://planb_shots_done"), FileAccess.WRITE)
	df.store_string("done")
	df.close()
	quit()

## --stock: a product on every empty slot of every open shelf (the shelves
## settle them in), so the crowd has something to buy.
func _restock() -> void:
	for sb in main.shelves:
		if not main.is_unlocked_at_pos(sb.global_position):
			continue
		var shelf: Node = sb.get_node("Shelf")
		for i in shelf.slots.size():
			if not shelf._is_filled(i):
				main.spawn_product_at(main._section_name_at(sb.global_position), shelf.slots[i].global_position)

func _shot(cam: Camera2D, name: String, at: Vector2, zoom: float) -> void:
	cam.global_position = at
	cam.zoom = Vector2.ONE * zoom
	for i in 10:
		await process_frame
	var path := out_dir.path_join("shot_%s_%s.png" % [tag, name])
	root.get_texture().get_image().save_png(path)
	print("SHOT  " + path)
