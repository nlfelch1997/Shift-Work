extends SceneTree
## PHASE 5B PART 2A — "NOTHING CHANGED" PROOF for the named-area refactor.
## Not part of the game. Written to run UNCHANGED on a pre-refactor checkout
## (clean main) and on the refactored one, so the two outputs can be diffed:
## it only calls things both versions have (Main's public position helpers —
## is_unlocked_at_pos(), _section_name_at(), is_outside_door(), ... — and the
## subsystems' own functions), never the new registry.
##
## Seeded (seed(--seed=N), default 1) and run under --fixed-fps 60, so a
## version whose game code makes the same random calls in the same order
## renders the same frames. Everything happens in PREP (store closed, no
## shoppers), the part of a shift whose frames are reproducible.
##   xvfb-run -a godot --fixed-fps 60 --path . --script res://tools/layout_proof.gd -- --server --no-save --day=1 --out=/abs/dir [--shots]
## Writes into --out:
##   probe_dN.txt  every position query on a lattice of points (+ exact cell
##                 edges), seeded spawn/spill/route rolls, Helper rooms
##   nav_dN.txt    the shopper grid, the janitor grid and each helper's grid
##                 (one row of 0/1 per grid row) — must be identical
##   tree_dN.txt   every node under Main: path, class, position, polygon,
##                 visibility (node counts included)
##   shot_dN_*.png (with --shots, needs a display: xvfb-run) the whole store,
##                 Storage, the Break Room, the HUD view, the report

var main: Node
var out_dir := ""
var day := 1
var tag := ""
var lines: PackedStringArray = []

func _initialize() -> void:
	var s := 1
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			s = int(a.substr(7))
		if a.begins_with("--out="):
			out_dir = a.substr(6)
		if a.begins_with("--day="):
			day = int(a.substr(6))
		if a.begins_with("--tag="):
			tag = a.substr(6)
	if tag == "":
		tag = "d%d" % day
	seed(s)
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	main.events_on = false
	_run.call_deferred()

func _frames(n: int) -> void:
	for i in n:
		await physics_frame

func _run() -> void:
	while not (main.shift_active and main.players.has(1)):
		await physics_frame
	await _frames(120) # products spawned and settled, still prep
	_probe()
	_write("probe_%s.txt" % tag)
	_nav()
	_write("nav_%s.txt" % tag)
	_tree(main, "")
	_write("tree_%s.txt" % tag)
	if "--shots" in OS.get_cmdline_user_args():
		await _shots()
	print("PROOF done %s" % tag)
	quit()

func _write(name: String) -> void:
	var f := FileAccess.open(out_dir.path_join(name), FileAccess.WRITE)
	f.store_string("\n".join(lines) + "\n")
	f.close()
	print("PROOF wrote %s (%d lines)" % [name, lines.size()])
	lines = PackedStringArray()

func _v(p: Vector2) -> String:
	return "(%.2f,%.2f)" % [p.x, p.y]

## --- the lattice probe -------------------------------------------------------

func _axis(lo: float, hi: float, edges: Array) -> Array:
	var out := []
	var x := lo
	while x <= hi:
		out.append(x)
		x += 20.0
	for e in edges:
		out.append(e - 0.25)
		out.append(e + 0.25)
	out.sort()
	return out

func _probe() -> void:
	var xs := _axis(-40.0, 2920.0, [0.0, 960.0, 1920.0, 2880.0, 1320.0, 1560.0, 2150.0])
	var ys := _axis(-40.0, 1660.0, [0.0, 540.0, 1080.0, 1620.0, 1104.0, 1150.0, 1510.0])
	var cl: Node = main.cleanup
	var jan: Node = main.staff.janitor
	var helpers: Dictionary = main.staff.helpers
	lines.append("sections_owned=%d tutorial=%s" % [main.sections_owned, str(main.tutorial.active)])
	for sec in helpers:
		var h: Node = helpers[sec]
		lines.append("HELPER %s room=%s home=%s region=%s offset=%s" % [sec, str(h._room), _v(h.home()), str(h._astar.region), _v(h._astar.offset)])
	for y in ys:
		for x in xs:
			var p := Vector2(x, y)
			var hr := ""
			for sec in helpers:
				hr += "1" if helpers[sec].in_room(p) else "0"
			lines.append("%s sec=%s un=%d br=%d st=%d door=%d oob=%d lit=%d jz=%d gate=%s hr=%s" % [
				_v(p), main._section_name_at(p), int(main.is_unlocked_at_pos(p)), int(main.is_break_room_at_pos(p)),
				int(main.is_storage_at_pos(p)), int(main.is_outside_door(p)), int(main._is_out_of_bounds(p)),
				int(cl._litter_zone_ok(p)), int(jan._reachable_zone(p)), main.for_sale_gate_at(p), hr])
	# Seeded rolls: the same random draws must land on the same spots.
	for k in 40:
		for section in main.SECTIONS:
			seed(1000 + k)
			lines.append("SPAWN %s %d %s" % [section["name"], k, _v(main._spawn_pos_in_section(section))])
		seed(2000 + k)
		lines.append("ENTRANCE %d %s" % [k, _v(main._store_entrance_pos())])
		seed(3000 + k)
		lines.append("SPILL %d %s" % [k, str(main.ambience.pick_spill_spot())])
		for sec in main.delivery.PAD_CENTERS:
			seed(4000 + k)
			lines.append("PADSPILL %s %d %s" % [sec, k, _v(main.delivery._spill_spot(sec, []))])
	# The manager's rounds (every section, both entry states of the forklift).
	var m: Node = main.manager
	for k in 24:
		seed(5000 + k)
		m._legs = []
		m._last_section = ""
		m._plan_visit(main)
		lines.append("MGR %d %s" % [k, ", ".join(m._legs.map(func(l): return "%s/%.2f" % [_v(l["pos"]), l.get("pause", 0.0)]))])
	# The Produce forklift's lap (stations, ends) from its lane.
	var fk: Node = main.forklift
	for k in 6:
		seed(6000 + k)
		fk._legs = []
		fk._build_lap()
		lines.append("LAP %d %s" % [k, ", ".join(fk._legs.map(func(l): return "%s %s %s %s" % [_v(l.get("pos", Vector2.INF)), l.get("mode", ""), l.get("pause", 0.0), l["shelf"].name if l.has("shelf") else str(l.get("end", ""))]))])
	# Fixed anchors the systems hold (their values, wherever they now come from).
	var d: Node = main.delivery
	lines.append("PADS %s" % str(d.PAD_CENTERS))
	lines.append("RECEIVING %s" % str(d.RECEIVING_SPOTS))
	lines.append("DOCK lane=%.1f dock=%.1f home=%s" % [d.LANE_Y, d.DOCK_X, _v(d.FORKLIFT_HOME)])
	lines.append("BINS %s" % str(cl.BINS))
	lines.append("CANS %s" % str(cl.cans))
	lines.append("DUMPSTER %s STATION %s RACK %s TOOLS %s DOOR %s" % [_v(cl.DUMPSTER_POS), _v(cl.STATION_POS), _v(cl.RACK_POS), str(cl.TOOL_SPOTS), _v(cl.FRONT_DOOR)])
	lines.append("JANITOR home=%s keepout=%s" % [_v(jan.home()), str(preload("res://CustomerNav.gd").JANITOR_KEEP_OUT)])
	lines.append("SIGN %s CLOCK %s SPAWN %s" % [_v(main.STORE_SIGN_POS), _v(main.TIME_CLOCK_POS), _v(main.SPAWN_CENTER)])
	lines.append("CASHIERS active=%d %s" % [main._active_cashier_count(), str(main.cashiers.map(func(c): return _v(c.global_position)))])
	var cam: Camera2D = _player_cam()
	lines.append("CAMERA limits=%d,%d,%d,%d" % [cam.limit_left, cam.limit_top, cam.limit_right, cam.limit_bottom])
	lines.append("FORKLIFT home=%s" % _v(fk.home_position))
	lines.append("HAZARDS %s" % str(main.hazard_levels()))
	var acc := []
	for sb in main.shelves:
		acc.append("%s:%s:%s" % [sb.name, str(sb.get_node("Shelf").accent_color), str(sb.modulate)])
	lines.append("SHELVES %s" % ", ".join(acc))
	lines.append("FILL %.4f OPEN_SLOTS %s" % [main.open_shelf_fill(), str(main.SECTIONS.map(func(s): return main._open_slots_in_section(s)))])
	lines.append("STOCKED %s" % str(main.stocked_units_by_section()))

## --- the nav grids -----------------------------------------------------------

func _grid_rows(astar: AStarGrid2D) -> void:
	var r := astar.region
	lines.append("region=%s offset=%s" % [str(r), _v(astar.offset)])
	for y in range(r.position.y, r.end.y):
		var row := ""
		for x in range(r.position.x, r.end.x):
			row += "1" if astar.is_point_solid(Vector2i(x, y)) else "0"
		lines.append(row)

func _nav() -> void:
	var NavScript := preload("res://CustomerNav.gd")
	for jan in [false, true]:
		var n = NavScript.new(main)
		n.for_janitor = jan
		n._build()
		lines.append("NAV janitor=%s" % str(jan))
		_grid_rows(n._astar)
	for sec in main.staff.helpers:
		var h: Node = main.staff.helpers[sec]
		h._plan(h.home())
		lines.append("HELPERNAV %s" % sec)
		_grid_rows(h._astar)

## --- the scene tree ----------------------------------------------------------

func _tree(n: Node, path: String) -> void:
	var p := path + "/" + n.name
	var bits := n.get_class()
	if n is Node2D:
		bits += " pos=%s rot=%.3f" % [_v(n.global_position), n.global_rotation]
	if n is CanvasItem:
		bits += " vis=%d mod=%s" % [int(n.visible), str(n.modulate)]
	if n is Polygon2D:
		bits += " poly=%s col=%s tex=%s" % [str(n.polygon), str(n.color), str(n.texture.get_size()) if n.texture else "-"]
	if n is Label:
		bits += " text=%s" % n.text.c_escape()
	if n is CollisionShape2D and n.shape is RectangleShape2D:
		bits += " rect=%s dis=%d" % [str(n.shape.size), int(n.disabled)]
	lines.append(p + " " + bits)
	for c in n.get_children():
		_tree(c, p)

func _player_cam() -> Camera2D:
	for c in main.players[1].get_children():
		if c is Camera2D:
			return c
	return null

## --- screenshots -------------------------------------------------------------

func _shots() -> void:
	main.debug_label.visible = false
	var cam := Camera2D.new()
	main.add_child(cam)
	cam.limit_left = -100000
	cam.limit_top = -100000
	main.status_hud = false
	var alerts := main.get_node_or_null("AlertLayer")
	if alerts:
		alerts.visible = false
	cam.make_current()
	# The whole 2880x1620 store at half size (content scaling off, or the
	# window's canvas_items stretch keeps showing a 960x540 world area).
	var mode := root.content_scale_mode
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = Vector2i(1440, 810)
	await _shot(cam, "store", Vector2(1440, 810), 0.5)
	root.content_scale_mode = mode
	root.size = Vector2i(960, 540)
	await _shot(cam, "storage", Vector2(2400, 1350), 1.0)
	await _shot(cam, "breakroom", Vector2(480, 270), 1.0)
	# The HUD as a player sees it: their own camera, status line and banners on.
	if alerts:
		alerts.visible = true
	main.status_hud = true
	cam.queue_free()
	_player_cam().make_current()
	main.players[1].teleport_to(Vector2(1440, 700))
	await _shot(null, "hud", Vector2.ZERO, 1.0)
	main.shift_time_left = 0.01
	while not main.is_day_report_active():
		await physics_frame
	await _shot(null, "report", Vector2.ZERO, 1.0)

func _shot(cam: Camera2D, name: String, at: Vector2, zoom: float) -> void:
	if cam:
		cam.global_position = at
		cam.zoom = Vector2.ONE * zoom
	for i in 10:
		await process_frame
	var path := out_dir.path_join("shot_%s_%s.png" % [tag, name])
	root.get_texture().get_image().save_png(path)
	print("SHOT  " + path)
