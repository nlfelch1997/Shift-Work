extends "res://tools/staff_test.gd"
## OCT 2026 PIVOT, PHASE 4B — THE JANITOR (Janitor.gd, hired through Staff.gd).
## Reuses tools/staff_test.gd's helpers (and through it economy_test.gd's and
## hazards_test.gd's: walking, key taps, the solo bot brain, the net step
## files, the income harness) and drives the real Main.tscn through the real
## game code. Not part of the game. Real wall-clock time throughout (no
## --fixed-fps) except where a mode's header says it's a bot sim.
##
## HIRE (solo, from a brand-new shop: a real walk to the staff board and a real
## E, the janitor's row and buttons, every refusal — the sections gate and the
## money gate apart —, the one speed upgrade, prep-only, the wage at clock-out
## (bank yes, lifetime no; beside a section helper's), letting go — this
## shift still paid, a held bag back in its can —, rehiring from scratch):
##   godot --headless --path . --script res://tools/janitor_test.gd -- --server --no-save --test=jan-hire
## CHORES (litter by hand into the nearest can with room, puddles and spills
## mopped with their own mop, a full can's bag to the dumpster, what they
## leave alone, the crew's tools untouched, off the clock at close, never in
## the Break Room / a locked section / the forklift's floor / a forklift):
##   godot --headless --path . --script res://tools/janitor_test.gd -- --server --day=5 --no-save --test=jan-chores
## STUCK (the safety nets): a janitor pinned in place gives up on its target
## after STUCK_SECONDS and comes back to it after the cooldown; a target the
## grid can't reach is skipped at once; litter in a locked section or the
## Break Room is never a target; with the Produce forklift patrolling and
## litter dropped in its aisle, the janitor gives way and never ends up in it:
##   godot --headless --path . --script res://tools/janitor_test.gd -- --server --day=5 --no-save --test=jan-stuck
## SAVE (version 6), three launches over one file, in order: a v5 (Phase 4)
## save loads with no janitor and its helper intact, hiring one writes v6;
## relaunch keeps them, trained; hand-edited files (a janitor with too few
## sections, a level past the top, junk) load cleaned:
##   godot ... -- --server --save-file=user://jan_test/save.json --test=jan-save --phase=1   (then 2, 3)
## CO-OP (host + 2 clients, each its own process; one shared bank): two
## clients hiring the janitor in the same instant hire once and pay once; a
## forged request from across the store is refused; an upgrade race buys one
## level; every peer sees Pat where the host has them, with what's in their
## hands; the wage on every peer's report; a client lets them go:
##   godot ... -- --server --port=8979 --players=3 --day=5 --no-save --money=3000 --test=jan-net &
##   (x2) godot ... -- --client --connect-port=8979 --no-save --test=jan-net
## EVENTS (how the janitor meets Leaky Roof and Surprise Inspection): with a
## janitor on staff the roof drops LEAK_PER_JANITOR more leaks; they mop them
## at LEAK_MOP_TIME each, counted for the event like anyone's mop, and alone
## don't finish the roof; janitor + crew do. An inspection with a janitor on
## staff has its own bar knob and the janitor walking the inspector round (off
## the floor, tag says so): the crew cleans, passes, and Pat goes back to work:
##   godot --headless --path . --script res://tools/janitor_test.gd -- --server --day=7 --shift-seconds=1200 --no-save --events=on --test=jan-events
## SMOKE (the janitor on the floor for a few minutes of a real crowd; prints
## what they're doing every 5 s):
##   godot --headless --path . --script res://tools/janitor_test.gd -- --server --day=5 --no-save --test=jan-smoke
## REACH (stuck detection's other half: every spot a mess can land is one
## the janitor gets to): puddles dropped one at a time at the spots Events.gd
## drops leaks (Main._spawn_pos_in_section, every open section) and litter at
## customers' feet spots; each must be cleaned in time, and nothing gives up:
##   godot --headless --path . --script res://tools/janitor_test.gd -- --server --day=7 --no-save --test=jan-reach [--n=12]
## EVENTS ALONE (measurement, bot-free: the player never moves; can the
## janitor alone handle a Leaky Roof / Surprise Inspection? one long shift,
## the event forced N times with a gap of ordinary trading between; --no-janitor
## for the same store with nobody cleaning):
##   godot --headless [--fixed-fps 60] --path . --script res://tools/janitor_test.gd -- --server --day=7 --shift-seconds=2400 --no-save --events=on --test=jan-events-alone --only=leak --rounds=6 [--no-janitor] [--jspeed=1]

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--test="):
			_mode = a.substr(7)
	if not _mode.begins_with("jan-"):
		super._initialize()
		return
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	main.events_on = "--events=on" in args
	careless = true
	if _mode == "jan-save":
		_prepare_jan_save()
	if OS.get_environment("SW_NET_DIR") == "":
		NET_DIR = "user://net_janitor/"
	var client := "--client" in args
	match _mode:
		"jan-smoke": _run_jan_smoke.call_deferred()
		"jan-hire": _run_jan_hire.call_deferred()
		"jan-chores": _run_jan_chores.call_deferred()
		"jan-stuck": _run_jan_stuck.call_deferred()
		"jan-save": _run_jan_save.call_deferred()
		"jan-events": _run_jan_events.call_deferred()
		"jan-probe": _run_jan_probe.call_deferred()
		"jan-net": (_run_jan_net_client if client else _run_jan_net_host).call_deferred()
		"jan-events-alone": _run_jan_events_alone.call_deferred()
		"jan-reach": _run_jan_reach.call_deferred()
		_:
			print("FAIL  unknown --test=%s" % _mode)
			quit(1)

func jan() -> Node2D:
	return main.staff.janitor

func jan_line(tag: String) -> String:
	var j := jan()
	var cl: Node = main.cleanup
	return "JAN %s pos=%s job=%s key=%s hand=%d bag=%d work=%.2f status=%s | litter %d puddles %d cans %s | picked %d binned %d mopped %d (leaks %d) bags %d/%d stuck %d unreach %d yield %.1fs walked %.0f | rating %.2f" % [tag, str(j.position.round()), j._job.get("kind", "-"), str(j._job.get("key", "")), j.hand, j.bag_n, j.work, j.status, cl.litter.size(), cl.puddles.size(), str(cl.cans), j.litter_picked_today, j.litter_binned_today, j.mopped_today, j.leaks_mopped_today, j.bags_taken_today, j.bags_dumped_today, j.stuck_skips, j.unreachable_skips, j.forklift_yield_s, j.walked_px, main.store_rating.rating]

func _run_jan_smoke() -> void:
	await wait_until(func(): return main.shift_active, 20.0)
	main.money = 5000
	check(main.staff.do_action("Janitor", "hire", 1), "hire the janitor")
	await process_frame
	check(jan().active and jan().visible, "the janitor is on the floor")
	# Something to do from the start: a full can and a puddle.
	main.cleanup.set_can(1, main.cleanup.can_capacity())
	main.cleanup.drop_puddle(Vector2(1440, 700))
	for i in 40:
		if i == 1:
			main.open_store(1)
		await wait(5.0)
		print(jan_line("t=%d" % (i * 5)))
	finish()

func _arg_str(prefix: String, fallback: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return a.substr(prefix.length())
	return fallback

func _run_jan_events_alone() -> void:
	var k := _arg_str("--only=", "leak")
	var rounds := _arg_int("--rounds=", 4)
	var ev: Node2D = main.events
	ev.reschedule = false
	await wait_until(func(): return main.shift_active, 20.0)
	ev._skip_shift = true # no roll of its own: every event here is forced
	main.money = 5000
	var with_j := not "--no-janitor" in OS.get_cmdline_user_args()
	if with_j:
		check(main.staff.do_action("Janitor", "hire", 1), "hire the janitor")
		var lvl := _arg_int("--jspeed=", 0)
		if lvl > 0:
			var next: Dictionary = main.staff.staff.duplicate(true)
			next["Janitor"]["speed"] = lvl
			main.staff.staff = next
			main.staff.sync_helpers()
	main.open_store(1)
	await wait(40.0) # some ordinary mess first
	var won := 0
	for r in rounds:
		var n0: int = ev.log_today.size()
		var leaks0: int = jan().leaks_mopped_today
		ev.force_next(k, 0.5)
		await wait_until(func(): return ev.log_today.size() > n0, 200.0)
		var entry: Array = ev.log_today[-1] if ev.log_today.size() > n0 else ["?", false, 0]
		if entry[1]:
			won += 1
		print("JANEV event=%s janitor=%d round=%d outcome=%s | leaks mopped by the janitor %d | data at end: %s | rating %.2f, mess %.1f (bar %.1f)" % [k, 1 if with_j else 0, r + 1, "won" if entry[1] else "missed", jan().leaks_mopped_today - leaks0, ev.result_text, main.store_rating.rating, main.store_rating.mess_points(), float(ev.data.get("pass_at", ev._inspection_bar()))])
		await wait(25.0)
	print("JANEV SUMMARY event=%s janitor=%d won %d/%d" % [k, 1 if with_j else 0, won, rounds])
	finish()

func _run_jan_reach() -> void:
	main.test_hold_customers = true
	await wait_until(func(): return main.shift_active, 20.0)
	# Only the dropped mess (the stage-4 spills would queue ahead of it).
	main.ambience._spill_timer = 1.0e9
	for sp in main.ambience.spills.duplicate():
		main.ambience.remove_spill(int(sp["id"]))
	main.money = 5000
	check(main.staff.do_action("Janitor", "hire", 1), "R0: hire the janitor")
	main.open_store(1)
	var n := _arg_int("--n=", 10)
	var worst := 0.0
	var fails_here := 0
	for sec in main._unlocked_sections():
		for i in n:
			var pos: Vector2 = main._spawn_pos_in_section(sec)
			if not main.cleanup._litter_spot_ok(pos):
				continue
			var id: int = main.cleanup.drop_puddle(pos, 20.0, true) if i % 2 == 0 else main.cleanup.drop_litter(pos)
			var is_puddle := i % 2 == 0
			var t0 := _wall()
			var gone := func(): return not (main.cleanup.puddles if is_puddle else main.cleanup.litter).any(func(x): return x["id"] == id)
			var ok: bool = await wait_until(gone, 90.0)
			var took := _wall() - t0
			worst = maxf(worst, took)
			if not ok:
				fails_here += 1
				print("INFO R1 not cleaned: %s %s at %s (janitor at %s, job %s)" % [sec["name"], "puddle" if is_puddle else "litter", str(pos.round()), str(jan().position.round()), str(jan()._job.get("key", "-"))])
	check(fails_here == 0, "R1: every puddle/litter at a spawn spot in every open section was cleaned (worst %.0fs)" % worst)
	check(jan().stuck_skips == 0 and jan().unreachable_skips == 0, "R2: no give-ups (stuck %d, unreachable %d)" % [jan().stuck_skips, jan().unreachable_skips])
	finish()

## =============================================================================
## HIRE
## =============================================================================

const JK := "Janitor"

func _run_jan_hire() -> void:
	main.cleanup_ceiling_override = 0.0
	await wait_until(func(): return main.shift_active, 20.0)
	await wait(0.5)
	# --- J1 a fresh shop: one section, nobody hired, no janitor
	check(st().staff.is_empty() and main.money == 0 and main.sections_owned == 1, "J1: fresh shop — no staff, bank $0, Dry Goods only")
	check(not jan().active and not jan().visible, "J1: no janitor on the floor")
	var walked := await walk_to(st().BOARD_SPOT, 10.0, 20.0)
	check(walked, "J1: walked to the staff board")
	await tap(act + "interact")
	await wait(0.2)
	check(st().panel.visible, "J1: E at the board opens the panel")
	check(await panel_button(JK + ":hire") == null, "J1: no Hire button for the janitor with one section")
	check(st().blocker(JK, "hire") == "own %d sections first" % st().JANITOR_MIN_SECTIONS, "J1: the sections gate: '%s'" % st().blocker(JK, "hire"))
	main.money = 5000
	check(st().blocker(JK, "hire") == "own %d sections first" % st().JANITOR_MIN_SECTIONS, "J1: ...money doesn't open it: '%s'" % st().blocker(JK, "hire"))
	var refused0: int = st().actions_refused
	check(not st().do_action(JK, "hire", 1) and st().actions_refused == refused0 + 1 and main.money == 5000 and st().staff.is_empty(), "J1: a hire with one section is refused, nothing charged")
	# --- J2 two sections, broke: the money gate, its own refusal
	main.money = main.section_price("Produce")
	check(main.buy_section("Produce", 1) and main.money == 0, "J2: bought Produce (bank $0) — two sections")
	var b: Button = await panel_button(JK + ":hire")
	check(b != null and b.disabled and b.text.contains("$%d" % st().JANITOR_HIRE_FEE), "J2: the janitor's Hire button is there, disabled ('%s')" % (b.text if b else "none"))
	check(st().blocker(JK, "hire") == "need $%d more" % st().JANITOR_HIRE_FEE, "J2: eligible but broke — '%s'" % st().blocker(JK, "hire"))
	await press_button(JK + ":hire")
	check(not st().is_hired(JK) and main.money == 0, "J2: pressing it anyway is refused by the host")
	check(main._toast_label.text.contains("need $"), "J2: ...and says why ('%s')" % main._toast_label.text)
	# --- J3 hired
	main.money = 1000
	b = await panel_button(JK + ":hire")
	check(b != null and not b.disabled, "J3: with the money, Hire is live")
	await press_button(JK + ":hire")
	check(st().is_hired(JK) and main.money == 1000 - st().JANITOR_HIRE_FEE, "J3: Pat hired — bank $1000 -> %s" % main._format_money(main.money))
	await wait(0.2)
	check(jan().active and jan().visible and jan().speed == st().JANITOR_SPEED_BY_LEVEL[0], "J3: on the floor at %d px/s (%s)" % [int(jan().speed), str(jan().position.round())])
	check(jan()._tag.text == "Pat · staff", "J3: the staff tag over their head: '%s'" % jan()._tag.text)
	check(st().on_books.has(JK) and st().wages_due() == st().JANITOR_WAGE, "J3: on the books — $%d due at clock-out" % st().wages_due())
	check(main._toast_label.text.begins_with("You hired Pat as the janitor"), "J3: toast '%s'" % main._toast_label.text)
	# --- J4 the other refusals
	check(st().blocker(JK, "hire") == "Pat already works here", "J4: hiring twice: '%s'" % st().blocker(JK, "hire"))
	check(st().blocker(JK, "carry") == "maxed out" and await panel_button(JK + ":carry") == null, "J4: no carry upgrade for the janitor ('%s')" % st().blocker(JK, "carry"))
	main.tutorial.active = true
	var why_practice: String = st().blocker(JK, "speed")
	main.tutorial.active = false
	check(why_practice.begins_with("practice shift"), "J4: practice shift: '%s'" % why_practice)
	# --- J5 the one speed upgrade
	var m0: int = main.money
	main.money = 0
	await press_button(JK + ":speed")
	check(st().speed_level(JK) == 0 and main.money == 0, "J5: broke -> the upgrade is refused ('%s')" % st().blocker(JK, "speed"))
	main.money = m0
	await press_button(JK + ":speed")
	check(st().speed_level(JK) == 1 and main.money == m0 - st().JANITOR_SPEED_COSTS[0] and jan().speed == st().JANITOR_SPEED_BY_LEVEL[1], "J5: faster -> %d px/s, -$%d" % [int(jan().speed), st().JANITOR_SPEED_COSTS[0]])
	m0 = main.money
	b = await panel_button(JK + ":speed")
	check(b != null and b.disabled and b.text.contains("MAX") and st().blocker(JK, "speed") == "maxed out", "J5: one upgrade only: '%s' / '%s'" % [b.text if b else "none", st().blocker(JK, "speed")])
	await press_button(JK + ":speed")
	check(main.money == m0 and st().speed_level(JK) == 1, "J5: pressed anyway: nothing charged")
	await tap(act + "interact") # close the panel
	# --- J6 store open: no staff changes
	main.open_store(1)
	await wait(0.3)
	check(st().blocker(JK, "fire").begins_with("staff changes during prep"), "J6: store open -> '%s'" % st().blocker(JK, "fire"))
	check(not st().do_action(JK, "fire", 1) and st().is_hired(JK), "J6: letting go with the store open is refused")
	# --- J7 payday: the wage out of the bank, NOT out of lifetime earnings
	main.test_hold_customers = true
	add_sales(30)
	m0 = main.money
	var life0: int = main.lifetime_earned
	var pay := await end_day()
	check(main.money == m0 + pay - st().JANITOR_WAGE, "J7: clock-out: bank %s + pay %s - wage $%d = %s" % [main._format_money(m0), main._format_money(pay), st().JANITOR_WAGE, main._format_money(main.money)])
	check(main.lifetime_earned == life0 + maxi(0, pay), "J7: lifetime earned +%d — the pay, the wage not taken off" % (main.lifetime_earned - life0))
	check(st().wages_today == st().JANITOR_WAGE and main.report_pay_label.text.contains("Staff wages: -$%d (Pat $%d)" % [st().JANITOR_WAGE, st().JANITOR_WAGE]), "J7: the report shows the wage ('%s')" % main.report_pay_label.text.replace("\n", " / "))
	# --- J8 beside a section helper: one bill, both names
	await next_day()
	check(st().on_books.has(JK) and jan().active, "J8: next shift — Pat's back on the books and on the floor")
	main.money = 1000
	check(st().do_action("Produce", "hire", 1), "J8: hired Sam for Produce too")
	add_sales(10)
	m0 = main.money
	pay = await end_day()
	var both: int = st().JANITOR_WAGE + st().WAGE["Produce"]
	check(main.money == m0 + pay - both and st().wages_today == both, "J8: two wages, one bill: -$%d (bank %s)" % [both, main._format_money(main.money)])
	check(main.report_pay_label.text.contains("(Sam $%d, Pat $%d)" % [st().WAGE["Produce"], st().JANITOR_WAGE]), "J8: the report names both ('%s')" % main.report_pay_label.text.replace("\n", " / "))
	# --- J9 letting go: off the floor now, a held bag back in its can, this
	# shift still paid, then no wage
	await next_day()
	check(st().do_action("Produce", "fire", 1), "J9: let Sam go (just the janitor from here)")
	var cl: Node = main.cleanup
	cl.set_can(1, 9)
	jan().bag_n = 9
	jan()._bag_can = 1
	cl.set_can(1, 0) # as if Pat had just lifted can 1's bag out
	jan().hand = 2
	m0 = main.money
	var binned0: int = cl.trash_binned_today
	check(st().do_action(JK, "fire", 1) and not st().is_hired(JK) and main.money == m0, "J9: 'Let go' — Pat's off the staff, nothing charged now")
	await wait(0.2)
	check(not jan().active and not jan().visible, "J9: and off the floor")
	check(int(cl.cans[1]) >= 9 and jan().bag_n == 0, "J9: the bag they held went back in its can (can 1: %d)" % cl.cans[1])
	check(jan().hand == 0 and cl.trash_binned_today == binned0 + 2, "J9: the trash in hand went into a can (+%d binned)" % (cl.trash_binned_today - binned0))
	check(st().wages_due() == st().JANITOR_WAGE + st().WAGE["Produce"], "J9: this shift's wages are still owed ($%d)" % st().wages_due())
	pay = await end_day()
	check(main.money == m0 + pay - st().JANITOR_WAGE - st().WAGE["Produce"], "J9: clock-out charged them (bank %s)" % main._format_money(main.money))
	await next_day()
	m0 = main.money
	check(st().on_books.is_empty() and st().wages_due() == 0 and not jan().active, "J9: next shift: nobody on the books, no janitor")
	pay = await end_day()
	check(main.money == m0 + pay and st().wages_today == 0, "J9: ...and no wage at clock-out")
	# --- J10 hiring again starts from scratch
	await next_day()
	main.money = 1000
	check(st().do_action(JK, "hire", 1) and st().speed_level(JK) == 0 and main.money == 1000 - st().JANITOR_HIRE_FEE, "J10: rehired — the fee again, speed back to level 1")
	await wait(0.2)
	check(jan().speed == st().JANITOR_SPEED_BY_LEVEL[0], "J10: ...walking at %d px/s" % int(jan().speed))
	finish()

## =============================================================================
## CHORES
## =============================================================================

## Every frame, host: where the janitor is never allowed to be.
var _bad_spots := []
var _watch_jan := false

func _watch_janitor() -> void:
	_watch_jan = true
	while _watch_jan:
		await physics_frame
		var j := jan()
		if not j.active:
			continue
		var p: Vector2 = j.position
		var cell: Vector2i = main._grid_cell_of(p)
		var why := ""
		if cell == main.BREAK_ROOM_GRID_POS:
			why = "in the Break Room"
		elif cell != main.ENTRANCE_GRID_POS and cell != main.STORAGE_GRID_POS and cell != main.SIDEWALK_GRID_POS and not main.is_unlocked_at_pos(p):
			why = "in a locked section"
		elif load("res://CustomerNav.gd").JANITOR_KEEP_OUT.has_point(p):
			why = "on the delivery forklift's floor"
		else:
			for fk in [main.forklift, main.delivery_forklift]:
				if fk.visible and fk.active:
					var local: Vector2 = (p - fk.global_position).rotated(-fk.rotation) - Vector2(j.FORKLIFT_BOX_OFFSET, 0.0)
					if absf(local.x) < j.FORKLIFT_HALF.x - 4.0 and absf(local.y) < j.FORKLIFT_HALF.y - 4.0:
						why = "inside %s" % fk.name
		if why != "" and _bad_spots.size() < 20:
			_bad_spots.append("%s at %s" % [why, str(p.round())])

func _until_idle(timeout: float) -> bool:
	return await wait_until(func(): return jan()._job.get("kind", "") == "home" and jan().hand == 0 and jan().bag_n == 0 and jan()._pause <= 0.0, timeout)

func _run_jan_chores() -> void:
	main.test_hold_customers = true
	main.cleanup_ceiling_override = 0.0
	await wait_until(func(): return main.shift_active, 20.0)
	await wait(0.5)
	# Only the mess this test makes (C6 makes its own spill).
	main.ambience._spill_timer = 1.0e9
	for sp in main.ambience.spills.duplicate():
		main.ambience.remove_spill(int(sp["id"]))
	var cl: Node = main.cleanup
	main.money = 5000
	check(main.sections_owned >= 2 and st().do_action(JK, "hire", 1), "C0: hired the janitor (%d sections)" % main.sections_owned)
	_watch_janitor()
	await wait(0.5)
	check(jan()._job.get("kind", "") == "home", "C0: nothing to do -> waits at home (%s)" % str(jan().position.round()))
	var tools0: String = str(cl.tools)
	# --- C1 litter: picked by hand, HAND_MAX at a time, into the nearest can with room
	var spots := [Vector2(1300, 760), Vector2(1350, 800), Vector2(1400, 760), Vector2(1450, 820), Vector2(1500, 760), Vector2(1550, 820)]
	var binned0: int = cl.trash_binned_today
	var pay0: int = cl.litter_pay_today()
	var cans0: Array = cl.cans.duplicate()
	for p in spots:
		cl.drop_litter(p)
	var max_hand := 0
	var t0 := _wall()
	var done := false
	var can_ok := true
	var bin_jobs := 0
	var last_kind := ""
	while _wall() - t0 < 60.0:
		max_hand = maxi(max_hand, jan().hand)
		# Each can trip: to the nearest open can with room, from where it was chosen.
		var kind: String = jan()._job.get("kind", "")
		if kind == "bin" and last_kind != "bin":
			bin_jobs += 1
			if jan()._job["can"] != jan()._nearest_can(jan().position, true):
				can_ok = false
		last_kind = kind
		if cl.litter.is_empty() and jan().hand == 0:
			done = true
			break
		await physics_frame
	check(done, "C1: all %d pieces off the floor and in a can (%.0fs)" % [spots.size(), _wall() - t0])
	check(max_hand == jan().HAND_MAX, "C1: picked up to %d at a time before a can trip (max seen %d)" % [jan().HAND_MAX, max_hand])
	check(cl.trash_binned_today == binned0 + spots.size() and cl.litter_pay_today() == pay0 + spots.size() * cl.LITTER_PAY_PER_PIECE, "C1: +%d binned, +$%d trash pay (the crew's usual rate)" % [cl.trash_binned_today - binned0, cl.litter_pay_today() - pay0])
	var added := 0
	for i in cl.cans.size():
		added += int(cl.cans[i]) - int(cans0[i])
	check(added == spots.size() and can_ok and bin_jobs >= 2, "C1: %d can trips, each to the nearest can with room (cans %s -> %s)" % [bin_jobs, str(cans0), str(cl.cans)])
	# --- C2 a puddle: mopped with their own mop, in MOP_TIME_PUDDLE
	var pid: int = cl.drop_puddle(Vector2(1300, 900))
	# (Game time, in physics frames: under load real time runs ahead of it.)
	var mop_frames := 0
	t0 = _wall()
	while _wall() - t0 < 40.0 and cl.puddles.any(func(x): return x["id"] == pid):
		if jan().work >= 0.0:
			mop_frames += 1
		await physics_frame
	var took := mop_frames / float(Engine.physics_ticks_per_second)
	check(not cl.puddles.any(func(x): return x["id"] == pid), "C2: the puddle's mopped up")
	check(absf(took - jan().MOP_TIME_PUDDLE) < 0.25, "C2: ...in %.2fs of mopping (MOP_TIME_PUDDLE %.1f)" % [took, jan().MOP_TIME_PUDDLE])
	check(str(cl.tools) == tools0, "C2: with their own mop — the crew's mops and brooms never moved")
	# --- C3 a full can: the bag out to the dumpster, the can empty
	await _until_idle(20.0)
	cl.set_can(3, cl.can_capacity()) # Dairy/Frozen's (west of the hub)
	var dumped0: int = cl.bags_dumped_today
	var bagged := await wait_until(func(): return jan().bag_n == cl.can_capacity(), 60.0)
	check(bagged and int(cl.cans[3]) == 0, "C3: Pat lifted can 3's bag out (%d pieces), the can's empty" % jan().bag_n)
	check(cl.full_cans() == 0, "C3: no full can on the rating while the bag's in hand")
	var tipped := await wait_until(func(): return cl.bags_dumped_today == dumped0 + 1 and jan().bag_n == 0, 90.0)
	check(tipped and jan().position.distance_to(cl.DUMPSTER_POS) < cl.DUMPSTER_RANGE, "C3: ...and tipped it into the dumpster (%s)" % str(jan().position.round()))
	# --- C4 trash in hand when a can is full: it goes in the bag
	await _until_idle(60.0)
	cl.set_can(0, cl.can_capacity())
	cl.set_can(1, cl.can_capacity())
	cl.set_can(3, cl.can_capacity())
	cl.set_can(2, cl.can_capacity())
	jan().hand = 2 # (as if just picked up)
	var b2 := await wait_until(func(): return jan().bag_n > 0, 60.0)
	check(b2 and jan().bag_n == cl.can_capacity() + 2 and jan().hand == 0, "C4: every can full, trash in hand -> into the bag with the can's (%d)" % jan().bag_n)
	await wait_until(func(): return jan().bag_n == 0, 90.0)
	# (the other three full cans: one at a time, each to the dumpster)
	var all_out := await wait_until(func(): return cl.full_cans() == 0 and jan().bag_n == 0, 300.0)
	check(all_out, "C4: ...then every other full can, one bag at a time (cans %s)" % str(cl.cans))
	# --- C5 what they leave alone: a knocked-over display, stock on the floor
	await _until_idle(30.0)
	var d: Node = main.displays[0].get_node("Display") if not main.displays.is_empty() else null
	if d != null:
		d.toppled = true
	main.spawn_product_at("Dry Goods", Vector2(1440, 380))
	await wait(4.0)
	var obj: Node2D = null
	for o in get_nodes_in_group("carryable"):
		if o.global_position.distance_to(Vector2(1440, 380)) < 40.0:
			obj = o
	check(jan()._job.get("kind", "") == "home", "C5: a toppled display and loose stock aren't theirs — still waiting at home")
	if d != null:
		d.reset_to_home()
	if is_instance_valid(obj):
		obj.queue_free()
	# --- C6 a spill (stage 4's hazard) counts only while spills are on; mopped then
	var sid: int = main.ambience.spawn_spill(Vector2(1500, 900), 40.0)
	if main.ambience.spills_enabled():
		# Litter before a spill, even a farther piece (spills dry on their own).
		var far: int = cl.drop_litter(Vector2(1000, 950))
		await wait(0.8)
		check(jan()._job.get("key", "") == "l%d" % far, "C6: litter first, though the spill's nearer (job %s)" % str(jan()._job.get("key", "-")))
		var gone := await wait_until(func(): return not main.ambience.spills.any(func(x): return x["id"] == sid), 40.0)
		check(gone, "C6: a stage-4 spill (it counts on the rating at this stage) is mopped too")
	else:
		await wait(4.0)
		check(main.ambience.spills.any(func(x): return x["id"] == sid) and jan()._job.get("kind", "") == "home", "C6: spills off at this stage (not on the rating): left alone")
		main.ambience.remove_spill(sid)
	# --- C7 off the clock at close: trash in hand into a can, waits at home
	cl.set_can(0, 0)
	cl.set_can(1, 0)
	cl.drop_litter(Vector2(1300, 760))
	cl.drop_litter(Vector2(1310, 770))
	await wait_until(func(): return jan().hand == 2, 30.0)
	var binned1: int = cl.trash_binned_today
	main.cleanup_ceiling_override = 60.0 # (a real cleanup phase, not straight to the report)
	main.open_store(1)
	await wait(0.3)
	main.shift_time_left = 0.01
	await wait_until(func(): return main.cleanup_active, 10.0)
	await wait(0.3)
	check(jan().hand == 0 and cl.trash_binned_today == binned1 + 2, "C7: the store closed -> the 2 in hand went into a can")
	cl.drop_litter(Vector2(1400, 760))
	await wait(3.0)
	check(jan()._job.get("kind", "") == "home" and cl.litter.size() >= 1, "C7: cleanup is the crew's: litter left for them, Pat heads home")
	_watch_jan = false
	check(_bad_spots.is_empty(), "C8: never in the Break Room, a locked section, the forklift's floor or a forklift %s" % str(_bad_spots))
	finish()

## =============================================================================
## STUCK
## =============================================================================

func _run_jan_stuck() -> void:
	main.test_hold_customers = true
	main.cleanup_ceiling_override = 0.0
	await wait_until(func(): return main.shift_active, 20.0)
	await wait(0.5)
	var cl: Node = main.cleanup
	main.money = 5000
	check(st().do_action(JK, "hire", 1), "S0: hired the janitor")
	_bad_spots = []
	_watch_janitor()
	await wait(0.5)
	# --- S1 pinned (speed 0): gives up after STUCK_SECONDS, target on cooldown
	var keep_speed: float = jan().speed
	jan().speed = 0.0
	var lid: int = cl.drop_litter(Vector2(1300, 900))
	var t0 := _wall()
	var gave := await wait_until(func(): return jan().stuck_skips == 1, jan().STUCK_SECONDS + 4.0)
	check(gave, "S1: pinned in place -> gave up after %.1fs (STUCK_SECONDS %.0f)" % [_wall() - t0, jan().STUCK_SECONDS])
	check(jan()._skipped("l%d" % lid), "S1: ...and that piece is on its cooldown")
	await wait(1.0)
	check(jan()._job.get("key", "") != "l%d" % lid, "S1: it isn't chosen again straight away (job %s)" % str(jan()._job.get("key", jan()._job.get("kind", "-"))))
	# --- S2 free again: it's picked up once the cooldown runs out
	jan().speed = keep_speed
	var got := await wait_until(func(): return not cl.litter.any(func(x): return x["id"] == lid), jan().TARGET_COOLDOWN + 30.0)
	check(got, "S2: back on its feet -> the piece is picked up after the cooldown (%.0fs)" % (_wall() - t0))
	await _until_idle(30.0)
	# --- S3 never a target: a locked section's floor, the Break Room
	var locked: Array = main.SECTIONS.filter(func(sc): return main.section_index(sc["name"]) >= main.sections_owned)
	var ids := []
	if not locked.is_empty():
		var cell: Vector2i = locked[0]["grid_pos"]
		ids.append(cl.drop_litter(Vector2((cell.x + 0.5) * main.ROOM_WIDTH, (cell.y + 0.5) * main.ROOM_HEIGHT)))
	ids.append(cl.drop_litter(Vector2(480, 270))) # Break Room
	var touched := false
	for k in 300:
		await physics_frame
		for id in ids:
			if jan()._job.get("key", "") == "l%d" % id:
				touched = true
	check(not touched and jan()._job.get("kind", "") == "home", "S3: litter in %s and the Break Room is never a target — waiting at home" % (locked[0]["name"] if not locked.is_empty() else "(no locked section)"))
	for id in ids:
		cl.litter = cl.litter.filter(func(x): return x["id"] != id)
	# --- S4 a target the grid can't reach (the middle of the forklift's floor) is skipped at once
	var u0: int = jan().unreachable_skips
	var pid: int = cl.drop_puddle(Vector2(2500, 1320))
	var skipped := await wait_until(func(): return jan().unreachable_skips > u0, 5.0)
	check(skipped and jan()._skipped("u%d" % pid), "S4: a puddle on the delivery forklift's floor -> skipped as unreachable (not walked into)")
	cl.remove_puddle(pid)
	await _until_idle(30.0)
	# --- S5 the Produce forklift patrolling, litter in its aisle: give way, never in it
	main.open_store(1)
	fk()._pause_timer = 0.0
	await wait(1.0)
	var y0: float = jan().forklift_yield_s
	var cleaned := 0
	var dropped := 0
	t0 = _wall()
	while _wall() - t0 < 70.0:
		if cl.litter.size() < 2 and fk().visible and fk().active:
			var at: Vector2 = fk().global_position + Vector2.RIGHT.rotated(fk().rotation) * randf_range(120.0, 220.0)
			if main._grid_cell_of(at) == Vector2i(2, 1) and cl._litter_spot_ok(at):
				cl.drop_litter(at)
				dropped += 1
		await wait(1.0)
	cleaned = jan().litter_picked_today
	check(fk().active and dropped >= 4, "S5: the forklift patrolled with %d pieces dropped in its path" % dropped)
	check(cleaned >= dropped - 2, "S5: the janitor got to them anyway (%d picked of %d)" % [cleaned, dropped])
	check(jan().forklift_yield_s > y0, "S5: ...giving way to the forklift (%.1fs yielding)" % (jan().forklift_yield_s - y0))
	_watch_jan = false
	check(_bad_spots.is_empty(), "S6: never inside a forklift, the Break Room, a locked section or the forklift's floor %s" % str(_bad_spots))
	finish()

## =============================================================================
## SAVE
## =============================================================================

const V5_SAVE := {
	"version": 5, "saved_at": "2026-10-05T20:00:00",
	"shop": {"completed_day": 8, "money": 2000, "lifetime_earned": 3100, "sections_owned": 2, "stage": 2, "lifetime_sold": 400},
	"staff": {"Produce": {"speed": 1, "carry": 0}},
	"upkeep": {"rating": 3.4, "cans": [2, 0, 5, 0, 0]},
	"gear": {}, "events": {"seen": ["rush"], "completed": 1},
}

func _prepare_jan_save() -> void:
	var path := _save_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if _phase() == 1 or _phase() == 3:
		for f in [path, path + ".tmp", path + ".bad", path + ".v1.bak"]:
			if FileAccess.file_exists(f):
				DirAccess.remove_absolute(f)
		var data: Dictionary = V5_SAVE.duplicate(true)
		if _phase() == 3:
			# A v6 file edited by hand: a janitor in a ONE-section shop.
			data["version"] = 6
			data["shop"]["sections_owned"] = 1
			data["staff"] = {"Janitor": {"speed": 1}}
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(JSON.stringify(data, "\t"))
		f.close()

func _run_jan_save() -> void:
	var path := _save_path()
	await wait_until(func(): return main.shift_active, 20.0)
	await wait(0.5)
	var SG = load("res://SaveGame.gd")
	match _phase():
		1:
			check(main.load_status == SG.LOAD_OK and main.current_day == 9 and main.money == 2000 and main.sections_owned == 2, "JS1: a Phase-4 (version 5) save loads — Day %d, bank %s, %d sections" % [main.current_day, main._format_money(main.money), main.sections_owned])
			check(not st().is_hired(JK) and not jan().active, "JS1: ...with no janitor")
			check(st().is_hired("Produce") and st().speed_level("Produce") == 1 and helper("Produce").active, "JS1: ...and its Produce helper intact, trained")
			check(st().do_action(JK, "hire", 1) and st().do_action(JK, "speed", 1), "JS1: hired Pat and trained them (speed 2)")
			var disk := _read_json(path)
			check(int(disk.get("version", 0)) == SG.VERSION and SG.VERSION == 6, "JS1: the save on disk is version %d" % int(disk.get("version", 0)))
			var ds: Dictionary = disk.get("staff", {})
			check(ds.size() == 2 and int(ds.get(JK, {}).get("speed", -1)) == 1 and int(ds.get("Produce", {}).get("speed", -1)) == 1, "JS1: ...with the janitor beside the helper (%s)" % str(ds))
			check(int(disk.get("shop", {}).get("money", 0)) == main.money and main.money == 2000 - st().JANITOR_HIRE_FEE - st().JANITOR_SPEED_COSTS[0], "JS1: and the bank after paying (%s)" % main._format_money(main.money))
		2:
			check(main.load_status == SG.LOAD_OK, "JS2: relaunch loads the version-6 save")
			check(st().is_hired(JK) and st().speed_level(JK) == 1 and st().is_hired("Produce"), "JS2: Pat (speed 2) and Sam still on staff (%s)" % str(st().staff))
			check(jan().active and jan().visible and jan().speed == st().JANITOR_SPEED_BY_LEVEL[1], "JS2: Pat's on the floor at %d px/s" % int(jan().speed))
			check(st().on_books.has(JK) and st().wages_due() == st().JANITOR_WAGE + st().WAGE["Produce"], "JS2: on this shift's books ($%d due)" % st().wages_due())
			# A bag in hand when the store closes goes back in its can, before
			# the clock-out save (Staff.on_store_close(), from start_cleanup()).
			jan().bag_n = 11
			jan()._bag_can = 2
			main.cleanup.set_can(2, 0)
			st().on_store_close()
			check(main.cleanup.cans[2] == 11 and jan().bag_n == 0, "JS2: the store closing puts a held bag back in its can (can 2: %d)" % main.cleanup.cans[2])
		3:
			check(main.load_status == SG.LOAD_OK and main.sections_owned == 1, "JS3: a hand-edited v6 save still loads (1 section)")
			check(not st().is_hired(JK) and not jan().active, "JS3: a janitor in a one-section shop is dropped (%s)" % str(st().staff))
			var t := path.get_base_dir() + "/edited.json"
			var cases := [
				[{"version": 6, "shop": {"sections_owned": 3}, "staff": {"Janitor": {"speed": 99}}}, func(d): return d["staff"].get("Janitor", {}).get("speed", -1) == st().JANITOR_SPEED_BY_LEVEL.size() - 1, "a level past the top is clamped"],
				[{"version": 6, "shop": {"sections_owned": 3}, "staff": {"Janitor": "junk"}}, func(d): return not d["staff"].has("Janitor"), "a junk entry is dropped"],
				[{"version": 6, "shop": {"sections_owned": 2}, "staff": {"Janitor": {}}}, func(d): return d["staff"].get("Janitor", {}).get("speed", -1) == 0, "an empty entry is a fresh hire"],
			]
			for c in cases:
				var f := FileAccess.open(t, FileAccess.WRITE)
				f.store_string(JSON.stringify(c[0]))
				f.close()
				var r: Array = SG.read(t)
				check(r[0] == SG.LOAD_OK and c[1].call(r[1]), "JS3: %s (%s)" % [c[2], str(r[1].get("staff", {}))])
			var f2 := FileAccess.open(t, FileAccess.WRITE)
			f2.store_string(JSON.stringify({"version": 7, "shop": {}}))
			f2.close()
			check(SG.read(t)[0] == SG.LOAD_CORRUPT, "JS3: a save from a newer version (7) isn't loaded")
	finish()

## Diagnostic (not in the regression): a trip from Bakery to Produce with the
## Produce forklift running, the janitor and the forklift logged 4x a second.
func _run_jan_probe() -> void:
	main.test_hold_customers = true
	await wait_until(func(): return main.shift_active, 20.0)
	main.money = 5000
	st().do_action(JK, "hire", 1)
	main.open_store(1)
	fk()._pause_timer = 0.0
	for r in 3:
		jan().position = Vector2(2300, 250)
		jan().target_position = jan().position
		jan()._reset_brain()
		var pid: int = main.cleanup.drop_puddle(Vector2(2439, 775))
		for k in 160:
			await wait(0.25)
			var f := fk()
			print("PROBE r%d t=%.2f jan=%s job=%s path=%s | fk=%s rot=%.2f v=%.0f alert=%s moving=%s | live=%s flee=%s" % [r, k * 0.25, str(jan().position.round()), jan()._job.get("key", jan()._job.get("kind", "-")), str(jan()._path), str(f.global_position.round()), f.rotation, f.velocity.length(), str(f.alert), str(jan()._forklift_moving(f)), str(jan()._forklift_live() != null), str(jan()._forklift_step(0.0) != Vector2.INF)])
			if not main.cleanup.puddles.any(func(x): return x["id"] == pid):
				print("PROBE r%d done in %.1fs" % [r, k * 0.25])
				break
	finish()

## =============================================================================
## CO-OP
## =============================================================================

func jan_view() -> Dictionary:
	return {"staff": st().staff, "jan": jan().active, "money": main.money}

func _jan_sync(ids: Array, tag: String) -> void:
	await wait(0.5)
	_step("jview", {"tag": tag, "view": JSON.parse_string(JSON.stringify(jan_view()))})
	var ans := await _answers(ids)
	for id in ans:
		check(ans[id].get("ok", false), "%s: %s sees the host's staff and janitor%s" % [tag, main.player_display_name(id), ans[id].get("why", " (no answer)")])

func _run_jan_net_host() -> void:
	var want := _arg_int("--players=", 3)
	if DirAccess.dir_exists_absolute(NET_DIR):
		for f in DirAccess.get_files_at(NET_DIR):
			DirAccess.remove_absolute(NET_DIR + f)
	main.cleanup_ceiling_override = 0.0
	await wait_until(func(): return main.shift_active and main.players.size() >= want, 60.0)
	await wait(1.0)
	main.prep_time_left = 9999.0
	main.shift_time_left = 99999.0
	var ids: Array = main.players.keys()
	ids.sort()
	check(main.players.size() == want and main.money == 3000 and main.sections_owned >= 2 and st().staff.is_empty(), "N0: %d players, bank %s, %d sections, nobody hired" % [main.players.size(), main._format_money(main.money), main.sections_owned])
	_step("hello")
	await _answers(ids)
	await _jan_sync(ids, "N0")
	# N1 the race: both clients, at the board, hire the janitor in one instant
	var m0: int = main.money
	var done0: int = st().actions_done
	var refused0: int = st().actions_refused
	_step("race", {"sec": JK, "action": "hire", "at": Time.get_unix_time_from_system() + 2.0})
	await _answers(ids)
	await wait(1.0)
	check(st().is_hired(JK) and st().actions_done == done0 + 1 and main.money == m0 - st().JANITOR_HIRE_FEE, "N1: two clients hired the janitor in the same instant -> hired ONCE, charged once (bank %s)" % main._format_money(main.money))
	check(st().actions_refused == refused0 + 1, "N1: ...the other request reached the host and was refused (+%d)" % (st().actions_refused - refused0))
	await _jan_sync(ids, "N1")
	# N2 a forged upgrade from across the store is refused
	refused0 = st().actions_refused
	_step("forge", {"who": ids[2]})
	await _answers(ids)
	await wait(0.6)
	check(st().speed_level(JK) == 0 and st().actions_refused == refused0 + 1, "N2: %s asked for the upgrade from across the store -> refused" % main.player_display_name(ids[2]))
	# N3 the upgrade race: one level, paid once
	m0 = main.money
	done0 = st().actions_done
	_step("race", {"sec": JK, "action": "speed", "at": Time.get_unix_time_from_system() + 2.0})
	await _answers(ids)
	await wait(1.0)
	check(st().speed_level(JK) == 1 and main.money == m0 - st().JANITOR_SPEED_COSTS[0] and st().actions_done == done0 + 1, "N3: two clients bought the speed upgrade in one instant -> ONE level, $%d once (bank %s)" % [st().JANITOR_SPEED_COSTS[0], main._format_money(main.money)])
	await _jan_sync(ids, "N3")
	# N4 Pat on every screen, carrying what the host says
	main.cleanup.set_can(0, main.cleanup.can_capacity())
	await wait_until(func(): return jan().bag_n > 0, 30.0)
	_step("jan", {"pos": [jan().position.x, jan().position.y], "bag": jan().bag_n, "hand": jan().hand})
	var ans := await _answers(ids)
	for id in ans:
		check(ans[id].get("ok", false), "N4: %s sees Pat carrying the bag where the host has them%s" % [main.player_display_name(id), ans[id].get("why", "")])
	await wait_until(func(): return jan().bag_n == 0, 90.0)
	main.cleanup.drop_litter(jan().position + Vector2(40, 0))
	await wait_until(func(): return jan().hand > 0, 20.0)
	_step("jan", {"pos": [jan().position.x, jan().position.y], "bag": jan().bag_n, "hand": jan().hand})
	ans = await _answers(ids)
	for id in ans:
		check(ans[id].get("ok", false), "N4: %s sees the litter in Pat's hand%s" % [main.player_display_name(id), ans[id].get("why", "")])
	# N5 payday on every peer
	main.test_hold_customers = true
	main.prep_time_left = 0.0
	await wait_until(func(): return main.store_open, 3.0)
	add_sales(20)
	m0 = main.money
	main.shift_time_left = 0.01
	await wait_until(func(): return main.is_day_report_active(), 200.0)
	await wait(0.5)
	var pay: int = main._pay_today()
	check(main.money == m0 + pay - st().JANITOR_WAGE and st().wages_today == st().JANITOR_WAGE, "N5: payday — pay %s, wage $%d, bank %s" % [main._format_money(pay), st().JANITOR_WAGE, main._format_money(main.money)])
	_step("report", {"pay": main.report_pay_label.text})
	ans = await _answers(ids)
	for id in ans:
		check(ans[id].get("ok", false), "N5: %s's report shows the same pay + wage%s" % [main.player_display_name(id), ans[id].get("why", "")])
	# N6 next shift: a client lets Pat go at the board
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 6.0)
	await wait(0.5)
	main.prep_time_left = 9999.0
	check(st().on_books.has(JK) and jan().active, "N6: next shift — Pat's on the books and on the floor")
	_step("fire", {"who": ids[1]})
	await _answers(ids)
	await wait(0.5)
	check(not st().is_hired(JK) and not jan().active, "N6: %s let Pat go through the host" % main.player_display_name(ids[1]))
	await _jan_sync(ids, "N6")
	_step("done")
	await _answers(ids)
	finish()

func _run_jan_net_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 30.0)
	me = main.multiplayer.get_unique_id()
	act = "client_"
	var n := 0
	while true:
		n += 1
		var step := await _net_read("ec_%d.json" % n, 600.0)
		var kind: String = step.get("kind", "")
		var ans := {}
		match kind:
			"jview":
				var theirs: Dictionary = step["view"]
				var ok := await wait_until(func(): return _canon(jan_view()) == _canon(theirs), 8.0)
				ans = {"ok": ok, "why": "" if ok else " — mine %s vs host %s" % [_canon(jan_view()), _canon(theirs)]}
			"race":
				player().teleport_to(st().BOARD_SPOT + Vector2(0, -25 + 50 * (main.players.keys().find(me) % 2)))
				await wait(0.5)
				var lvl: int = st()._level_of(step["sec"], step["action"])
				while Time.get_unix_time_from_system() < float(step["at"]):
					await physics_frame
				st()._request_staff.rpc_id(1, step["sec"], step["action"], lvl)
				await wait(0.5)
			"forge":
				if int(step["who"]) == me:
					player().teleport_to(Vector2(1440, 700))
					await wait(0.4)
					st()._request_staff.rpc_id(1, JK, "speed", 0)
			"jan":
				var host_pos := Vector2(step["pos"][0], step["pos"][1])
				var ok := await wait_until(func(): return jan().visible and jan().bag_n == int(step["bag"]) and jan().hand == int(step["hand"]) and jan().position.distance_to(host_pos) < 120.0, 4.0)
				var shown: bool = jan()._bag_node.visible == (int(step["bag"]) > 0) and jan()._hand_node.get_child_count() == mini(int(step["hand"]), jan().HAND_MAX)
				ans = {"ok": ok and shown and jan()._tag.text.begins_with("Pat · "), "why": "" if ok and shown else " — visible %s at %s vs host %s, bag %d/%d, hand %d/%d, drawn bag %s hand %d, tag '%s'" % [str(jan().visible), str(jan().position.round()), str(host_pos.round()), jan().bag_n, int(step["bag"]), jan().hand, int(step["hand"]), str(jan()._bag_node.visible), jan()._hand_node.get_child_count(), jan()._tag.text]}
			"report":
				var ok := await wait_until(func(): return main.report_layer.visible and main.report_pay_label.text == step["pay"], 8.0)
				ans = {"ok": ok and main.report_pay_label.text.contains("Pat $"), "why": "" if ok else " — mine '%s' vs '%s'" % [main.report_pay_label.text, step["pay"]]}
			"fire":
				if int(step["who"]) == me:
					player().teleport_to(st().BOARD_SPOT)
					await wait(0.5)
					await tap(act + "interact")
					await wait(0.3)
					await press_button(JK + ":fire")
					await wait_until(func(): return not st().is_hired(JK), 4.0)
					await tap(act + "interact")
			"done":
				_net_write("ec_%d_%d.json" % [n, me], {})
				finish()
				return
		_net_write("ec_%d_%d.json" % [n, me], ans)

## =============================================================================
## EVENTS
## =============================================================================

func _run_jan_events() -> void:
	var ev: Node2D = main.events
	ev.reschedule = false
	main.test_hold_customers = true
	await wait_until(func(): return main.shift_active, 20.0)
	ev._skip_shift = true
	main.ambience._spill_timer = 1.0e9
	for sp in main.ambience.spills.duplicate():
		main.ambience.remove_spill(int(sp["id"]))
	var cl: Node = main.cleanup
	main.money = 5000
	var bar0: float = ev._inspection_bar()
	check(int(ev._plan("leak")["total"]) == ev.LEAK_COUNT, "E0: no janitor -> a solo roof drops LEAK_COUNT (%d)" % ev.LEAK_COUNT)
	check(st().do_action(JK, "hire", 1), "E0: hired the janitor")
	await physics_frame
	check(is_equal_approx(ev._inspection_bar(), snappedf(main.store_rating.mess_per_star() * ev.INSPECTION_PASS_STARS_JANITOR, 0.1)) and ev._inspection_bar() <= bar0, "E0: the inspection bar with a janitor: %.1f (without: %.1f)" % [ev._inspection_bar(), bar0])
	main.open_store(1)
	await wait(1.0)
	# --- E1 Leaky Roof: the janitor goes for the leaks; each takes LEAK_MOP_TIME
	var n0: int = ev.log_today.size()
	ev.force_next("leak", 0.5)
	await wait_until(func(): return ev.active() and ev.key == "leak", 20.0)
	var total0: int = int(ev.data.get("total", -1))
	var mop_frames := 0
	var leak_frames := []
	var was_mopping := false
	var leaks0: int = jan().leaks_mopped_today
	while ev.log_today.size() == n0:
		await physics_frame
		var on_leak: bool = jan().work >= 0.0 and jan()._job.get("what", "") == "leak"
		if on_leak:
			mop_frames += 1
		elif was_mopping:
			leak_frames.append(mop_frames)
			mop_frames = 0
		was_mopping = on_leak
	var entry: Array = ev.log_today[-1]
	var mopped: int = jan().leaks_mopped_today - leaks0
	check(total0 == ev.LEAK_COUNT + ev.LEAK_PER_JANITOR, "E1: with a janitor working, a solo crew's roof drops %d leaks (LEAK_COUNT %d + LEAK_PER_JANITOR %d)" % [total0, ev.LEAK_COUNT, ev.LEAK_PER_JANITOR])
	check(mopped >= 1, "E1: the janitor mopped %d of the %d leaks" % [mopped, int(LeakTotal())])
	var times: Array = leak_frames.map(func(f): return snappedf(f / float(Engine.physics_ticks_per_second), 0.01))
	check(not times.is_empty() and times.all(func(t): return absf(t - jan().LEAK_MOP_TIME) < 0.3 or t < jan().LEAK_MOP_TIME), "E1: ...each one a slow job: %s s of mopping (LEAK_MOP_TIME %.0f)" % [str(times), jan().LEAK_MOP_TIME])
	check(not entry[1], "E1: alone, the janitor doesn't finish a %d-leak roof in time — the crew's mop still decides it (%s)" % [int(LeakTotal()), ev.result_text])
	# --- E2 the event's own count: a leak the janitor mops counts like anyone's
	await wait(4.0)
	for pd in cl.puddles.duplicate():
		cl.remove_puddle(int(pd["id"]))
	await _until_idle(30.0)
	n0 = ev.log_today.size()
	ev.force_next("leak", 0.5)
	await wait_until(func(): return ev.active() and ev.key == "leak" and not ev.data["leaks"].is_empty(), 20.0)
	var first: int = int(ev.data["leaks"][0])
	await wait_until(func(): return not cl.puddles.any(func(x): return int(x["id"]) == first), 40.0)
	await physics_frame
	await physics_frame
	check(int(ev.data.get("mopped", 0)) >= 1, "E2: the janitor's mopped leak counts on the event (mopped %d)" % int(ev.data.get("mopped", 0)))
	# (the crew's mop for the rest: cleared by hand here)
	for id in ev.data.get("leaks", []).duplicate():
		cl.remove_puddle(int(id))
	await wait_until(func(): return ev.log_today.size() > n0 or (int(ev.data.get("to_drop", 1)) == 0 and ev.data.get("leaks", [1]).is_empty()), 30.0)
	while int(ev.data.get("to_drop", 0)) > 0 and ev.active():
		await wait(0.5)
		for id in ev.data.get("leaks", []).duplicate():
			cl.remove_puddle(int(id))
	await wait_until(func(): return ev.log_today.size() > n0, 30.0)
	check(ev.log_today.size() > n0 and ev.log_today[-1][1], "E2: janitor + crew together finish it (%s)" % ev.result_text)
	await wait(4.0)
	# --- E3 Surprise Inspection with a janitor on staff: they walk the
	# inspector round (off the floor), the bar is tighter, the crew cleans
	await _until_idle(30.0)
	for i in 8:
		cl.drop_litter(Vector2(1150 + i * 60, 900 + (i % 3) * 20))
	n0 = ev.log_today.size()
	ev.force_next("inspection", 0.5)
	await wait_until(func(): return ev.busy() and ev.key == "inspection", 20.0)
	await wait(0.5)
	check(ev.data.get("escort", false) and ev.janitor_escorting(), "E3: the inspection knows the janitor's on staff (escort)")
	check(is_equal_approx(float(ev.data["pass_at"]), snappedf(main.store_rating.mess_per_star() * ev.INSPECTION_PASS_STARS_JANITOR, 0.1)), "E3: the bar with a janitor: %.1f (INSPECTION_PASS_STARS_JANITOR %.2f)" % [float(ev.data["pass_at"]), ev.INSPECTION_PASS_STARS_JANITOR])
	check(ev._how_text().begins_with("Pat is showing the inspector round"), "E3: the banner says so: '%s'" % ev._how_text())
	var picked0: int = jan().litter_picked_today
	var litter0: int = cl.litter.size()
	await wait_until(func(): return ev.active(), 15.0)
	await wait(6.0)
	check(jan().status == "with the inspector" and jan().litter_picked_today == picked0 and cl.litter.size() >= litter0, "E3: Pat stopped cleaning to walk the inspector round ('%s', %d picked, litter %d)" % [jan().status, jan().litter_picked_today - picked0, cl.litter.size()])
	await process_frame
	check(jan()._tag.text == "Pat · with the inspector", "E3: their tag says where they are: '%s'" % jan()._tag.text)
	# The crew cleans it up (by hand here) — and passes.
	cl.litter = []
	for pd in cl.puddles.duplicate():
		cl.remove_puddle(int(pd["id"]))
	await wait_until(func(): return ev.log_today.size() > n0, 60.0)
	check(ev.log_today.size() > n0 and ev.log_today[-1][1], "E3: the crew got it under the bar -> passed (%s)" % ev.result_text)
	await wait(1.0)
	check(jan().status != "with the inspector", "E3: the inspector's gone: Pat's back to work")
	cl.drop_litter(jan().position + Vector2(60, 0))
	var back := await wait_until(func(): return jan().litter_picked_today > picked0, 20.0)
	check(back, "E3: ...and picking up litter again")
	finish()

func LeakTotal() -> int:
	return main.events.LEAK_COUNT + main.events.LEAK_PER_EXTRA * (main.events.crew() - 1) + main.events.LEAK_PER_JANITOR
