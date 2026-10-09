extends "res://tools/staff_test.gd"
## OCT 2026 PHASE 4 — RANDOM EVENTS (Events.gd) AND THE BREAK ROOM SHOP
## (Shop.gd), which together replace Week 21's Endless Mode. Reuses
## tools/staff_test.gd's helpers (and through it economy_test.gd's and
## hazards_test.gd's: walking, key taps, the solo bot brain — with
## --event-brain it plays events —, the cleaning pass, the net step files) and
## drives the real Main.tscn. Not part of the game. Real wall-clock time
## throughout, except FEASIBLE (a bot sim, see its header).
##
## GATING (unlocks by sections/lifetime earned, never on a new-stage shift,
## the crew's first event guaranteed + explained, one at a time, the shift
## cap, the fit rule, off in practice / with --events=off):
##   godot --headless --path . --script res://tools/events_test.gd -- --server --day=1 --no-save --test=gating
## EACH EVENT (trigger, cue, active effect, a win and a miss, a clean end):
##   godot ... -- --server --day=7 --no-save --test=each
## INTERACTIONS (priority orders, the truck, the store closing, hazards, the
## rating, shopping lists, the bank/lifetime accounting, the HUD rows):
##   godot ... -- --server --day=7 --no-save --test=interactions
## SHOP (the gear lockers: E, the panel, prep-only, the bank, refusals, a
## race, the effects; coffee still $ off Pay):
##   godot ... -- --server --day=1 --no-save --test=shop
## CO-OP (host + 2 clients: every peer sees the same event; races on the last
## unit of an event resolve once; a forged and a raced shop purchase):
##   godot ... -- --server --port=8977 --day=7 --players=3 --no-save --test=net-events &
##   (x2) godot ... -- --client --connect-port=8977 --no-save --test=net-events
## FEASIBLE (bot sim — can ONE player handle each event? with and without
## helpers): the solo brain plays whole shifts with --event-brain, one event
## forced per shift, and reports each outcome:
##   godot --headless [--fixed-fps 60] --path . --script res://tools/events_test.gd -- --server --day=7 --no-save --prep-seconds=240 --test=feasible --event-brain [--hire=Produce:0:0,...] [--only=rush]
## SHOTS (xvfb, not headless): each event's warning and running state:
##   xvfb-run -a godot --path . --script res://tools/events_test.gd -- --server --day=7 --no-save --test=shots

const NET_DIR_EVENTS := "user://net_events/"

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--test="):
			_mode = a.substr(7)
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	main.events_on = true
	var client := "--client" in args
	if OS.get_environment("SW_NET_DIR") == "":
		NET_DIR = NET_DIR_EVENTS
	if _mode in ["each", "interactions", "shots", "net-events"]:
		main.opening_stock_fraction = 1.0
		main.rating_frozen = true
	if _mode in ["gating", "each", "shots"]:
		main.cleanup_ceiling_override = 0.0
	if _mode == "net-events" and not client:
		var d := DirAccess.open(NET_DIR)
		if d:
			for f in d.get_files():
				d.remove(f)
	match _mode:
		"gating": _run_gating.call_deferred()
		"each": _run_each.call_deferred()
		"interactions": _run_interactions.call_deferred()
		"shop": _run_shop.call_deferred()
		"feasible": _run_feasible.call_deferred()
		"shots": _run_ev_shots.call_deferred()
		"net-events": (_run_ev_net_client if client else _run_ev_net_host).call_deferred()
		_:
			print("FAIL  unknown --test=%s" % _mode)
			quit(1)

## --- helpers ------------------------------------------------------------------

func ev() -> Node2D:
	return main.events

func shop() -> Node2D:
	return main.shop

## Everything that could act on its own, parked: customers, the forklift,
## the manager, call-outs, the lights and spills. (Events don't need any of it.)
func quiet() -> void:
	main.test_hold_customers = true
	fk()._pause_timer = 1.0e9
	pin_manager(Vector2(480, 1350), 0.0)
	main._order_timer = 1.0e9
	main.ambience._spill_timer = 1.0e9
	main.ambience._lights_timer = 1.0e9
	for sp in main.ambience.spills.duplicate():
		main.ambience.remove_spill(int(sp["id"]))
	for c in get_nodes_in_group("customer"):
		c.force_leave()

## Wait for the shift, open the store, give it a long clock.
func selling(clock := 3000.0) -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 30.0)
	await wait(0.5)
	ev().reschedule = false # every start is scripted here
	main.open_store(1)
	await wait(0.2)
	main.shift_time_left = clock

## Force `k` and wait for it to reach the warning, then the active phase.
func force(k: String, wait_active := true) -> bool:
	ev().force_next(k, 0.1)
	var ok := await wait_until(func(): return ev().warning() and ev().key == k, 6.0)
	if ok and wait_active:
		ok = await wait_until(func(): return ev().active() and ev().key == k, 15.0)
	return ok

## Ends the running event by running its clock out.
func time_out() -> void:
	# (A warning cut short just goes active with a full clock — keep cutting
	# until it's over.)
	for i in 8:
		if not ev().busy():
			break
		ev().time_left = 0.05
		await wait_until(func(): return not ev().busy() or ev().time_left > 0.1, 1.0)
	await physics_frame

## `n` real sales of `sec`'s stock: shelved, taken off by a "shopper", rung up
## at a register (Cashier.gd -> Main.note_sale -> Events.note_sale).
func sell_from(sec: String, n: int) -> int:
	var done := 0
	for i in n:
		if loose_products(sec).is_empty():
			main._spawn_product_for(sec)
			await physics_frame
			await physics_frame
		var obj = await stock_one(sec)
		if obj == null:
			continue
		await sell(obj)
		done += 1
	return done

func _marker(sec: String) -> Label:
	return ev()._markers[sec]

func section_names() -> Array:
	return main._unlocked_sections().map(func(s): return s["name"])

## =============================================================================
## GATING
## =============================================================================

func _run_gating() -> void:
	main.test_follow_old_calendar = false
	await wait_until(func(): return main.shift_active and main.players.has(1), 30.0)
	await wait(0.5)
	main.test_hold_customers = true
	# --- G1 a brand-new crew: nothing unlocked, nothing ever rolls.
	check(main.sections_owned == 1 and ev().unlocked_keys().is_empty(), "G1: Dry Goods only: no event unlocked (%s)" % str(ev().unlocked_keys()))
	main.open_store(1)
	await wait(0.3)
	check(ev()._countdown < 0.0 and not ev().busy(), "G1: the store opens — no event is scheduled")
	ev().force_next("rush", 0.1)
	await wait(1.0)
	check(not ev().busy(), "G1: even a forced Lunch Rush can't run in a one-section store (nothing to rush to)")
	check(await wait_until(func(): return ev()._countdown < 0.0 and not ev().busy(), 30.0), "G1: ...it retries a while, then lets it go for this shift")
	# --- G2 the unlock table, by sections owned and lifetime earned.
	var table := [
		[1, 99999, []],
		[2, 0, ["rush"]],
		[2, 599, ["rush"]],
		[2, 600, ["rush", "inspection"]],
		[2, 1000, ["rush", "inspection", "leak"]],
		[3, 0, ["rush", "catering"]],
		[3, 1999, ["rush", "inspection", "leak", "catering"]],
		[3, 2000, ["rush", "inspection", "leak", "catering", "delivery"]],
		[4, 5000, ["rush", "inspection", "leak", "catering", "delivery"]],
	]
	var s0: int = main.sections_owned
	var e0: int = main.lifetime_earned
	for row in table:
		main.sections_owned = row[0]
		main.lifetime_earned = row[1]
		check(ev().unlocked_keys() == row[2], "G2: %d section(s), $%d lifetime -> %s (%s)" % [row[0], row[1], str(row[2]), str(ev().unlocked_keys())])
	main.sections_owned = s0
	main.lifetime_earned = e0
	# --- G3 the shift a NEW complication starts gets no event: own Produce
	# with $500 earned -> next shift starts the forklift stage.
	main.shift_time_left = 0.05
	await wait_until(func(): return main.is_day_report_active(), 10.0)
	main.sections_owned = 2
	main.lifetime_earned = 500
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 10.0)
	check(main.complication_stage == main.STAGE_FORKLIFT and main.stage_banner == main.STAGE_FORKLIFT, "G3: this shift brings the forklift stage (banner %d)" % main.stage_banner)
	main.test_hold_customers = true
	main.open_store(1)
	await wait(0.3)
	check(ev()._skip_shift and ev()._countdown < 0.0, "G3: ...so it gets no event, though Lunch Rush is unlocked")
	main.shift_time_left = 0.05
	await wait_until(func(): return main.is_day_report_active(), 10.0)
	await wait(0.3)
	check(main.report_shop_label.text.contains("Random events can happen now"), "G3: the report says events can happen now (before the first one): '%s'" % main.report_shop_label.text.replace("\n", " | "))
	# --- G4 the next shift: the crew's FIRST event is guaranteed, and it
	# explains itself (a longer warning, the RANDOM EVENT line).
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 10.0)
	check(main.stage_banner == 0 and ev().seen.is_empty(), "G4: an ordinary shift, and this crew has never seen an event")
	main.test_hold_customers = true
	main.open_store(1)
	await wait(0.2)
	main.shift_time_left = 500.0
	check(ev()._countdown >= ev().FIRST_AFTER_OPEN_MIN and ev()._countdown <= ev().FIRST_AFTER_OPEN_MAX, "G4: the first event is guaranteed: due %.1fs after opening (window %.0f-%.0fs)" % [ev()._countdown, ev().FIRST_AFTER_OPEN_MIN, ev().FIRST_AFTER_OPEN_MAX])
	ev()._countdown = 0.2
	check(await wait_until(func(): return ev().warning(), 3.0), "G4: ...and it comes")
	check(ev().key == "rush" and ev().data.get("first", false) and ev().time_left > ev().WARN_SECONDS, "G4: Lunch Rush (the only one unlocked), with the long first warning (%.1fs)" % ev().time_left)
	await wait(0.2)
	var bl: Array = ev().banner_lines()
	check(bl.size() == 3 and bl[0] == "INCOMING: LUNCH RUSH" and str(bl[2]).begins_with("RANDOM EVENT"), "G4: the banner explains it: %s" % str(bl))
	check(main._finale_banner.visible and (main._finale_banner.get_child(0) as Label).text == "INCOMING: LUNCH RUSH", "G4: ...on the big banner band")
	check(ev().seen.has("rush"), "G4: the crew has now seen one (saved)")
	# --- G5 never two at once.
	await wait_until(func(): return ev().active(), 15.0)
	var id0: int = ev().event_id
	ev().force_next("rush", 0.1)
	await wait(1.0)
	check(ev().active() and ev().event_id == id0, "G5: forcing another while one runs starts nothing (still event #%d)" % id0)
	await time_out()
	ev()._countdown = -1.0
	ev()._forced = ""
	# --- G6 the shift cap: 1 below the top tier...
	check(ev().fired_today == 1 and ev().max_per_shift() == 1 and ev()._countdown < 0.0, "G6: one this shift (cap %d), nothing more scheduled" % ev().max_per_shift())
	# ...2 at the top tier.
	var st0: int = main.complication_stage
	main.complication_stage = main.STAGE_RUSH
	check(ev().max_per_shift() == 2, "G6: the top tier allows 2 a shift")
	main.complication_stage = st0
	# --- G7 the fit rule: an event that couldn't finish before close doesn't start.
	main.shift_time_left = 20.0
	ev().force_next("rush", 0.1)
	await wait(1.0)
	check(not ev().busy() and ev()._countdown < 0.0, "G7: 20s of selling left: a 45s rush doesn't start (none fits — none this time)")
	main.shift_time_left = 500.0
	# --- G8 off: --events=off (Main.events_on = false) and the practice shift.
	main.events_on = false
	ev()._countdown = -1.0
	ev().on_store_open()
	check(ev()._countdown < 0.0, "G8: events off: the store opening rolls nothing")
	main.events_on = true
	ev().reset_for_new_shift(true)
	ev().on_store_open()
	check(ev()._countdown < 0.0, "G8: a skipped shift (new stage / practice) rolls nothing")
	ev().reset_for_new_shift(false)
	main.tutorial.active = true
	ev().on_store_open()
	main.tutorial.active = false
	check(ev()._countdown < 0.0, "G8: the practice shift rolls nothing")
	# --- G9 the odds: ~EVENT_CHANCE of shifts once the first is seen.
	var hits := 0
	for i in 400:
		ev().reset_for_new_shift(false)
		ev().on_store_open()
		if ev()._countdown >= 0.0:
			hits += 1
	ev().reset_for_new_shift(false)
	check(absf(hits / 400.0 - ev().EVENT_CHANCE) < 0.08, "G9: %d/400 shifts rolled an event (EVENT_CHANCE %.2f)" % [hits, ev().EVENT_CHANCE])
	finish()

## =============================================================================
## EACH EVENT — trigger, cue, effect, a win, a miss, a clean end
## =============================================================================

func _run_each() -> void:
	await selling()
	quiet()
	check(ev().unlocked_keys().size() == 5, "E0: the top tier has all five unlocked (%s)" % str(ev().unlocked_keys()))
	var pay0: int = main._pay_today()
	await _each_rush()
	await _each_catering()
	await _each_delivery()
	await _each_inspection()
	await _each_leak()
	# Every bonus is in Pay Today, exactly.
	var won: int = ev().log_today.filter(func(e): return e[1]).map(func(e): return int(e[2])).reduce(func(a, b): return a + b, 0)
	check(ev().bonus_today == won and main._pay_today() - pay0 >= won, "E9: Pay Today carries every bonus won ($%d = log %s)" % [ev().bonus_today, str(ev().log_today)])
	check(ev().report_line().begins_with("Events: Lunch Rush ✓"), "E9: the report line: '%s'" % ev().report_line())
	finish()

func _end_clean(tag: String) -> void:
	await process_frame
	await process_frame
	var markers_off := true
	for sec in ev()._markers:
		if _marker(sec).visible:
			markers_off = false
	check(not ev().busy() and ev().key == "" and ev().data.is_empty() and markers_off and ev().extra_customers() == 0 and not ev().blocks_orders(45.0) and not ev().holds_truck(), "%s: a clean end — idle, no markers, no extra crowd, orders and trucks free (phase %d, markers off %s, countdown %.1f)" % [tag, ev().phase, markers_off, ev()._countdown])

func _each_rush() -> void:
	# Warning: the cue, and the call-outs stand aside.
	check(await force("rush", false), "R1: Lunch Rush warns")
	var sec: String = ev().data["section"]
	var goal: int = ev().data["goal"]
	check(sec in section_names() and goal == ev().RUSH_GOAL, "R1: rush on %s, sell %d" % [sec, goal])
	await wait(0.1)
	check(main._finale_banner.visible and (main._finale_banner.get_child(0) as Label).text == "INCOMING: LUNCH RUSH" and (main._finale_banner.get_child(1) as Label).text.contains(sec.to_upper()), "R1: the banner names it and the section ('%s')" % (main._finale_banner.get_child(1) as Label).text)
	check(_marker(sec).visible and _marker(sec).text == "RUSH COMING!", "R1: a marker over %s's pad: '%s'" % [sec, _marker(sec).text])
	main._order_timer = 0.0
	await wait(0.3)
	check(main.order_section == "" and ev().blocks_orders(45.0), "R1: no priority order is called during the warning")
	main._order_timer = 1.0e9
	await wait_until(func(): return ev().active(), 10.0)
	# Active: the crowd and the lists.
	main.test_hold_customers = false
	var cap_on: int = main.customer_cap()
	check(ev().extra_customers() == ev().RUSH_EXTRA_CUSTOMERS and cap_on == main.customer_cap() and cap_on - ev().extra_customers() > 0, "R2: the crowd cap grows by %d while it runs (cap %d)" % [ev().extra_customers(), cap_on])
	main.test_hold_customers = true
	# Demand follows stock: an empty rush section isn't forced onto lists...
	for sb in main.shelves:
		if main._section_name_at(sb.global_position) == sec:
			for o in sb.get_node("Shelf").filled_objects():
				move_body(o, o.global_position + Vector2(0, 90))
	await wait(0.6)
	var none_forced := true
	for i in 30:
		var l: PackedStringArray = main.make_shopping_list()
		if l.has(sec):
			none_forced = false
	check(none_forced, "R2: %s's shelves are bare: it isn't forced onto lists (no shopper sent to empty shelves)" % sec)
	# ...a stocked one is on every list.
	await stock_one(sec)
	var all_have := true
	for i in 30:
		if not main.make_shopping_list().has(sec):
			all_have = false
	check(all_have and ev().adjust_list(PackedStringArray(["Dry Goods"] if sec != "Dry Goods" else ["Produce"])).has(sec), "R2: one unit on %s's shelves -> every new shopping list has it (30/30)" % sec)
	check(_marker(sec).visible and _marker(sec).text.begins_with("RUSH HERE!"), "R2: the marker: '%s'" % _marker(sec).text.replace("\n", " "))
	await wait(0.1)
	check(main._order_label.visible and main._order_label.text.begins_with("LUNCH RUSH — sell from %s: 0/%d" % [sec, goal]), "R2: the live row: '%s'" % main._order_label.text)
	# Other sections' sales don't count.
	var other: String = section_names().filter(func(s): return s != sec)[0]
	await sell_from(other, 2)
	check(int(ev().data["done"]) == 0, "R3: sales from %s don't count" % other)
	# The win.
	var pay0: int = main._pay_today()
	var b0: int = ev().bonus_today
	var bonus: int = ev().data["bonus"]
	await sell_from(sec, goal)
	check(not ev().busy() and ev().bonus_today == b0 + bonus and ev().log_today[-1] == ["Lunch Rush", true, bonus], "R3: %d sold from %s -> COMPLETE, +$%d once" % [goal, sec, bonus])
	check(main._pay_today() - pay0 >= bonus and ev().result_text == "LUNCH RUSH COMPLETE!  +$%d" % bonus, "R3: Pay Today +$%d (and the sales); '%s'" % [main._pay_today() - pay0, ev().result_text])
	await wait(0.1)
	check(main._order_label.visible and main._order_label.text == ev().result_text, "R3: the result on the row")
	await _end_clean("R3")
	var other_list := PackedStringArray([other])
	check(ev().adjust_list(other_list) == other_list, "R3: lists are back to normal afterwards (nothing added)")
	# The miss: time runs out.
	check(await force("rush"), "R4: another Lunch Rush")
	var b1: int = ev().bonus_today
	await time_out()
	check(ev().bonus_today == b1 and ev().log_today[-1][1] == false and ev().result_text.contains("missed") and not ev().result_ok, "R4: time's up -> missed, no bonus ('%s')" % ev().result_text)
	await _end_clean("R4")

func _each_catering() -> void:
	check(await force("catering"), "C1: Catering Order starts")
	var needs: Dictionary = ev().data["needs"]
	check(needs.size() >= 2 and needs.size() <= ev().CATERING_SECTIONS and needs.values().all(func(n): return int(n) >= 1 and int(n) <= ev().CATERING_PER_SECTION), "C1: across %d sections: %s" % [needs.size(), str(needs)])
	for sec in needs:
		check(_marker(sec).visible and _marker(sec).text == "STOCK %d MORE" % int(needs[sec]), "C1: marker over %s: '%s'" % [sec, _marker(sec).text])
	await wait(0.1)
	check(main._order_label.text.begins_with("CATERING — stock "), "C1: the live row: '%s'" % main._order_label.text)
	# A section not on the order doesn't count; one item counted once even if
	# it's knocked off and put back.
	var off_list: Array = section_names().filter(func(s): return not needs.has(s))
	if not off_list.is_empty():
		await stock_one(off_list[0])
		check(ev().data["have"].values().all(func(n): return int(n) == 0), "C2: stock in %s (not on the order) doesn't count" % off_list[0])
	var first: String = needs.keys()[0]
	var obj = await stock_one(first)
	check(obj != null and int(ev().data["have"][first]) == 1 and obj.get_meta("event_item", 0) == ev().event_id, "C2: one into %s counts and is tagged" % first)
	move_body(obj, obj.global_position + Vector2(0, 90))
	await wait_until(func(): return not _is_placed(obj), 2.0)
	await stock_one(first, obj)
	check(int(ev().data["have"][first]) == 1, "C2: knocked off and put back, it still counts once")
	var b0: int = ev().bonus_today
	var bonus: int = ev().data["bonus"]
	for sec in needs:
		while ev().active() and int(ev().data["have"].get(sec, 0)) < int(needs[sec]):
			if loose_products(sec).is_empty():
				main._spawn_product_for(sec)
				await physics_frame
				await physics_frame
			if await stock_one(sec) == null:
				break
	check(not ev().busy() and ev().bonus_today == b0 + bonus and ev().log_today[-1] == ["Catering Order", true, bonus], "C3: every section stocked -> COMPLETE, +$%d" % bonus)
	await _end_clean("C3")
	# The miss.
	check(await force("catering"), "C4: another Catering Order")
	var b1: int = ev().bonus_today
	await time_out()
	check(ev().bonus_today == b1 and not ev().log_today[-1][1], "C4: time's up -> missed, no bonus")
	await _end_clean("C4")

func _each_delivery() -> void:
	# A helper in Produce: that section's box is the helper's — done for the crew.
	main.staff.staff = {"Produce": {"speed": 0, "carry": 0}}
	main.staff.on_books = {"Produce": true}
	main.staff.sync_helpers()
	await wait_until(func(): return main.delivery.truck_away(), 60.0)
	for b in boxes():
		b.queue_free() # earlier trucks' boxes: only the event's truck's count here
	await physics_frame
	var deliveries0: int = main.delivery.deliveries_today
	check(await force("delivery", false), "D1: Surprise Delivery warns")
	# The regular truck holds while it's announced.
	main.delivery._truck_timer = 0.0
	await wait(1.0)
	check(main.delivery.truck_away() and main.delivery.deliveries_today == deliveries0 and ev().holds_truck(), "D1: the regular truck waits for it")
	await wait_until(func(): return ev().active(), 10.0)
	var needs: Dictionary = ev().data["needs"]
	check(needs.keys().size() == mini(ev().DELIVERY_SOLO_SECTIONS, section_names().size()) and needs.values().all(func(n): return int(n) == 1), "D2: solo: one box each for %d sections: %s" % [ev().DELIVERY_SOLO_SECTIONS, str(needs)])
	check(not needs.has("Produce") or int(ev().data["have"].get("Produce", 0)) == 1, "D2: Produce's box (if it's on the list) went to its helper's back room — counted (%s)" % str(ev().data["have"]))
	check(main.delivery.deliveries_today == deliveries0 + 1 and not main.delivery.truck_away(), "D2: the event's truck is coming in")
	var owed: Array = needs.keys().filter(func(s): return s != "Produce")
	check(not _marker("Produce").visible and _marker(owed[0]).visible and _marker(owed[0]).text == "BOX NEEDED", "D2: markers on the sections still owed a box ('%s')" % _marker(owed[0]).text)
	# Unpack every owed box (as the crew would on its pad).
	var want_secs: Array = needs.keys().filter(func(s): return s != "Produce")
	var old_boxes: Array = boxes().map(func(b): return b.name)
	var t := 0.0
	while ev().active() and t < 60.0:
		for b in boxes():
			if b.name in old_boxes:
				continue # an earlier truck's: only the event's own are unpacked here
			if b.get_node("Carryable").carrier_id == 0 and b.get_meta("section") in want_secs and int(ev().data["have"].get(b.get_meta("section"), 0)) < 1:
				main.delivery.unpack(b)
		await wait(0.5)
		t += 0.5
	check(not ev().busy() and ev().log_today[-1][0] == "Surprise Delivery" and ev().log_today[-1][1], "D3: every section's box unpacked -> COMPLETE (%.0fs after the truck)" % t)
	await _end_clean("D3")
	main.staff.staff = {}
	main.staff.on_books = {}
	main.staff.sync_helpers()
	# The miss: a forced one that runs out (once the truck's away again).
	await wait_until(func(): return main.delivery.truck_away(), 60.0)
	check(await force("delivery"), "D4: another Surprise Delivery")
	await time_out()
	check(not ev().log_today[-1][1], "D4: time's up -> missed")
	await _end_clean("D4")
	# A truck already at the dock: the event's boxes go on it, first in line.
	main.delivery._truck_timer = 0.0
	await wait_until(func(): return not main.delivery.truck_away(), 30.0)
	var load0: Array = main.delivery.truck_load.duplicate()
	check(await force("delivery"), "D5: a Surprise Delivery with a truck at the dock")
	var n: int = ev().data["needs"].values().reduce(func(a, b): return a + int(b), 0)
	var tl: Array = main.delivery.truck_load
	check(tl.size() >= n and tl.slice(0, n).all(func(sec): return ev().data["needs"].has(sec)), "D5: its %d box(es) went on that truck, first off (load %s, was %s)" % [n, str(tl), str(load0)])
	await time_out()
	await _end_clean("D5")

func _each_inspection() -> void:
	main.cleanup.litter = []
	main.cleanup.puddles = []
	check(await force("inspection"), "I1: Surprise Inspection starts")
	var bar: float = ev().data["pass_at"]
	check(is_equal_approx(bar, main.store_rating.mess_per_star()), "I1: the bar is one star's worth of mess (%s)" % str(bar))
	# A failing floor.
	for i in int(bar) + 4:
		main.cleanup.drop_litter(Vector2(1300 + (i % 10) * 30, 330 + (i / 10) * 30))
	await wait(0.3)
	check(float(ev().data["mess"]) > bar and main._order_label.text.begins_with("INSPECTOR IN") and main._order_label.text.contains("clean up"), "I1: the live row counts the mess: '%s'" % main._order_label.text)
	var r0: float = main.store_rating.rating
	var b0: int = ev().bonus_today
	await time_out()
	check(not ev().result_ok and ev().result_text.begins_with("INSPECTION FAILED — mess") and ev().bonus_today == b0 and is_equal_approx(main.store_rating.rating, r0), "I2: a dirty store fails, no bonus, rating untouched ('%s')" % ev().result_text)
	await _end_clean("I2")
	# A passing floor.
	main.cleanup.litter = []
	main.store_rating.set_rating(3.0)
	check(await force("inspection"), "I3: another inspection")
	var bonus: int = ev().data["bonus"]
	await wait(0.3)
	check(main._order_label.text.contains("✓"), "I3: a clean store reads as passing: '%s'" % main._order_label.text)
	await time_out()
	check(ev().result_ok and ev().bonus_today == b0 + bonus and is_equal_approx(main.store_rating.rating, 3.0 + ev().INSPECTION_RATING_BUMP), "I3: passes: +$%d and the rating bumps 3.0 -> %.2f" % [bonus, main.store_rating.rating])
	await _end_clean("I3")

func _each_leak() -> void:
	main.cleanup.puddles = []
	check(await force("leak"), "L1: Leaky Roof starts")
	var total: int = ev().data["total"]
	check(await wait_until(func(): return int(ev().data.get("to_drop", 1)) == 0, total * ev().LEAK_DROP_GAP + 3.0), "L1: all %d leaks came down" % total)
	var leaks: Array = ev().data["leaks"]
	var secs := {}
	for pd in main.cleanup.puddles:
		if int(pd["id"]) in leaks:
			secs[main._section_name_at(pd["pos"])] = true
			check(pd.get("water", false), "L1: leak %d is water, in %s" % [int(pd["id"]), main._section_name_at(pd["pos"])])
	check(secs.size() == mini(total, section_names().size()), "L1: spread over %d sections (%s)" % [secs.size(), str(secs.keys())])
	check(main.store_rating.mess_points() >= leaks.size() * main.store_rating.MESS_SPILL, "L2: the leaks drag the rating like spills (mess %s)" % str(main.store_rating.mess_points()))
	await wait(0.1)
	check(main._order_label.text.begins_with("LEAKY ROOF — mop up %d leaks" % leaks.size()), "L2: the live row: '%s'" % main._order_label.text)
	var b0: int = ev().bonus_today
	var bonus: int = ev().data["bonus"]
	for id in leaks:
		main.cleanup.remove_puddle(int(id)) # what a mop stroke does when it finishes
		await physics_frame
	await wait(0.2)
	check(not ev().busy() and ev().bonus_today == b0 + bonus and ev().log_today[-1] == ["Leaky Roof", true, bonus], "L3: every leak mopped -> COMPLETE, +$%d" % bonus)
	await _end_clean("L3")
	# The miss: they stay on the floor (mess like any puddle).
	check(await force("leak"), "L4: another Leaky Roof")
	await wait_until(func(): return int(ev().data.get("to_drop", 1)) == 0, 20.0)
	var left: Array = ev().data["leaks"].duplicate()
	await time_out()
	check(not ev().log_today[-1][1] and left.all(func(id): return main.cleanup.puddles.any(func(pd): return int(pd["id"]) == int(id))), "L4: time's up -> missed; the %d leaks are still there to mop" % left.size())
	await _end_clean("L4")

## =============================================================================
## INTERACTIONS
## =============================================================================

func _run_interactions() -> void:
	await selling()
	quiet()
	# --- X1 an open priority order goes first: the event waits for it.
	main._issue_priority_order("Dry Goods", 3)
	check(main.order_section == "Dry Goods", "X1: a priority order is open")
	ev().force_next("rush", 0.1)
	await wait(1.5)
	check(not ev().busy(), "X1: an event due now waits while the order is open")
	main._close_priority_order(false)
	check(await wait_until(func(): return ev().warning(), 5.0), "X1: ...and comes once it closes")
	await wait_until(func(): return ev().active(), 15.0)
	await time_out()
	# --- X2 an event due soon keeps a new order from being called.
	ev()._countdown = 20.0
	main._order_timer = 0.0
	await wait(0.5)
	check(main.order_section == "", "X2: an event due in 20s blocks a call-out with a %ds window" % int(main._priority_order_window()))
	ev()._countdown = -1.0
	main._order_timer = 0.0
	check(await wait_until(func(): return main.order_section != "", 2.0), "X2: nothing due -> the call-out comes")
	main._close_priority_order(false)
	main._order_timer = 1.0e9
	# --- X3 the hazards keep running through an event.
	fk()._pause_timer = 0.0
	release_manager()
	check(await force("inspection"), "X3: an event runs")
	check(fk().active and main.manager.active and main.hazard_levels()["orders"] == 2, "X3: the forklift and the manager are still on (and orders stay configured)")
	# --- X4 the HUD rows: the event row never overlaps LOOK BUSY or a toast.
	main.show_toast("a toast", Color.WHITE, 3.0)
	main.manager.watch_peer = 1
	main.manager.watch_level = 0.8
	await wait(0.1)
	var ol: Control = main._order_label
	check(ol.visible and main._toast_label.visible and not rects_overlap(ol, main._toast_label) and not rects_overlap(ol, main._watch_label), "X4: event row, toast and LOOK BUSY each in their own band")
	main.manager.watch_level = 0.0
	await time_out()
	quiet()
	# --- X5 the rating: a passed inspection bumps it; leaks drag it.
	main.cleanup.litter = []
	main.store_rating.set_rating(2.0)
	check(await force("inspection"), "X5: an inspection")
	await time_out()
	check(is_equal_approx(main.store_rating.rating, 2.0 + ev().INSPECTION_RATING_BUMP), "X5: passing bumps the rating 2.0 -> %.2f" % main.store_rating.rating)
	main.store_rating.set_rating(5.0)
	main.rating_frozen = false
	check(await force("leak"), "X5: a Leaky Roof")
	await wait_until(func(): return int(ev().data.get("to_drop", 1)) == 0, 20.0)
	await wait(0.5)
	check(main.store_rating.target < 5.0 and main.store_rating.trend() < 0, "X5: unmopped leaks pull the rating's target down (%.2f)" % main.store_rating.target)
	main.rating_frozen = true
	for id in ev().data["leaks"]:
		main.cleanup.remove_puddle(int(id))
	await wait(0.3)
	# --- X6 the store closing calls a running event off cleanly.
	check(await force("rush"), "X6: a rush runs")
	var b0: int = ev().bonus_today
	main.shift_time_left = 0.05
	await wait_until(func(): return main.cleanup_active, 5.0)
	await wait(0.2)
	check(not ev().busy() and ev()._countdown < 0.0 and ev().bonus_today == b0 and not ev().log_today[-1][1], "X6: the store closed -> the rush is called off (missed, no bonus), nothing pending")
	check(ev().log_today[-1][0] == "Lunch Rush" and ev().result_text.contains("the store closed"), "X6: '%s'" % ev().result_text)
	# --- X7 the money: bonuses ride Pay Today into the bank through
	# _bank_shift_pay(); lifetime grows by the pay; the report says so.
	var m0: int = main.money
	var l0: int = main.lifetime_earned
	main.clock_out(1)
	await wait_until(func(): return main.is_day_report_active(), 5.0)
	await wait(0.3)
	var pay: int = main._pay_today()
	check(main.money == m0 + pay - main.staff.wages_today and main.lifetime_earned == l0 + maxi(0, pay), "X7: bank +%s, lifetime +$%d — the one payout path" % [main._format_money(pay), main.lifetime_earned - l0])
	check(main.report_event_label.visible and main.report_event_label.text == ev().report_line() and main.report_event_label.text.contains("Inspection"), "X7: the report's event line: '%s'" % main.report_event_label.text)
	check(ev().bonus_today >= 2 * ev().bonus_for("inspection") and pay >= ev().bonus_today - main.writeups_today * main.WRITEUP_PENALTY, "X7: today's bonuses ($%d) are in that pay" % ev().bonus_today)
	# --- X8 the next shift starts clean.
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 10.0)
	check(ev().bonus_today == 0 and ev().log_today.is_empty() and not ev().busy() and ev().report_line() == "", "X8: a new shift: no bonus, no log, nothing running")
	finish()

## =============================================================================
## SHOP
## =============================================================================

func _run_shop() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 30.0)
	await wait(0.5)
	main.test_hold_customers = true
	# --- S1 the lockers: a real walk, a real E.
	check(shop().upgrades.is_empty() and not shop()._hint.visible and not shop().panel.visible, "S1: no gear, no prompt, no panel away from the lockers")
	check(await walk_to(shop().LOCKER_SPOT, 10.0, 25.0), "S1: walked to the gear lockers")
	await wait(0.2)
	check(shop()._hint.visible and shop()._hint.text.contains("gear shop"), "S1: prompt: '%s'" % shop()._hint.text)
	await tap(act + "interact")
	await wait(0.2)
	check(shop().panel.visible and shop().buttons.size() == shop().UPGRADES.size(), "S1: E opens the shop: %d items" % shop().buttons.size())
	# --- S2 broke: refused, nothing charged.
	check(main.money == 0 and shop().buttons["shoes"].disabled and shop().blocker("shoes") == "need $%d more" % shop().next_cost("shoes"), "S2: an empty bank: '%s'" % shop().blocker("shoes"))
	check(not shop().buy("shoes", 1) and main.money == 0 and shop().upgrade_level("shoes") == 0, "S2: the host refuses it")
	# --- S3 buy, out of the bank; lifetime untouched.
	# (PHASE 5: prices read from Shop.gd, not written in.)
	var shoes: Array = shop().UPGRADES[0]["costs"]
	var brace0: int = shop().next_cost("brace")
	main.money = shoes[0] + brace0 + shop().next_cost("soles") + 500
	var bank0: int = main.money
	main.lifetime_earned = 30000
	await wait(0.2)
	shop().buttons["shoes"].pressed.emit()
	await wait(0.2)
	check(shop().upgrade_level("shoes") == 1 and main.money == bank0 - shoes[0] and main.lifetime_earned == 30000, "S3: Sneakers 1 for $%d — bank %s, lifetime still $30000 (spending never touches it)" % [shoes[0], main._format_money(main.money)])
	check(shop().buttons["shoes"].text == "Buy  $%d" % shoes[1], "S3: the button moves to the next level's price ('%s')" % shop().buttons["shoes"].text)
	shop().buttons["brace"].pressed.emit()
	await wait(0.2)
	check(shop().upgrade_level("brace") == 1 and main.money == bank0 - shoes[0] - brace0, "S3: Back Brace 1 for $%d (bank %s)" % [brace0, main._format_money(main.money)])
	# --- S4 a race: two requests for the same level in the same instant buy one.
	var m0: int = main.money
	var a: bool = shop().buy("soles", 1, 0)
	var b: bool = shop().buy("soles", 1, 0)
	check(a and not b and shop().upgrade_level("soles") == 1 and main.money == m0 - shop().UPGRADES[2]["costs"][0], "S4: two buys of Soles level 1 at once -> one level, one charge")
	# --- S5 maxed.
	shop().upgrades = {"shoes": 1, "brace": 1, "soles": 1, "badge": 1}
	await wait(0.2)
	check(shop().buttons["badge"].text == "MAXED" and shop().buttons["badge"].disabled and not shop().buy("badge", 1), "S5: maxed gear can't be bought")
	# --- S6 prep only.
	main.open_store(1)
	await wait(0.2)
	check(shop().blocker("boots") == "buy gear during prep, before you open" and not shop().buy("boots", 1) and shop().buttons["boots"].disabled, "S6: store open: '%s'" % shop().blocker("boots"))
	# --- S7 walking off closes the panel.
	await walk_to(shop().LOCKER_SPOT + Vector2(250, -80), 10.0, 10.0)
	await wait(0.2)
	check(not shop().panel.visible, "S7: walking off closes the panel")
	# --- S8 the gear really does what it says (the Endless Mode upgrade check, unchanged).
	await _check_upgrade_effects("S8")
	# --- S9 coffee still works, $ off Pay (no Bucks anywhere).
	player().teleport_to(main.break_room.COFFEE_POS + Vector2(0, 60))
	await wait(0.3)
	var pay0: int = main._pay_today()
	await tap(act + "interact")
	await wait(0.3)
	check(main.break_room.has_coffee(1) and main._pay_today() == pay0 - main.break_room.COFFEE_COST_DOLLARS and is_equal_approx(player().speed(), player().SPEED * (shop().speed_mult() + 0.2)), "S9: coffee: +20%% speed on top of the Sneakers, $%d off Pay Today" % main.break_room.COFFEE_COST_DOLLARS)
	finish()

## =============================================================================
## CO-OP — host + 2 clients
## =============================================================================

## What every peer must agree on (and what each derives from it on screen).
func _ev_view() -> Dictionary:
	return {"phase": ev().phase, "key": ev().key, "id": ev().event_id, "data": ev().data, "bonus_today": ev().bonus_today,
		"log": ev().log_today, "banner": ev().banner_lines().slice(0, 2), "row": main._order_label.text.split("   ")[0] if ev().active() else "",
		"gear": shop().upgrades, "money": main.money}

func _view_req(n: int, ids: Array, tag: String) -> void:
	await wait(0.6)
	var mine := _canon(_ev_view())
	_net_write("evview_req_%d" % n, {"view": JSON.parse_string(mine)})
	for id in ids:
		var a := await _net_read("evview_%d_%d" % [n, id], 15.0)
		check(a.get("ok", false), "%s: %s sees what the host sees%s" % [tag, main.player_display_name(id), "" if a.get("ok", false) else ": %s vs host %s" % [str(a.get("mine")), mine]])

func _ev_client_ids() -> Array:
	var ids: Array = main.players.keys().filter(func(id): return id != 1)
	ids.sort()
	return ids

func _run_ev_net_host() -> void:
	var want := _arg_int("--players=", 3)
	await wait_until(func(): return main.shift_active and main.players.size() >= want, 60.0)
	check(main.players.size() >= want, "NE0: the crew is here (%d)" % main.players.size())
	ev().reschedule = false
	await wait(1.0)
	var ids := _ev_client_ids()
	var vn := 0
	# --- NE1 the shop over the wire: a forged far request, then a race.
	main.money = 3000
	_net_write("go_forge", {"who": ids[0]})
	await _net_read("did_forge_%d" % ids[0], 20.0)
	await wait(0.5)
	check(shop().upgrade_level("boots") == 0 and shop().purchases_refused >= 1 and main.money == 3000, "NE1: a buy RPC from across the store is refused (refused %d)" % shop().purchases_refused)
	_net_write("go_race", {"t": Time.get_unix_time_from_system() + 3.0})
	for id in ids:
		await _net_read("did_race_%d" % id, 30.0)
	await wait(1.0)
	check(shop().upgrade_level("shoes") == 1 and main.money == 3000 - shop().UPGRADES[0]["costs"][0] and shop().purchases_applied == 1, "NE1: both clients bought Sneakers in the same instant -> level 1, charged once (applied %d, refused %d)" % [shop().purchases_applied, shop().purchases_refused])
	vn += 1
	await _view_req(vn, ids, "NE1")
	# --- NE2 an event, seen the same everywhere: warning, running, result.
	main.open_store(1)
	main.test_hold_customers = true
	await wait(0.3)
	main.shift_time_left = 2000.0
	main._order_timer = 1.0e9
	check(await force("catering", false), "NE2: a Catering Order warns")
	vn += 1
	await _view_req(vn, ids, "NE2 warning")
	await wait_until(func(): return ev().active(), 10.0)
	vn += 1
	await _view_req(vn, ids, "NE2 running")
	# --- NE3 the race: two units settle into the order's LAST open unit in
	# the same physics tick — it completes once, pays once, tags one.
	var needs: Dictionary = ev().data["needs"]
	var secs: Array = needs.keys()
	for sec in secs:
		var left: int = int(needs[sec]) - (1 if sec == secs[-1] else 0)
		for i in left:
			if loose_products(sec).is_empty():
				main._spawn_product_for(sec)
				await physics_frame
				await physics_frame
			await stock_one(sec)
	var last: String = secs[-1]
	check(ev().active() and int(ev().data["have"][last]) == int(needs[last]) - 1, "NE3: one unit left, in %s" % last)
	for i in 2:
		if loose_products(last).size() < 2:
			main._spawn_product_for(last)
			await physics_frame
			await physics_frame
	var pair: Array = loose_products(last).slice(0, 2)
	var slots := []
	var cell: Vector2i = section_by_name(last)["grid_pos"]
	for sb in main.shelves:
		if main._grid_cell_of(sb.global_position) != cell or sb.get_node("Shelf").wrecked:
			continue
		var shelf: Node = sb.get_node("Shelf")
		for i in shelf.slots.size():
			if not shelf.filled[i] and slots.size() < 2:
				slots.append(shelf.slots[i])
	var b0: int = ev().bonus_today
	var bonus: int = ev().data["bonus"]
	var c0: int = ev().completions
	move_body(pair[0], slots[0].global_position)
	move_body(pair[1], slots[1].global_position)
	await wait_until(func(): return _is_placed(pair[0]) and _is_placed(pair[1]), 3.0)
	await wait(0.3)
	var tagged: int = pair.filter(func(o): return o.has_meta("event_item")).size()
	check(not ev().busy() and ev().completions == c0 + 1 and ev().bonus_today == b0 + bonus and tagged == 1, "NE3: two units at once into the last slot of the order -> one completion, $%d once, one unit tagged (%d)" % [bonus, tagged])
	vn += 1
	await _view_req(vn, ids, "NE3 result")
	# --- NE4 the same for a rush's last sale (two registers, one tick).
	check(await force("rush"), "NE4: a Lunch Rush")
	var rsec: String = ev().data["section"]
	ev().data = ev().data.merged({"done": int(ev().data["goal"]) - 1}, true)
	var c1: int = ev().completions
	var b1: int = ev().bonus_today
	ev().note_sale(rsec)
	ev().note_sale(rsec) # the second register, same instant
	check(ev().completions == c1 + 1 and ev().bonus_today == b1 + bonus_of("rush") and not ev().busy(), "NE4: two last sales at once -> one completion, one bonus")
	# --- NE5 every client's report shows the same event line.
	main.shift_time_left = 0.05
	await wait_until(func(): return main.cleanup_active, 5.0)
	main.clock_out(1)
	await wait_until(func(): return main.is_day_report_active(), 5.0)
	await wait(0.5)
	_net_write("go_report", {"line": main.report_event_label.text, "pay": main._pay_today()})
	for id in ids:
		var a := await _net_read("did_report_%d" % id, 20.0)
		check(a.get("ok", false), "NE5: %s's report: '%s'" % [main.player_display_name(id), str(a.get("line"))])
	_net_write("all_done", {})
	await wait(1.0)
	finish()

func bonus_of(k: String) -> int:
	return ev().bonus_for(k)

func _run_ev_net_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()) and main.shift_active, 60.0)
	me = main.multiplayer.get_unique_id()
	act = root.get_node("Settings").local_prefix()
	var t0 := Time.get_ticks_msec()
	var vn := 1
	var did := {}
	while Time.get_ticks_msec() - t0 < 400000:
		if FileAccess.file_exists(NET_DIR + "all_done"):
			break
		if FileAccess.file_exists(NET_DIR + "evview_req_%d" % vn):
			var req := await _net_read("evview_req_%d" % vn, 5.0)
			var theirs: String = _canon(req.get("view", {}))
			var ok := await wait_until(func(): return _canon(_ev_view()) == theirs, 8.0)
			_net_write("evview_%d_%d" % [vn, me], {"ok": ok, "mine": _canon(_ev_view())})
			vn += 1
			continue
		if not did.has("forge") and FileAccess.file_exists(NET_DIR + "go_forge"):
			did["forge"] = true
			var g := await _net_read("go_forge", 5.0)
			if int(g.get("who", 0)) == me:
				player().teleport_to(Vector2(700, 270)) # nowhere near the lockers
				await wait(0.4)
				shop()._request_buy.rpc_id(1, "boots", 0)
			_net_write("did_forge_%d" % me, {})
			continue
		if not did.has("race") and FileAccess.file_exists(NET_DIR + "go_race"):
			did["race"] = true
			var g := await _net_read("go_race", 5.0)
			var ids := _ev_client_ids()
			player().teleport_to(shop().LOCKER_SPOT + Vector2(-20 + 40 * ids.find(me), 0))
			await wait(0.5)
			await tap(act + "interact")
			await wait_until(func(): return shop().panel.visible and shop().buttons.has("shoes"), 5.0)
			while Time.get_unix_time_from_system() < float(g.get("t", 0)):
				await process_frame
			shop().buttons["shoes"].pressed.emit()
			await wait(1.0)
			check(shop().upgrade_level("shoes") == 1, "client %d: I see Sneakers level 1 after the race" % me)
			_net_write("did_race_%d" % me, {})
			continue
		if not did.has("report") and FileAccess.file_exists(NET_DIR + "go_report"):
			did["report"] = true
			var g := await _net_read("go_report", 5.0)
			var ok := await wait_until(func(): return main.report_layer.visible and main.report_event_label.text == str(g.get("line")) and main._pay_today() == int(g.get("pay", -1)), 8.0)
			check(ok, "client %d: my report matches the host's event line and pay" % me)
			_net_write("did_report_%d" % me, {"ok": ok, "line": main.report_event_label.text})
			continue
		await wait(0.1)
	finish()

## =============================================================================
## FEASIBLE — can ONE player handle each event? (bot sim)
## The solo brain (hazards_test.gd's competent player, --event-brain: it goes
## for what an event asks for, and staff_test.gd's cleaning pass handles the
## Inspection's and the Leaky Roof's mess) plays whole shifts at the given
## economy; one event is forced per shift, FORCE_AFTER s after the store
## opens; each outcome is printed (FEASIBLE ...) and the summary counts wins.
## --hire=...: with helpers (staff_test.gd's flag). --only=key: just one.
## =============================================================================

const FORCE_AFTER := 10.0

func _run_feasible() -> void:
	_hire_spec = _parse_hire()
	upkeep_hook = _event_upkeep
	event_aware = true
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.substr(7)
	var keys: Array = [only] if only != "" else ev().EVENT_ORDER.duplicate()
	var rounds := _arg_int("--rounds=", 1)
	await wait_until(func(): return main.players.has(1), 20.0)
	main.staff.staff = _hire_spec.duplicate(true)
	var results := {}
	for r in rounds:
		for k in keys:
			await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 60.0)
			stats = {"placed": 0, "hits": 0, "watched_s": 0.0, "idle_s": 0.0, "reasons": {}, "wrecks": 0, "overlap": 0, "banner_and_busy_s": 0.0, "banner_clash": 0, "first_customer_s": -1.0, "shift_len": main.shift_time_left, "grace": main.prep_time_left, "slip_s": 0.0}
			ev()._skip_shift = false
			var forced := {"done": false}
			var forcer := func():
				await wait_until(func(): return main.store_open or not main.shift_active, 3000.0)
				# At opening, in place of the shift's own roll (so it holds the
				# first call-out back, as a real roll does).
				if main.store_open:
					ev().force_next(k, FORCE_AFTER)
				forced["done"] = true
			forcer.call()
			await _play_shift()
			for o in get_nodes_in_group("carryable"):
				if o.get_node("Carryable").carrier_id == me:
					await tap(act + "interact")
			await _play_cleanup(false, true)
			await wait_until(func(): return main.is_day_report_active(), 200.0)
			await wait(0.3)
			var entry: Array = ev().log_today.filter(func(e): return e[0] == ev().name_of(k))
			var outcome := "won" if not entry.is_empty() and entry[0][1] else ("missed" if not entry.is_empty() else "never ran")
			results[k] = results.get(k, []) + [outcome]
			print("FEASIBLE day=%d hire=%s event=%s outcome=%s | log %s | pay %s, sold %d, opened at %.0fs, selling %.0fs" % [main.debug_day, str(_hire_spec.keys()).replace(" ", ""), k, outcome, str(ev().log_today), main._format_money(main._pay_today()), main._total_sold() - main._sold_at_day_start, stats.get("opened_at", -1.0), stats["shift_len"] - stats.get("opened_at", 0.0)])
			main._on_continue_pressed()
	print("FEASIBLE SUMMARY day=%d hire=%s: %s" % [main.debug_day, str(_hire_spec.keys()).replace(" ", ""), str(results)])
	for k in results:
		check(results[k].has("won"), "FEASIBLE: a solo player%s can win %s (%s)" % [" with helpers" if not _hire_spec.is_empty() else "", ev().name_of(k), str(results[k])])
	finish()

## =============================================================================
## SHOTS — each event's warning and running state (xvfb)
## =============================================================================

func _ev_shot(name: String) -> void:
	await process_frame
	await process_frame
	await process_frame
	DirAccess.make_dir_recursive_absolute("user://event_shots")
	var path := "user://event_shots/%02d_%s.png" % [shot_index, name]
	shot_index += 1
	root.get_texture().get_image().save_png(path)
	print("SHOT  " + ProjectSettings.globalize_path(path))

func _run_ev_shots() -> void:
	root.size = Vector2i(960, 540)
	await selling()
	quiet()
	main.test_hold_customers = false
	main.debug_label.visible = false
	for k in ev().EVENT_ORDER:
		if k == "delivery":
			await wait_until(func(): return main.delivery.truck_away(), 60.0)
		if k == "inspection":
			for i in 12:
				main.cleanup.drop_litter(Vector2(1300 + (i % 6) * 40, 350 + (i / 6) * 40))
		ev().force_next(k, 0.1)
		await wait_until(func(): return ev().warning(), 6.0)
		await wait(0.3)
		# Stand where the event is.
		var focus: Vector2 = Vector2(1440, 600)
		if ev().data.has("section"):
			focus = main.delivery.pad_center(ev().data["section"]) + Vector2(0, 120)
		elif ev().data.has("needs"):
			focus = main.delivery.pad_center(ev().data["needs"].keys()[0]) + Vector2(0, 120)
		player().teleport_to(focus)
		await wait(0.5)
		await _ev_shot("%s_warning" % k)
		await wait_until(func(): return ev().active(), 15.0)
		await wait(6.0 if k == "leak" else 1.5)
		if k == "leak":
			var pd: Array = main.cleanup.puddles.filter(func(p): return int(p["id"]) in ev().data["leaks"])
			if not pd.is_empty():
				player().teleport_to(pd[0]["pos"] + Vector2(0, 80))
		if k == "delivery":
			await wait(8.0)
		await wait(0.5)
		await _ev_shot("%s_active" % k)
		if k in ["rush", "catering"]:
			# A win, for the result line.
			if k == "rush":
				await sell_from(ev().data["section"], int(ev().data["goal"]))
			else:
				for sec in ev().data["needs"]:
					while ev().active() and int(ev().data["have"].get(sec, 0)) < int(ev().data["needs"][sec]):
						if await stock_one(sec) == null:
							main._spawn_product_for(sec)
							await wait(0.1)
			await wait(0.2)
			await _ev_shot("%s_result" % k)
		else:
			await time_out()
			await wait(0.2)
			await _ev_shot("%s_result" % k)
		await wait(3.5)
	# The report with the events line.
	main.shift_time_left = 0.05
	await wait_until(func(): return main.is_day_report_active(), 10.0)
	await wait(0.6)
	await _ev_shot("report")
	# The gear shop.
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 10.0)
	main.money = 2500
	player().teleport_to(shop().LOCKER_SPOT)
	await wait(0.5)
	await _ev_shot("lockers_prompt")
	await tap(act + "interact")
	await wait(0.4)
	shop().buttons["shoes"].pressed.emit()
	await wait(0.5)
	await _ev_shot("shop_panel")
	finish()
