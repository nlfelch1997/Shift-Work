extends "res://tools/hazards_test.gd"
## OCT 2026 OUTSIDE-PLAYTEST FIXES — the test modes for the five fixes from
## the first real outside playtest (two friends, Oct 2-3). Reuses
## tools/hazards_test.gd's helpers (stocking, the solo brain, net files), so it
## drives the real Main.tscn through the real game code like every other test
## here. Not part of the game.
##
## DISRUPTIVE CUSTOMER RATE ("red customers show up early, then never again"):
##   godot --headless --path . --script res://tools/playtest_fixes_test.gd -- --server --day=2 --no-save --test=disruptive
##   (a crew that keeps every shelf stocked — the playtest's situation — over
##   a full selling window; --long runs a 600s window; --runs=N repeats it)
## Co-op (host + 2 clients; every client counts what IT sees):
##   godot ... -- --server --port=8961 --day=2 --players=3 --no-save --test=net-disruptive &
##   (x2) godot ... -- --client --connect-port=8961 --no-save --test=net-disruptive
## SHELF STOCK vs BUMPS (players, thrown/pushed stock, shoppers bump nothing;
## pickup, disruptive customers and a forklift ram still work):
##   godot ... -- --server --day=3 --no-save --test=shelf
##   godot ... -- --server --port=8962 --day=3 --players=3 --no-save --test=net-shelf &   (x2 clients)
## PICKUP RADIUS (crate stock, the delivery crate itself, host = client rule):
##   godot ... -- --server --day=1 --no-save --test=pickup
## TRASH ($1 a piece by hand mid-shift and by broom at close, popups):
##   godot ... -- --server --day=2 --no-save --test=trash
## PRACTICE SHIFT (plays it through with real key presses, then skip):
##   godot ... -- --server --no-save --practice --test=practice
##   godot ... -- --server --no-save --practice --test=practice-skip
##   godot ... -- --server --port=8963 --no-save --practice --players=2 --test=net-practice &  (x1 client)

var _mode := ""

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--test="):
			_mode = a.substr(7)
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	careless = true
	if _mode in ["disruptive", "net-disruptive", "shelf", "net-shelf"]:
		main.opening_stock_fraction = 1.0
	if _mode in ["disruptive", "net-disruptive", "shelf", "net-shelf", "pickup"]:
		main.cleanup_ceiling_override = 0.0
	var client := "--client" in args
	match _mode:
		"disruptive": _run_disruptive.call_deferred()
		"net-disruptive": (_run_net_disruptive_client if client else _run_net_disruptive_host).call_deferred()
		"shelf": _run_shelf.call_deferred()
		"net-shelf": (_run_net_shelf_client if client else _run_net_shelf_host).call_deferred()
		"pickup": _run_pickup.call_deferred()
		"trash": _run_trash.call_deferred()
		"practice": _run_practice.call_deferred(false)
		"practice-skip": _run_practice_skip.call_deferred()
		"net-practice":
			if client:
				_run_net_practice_client.call_deferred()
			else:
				_run_practice.call_deferred(true)
		_:
			print("FAIL  unknown --test=%s" % _mode)
			quit(1)

func _arg(name: String, fallback: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.substr(name.length() + 3)
	return fallback

## =============================================================================
## DISRUPTIVE CUSTOMERS
## =============================================================================

## Keeps every open shelf full — a crew on top of its stocking, which is
## exactly what makes shoppers commit to items (and so stay longer).
func _keep_stocked() -> void:
	while main.shift_active and not main.cleanup_active:
		for s in main._unlocked_sections():
			var n: String = s["name"]
			while empty_slot_in(n) != null:
				if loose_products(n).is_empty():
					main._spawn_product_for(n)
					await physics_frame
					await physics_frame
				var ok = await stock_one(n)
				if ok == null:
					break
		await wait(1.0)

## Samples the host's live crowd once a second through one selling window.
## Returns the per-second samples and every customer seen, by role.
func _sample_crowd(window: float) -> Dictionary:
	var seen := {}
	var samples := [] # [t, live_shoppers, live_disruptive]
	var t := 0.0
	while t < window and main.shift_active and not main.cleanup_active:
		var s := 0
		var d := 0
		for c in get_nodes_in_group("customer"):
			if c.is_queued_for_deletion():
				continue
			if c.role == "disruptive":
				d += 1
			else:
				s += 1
			if not seen.has(c.name):
				seen[c.name] = {"role": c.role, "t": t}
		samples.append([t, s, d])
		await wait(1.0)
		t += 1.0
	return {"samples": samples, "seen": seen}

func _crowd_report(tag: String, r: Dictionary, window: float) -> Dictionary:
	var samples: Array = r["samples"]
	var seen: Dictionary = r["seen"]
	var thirds := [[0.0, window / 3.0], [window / 3.0, 2.0 * window / 3.0], [2.0 * window / 3.0, window + 1.0]]
	var line := "DISRUPTIVE %s (%.0fs window, cap %d):" % [tag, window, main._customer_baseline() + main.CUSTOMER_PER_EXTRA_PLAYER * max(0, main.players.size() - 1)]
	var out := {"arrivals": [], "share": [], "present": []}
	for th in thirds:
		var arrivals := 0
		var total := 0
		for n in seen:
			if seen[n]["t"] >= th[0] and seen[n]["t"] < th[1]:
				total += 1
				if seen[n]["role"] == "disruptive":
					arrivals += 1
		var live_d := 0.0
		var live_all := 0.0
		var present := 0
		var cnt := 0
		for smp in samples:
			if smp[0] >= th[0] and smp[0] < th[1]:
				live_d += smp[2]
				live_all += smp[1] + smp[2]
				present += 1 if smp[2] > 0 else 0
				cnt += 1
		var share := live_d / maxf(1.0, live_all)
		var pres := float(present) / maxf(1.0, cnt)
		out["arrivals"].append(arrivals)
		out["share"].append(share)
		out["present"].append(pres)
		line += "  | %3.0f-%3.0fs: %d red of %d arrivals, live red share %2.0f%%, a red one on the floor %3.0f%% of the time" % [th[0], minf(th[1], window), arrivals, total, share * 100.0, pres * 100.0]
	print(line)
	return out

func _open_and_measure(window: float) -> Dictionary:
	await wait_until(func(): return main.shift_active and main.players.size() >= int(_arg("players", "1")), 30.0)
	await wait(1.0)
	# Opening shelves full before the doors open, like a crew that used prep.
	_keep_stocked()
	await wait_until(func(): return _all_stocked(), 40.0)
	main.shift_time_left = window + 2.0
	main.open_store(0)
	return await _sample_crowd(window)

func _all_stocked() -> bool:
	for s in main._unlocked_sections():
		if empty_slot_in(s["name"]) != null:
			return false
	return true

func _run_disruptive() -> void:
	var window: float = 600.0 if "--long" in OS.get_cmdline_user_args() else main._selling_window()
	var r := await _open_and_measure(window)
	var o := _crowd_report("day %d" % main.current_day, r, window)
	var ratio: float = main.CUSTOMER_DISRUPTIVE_RATIO
	# The fix's promise: the ratio holds for the crowd on the floor, all
	# window long — not just for the first wave.
	for i in 3:
		check(o["arrivals"][i] > 0, "third %d: red customers still arriving (%d)" % [i + 1, o["arrivals"][i]])
		check(absf(o["share"][i] - ratio) <= 0.12, "third %d: live red share %d%% within 12 pts of the %d%% ratio" % [i + 1, roundi(o["share"][i] * 100), roundi(ratio * 100)])
		check(o["present"][i] >= 0.9, "third %d: a red customer on the floor %d%% of the time (>= 90%%)" % [i + 1, roundi(o["present"][i] * 100)])
	finish()

## Co-op: the host measures as above; each client counts the reds IT sees
## (its replicated copies) every second, so a client view that stops showing
## reds the host has would show up here.
func _run_net_disruptive_host() -> void:
	var window: float = 600.0 if "--long" in OS.get_cmdline_user_args() else main._selling_window()
	DirAccess.make_dir_recursive_absolute(NET_DIR)
	for f in DirAccess.get_files_at(NET_DIR):
		DirAccess.remove_absolute(NET_DIR + f)
	var r := await _open_and_measure(window)
	_net_write("host_crowd.json", {"samples": r["samples"]})
	var o := _crowd_report("co-op host", r, window)
	var ratio: float = main.CUSTOMER_DISRUPTIVE_RATIO
	for i in 3:
		check(o["arrivals"][i] > 0, "co-op third %d: red customers still arriving (%d)" % [i + 1, o["arrivals"][i]])
		check(absf(o["share"][i] - ratio) <= 0.15, "co-op third %d: live red share %d%% near the %d%% ratio" % [i + 1, roundi(o["share"][i] * 100), roundi(ratio * 100)])
	main.shift_time_left = 0.01 # ends the window (the clock check needs a running clock)
	for id in main.players:
		if id == 1:
			continue
		var c := await _net_read("client_crowd_%d.json" % id, 60.0)
		var cs: Array = c.get("samples", [])
		var reds := 0
		var late_reds := 0
		var names := {}
		for smp in cs:
			reds += 1 if smp[2] > 0 else 0
			if smp[0] > window * 2.0 / 3.0:
				late_reds += 1 if smp[2] > 0 else 0
		for n in c.get("red_names", []):
			names[n] = true
		print("DISRUPTIVE client %d saw: %d samples, a red customer on its screen in %d of them (%d in the last third), %d distinct red customers" % [id, cs.size(), reds, late_reds, names.size()])
		check(cs.size() > window * 0.8, "client %d sampled the whole window (%d)" % [id, cs.size()])
		check(late_reds > 0, "client %d still saw red customers in the last third" % id)
		check(names.size() >= int(o["arrivals"][0] + o["arrivals"][1] + o["arrivals"][2]) - 2, "client %d saw (nearly) every red customer the host spawned (%d vs %d)" % [id, names.size(), o["arrivals"][0] + o["arrivals"][1] + o["arrivals"][2]])
	finish()

func _run_net_disruptive_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 20.0)
	me = main.multiplayer.get_unique_id()
	await wait_until(func(): return main.store_open, 120.0)
	var samples := []
	var red_names := {}
	var t := 0.0
	while main.store_open and main.shift_active and not main.cleanup_active and t < 900.0:
		var s := 0
		var d := 0
		for c in get_nodes_in_group("customer"):
			if c.role == "disruptive":
				d += 1
				red_names[String(c.name)] = true
			else:
				s += 1
		samples.append([t, s, d])
		await wait(1.0)
		t += 1.0
	_net_write("client_crowd_%d.json" % me, {"samples": samples, "red_names": red_names.keys()})
	print("RESULT: OK (client %d wrote %d samples)" % [me, samples.size()])
	await wait(2.0)
	quit(0)

## =============================================================================
## SHELF STOCK vs BUMPS
## =============================================================================

## Stocked items on one shelf, with the slot they're in.
func _stocked_on(shelf_body: Node) -> Array:
	var out := []
	var shelf: Node = shelf_body.get_node("Shelf")
	for i in shelf.slots.size():
		if shelf._occupant[i] != null:
			out.append(shelf._occupant[i])
	return out

func _first_open_shelf() -> Node:
	for sb in main.shelves:
		if main.is_unlocked_at_pos(sb.global_position) and main._section_name_at(sb.global_position) == "Dry Goods":
			return sb
	return null

## Fills one shelf completely and returns it.
func _fill_shelf(sb: Node) -> void:
	var shelf: Node = sb.get_node("Shelf")
	var sec: String = main._section_name_at(sb.global_position)
	for i in shelf.slots.size():
		if shelf._occupant[i] != null:
			continue
		var pool := loose_products(sec)
		if pool.is_empty():
			main._spawn_product_for(sec)
			await physics_frame
			await physics_frame
			pool = loose_products(sec)
		var obj: RigidBody2D = pool[0]
		move_body(obj, shelf.slots[i].global_position)
		await wait_until(func(): return shelf._occupant[i] == obj, 2.0)

## Drives the player through the slots' row at full walking speed (real key
## presses), back and forth `passes` times; returns how many items left.
func _walk_through_stock(sb: Node, passes: int) -> int:
	var shelf: Node = sb.get_node("Shelf")
	var before := _stocked_on(sb).size()
	var a: Vector2 = shelf.slots[0].global_position
	var b: Vector2 = shelf.slots[shelf.slots.size() - 1].global_position
	var along := (b - a).normalized()
	var start := a - along * 60.0
	var end := b + along * 60.0
	var p := player()
	for k in passes:
		p.teleport_to(start if k % 2 == 0 else end)
		await wait(0.2)
		var goal := end if k % 2 == 0 else start
		var t := 0.0
		while t < 4.0 and p.global_position.distance_to(goal) > 20.0:
			steer((goal - p.global_position).normalized())
			await physics_frame
			t += 1.0 / 60.0
		steer(Vector2.ZERO)
	await wait(0.5)
	return before - _stocked_on(sb).size()

func _run_shelf() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 20.0)
	await wait(1.0)
	main.prep_time_left = 1.0e6
	main.shift_time_left = 1.0e6
	var sb := _first_open_shelf()
	await _fill_shelf(sb)
	var shelf: Node = sb.get_node("Shelf")
	var full: int = shelf.slots.size()
	check(_stocked_on(sb).size() == full, "S0: shelf filled (%d/%d)" % [_stocked_on(sb).size(), full])
	var all_shelved := true
	for o in _stocked_on(sb):
		all_shelved = all_shelved and o.get_node("Carryable").get("shelved") == true and o.collision_layer == 4
	check(all_shelved, "S0: every stocked item is shelved (own physics layer)")
	# 1. A player walking straight through the stocked row, 6 passes.
	var lost := await _walk_through_stock(sb, 6)
	check(lost == 0, "S1: player walked through the stocked row 6x — %d item(s) knocked off" % lost)
	# 2. Loose stock shoved / thrown into it.
	var sec: String = main._section_name_at(sb.global_position)
	main._spawn_product_for(sec)
	await wait(0.2)
	var loose: RigidBody2D = loose_products(sec)[0]
	var target: Vector2 = shelf.slots[1].global_position
	for k in 3:
		move_body(loose, target + Vector2(0, 90))
		await physics_frame
		loose.linear_velocity = Vector2(0, -620) # a full-speed throw, straight into the slot
		await wait(0.8)
	check(_stocked_on(sb).size() == full, "S2: three thrown products into the stocked row — %d/%d still stocked" % [_stocked_on(sb).size(), full])
	# ...and the thrown one bounced off rather than coming to rest inside the
	# occupied slot (it would drop into it the moment the stocked item sold —
	# a free "restock" the net-orders test caught).
	await wait(0.6)
	var overlap := 1.0e9
	for i in shelf.slots.size():
		overlap = minf(overlap, loose.global_position.distance_to(shelf.slots[i].global_position))
	check(overlap > shelf.CAPTURE_RADIUS, "S2: the thrown product isn't resting inside a stocked slot (nearest slot %.0fpx, capture %.0f)" % [overlap, shelf.CAPTURE_RADIUS])
	var occ0: RigidBody2D = shelf._occupant[1]
	occ0.get_node("Carryable").try_pickup(1, occ0.global_position)
	await wait(0.6)
	check(shelf._occupant[1] == null or shelf._occupant[1] == occ0, "S2: taking a stocked item off doesn't let a loose one auto-stock in its place")
	occ0.get_node("Carryable").try_drop(1)
	await wait(0.3)
	move_body(occ0, occ0.global_position + Vector2(0, 250))
	await wait(0.3)
	# 3. A remote-style push request from a player is refused by the host.
	var victim: RigidBody2D = _stocked_on(sb)[0]
	var pos0 := victim.global_position
	victim.get_node("Carryable").request_push(Vector2(0, 400)) # local call = sender 0 (a hazard) — expected to knock it
	await wait(0.6)
	check(not shelf.contains(victim) and victim.collision_layer == 1, "S3: a hazard's push (sender 0) still knocks a shelved item off and it collides again (moved %.0fpx)" % victim.global_position.distance_to(pos0))
	await _fill_shelf(sb)
	# 4. Picking a shelved item up is unchanged: E right in front of it.
	var p := player()
	var pick: RigidBody2D = _stocked_on(sb)[0]
	var aisle: Vector2 = -sb.global_transform.y.normalized() # slots sit at shelf-local -y: this points into the aisle
	p.teleport_to(pick.global_position + aisle * 40.0)
	await wait(0.3)
	for o in get_nodes_in_group("carryable"):
		if o != pick and not o.get_node("Carryable").shelved and o.global_position.distance_to(p.global_position) < 90.0:
			move_body(o, o.global_position + Vector2(0, 200)) # nothing loose nearer
	await wait(0.2)
	await tap("host_interact")
	await wait(0.3)
	check(pick.get_node("Carryable").carrier_id == 1, "S4: E in front of a stocked item still picks it up")
	check(not shelf.contains(pick), "S4: and it left the shelf")
	# Put it back with C, like a player.
	var slot_i := -1
	for i in shelf.slots.size():
		if shelf._occupant[i] == null:
			slot_i = i
	var slot_pos: Vector2 = shelf.slots[slot_i].global_position
	p.teleport_to(slot_pos + aisle * 30.0)
	await wait(0.2)
	p.facing_angle = (slot_pos - p.global_position).angle()
	await physics_frame
	await tap("host_place")
	await wait_until(func(): return shelf.contains(pick), 2.0)
	check(shelf.contains(pick) and pick.get_node("Carryable").shelved, "S5: placed back with C, it's shelved again")
	# 5. A disruptive customer walking into the stock still knocks it.
	await _fill_shelf(sb)
	main._spawn_customer("disruptive")
	await physics_frame
	await physics_frame
	var red: CharacterBody2D = null
	for c in get_nodes_in_group("customer"):
		if c.role == "disruptive":
			red = c
	check(red != null and red.collision_mask & 4 != 0, "S6: a disruptive customer's mask includes the shelf-stock layer")
	var knocked_by_red := 0
	for k in 3:
		var tgt: Vector2 = shelf.slots[k % shelf.slots.size()].global_position
		red.position = tgt + Vector2(0, 70)
		red.reset_physics_interpolation()
		red._retarget_pos = tgt + Vector2(0, -20)
		red._retarget_timer = 5.0
		red._lifetime = 0.0
		await wait(1.5)
	knocked_by_red = full - _stocked_on(sb).size()
	check(knocked_by_red > 0, "S6: a disruptive customer walked into the stock and knocked %d item(s) off" % knocked_by_red)
	red.force_leave()
	await wait(0.3)
	# 6. A shopper walking through it does not.
	await _fill_shelf(sb)
	main._spawn_customer("shopper")
	await physics_frame
	await physics_frame
	var blue: CharacterBody2D = null
	for c in get_nodes_in_group("customer"):
		if c.role == "shopper":
			blue = c
	blue.position = shelf.slots[0].global_position + Vector2(-60, 0)
	blue.reset_physics_interpolation()
	var tt := 0.0
	var goal: Vector2 = shelf.slots[shelf.slots.size() - 1].global_position + Vector2(60, 0)
	while tt < 3.0:
		blue.position = blue.position.move_toward(goal, 200.0 / 60.0)
		blue.velocity = Vector2.ZERO
		await physics_frame
		tt += 1.0 / 60.0
	await wait(0.5)
	check(_stocked_on(sb).size() == full, "S7: a shopper dragged through the stocked row — %d/%d still stocked" % [_stocked_on(sb).size(), full])
	blue.force_leave()
	# 7. A real forklift ram still wrecks a (Produce) shelf and spills its stock.
	await _run_ram_check()
	finish()

## Day 3+: the Produce forklift rams a full Produce shelf for real.
func _run_ram_check() -> void:
	var f := fk()
	if not f.active:
		check(false, "S8: the forklift isn't running (needs --day=3+)")
		return
	var fk_sec: String = main._section_name_at(f.home_position)
	var target_sb: Node = null
	for sb in main.shelves:
		if main._section_name_at(sb.global_position) == fk_sec:
			target_sb = sb
			break
	# The forklift only drives while the store's open (not in prep).
	main.test_hold_customers = true
	main.open_store(0)
	await _fill_shelf(target_sb)
	var full: int = target_sb.get_node("Shelf").slots.size()
	check(_stocked_on(target_sb).size() == full, "S8: %s shelf full before the ram (%d)" % [fk_sec, full])
	var rams0: int = f.rams_today
	# Wait for the forklift's own route to ram something — up to 3 minutes —
	# re-stocking every Produce shelf so whichever it picks is full.
	var spilled := 0
	var wrecked_sb: Node = null
	var t := 0.0
	while t < 180.0 and f.rams_today == rams0:
		for sb in main.shelves:
			if main._section_name_at(sb.global_position) == fk_sec and not sb.get_node("Shelf").wrecked and _stocked_on(sb).size() < sb.get_node("Shelf").slots.size():
				await _fill_shelf(sb)
		await wait(0.5)
		t += 0.5
	for sb in main.shelves:
		if sb.get_node("Shelf").wrecked:
			wrecked_sb = sb
	check(f.rams_today > rams0 and wrecked_sb != null, "S8: the forklift rammed and wrecked a shelf (%d ram(s), %.0fs)" % [f.rams_today - rams0, t])
	if wrecked_sb != null:
		spilled = _stocked_on(wrecked_sb).size()
		var knocked := 0
		for o in get_nodes_in_group("carryable"):
			if o.has_meta("knocked") and o.global_position.distance_to(wrecked_sb.global_position) < 400.0:
				knocked += 1
				check(not o.get_node("Carryable").shelved and o.collision_layer == 1, "S8: spilled %s is ordinary loose stock again (layer %d)" % [o.name, o.collision_layer])
		check(spilled == 0 and knocked > 0, "S8: the wreck emptied the shelf (%d left) and spilled %d item(s)" % [spilled, knocked])

## Co-op: two clients walk their own players (client_* keys, their own
## physics) through a stocked row; the host checks nothing moved.
func _run_net_shelf_host() -> void:
	DirAccess.make_dir_recursive_absolute(NET_DIR)
	for f in DirAccess.get_files_at(NET_DIR):
		DirAccess.remove_absolute(NET_DIR + f)
	await wait_until(func(): return main.shift_active and main.players.size() >= int(_arg("players", "3")), 30.0)
	main.prep_time_left = 1.0e6
	main.shift_time_left = 1.0e6
	await wait(1.0)
	var sb := _first_open_shelf()
	await _fill_shelf(sb)
	var shelf: Node = sb.get_node("Shelf")
	var full: int = shelf.slots.size()
	var names := []
	for o in _stocked_on(sb):
		names.append(String(o.name))
	_net_write("shelf.json", {"path": String(sb.get_path()), "items": names})
	var done := 0
	var clients: int = main.players.size() - 1
	var t := 0.0
	while done < clients and t < 90.0:
		done = 0
		for id in main.players:
			if id != 1 and FileAccess.file_exists(NET_DIR + "walked_%d.json" % id):
				done += 1
		await wait(0.5)
		t += 0.5
	check(done == clients, "NS: %d/%d clients walked the stocked row" % [done, clients])
	check(_stocked_on(sb).size() == full, "NS: after every client walked through the stocked row 6x, %d/%d still stocked (host)" % [_stocked_on(sb).size(), full])
	for id in main.players:
		if id == 1:
			continue
		var r := await _net_read("walked_%d.json" % id, 5.0)
		check(r.get("shelved_seen", 0) == full, "NS: client %d saw all %d items on the shelf layer (%d)" % [id, full, r.get("shelved_seen", 0)])
		check(r.get("passes", 0) >= 6, "NS: client %d made %d passes" % [id, r.get("passes", 0)])
	# The host's own player too, then a hazard push still works over the net.
	var lost := await _walk_through_stock(sb, 4)
	check(lost == 0, "NS: host player walked through it 4x — %d knocked off" % lost)
	_net_write("host_done.json", {"ok": true})
	await wait(1.0)
	finish()

func _run_net_shelf_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 20.0)
	me = main.multiplayer.get_unique_id()
	act = "client_"
	var info := await _net_read("shelf.json", 60.0)
	var sb: Node = main.get_node_or_null(NodePath(info.get("path", "")))
	if sb == null:
		print("FAIL  client couldn't find the shelf")
		quit(1)
		return
	await wait(1.0)
	var shelved_seen := 0
	for n in info["items"]:
		var o = main.products_root.get_node_or_null(NodePath(n))
		if o != null and o.get_node("Carryable").shelved and o.collision_layer == 4:
			shelved_seen += 1
	var shelf: Node = sb.get_node("Shelf")
	var a: Vector2 = shelf.slots[0].global_position
	var b: Vector2 = shelf.slots[shelf.slots.size() - 1].global_position
	var along := (b - a).normalized()
	var p := player()
	var passes := 0
	# Stagger the clients so they don't block each other.
	await wait(2.0 * (me % 3))
	for k in 6:
		var start := (a - along * 60.0) if k % 2 == 0 else (b + along * 60.0)
		var goal := (b + along * 60.0) if k % 2 == 0 else (a - along * 60.0)
		p.teleport_to(start)
		await wait(0.3)
		var t := 0.0
		while t < 4.0 and p.global_position.distance_to(goal) > 20.0:
			steer((goal - p.global_position).normalized())
			await physics_frame
			t += 1.0 / 60.0
		steer(Vector2.ZERO)
		passes += 1
	_net_write("walked_%d.json" % me, {"shelved_seen": shelved_seen, "passes": passes})
	await _net_read("host_done.json", 60.0)
	print("RESULT: OK (client %d: %d passes, saw %d shelved)" % [me, passes, shelved_seen])
	quit(0)

## =============================================================================
## PICKUP RADIUS
## =============================================================================

func _clear_around(pos: Vector2, r: float, keep: Node) -> void:
	for o in get_nodes_in_group("carryable"):
		if o != keep and o.global_position.distance_to(pos) < r:
			move_body(o, o.global_position + (o.global_position - pos).normalized() * (r + 40.0))

func _run_pickup() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 20.0)
	main.prep_time_left = 1.0e6
	main.shift_time_left = 1.0e6
	await wait(1.0)
	var p := player()
	var R: float = load("res://Carryable.gd").PICKUP_RANGE
	check(R == main.STORE_SIGN_RANGE and R == main.TIME_CLOCK_RANGE, "P0: stock pickup radius (%.0f) is the store's shared E radius (sign %.0f, time clock %.0f)" % [R, main.STORE_SIGN_RANGE, main.TIME_CLOCK_RANGE])
	# 1. Wait for a real delivery crate and unpack it on its pad, by hand.
	var box: Node2D = null
	await wait_until(func(): return not get_nodes_in_group("delivery_box").is_empty(), 60.0)
	box = get_nodes_in_group("delivery_box")[0]
	await wait_until(func(): return box.get_node("Carryable").carrier_id == 0 and box.linear_velocity.length() < 5.0, 10.0)
	# Pick the crate itself up from 60px — off-axis, no lining up.
	_clear_around(box.global_position, 140.0, box)
	p.teleport_to(box.global_position + Vector2(-42, 42))
	await wait(0.3)
	await tap("host_interact")
	await wait(0.3)
	check(box.get_node("Carryable").carrier_id == 1, "P1: picked up the delivery crate from %.0fpx, diagonally" % p.global_position.distance_to(box.global_position))
	var sec: String = box.get_meta("section")
	var pad: Vector2 = dl().pad_center(sec)
	p.teleport_to(pad - Vector2(box.get_node("Carryable").carry_distance + 2.0, 0))
	p.facing_angle = 0.0
	await wait(0.3)
	var box_id := box.get_instance_id()
	await tap("host_interact")
	await wait_until(func(): return not is_instance_id_valid(box_id), 3.0)
	check(not is_instance_id_valid(box_id), "P2: the crate unpacked on its pad")
	await wait(1.5)
	# 2. Grab each unpacked product from a range of distances / angles.
	var spilled := loose_products(sec)
	var dists := [30.0, 45.0, 55.0, 62.0, 68.0]
	var got := 0
	var tries := 0
	for i in mini(dists.size(), spilled.size()):
		var obj: RigidBody2D = spilled[i]
		await wait_until(func(): return obj.linear_velocity.length() < 5.0, 3.0)
		_clear_around(obj.global_position, dists[i] + 80.0, obj)
		await wait(0.2)
		# A random angle whose spot is clear (a teleport into a shelf or wall
		# gets pushed back out, which would test the wrong distance).
		var ang := randf() * TAU
		var d := 0.0
		for attempt in 8:
			p.teleport_to(obj.global_position + Vector2.RIGHT.rotated(ang) * dists[i])
			await wait(0.25)
			d = p.global_position.distance_to(obj.global_position)
			if absf(d - dists[i]) < 6.0:
				break
			ang += TAU / 8.0
		await tap("host_interact")
		await wait(0.25)
		tries += 1
		var ok: bool = obj.get_node("Carryable").carrier_id == 1
		got += 1 if ok else 0
		print("PICKUP  product %s from %.0fpx at %.0f deg: %s" % [obj.name, d, rad_to_deg(ang), "got it" if ok else "MISSED"])
		if ok:
			await tap("host_interact") # put it down
			await wait(0.3)
			move_body(obj, obj.global_position + Vector2(0, 300))
	check(got == tries and tries >= 4, "P3: %d/%d presses within %.0fpx picked up the unpacked stock (first try, any angle)" % [got, tries, R])
	# 3. Out of reach is still out of reach.
	var far: RigidBody2D = loose_products(sec)[0]
	_clear_around(far.global_position, 160.0, far)
	p.teleport_to(far.global_position + Vector2(R + 15.0, 0))
	await wait(0.3)
	await tap("host_interact")
	await wait(0.3)
	check(far.get_node("Carryable").carrier_id == 0, "P4: %.0fpx away (past the radius) is still out of reach" % (R + 15.0))
	# 4. The host accepts a client's press at the edge (client/host agree).
	var c: Node = far.get_node("Carryable")
	var slack: float = c.PICKUP_NET_SLACK if "PICKUP_NET_SLACK" in c else 0.0
	c._validate_pickup(2, far.global_position + Vector2(R + slack - 1.0, 0))
	await physics_frame
	check(c.carrier_id == 2, "P5: the host accepts a (client's) press from %.0fpx — the radius plus %.0fpx net slack" % [R + slack - 1.0, slack])
	c.force_drop_if_carrier(2)
	await physics_frame
	c._validate_pickup(2, far.global_position + Vector2(R + slack + 6.0, 0))
	await physics_frame
	check(c.carrier_id == 0, "P5: and refuses one from %.0fpx" % (R + slack + 6.0))
	finish()

## =============================================================================
## TRASH
## =============================================================================

func _run_trash() -> void:
	shots = DisplayServer.get_name() != "headless"
	await wait_until(func(): return main.shift_active and main.players.has(1), 20.0)
	await wait(1.0)
	main.prep_time_left = 0.0
	await wait_until(func(): return main.store_open, 5.0)
	main.test_hold_customers = true
	var cl: Node = main.cleanup
	var p := player()
	var pay0: int = main._pay_today()
	var juice: Node = main.juice
	var pops := []
	juice.fired.connect(func(kind, pos): if kind == "litter_pay": pops.append(pos))
	# 1. Mid-shift: 5 pieces, picked up by hand with E.
	var hub: Vector2 = cell_center(main.ENTRANCE_GRID_POS)
	var ids := []
	for i in 5:
		ids.append(cl.drop_litter(hub + Vector2(i * 120.0 - 240.0, 40.0)))
	await wait(0.3)
	for o in get_nodes_in_group("carryable"):
		if o.global_position.distance_to(hub) < 400.0:
			move_body(o, o.global_position + Vector2(0, 400))
	var hinted := 0
	for i in ids.size():
		var at: Vector2 = hub + Vector2(i * 120.0 - 240.0, 40.0)
		p.teleport_to(at + Vector2(-35, 30))
		await wait(0.3)
		if cl._hint.visible and cl._hint.text.begins_with("E: pick up trash"):
			hinted += 1
		if i == 0:
			await shot("trash_hint")
		await tap("host_interact")
		if i == 0:
			await wait(0.12)
			await shot("trash_popup")
		await wait(0.3)
	check(cl.litter.size() == 0, "T1: 5 pieces picked up by hand mid-shift (%d left)" % cl.litter.size())
	check(cl.litter_collected_today == 5 and main._pay_today() - pay0 == 5, "T1: +$1 each — collected %d, pay +$%d" % [cl.litter_collected_today, main._pay_today() - pay0])
	check(hinted == 5, "T1: the 'E: pick up trash' hint showed at every piece (%d/5)" % hinted)
	check(pops.size() == 5, "T2: a +$1 popup at every piece (%d)" % pops.size())
	await wait(1.4)
	check(juice.popups.filter(func(x): return x["text"].begins_with("+$")).is_empty(), "T2: and they've all faded after %.1fs (none left)" % (juice.POPUP_LIFE + 0.3))
	# 2. E near trash AND near stock: the nearer one wins; shelved stock never.
	var prod: RigidBody2D = null
	main._spawn_product_for("Dry Goods")
	await physics_frame
	await physics_frame
	prod = loose_products("Dry Goods")[0]
	move_body(prod, hub + Vector2(0, 150))
	var lid: int = cl.drop_litter(hub + Vector2(45, 150))
	await wait(0.3)
	p.teleport_to(hub + Vector2(45, 190)) # trash 40px, product 60px: stock still wins
	await wait(0.3)
	await tap("host_interact")
	await wait(0.3)
	check(prod.get_node("Carryable").carrier_id == 1 and cl.litter.size() == 1, "T3: loose stock and trash both in reach -> E picks up the stock (product %.0fpx, trash %.0fpx, carrier %d, litter %d)" % [p.global_position.distance_to(prod.global_position), p.global_position.distance_to(hub + Vector2(45, 150)), prod.get_node("Carryable").carrier_id, cl.litter.size()])
	await tap("host_interact")
	await wait(0.3)
	move_body(prod, hub + Vector2(0, 400))
	await wait(0.2)
	p.teleport_to(hub + Vector2(45, 190))
	await wait(0.3)
	await tap("host_interact")
	await wait(0.3)
	check(cl.litter.size() == 0, "T3: no loose stock in reach -> E picks up the trash")
	# 3. A burst: 12 pieces swept together at close coalesce, no clutter.
	var before_pops := pops.size()
	for i in 12:
		cl.drop_litter(hub + Vector2(randf_range(-30, 30), 260.0 + randf_range(-20, 20)))
	await wait(0.2)
	main.shift_time_left = 0.01 # the clock check only fires on a running clock
	await wait_until(func(): return main.cleanup_active, 5.0)
	await wait(0.3)
	var collected0: int = cl.litter_collected_today
	var bonus_before: int = cl.clean_bonus_today
	# Grab a broom and sweep the patch with C held.
	var tool := -1
	for i in cl.tools.size():
		if cl.tools[i]["kind"] == "broom":
			tool = i
	p.teleport_to(cl.tools[tool]["pos"] + Vector2(0, 20))
	await wait(0.3)
	await tap("host_interact")
	await wait(0.3)
	check(cl.tool_of(1) >= 0 and cl.tools[cl.tool_of(1)]["kind"] == "broom", "T4: picked up a broom (holding %d, at %s, tool at %s, cleanup %s)" % [cl.tool_of(1), p.global_position, cl.tools[tool]["pos"], main.cleanup_active])
	var peak := 0
	p.teleport_to(hub + Vector2(-30, 260))
	p.facing_angle = 0.0
	await wait(0.3)
	press("host_place")
	var t := 0.0
	var shot_sweep := false
	while t < 4.0 and cl.litter.size() > 0:
		steer(Vector2(0.3, 0.0) if fmod(t, 2.0) < 1.0 else Vector2(-0.3, 0.0))
		peak = maxi(peak, juice.popups.size())
		if not shot_sweep and cl.litter_collected_today - collected0 >= 4:
			shot_sweep = true
			await shot("trash_sweep_coalesced")
		await physics_frame
		t += 1.0 / 60.0
	Input.action_release("host_place")
	steer(Vector2.ZERO)
	var swept: int = cl.litter_collected_today - collected0
	check(swept >= 8, "T4: the broom swept %d pieces (pan holds %d)" % [swept, cl.pan_capacity()])
	check(pops.size() - before_pops == swept, "T4: one +$ per swept piece counted (%d)" % (pops.size() - before_pops))
	var live_litter_pops: int = juice.popups.filter(func(x): return String(x["key"]).begins_with("litter")).size()
	print("TRASH  sweep of %d pieces: %d live +$ popup(s) at once (coalesced), %d popups peak overall, cap %d, dropped by cap %d" % [swept, live_litter_pops, peak, juice.MAX_POPUPS, juice.dropped])
	check(peak <= 3, "T4: a sweep coalesces into at most 3 popups on screen (peak %d)" % peak)
	# 4. The cleanliness bonus math is untouched: the formula on the gross.
	main._sold_at_day_start -= 20 # as if 20 sales happened today (a non-zero gross to take a share of)
	main.clock_out(1)
	await wait_until(func(): return main.is_day_report_active(), 5.0)
	await wait(0.3)
	var expect := int(round(maxf(0.0, float(main._gross_pay_today())) * cl.CLEAN_BONUS_MAX * (0.5 * cl.mop_fraction() + 0.5 * cl.litter_fraction())))
	check(cl.clean_bonus_today == expect and expect > 0, "T5: cleanliness bonus is the unchanged formula on the gross ($%d == $%d, gross $%d, litter %d%%) — trash pay isn't in it" % [cl.clean_bonus_today, expect, main._gross_pay_today(), roundi(cl.litter_fraction() * 100)])
	check(main._pay_today() == main._gross_pay_today() + cl.clean_bonus_today + cl.litter_collected_today - main.writeups_today * main.WRITEUP_PENALTY - main.break_room.dollars_today(), "T5: pay = gross + bonus + $1 x %d pieces" % cl.litter_collected_today)
	check(main.report_cleanup_label.text.contains("trash picked up (%d)" % cl.litter_collected_today), "T5: the report shows the trash line: %s" % main.report_cleanup_label.text.replace("\n", " / "))
	var snap: Dictionary = load("res://SaveGame.gd").snapshot(main)
	check(snap["week"]["litter_pay"] == cl.litter_pay_week and cl.litter_pay_week == cl.litter_collected_today, "T6: the week's trash pay is in the save ($%d)" % snap["week"]["litter_pay"])
	var round_trip: Dictionary = load("res://SaveGame.gd").sanitize({"version": 1, "week": {"sold": 3}})
	check(round_trip["week"]["litter_pay"] == 0, "T6: an older save without it loads as $0")
	finish()

## =============================================================================
## PRACTICE SHIFT
## =============================================================================

## Walks this process's player to `goal` with real key presses.
func _walk_to(goal: Vector2, timeout := 20.0, stop_at := 24.0) -> bool:
	var p := player()
	var t := 0.0
	var stuck := 0.0
	var last := p.global_position
	var jig := Vector2.ZERO
	var jig_t := 0.0
	while t < timeout and p.global_position.distance_to(goal) > stop_at:
		var wp := waypoint(p.global_position, goal)
		var dir := (wp - p.global_position).normalized()
		if jig_t > 0.0:
			jig_t -= 1.0 / 60.0
			dir = (dir + jig).normalized()
		steer(dir)
		await physics_frame
		t += 1.0 / 60.0
		stuck += 1.0 / 60.0
		if stuck > 0.6:
			if p.global_position.distance_to(last) < 12.0:
				jig = dir.orthogonal() * (1.0 if randf() < 0.5 else -1.0)
				jig_t = 0.5
			last = p.global_position
			stuck = 0.0
	steer(Vector2.ZERO)
	return p.global_position.distance_to(goal) <= stop_at

func _tut() -> Node:
	return main.tutorial

func _await_step(id: String, timeout: float) -> bool:
	return await wait_until(func(): return _tut().current_id() != id, timeout)

## The step card never covers a hazard cue or the step's own target.
func _card_clear(what: String, world_pos: Vector2) -> void:
	var tut := _tut()
	await process_frame
	var pt: Vector2 = tut.get_viewport().get_canvas_transform() * world_pos
	var r: Rect2 = tut._card.get_global_rect()
	check(not r.has_point(pt) or tut._card.modulate.a < 0.5, "CARD: the step card (%s side) doesn't cover %s (at %s, card %s)" % ["right" if tut.card_side == 1 else "left", what, pt.round(), r])

func _shot_tutorial(name: String) -> void:
	await shot("practice_" + name)

func _run_practice(net := false) -> void:
	shots = DisplayServer.get_name() != "headless"
	var tut := _tut()
	if net:
		DirAccess.make_dir_recursive_absolute(NET_DIR)
		for f in DirAccess.get_files_at(NET_DIR):
			DirAccess.remove_absolute(NET_DIR + f)
		await wait_until(func(): return main.players.size() >= int(_arg("players", "2")), 30.0)
	await wait_until(func(): return tut.active and main.shift_active and main.players.has(1), 20.0)
	await wait(0.5)
	check(main.current_day == 1 and main.hazard_levels()["manager"] == 1 and main.manager.active, "PR0: practice = Day 1 + the manager on (day %d, manager %s)" % [main.current_day, main.manager.active])
	check(tut._card.visible and tut._title.text.begins_with("PRACTICE SHIFT  ·  1/"), "PR0: the step card is up: %s" % tut._title.text)
	check(not main.store_open and main.prep_time_left > 1000.0, "PR0: no clock (prep pinned at %.0f)" % main.prep_time_left)
	await _shot_tutorial("01_move")
	var t0 := _wall()
	# 1. Move.
	await _walk_to(cell_center(Vector2i(1, 0)), 15.0, 60.0)
	check(await _await_step("move", 5.0), "PR1: walking out of the break room finished 'move'")
	# 2. Crate.
	await wait_until(func(): return not get_nodes_in_group("delivery_box").is_empty(), 60.0)
	await _shot_tutorial("02_crate")
	var box: Node2D = null
	var picked := false
	var tries := 0
	while not picked and tries < 4:
		tries += 1
		box = null
		for b in get_nodes_in_group("delivery_box"):
			if b.get_node("Carryable").carrier_id == 0:
				box = b
		if box == null:
			await wait(1.0)
			continue
		await _walk_to(box.global_position, 25.0, 50.0)
		await tap("host_interact")
		await wait(0.3)
		picked = box.get_node("Carryable").carrier_id == 1
	check(picked and await _await_step("crate", 3.0), "PR2: picked up a crate (%d tries) -> step done" % tries)
	# 3. Unpack on its pad.
	var sec: String = box.get_meta("section")
	var pad: Vector2 = dl().pad_center(sec)
	check(tut._marker_pos.distance_to(pad) < 1.0, "PR3: the marker points at the %s pad" % sec)
	await _shot_tutorial("03_unpack")
	await _walk_to(pad - Vector2(box.get_node("Carryable").carry_distance, 0), 30.0, 16.0)
	player().facing_angle = 0.0
	await physics_frame
	await tap("host_interact")
	check(await _await_step("unpack", 4.0), "PR3: set it down on the pad -> unpacked -> step done")
	# 4. Stock two items.
	await wait(1.5)
	await _shot_tutorial("04_stock")
	var placed := 0
	for k in 4:
		if tut.current_id() != "stock":
			break
		var pool := loose_products(sec)
		if pool.is_empty():
			break
		var obj: RigidBody2D = pool[0]
		await _walk_to(obj.global_position, 15.0, 45.0)
		await tap("host_interact")
		await wait(0.3)
		if obj.get_node("Carryable").carrier_id != 1:
			continue
		var slot := empty_slot_in(sec)
		# Stand so the carry offset lands on the slot: 30px out from it,
		# toward the aisle, facing the slot.
		var outward: Vector2 = -slot.get_parent().global_transform.y.normalized()
		await _walk_to(slot.global_position + outward * 30.0, 15.0, 8.0)
		player().facing_angle = (-outward).angle()
		await wait(0.1)
		await tap("host_place")
		await wait(0.8)
		placed = tut._placed
	check(tut.current_id() != "stock" and tut._placed >= 2, "PR4: placed %d item(s) with C -> step done" % tut._placed)
	# 5. Register.
	await _shot_tutorial("05_register")
	var reg: Vector2 = tut._marker_pos
	await _walk_to(reg, 25.0, 60.0)
	check(await _await_step("register", 4.0), "PR5: stood at a register -> step done")
	# 6. Manager: he stops on his rounds facing you; stand still in his sight
	# until the "?" (watch) comes up, then get busy and it clears.
	await _shot_tutorial("06_manager")
	var m: Node2D = main.manager
	var watched := false
	# Off the registers first (standing at one counts as working).
	await _walk_to(player().global_position + Vector2(0, -170), 6.0, 20.0)
	var spot: Vector2 = player().global_position
	pin_manager(spot + Vector2(-150, 0), 0.0) # 150px west of me, looking right at me
	steer(Vector2.ZERO)
	var t := 0.0
	while t < 15.0 and not watched:
		await wait(0.25)
		t += 0.25
		watched = m.watch_peer == 1 and m.watch_level > 0.0
	if watched:
		await _shot_tutorial("06b_manager_watching")
		await _card_clear("the watching manager", m.global_position)
	check(watched, "PR6: standing idle in his cone got me watched (the ?) after %.1fs" % t)
	release_manager()
	var t2 := 0.0
	while tut.current_id() == "manager" and t2 < 30.0:
		await tap("host_interact") # grab whatever's near: busy
		steer(Vector2(1, 0) if fmod(t2, 2.0) < 1.0 else Vector2(-1, 0))
		await wait(0.25)
		t2 += 0.25
	steer(Vector2.ZERO)
	t += t2
	check(tut.current_id() != "manager" and t < tut.MANAGER_FALLBACK_TIME, "PR6: caught idle, then got busy -> the manager step finished (%.0fs)" % t)
	check(main.writeups_today == 0, "PR6: no write-up counted in practice (%d)" % main.writeups_today)
	# 7. Forklift.
	# Put down anything in hand, then go and watch it from the lane's edge.
	for o in get_nodes_in_group("carryable"):
		if o.get_node("Carryable").carrier_id == 1:
			await tap("host_interact")
	var tw := 0.0
	# Hub -> Sidewalk -> Storage (Produce, east of the hub, is locked on Day 1).
	await _walk_to(cell_center(Vector2i(1, 2)), 20.0, 60.0)
	await _walk_to(cell_center(Vector2i(2, 2)) + Vector2(-200, -100), 20.0, 60.0)
	while tut.current_id() == "forklift" and tw < 60.0:
		var fkp: Vector2 = main.delivery_forklift.global_position
		await _walk_to(fkp + Vector2(0, -200), 3.0, 60.0)
		tw += 3.0
	var fk_d: float = player().global_position.distance_to(main.delivery_forklift.global_position)
	check(tut.current_id() != "forklift", "PR7: watched the delivery forklift -> step done (%.0fs, %.0fpx from it)" % [tw, fk_d])
	await _shot_tutorial("07_forklift")
	# 8. Open: flip the sign.
	check(tut.current_id() == "open" and tut._marker_pos == main.STORE_SIGN_POS, "PR8: last step points at the Store sign")
	await _card_clear("the delivery forklift", main.delivery_forklift.global_position)
	await _shot_tutorial("08_open")
	if net:
		_net_write("host_at_sign.json", {"ok": true})
		await _net_read("client_done.json", 120.0)
	await _walk_to(main.STORE_SIGN_POS, 40.0, 40.0)
	await _card_clear("the Store sign", main.STORE_SIGN_POS)
	await _shot_tutorial("09_at_sign")
	await tap("host_interact")
	await wait_until(func(): return not tut.active, 3.0)
	check(not tut.active, "PR9: flipping the sign ended practice")
	await wait(0.5)
	check(main.shift_active and main.current_day == 1 and not main.store_open and main.prep_time_left > 100.0 and main.prep_time_left < 1000.0, "PR9: real Day 1 started: prep clock %.0fs, store closed" % main.prep_time_left)
	check(main.hazard_levels()["manager"] == 0 and not main.manager.active, "PR9: manager off again (Day 1)")
	check(get_nodes_in_group("carryable").filter(func(o): return o.get_node("Carryable").shelved).is_empty(), "PR9: practice stock cleared off the shelves")
	check(not tut._card.visible, "PR9: card gone")
	print("PRACTICE  played through in %.0fs (wall), steps %s" % [_wall() - t0, str(tut.completed)])
	finish()

func _run_practice_skip() -> void:
	var tut := _tut()
	await wait_until(func(): return tut.active and main.shift_active and main.players.has(1), 20.0)
	await wait(0.5)
	var ev := InputEventKey.new()
	ev.keycode = KEY_TAB
	ev.pressed = true
	root.push_input(ev)
	await wait(0.5)
	check(not tut.active, "PK1: Tab skipped practice")
	check(main.shift_active and main.current_day == 1 and main.prep_time_left < 1000.0, "PK1: straight into a real Day 1 (prep %.0fs)" % main.prep_time_left)
	check(main._status_text().begins_with("Day 1"), "PK1: status line: %s" % main._status_text())
	finish()

func _run_net_practice_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 20.0)
	me = main.multiplayer.get_unique_id()
	act = "client_"
	var tut := _tut()
	await wait_until(func(): return tut.active and main.shift_active, 20.0)
	await wait(0.5)
	check(tut._card.visible and tut._body.text.contains("arrow keys"), "NC0: client sees its own card with its own keys")
	check(main.manager.active, "NC0: the manager is on for the client too")
	# Walk out, grab stock and place one — the client's own steps.
	await _walk_to(Vector2(1440, 700), 20.0, 80.0)
	check(tut.current_id() != "move", "NC1: client's 'move' step done (%s)" % tut.current_id())
	await _net_read("host_at_sign.json", 300.0)
	check(tut.active, "NC2: practice still on while the host is at the sign")
	_net_write("client_done.json", {"steps": tut.completed})
	await wait_until(func(): return not tut.active, 60.0)
	check(not tut.active and not tut._card.visible, "NC3: practice ended for the client when the host flipped the sign")
	await wait(1.0)
	check(main.current_day == 1 and not main.manager.active, "NC3: client back on Day 1, manager off")
	print("RESULT: %s (client)" % ("OK" if fails == 0 else "FAILED"))
	quit(1 if fails else 0)
