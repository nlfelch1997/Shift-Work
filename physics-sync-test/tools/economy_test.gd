extends "res://tools/hazards_test.gd"
## OCT 2026 PIVOT, PHASE 2 — THE SHOPKEEPER ECONOMY (Main.gd's money /
## lifetime_earned / sections_owned / complication_stage, buying a section at
## its gate, the stage ladder, SaveGame.gd v2 + old saves). Reuses
## tools/hazards_test.gd's helpers (walking, key taps, net files), so it drives
## the real Main.tscn through the real game code like every other test here.
## Not part of the game. Real wall-clock time throughout (no --fixed-fps).
##
## PURCHASE FLOW + BANK + LADDER, solo, from a brand-new shop (no --day): pay
## banked at clock-out, a real walk to the Produce gate and a real E press,
## every refusal (broke, out of order, store open, practice), the purchase's
## side effects, one stage per shift, the top tier sustained, negative pay:
##   godot --headless --path . --script res://tools/economy_test.gd -- --server --no-save --test=economy
## STAGE TABLE — every stage's hazard levels and the systems they switch on,
## and every --day=N debug preset against the old day schedule:
##   godot --headless --path . --script res://tools/economy_test.gd -- --server --no-save --test=thresholds
## OLD SAVES — a version-1 (7-day story) save -> kept aside as .v1.bak, a fresh
## shop, the one-time message; the relaunch loads the fresh v2 save quietly;
## a v2 save round-trips the whole economy:
##   godot ... -- --server --save-file=user://econ_test/save.json --test=legacy-save --phase=1   (then 2, 3, 4)
## CO-OP (host + 2 clients): every peer sees the same bank/sections/stage, a
## client's purchase through the host, a forged one refused, two clients
## buying the same gate in the same instant buy it once, payday and the
## stage banner on every peer:
##   godot ... -- --server --port=8971 --players=3 --no-save --money=2000 --test=net-economy &
##   (x2) godot ... -- --client --connect-port=8971 --no-save --test=net-economy
## SOAK — one long continuous session, every section open and the top tier on
## (--day=7), the crew stocking every shelf all shift, N consecutive shifts:
## node counts, object/memory use and frame time per shift, so a session with
## no 7-day ceiling can be checked for drift:
##   godot --headless --path . --script res://tools/economy_test.gd -- --server --day=7 --no-save --shifts=8 --test=soak
## Co-op soak: add --port=N --players=3 on the host and run 2 clients
## (--client --connect-port=N --no-save --test=soak); each client prints its
## own node/memory/frame line every 30s and leaves when the host does.

var _mode := ""

## Standing spots on the open side of each gate (inside GATE_BUY_RANGE).
const BUY_SPOT := {
	"Produce": Vector2(1880, 760),
	"Dairy/Frozen": Vector2(1000, 760),
	"Bakery": Vector2(1880, 270),
}

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--test="):
			_mode = a.substr(7)
	if _mode == "legacy-save":
		_prepare_legacy_phase() # the file has to be there before Main hosts
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	# OCT 2026 PHASE 4: random events (Events.gd) are off here — tools/events_test.gd
	# tests them; --events=on turns them on (the income runs measure both).
	main.events_on = "--events=on" in OS.get_cmdline_user_args()
	careless = true
	main.cleanup_ceiling_override = 5.0 if _mode == "soak" else 0.0
	var client := "--client" in args
	match _mode:
		"economy": _run_economy.call_deferred()
		"thresholds": _run_thresholds.call_deferred()
		"legacy-save": _run_legacy.call_deferred()
		"net-economy": (_run_net_client if client else _run_net_host).call_deferred()
		"soak": (_run_soak_client if client else _run_soak).call_deferred()
		_:
			print("FAIL  unknown --test=%s" % _mode)
			quit(1)

## --- helpers ------------------------------------------------------------------

func gate_open(sec: String) -> bool:
	var g: Node = main.gate_of(sec)
	return g.get_node("CollisionShape2D").disabled and not g.get_node("Locked").visible

func gate_text(sec: String) -> String:
	return main.gate_of(sec).get_node("Locked/Label").text

func add_sales(n: int) -> void:
	main.cashiers[0].get_node("Cashier").total_sold += n

## Runs the clock out and clocks out at once (cleanup ceiling 0); returns the
## day's pay as the report shows it.
func end_day() -> int:
	main.shift_time_left = 0.01
	await wait_until(func(): return main.is_day_report_active(), 6.0)
	await wait(0.3)
	return main._pay_today()

func next_day() -> void:
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 6.0)
	await wait(0.3)

## Stand at a gate and press E for real (the host's own player).
func press_e_at(sec: String) -> void:
	player().teleport_to(BUY_SPOT[sec])
	await physics_frame
	await physics_frame
	await tap(act + "interact")
	await wait(0.3)

func banner_text() -> String:
	return "%s | %s" % [main._finale_banner.get_child(0).text, main._finale_banner.get_child(1).text]

## =============================================================================
## PURCHASE FLOW, BANK, LADDER (solo)
## =============================================================================

func _run_economy() -> void:
	await wait_until(func(): return main.shift_active, 20.0)
	await wait(0.5)
	# --- E1 a brand-new shop
	check(main.current_day == 1 and main.money == main.STARTING_MONEY and main.sections_owned == 1 and main.complication_stage == 0 and main.lifetime_earned == 0, "E1: fresh shop — Day 1, bank $%d, 1 section, stage 0" % main.money)
	check(main._unlocked_sections().map(func(s): return s["name"]) == ["Dry Goods"], "E1: only Dry Goods is open")
	check(not gate_open("Produce") and gate_text("Produce") == "FOR SALE — $%d" % main.section_price("Produce"), "E1: Produce's gate is sealed and says '%s'" % gate_text("Produce"))
	check(gate_text("Bakery").contains("after Dairy/Frozen"), "E1: Bakery's gate says what comes first ('%s')" % gate_text("Bakery"))
	var lv: Dictionary = main.hazard_levels()
	check(lv["forklift"] == 0 and lv["manager"] == 0 and lv["orders"] == 0 and lv["spills"] == 0 and lv["lights"] == 0 and not lv["tight_clock"], "E1: no complications on a fresh shop %s" % str(lv))
	check(main.status_label.text.contains("Bank $0"), "E1: status line shows the bank ('%s')" % main.status_label.text)
	# --- E2 broke: E at the gate is refused, and the prompt says why
	await press_e_at("Produce")
	var hint: Array = main.gate_hint_for(player().global_position)
	check(main.sections_owned == 1 and not gate_open("Produce"), "E2: E at Produce's gate with $0 -> nothing bought")
	check(hint[0] == "Produce" and not hint[2] and str(hint[1]).contains("need $%d more" % main.section_price("Produce")), "E2: the prompt says why ('%s')" % str(hint[1]).replace("\n", " / "))
	check(main._gate_hint.visible and main._gate_hint.text == hint[1], "E2: the prompt is on screen over the gate")
	check(main._toast_label.visible and main._toast_label.text.contains("need $"), "E2: pressing E says why too ('%s')" % main._toast_label.text)
	# --- E3 payday: the day's pay goes into the bank
	# Enough for Produce ($500) but under the manager's $800 lifetime — the
	# same shape as the old Day 1-2 (each day here is a sales injection).
	add_sales(42)
	var pay := await end_day()
	check(pay > 0 and main.money == main.STARTING_MONEY + pay and main.lifetime_earned == pay, "E3: Day 1 paid %s -> bank %s, lifetime $%d" % [main._format_money(pay), main._format_money(main.money), main.lifetime_earned])
	check(main.report_week_label.text.begins_with("Bank: %s" % main._format_money(main.money)) and not main.report_week_label.text.contains("Week"), "E3: report shows the bank, no week ('%s')" % main.report_week_label.text)
	check(main.report_shop_label.visible and main.report_shop_label.text.contains("Coming up: the forklift — when you buy Produce"), "E3: report forecasts the forklift ('%s')" % main.report_shop_label.text.replace("\n", " / "))
	check(main.report_shop_label.text.contains("You can afford Produce ($%d)" % main.section_price("Produce")), "E3: report says Produce is affordable")
	check(not main.report_pay_label.text.contains("Week"), "E3: no Week pay ('%s')" % main.report_pay_label.text)
	await next_day()
	check(main.current_day == 2 and main.complication_stage == 0, "E3: Day 2, still stage 0 (nothing bought, nothing new)")
	# --- E4 a real walk to the gate, a real E press: bought
	var money0: int = main.money
	var prep0: float = main.prep_time_left
	var clock0: float = main.shift_time_left
	var rows0: int = main.shelf_rows
	var walked := await walk_to(BUY_SPOT["Produce"], 12.0, 40.0)
	check(walked, "E4: walked from the break room to Produce's gate (%s)" % str(player().global_position))
	hint = main.gate_hint_for(player().global_position)
	check(hint[2] and str(hint[1]).begins_with("E: buy Produce — $%d" % main.section_price("Produce")), "E4: prompt offers the purchase ('%s')" % str(hint[1]).replace("\n", " / "))
	prep0 = main.prep_time_left
	clock0 = main.shift_time_left
	await tap(act + "interact")
	await wait(0.3)
	check(main.sections_owned == 2 and main.money == money0 - main.section_price("Produce") and main.purchases_made == 1, "E4: Produce bought — bank %s -> %s" % [main._format_money(money0), main._format_money(main.money)])
	check(gate_open("Produce") and main.is_section_open(main.SECTIONS[1]), "E4: Produce's gate is open, the section is in play")
	check(main.prep_time_left >= prep0 + main.PREP_CEILING_PER_SECTION - 1.5 and main.shift_time_left >= clock0 + main.PREP_CEILING_PER_SECTION - 1.5, "E4: prep (%.0f -> %.0f s) and the clock grew by the section's prep time" % [prep0, main.prep_time_left])
	check(main.complication_stage == 0 and not fk().active, "E4: the forklift does NOT start mid-shift (stage %d)" % main.complication_stage)
	check(main.shelf_rows == rows0, "E4: shelf stacking depth unchanged until the next shift")
	check(main._finale_banner.visible and banner_text().contains("PRODUCE IS OPEN") and banner_text().contains("next shift: the forklift"), "E4: purchase notice on screen ('%s')" % banner_text())
	check(main._active_cashier_count() == main.CASHIER_COUNT_BY_TIER[1], "E4: checkout lanes follow the open sections (%d)" % main._active_cashier_count())
	# --- E5 out of order
	main.money = 99999
	await press_e_at("Bakery")
	check(main.sections_owned == 2 and not gate_open("Bakery"), "E5: Bakery before Dairy/Frozen -> refused")
	check(main.purchase_blocker("Bakery") == "buy Dairy/Frozen first", "E5: because '%s'" % main.purchase_blocker("Bakery"))
	# --- E6 store open: no buying
	main.open_store(1)
	await wait(0.3)
	await press_e_at("Dairy/Frozen")
	check(main.sections_owned == 2, "E6: E at Dairy/Frozen's gate with the store open -> refused ('%s')" % main.purchase_blocker("Dairy/Frozen"))
	main.money = money0 - main.section_price("Produce") # put the bank back
	# --- E7 next shift: the forecast, then the forklift arrives with a banner
	add_sales(5)
	pay = await end_day()
	check(main.report_shop_label.text.contains("NEXT SHIFT: THE FORKLIFT"), "E7: report says the forklift starts next shift ('%s')" % main.report_shop_label.text.replace("\n", " / "))
	await next_day()
	check(main.complication_stage == main.STAGE_FORKLIFT and fk().active and main.hazard_levels()["forklift"] == 1, "E7: Day 3 — stage 1, the forklift is on")
	check(main.shelf_rows == main.STACK_ROWS_BY_TIER[1], "E7: shelves took the 2-section stacking depth at shift start")
	check(main._finale_banner.visible and banner_text().begins_with("NEW: THE FORKLIFT"), "E7: start-of-shift banner announces it ('%s')" % banner_text())
	check(not mgr().active, "E7: no manager yet")
	# --- E8 the manager waits for lifetime earnings
	var short: int = main.MANAGER_EARNED - main.lifetime_earned
	check(short > 0, "E8: lifetime $%d is under the manager's $%d" % [main.lifetime_earned, main.MANAGER_EARNED])
	pay = await end_day() # no sales: a tiny day
	check(main.report_shop_label.text.contains("Coming up: the manager — at $%d lifetime earnings" % main.MANAGER_EARNED), "E8: forecast names the money threshold ('%s')" % main.report_shop_label.text.replace("\n", " / "))
	await next_day()
	check(main.complication_stage == main.STAGE_FORKLIFT and not mgr().active, "E8: under the threshold -> still stage 1, no manager")
	add_sales(int(ceil((main.MANAGER_EARNED - main.lifetime_earned) / 10.0)) + 1)
	pay = await end_day()
	check(main.lifetime_earned >= main.MANAGER_EARNED and main.report_shop_label.text.contains("NEXT SHIFT: THE MANAGER"), "E8: past $%d -> 'NEXT SHIFT: THE MANAGER'" % main.MANAGER_EARNED)
	await next_day()
	check(main.complication_stage == main.STAGE_MANAGER and mgr().active and banner_text().begins_with("NEW: THE MANAGER"), "E8: stage 2 — the manager's on, announced")
	# --- E9 one step per shift, even when everything's paid for at once
	main.money = 99999
	main.lifetime_earned = main.RUSH_EARNED + 10
	await press_e_at("Dairy/Frozen")
	check(main._finale_banner.visible and banner_text().begins_with("NEW: THE MANAGER"), "E9: bought during the shift's NEW banner — the banner keeps the band...")
	await wait_until(func(): return banner_text().contains("DAIRY/FROZEN IS OPEN"), main.STAGE_BANNER_SECONDS + 1.0)
	check(banner_text().contains("next shift: priority orders"), "E9: Dairy/Frozen's notice: orders next shift ('%s')" % banner_text())
	await press_e_at("Bakery")
	check(banner_text().contains("it brings rush season, in a shift or two"), "E9: Bakery's notice doesn't promise next shift — two stages are queued ('%s')" % banner_text())
	check(main.sections_owned == 4 and gate_open("Bakery") and gate_open("Dairy/Frozen"), "E9: Dairy/Frozen and Bakery both bought in one prep")
	check(main.complication_stage == main.STAGE_MANAGER and main.hazard_levels()["orders"] == 0, "E9: ...and nothing new starts mid-shift")
	var seen := []
	for i in 4:
		await end_day()
		await next_day()
		seen.append(main.complication_stage)
	check(seen == [3, 4, 5, 5], "E9: one stage per shift: %s (orders, then lights+spills, then the top tier, then it stays)" % str(seen))
	# --- E10 the top tier is sustained, not a one-off
	lv = main.hazard_levels()
	check(main.is_finale() and lv["tight_clock"] and lv["forklift"] == 2 and lv["manager"] == 2 and lv["orders"] == 2 and lv["spills"] == 2 and lv["lights"] == 2, "E10: top tier — every hazard at 2 and the tight clock %s" % str(lv))
	check(fk().finale and mgr().finale and main.ambience.spills_level == 2 and main.ambience.lights_level == 2, "E10: the systems run their top-tier numbers")
	check(not main._finale_banner.visible and main.stage_banner == 0, "E10: a second top-tier shift has no banner (sustained, not an event)")
	check(main._selling_window() == main.shift_duration - main.FINALE_SELLING_CUT, "E10: tight clock (%.0fs selling)" % main._selling_window())
	pay = await end_day()
	check(main.report_shop_label.text.contains("You own the whole store.") and not main.report_shop_label.text.contains("Coming up"), "E10: the report has nothing left to forecast ('%s')" % main.report_shop_label.text.replace("\n", " / "))
	check(main.continue_button.text == "Continue", "E10: no 'Finish the Week' — the game goes on")
	await next_day()
	check(main.current_day > 7 and main.shift_active, "E10: Day %d — past the old Day 7, still going" % main.current_day)
	# --- E11 a bad day can cost money; lifetime earnings never go down
	var m0: int = main.money
	var l0: int = main.lifetime_earned
	main.writeups_today = 5
	pay = await end_day()
	check(pay < 0 and main.money == m0 + pay and main.lifetime_earned == l0, "E11: a %s day -> bank %s -> %s, lifetime unchanged ($%d)" % [main._format_money(pay), main._format_money(m0), main._format_money(main.money), main.lifetime_earned])
	check(main.complication_stage == main.STAGE_RUSH, "E11: spending/losing money never lowers the stage")
	await next_day()
	# --- E12 nothing left for sale
	check(main.purchase_blocker("Produce") == "already yours" and main.next_section_for_sale().is_empty() and main.for_sale_gate_at(BUY_SPOT["Bakery"]) == "", "E12: owned sections aren't for sale, no prompt at their gates")
	finish()

## =============================================================================
## STAGE TABLE + --day presets
## =============================================================================

## The old Day N schedule (Days 1-7) the presets must reproduce:
## [forklift, manager, orders, spills, lights, tight_clock, open sections].
const OLD_DAY_GATES := {
	1: [0, 0, 0, 0, 0, false, 1],
	2: [0, 0, 0, 0, 0, false, 1],
	3: [1, 0, 0, 0, 0, false, 2],
	4: [1, 1, 0, 0, 0, false, 2],
	5: [1, 1, 1, 0, 0, false, 3],
	6: [1, 1, 1, 1, 1, false, 3],
	7: [2, 2, 2, 2, 2, true, 4],
}

func _levels_row() -> Array:
	var lv: Dictionary = main.hazard_levels()
	return [lv["forklift"], lv["manager"], lv["orders"], lv["spills"], lv["lights"], lv["tight_clock"], main._unlocked_sections().size()]

func _run_thresholds() -> void:
	await wait_until(func(): return main.shift_active, 20.0)
	await wait(0.5)
	# T1 every --day preset == the old day's gates (what every Day-N test relies on)
	for d in OLD_DAY_GATES:
		main._apply_debug_day_preset(d)
		main._advance_complication_stage() # what the first shift's start does
		main._reconfigure_world()
		await physics_frame
		check(_levels_row() == OLD_DAY_GATES[d], "T1: --day=%d preset -> %s (old Day %d: %s)" % [d, str(_levels_row()), d, str(OLD_DAY_GATES[d])])
		check(fk().active == (OLD_DAY_GATES[d][0] > 0) and mgr().active == (OLD_DAY_GATES[d][1] > 0) and (main.ambience.lights_level > 0) == (OLD_DAY_GATES[d][4] > 0), "T1: Day %d preset — systems configured to match (forklift %s, manager %s, lights %d)" % [d, fk().active, mgr().active, main.ambience.lights_level])
	# T2 the ladder's needs, stage by stage (state set directly; the advance
	# itself is the real _advance_complication_stage())
	main.sections_owned = 1
	main.lifetime_earned = 0
	main.complication_stage = 0
	check(main._advance_complication_stage() == 0, "T2: 1 section, $0 -> no stage")
	main.lifetime_earned = main.RUSH_EARNED * 2
	check(main._advance_complication_stage() == 0, "T2: lots of money but no Produce -> no forklift (it needs the section)")
	main.sections_owned = 2
	check(main._advance_complication_stage() == 1, "T2: Produce -> stage 1 forklift")
	check(main._advance_complication_stage() == 2, "T2: next shift, money already there -> stage 2 manager")
	check(main._advance_complication_stage() == 0, "T2: orders wait for Dairy/Frozen")
	main.sections_owned = 3
	check(main._advance_complication_stage() == 3 and main._advance_complication_stage() == 4, "T2: Dairy/Frozen -> 3 orders, then 4 lights+spills")
	check(main._advance_complication_stage() == 0, "T2: top tier waits for Bakery")
	main.sections_owned = 4
	main.lifetime_earned = main.RUSH_EARNED - 1
	check(main._advance_complication_stage() == 0, "T2: Bakery but under $%d lifetime -> not yet" % main.RUSH_EARNED)
	main.lifetime_earned = main.RUSH_EARNED
	check(main._advance_complication_stage() == 5 and main._advance_complication_stage() == 0, "T2: $%d -> stage 5, and that's the top" % main.RUSH_EARNED)
	main.sections_owned = 2
	main.lifetime_earned = 0
	check(main.complication_stage == 5, "T2: the stage never goes back down")
	# T3 the ladder's order is the old days' order, and each stage's needs are
	# reachable by the time the section that follows can be bought
	var st: Array = main.COMPLICATION_STAGES
	check(st.map(func(x): return x["key"]) == ["start", "forklift", "manager", "orders", "environment", "rush"], "T3: ladder order forklift -> manager -> orders -> lights/spills -> top tier")
	var spent := 0
	for i in range(1, main.SECTIONS.size()):
		spent += main.section_price(main.SECTIONS[i]["name"])
	check(main.MANAGER_EARNED <= main.section_price("Produce") + main.section_price("Dairy/Frozen") - main.STARTING_MONEY, "T3: the manager is always on before Dairy/Frozen can be afforded")
	check(main.ENVIRONMENT_EARNED <= spent - main.STARTING_MONEY, "T3: lights+spills are always on before Bakery can be afforded")
	check(main.RUSH_EARNED > spent, "T3: the top tier needs more than the whole store costs ($%d > $%d)" % [main.RUSH_EARNED, spent])
	var prices := [main.section_price("Produce"), main.section_price("Dairy/Frozen"), main.section_price("Bakery")]
	check(prices[0] < prices[1] and prices[1] < prices[2], "T3: prices escalate %s" % str(prices))
	finish()

## =============================================================================
## OLD SAVES
## =============================================================================

## Phase 1: a version-1 (story) save, as Week 24's code wrote it — Day 4 done.
const V1_SAVE := {
	"version": 1, "saved_at": "2026-10-01T20:00:00",
	"story": {"completed_day": 4, "complete": false},
	"week": {"sold": 120, "writeups": 2, "priority_sales": 0, "clean_bonus": 40, "litter_pay": 6, "coffee_cups": 1},
	"endless": {"wallet": 0, "upgrades": {}, "shift_number": 0, "run_stats": {"shifts": 0, "sold": 0, "bucks": 0, "medals": [0, 0, 0, 0]}, "week_summary": {}},
}

func _save_path() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--save-file="):
			return a.substr(12)
	return "user://econ_test/save.json"

func _phase() -> int:
	return _arg_int("--phase=", 1)

func _prepare_legacy_phase() -> void:
	var path := _save_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if _phase() == 1:
		for f in [path, path + ".v1.bak", path + ".tmp", path + ".bad"]:
			if FileAccess.file_exists(f):
				DirAccess.remove_absolute(f)
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(JSON.stringify(V1_SAVE, "\t"))
		f.close()
	elif _phase() == 4:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(JSON.stringify({"version": 99, "shop": {"money": 1}}))
		f.close()

func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var p = JSON.parse_string(FileAccess.get_file_as_string(path))
	return p if p is Dictionary else {}

func _run_legacy() -> void:
	var path := _save_path()
	await wait_until(func(): return main.shift_active, 20.0)
	await wait(0.3)
	var SG = load("res://SaveGame.gd")
	match _phase():
		1:
			check(main.load_status == SG.LOAD_LEGACY, "L1: a version-1 save is recognised as pre-shopkeeper (status %d)" % main.load_status)
			check(main.current_day == 1 and main.money == main.STARTING_MONEY and main.sections_owned == 1 and main.complication_stage == 0 and main.lifetime_earned == 0, "L1: the crew starts fresh — Day 1, bank $%d, 1 section, stage 0 (not 'Day 5')" % main.money)
			check(main._finale_banner.visible and main._finale_banner.get_child(0).text == "NEW GAME" and main._finale_banner.get_child(1).text.contains("predates the shopkeeper update — starting a new game"), "L1: the one-time message is on screen ('%s')" % banner_text().replace("\n", " "))
			check(main._finale_banner.get_child(1).text.contains("save.json.v1.bak"), "L1: ...and says where the old save went")
			check(main._toast_label.visible, "L1: a toast backs it up ('%s')" % main._toast_label.text)
			var bak := _read_json(path + ".v1.bak")
			check(int(bak.get("version", 0)) == 1 and int(bak.get("story", {}).get("completed_day", 0)) == 4, "L1: the old save is kept, untouched, at .v1.bak")
			var now := _read_json(path)
			check(int(now.get("version", 0)) == SG.VERSION and now.has("shop") and not now.has("story"), "L1: the save on disk is a fresh current-version (%d) one already (keys %s)" % [SG.VERSION, str(now.keys())])
			check(not main.tutorial.active, "L1: a returning crew isn't pushed into the practice shift")
			await wait(main.LEGACY_NOTICE_SECONDS + 0.5)
			check(not main._finale_banner.visible, "L1: the message goes away by itself")
		2:
			check(main.load_status == SG.LOAD_OK, "L2: relaunch loads the fresh save (status %d)" % main.load_status)
			check(not (main._finale_banner.visible and main._finale_banner.get_child(0).text == "NEW GAME"), "L2: no 'new game' message the second time")
			check(main.current_day == 1 and main.money == main.STARTING_MONEY, "L2: still the fresh shop")
			# earn, buy, finish the day -> everything the economy has goes to disk
			add_sales(90)
			var pay := await end_day()
			await next_day()
			main.money = 5000
			check(main.buy_section("Produce", 1), "L2: bought Produce")
			main.lifetime_earned = 1234
			main.save_progress("test")
			print("L2STATE,%d,%d,%d,%d,%d" % [main.current_day, main.money, main.lifetime_earned, main.sections_owned, main.complication_stage])
		3:
			check(main.load_status == SG.LOAD_OK, "L3: v2 save loads")
			var disk := _read_json(path)
			var sh: Dictionary = disk.get("shop", {})
			check(main.current_day == int(sh.get("completed_day", -1)) + 1 and main.current_day == 2, "L3: resumes the day after the last completed one (Day %d)" % main.current_day)
			check(main.money == 5000 - main.section_price("Produce") and main.lifetime_earned == 1234 and main.sections_owned == 2, "L3: bank %s, lifetime $%d, %d sections — as saved" % [main._format_money(main.money), main.lifetime_earned, main.sections_owned])
			check(gate_open("Produce"), "L3: the bought section is open after a relaunch")
			check(main.status_label.text.contains("Bank %s" % main._format_money(main.money)), "L3: status line shows the loaded bank")
		4:
			# A save from the future / garbage stays a damaged-file fresh start.
			check(main.load_status == SG.LOAD_CORRUPT and main.money == main.STARTING_MONEY and main.sections_owned == 1, "L4: a version-99 save -> a damaged-file fresh start (status %d)" % main.load_status)
	finish()

## =============================================================================
## CO-OP
## =============================================================================

var _seq := 0

func econ_view() -> Dictionary:
	var gates := {}
	for i in range(1, main.SECTIONS.size()):
		gates[main.SECTIONS[i]["name"]] = [gate_open(main.SECTIONS[i]["name"]), gate_text(main.SECTIONS[i]["name"])]
	return {"day": main.current_day, "money": main.money, "earned": main.lifetime_earned, "owned": main.sections_owned, "stage": main.complication_stage, "rows": main.shelf_rows, "gates": gates, "open": main._unlocked_sections().map(func(s): return s["name"]), "levels": _levels_row()}

func _canon(v) -> String:
	return JSON.stringify(JSON.parse_string(JSON.stringify(v)), "", true)

func _step(kind: String, data := {}) -> void:
	_seq += 1
	data["kind"] = kind
	_net_write("ec_%d.json" % _seq, data)

func _answers(ids: Array, timeout := 40.0) -> Dictionary:
	var out := {}
	for id in ids:
		if id == 1:
			continue
		out[id] = await _net_read("ec_%d_%d.json" % [_seq, id], timeout)
	return out

func _sync_view(ids: Array, tag: String) -> void:
	await wait(0.4)
	_step("view", {"tag": tag, "view": JSON.parse_string(JSON.stringify(econ_view()))})
	var ans := await _answers(ids)
	for id in ans:
		check(ans[id].get("ok", false), "%s: %s sees the host's economy%s" % [tag, main.player_display_name(id), ans[id].get("why", " (no answer)")])

func _run_net_host() -> void:
	var want := _arg_int("--players=", 3)
	if DirAccess.dir_exists_absolute(NET_DIR):
		for f in DirAccess.get_files_at(NET_DIR):
			DirAccess.remove_absolute(NET_DIR + f)
	await wait_until(func(): return main.shift_active and main.players.size() >= want, 60.0)
	await wait(1.0)
	var ids: Array = main.players.keys()
	ids.sort()
	check(main.players.size() == want and main.money == 2000 and main.sections_owned == 1, "N0: %d players, bank %s, 1 section, prep" % [main.players.size(), main._format_money(main.money)])
	_step("hello")
	await _answers(ids)
	await _sync_view(ids, "N1 start")
	# N2 a forged purchase from across the store is refused
	var refused0: int = main.purchases_refused
	_step("forge", {"who": ids[1]})
	await _answers(ids)
	await wait(0.6)
	check(main.sections_owned == 1 and main.purchases_refused == refused0 + 1, "N2: %s asked to buy Produce from the break room -> refused" % main.player_display_name(ids[1]))
	# N3 a client walks up and presses E: bought through the host
	_step("buy", {"who": ids[1], "sec": "Produce"})
	await _answers(ids)
	await wait_until(func(): return main.sections_owned == 2, 5.0)
	check(main.sections_owned == 2 and main.money == 2000 - main.section_price("Produce") and main.purchases_made == 1, "N3: %s bought Produce at its gate — bank %s" % [main.player_display_name(ids[1]), main._format_money(main.money)])
	await _sync_view(ids, "N3 after the purchase")
	_step("notice", {"want": "PRODUCE IS OPEN"})
	var ans := await _answers(ids)
	for id in ans:
		check(ans[id].get("ok", false), "N3: %s saw the purchase notice ('%s')" % [main.player_display_name(id), ans[id].get("text", "")])
	# N4 the race: both clients press E at Dairy/Frozen's gate at one instant
	main.money = main.section_price("Dairy/Frozen") + 50
	var made0: int = main.purchases_made
	var refused_race0: int = main.purchases_refused
	var at := Time.get_unix_time_from_system() + 2.0
	_step("race", {"sec": "Dairy/Frozen", "at": at})
	await _answers(ids)
	await wait(1.0)
	check(main.sections_owned == 3 and main.purchases_made == made0 + 1 and main.money == 50, "N4: two clients asked the host to buy Dairy/Frozen in the same instant -> bought ONCE (bank %s, purchases %d)" % [main._format_money(main.money), main.purchases_made - made0])
	check(main.purchases_refused == refused_race0 + 1, "N4: ...the other client's press did reach the host and was refused (refused +%d)" % (main.purchases_refused - refused_race0))
	await _sync_view(ids, "N4 after the race")
	# N5 payday: the shared bank, on every peer
	main.cashiers[0].get_node("Cashier").total_sold += 40
	main.shift_time_left = 0.01
	await wait_until(func(): return main.is_day_report_active(), 6.0)
	await wait(0.5)
	var pay: int = main._pay_today()
	check(main.money == 50 + pay, "N5: payday -> bank %s (+%s)" % [main._format_money(main.money), main._format_money(pay)])
	_step("report", {"week": main.report_week_label.text, "shop": main.report_shop_label.text})
	ans = await _answers(ids)
	for id in ans:
		check(ans[id].get("ok", false), "N5: %s's report shows the same bank + forecast%s" % [main.player_display_name(id), ans[id].get("why", "")])
	await _sync_view(ids, "N5 payday")
	# N6 next shift: the stage moves on every peer, with its banner
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 6.0)
	await wait(0.5)
	check(main.complication_stage == main.STAGE_FORKLIFT, "N6: next shift -> stage 1 (forklift)")
	_step("banner", {"want": "NEW: THE FORKLIFT"})
	ans = await _answers(ids)
	for id in ans:
		check(ans[id].get("ok", false), "N6: %s saw the banner ('%s')" % [main.player_display_name(id), ans[id].get("text", "")])
	await _sync_view(ids, "N6 stage 1")
	_step("done")
	await _answers(ids)
	finish()

func _run_net_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 30.0)
	me = main.multiplayer.get_unique_id()
	act = root.get_node("Settings").local_prefix()
	var who: String = main.player_display_name(me)
	var n := 0
	while true:
		n += 1
		var step := await _net_read("ec_%d.json" % n, 600.0)
		var kind: String = step.get("kind", "")
		var ans := {}
		match kind:
			"hello":
				pass
			"view":
				var theirs: Dictionary = step["view"]
				var ok := await wait_until(func(): return _canon(econ_view()) == _canon(theirs), 8.0)
				ans = {"ok": ok, "why": "" if ok else " — mine %s vs host %s" % [_canon(econ_view()), _canon(theirs)]}
				check(ok, "%s: %s matches the host" % [who, step.get("tag", "")])
			"forge":
				if int(step["who"]) == me:
					player().teleport_to(Vector2(480, 330))
					await wait(0.3)
					main._request_buy_section.rpc_id(1, "Produce")
			"buy":
				if int(step["who"]) == me:
					player().teleport_to(BUY_SPOT[step["sec"]])
					await wait(0.4)
					var hint: Array = main.gate_hint_for(player().global_position)
					check(hint[2], "%s: the prompt offers %s ('%s')" % [who, step["sec"], str(hint[1]).replace("\n", " / ")])
					await tap(act + "interact")
					await wait(0.5)
			"notice":
				var ok := await wait_until(func(): return main._finale_banner.visible and main._finale_banner.get_child(0).text == step["want"], 4.0)
				ans = {"ok": ok, "text": banner_text()}
			"race":
				player().teleport_to(BUY_SPOT[step["sec"]] + Vector2(0, 40 * (main.players.keys().find(me))))
				await wait(0.3)
				while Time.get_unix_time_from_system() < float(step["at"]):
					await physics_frame
				# Straight to the host, both on the same instant: a real E press
				# would usually see the first purchase replicate in and never
				# send (the client-side check) — this is the host's own guard.
				main._request_buy_section.rpc_id(1, step["sec"])
				await wait(0.5)
			"report":
				var ok := await wait_until(func(): return main.report_layer.visible and main.report_week_label.text == step["week"] and main.report_shop_label.text == step["shop"], 8.0)
				ans = {"ok": ok, "why": "" if ok else " — mine '%s' / '%s' vs '%s' / '%s'" % [main.report_week_label.text, main.report_shop_label.text, step["week"], step["shop"]]}
			"banner":
				var ok := await wait_until(func(): return main._finale_banner.visible and main._finale_banner.get_child(0).text == step["want"], 6.0)
				ans = {"ok": ok, "text": banner_text()}
			"done":
				_net_write("ec_%d_%d.json" % [n, me], {})
				finish()
				return
		_net_write("ec_%d_%d.json" % [n, me], ans)

## =============================================================================
## SOAK
## =============================================================================

func _counts() -> Dictionary:
	return {
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"orphans": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"mem_mb": snappedf(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, 0.1),
		"products": get_nodes_in_group("carryable").size(),
		"customers": get_nodes_in_group("customer").size(),
		# PHASE 5: nodes under each of Main's children (and root's other
		# children), to find where a node-count creep lives.
		"tree": _subtree_counts(),
	}

func _subtree_counts() -> Dictionary:
	var out := {}
	for c in root.get_children():
		if c == main:
			for k in main.get_children():
				out[String(k.name)] = _count_nodes(k)
		else:
			out["/" + String(c.name)] = _count_nodes(c)
	return out

func _count_nodes(n: Node) -> int:
	var t := 1
	for c in n.get_children(true):
		t += _count_nodes(c)
	return t

## Keeps every open shelf stocked (spawning stock at the section if none is
## loose), for as long as the store is open — a crew on top of its job, so
## shoppers keep buying and the floor stays busy all shift.
func _soak_crew() -> void:
	while main.shift_active and not main.cleanup_active:
		for s in main._unlocked_sections():
			var n: String = s["name"]
			var tries := 0
			while empty_slot_in(n) != null and tries < 6 and main.shift_active and not main.cleanup_active:
				tries += 1
				if loose_products(n).is_empty():
					main._spawn_product_for(n)
					await physics_frame
					await physics_frame
				var ok = await stock_one(n)
				if ok == null:
					break
		await wait(1.0)

func _run_soak_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1, 30.0)
	var last := Time.get_ticks_msec()
	var worst := 0
	var t := 0.0
	while true:
		await process_frame
		var now := Time.get_ticks_msec()
		worst = maxi(worst, now - last)
		t += (now - last) / 1000.0
		last = now
		if t >= 30.0:
			var c := _counts()
			c["worst_frame_ms"] = worst
			c["day"] = main.current_day
			print("SOAKC %d: %s" % [main.multiplayer.get_unique_id(), str(c)])
			t = 0.0
			worst = 0

func _run_soak() -> void:
	var shifts := _arg_int("--shifts=", 8)
	var want := _arg_int("--players=", 1)
	await wait_until(func(): return main.shift_active and main.players.size() >= want, 40.0)
	await wait(0.5)
	var rows := []
	var t0 := Time.get_ticks_msec()
	for i in shifts:
		check(main.shift_active and main.sections_owned == 4 and main.complication_stage == main.STAGE_RUSH, "S%d: Day %d, all sections, top tier" % [i + 1, main.current_day])
		main.open_store(1)
		var frame_ms := []
		_soak_crew()
		var start := Time.get_ticks_msec()
		var last := start
		var peak_customers := 0
		while main.shift_active and not main.cleanup_active:
			await process_frame
			var now := Time.get_ticks_msec()
			frame_ms.append(now - last)
			last = now
			peak_customers = maxi(peak_customers, get_nodes_in_group("customer").size())
		frame_ms.sort()
		var p95: int = frame_ms[int(frame_ms.size() * 0.95)] if not frame_ms.is_empty() else 0
		var avg := 0.0
		for f in frame_ms:
			avg += f
		avg /= maxf(1.0, frame_ms.size())
		await wait_until(func(): return main.is_day_report_active(), 400.0)
		await wait(0.5)
		var c := _counts()
		c["sold"] = main._total_sold() - main._sold_at_day_start
		c["pay"] = main._pay_today()
		c["frame_avg_ms"] = snappedf(avg, 0.01)
		c["frame_p95_ms"] = p95
		c["peak_customers"] = peak_customers
		c["fps"] = snappedf(frame_ms.size() / maxf(0.001, (last - start) / 1000.0), 0.1)
		rows.append(c)
		print("SOAK shift %d (Day %d): %s" % [i + 1, main.current_day, str(c)])
		main._on_continue_pressed()
		await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 10.0)
		await wait(0.5)
	print("SOAK SUMMARY — %d shifts, %.1f min of real time" % [shifts, (Time.get_ticks_msec() - t0) / 60000.0])
	for r in rows:
		print("SOAK  ", r)
	# PHASE 5: which subtrees grew from the first shift to the last.
	var grew := {}
	var tree0: Dictionary = rows[0]["tree"]
	var tree1: Dictionary = rows[-1]["tree"]
	for k in tree1:
		var d: int = tree1[k] - int(tree0.get(k, 0))
		if d != 0:
			grew[k] = d
	print("SOAK GROWTH (nodes, first -> last shift, by subtree): %s" % str(grew))
	# Drift checks: compare the last shift's between-shifts counts with the
	# first's (both taken at the report, when the floor has just been cleared
	# of customers but still holds the shift's stock).
	var a: Dictionary = rows[0]
	var b: Dictionary = rows[-1]
	check(b["nodes"] <= a["nodes"] + 150, "SOAK: node count steady (%d -> %d)" % [a["nodes"], b["nodes"]])
	check(b["objects"] <= a["objects"] * 1.15 + 500, "SOAK: object count steady (%d -> %d)" % [a["objects"], b["objects"]])
	check(b["orphans"] <= a["orphans"] + 20, "SOAK: orphan nodes steady (%d -> %d)" % [a["orphans"], b["orphans"]])
	check(b["mem_mb"] <= a["mem_mb"] * 1.15 + 16.0, "SOAK: memory steady (%.1f -> %.1f MB)" % [a["mem_mb"], b["mem_mb"]])
	check(b["frame_p95_ms"] <= maxi(a["frame_p95_ms"] * 2, a["frame_p95_ms"] + 10), "SOAK: frame time p95 steady (%d -> %d ms)" % [a["frame_p95_ms"], b["frame_p95_ms"]])
	var sold_all := rows.all(func(r): return r["sold"] > 0)
	check(sold_all, "SOAK: every shift sold (%s)" % str(rows.map(func(r): return r["sold"])))
	finish()
