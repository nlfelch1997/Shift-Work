extends SceneTree
## WEEK 25 test harness — the real character art (CharacterSprite.gd):
## customers, cashiers, the manager and the players, against the real
## Main.tscn. Not part of the game.
##
## Solo — every look loads, nobody shows the old polygon, customer variety,
## facing/walk animation follows movement, and the fixed identities (each
## register's cashier, the manager, the player) hold across Days 4-7:
##   godot --headless --path . --script res://tools/character_test.gd -- --server --day=4 --shift-seconds=600 --prep-seconds=900 --no-save --test=characters
## Add --shots (run under xvfb-run, no --headless) for close-up frames in
## user://char_shots/.
##
## Co-op — host + N-1 clients over ENet. Every peer reports the looks it sees
## for every player, customer, cashier and the manager, plus the facing row
## and walk cycle it sees on every player while each one walks its own
## direction; the host checks every peer saw exactly the same:
##   godot --headless --path . --script res://tools/character_test.gd -- --server --port=8941 --day=5 --players=3 --shift-seconds=600 --prep-seconds=900 --no-save --test=net-characters &
##   (x2) godot --headless --path . --script res://tools/character_test.gd -- --client --connect-port=8941 --no-save --test=net-characters
## tools/run_character_tests.sh runs all of it (solo twice, to compare the
## identities across two separate sessions).
##
## WEEK 26 — the forklift drivers ride along in both modes: each forklift's
## fixed driver look (in identity(), so the per-day/per-session/per-peer
## identity checks cover them), the sheet loaded, and — sampled every frame
## while both forklifts really drive — the driver facing the same way as its
## own truck art and the truck's heading, and never sticking out of the
## truck. Co-op: every peer samples on the same wall-clock ticks and the host
## compares each peer's driver rows against its own.

const CS := preload("res://CharacterSprite.gd")
const NET_DIR := "user://net_chars/"
const DIRS := {"right": Vector2.RIGHT, "left": Vector2.LEFT, "up": Vector2.UP, "down": Vector2.DOWN}
const DIR_ROW := {"right": CS.ROW_RIGHT, "left": CS.ROW_LEFT, "up": CS.ROW_UP, "down": CS.ROW_DOWN}

var main: Node

## A spot in a named room of the layout table (tools/spots.gd).
func area_spot(id: String, offset := Vector2.ZERO) -> Vector2:
	return preload("res://tools/spots.gd").area_spot(main, id, offset)

func out_of_the_way(offset := Vector2.ZERO) -> Vector2:
	return preload("res://tools/spots.gd").out_of_the_way(main, offset)
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
	# OCT 2026 PHASE 4: random events (Events.gd) are off here — tools/events_test.gd
	# tests them; --events=on turns them on (the income runs measure both).
	main.events_on = "--events=on" in OS.get_cmdline_user_args()
	# OCT 2026 PHASE 2: written for the 7-day story — Day N -> N+1 hands the
	# crew old Day N+1's sections/earnings (Main.gd's test_follow_old_calendar),
	# (OCT 2026 PHASE 4: Week 21's Endless Mode and its debug --endless route
	# are retired — Day 7's report just leads to Day 8 now.)
	main.test_follow_old_calendar = true
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
	main.status_hud = false
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

## WEEK 26: forklift name -> the one driver look it always has.
const DRIVER_LOOKS := {"Forklift": "driver_produce", "DeliveryForklift": "driver_delivery"}

func forklifts() -> Array:
	return [main.forklift, main.delivery_forklift]

func driver_of(f: Node) -> Sprite2D:
	return f.get_node_or_null("Art/Driver") as Sprite2D

func driver_look(f: Node) -> String:
	var s := driver_of(f)
	if s == null or s.texture == null:
		return "<none>"
	return s.texture.resource_path.get_file().get_basename()

## The seated sheet: 1 column x the 4 facing rows, 64 px.
func driver_sheet_ok(s: Sprite2D) -> bool:
	return s != null and s.texture != null and s.texture.get_size() == Vector2(CS.FRAME, CS.ROWS * CS.FRAME) and s.region_enabled

## The row the truck's own art implies: front view -> facing the camera,
## else the side the forks point to.
func art_row(f: Node) -> int:
	var art: Sprite2D = f.get_node("Art")
	if Rect2i(art.region_rect) == f.ART_FRONT:
		return CS.ROW_DOWN
	return CS.ROW_RIGHT if art.flip_h else CS.ROW_LEFT

## The row the truck's heading implies, or -1 where the pack has no view
## for it (heading north/diagonal: the art keeps its last side view).
func heading_row(f: Node) -> int:
	var dir := Vector2.RIGHT.rotated(f.rotation)
	if dir.y > 0.7:
		return CS.ROW_DOWN
	if dir.y < -0.3:
		return -1
	if dir.x > 0.3:
		return CS.ROW_RIGHT
	if dir.x < -0.3:
		return CS.ROW_LEFT
	return -1

## Driver drawn fully over the truck art (same screen-space box test).
func driver_inside(f: Node) -> bool:
	var d := driver_of(f)
	var art: Sprite2D = f.get_node("Art")
	var dr := d.get_global_transform() * d.get_rect()
	var ar := art.get_global_transform() * art.get_rect()
	return ar.grow(0.5).encloses(dr)

## Samples both forklifts' drivers every frame for `seconds` on THIS peer.
## With `tick` > 0 also records the driver row at every multiple of `tick`
## since `t0_unix` (wall clock), for comparing peers sample-for-sample.
func sample_drivers(seconds: float, t0_unix := 0.0, tick := 0.0) -> Dictionary:
	var out := {}
	for f in forklifts():
		out[String(f.name)] = {"look": driver_look(f), "loaded": driver_sheet_ok(driver_of(f)), "n": 0, "art_bad": 0, "heading_n": 0, "heading_bad": 0, "inside_bad": 0, "visible_bad": 0, "turning": 0, "rows": {}, "moved": 0.0, "timeline": [], "_last": f.global_position, "_rot": f.rotation}
	var t := 0.0
	var next_k := 0
	while t < seconds:
		await process_frame
		t += root.get_process_delta_time()
		var stamp := -1
		if tick > 0.0:
			var k := int((Time.get_unix_time_from_system() - t0_unix) / tick)
			if k >= next_k:
				stamp = k
				next_k = k + 1
		for f in forklifts():
			var e: Dictionary = out[String(f.name)]
			var d := driver_of(f)
			if d == null:
				continue
			var r: int = f.driver_row()
			if stamp >= 0:
				e["timeline"].append([stamp, r])
			if not f.visible:
				continue
			e["n"] += 1
			e["moved"] += f.global_position.distance_to(e["_last"])
			e["_last"] = f.global_position
			e["rows"][r] = e["rows"].get(r, 0) + 1
			e["art_bad"] += 0 if r == art_row(f) else 1
			e["visible_bad"] += 0 if d.is_visible_in_tree() else 1
			e["inside_bad"] += 0 if driver_inside(f) else 1
			# The art (and so the driver) is set in _process, before this
			# frame's physics step turns the truck — mid-turn it trails the
			# heading by a frame, truck and driver alike. Heading is checked
			# on frames the truck isn't rotating; art_bad covers every frame.
			var turning := absf(angle_difference(f.rotation, e["_rot"])) > 0.0005
			e["_rot"] = f.rotation
			if turning:
				e["turning"] += 1
			var h := heading_row(f)
			if h >= 0 and not turning:
				e["heading_n"] += 1
				e["heading_bad"] += 0 if h == r else 1
	for k in out:
		out[k].erase("_last")
		out[k].erase("_rot")
	return out

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
	out["drivers"] = {}
	for f in forklifts():
		out["drivers"][String(f.name)] = driver_look(f)
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
	if idn.get("drivers", {}) != DRIVER_LOOKS:
		return "forklift drivers %s, want %s" % [str(idn.get("drivers", {})), str(DRIVER_LOOKS)]
	return ""

func identity_line(idn: Dictionary) -> String:
	var keys: Array = idn["cashiers"].keys()
	keys.sort()
	var parts := []
	for k in keys:
		parts.append("%s=%s" % [k, idn["cashiers"][k]])
	var drivers: Dictionary = idn.get("drivers", {})
	return "%s manager=%s forklift=%s delivery_forklift=%s" % [" ".join(parts), idn["manager"], drivers.get("Forklift", "?"), drivers.get("DeliveryForklift", "?")]

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
	p.teleport_to(area_spot("hub", Vector2(-140, 190)))
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
	# --- C8 (WEEK 26): forklift drivers, while both forklifts really drive
	# (the store is open: the Produce forklift patrols/rams; the delivery
	# one has been unloading since the shift started)
	for fk in forklifts():
		var d := driver_of(fk)
		check(driver_sheet_ok(d) and driver_look(fk) == DRIVER_LOOKS[String(fk.name)], "C8 %s: driver sheet loaded (%s, 4 seated facings of 64px)" % [fk.name, driver_look(fk)])
	var staff_looks := ["manager"]
	for k in 5:
		staff_looks.append("cashier_%d" % (k + 1))
	for k in 4:
		staff_looks.append("player_%d" % (k + 1))
	check(not DRIVER_LOOKS.values().any(func(l): return l in staff_looks) and DRIVER_LOOKS["Forklift"] != DRIVER_LOOKS["DeliveryForklift"], "C8 each forklift has its own driver, neither wearing a store-staff or manager look")
	var rams0: int = main.forklift.rams_today
	var drops0: int = main.delivery_forklift.drops_today
	var dv: Dictionary = await sample_drivers(30.0)
	for fk in forklifts():
		var e: Dictionary = dv[String(fk.name)]
		print("DRIVER %s %s" % [fk.name, str(e)])
		check(e["n"] > 600 and e["moved"] > 300.0, "C8 %s drove %.0f px over %d frames" % [fk.name, e["moved"], e["n"]])
		check(e["art_bad"] == 0 and e["visible_bad"] == 0, "C8 %s: driver faces the same way as the truck art on every frame (%d off), always visible" % [fk.name, e["art_bad"]])
		check(e["heading_n"] > 300 and e["heading_bad"] == 0, "C8 %s: driver row matches the truck's heading on %d/%d steady (not mid-turn) frames with a side/front view; %d turning frames" % [fk.name, e["heading_n"] - e["heading_bad"], e["heading_n"], e["turning"]])
		check(e["inside_bad"] == 0, "C8 %s: driver never drawn outside the truck art (%d frames off)" % [fk.name, e["inside_bad"]])
	check(dv["Forklift"]["rows"].has(CS.ROW_LEFT) and dv["Forklift"]["rows"].has(CS.ROW_RIGHT), "C8 Produce driver seen facing both left and right on patrol %s" % str(dv["Forklift"]["rows"]))
	check(dv["DeliveryForklift"]["rows"].size() >= 2, "C8 delivery driver seen in %d facings while unloading %s" % [dv["DeliveryForklift"]["rows"].size(), str(dv["DeliveryForklift"]["rows"])])
	print("C8 info: Produce forklift rams %d -> %d, delivery drops %d -> %d during the sample" % [rams0, main.forklift.rams_today, drops0, main.delivery_forklift.drops_today])
	if shots:
		for fk in forklifts():
			await shot("driver_%s" % fk.name, fk.global_position + Vector2(0, -20), 3.0)
	# --- C6: staff vs manager vs customers lineup (shots only)
	if shots:
		var spot := area_spot("hub", Vector2(0, 190))
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
	# WEEK 26: both forklift drivers, every peer on the same wall-clock ticks.
	var drv_t0 := start_at + 9.0
	while Time.get_unix_time_from_system() < drv_t0:
		await process_frame
	var drivers: Dictionary = await sample_drivers(15.0, drv_t0, 0.1)
	var idn := identity()
	var all_loaded := true
	for n in main.players.values() + customers() + [main.manager]:
		all_loaded = all_loaded and sheet_ok(sprite_of(n))
	for body in main.cashiers:
		all_loaded = all_loaded and sheet_ok(cashier_sprite(body))
	for fk in forklifts():
		all_loaded = all_loaded and driver_sheet_ok(driver_of(fk))
	return {"id": me, "identity": idn, "walk": walk, "stopped": stopped, "npc": f, "loaded": all_loaded, "drivers": drivers}

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
		var start: Vector2 = {"right": area_spot("hub", Vector2(-390, -210)), "left": area_spot("hub", Vector2(210, -130)), "up": area_spot("sidewalk", Vector2(460, -100)), "down": area_spot("hub", Vector2(-440, -10))}[dir_for(ids, ids[k])]
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
	# N4 (WEEK 26): forklift drivers — same look, facing their own truck on
	# every peer, and the same row as the host's at the same moment
	var host_drv: Dictionary = mine["drivers"]
	for pid in reports:
		var dr: Dictionary = reports[pid]["drivers"]
		for fname in DRIVER_LOOKS:
			var e: Dictionary = dr[fname]
			check(e["look"] == DRIVER_LOOKS[fname] and e["loaded"], "N4 peer %s: %s driver is %s, sheet loaded" % [pid, fname, e["look"]])
			check(int(e["n"]) > 300 and int(e["art_bad"]) == 0 and int(e["visible_bad"]) == 0 and int(e["inside_bad"]) == 0, "N4 peer %s: %s driver faces its truck art on all %d frames, visible, inside the truck (moved %.0f px; rows %s)" % [pid, fname, int(e["n"]), float(e["moved"]), str(e["rows"])])
			check(int(e["heading_bad"]) == 0, "N4 peer %s: %s driver row matches the truck's heading on that screen (%d frames)" % [pid, fname, int(e["heading_n"])])
			var hrows := {}
			for pair in host_drv[fname]["timeline"]:
				hrows[int(pair[0])] = int(pair[1])
			var common := 0
			var same := 0
			for pair in e["timeline"]:
				if hrows.has(int(pair[0])):
					common += 1
					same += 1 if hrows[int(pair[0])] == int(pair[1]) else 0
			var share := float(same) / maxf(1.0, float(common))
			check(common > 100 and share > 0.9, "N4 peer %s: %s driver shows the host's row on %.1f%% of %d shared 0.1 s ticks" % [pid, fname, 100.0 * share, common])
	_net_write("done.json", {"fails": fails})
	await wait(1.0)
	finish()

func _run_net_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 30.0)
	me = main.multiplayer.get_unique_id()
	act = root.get_node("Settings").local_prefix()
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
