extends "res://tools/hazards_test.gd"
## PHASE 5B PART 2A — guards for the named-area registry (Areas.gd reading
## StoreLayout.gd). Not part of the game. Real wall-clock time (nothing here
## is timing-sensitive).
##
##   --test=snapshot      the registry's dump of the layout table must equal
##                        tools/areas_snapshot.txt (today's store). A change
##                        to the layout is deliberate: re-run with --write
##                        and commit the new snapshot with it. Also checks the
##                        table against itself and against Main.tscn: rooms
##                        tile the world, the index agrees with a plain scan,
##                        every section, pad, can, gate, shelf and register
##                        sits where the table says.
##   --test=net           host + clients: every peer hashes the registry's
##                        answers (area_at, section_of, open state, ...) on a
##                        lattice of points at five moments of a shift — prep,
##                        just after a purchase, selling, the report, the next
##                        prep — and the host checks every client's hash equals
##                        its own (same answers, no new network state: they
##                        come from the replicated sections_owned alone).
##   --test=no-cell-math  scans every game script (res://*.gd — not tools/)
##                        for the screen-cell arithmetic the registry replaced
##                        (960/540 cells, ROOM_WIDTH, _grid_cell_of, grid_pos,
##                        *_GRID_POS ...) so it can't creep back in.
##   godot --headless --path . --script res://tools/areas_test.gd -- --server --no-save --test=snapshot [--write]
##   godot --headless --path . --script res://tools/areas_test.gd -- --test=no-cell-math
##   godot --headless --path . --script res://tools/areas_test.gd -- --server --players=3 --no-save --money=5000 --test=net
##   (x2) godot --headless --path . --script res://tools/areas_test.gd -- --client --no-save --test=net

const SNAPSHOT := "res://tools/areas_snapshot.txt"
const Layout := preload("res://StoreLayout.gd")

var _mode := ""

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--test="):
			_mode = a.substr(7)
	match _mode:
		"snapshot":
			main = load("res://Main.tscn").instantiate()
			root.add_child(main)
			current_scene = main
			main.events_on = false
			_run_snapshot.call_deferred()
		"no-cell-math":
			_run_scan.call_deferred()
		"net":
			main = load("res://Main.tscn").instantiate()
			root.add_child(main)
			current_scene = main
			main.events_on = false
			main.cleanup_ceiling_override = 0.0
			(_run_net_client if "--client" in OS.get_cmdline_user_args() else _run_net_host).call_deferred()
		_:
			print("FAIL  unknown --test=%s" % _mode)
			quit(1)

## --- SNAPSHOT ---------------------------------------------------------------

func _run_snapshot() -> void:
	while not (main.shift_active and main.players.has(1)):
		await physics_frame
	var areas: RefCounted = main.areas
	var dump: String = areas.snapshot()
	if "--write" in OS.get_cmdline_user_args():
		var f := FileAccess.open(SNAPSHOT, FileAccess.WRITE)
		f.store_string(dump)
		f.close()
		print("INFO  wrote %s" % SNAPSHOT)
	var saved := FileAccess.get_file_as_string(SNAPSHOT)
	check(saved == dump, "S1: the registry's dump of the layout table equals %s (re-run with --write after a deliberate layout change)" % SNAPSHOT)
	if saved != dump:
		var a := saved.split("\n")
		var b := dump.split("\n")
		for i in maxi(a.size(), b.size()):
			var x: String = a[i] if i < a.size() else "<none>"
			var y: String = b[i] if i < b.size() else "<none>"
			if x != y:
				print("INFO  first difference, line %d:\n  saved: %s\n  now:   %s" % [i + 1, x, y])
				break
	_check_table(areas)
	_check_scene(areas)
	finish()

func _check_table(areas: RefCounted) -> void:
	var world: Rect2 = areas.world_rect()
	# S2: the rooms tile the world — no gaps, no overlaps (every 20 px cell
	# centre is in exactly one room) — and stay inside it.
	var gaps := 0
	var overlaps := 0
	var y := 10.0
	while y < world.end.y:
		var x := 10.0
		while x < world.end.x:
			var n := 0
			for id in areas.room_ids():
				if areas.in_area(id, Vector2(x, y)):
					n += 1
			if n == 0:
				gaps += 1
			elif n > 1:
				overlaps += 1
			x += 20.0
		y += 20.0
	var inside: bool = areas.room_ids().all(func(id): return world.encloses(areas.rect_of(id)))
	check(gaps == 0 and overlaps == 0 and inside, "S2: the rooms tile the world exactly (gaps %d, overlaps %d, all inside %s)" % [gaps, overlaps, str(inside)])
	# S3: area_at()'s index agrees with a plain scan of the rooms, on and off
	# every edge (a few thousand points, outside the world too).
	var bad := 0
	var probes := 0
	for id in areas.room_ids():
		var r: Rect2 = areas.rect_of(id)
		for px in [r.position.x - 0.25, r.position.x, r.position.x + 0.25, r.get_center().x, r.end.x - 0.25, r.end.x, r.end.x + 0.25]:
			for py in [r.position.y - 0.25, r.position.y, r.position.y + 0.25, r.get_center().y, r.end.y - 0.25, r.end.y, r.end.y + 0.25]:
				var p := Vector2(px, py)
				var want := ""
				for j in areas.room_ids():
					if areas.in_area(j, p):
						want = j
						break
				probes += 1
				if areas.area_at(p) != want:
					bad += 1
	check(bad == 0, "S3: area_at() agrees with a plain scan of the rooms at %d edge points (%d wrong)" % [probes, bad])
	# S4: links are listed both ways and name real rooms.
	var one_way := []
	for id in areas.room_ids():
		for n in areas.area(id).get("links", []):
			if not areas.has_area(n) or not id in areas.area(n).get("links", []):
				one_way.append("%s->%s" % [id, n])
	check(one_way.is_empty(), "S4: every link between rooms is listed both ways %s" % str(one_way))
	# S5: every feature sits inside the room it names.
	var stray := []
	for id in Layout.FEATURES.map(func(f): return f["id"]):
		var f: Dictionary = areas.area(id)
		if not areas.rect_of(f["room"]).encloses(areas.rect_of(id)):
			stray.append(id)
	check(stray.is_empty(), "S5: every feature lies inside its room %s" % str(stray))

func _check_scene(areas: RefCounted) -> void:
	# S6: every section has a room of role "section" naming it, and back.
	var ok := true
	for s in main.SECTIONS:
		ok = ok and areas.role_of(s["area"]) == "section" and areas.area(s["area"])["section"] == s["name"] and areas.room_of_section(s["name"]) == s["area"]
	check(ok and areas.ids_with_role("section").size() == main.SECTIONS.size(), "S6: each of the %d sections has its own section room in the table" % main.SECTIONS.size())
	# S7: every shelf stands in a section room; each section has the shelves
	# it always had (6/5/5/5).
	var per := {}
	for sb in main.shelves:
		var sec: String = areas.section_of(sb.global_position)
		per[sec] = int(per.get(sec, 0)) + 1
	check(per == {"Dry Goods": 6, "Produce": 5, "Dairy/Frozen": 5, "Bakery": 5}, "S7: shelves per section from the table: %s" % str(per))
	# S8: pads and cans: one pad per section, inside its room; five cans in
	# save order (hub, Dry Goods, Produce, Dairy/Frozen, Bakery), each in the
	# room it serves (the hub's, or its section's doorway inside the hub or
	# the section).
	var pads_ok := true
	for s in main.SECTIONS:
		pads_ok = pads_ok and areas.section_of(main.delivery.pad_center(s["name"])) == s["name"]
	check(pads_ok and Layout.PADS.size() == main.SECTIONS.size(), "S8: one unpack pad per section, inside that section's room")
	var order: Array = Layout.CANS.map(func(c): return c["section"])
	check(order == ["", "Dry Goods", "Produce", "Dairy/Frozen", "Bakery"] and main.cleanup.BINS == Layout.CANS and main.cleanup.cans.size() == 5,
		"S9: 5 trash cans in save order %s (v6 saves store fills by index)" % str(order))
	var can_rooms: Array = Layout.CANS.map(func(c): return areas.area_at(c["pos"]))
	check(can_rooms[0] == "hub" and can_rooms.slice(1).all(func(r): return r == "hub" or areas.role_of(r) == "section"), "S10: the cans stand on the sales floor %s" % str(can_rooms))
	# S11: every barrier piece (PHASE 5B PART 2B: several per section, built
	# from the table) lies on an edge of its section's room, and each section
	# but the first has one.
	var gates_ok := true
	var bad_g := []
	for g in main.get_node("Gates").get_children():
		var sec: String = g.get_node("Gate").section
		var r: Rect2 = areas.rect_of(areas.room_of_section(sec))
		var p: Vector2 = g.global_position
		var on_v: bool = (is_equal_approx(p.x, r.position.x) or is_equal_approx(p.x, r.end.x)) and p.y > r.position.y and p.y < r.end.y
		var on_h: bool = (is_equal_approx(p.y, r.position.y) or is_equal_approx(p.y, r.end.y)) and p.x > r.position.x and p.x < r.end.x
		if not (on_v or on_h):
			gates_ok = false
			bad_g.append(String(g.name))
	for i in range(1, main.SECTIONS.size()):
		gates_ok = gates_ok and main.gate_of(main.SECTIONS[i]["name"]) != null
	check(gates_ok and main.get_node("Gates").get_child_count() == Layout.BARRIERS.size(), "S11: every barrier piece stands on its section room's edge (%d pieces) %s" % [main.get_node("Gates").get_child_count(), str(bad_g)])
	# S11b: the walls in the scene are the table's, one body each.
	check(main.get_node("Walls").get_child_count() == Layout.WALLS.size(), "S11b: %d wall bodies built from the table's %d walls" % [main.get_node("Walls").get_child_count(), Layout.WALLS.size()])
	# S12: the registers are in the checkout's room, and each queue runs the
	# way the table says (Cashier.tscn's Queue* markers).
	var q_dir: Vector2 = Layout.CHECKOUT["queue_dir"]
	var reg_ok: bool = main.cashiers.size() == Layout.CHECKOUT["registers_by_tier"][-1]
	for c in main.cashiers:
		reg_ok = reg_ok and areas.area_at(c.global_position) == Layout.CHECKOUT["room"]
		var slots: Array = c.get_node("Cashier").queue_slots
		var prev: Vector2 = c.get_node("Checkout").global_position
		for m in slots:
			var step: Vector2 = (m.global_position - prev)
			reg_ok = reg_ok and step.length() > 1.0 and step.normalized().dot(q_dir) > 0.99
			prev = m.global_position
	check(reg_ok, "S12: %d registers in the %s, every queue running %s" % [main.cashiers.size(), Layout.CHECKOUT["room"], str(q_dir)])
	check(main.CASHIER_COUNT_BY_TIER == Layout.CHECKOUT["registers_by_tier"], "S13: open registers by tier come from the table %s" % str(main.CASHIER_COUNT_BY_TIER))
	# S14: the floors: each RoomBackgrounds polygon is centred in the room
	# the table says it floors.
	var bg_ok := true
	for id in areas.room_ids():
		var bg: Node2D = main.get_node_or_null("RoomBackgrounds/" + areas.area(id).get("bg", ""))
		bg_ok = bg_ok and bg != null and areas.area_at(bg.position) == id
	check(bg_ok, "S14: every room's floor polygon sits in that room")
	# S15: the camera can see the whole world and no more.
	var cam: Camera2D = main.players[1].get_node("Camera")
	var w: Rect2 = areas.world_rect()
	check(Rect2(cam.limit_left, cam.limit_top, cam.limit_right - cam.limit_left, cam.limit_bottom - cam.limit_top) == w, "S15: camera limits = the world %s" % str(w))
	# S16: open state follows the sections (and the signals fire once each).
	var opened := []
	areas.area_opened.connect(func(id): opened.append(id))
	var before: int = main.sections_owned
	main.sections_owned = 2
	main._reconfigure_world()
	check(opened == ["produce", "produce_forklift_lane"] and areas.is_open("produce") and not areas.is_open("dairy_frozen") and not areas.is_open("bakery") and areas.is_open("hub") and areas.is_open("dry_goods"),
		"S16: buying Produce opens its room and its forklift lane (area_opened %s), Dairy and Bakery stay shut, the shop is always open" % str(opened))
	main.sections_owned = before
	main._reconfigure_world()

## --- NET: the same answers on every peer ------------------------------------

## Every answer the registry (and Main's wrappers over it) gives, over a
## lattice of points and every area, as one digest.
func _answers() -> String:
	var areas: RefCounted = main.areas
	var out := PackedStringArray()
	out.append("owned=%d" % main.sections_owned)
	for id in areas.room_ids() + Layout.FEATURES.map(func(f): return f["id"]):
		out.append("%s:%s" % [id, str(areas.is_open(id))])
	var wr: Rect2 = areas.world_rect()
	var y := wr.position.y - 30.0
	while y < wr.end.y + 40.0:
		var x := wr.position.x - 30.0
		while x < wr.end.x + 40.0:
			var p := Vector2(x, y)
			out.append("%s|%s|%s|%d%d%d%d%d%d" % [areas.area_at(p), areas.section_of(p), areas.feature_at(p, "exit"),
				int(areas.is_section_open_at(p)), int(areas.is_open_shop_floor_at(p)), int(areas.shoppers_allowed_at(p)),
				int(main.is_unlocked_at_pos(p)), int(main.is_break_room_at_pos(p)), int(main.is_storage_at_pos(p))])
			x += 30.0
		y += 30.0
	return "\n".join(out).md5_text()

const NET_PHASES := ["prep", "bought", "selling", "report", "next_prep"]

func _run_net_host() -> void:
	var want := 3
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--players="):
			want = int(a.substr(10))
	await wait_until(func(): return main.players.size() >= want and main.shift_active, 60.0)
	check(main.players.size() >= want, "NA0: %d players in (want %d)" % [main.players.size(), want])
	for phase in NET_PHASES:
		match phase:
			"bought":
				main.money = 5000
				check(main.buy_section("Produce", 1), "NA1: the host buys Produce at prep")
			"selling":
				main.open_store(1)
				await wait(20.0)
			"report":
				main.shift_time_left = 0.01
				await wait_until(func(): return main.is_day_report_active(), 30.0)
			"next_prep":
				main._on_continue_pressed()
				await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 30.0)
		await wait(1.0)
		var mine := _answers()
		_net_write("areas_%s.json" % phase, {"owned": main.sections_owned, "hash": mine})
		var same := 0
		for id in main.players:
			if id == 1:
				continue
			var r := await _net_read("areas_%s_%d.json" % [phase, id], 60.0)
			if r.get("hash", "") == mine:
				same += 1
			else:
				print("INFO  %s: client %d hash %s (owned %s) vs host %s" % [phase, id, r.get("hash", "none"), str(r.get("owned", "?")), mine])
		check(same == main.players.size() - 1, "NA-%s: every client's registry answers match the host's (%d/%d, %d sections owned)" % [phase, same, main.players.size() - 1, main.sections_owned])
	_net_write("areas_done.json", {"done": true})
	for id in main.players: # (let every client report before the host leaves)
		if id != 1:
			await _net_read("areas_bye_%d.json" % id, 60.0)
	await wait(1.0)
	finish()

func _run_net_client() -> void:
	await wait_until(func(): return main.shift_active and main.multiplayer.get_unique_id() != 1, 60.0)
	var me_id: int = main.multiplayer.get_unique_id()
	for phase in NET_PHASES:
		var h := await _net_read("areas_%s.json" % phase, 240.0)
		# Wait for the replicated state the host was in (sections owned).
		await wait_until(func(): return main.sections_owned == int(h.get("owned", -1)), 20.0)
		await wait(0.5)
		var mine := _answers()
		_net_write("areas_%s_%d.json" % [phase, me_id], {"owned": main.sections_owned, "hash": mine})
		check(mine == h.get("hash", ""), "NA-%s: this client's registry answers match the host's" % phase)
	await _net_read("areas_done.json", 120.0)
	print("RESULT: %s (%d failure%s)" % ["OK" if fails == 0 else "FAILED", fails, "" if fails == 1 else "s"])
	_net_write("areas_bye_%d.json" % me_id, {"fails": fails})
	quit(1 if fails else 0) # (the host leaves once every client has said bye)

## --- NO CELL MATH -----------------------------------------------------------

## Patterns the registry replaced. Checked against code only (comments and
## strings are dropped first), in every game script except the table itself
## and the registry (Areas.gd's own 20 px lookup index is the one place that
## divides positions into cells).
const BANNED := [
	["ROOM_WIDTH / ROOM_HEIGHT", "\\bROOM_(WIDTH|HEIGHT)\\b"],
	["GRID_COLS / GRID_ROWS", "\\bGRID_(COLS|ROWS)\\b"],
	["a *_GRID_POS cell", "_GRID_POS\\b"],
	["grid_pos", "\\bgrid_pos\\b"],
	["_grid_cell_of()", "_grid_cell_of\\b"],
	["main.WORLD_WIDTH / HEIGHT", "\\bWORLD_(WIDTH|HEIGHT)\\b"],
	["960 / 540 (a screen cell's size)", "(?<![\\w.])(960|540)(\\.0*)?(?![\\w.])"],
	["floor(x / N) cell maths", "floor\\([^)]*/\\s*[A-Z_]*(ROOM|CELL|960|540)"],
]

func _strip(line: String) -> String:
	var out := ""
	var in_str := false
	var q := ""
	var i := 0
	while i < line.length():
		var ch := line[i]
		if in_str:
			if ch == "\\":
				i += 2
				continue
			if ch == q:
				in_str = false
			i += 1
			continue
		if ch == "#":
			break
		if ch == "\"" or ch == "'":
			in_str = true
			q = ch
			out += "\"\""
			i += 1
			continue
		out += ch
		i += 1
	return out

func _run_scan() -> void:
	var regs := []
	for b in BANNED:
		var r := RegEx.new()
		r.compile(b[1])
		regs.append([b[0], r])
	# Sprite-sheet regions (Rect2i(...)) are pixel coordinates in an image,
	# not world positions: they're left out.
	var region := RegEx.new()
	region.compile("Rect2i\\([^)]*\\)")
	var files := []
	for f in DirAccess.get_files_at("res://"):
		if f.ends_with(".gd") and not f in ["StoreLayout.gd", "Areas.gd"]:
			files.append(f)
	files.sort()
	var hits := []
	for f in files:
		var lines := FileAccess.get_file_as_string("res://" + f).split("\n")
		for i in lines.size():
			var code := region.sub(_strip(lines[i]), "Rect2i()", true)
			for r in regs:
				if r[1].search(code) != null:
					hits.append("%s:%d (%s): %s" % [f, i + 1, r[0], lines[i].strip_edges().left(110)])
	for h in hits:
		print("INFO  " + h)
	check(files.size() >= 30, "N1: scanned %d game scripts (every res://*.gd but the layout table and the registry)" % files.size())
	check(hits.is_empty(), "N2: no screen-cell arithmetic in game code (%d hits) — positions come from StoreLayout.gd via main.areas" % hits.size())
	# N3: the scan itself works (a planted line is caught, a comment isn't).
	var planted := ["var c := Vector2i(int(floor(p.x / ROOM_WIDTH)), 0)", "var w := 960.0", "x = cell.grid_pos"]
	var caught := 0
	for line in planted:
		for r in regs:
			if r[1].search(_strip(line)) != null:
				caught += 1
				break
	var quiet: bool = regs.all(func(r): return r[1].search(_strip("var a := 1 # one room is 960 wide")) == null and r[1].search(_strip("print(\"ROOM_WIDTH\")")) == null)
	check(caught == planted.size() and quiet, "N3: the scan catches planted cell maths (%d/%d) and ignores comments and strings (%s)" % [caught, planted.size(), str(quiet)])
	finish()
