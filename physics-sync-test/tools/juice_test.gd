extends SceneTree
## WEEK 27 test harness — juice (Juice.gd). Loads the real Main.tscn and drives
## the real game code; checks WHICH effects fire WHEN, on WHICH peer, that each
## fires ONCE per event (no per-frame re-trigger), that every popup/particle/
## shake dies away (nothing persists or stacks), and that the caps hold under
## load. Not part of the game.
##
## Solo, every system on (Day 7): pickup/drop/throw pops, shelf place, sales
## (+ coalescing), a rush bonus, orders, spill, write-up, forklift bonk, shelf
## wreck, display topple, thuds, cleanup sparkles + SPOTLESS, the report:
##   godot --headless --path . --script res://tools/juice_test.gd -- --server --day=7 --no-save --test=juice
## Endless: Day 7 report -> Week Complete confetti -> hub -> a posting -> the
## medal stamp + "+N Bucks":
##   godot --headless --path . --script res://tools/juice_test.gd -- --server --day=7 --no-save --test=juice-endless
## Co-op (2-4 players): every shared-world effect fires on every peer, once,
## within a beat of the host; shake only for the peer it's about:
##   godot --headless --path . --script res://tools/juice_test.gd -- --server --day=7 --no-save --players=3 --test=net-juice &
##   (x2) godot --headless --path . --script res://tools/juice_test.gd -- --client --no-save --test=net-juice
## Load (needs a real renderer — xvfb-run, no --headless): Day 7 with every
## hazard live + a burst of sales/impacts, frame times with juice on vs off,
## and screenshots (user://juice_shots/):
##   xvfb-run -a godot --path . --script res://tools/juice_test.gd -- --server --day=7 --no-save --test=juice-perf

var main: Node
var juice: Node
var fails := 0
var me := 1
## Every effect this peer fired: [[unix seconds, kind], ...].
var seen: Array = []
var NET_DIR: String = OS.get_environment("SW_NET_DIR") if OS.get_environment("SW_NET_DIR") != "" else "user://net_juice/"

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	# OCT 2026 PHASE 2: written for the 7-day story — Day N -> N+1 hands the
	# crew old Day N+1's sections/earnings (Main.gd's test_follow_old_calendar),
	# and Day 7's report still finishes the week into Endless Mode (the debug
	# --endless route) for the endless checks.
	main.test_follow_old_calendar = true
	main.legacy_endless_route = true
	_hook.call_deferred() # main.juice exists once Main's _ready has run
	root.get_node("Sfx").log_plays = false
	var mode := "juice"
	for a in args:
		if a.begins_with("--test="):
			mode = a.substr(7)
	main.opening_stock_fraction = 1.0
	match mode:
		"juice":
			_run_solo.call_deferred()
		"juice-endless":
			_run_endless.call_deferred()
		"juice-perf":
			_run_perf.call_deferred()
		"net-juice":
			if "--client" in args:
				_run_net_client.call_deferred()
			else:
				_run_net_host.call_deferred()

var place_log := []
func _hook() -> void:
	juice = main.juice
	juice.fired.connect(func(k, p): if k == "shelf_place": place_log.append([Time.get_ticks_msec(), p]))
	juice.fired.connect(func(k, _p): seen.append([Time.get_unix_time_from_system(), k]))

## --- helpers ---------------------------------------------------------------------

func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1

func finish() -> void:
	print("JUICE  %s" % str(_sorted_counts()))
	print("PEAKS  popups %d · particles %d · bursts %d · trauma %.2f · culled %d" % [juice.peak_popups, juice.peak_particles, juice.peak_bursts, juice.peak_trauma, juice.dropped])
	print("RESULT: %s (%d failure%s)" % ["OK" if fails == 0 else "FAILED", fails, "" if fails == 1 else "s"])
	quit(1 if fails else 0)

func _sorted_counts() -> Array:
	var out := []
	var names: Array = juice.counts.keys()
	names.sort()
	for n in names:
		out.append("%s=%d" % [n, juice.counts[n]])
	return out

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

func count(kind: String) -> int:
	return juice.counts.get(kind, 0)

func fired_after(kind: String, before: int, timeout := 1.5) -> bool:
	return await wait_until(func(): return count(kind) > before, timeout)

func player() -> Node2D:
	return main.players[me]

func amb() -> Node2D:
	return main.ambience

func move_body(body: RigidBody2D, pos: Vector2) -> void:
	PhysicsServer2D.body_set_state(body.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, Transform2D(0.0, pos))
	PhysicsServer2D.body_set_state(body.get_rid(), PhysicsServer2D.BODY_STATE_LINEAR_VELOCITY, Vector2.ZERO)
	body.global_position = pos
	body.linear_velocity = Vector2.ZERO

func free_product(color = null) -> RigidBody2D:
	for obj in get_nodes_in_group("carryable"):
		if obj.is_in_group("delivery_box") or obj.get_node("Carryable").carrier_id != 0 or obj.is_queued_for_deletion():
			continue
		if main.shelves.any(func(s): return s.get_node("Shelf").contains(obj)):
			continue
		if color != null and not obj.get_node("Polygon2D").color.is_equal_approx(color):
			continue
		return obj
	return null

func pin_manager(pos: Vector2, heading: float) -> void:
	var m: Node2D = main.manager
	m.position = pos
	m.target_position = pos
	m.facing = heading
	m._look_heading = heading
	m._pause_timer = 1.0e9
	m._legs.clear()

func park_everything() -> void:
	main.test_hold_customers = true
	main.forklift._pause_timer = 1.0e9
	pin_manager(Vector2(480, 1350), 0.0)
	main._order_timer = 1.0e9
	amb()._lights_timer = 1.0e9
	amb()._spill_timer = 1.0e9

func active_cashier() -> Node:
	return main.cashiers.filter(func(c): return c.get_node("Cashier").active)[0]

## Everything fades: no popup, particle or burst left, the shake settled, the
## camera back on centre.
func all_settled() -> bool:
	var cam: Camera2D = player().get_node("Camera")
	return juice.popups.is_empty() and juice.particles.is_empty() and juice.bursts.is_empty() and juice.ui_popups.is_empty() and juice.ui_particles.is_empty() and juice.trauma == 0.0 and cam.offset == Vector2.ZERO

func visuals_scale(body: Node) -> Vector2:
	for c in body.get_children():
		if c is Polygon2D:
			return c.scale
	return Vector2.ONE

## Settled, then nothing new fires for `seconds` (an effect re-triggering every
## frame would show up here).
func quiet_check(label: String, kinds: Array, seconds := 1.5) -> void:
	await wait_until(all_settled, 4.0)
	var n := seen.size()
	await wait(seconds)
	var extra := seen.slice(n).filter(func(h): return h[1] in kinds)
	var cam: Camera2D = player().get_node("Camera")
	var live := "popups %d particles %d bursts %d ui %d/%d trauma %.2f offset %s; last fired: %s" % [juice.popups.size(), juice.particles.size(), juice.bursts.size(), juice.ui_popups.size(), juice.ui_particles.size(), juice.trauma, str(cam.offset), str(seen.slice(maxi(0, seen.size() - 4)).map(func(h): return h[1]))]
	check(all_settled() and extra.is_empty(), "%s: everything faded and nothing re-fired over %.1fs (extra: %s)%s" % [label, seconds, str(extra.map(func(h): return h[1])), "" if all_settled() else "  LIVE: " + live])

## --- solo --------------------------------------------------------------------------

func _run_solo() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 15.0)
	me = 1
	await wait(0.5)
	park_everything()
	await wait(1.6)
	check(juice.z_index == 90 and not juice.z_as_relative and juice.z_index < amb().Z_DARKNESS and juice.z_index < amb().Z_EMISSIVE, "J0 juice draws at z %d: under the darkness (%d) and every hazard marker (%d)" % [juice.z_index, amb().Z_DARKNESS, amb().Z_EMISSIVE])
	check(main.manager.get_node("Alert").z_index == amb().Z_EMISSIVE if main.manager.has_node("Alert") else true, "J0 the manager's alert marker sits at Z_EMISSIVE")

	# J1 pickup / drop / throw: one pop each, back to scale 1.
	player().teleport_to(Vector2(1440, 300))
	await wait(0.3)
	var obj := free_product()
	move_body(obj, player().global_position + Vector2(42, 0))
	await wait(0.2)
	var c0 := count("carry_pickup")
	obj.get_node("Carryable").try_pickup(1, player().global_position)
	check(await fired_after("carry_pickup", c0), "J1 pop on pickup")
	await wait(0.05)
	var mid := visuals_scale(obj)
	check(mid.x > 1.02, "J1 ...the item's visuals scaled up mid-pop (%.2f)" % mid.x)
	await wait(0.4)
	check(visuals_scale(obj).is_equal_approx(Vector2.ONE), "J1 ...and settled back to 1 (%s)" % str(visuals_scale(obj)))
	check(count("carry_pickup") == c0 + 1, "J1 exactly one pickup pop (%d)" % (count("carry_pickup") - c0))
	var d0 := count("carry_drop")
	obj.get_node("Carryable").try_drop(1)
	check(await fired_after("carry_drop", d0), "J1 squash on set-down")
	await wait(0.3)
	obj.get_node("Carryable").try_pickup(1, player().global_position)
	await wait(0.2)
	var t0 := count("carry_throw")
	obj.get_node("Carryable").try_throw(1, Vector2.UP)
	check(await fired_after("carry_throw", t0), "J1 stretch on throw")
	await wait(1.0)
	check(visuals_scale(obj).is_equal_approx(Vector2.ONE), "J1 thrown item back to scale 1 (%s)" % str(visuals_scale(obj)))

	# J2 open the store; a product settling onto a shelf slot.
	main.open_store(1)
	main.forklift._pause_timer = 1.0e9
	await wait(0.3)
	main._order_timer = 1.0e9 # opening re-arms the order clock
	var placed := false
	for shelf_body in main.shelves:
		if placed or not main.is_unlocked_at_pos(shelf_body.global_position) or shelf_body.get_node("Shelf").wrecked:
			continue
		var shelf: Node = shelf_body.get_node("Shelf")
		for i in shelf.slots.size():
			if shelf._is_filled(i):
				continue
			var item := free_product(main.SECTION_COLORS[main._section_name_at(shelf_body.global_position)])
			if item == null:
				continue
			var s0 := count("shelf_place")
			move_body(item, shelf.slots[i].global_position)
			placed = await fired_after("shelf_place", s0, 2.0)
			await wait(0.5)
			print("INFO  J2 placed at %s; shelf_place events: %s" % [str(shelf.slots[i].global_position), str(place_log)])
			var at_slot := place_log.filter(func(e): return e[1].distance_to(shelf.slots[i].global_position) < 1.0).size()
			check(at_slot == 1, "J2 one sparkle for that slot filling (%d; %d shelf-place events in all — other loose stock may settle too)" % [at_slot, count("shelf_place") - s0])
			break
	check(placed, "J2 sparkle + pop as an item settles onto a shelf")
	await quiet_check("J2", ["shelf_place"])

	# J3 sales: "+$10" at the register; a fast line coalesces into one popup.
	var cb: Node = active_cashier()
	var cashier: Node = cb.get_node("Cashier")
	var sa0 := count("sale")
	cashier._complete_purchase(free_product(), 0)
	check(await fired_after("sale", sa0), "J3 sale effect")
	var pops: Array = juice.popups.filter(func(p): return p["key"] is Node and p["key"] == cb)
	check(pops.size() == 1 and pops[0]["text"] == "+$%d" % main.PAY_PER_SALE, "J3 one '+$%d' popup at the register (%s)" % [main.PAY_PER_SALE, str(pops.map(func(p): return p["text"]))])
	for i in 2:
		await wait(0.12)
		cashier._complete_purchase(free_product(), 0)
	await wait(0.1)
	pops = juice.popups.filter(func(p): return p["key"] is Node and p["key"] == cb)
	check(pops.size() == 1 and pops[0]["text"] == "+$%d" % (3 * main.PAY_PER_SALE), "J3 three quick sales = ONE popup reading '+$%d' (%s)" % [3 * main.PAY_PER_SALE, str(pops.map(func(p): return p["text"]))])
	await quiet_check("J3", ["sale", "rush_bonus"])

	# J4 priority order: banner punch as it's called, confetti when filled,
	# then a sale of a tagged item pays the rush bonus on the popup.
	var oc0 := count("order_called")
	main._issue_priority_order()
	check(await fired_after("order_called", oc0), "J4 banner punch as an order is called out")
	await wait(0.1)
	check(main._order_label.scale.x > 1.0, "J4 ...the banner is mid-punch (%.2f)" % main._order_label.scale.x)
	var oid: int = main._order_id
	var of0 := count("order_filled")
	main._close_priority_order(true)
	check(await fired_after("order_filled", of0), "J4 'filled' confetti")
	check(juice.particles.size() >= 30, "J4 ...a burst of confetti in the world (%d particles)" % juice.particles.size())
	await wait(0.6)
	check(main._order_label.scale.is_equal_approx(Vector2.ONE), "J4 banner back to scale 1")
	var rb0 := count("rush_bonus")
	var tagged := free_product()
	tagged.set_meta("priority_order", oid)
	cashier._complete_purchase(tagged, 0)
	check(await fired_after("rush_bonus", rb0), "J4 rush-bonus popup on a priority sale")
	await wait(0.05)
	var rush: Array = juice.popups.filter(func(p): return p["key"] is String and p["key"] == "rush")
	check(rush.size() == 1 and rush[0]["text"] == "+$%d RUSH" % main._priority_bonus(1), "J4 ...reads '+$%d RUSH' (%s)" % [main._priority_bonus(1), str(rush.map(func(p): return p["text"]))])
	var om0 := count("order_missed")
	await wait(1.2)
	main._issue_priority_order()
	await wait(0.3)
	main._close_priority_order(false)
	check(await fired_after("order_missed", om0), "J4 'missed': a smaller punch, no confetti")
	await quiet_check("J4", ["order_called", "order_filled", "order_missed", "rush_bonus"])

	# J5 a spill appearing: a splash, once.
	var sp0 := count("spill")
	var sid: int = amb().spawn_spill(Vector2(1300, 450), 40.0)
	check(await fired_after("spill", sp0, 0.5), "J5 splash as a spill appears")
	await wait(1.0)
	check(count("spill") == sp0 + 1, "J5 one splash per spill (%d)" % (count("spill") - sp0))
	amb().remove_spill(sid)
	await quiet_check("J5", ["spill"])

	# J6 a write-up on me: "-$25", red flash + wince, a small jolt.
	var w0 := count("writeup")
	var trauma0: float = juice.peak_trauma
	juice.peak_trauma = 0.0
	main.record_writeup(1, "test")
	check(await fired_after("writeup", w0), "J6 write-up effect")
	await wait(0.02)
	var wp: Array = juice.popups.filter(func(p): return p["text"] == "-$%d" % main.WRITEUP_PENALTY)
	check(wp.size() == 1, "J6 one '-$%d' popup over me" % main.WRITEUP_PENALTY)
	var spr: Sprite2D = player().get_node("CharacterSprite")
	check(spr.self_modulate.g < 0.9 and spr.self_modulate.r > 1.0, "J6 red flash on my sprite (%s)" % str(spr.self_modulate))
	check(juice.peak_trauma > 0.2 and juice.peak_trauma < 0.5, "J6 small jolt (trauma %.2f)" % juice.peak_trauma)
	await wait(0.6)
	check(spr.self_modulate.is_equal_approx(Color.WHITE) and spr.scale.is_equal_approx(Vector2(spr.ART_SCALE, spr.ART_SCALE)) and spr.position.is_equal_approx(spr.FEET_AT - spr.FEET_PX * spr.ART_SCALE), "J6 sprite back to normal colour, scale and feet position")
	await quiet_check("J6", ["writeup"])

	# J7 the forklift clipping me: BONK burst, white flash, real shake.
	var f0 := count("forklift_hit")
	juice.peak_trauma = 0.0
	player().forklift_hit(player().global_position + Vector2(40, 0))
	check(await fired_after("forklift_hit", f0), "J7 bonk effect")
	check(juice.bursts.size() == 1, "J7 one star burst (%d)" % juice.bursts.size())
	await wait(0.03)
	var cam: Camera2D = player().get_node("Camera")
	var max_off := 0.0
	for i in 20:
		max_off = maxf(max_off, cam.offset.length())
		await process_frame
	check(juice.peak_trauma >= 0.5 and max_off > 1.0 and max_off <= juice.SHAKE_MAX_PX * 1.01, "J7 shake: trauma %.2f, max offset %.1fpx (<= %.0fpx)" % [juice.peak_trauma, max_off, juice.SHAKE_MAX_PX])
	await quiet_check("J7", ["forklift_hit"])
	check(cam.offset == Vector2.ZERO, "J7 camera back on centre")

	# J8 a shelf wrecked on screen: POW + dust + jolt; OFF screen: no shake.
	var near_shelf: Node = null
	var far_shelf: Node = null
	for s in main.shelves:
		if not main.is_unlocked_at_pos(s.global_position) or s.get_node("Shelf").wrecked:
			continue
		var d: float = s.global_position.distance_to(cam.get_screen_center_position())
		if d < 300.0 and near_shelf == null:
			near_shelf = s
		elif d > 900.0 and far_shelf == null:
			far_shelf = s
	if near_shelf == null:
		player().teleport_to(main.shelves.filter(func(s): return main.is_unlocked_at_pos(s.global_position))[0].global_position + Vector2(0, 90))
		await wait(0.5)
		near_shelf = main.shelves.filter(func(s): return main.is_unlocked_at_pos(s.global_position) and not s.get_node("Shelf").wrecked)[0]
	var wr0 := count("shelf_wreck")
	juice.peak_trauma = 0.0
	near_shelf.get_node("Shelf").wreck(near_shelf.global_position + Vector2(0, 80))
	check(await fired_after("shelf_wreck", wr0), "J8 POW as a shelf is wrecked")
	check(juice.peak_trauma > 0.15, "J8 ...and a jolt, it's on screen (trauma %.2f)" % juice.peak_trauma)
	await wait(1.0)
	check(count("shelf_wreck") == wr0 + 1, "J8 one POW per wreck (%d)" % (count("shelf_wreck") - wr0))
	await quiet_check("J8", ["shelf_wreck"])
	if far_shelf:
		juice.peak_trauma = 0.0
		far_shelf.get_node("Shelf").wreck(far_shelf.global_position + Vector2(0, 80))
		await fired_after("shelf_wreck", wr0 + 1)
		check(juice.peak_trauma == 0.0, "J8 a wreck across the store (%.0fpx away) doesn't shake my view" % far_shelf.global_position.distance_to(cam.get_screen_center_position()))
		await quiet_check("J8b", ["shelf_wreck"])

	# J9 a floor display going over.
	var disp: Node = main.displays.map(func(d): return d.get_node("Display")).filter(func(d): return not d.toppled)[0]
	var dt0 := count("display_topple")
	disp.toppled = true
	check(await fired_after("display_topple", dt0), "J9 POW + glass as a display topples")
	await quiet_check("J9", ["display_topple"])

	# J10 a thrown item thudding into a wall: a dust puff (host broadcast).
	var th0 := count("thud") + count("collapse")
	var o := free_product()
	move_body(o, Vector2(1440, 160))
	o.linear_velocity = Vector2(0, -620)
	var thud := await wait_until(func(): return count("thud") + count("collapse") > th0, 2.0)
	print("INFO  J10 dust puff on a thrown-item impact: %s (only heavy hits / box thuds puff)" % str(thud))

	# J11 cleanup: sparkles per mess, SPOTLESS when the floor's clean.
	var mess := Vector2(1440, 700)
	var msid: int = amb().spawn_spill(mess, 40.0)
	await wait(amb().SPILL_FORM_TIME + 0.2)
	main.cleanup.drop_litter(Vector2(1500, 760))
	main.shift_time_left = 0.01
	await wait_until(func(): return main.cleanup_active, 3.0)
	await wait(1.6)
	var mc0 := count("mess_cleared")
	amb().remove_spill(msid)
	check(await fired_after("mess_cleared", mc0), "J11 sparkle as a spill is mopped up")
	var sl0 := count("spotless")
	# Clear the rest the way the host's own cleanup would (test hook).
	for s in amb().spills.duplicate():
		amb().remove_spill(s["id"])
	main.cleanup.litter = []
	for d in main.displays:
		d.get_node("Display").toppled = false
	for p in get_nodes_in_group("carryable"):
		p.remove_meta("knocked")
	check(await fired_after("spotless", sl0, 3.0), "J11 SPOTLESS! when the last mess is gone")
	print("INFO  J11 sparkles during cleanup: %d" % (count("mess_cleared") - mc0))
	await wait(2.0)
	check(count("spotless") == sl0 + 1, "J11 SPOTLESS fires once (%d)" % (count("spotless") - sl0))

	# J12 clock-out: the report's pay line punches in with confetti.
	var r0 := count("report")
	main.clock_out(1)
	check(await fired_after("report", r0, 3.0), "J12 report payoff as the report comes up")
	await wait(0.05)
	var fs: int = main.report_pay_label.get_theme_font_size("font_size")
	var base_fs: int = main.report_pay_label.get_meta("juice_font_base")[1]
	check(juice.ui_particles.size() > 0 and fs > base_fs, "J12 ...confetti (%d) and the pay line mid-punch (font %d > %d)" % [juice.ui_particles.size(), fs, base_fs])
	await wait(2.5)
	check(juice.ui_particles.is_empty() and main.report_pay_label.get_theme_font_size("font_size") == base_fs, "J12 confetti gone, pay line back to its own font size (%d)" % main.report_pay_label.get_theme_font_size("font_size"))
	check(count("report") == r0 + 1, "J12 one payoff per report (%d)" % (count("report") - r0))
	check(juice.peak_popups <= juice.MAX_POPUPS and juice.peak_particles <= juice.MAX_PARTICLES * 2, "J13 caps held over the whole run (popups %d, particles %d)" % [juice.peak_popups, juice.peak_particles])
	finish()

## --- endless: Week Complete, medal, Bucks -----------------------------------------

func _run_endless() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 15.0)
	me = 1
	await wait(1.6)
	park_everything()
	main.shift_time_left = 0.01
	await wait_until(func(): return main.cleanup_active, 3.0)
	main.clock_out(1)
	await wait_until(func(): return main.is_day_report_active(), 5.0)
	await wait(0.5)
	var wc0 := count("week_complete")
	main._on_continue_pressed()
	check(await fired_after("week_complete", wc0, 3.0), "E1 Week Complete: confetti")
	await wait(0.05)
	check(juice.ui_particles.size() >= 60, "E1 ...a big burst (%d pieces)" % juice.ui_particles.size())
	main.enter_hub()
	await wait(0.5)
	# A purchase in the hub: "-N Bucks".
	var sp0 := count("spend")
	main.endless.wallet += 0
	var before: int = main.endless.wallet
	if before > 0:
		main.endless.wallet = before - 1
		check(await fired_after("spend", sp0), "E2 '-Bucks' popup when the wallet goes down in the hub")
		main.endless.wallet = before
		await wait(0.2)
	# Take a posting, sell enough for GOLD, end it.
	main.take_offer(0)
	await wait_until(func(): return main.shift_active, 5.0)
	await wait(1.6)
	park_everything()
	main.open_store(1)
	main.forklift._pause_timer = 1.0e9
	await wait(0.5)
	var gold: int = main.endless.contract["targets"][2]
	var cashier: Node = active_cashier().get_node("Cashier")
	var n := ceili(float(gold) / main.PAY_PER_SALE) + 2
	var sa0 := count("sale")
	for i in n:
		var p := free_product()
		if p == null:
			break
		cashier._complete_purchase(p, 0)
		await wait(0.05)
	await wait(0.3)
	print("INFO  E3 %d sales (gold target $%d); popups live now: %d; sale effects %d" % [n, gold, juice.popups.size(), count("sale") - sa0])
	check(juice.popups.filter(func(p): return p["key"] is Node and p["key"] == active_cashier()).size() <= 1, "E3 a rapid run of sales at one register is one growing popup, not a stack")
	main.shift_time_left = 0.01
	await wait_until(func(): return main.cleanup_active, 3.0)
	var m0 := count("medal_3") + count("medal_2") + count("medal_1") + count("medal_0")
	main.clock_out(1)
	check(await wait_until(func(): return count("medal_3") + count("medal_2") + count("medal_1") + count("medal_0") > m0, 4.0), "E4 the medal stamp as the endless report comes up")
	var medal: int = int(main.endless.last_payout.get("medal", -1))
	print("INFO  E4 payout %s" % str(main.endless.last_payout))
	check(count("medal_%d" % medal) == 1, "E4 ...for the medal actually won (%s)" % main.endless.MEDAL_NAMES[medal])
	await wait(0.05)
	var wl: Label = main.report_week_label
	check(wl.get_theme_font_size("font_size") > wl.get_meta("juice_font_base")[1], "E4 medal line mid-stamp (font %d > %d)" % [wl.get_theme_font_size("font_size"), wl.get_meta("juice_font_base")[1]])
	var bucks: Array = juice.ui_popups.filter(func(p): return p["text"].ends_with("Bucks"))
	check(bucks.size() == 1 and bucks[0]["text"] == "%+d Bucks" % int(main.endless.last_payout["total"]), "E4 '%+d Bucks' floats up (%s)" % [int(main.endless.last_payout["total"]), str(bucks.map(func(p): return p["text"]))])
	if medal == 3:
		check(juice.ui_popups.any(func(p): return p["text"] == "GOLD!") and juice.ui_particles.size() >= 60, "E4 GOLD gets the big confetti + 'GOLD!' (%d pieces)" % juice.ui_particles.size())
	await wait(3.0)
	check(juice.ui_popups.is_empty() and juice.ui_particles.is_empty() and wl.get_theme_font_size("font_size") == wl.get_meta("juice_font_base")[1], "E5 report effects all faded, medal line back to its own font size")
	check(count("medal_%d" % medal) == 1, "E5 the stamp fired once while the report stayed up")
	finish()

## --- load: real renderer, frame times, screenshots ----------------------------------

func _frame_stats(seconds: float) -> Dictionary:
	var times: Array = []
	var t0 := Time.get_ticks_usec()
	var last := t0
	while Time.get_ticks_usec() - t0 < seconds * 1e6:
		await process_frame
		var now := Time.get_ticks_usec()
		times.append((now - last) / 1000.0)
		last = now
	times.sort()
	var sum := 0.0
	for x in times:
		sum += x
	return {"frames": times.size(), "avg": sum / maxf(1.0, times.size()), "p95": times[int(times.size() * 0.95)], "max": times[-1]}

func _shot(name: String) -> void:
	await process_frame
	await process_frame
	var img := root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("user://juice_shots")
	img.save_png("user://juice_shots/%s.png" % name)
	print("SHOT  %s" % ProjectSettings.globalize_path("user://juice_shots/%s.png" % name))

## A heavy second of chaos: every register selling, a priority order filled,
## two wrecks, a bonk, displays over, spills — repeated.
func _chaos_burst() -> void:
	for cb in main.cashiers:
		var c: Node = cb.get_node("Cashier")
		if c.active:
			var p := free_product()
			if p:
				c._complete_purchase(p, 0)
	for s in main.shelves:
		var sh: Node = s.get_node("Shelf")
		if main.is_unlocked_at_pos(s.global_position) and not sh.wrecked and randf() < 0.25:
			sh.wreck(s.global_position + Vector2(0, 80))
	player().forklift_hit(player().global_position + Vector2(40, 0))
	amb().spawn_spill(player().global_position + Vector2(randf_range(-200, 200), randf_range(-120, 120)), 30.0)
	for d in main.displays:
		d.get_node("Display").toppled = not d.get_node("Display").toppled

func _chaos_loop() -> void:
	for i in 12:
		_chaos_burst()
		await wait(0.5)

func _run_perf() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 15.0)
	me = 1
	root.size = Vector2i(960, 540)
	await wait(1.6)
	main.debug_label.visible = false
	main.status_hud = false
	main.prep_time_left = 0.5 # opens by itself: every Day 7 hazard live
	await wait_until(func(): return main.store_open, 5.0)
	player().teleport_to(Vector2(1440, 810))
	await wait(14.0) # customers fill in, forklift + manager on rounds
	var crowd := get_nodes_in_group("customer").size()
	print("INFO  P0 Day 7 live: %d customers, forklift %s, manager %s, spills %d" % [crowd, main.forklift.active, main.manager.active, amb().spills.size()])
	# Baseline: juice processing off, same chaos.
	juice.set_process(false)
	juice.visible = false
	var base := await _frame_stats(6.0)
	juice.set_process(true)
	juice.visible = true
	var calm := await _frame_stats(6.0)
	# The worst case: a chaos burst every 0.5s for 6s.
	_chaos_loop() # runs alongside (not awaited)
	var chaos: Dictionary = await _frame_stats(6.0)
	print("PERF  juice off (Day 7 live):   avg %.2fms p95 %.2fms max %.2fms over %d frames" % [base["avg"], base["p95"], base["max"], base["frames"]])
	print("PERF  juice on, normal play:     avg %.2fms p95 %.2fms max %.2fms over %d frames" % [calm["avg"], calm["p95"], calm["max"], calm["frames"]])
	print("PERF  juice on, chaos every .5s: avg %.2fms p95 %.2fms max %.2fms over %d frames" % [chaos["avg"], chaos["p95"], chaos["max"], chaos["frames"]])
	check(chaos["p95"] < base["p95"] * 1.35 + 2.0, "P1 chaos bursts cost little: p95 %.2fms vs %.2fms with juice off" % [chaos["p95"], base["p95"]])
	check(juice.peak_popups <= juice.MAX_POPUPS and juice.peak_particles <= juice.MAX_PARTICLES * 2 and juice.peak_bursts <= juice.MAX_BURSTS, "P2 caps held under chaos: popups %d/%d, particles %d, bursts %d/%d (culled %d)" % [juice.peak_popups, juice.MAX_POPUPS, juice.peak_particles, juice.peak_bursts, juice.MAX_BURSTS, juice.dropped])
	check(juice.peak_trauma <= 1.0, "P3 stacked impacts never compound past full trauma (%.2f -> max %.0fpx)" % [juice.peak_trauma, juice.SHAKE_MAX_PX])
	await wait_until(all_settled, 5.0)
	check(all_settled(), "P4 everything faded after the chaos")
	_chaos_burst() # one more, outside the timed window, for the screenshot
	await wait(0.12)
	await _shot("chaos_burst")
	await wait_until(all_settled, 5.0)
	# Hazard readability: a popup right on top of the manager's "!" and the
	# forklift's BEEP — the hazard draws over it (screenshot to eyeball).
	main.manager.position = player().global_position + Vector2(-90, -40)
	main.forklift.global_position = player().global_position + Vector2(110, 30)
	await wait(0.2)
	for k in 6:
		juice.popup(main.manager.global_position + Vector2(0, -30 + k * 6), 10 * (k + 1), "+$%d", juice.C_MONEY)
		juice.popup(main.forklift.global_position + Vector2(0, -20 + k * 6), 10 * (k + 1), "+$%d", juice.C_MONEY)
	juice.burst(main.manager.global_position, 50.0)
	await wait(0.08)
	await _shot("hazards_over_popups")
	# A few hand-posed beats for the report.
	await wait_until(all_settled, 5.0)
	var cb: Node = active_cashier()
	player().teleport_to(cb.global_position + Vector2(0, 120))
	await wait(0.4)
	for i in 3:
		cb.get_node("Cashier")._complete_purchase(free_product(), 0)
		await wait(0.1)
	await _shot("sale_popup")
	await wait(0.4)
	main.record_writeup(1, "test")
	await wait(0.05)
	await _shot("writeup")
	main._issue_priority_order()
	await wait(0.3)
	main._close_priority_order(true)
	await wait(0.25)
	await _shot("order_filled")
	finish()

## --- co-op -------------------------------------------------------------------------

## Shared-world effects every peer must fire, once, as the host triggers them.
func _run_net_host() -> void:
	var want := 2
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--players="):
			want = int(a.substr(10))
	DirAccess.make_dir_recursive_absolute(NET_DIR)
	for f in DirAccess.get_files_at(NET_DIR):
		DirAccess.remove_absolute(NET_DIR + f)
	await wait_until(func(): return main.shift_active and main.players.size() >= want, 40.0)
	check(main.players.size() == want, "net: %d players connected" % main.players.size())
	park_everything()
	await wait(2.5)
	var ids: Array = main.players.keys()
	ids.sort()
	var clients: Array = ids.filter(func(id): return id != 1)
	for k in ids.size():
		main.players[ids[k]].rpc("teleport_to", Vector2(1300 + 70 * k, 760))
	await wait(0.6)
	var events := [] # [label, kind, host unix time]
	var host_event := func(label: String, kind: String, trigger: Callable, timeout := 3.0) -> void:
		var start := seen.size()
		trigger.call()
		var ok := await wait_until(func(): return seen.slice(start).any(func(h): return h[1] == kind), timeout)
		var at := -1.0
		for h in seen.slice(start):
			if h[1] == kind and at < 0.0:
				at = h[0]
		check(ok, "N %s: host fired %s" % [label, kind])
		events.append([label, kind, at])
		await wait(1.3)

	main.open_store(1)
	main.forklift._pause_timer = 1.0e9
	await wait(1.0)
	await host_event.call("sale", "sale", func(): active_cashier().get_node("Cashier")._complete_purchase(free_product(), 0))
	await host_event.call("spill", "spill", func(): amb().spawn_spill(Vector2(1440, 640), 40.0))
	await host_event.call("order called", "order_called", func(): main._issue_priority_order())
	await host_event.call("order filled", "order_filled", func(): main._close_priority_order(true))
	await host_event.call("shelf wreck", "shelf_wreck", func():
		var s: Node = main.shelves.filter(func(x): return main.is_unlocked_at_pos(x.global_position) and not x.get_node("Shelf").wrecked)[0]
		s.get_node("Shelf").wreck(s.global_position + Vector2(0, 80)))
	await host_event.call("display topple", "display_topple", func():
		main.displays.filter(func(d): return not d.get_node("Display").toppled)[0].get_node("Display").toppled = true)
	var target: int = clients[0]
	await host_event.call("forklift bonk", "forklift_hit", func(): main.players[target].rpc("forklift_hit", main.players[target].global_position + Vector2(40, 0)))
	var victim: int = clients[-1]
	await host_event.call("write-up", "writeup", func(): main.record_writeup(victim, "test"))
	# Carry pops: a client picks up and throws (its RPCs land on every peer).
	var mover: int = clients[0]
	var obj := free_product()
	move_body(obj, main.players[mover].global_position + Vector2(42, 0))
	await wait(0.4)
	var pick0 := count("carry_pickup")
	var carry_t0 := Time.get_unix_time_from_system()
	_net_write("mover.json", {"peer": mover, "obj": String(obj.name)})
	await _net_read("mover_done.json", 15.0)
	check(count("carry_pickup") > pick0, "N carry: the host saw the mover's pickup pop too")
	var placed := false
	for shelf_body in main.shelves:
		if placed or not main.is_unlocked_at_pos(shelf_body.global_position) or shelf_body.get_node("Shelf").wrecked:
			continue
		var shelf: Node = shelf_body.get_node("Shelf")
		var color: Color = main.SECTION_COLORS[main._section_name_at(shelf_body.global_position)]
		for i in shelf.slots.size():
			var item := free_product(color)
			if shelf._is_filled(i) or item == null:
				continue
			await host_event.call("shelf place", "shelf_place", func(): move_body(item, shelf.slots[i].global_position))
			placed = true
			break
	main.shift_time_left = 0.01
	await wait_until(func(): return main.cleanup_active, 3.0)
	await wait(1.0)
	await host_event.call("report", "report", func(): main.clock_out(1))
	await wait(1.0)
	_net_write("done.json", {"go": true})
	var host_counts: Dictionary = juice.counts.duplicate()
	for id in clients:
		var r := await _net_read("log_%d.json" % id, 30.0)
		var log: Array = r.get("seen", [])
		check(not log.is_empty(), "N %d: client log received (%d effects)" % [id, log.size()])
		for e in events:
			var near := log.filter(func(h): return h[1] == e[1] and h[0] >= e[2] - 0.4 and h[0] <= e[2] + 1.0)
			var lag: float = (near[0][0] - e[2]) if not near.is_empty() else 99.0
			check(near.size() == 1, "N %s: client %d fired %s once (%d, %+.2fs vs host)" % [e[0], id, e[1], near.size(), lag])
		var trauma: Dictionary = r.get("trauma", {})
		if id == target:
			check(float(trauma.get("forklift_hit", 0.0)) >= 0.5, "N bonk: the clipped client %d got the big shake (%.2f)" % [id, float(trauma.get("forklift_hit", 0.0))])
		else:
			check(float(trauma.get("forklift_hit", 1.0)) < 0.5, "N bonk: bystander client %d only a nudge at most (%.2f)" % [id, float(trauma.get("forklift_hit", 1.0))])
		if id == victim:
			check(float(trauma.get("writeup", 0.0)) > 0.2, "N write-up: client %d (written up) felt the jolt (%.2f)" % [id, float(trauma.get("writeup", 0.0))])
		else:
			check(float(trauma.get("writeup", 1.0)) < 0.2 or id == target, "N write-up: client %d (bystander) no write-up jolt (%.2f)" % [id, float(trauma.get("writeup", 1.0))])
		var picks := log.filter(func(h): return h[1] == "carry_pickup" and h[0] >= carry_t0).size()
		check(picks >= 1, "N carry: client %d saw the mover's pickup pop (%d)" % [id, picks])
		check(r.get("settled", false), "N client %d: every effect faded by the end" % id)
		check(int(r.get("peak_popups", 99)) <= juice.MAX_POPUPS, "N client %d: popups capped (%d)" % [id, int(r.get("peak_popups", 99))])
	check(float(host_counts.get("forklift_hit", 0)) == 1.0, "N host fired the bonk once")
	finish()

func _run_net_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 20.0)
	me = main.multiplayer.get_unique_id()
	# Peak trauma right after each shaking event.
	var trauma := {}
	juice.fired.connect(func(k, _p):
		if k in ["forklift_hit", "writeup"]:
			(func(): trauma[k] = juice.trauma).call_deferred())
	var deadline := Time.get_ticks_msec() + 180000
	var moved := false
	while Time.get_ticks_msec() < deadline:
		if not moved:
			var mv := _net_peek("mover.json")
			if int(mv.get("peer", 0)) == me:
				moved = true
				await _client_move(String(mv.get("obj", "")))
				_net_write("mover_done.json", {"ok": true})
		if FileAccess.file_exists(NET_DIR + "done.json"):
			break
		await process_frame
	await wait_until(func(): return juice.popups.is_empty() and juice.particles.is_empty() and juice.bursts.is_empty() and juice.trauma == 0.0, 4.0)
	var settled: bool = juice.popups.is_empty() and juice.particles.is_empty() and juice.bursts.is_empty() and juice.trauma == 0.0 and player().get_node("Camera").offset == Vector2.ZERO
	_net_write("log_%d.json" % me, {"seen": seen, "trauma": trauma, "settled": settled, "peak_popups": juice.peak_popups})
	print("JUICE  client %d: %s" % [me, str(_sorted_counts())])
	quit(0)

func _client_move(obj_name: String) -> void:
	var obj: Node = null
	for o in get_nodes_in_group("carryable"):
		if String(o.name) == obj_name:
			obj = o
	if obj:
		obj.get_node("Carryable").try_pickup(me, player().global_position)
		await wait(0.6)
		if obj.get_node("Carryable").carrier_id == me:
			obj.get_node("Carryable").try_throw(me, Vector2.RIGHT)
	await wait(0.8)

func _net_peek(file: String) -> Dictionary:
	if not FileAccess.file_exists(NET_DIR + file):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(NET_DIR + file))
	return parsed if parsed is Dictionary else {}

func _net_write(file: String, data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(NET_DIR)
	var f := FileAccess.open(NET_DIR + file + ".tmp", FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()
	DirAccess.rename_absolute(NET_DIR + file + ".tmp", NET_DIR + file)

func _net_read(file: String, timeout: float) -> Dictionary:
	var t := 0.0
	while t < timeout:
		var d := _net_peek(file)
		if not d.is_empty():
			return d
		await create_timer(0.25).timeout
		t += 0.25
	return {}
