extends SceneTree
## WEEK 23 — the break room's COFFEE MACHINE (BreakRoom.gd), tested for real:
## real E presses at the real machine, real walking speed measured off real
## movement, the real end-of-shift payout (story Pay, endless Bucks).
##
##   Solo (Day 6 -> Day 7 -> WEEK COMPLETE -> hub -> two endless shifts):
##     godot --headless --path . --script res://tools/coffee_test.gd -- --server --day=6 --prep-seconds=900 --test=coffee
##   Co-op, 2-4 players (Day 7 -> WEEK COMPLETE -> hub -> an endless shift);
##   every peer checks its own view against the host's:
##     godot --headless --path . --script res://tools/coffee_test.gd -- --server --day=7 --prep-seconds=900 --players=3 --test=net-coffee &
##     (x2) godot --headless --path . --script res://tools/coffee_test.gd -- --client --test=net-coffee
##   --port=N / --connect-port=N and SW_NET_DIR=user://some_dir/ (every process
##   of one run) let several runs go at once.
##
## Sales are injected on the host (a cashier's replicated total_sold) so the
## payout math is checked against real non-zero pay without playing a whole
## day; everything coffee touches — the purchase, the speed, the deduction,
## the report — runs through the game's own code paths.

var main: Node
var fails := 0
var me := 1
var act := "host_"
var NET_DIR: String = OS.get_environment("SW_NET_DIR") if OS.get_environment("SW_NET_DIR") != "" else "user://net_coffee/"

func _initialize() -> void:
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	main.cleanup_ceiling_override = 0.0 # the report the moment the clock runs out (C4 turns cleanup back on)
	var mode := "coffee"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--test="):
			mode = a.substr(7)
	match mode:
		"coffee":
			_run_solo.call_deferred()
		"net-coffee":
			if "--client" in OS.get_cmdline_user_args():
				_run_client.call_deferred()
			else:
				_run_host.call_deferred()

## --- Plumbing ---------------------------------------------------------------

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

func br() -> Node:
	return main.break_room

func en() -> Node:
	return main.endless

func player() -> Node2D:
	return main.players[me]

func tap(action: String) -> void:
	Input.action_press(action)
	await physics_frame
	await physics_frame
	Input.action_release(action)

func _arg_int(prefix: String, fallback: int) -> int:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return int(a.substr(prefix.length()))
	return fallback

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

func _canon(v) -> String:
	return JSON.stringify(JSON.parse_string(JSON.stringify(v)), "", true)

## Where player slot `i` stands to use the machine (all inside its 70px reach,
## spaced so four bodies fit side by side).
func machine_spot(i: int) -> Vector2:
	return Vector2(130.0 + 30.0 * i, 105.0)

## Walk right across open break-room floor for `frames` physics frames and
## return the real speed (px/s) the body moved at. Owner only.
func measure_speed(frames := 30) -> float:
	var p := player()
	p.teleport_to(Vector2(420.0, 250.0) if me == 1 else Vector2(420.0, 290.0 + 40.0 * (main.players.keys().find(me) % 4)))
	await physics_frame
	await physics_frame
	Input.action_press(act + "move_right")
	for i in 4: # get up to speed (velocity is set, not accelerated, but be safe)
		await physics_frame
	var x0: float = p.global_position.x
	for i in frames:
		await physics_frame
	var dx: float = p.global_position.x - x0
	Input.action_release(act + "move_right")
	await physics_frame
	return dx / (frames / float(Engine.physics_ticks_per_second))

## Inject `n` sales on the host (cashier total_sold is replicated).
func add_sales(n: int) -> void:
	var c: Node = main.cashiers[0].get_node("Cashier")
	c.total_sold += n

## Everything coffee replicates or derives, as this peer sees it.
func coffee_view() -> Dictionary:
	var peers: Array = br().coffee_peers.keys().map(func(k): return int(k))
	peers.sort()
	var icons := {}
	for id in main.players:
		icons[str(id)] = main.players[id]._coffee_cup.visible
	return {"peers": peers, "today": br().coffee_cups_today, "week": br().coffee_cups_week, "icons": icons, "day": main.current_day, "shift": en().shift_number}

## The pay a story day should show: the game's own components, minus coffee
## computed HERE from the cup count (so a wrong deduction can't hide).
func expected_story_pay() -> int:
	return main._gross_pay_today() + main.cleanup.clean_bonus_today - main.writeups_today * main.WRITEUP_PENALTY - br().coffee_cups_today * br().COFFEE_COST_DOLLARS

## End the running shift (no cleanup) and wait for the report.
func end_shift_now() -> void:
	main.shift_time_left = 0.05
	await wait_until(func(): return main.is_day_report_active() and not main.shift_active, 10.0)
	await wait(0.3)

## =============================================================================
## SOLO
## =============================================================================

func _run_solo() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 20.0)
	await wait(0.3)
	var p := player()
	var S: float = p.SPEED
	check(main.current_day == 6 and not main.store_open, "C0: Day 6, prep phase, store closed")
	# --- C1: nothing yet.
	check(br().coffee_peers.is_empty() and br().coffee_cups_today == 0 and not p._coffee_cup.visible, "C1: no coffee at the start of the shift")
	var v0 := await measure_speed()
	check(absf(v0 - S) < S * 0.03, "C1: walks at %.0f px/s = SPEED %.0f (no coffee, no sneakers)" % [v0, S])
	# --- C2: E away from the machine buys nothing; a request from far away is refused.
	p.teleport_to(Vector2(480, 300))
	await wait(0.2)
	await tap("host_interact")
	await wait(0.2)
	check(br().coffee_cups_today == 0, "C2: E in the middle of the room buys nothing")
	check(not br().near_coffee(Vector2(480, 300)) and br().near_coffee(machine_spot(0)) and br().near_coffee(machine_spot(3)), "C2: the machine's reach covers every machine spot, not the room's middle")
	# --- C3: the vending machine is flavor only.
	p.teleport_to(br().VENDING_POS + Vector2(0, 60))
	await wait(0.2)
	var hint: Label = br()._vending_hint
	check(hint.visible and hint.text == "E: vending machine", "C3: vending prompt shows near it ('%s')" % hint.text)
	await tap("host_interact")
	await wait(0.1)
	check(hint.visible and hint.text in br().VENDING_LINES and br().coffee_cups_today == 0 and main._pay_today() == expected_story_pay(), "C3: E at the vending machine -> a joke line ('%s'), no state, no pay change" % hint.text)
	# --- C4: E holding a product at the machine doesn't buy (E drops it).
	# (Picked up out in the hub: a loose product in the break room is
	# rescued back to a section at once — Main._rescue_stranded_products().)
	p.teleport_to(Vector2(1440, 700))
	await wait(0.3)
	main.spawn_product_at("Dry Goods", p.global_position + Vector2(0, 30))
	await wait(0.4)
	var prod: Node2D = null
	for o in get_nodes_in_group("carryable"):
		if o.global_position.distance_to(p.global_position) < 60.0 and o.get_node("Carryable").carrier_id == 0:
			prod = o
	if prod:
		prod.get_node("Carryable").try_pickup(1, p.global_position)
		await wait(0.2)
		p.teleport_to(machine_spot(1))
		await wait(0.3)
		await tap("host_interact")
		await wait(0.2)
		check(br().coffee_cups_today == 0 and prod.get_node("Carryable").carrier_id == 0, "C4: holding a product, E at the machine puts it down and buys nothing")
		prod.queue_free()
	else:
		check(false, "C4: couldn't spawn a product to hold")
	# --- C5: the real purchase.
	var cb: Label = br()._coffee_hint
	await wait(0.2)
	check(cb.visible and cb.text.begins_with("E: coffee"), "C5: coffee prompt near the machine ('%s')" % cb.text)
	await tap("host_interact")
	await wait(0.2)
	check(br().has_coffee(1) and br().coffee_cups_today == 1 and br().coffee_cups_week == 1 and br().cups_poured == 1, "C5: E at the machine -> one cup (today %d, week %d)" % [br().coffee_cups_today, br().coffee_cups_week])
	check(p._coffee_cup.visible and cb.text.begins_with("Already had"), "C5: cup icon over the player, prompt now '%s'" % cb.text)
	var v1 := await measure_speed()
	check(absf(v1 - S * 1.2) < S * 0.03 and is_equal_approx(p.speed(), S * 1.2), "C5: walks at %.0f px/s = SPEED x 1.20 (%.0f)" % [v1, S * 1.2])
	# --- C6: a second cup the same shift is refused.
	p.teleport_to(machine_spot(1))
	await wait(0.2)
	await tap("host_interact")
	await wait(0.2)
	check(not br().buy_coffee(1), "C6: buy_coffee() for someone who's had one returns false")
	check(br().coffee_cups_today == 1 and br().cups_poured == 1, "C6: still one cup after pressing again (refused %d)" % br().cups_refused)
	# --- C7: the deduction at payday (Day 6 report), with real pay.
	add_sales(23)
	await wait(0.3)
	var gross: int = main._gross_pay_today()
	check(gross == 230, "C7: 23 sales -> gross $%d" % gross)
	check(main._pay_today() == gross - 40 and main._pay_today() == expected_story_pay(), "C7: Pay Today mid-shift %s = $230 - $40 coffee" % main._format_money(main._pay_today()))
	# Turn cleanup on for this one close so C8 can try a cup during it.
	main.cleanup_ceiling_override = 30.0
	main.shift_time_left = 0.05
	await wait_until(func(): return main.cleanup_active, 5.0)
	# --- C8: no coffee during cleanup (for anyone — even a first cup).
	br().coffee_peers = {} # pretend the cup wasn't had, to test the phase gate alone
	var refused0: int = br().cups_refused
	check(not br().coffee_open() and not br().buy_coffee(1), "C8: cleanup phase: the machine is closed")
	br().coffee_peers = {1: true}
	check(br().coffee_cups_today == 1 and br().cups_refused == refused0 + 1, "C8: still one cup after a cleanup-phase try")
	main.clock_out(1)
	await wait_until(func(): return main.is_day_report_active(), 5.0)
	await wait(0.3)
	main.cleanup_ceiling_override = 0.0
	var pay6: int = main._pay_today()
	check(pay6 == expected_story_pay() and pay6 == gross + main.cleanup.clean_bonus_today - 40, "C9: Day 6 Pay Today %s = gross $%d + clean $%d - coffee $40" % [main._format_money(pay6), gross, main.cleanup.clean_bonus_today])
	var lbl: String = main.report_pay_label.text
	check(lbl.begins_with("Pay Today: %s" % main._format_money(pay6)) and lbl.contains("coffee: 1 cup(s), $40 off") and lbl.contains("Host"), "C9: report: '%s'" % lbl.replace("\n", " | "))
	var week6: int = main._pay_week()
	check(week6 == main._total_sold() * main.PAY_PER_SALE + main.cleanup.clean_bonus_week - main.writeups_week * main.WRITEUP_PENALTY + main._priority_bonus(main.priority_sales_week) - 40, "C9: the week's pay carries the $40 too (%s)" % main._format_money(week6))
	# --- C10: next day: a fresh pot.
	main.continue_button.pressed.emit()
	await wait_until(func(): return main.shift_active and main.current_day == 7, 10.0)
	await wait(0.3)
	check(br().coffee_peers.is_empty() and br().coffee_cups_today == 0 and br().coffee_cups_week == 1 and not p._coffee_cup.visible, "C10: Day 7: nobody's had a cup (today 0), week tab still 1")
	var v2 := await measure_speed()
	check(absf(v2 - S) < S * 0.03, "C10: back to %.0f px/s (no coffee today)" % v2)
	add_sales(10)
	await end_shift_now()
	check(main._pay_today() == expected_story_pay() and main._pay_today() == main._gross_pay_today() + main.cleanup.clean_bonus_today - main.writeups_today * main.WRITEUP_PENALTY, "C10: Day 7 pay %s — no coffee, no deduction" % main._format_money(main._pay_today()))
	check(not main.report_pay_label.text.contains("coffee"), "C10: no coffee line on the report ('%s')" % main.report_pay_label.text)
	# --- C11: the week ends: its tab closes.
	main.continue_button.pressed.emit()
	await wait_until(func(): return en().screen == en().SCREEN_WEEK_COMPLETE, 5.0)
	check(br().coffee_cups_week == 0, "C11: WEEK COMPLETE: the week's coffee tab resets")
	await wait_until(func(): return main.hub_ui.enter_button != null, 5.0)
	main.hub_ui.enter_button.pressed.emit()
	await wait_until(func(): return en().screen == en().SCREEN_HUB, 5.0)
	await wait_until(func(): return main.hub_ui.buy_buttons.has("shoes"), 5.0)
	await wait(0.2)
	# --- E1: sneakers + coffee stack ADDITIVELY.
	main.hub_ui.buy_buttons["shoes"].pressed.emit()
	await wait(0.1)
	check(en().upgrade_level("shoes") == 1, "E1: bought Comfy Sneakers 1 (wallet %d)" % en().wallet)
	main.hub_ui.offer_buttons[0].pressed.emit()
	await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 5.0)
	await wait(0.3)
	check(br().coffee_cups_today == 0 and not br().has_coffee(1), "E1: endless shift #1 starts with a fresh pot")
	var v3 := await measure_speed()
	check(absf(v3 - S * 1.08) < S * 0.03, "E1: sneakers alone: %.0f px/s = SPEED x 1.08" % v3)
	p.teleport_to(machine_spot(0))
	await wait(0.2)
	var cbt: String = br()._coffee_hint.text
	check(cbt.contains("-5 Bucks"), "E1: the endless prompt names the Bucks cost ('%s')" % cbt)
	await tap("host_interact")
	await wait(0.2)
	var v4 := await measure_speed()
	check(br().has_coffee(1) and absf(v4 - S * 1.28) < S * 0.03 and is_equal_approx(p.speed(), S * 1.28), "E1: sneakers + coffee: %.0f px/s = SPEED x (1 + 0.08 + 0.20) = %.0f (additive)" % [v4, S * 1.28])
	# --- E2: a shift that earns nothing can't go negative: coffee is capped.
	var w0: int = en().wallet
	var pay_before: int = main._pay_today()
	await end_shift_now()
	var lp: Dictionary = en().last_payout
	check(main._pay_today() == pay_before and main._pay_today() == main._gross_pay_today() + main.cleanup.clean_bonus_today - main.writeups_today * main.WRITEUP_PENALTY, "E2: endless Pay (the medal score) %s untouched by coffee" % main._format_money(main._pay_today()))
	check(int(lp["coffee_cups"]) == 1 and int(lp["total"]) >= 0 and int(lp["total"]) == int(lp["earned"]) + int(lp["coffee"]) and int(lp["coffee"]) == -mini(int(lp["earned"]), 5) and en().wallet == w0 + int(lp["total"]), "E2: payout earned %d, coffee %d -> +%d Bucks, never negative (wallet %d -> %d)" % [lp["earned"], lp["coffee"], lp["total"], w0, en().wallet])
	# --- E3: a real shift: the full 5 Bucks come off.
	main.continue_button.pressed.emit()
	await wait_until(func(): return en().screen == en().SCREEN_HUB, 5.0)
	await wait_until(func(): return main.hub_ui.offer_buttons.size() == 3 and is_instance_valid(main.hub_ui.offer_buttons[1]) and not main.hub_ui.offer_buttons[1].is_queued_for_deletion(), 5.0)
	await wait(0.2)
	main.hub_ui.offer_buttons[1].pressed.emit()
	await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 5.0)
	await wait(0.3)
	check(not br().has_coffee(1) and br().coffee_cups_today == 0, "E3: shift #2: fresh pot again")
	p.teleport_to(machine_spot(2))
	await wait(0.2)
	await tap("host_interact")
	await wait(0.2)
	add_sales(40)
	w0 = en().wallet
	await end_shift_now()
	lp = en().last_payout
	var sold: int = main._total_sold() - main._sold_at_day_start
	var clean: float = 0.5 * main.cleanup.mop_fraction() + 0.5 * main.cleanup.litter_fraction()
	var plain: Dictionary = en().compute_payout(en().contract, sold, main.orders_filled_today, clean, main.writeups_today, main._pay_today())
	check(int(plain["total"]) >= 5 and int(lp["earned"]) == int(plain["total"]) and int(lp["coffee"]) == -5 and int(lp["total"]) == int(plain["total"]) - 5 and en().wallet == w0 + int(plain["total"]) - 5, "E3: %d sold -> %d Bucks without coffee, %d with (−5) — wallet %d -> %d" % [sold, plain["total"], lp["total"], w0, en().wallet])
	check(int(lp["medal"]) == int(plain["medal"]) and int(lp["score"]) == int(plain["score"]), "E3: medal and score identical with or without coffee (%s, $%d)" % [en().medal_text(int(lp["medal"])), lp["score"]])
	await wait(0.2)
	var bl: String = main.report_bucks_label.text
	check(bl.contains("+%d Break Room Bucks" % int(lp["total"])) and bl.contains("− coffee 5 (1 cup(s): Host)"), "E3: report: '%s'" % bl.replace("\n", " | "))
	# --- E4: per head (pure): a crew of 3, all three cups = one solo cup.
	var c3 := {"targets": [100, 200, 300], "bucks_mult": 1.0, "crew": 3}
	var a: Dictionary = en().compute_payout(c3, 90, 0, 0.0, 0, 250, 0)
	var b: Dictionary = en().compute_payout(c3, 90, 0, 0.0, 0, 250, 3)
	var c: Dictionary = en().compute_payout(c3, 90, 0, 0.0, 0, 250, 1)
	check(int(a["total"]) - int(b["total"]) == 5 and int(a["total"]) - int(c["total"]) == 2, "E4: crew of 3: 3 cups cost %d Bucks, 1 cup %d (per head, like sales)" % [int(a["total"]) - int(b["total"]), int(a["total"]) - int(c["total"])])
	finish()

## =============================================================================
## CO-OP. The host writes numbered steps (co_<n>.json); each client acts and
## answers (co_<n>_<peer>.json).
## =============================================================================

var _seq := 0

func _step(kind: String, data := {}) -> void:
	_seq += 1
	data["kind"] = kind
	_net_write("co_%d.json" % _seq, data)

func _answers(ids: Array, timeout := 40.0) -> Dictionary:
	var out := {}
	for id in ids:
		if id == 1:
			continue
		out[id] = await _net_read("co_%d_%d.json" % [_seq, id], timeout)
	return out

## Every client waits until its coffee view equals the host's (8s max).
func _sync_view(ids: Array, tag: String) -> void:
	await wait(0.4)
	_step("view", {"tag": tag, "view": JSON.parse_string(JSON.stringify(coffee_view()))})
	var ans := await _answers(ids)
	for id in ans:
		check(ans[id].get("ok", false), "%s: %s sees the host's coffee state%s" % [tag, main.player_display_name(id), ans[id].get("why", " (no answer)")])

func _run_host() -> void:
	var want := _arg_int("--players=", 2)
	if DirAccess.dir_exists_absolute(NET_DIR):
		for f in DirAccess.get_files_at(NET_DIR):
			DirAccess.remove_absolute(NET_DIR + f)
	await wait_until(func(): return main.shift_active and main.players.size() >= want, 60.0)
	await wait(1.0)
	var ids: Array = main.players.keys()
	ids.sort()
	var S: float = player().SPEED
	check(main.players.size() == want and main.current_day == 7 and not main.store_open, "N0: %d players, Day 7, prep" % main.players.size())
	_step("hello")
	await _answers(ids)
	await _sync_view(ids, "N1 start")
	# --- N2: a forged request from across the room is refused (the host
	# checks where IT sees the sender).
	var refused0: int = br().cups_refused
	_step("forge", {"who": ids[-1]})
	await _answers(ids)
	await wait(0.5)
	check(br().coffee_cups_today == 0 and br().cups_refused == refused0 + 1, "N2: %s asked for coffee from across the room -> refused (cups %d)" % [main.player_display_name(ids[-1]), br().coffee_cups_today])
	# --- N3: a client walks up and presses E.
	var buyer: int = ids[1]
	_step("buy", {"who": buyer, "spot": 1, "at": 0.0})
	await _answers(ids)
	await wait_until(func(): return br().has_coffee(buyer), 5.0)
	check(br().has_coffee(buyer) and br().coffee_cups_today == 1 and br().coffee_peers.size() == 1, "N3: %s pressed E at the machine -> one cup, theirs only" % main.player_display_name(buyer))
	await _sync_view(ids, "N3 after %s's cup" % main.player_display_name(buyer))
	# --- N4: only the drinker is faster — measured on each peer's own movement.
	_step("speed")
	var host_v := await measure_speed()
	var sp := await _answers(ids)
	check(absf(host_v - S) < S * 0.03, "N4: Host (no cup) walks %.0f px/s = SPEED" % host_v)
	for id in sp:
		var v: float = float(sp[id].get("v", -1.0))
		var want_v: float = S * (1.2 if id == buyer else 1.0)
		check(absf(v - want_v) < S * 0.03, "N4: %s (%s) walks %.0f px/s on their own peer = %.0f" % [main.player_display_name(id), "cup" if id == buyer else "no cup", v, want_v])
	# And as the HOST sees it (the replicated position, lerped).
	_step("walk", {"who": buyer})
	await wait(0.6)
	var bp: Node2D = main.players[buyer]
	var x0: float = bp.global_position.x
	await wait(0.5)
	var seen_v: float = (bp.global_position.x - x0) / 0.5
	await _answers(ids)
	check(absf(seen_v - S * 1.2) < S * 0.12, "N4: on the host, %s's replicated walk is %.0f px/s (~%.0f)" % [main.player_display_name(buyer), seen_v, S * 1.2])
	# --- N5: the rush — everyone at the machine pressing E in the same instant
	# (the buyer too, for a second cup): one cup each, the buyer still one.
	var at := Time.get_unix_time_from_system() + 2.5
	_step("buy", {"who": 0, "at": at})
	player().teleport_to(machine_spot(0))
	while Time.get_unix_time_from_system() < at:
		await process_frame
	await tap("host_interact")
	await _answers(ids)
	await wait(1.0)
	check(br().coffee_cups_today == want and br().coffee_peers.size() == want and br().cups_poured == want, "N5 rush: %d players pressed E at once -> %d cups, one each (poured %d, refused %d)" % [want, br().coffee_cups_today, br().cups_poured, br().cups_refused])
	await _sync_view(ids, "N5 after the rush")
	# --- N6: payday (Day 7's report): the same, exact Pay on every peer.
	add_sales(31)
	await wait(0.5)
	await end_shift_now()
	var pay: int = main._pay_today()
	check(pay == expected_story_pay() and pay == main._gross_pay_today() + main.cleanup.clean_bonus_today - main.writeups_today * main.WRITEUP_PENALTY - want * 40, "N6: Day 7 Pay Today %s = $%d gross + $%d clean - %d write-ups - %d cups x $40" % [main._format_money(pay), main._gross_pay_today(), main.cleanup.clean_bonus_today, main.writeups_today, want])
	_step("report", {"pay": pay, "week": main._pay_week(), "label": main.report_pay_label.text})
	var rep := await _answers(ids)
	for id in rep:
		check(rep[id].get("ok", false), "N6: %s's report matches: '%s'%s" % [main.player_display_name(id), str(rep[id].get("label", "")).replace("\n", " | "), rep[id].get("why", "")])
	# --- N7: WEEK COMPLETE -> hub -> an endless shift (a client clicks through).
	main.continue_button.pressed.emit()
	await wait_until(func(): return en().screen == en().SCREEN_WEEK_COMPLETE, 5.0)
	check(br().coffee_cups_week == 0, "N7: week tab closed at WEEK COMPLETE")
	await wait_until(func(): return main.hub_ui.enter_button != null, 5.0)
	main.hub_ui.enter_button.pressed.emit()
	await wait_until(func(): return en().screen == en().SCREEN_HUB, 5.0)
	await wait_until(func(): return main.hub_ui.buy_buttons.has("shoes"), 5.0)
	await wait(0.2)
	main.hub_ui.buy_buttons["shoes"].pressed.emit()
	await wait(0.2)
	_step("take", {"who": ids[-1]})
	await _answers(ids)
	await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 10.0)
	await wait(0.5)
	check(br().coffee_peers.is_empty() and br().coffee_cups_today == 0 and en().upgrade_level("shoes") == 1, "N8: endless shift #%d: fresh pot, sneakers 1" % en().shift_number)
	await _sync_view(ids, "N8 endless start")
	# --- N9: the last client buys a cup here; speeds stack additively.
	var eb: int = ids[-1]
	_step("buy", {"who": eb, "spot": 2, "at": 0.0})
	await _answers(ids)
	await wait_until(func(): return br().has_coffee(eb), 5.0)
	check(br().coffee_cups_today == 1 and br().has_coffee(eb), "N9: %s had a cup on the endless shift" % main.player_display_name(eb))
	await _sync_view(ids, "N9 after the endless cup")
	_step("speed")
	host_v = await measure_speed()
	sp = await _answers(ids)
	check(absf(host_v - S * 1.08) < S * 0.03, "N9: Host: sneakers only, %.0f px/s = SPEED x 1.08" % host_v)
	for id in sp:
		var v: float = float(sp[id].get("v", -1.0))
		var want_v: float = S * (1.28 if id == eb else 1.08)
		check(absf(v - want_v) < S * 0.03, "N9: %s walks %.0f px/s = SPEED x %.2f" % [main.player_display_name(id), v, want_v / S])
	# --- N10: endless payday — Bucks, per head, on every peer.
	add_sales(45)
	var w0: int = en().wallet
	await wait(0.5)
	await end_shift_now()
	await wait(0.5)
	var lp: Dictionary = en().last_payout
	var sold: int = main._total_sold() - main._sold_at_day_start
	var clean: float = 0.5 * main.cleanup.mop_fraction() + 0.5 * main.cleanup.litter_fraction()
	var plain: Dictionary = en().compute_payout(en().contract, sold, main.orders_filled_today, clean, main.writeups_today, main._pay_today())
	var cost: int = mini(int(plain["total"]), int(round(5.0 / want)))
	check(int(lp["earned"]) == int(plain["total"]) and int(lp["coffee"]) == -cost and int(lp["total"]) == int(plain["total"]) - cost and en().wallet == w0 + int(lp["total"]), "N10: crew of %d, 1 cup: %d Bucks earned - %d coffee (5 / %d per head) = +%d (wallet %d -> %d)" % [want, plain["total"], cost, want, lp["total"], w0, en().wallet])
	check(main._pay_today() == main._gross_pay_today() + main.cleanup.clean_bonus_today - main.writeups_today * main.WRITEUP_PENALTY, "N10: endless Pay (score) %s carries no coffee $" % main._format_money(main._pay_today()))
	_step("payout", {"payout": JSON.parse_string(JSON.stringify(lp)), "wallet": en().wallet, "pay": main._pay_today(), "bucks_label": main.report_bucks_label.text})
	rep = await _answers(ids)
	for id in rep:
		check(rep[id].get("ok", false), "N10: %s's payout, wallet and report match the host's%s" % [main.player_display_name(id), rep[id].get("why", "")])
	_step("done")
	await _answers(ids)
	print("NET-COFFEE SUMMARY — %d players, cups poured %d, refused %d, wallet %d" % [want, br().cups_poured, br().cups_refused, en().wallet])
	finish()

func _run_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 30.0)
	me = main.multiplayer.get_unique_id()
	act = "client_"
	var who: String = main.player_display_name(me)
	var n := 0
	while true:
		n += 1
		var step := await _net_read("co_%d.json" % n, 600.0)
		var kind: String = step.get("kind", "")
		var ans := {}
		match kind:
			"hello":
				pass
			"view":
				var theirs: Dictionary = step["view"]
				var ok := await wait_until(func(): return _canon(coffee_view()) == _canon(theirs), 8.0)
				ans = {"ok": ok, "why": "" if ok else " — mine %s vs host %s" % [_canon(coffee_view()), _canon(theirs)]}
				check(ok, "%s: %s matches the host" % [who, step.get("tag", "")])
			"forge":
				if int(step["who"]) == me:
					player().teleport_to(Vector2(480, 330))
					await wait(0.3)
					br()._request_coffee.rpc_id(1) # the RPC the E press sends, from far away
			"buy":
				var target := int(step.get("who", 0))
				if target == me or target == 0:
					var ids: Array = main.players.keys()
					ids.sort()
					var spot: int = int(step["spot"]) if step.has("spot") else ids.find(me)
					player().teleport_to(machine_spot(spot))
					var at: float = float(step.get("at", 0.0))
					await wait(0.3)
					while Time.get_unix_time_from_system() < at:
						await process_frame
					await tap(act + "interact")
					await wait(0.3)
			"speed":
				ans = {"v": await measure_speed()}
			"walk":
				if int(step["who"]) == me:
					player().teleport_to(Vector2(300, 250))
					await wait(0.2)
					Input.action_press(act + "move_right")
					await wait(1.4)
					Input.action_release(act + "move_right")
			"report":
				await wait_until(func(): return main.report_layer.visible and main._pay_today() == int(step["pay"]), 8.0)
				await process_frame
				var mine := {"pay": main._pay_today(), "week": main._pay_week(), "label": main.report_pay_label.text}
				var ok: bool = mine["pay"] == int(step["pay"]) and mine["week"] == int(step["week"]) and mine["label"] == step["label"]
				ans = {"ok": ok, "label": mine["label"], "why": "" if ok else " — mine %s vs host %s" % [str(mine), str(step)]}
				check(ok, "%s: Day 7 report matches the host (%s)" % [who, mine["label"].replace("\n", " | ")])
			"take":
				if int(step["who"]) == me:
					await wait_until(func(): return main.hub_ui.visible and main.hub_ui.offer_buttons.size() > 0, 5.0)
					main.hub_ui.offer_buttons[0].pressed.emit()
			"payout":
				var hp: Dictionary = step["payout"]
				await wait_until(func(): return main.report_layer.visible and _canon(en().last_payout) == _canon(hp), 8.0)
				await process_frame
				var ok: bool = _canon(en().last_payout) == _canon(hp) and en().wallet == int(step["wallet"]) and main._pay_today() == int(step["pay"]) and main.report_bucks_label.text == step["bucks_label"]
				ans = {"ok": ok, "why": "" if ok else " — payout %s wallet %d pay %d label '%s'" % [_canon(en().last_payout), en().wallet, main._pay_today(), main.report_bucks_label.text]}
				check(ok, "%s: endless payout matches the host (+%d Bucks, wallet %d)" % [who, int(en().last_payout.get("total", -1)), en().wallet])
			"done":
				_net_write("co_%d_%d.json" % [n, me], {})
				finish()
				return
			_:
				check(false, "%s: no step %d from the host" % [who, n])
				finish()
				return
		_net_write("co_%d_%d.json" % [n, me], ans)
