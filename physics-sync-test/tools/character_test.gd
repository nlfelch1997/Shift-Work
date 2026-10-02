extends SceneTree
## WEEK 25 test harness — the real character art (CharacterSprite.gd):
## customers, cashiers, the manager and the players, against the real
## Main.tscn. Not part of the game.
##
## Solo — every look loads, nobody shows the old polygon, customer variety,
## facing/walk animation follows movement, and the fixed identities (each
## register's cashier, the manager, the player) hold across Days 4-7:
##   godot --headless --path . --script res://tools/character_test.gd -- --server --day=4 --shift-seconds=600 --prep-seconds=900 --save-file=user://char_test/save.json --test=characters
## Add --shots (run under xvfb-run, no --headless) for close-up frames in
## user://char_shots/.
##
## Co-op — host + N-1 clients over ENet. Every peer reports the looks it sees
## for every player, customer, cashier and the manager, plus the facing row
## and walk cycle it sees on every player while each one walks its own
## direction; the host checks every peer saw exactly the same:
##   godot --headless --path . --script res://tools/character_test.gd -- --server --port=8941 --day=5 --players=3 --shift-seconds=600 --prep-seconds=900 --save-file=user://char_test/host.json --test=net-characters &
##   (x2) godot --headless --path . --script res://tools/character_test.gd -- --client --connect-port=8941 --save-file=user://char_test/client.json --test=net-characters
## tools/run_character_tests.sh runs all of it (solo twice, to compare the
## identities across two separate sessions).

const CS := preload("res://CharacterSprite.gd")
const NET_DIR := "user://net_chars/"
const DIRS := {"right": Vector2.RIGHT, "left": Vector2.LEFT, "up": Vector2.UP, "down": Vector2.DOWN}
const DIR_ROW := {"right": CS.ROW_RIGHT, "left": CS.ROW_LEFT, "up": CS.ROW_UP, "down": CS.ROW_DOWN}

var main: Node
var fails := 0
var shots := false
var me := 1
var act := "host_"

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	shots = "--shots" in args and DisplayServer.get_name() != "headless"
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	main.cleanup_ceiling_override = 0.0 # clock out at once: this is about people, not cleanup
	var mode := "characters"
	for a in args:
		if a.begins_with("--test="):
			mode = a.substr(7)
	match mode:
		"characters":
			_run_solo.call_deferred()
		"net-characters":
			if "--client" in args:
				_run_net_client.call_deferred()
			else:
				_run_net_host.call_deferred()

func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1

func finish() -> void:
	print("RESULT: %s (%d failure%s)" % ["OK" if fails == 0 else "FAILED", fails, "" if fails == 1 else "s"])
	quit(1 if fails else 0)

func wait(seconds: float) -> void:
	await create_timer(seconds).timeout

func wait_until(cond: Callable, timeout: float) -> bool:
	var t := 0.0
	while t < timeout:
		if cond.call():
			return true
		await physics_frame
		t += 1.0 / 60.0
	return cond.call()

func shot(name: String, at: Vector2, zoom: float) -> void:
	if not shots:
		return
	var cam := Camera2D.new()
	cam.zoom = Vector2(zoom, zoom)
	cam.global_position = at
	main.add_child(cam)
	cam.make_current()
	main.debug_label.visible = false
	for i in 6:
		await process_frame
	DirAccess.make_dir_recursive_absolute("user://char_shots")
	var path := "user://char_shots/%s.png" % name
	root.get_texture().get_image().save_png(path)
	print("SHOT  " + ProjectSettings.globalize_path(path))
	cam.queue_free()
	var mine: Node = main.players.get(me)
	if mine and mine.has_node("Camera"):
		mine.get_node("Camera").make_current()

func sprite_of(n: Node) -> Sprite2D:
	return n.get_node_or_null("CharacterSprite") as Sprite2D

func cashier_sprite(body: Node) -> Sprite2D:
	return body.get_node("CashierNPC/CharacterSprite") as Sprite2D

func customers() -> Array:
	return get_nodes_in_group("customer")

## A sprite is "good" when its sheet really loaded (no missing texture) at
## the expected 9x4 x 64px layout.
func sheet_ok(s: Sprite2D) -> bool:
	return s != null and s.texture != null and s.texture.get_size() == Vector2(CS.COLUMNS * CS.FRAME, CS.ROWS * CS.FRAME) and s.hframes == CS.COLUMNS and s.vframes == CS.ROWS

## Every person's look on this peer, as plain data (also what the co-op test
## compares between peers).
func identity() -> Dictionary:
	var out := {"players": {}, "customers": {}, "cashiers": {}, "manager": ""}
	for id in main.players:
		var s := sprite_of(main.players[id])
		out["players"][str(id)] = s.look if s else "<none>"
	for c in customers():
		var s := sprite_of(c)
		out["customers"][String(c.name)] = s.look if s else "<none>"
	for body in main.cashiers:
		var s := cashier_sprite(body)
		out["cashiers"][String(body.name)] = s.look if s else "<none>"
	var ms := sprite_of(main.manager)
	out["manager"] = ms.look if ms else "<none>"
	return out

## The fixed-identity table: Cashier<N> wears cashier_<N>, the manager
## wears "manager". Same every day, every session, every peer.
func fixed_identity_ok(idn: Dictionary) -> String:
	for body_name in idn["cashiers"]:
		var want := "cashier_" + String(body_name).trim_prefix("Cashier")
		if idn["cashiers"][body_name] != want:
			return "%s wears %s, want %s" % [body_name, idn["cashiers"][body_name], want]
	if idn["manager"] != "manager":
		return "manager wears %s" % idn["manager"]
	return ""

func identity_line(idn: Dictionary) -> String:
	var keys: Array = idn["cashiers"].keys()
	keys.sort()
	var parts := []
	for k in keys:
		parts.append("%s=%s" % [k, idn["cashiers"][k]])
	return "%s manager=%s" % [" ".join(parts), idn["manager"]]

## Walks this process's own player one way through its real keyboard
## actions; samples (on THIS peer) every given node's sprite row/walk state
## while it moves. Returns {node_name: {"rows": {row: frames}, "walk": n, "n": n}}.
func walk_and_sample(dir: String, seconds: float, watch: Array) -> Dictionary:
	var action := act + "move_" + dir
	Input.action_press(action)
	var seen := {}
	for n in watch:
		seen[String(n.name)] = {"rows": {}, "walk": 0, "n": 0, "from": n.global_position, "moved": 0.0}
	var t := 0.0
	while t < seconds:
		await physics_frame
		t += 1.0 / 60.0
		if t < 0.35:
			continue # let remote copies catch up before judging
		for n in watch:
			var s := sprite_of(n)
			if s == null:
				continue
			var e: Dictionary = seen[String(n.name)]
			e["rows"][s.row()] = e["rows"].get(s.row(), 0) + 1
			e["walk"] += 1 if s.is_walking() else 0
			e["n"] += 1
	Input.action_release(action)
	for n in watch:
		seen[String(n.name)]["moved"] = n.global_position.distance_to(seen[String(n.name)]["from"])
		seen[String(n.name)].erase("from")
	return seen

func dominant_row(e: Dictionary) -> int:
	var best := -1
	var best_n := -1
	for r in e["rows"]:
		if e["rows"][r] > best_n:
			best_n = e["rows"][r]
			best = int(r)
	return best

func row_share(e: Dictionary, row: int) -> float:
	return float(e["rows"].get(row, e["rows"].get(str(row), 0))) / maxf(1.0, float(e["n"]))

## Samples every walking customer (and the manager) for `seconds`: is the
## row the one its replicated facing asks for (outside the hysteresis band),
## and does that facing match the way it is really moving on screen?
func sample_npc_facing(seconds: float) -> Dictionary:
	var r := {"samples": 0, "row_bad": 0, "motion_n": 0, "motion_match": 0, "walking": 0, "mgr_samples": 0, "mgr_bad": 0}
	var last := {}
	var bad_prev := {}
	var t := 0.0
	while t < seconds:
		await process_frame
		t += main.get_process_delta_time()
		var people: Array = customers()
		if main.manager.active:
			people.append(main.manager)
		for c in people:
			if not is_instance_valid(c):
				continue
			var s := sprite_of(c)
			var is_mgr: bool = c == main.manager
			var angle: float = c.get("facing") if is_mgr else c.get("facing_angle")
			var off := absf(angle_difference(angle, CS._row_center(s.row())))
			# The sprite updates in its own _process, which may run after
			# this sample in the same frame: a row one frame behind a facing
			# that just changed is expected; two frames behind is a bug.
			var key: int = c.get_instance_id()
			var raw_bad := off > PI / 4.0 + CS.ROW_HYSTERESIS + 0.05
			var bad: bool = raw_bad and bad_prev.get(key, false)
			bad_prev[key] = raw_bad
			if is_mgr:
				r["mgr_samples"] += 1
				r["mgr_bad"] += 1 if bad else 0
			else:
				r["samples"] += 1
				r["row_bad"] += 1 if bad else 0
			# Motion over a 0.1 s window, not one frame: at a high frame rate
			# a strolling customer moves well under a pixel per frame.
			var p: Vector2 = c.global_position
			if is_mgr:
				continue
			if s.is_walking():
				r["walking"] += 1
			if not last.has(key):
				last[key] = [p, t]
			elif t - last[key][1] >= 0.1:
				var mv: Vector2 = p - last[key][0]
				if s.is_walking() and mv.length() > 3.0:
					r["motion_n"] += 1
					r["motion_match"] += 1 if CS.row_for_angle(mv.angle()) == s.row() else 0
				last[key] = [p, t]
	return r

## ---------------------------------------------------------------------------
## Solo

func _run_solo() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 20.0)
	var p: Node2D = main.players[1]
	var ps := sprite_of(p)
	# --- C1: the player
	check(sheet_ok(ps), "C1 player sprite loaded (%s, 9x4 frames of 64px)" % (ps.look if ps else "none"))
	check(ps != null and ps.look == "player_1", "C1 host player wears player_1 (staff uniform)")
	check(not p.get_node("Polygon2D").visible, "C1 old player arrow polygon hidden")
	var ring: Polygon2D = p.get_node_or_null("FootRing")
	check(ring != null and Color(ring.color.r, ring.color.g, ring.color.b).is_equal_approx(Color(0.25, 0.55, 1.0)), "C1 host-blue ring under the player's feet")
	# --- C2: cashiers + manager
	var idn := identity()
	var all_cashiers_ok := true
	for body in main.cashiers:
		all_cashiers_ok = all_cashiers_ok and sheet_ok(cashier_sprite(body)) and not body.get_node("CashierNPC/Body").visible
	check(all_cashiers_ok and main.cashiers.size() == 5, "C2 all %d register cashiers have a loaded sprite, old polygons hidden" % main.cashiers.size())
	check(fixed_identity_ok(idn) == "", "C2 fixed identities: %s %s" % [identity_line(idn), fixed_identity_ok(idn)])
	check(sheet_ok(sprite_of(main.manager)) and not main.manager.get_node("Facing/Body").visible and main.manager.get_node("Facing/Cone").visible, "C2 manager sprite loaded, old polygon body hidden, vision cone kept")
	print("IDENTITY day%d %s players=%s" % [main.current_day, identity_line(idn), str(idn["players"])])
	# --- C3: facing + walk cycle follow the player's real keyboard movement
	p.teleport_to(Vector2(1300, 1000))
	await wait(0.4)
	for dir in ["right", "down", "left", "up"]:
		var seen: Dictionary = await walk_and_sample(dir, 0.7, [p])
		var e: Dictionary = seen[String(p.name)]
		check(e["moved"] > 80.0 and dominant_row(e) == DIR_ROW[dir] and row_share(e, DIR_ROW[dir]) > 0.95 and e["walk"] >= e["n"] * 0.9, "C3 walking %s (%.0f px): sprite faces %s %.0f%% of frames, walk cycle %d/%d frames" % [dir, e["moved"], dir, 100.0 * row_share(e, DIR_ROW[dir]), e["walk"], e["n"]])
		await wait(0.5)
		check(not ps.is_walking() and ps.row() == DIR_ROW[dir], "C3 stopped after %s: standing frame, still facing %s" % [dir, dir])
	# --- C4: customers — variety, loaded sheets, ring by role
	main.open_store(1)
	await wait(0.5)
	var before := customers().size()
	var dealt := []
	main._customer_look_deck.clear() # start a fresh deck so the blocks of 6 line up
	for i in 18:
		main._spawn_customer("disruptive" if i % 3 == 0 else "shopper")
	await wait(0.3)
	var spawned := customers().filter(func(c): return int(String(c.name).trim_prefix("Customer")) >= main._customer_spawn_index - 18)
	spawned.sort_custom(func(a, b): return int(String(a.name).trim_prefix("Customer")) < int(String(b.name).trim_prefix("Customer")))
	for c in spawned:
		dealt.append(c.look_index)
	var counts := {}
	for l in dealt:
		counts[l] = counts.get(l, 0) + 1
	var blocks_ok := true
	for b0 in [0, 6, 12]:
		var block := {}
		for l in dealt.slice(b0, b0 + 6):
			block[l] = true
		blocks_ok = blocks_ok and block.size() == 6
	var repeats := 0
	for i in range(1, dealt.size()):
		repeats += 1 if dealt[i] == dealt[i - 1] else 0
	check(spawned.size() == 18, "C4 spawned 18 customers on top of %d already in the store" % before)
	check(counts.size() == 6 and counts.values().all(func(n): return n == 3), "C4 all 6 customer looks dealt evenly over 18 spawns: %s" % str(counts))
	check(blocks_ok and repeats == 0, "C4 each deal of 6 is all six faces, never the same face back-to-back (%s)" % str(dealt))
	var cust_ok := true
	var ring_ok := true
	for c in customers():
		var s := sprite_of(c)
		cust_ok = cust_ok and sheet_ok(s) and s.look == "customer_%d" % c.look_index and not c.get_node("Polygon2D").visible
		var rc: Color = c.get_node("FootRing").color
		var want := Color(0.4, 0.75, 0.8) if c.role == "shopper" else Color(0.85, 0.25, 0.25)
		ring_ok = ring_ok and Color(rc.r, rc.g, rc.b).is_equal_approx(want)
	check(cust_ok, "C4 every customer (%d) shows its dealt look, sheet loaded, polygon hidden" % customers().size())
	check(ring_ok, "C4 shopper rings teal, disruptive rings red (role still legible)")
	# --- C5: customers (and the manager) face the way they move
	await shot("customers_crowd", main._store_entrance_pos() + Vector2(0, -160), 2.0)
	var f: Dictionary = await sample_npc_facing(8.0)
	check(f["samples"] > 500 and f["row_bad"] == 0, "C5 customer row always matches its replicated facing (%d samples, %d off)" % [f["samples"], f["row_bad"]])
	var mm: float = float(f["motion_match"]) / maxf(1.0, float(f["motion_n"]))
	# Bar is lower than the co-op run's: this crowd (18 extra customers
	# spawned at the entrance at once) shoves itself around a lot, and a
	# shoved customer keeps facing where it is trying to go (its facing is
	# the AI's intended direction, exactly as it always was) — the row-vs-
	# facing check above is the strict one.
	check(f["motion_n"] > 100 and mm > 0.75, "C5 walking customers face the way they actually move %.1f%% of %d moving frames" % [100.0 * mm, f["motion_n"]])
	if main.manager.active:
		check(f["mgr_samples"] > 100 and f["mgr_bad"] == 0, "C5 manager row matches his facing (%d samples, %d off)" % [f["mgr_samples"], f["mgr_bad"]])
	# --- C6: staff vs manager vs customers lineup (shots only)
	if shots:
		var spot := Vector2(1440, 1000)
		p.teleport_to(spot)
		var m: Node2D = main.manager
		m.position = spot + Vector2(50, 0)
		m.target_position = m.position
		m._pause_timer = 1000.0
		m._legs.clear()
		m.facing = PI / 2.0
		await wait(0.6)
		await shot("lineup_player_manager", spot + Vector2(25, -10), 3.0)
		var b: Node2D = main.cashiers[0]
		await shot("cashiers_row", main.cashiers[1].global_position + Vector2(0, 40), 1.6)
		await shot("cashier_1_close", b.global_position + Vector2(0, -20), 3.0)
		m._pause_timer = 0.0
	# --- C7: fixed identities hold day after day; the player keeps his look
	var start_day: int = main.current_day
	var per_day := []
	while main.current_day < 7:
		main._end_shift()
		await wait_until(func(): return main.is_day_report_active(), 5.0)
		main._on_continue_pressed()
		await wait_until(func(): return main.shift_active, 10.0)
		await wait(0.3)
		var d := identity()
		var active := []
		for body in main.cashiers:
			if body.visible:
				active.append(String(body.name))
		per_day.append(main.current_day)
		check(fixed_identity_ok(d) == "" and d["players"]["1"] == "player_1", "C7 Day %d: same cashier per register + manager + player look (%s; %d registers open: %s) %s" % [main.current_day, identity_line(d), active.size(), ",".join(active), fixed_identity_ok(d)])
		print("IDENTITY day%d %s players=%s" % [main.current_day, identity_line(d), str(d["players"])])
		check(sheet_ok(sprite_of(main.manager)) and sprite_of(main.manager).look == "manager", "C7 Day %d: manager still the one fixed suited look" % main.current_day)
	check(per_day.size() == 7 - start_day, "C7 walked Days %d-7 (%s)" % [start_day, str(per_day)])
	finish()

## ---------------------------------------------------------------------------
## Co-op

func _net_write(file: String, data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(NET_DIR)
	var f := FileAccess.open(NET_DIR + file + ".tmp", FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()
	DirAccess.rename_absolute(NET_DIR + file + ".tmp", NET_DIR + file)

func _net_read(file: String, timeout: float) -> Dictionary:
	var t := 0.0
	while t < timeout:
		if FileAccess.file_exists(NET_DIR + file):
			var parsed = JSON.parse_string(FileAccess.get_file_as_string(NET_DIR + file))
			if parsed is Dictionary:
				return parsed
		await create_timer(0.25).timeout
		t += 0.25
	return {}

## Each player walks a different direction, by sorted peer id.
func dir_for(ids: Array, id: int) -> String:
	return ["right", "left", "up", "down"][ids.find(id) % 4]

## Every peer, host included: report what this peer sees.
func _peer_round(ids: Array) -> Dictionary:
	var go := await _net_read("go.json", 60.0)
	# Line every peer up on the same wall-clock start (same machine).
	var start_at: float = float(go.get("start_unix", 0.0))
	while Time.get_unix_time_from_system() < start_at:
		await process_frame
	var watch := []
	for id in ids:
		watch.append(main.players[id])
	var seen: Dictionary = await walk_and_sample(dir_for(ids, me), 1.6, watch)
	var walk := {}
	for id in ids:
		var e: Dictionary = seen[str(id)]
		walk[str(id)] = {"row": dominant_row(e), "share": row_share(e, dominant_row(e)), "walk": e["walk"], "n": e["n"], "moved": e["moved"]}
	await wait(0.6)
	var stopped := {}
	for id in ids:
		var s := sprite_of(main.players[id])
		stopped[str(id)] = {"row": s.row(), "walking": s.is_walking()}
	var f: Dictionary = await sample_npc_facing(5.0)
	f["fps"] = Engine.get_frames_per_second()
	var idn := identity()
	var all_loaded := true
	for n in main.players.values() + customers() + [main.manager]:
		all_loaded = all_loaded and sheet_ok(sprite_of(n))
	for body in main.cashiers:
		all_loaded = all_loaded and sheet_ok(cashier_sprite(body))
	return {"id": me, "identity": idn, "walk": walk, "stopped": stopped, "npc": f, "loaded": all_loaded}

func _run_net_host() -> void:
	var want := 3
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--players="):
			want = int(a.substr(10))
	if DirAccess.dir_exists_absolute(NET_DIR):
		for f in DirAccess.get_files_at(NET_DIR):
			DirAccess.remove_absolute(NET_DIR + f)
	await wait_until(func(): return main.shift_active and main.players.size() >= want, 40.0)
	check(main.players.size() == want, "N0 %d players connected" % main.players.size())
	main.open_store(1)
	await wait_until(func(): return customers().size() >= 4, 30.0)
	var ids: Array = main.players.keys()
	ids.sort()
	# Spread the players out in open floor so nobody walks into a wall.
	for k in ids.size():
		var start: Vector2 = {"right": Vector2(1050, 600), "left": Vector2(1650, 680), "up": Vector2(1900, 1250), "down": Vector2(1000, 800)}[dir_for(ids, ids[k])]
		main.players[ids[k]].rpc("teleport_to", start)
	await wait(1.0)
	_net_write("go.json", {"start_unix": Time.get_unix_time_from_system() + 2.5, "ids": ids})
	var mine: Dictionary = await _peer_round(ids)
	var reports := {str(me): mine}
	for id in ids:
		if id == 1:
			continue
		var r := await _net_read("report_%d.json" % id, 60.0)
		check(not r.is_empty(), "N0 got peer %d's report" % id)
		reports[str(id)] = r
	var host_idn: Dictionary = mine["identity"]
	# N1: player looks — slot-based staff looks, identical on every peer
	# (slot = join order, so the host is always slot 1)
	var worn: Array = host_idn["players"].values()
	worn.sort()
	var want_worn := []
	for k in ids.size():
		want_worn.append("player_%d" % (k + 1))
	check(host_idn["players"].get("1", "") == "player_1" and worn == want_worn, "N1 host: one staff look per player slot, host in player_1 (%s)" % str(host_idn["players"]))
	for pid in reports:
		var r: Dictionary = reports[pid]
		var idn: Dictionary = r["identity"]
		check(r.get("loaded", false), "N1 peer %s: every sprite's sheet loaded on its side (no missing textures)" % pid)
		check(idn["players"] == host_idn["players"], "N1 peer %s sees the same player looks as the host %s" % [pid, str(idn["players"])])
		check(fixed_identity_ok(idn) == "" and idn["cashiers"] == host_idn["cashiers"] and idn["manager"] == host_idn["manager"], "N1 peer %s: same fixed cashier/manager identities (%s)" % [pid, identity_line(idn)])
		# customers: every customer both sides know about wears the same look
		var common := 0
		var mismatch := 0
		for cname in idn["customers"]:
			if host_idn["customers"].has(cname):
				common += 1
				mismatch += 0 if host_idn["customers"][cname] == idn["customers"][cname] else 1
		var looks := {}
		for cname in idn["customers"]:
			looks[idn["customers"][cname]] = true
		check(common >= 4 and mismatch == 0, "N1 peer %s: %d customers in common with the host, %d wearing a different look; %d distinct looks on screen" % [pid, common, mismatch, looks.size()])
	# N2: every peer sees every player face its own walking direction, legs moving, then standing
	for pid in reports:
		var r: Dictionary = reports[pid]
		for id in ids:
			var w: Dictionary = r["walk"][str(id)]
			var want_row: int = DIR_ROW[dir_for(ids, id)]
			check(float(w["moved"]) > 250.0 and int(w["row"]) == want_row and float(w["share"]) > 0.9 and int(w["walk"]) >= int(w["n"]) * 0.8, "N2 peer %s sees player %d walking %s (%.0f px): row %d (want %d) %.0f%% of frames, walk cycle %d/%d" % [pid, id, dir_for(ids, id), float(w["moved"]), int(w["row"]), want_row, 100.0 * float(w["share"]), int(w["walk"]), int(w["n"])])
			var st: Dictionary = r["stopped"][str(id)]
			check(int(st["row"]) == want_row and not st["walking"], "N2 peer %s sees player %d stopped, still facing %s" % [pid, id, dir_for(ids, id)])
	# N3: customers and the manager face their replicated facing on every peer
	for pid in reports:
		var f: Dictionary = reports[pid]["npc"]
		var mm: float = float(f["motion_match"]) / maxf(1.0, float(f["motion_n"]))
		check(int(f["samples"]) > 200 and int(f["row_bad"]) == 0, "N3 peer %s: customer rows match replicated facing (%d samples, %d off)" % [pid, int(f["samples"]), int(f["row_bad"])])
		check(int(f["motion_n"]) > 50 and mm > 0.8, "N3 peer %s: walking customers face the way they move on that screen %.1f%% of %d frames (%s)" % [pid, 100.0 * mm, int(f["motion_n"]), str(f)])
		if int(f["mgr_samples"]) > 0:
			check(int(f["mgr_bad"]) == 0, "N3 peer %s: manager row matches his facing (%d samples)" % [pid, int(f["mgr_samples"])])
	_net_write("done.json", {"fails": fails})
	await wait(1.0)
	finish()

func _run_net_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 30.0)
	me = main.multiplayer.get_unique_id()
	act = "client_"
	var go := await _net_read("go.json", 90.0)
	var ids: Array = go.get("ids", []).map(func(x): return int(x))
	await wait_until(func(): return ids.all(func(i): return main.players.has(i)), 10.0)
	var mine: Dictionary = await _peer_round(ids)
	check(mine["loaded"], "client %d: every sprite sheet loaded" % me)
	check(fixed_identity_ok(mine["identity"]) == "", "client %d: fixed cashier/manager identities %s" % [me, identity_line(mine["identity"])])
	_net_write("report_%d.json" % me, mine)
	var done := await _net_read("done.json", 90.0)
	check(not done.is_empty(), "client %d: host finished the comparison (host fails: %s)" % [me, str(done.get("fails", "?"))])
	finish()
