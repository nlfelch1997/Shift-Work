extends "res://tools/economy_test.gd"
## OCT 2026 PIVOT, PHASE 3 — HIRED HELPERS (Staff.gd / Helper.gd). Reuses
## tools/economy_test.gd's helpers (and through it tools/hazards_test.gd's:
## walking, key taps, the solo bot brain, the net step files) and drives the
## real Main.tscn through the real game code. Not part of the game. Real
## wall-clock time throughout, except INCOME (a bot sim, see its header).

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--test="):
			_mode = a.substr(7)
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	careless = true
	var client := "--client" in args
	if _mode == "soak":
		main.cleanup_ceiling_override = 5.0 # (economy_test's soak does the same)
	if _mode == "save":
		_prepare_staff_save_phase() # the file has to be there before Main hosts
	if _mode == "income" and "--afk" in args:
		main.cleanup_ceiling_override = 0.0 # nobody to clean: clock out at close
	match _mode:
		"smoke": _run_smoke.call_deferred()
		"probe": _run_probe.call_deferred()
		"income": _run_income.call_deferred()
		"hire": _run_hire.call_deferred()
		"effect": _run_effect.call_deferred()
		"save": _run_staff_save.call_deferred()
		"hazards": _run_staff_hazards.call_deferred()
		"soak": (_run_soak_client if client else _run_staff_soak).call_deferred()
		"net-staff": (_run_net_staff_client if client else _run_net_staff_host).call_deferred()
		_:
			print("FAIL  unknown --test=%s" % _mode)
			quit(1)

func helper(sec: String) -> Node2D:
	return main.staff.helpers[sec]

func st() -> Node2D:
	return main.staff

## Rebuilds the panel now (it rebuilds itself on the next frame anyway).
func panel_button(key: String) -> Button:
	await process_frame
	await process_frame
	return st().buttons.get(key)

func press_button(key: String) -> void:
	var b: Button = await panel_button(key)
	if b != null:
		b.pressed.emit() # a click (emit bypasses `disabled`: the host's rules still apply)
	await wait(0.3)

func _run_smoke() -> void:
	await wait_until(func(): return main.shift_active, 20.0)
	main.money = 5000
	check(main.staff.do_action("Produce", "hire", 1), "hire Produce")
	var h := helper("Produce")
	var overlap := 0
	for i in 30:
		if i == 6:
			main.open_store(1)
		for k in 300:
			await physics_frame
			if fk().active and h._in_forklift(h.position, 4.0):
				overlap += 1
		var shelf_fill := 0
		for s in h._shelves():
			shelf_fill += s.get_node("Shelf").filled_count()
		print("INFO t=%d pos=%s job=%s held=%d loose=%d empty=%d backstock=%d placed=%d picked=%d unpacked=%d fill=%d yield=%.1f diverted=%d store_open=%s fk=%s overlap=%d" % [i * 5, str(h.position.round()), h._job.get("kind", "-"), h._held().size(), h._loose_items().size(), h._empty_slots().size(), main.staff.backstock_of("Produce"), h.placed_today, h.picked_today, h.unpacked_today, shelf_fill, h.forklift_yield_s, main.staff.boxes_diverted_today, str(main.store_open), str(fk().global_position.round()), overlap])
	finish()

## =============================================================================
## INCOME — what a helper is worth to a SOLO crew, measured, not assumed.
## The solo bot (tools/hazards_test.gd's competent-player brain, the one Phase
## 2's prices were measured with) plays whole shifts — prep, selling, cleanup,
## clock-out — from an old Day N economy preset, with the helpers named by
## --hire=Section:speed:carry,... on the books from the shift's start. A
## competent human with a helper leaves that section to them: the bot skips
## a staffed section's stock (--share lets it help there too). --afk: the
## player never moves (the store opens when prep runs out) — what the helpers
## make with nobody else working at all. One INCOME line per shift:
##   godot --headless [--fixed-fps 60] --path . --script res://tools/staff_test.gd -- --server --day=3 --no-save --test=income --hire=Produce:0:0 [--afk] [--shifts=N]
## =============================================================================

var _hire_spec := {}
var _share := "--share" in OS.get_cmdline_user_args()

func _parse_hire() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--hire=") and a.length() > 7:
			for part in a.substr(7).split(","):
				var f := part.split(":")
				out[f[0]] = {"speed": int(f[1]) if f.size() > 1 else 0, "carry": int(f[2]) if f.size() > 2 else 0}
	return out

func _staffed_color(obj: Node) -> bool:
	if _share:
		return false
	var visual := obj.get_node_or_null("Polygon2D")
	if visual == null:
		return false
	for sec in _hire_spec:
		if visual.color.is_equal_approx(main.SECTION_COLORS[sec]):
			return true
	return false

## The brain leaves a staffed section's stock to its helper.
func _pick_product(p: Node2D, only_color: Color) -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for obj in get_nodes_in_group("carryable"):
		if _staffed_color(obj):
			continue
		if only_color.a > 0.0 and not obj.get_node("Polygon2D").color.is_equal_approx(only_color):
			continue
		if _at_a_slot(obj):
			continue
		if obj.get_node("Carryable").carrier_id != 0 or _is_placed(obj) or recent_drops.has(obj):
			continue
		if not main.is_unlocked_at_pos(obj.global_position) and not main._grid_cell_of(obj.global_position) in [Vector2i(1, 1), main.STORAGE_GRID_POS]:
			continue
		if pick_slot(obj.global_position, obj).is_empty():
			continue
		var d := p.global_position.distance_to(obj.global_position)
		if d < best_d:
			best_d = d
			best = obj
	return best

func _loose_stockable() -> int:
	var n := 0
	for obj in get_nodes_in_group("carryable"):
		if obj.is_in_group("delivery_box") or _staffed_color(obj) or obj.get_node("Carryable").carrier_id != 0 or _is_placed(obj) or _at_a_slot(obj):
			continue
		if main.is_unlocked_at_pos(obj.global_position) or main._grid_cell_of(obj.global_position) in [Vector2i(1, 1), main.STORAGE_GRID_POS]:
			n += 1
	return n

## The shelves the bot is responsible for: a staffed section's are the helper's.
## --open-after=S: the bot flips the sign S seconds into prep instead (a crew
## that opens early because its helpers have the other aisles covered).
var _open_after := -1.0

func _fill_ratio() -> float:
	if _open_after >= 0.0:
		return 0.0 # _open_at() flips the sign
	var f := 0
	var n := 0
	for sb in main.shelves:
		if not main.is_unlocked_at_pos(sb.global_position):
			continue
		var sec: String = main._section_name_at(sb.global_position)
		if _hire_spec.has(sec) and not _share:
			continue
		f += sb.get_node("Shelf").filled_count()
		n += sb.get_node("Shelf").slot_count()
	return float(f) / maxf(1.0, n)

## The sign flips at exactly S seconds of shift clock, whatever the bot is
## doing (FOUND BY THE FIRST OPEN-EARLY BATCH: a bot holding stock it had
## nowhere to put never counted as free to walk to the sign, and two of four
## runs opened at the ceiling instead).
func _open_at(s: float) -> void:
	var len0: float = main.shift_time_left
	await wait_until(func(): return len0 - main.shift_time_left >= s or main.store_open or not main.shift_active, 3000.0)
	if not main.store_open and main.shift_active:
		main.open_store(1)

## OCT 2026 PHASE 3D — --upkeep: the bot also keeps the store clean during
## the selling window, as a tidy crew would: when the floor has UPKEEP_LITTER
## pieces of trash, a puddle or spill, or a can is full, it stops between jobs
## and cleans — trash by hand into the nearest can with room, wet mess with
## the nearest mop, a full can's bag out to the dumpster — then goes back to
## stocking. Without it, the bot never cleans mid-shift (only at close, as
## before): the neglected store. The time it spends is on the INCOME line.
const UPKEEP_LITTER := 4
var _upkeep_s := 0.0
var _upkeep_passes := 0

func _upkeep_due() -> bool:
	if not main.store_open or main.cleanup_active:
		return false
	var cl: Node = main.cleanup
	return cl.litter.size() >= UPKEEP_LITTER or not cl.puddles.is_empty() or cl.full_cans() > 0 or (main.ambience.spills_enabled() and main.ambience.spills.any(func(sp): return sp["phase"] == 1))

func _upkeep_pass() -> bool:
	if not _upkeep_due():
		return false
	var cl: Node = main.cleanup
	var t0 := _wall()
	_upkeep_passes += 1
	steer(Vector2.ZERO)
	# Full cans first: their bags out back.
	var guard := 0
	while cl.full_cans() > 0 and guard < 3 and main.store_open and not main.cleanup_active:
		guard += 1
		await _dump_a_can()
	# Wet mess: a mop.
	var wet: Array = cl.puddles.map(func(x): return {"pos": x["pos"], "r": float(x["r"])})
	if main.ambience.spills_enabled():
		for sp in main.ambience.spills:
			wet.append({"pos": sp["pos"], "r": float(sp["r"])})
	if not wet.is_empty() and await get_tool("mop"):
		for m in wet:
			if not main.store_open or main.cleanup_active:
				break
			if await face_target(m["pos"], mop_stand(m)):
				press(act + "place")
				await wait_until(func(): return not mop_messes_view().any(func(q): return q["pos"].distance_to(m["pos"]) < 12.0), 5.0)
				press(act + "place", 0.0)
		if cl.tool_of(me) >= 0:
			await tap(act + "interact")
	# Trash by hand, a handful at a time, into a can with room.
	guard = 0
	while cl.litter.size() > 0 and guard < 12 and main.store_open and not main.cleanup_active:
		guard += 1
		while cl.hand_count(me) < cl.HAND_MAX and cl.litter.size() > 0:
			var near = _nearest(player().global_position, cl.litter, [])
			if near == null:
				break
			await walk_to(near["pos"], 22.0, 10.0)
			var before: int = cl.hand_count(me)
			await tap(act + "interact")
			await wait_until(func(): return cl.hand_count(me) > before, 1.0)
			if cl.hand_count(me) == before:
				break
		if cl.hand_count(me) > 0:
			var best := -1
			var bd := INF
			for i in cl.BINS.size():
				if cl._bin_open(i) and not cl.can_full(i):
					var d := route_len(player().global_position, cl.BINS[i]["pos"])
					if d < bd:
						bd = d
						best = i
			if best < 0:
				await tap(act + "interact") # drop it (nowhere to put it) and empty a can
				await _dump_a_can()
				continue
			await walk_to(cl.BINS[best]["pos"] + Vector2(0, 30), 12.0, 20.0)
			await tap(act + "interact")
			await wait_until(func(): return cl.hand_count(me) == 0, 1.0)
	_upkeep_s += _wall() - t0
	return true

func _run_income() -> void:
	_hire_spec = _parse_hire()
	if "--upkeep" in OS.get_cmdline_user_args():
		upkeep_hook = _upkeep_pass
	_open_after = float(_arg_int("--open-after=", -1))
	var afk := "--afk" in OS.get_cmdline_user_args()
	var shifts := _arg_int("--shifts=", 1)
	await wait_until(func(): return main.players.has(1), 20.0)
	# On the books before the first shift starts (PRODUCT_SPAWN_DELAY after
	# hosting), as a crew that hired them last prep would be.
	main.staff.staff = _hire_spec.duplicate(true)
	for n in shifts:
		await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 30.0)
		stats = {"placed": 0, "hits": 0, "watched_s": 0.0, "idle_s": 0.0, "reasons": {}, "wrecks": 0, "overlap": 0, "banner_and_busy_s": 0.0, "banner_clash": 0, "first_customer_s": -1.0, "shift_len": main.shift_time_left, "grace": main.prep_time_left, "slip_s": 0.0}
		_haul = {"walk_px": 0.0, "last_pos": null, "box_t": {}, "carry_s": [], "item_born": {}, "item_s": [], "box_items": {}, "box_cycle_s": [], "seen": {}, "last_event": dl().unpack_event_id, "last_carry": null, "open_placed": 0, "open_called": 0, "item_carry": null, "last_pos_c": null, "carry_item_s": [], "carry_item_px": []}
		var money0: int = main.money
		var life0: int = main.lifetime_earned
		var t0 := _wall()
		var rating0: float = main.store_rating.rating
		_upkeep_s = 0.0
		_upkeep_passes = 0
		if _open_after >= 0.0:
			_open_at(_open_after)
		if afk:
			await wait_until(func(): return main.is_day_report_active(), 3000.0)
		else:
			await _play_shift()
			for o in get_nodes_in_group("carryable"):
				if o.get_node("Carryable").carrier_id == me:
					await tap(act + "interact")
			await _play_cleanup(false, true)
			await wait_until(func(): return main.is_day_report_active(), 200.0)
		await wait(0.3)
		var sold: int = main._total_sold() - main._sold_at_day_start
		var helper_bits := []
		for sec in main.staff.HELPER_SECTIONS:
			if main.staff.is_hired(sec):
				var h := helper(sec)
				helper_bits.append("%s[s%d c%d]: placed %d, unpacked %d, walked %.0fpx, yield %.0fs" % [sec, main.staff.speed_level(sec), main.staff.carry_level(sec), h.placed_today, h.unpacked_today, h.walked_px, h.forklift_yield_s])
		var pay: int = main._pay_today()
		var cl: Node = main.cleanup
		print("UPKEEP day=%d upkeep=%d frozen=%d shift=%d | rating %.2f -> %.2f | sold %d, customer cap %d, price $%d | rating on prices %s, trash %s (%d binned), bounced %d | cleaning passes %d, %.0fs | litter dropped %d, puddles %d, cans %s, bags dumped %d | pay %s" % [main.debug_day, 1 if upkeep_hook.is_valid() else 0, 1 if main.rating_frozen else 0, n + 1, rating0, main.store_rating.rating, sold, main.customer_cap(), main.sale_price(), main._format_money(main.rating_sales_today), main._format_money(cl.litter_pay_today()), cl.trash_binned_today, main.bounced_today, _upkeep_passes, _upkeep_s, cl.litter_dropped_today, cl.puddles_dropped_today, str(cl.cans), cl.bags_dumped_today, main._format_money(pay)])
		print("INCOME day=%d open_after=%d stage=%d sections=%d hire=%s afk=%d share=%d shift=%d | sold %d by %s | pay %s, wages %s, net %s | bank %s -> %s, lifetime +%d | opened at %.0fs by %s, prep ceiling %.0fs | boxes diverted %d (skipped %d), bot placed %d | %s | wall %.0fs" % [main.debug_day, int(_open_after), main.complication_stage, main.sections_owned, str(_hire_spec).replace(" ", ""), 1 if afk else 0, 1 if _share else 0, n + 1, sold, str(main.sold_by_section_today).replace(" ", ""), main._format_money(pay), main._format_money(main.staff.wages_today), main._format_money(pay - main.staff.wages_today), main._format_money(money0), main._format_money(main.money), main.lifetime_earned - life0, stats.get("opened_at", -1.0), stats.get("opened_by", "ceiling" if afk else "?"), stats["grace"], main.staff.boxes_diverted_today, main.staff.boxes_skipped_today, stats["placed"], "; ".join(helper_bits), _wall() - t0])
		check(main.money == money0 + pay - main.staff.wages_today, "shift %d: bank moved by pay - wages exactly (%s -> %s)" % [n + 1, main._format_money(money0), main._format_money(main.money)])
		check(main.lifetime_earned == life0 + maxi(0, pay), "shift %d: lifetime earned grew by the pay alone (wages don't touch it)" % (n + 1))
		if n < shifts - 1:
			main._on_continue_pressed()
	finish()

## =============================================================================
## HIRING — solo, from a brand-new shop: a real walk to the staff board and a
## real E press, its panel's buttons, every refusal reason, the upgrades and
## what they set, wages at clock-out (bank yes, lifetime no), letting go.
##   godot --headless --path . --script res://tools/staff_test.gd -- --server --no-save --test=hire
## =============================================================================

func _run_hire() -> void:
	main.cleanup_ceiling_override = 0.0
	await wait_until(func(): return main.shift_active, 20.0)
	await wait(0.5)
	# --- H1 a fresh shop: nobody on staff
	check(st().staff.is_empty() and main.money == 0 and main.sections_owned == 1, "H1: fresh shop — no staff, bank $0, Dry Goods only")
	check(st().helpers.values().all(func(h): return not h.active and not h.visible), "H1: no helper on the floor")
	check(not st()._hint.visible and not st().panel.visible, "H1: the board's prompt and panel are hidden away from it")
	# --- H2 a real walk to the board, a real E: the panel
	var walked := await walk_to(st().BOARD_SPOT, 10.0, 20.0)
	check(walked, "H2: walked to the staff board (%s)" % str(player().global_position.round()))
	await wait(0.2)
	check(st()._hint.visible and st()._hint.text.contains("staff board"), "H2: prompt at the board ('%s')" % st()._hint.text)
	await tap(act + "interact")
	await wait(0.2)
	check(st().panel.visible, "H2: E at the board opens the staff panel")
	check(await panel_button("Produce:hire") == null, "H2: no Hire button for a section the crew doesn't own")
	check(st().blocker("Produce", "hire") == "buy Produce first", "H2: Produce's slot isn't open: '%s'" % st().blocker("Produce", "hire"))
	check(st().blocker("Dry Goods", "hire") == "no helpers for Dry Goods", "H2: Dry Goods takes no helper: '%s'" % st().blocker("Dry Goods", "hire"))
	var refused0: int = st().actions_refused
	check(not st().do_action("Produce", "hire", 1) and st().actions_refused == refused0 + 1 and main.money == 0 and st().staff.is_empty(), "H2: a hire for an unowned section is refused")
	# --- H3 owned but broke: the second gate
	main.money = main.section_price("Produce")
	check(main.buy_section("Produce", 1) and main.money == 0, "H3: bought Produce (bank $0)")
	var b: Button = await panel_button("Produce:hire")
	check(b != null and b.disabled and b.text.contains("$%d" % st().HIRE_FEE["Produce"]), "H3: Produce's Hire button is there, disabled ('%s')" % (b.text if b else "none"))
	check(st().blocker("Produce", "hire") == "need $%d more" % st().HIRE_FEE["Produce"], "H3: owned but broke — '%s'" % st().blocker("Produce", "hire"))
	await press_button("Produce:hire")
	check(st().staff.is_empty() and main.money == 0, "H3: pressing it anyway is refused by the host")
	check(main._toast_label.text.contains("need $"), "H3: ...and says why ('%s')" % main._toast_label.text)
	# --- H4 hired
	main.money = 1000
	b = await panel_button("Produce:hire")
	check(b != null and not b.disabled, "H4: with the money, Hire is live")
	await press_button("Produce:hire")
	var h := helper("Produce")
	check(st().is_hired("Produce") and main.money == 1000 - st().HIRE_FEE["Produce"], "H4: Sam hired for Produce — bank $1000 -> %s" % main._format_money(main.money))
	check(st().speed_level("Produce") == 0 and st().carry_level("Produce") == 0 and h.speed == st().SPEED_BY_LEVEL[0] and h.capacity == st().CARRY_BY_LEVEL[0], "H4: starts at speed %d px/s, carrying %d" % [int(h.speed), h.capacity])
	await wait(0.2)
	check(h.active and h.visible and main._grid_cell_of(h.position) == Vector2i(2, 1), "H4: on the floor in Produce (%s)" % str(h.position.round()))
	check(st().on_books.has("Produce") and st().wages_due() == st().WAGE["Produce"], "H4: on the books this shift — $%d due at clock-out" % st().wages_due())
	check(main._toast_label.text.begins_with("You hired Sam"), "H4: toast '%s'" % main._toast_label.text)
	# --- H5 the other refusals
	check(st().blocker("Produce", "hire") == "Sam already works here", "H5: hiring twice: '%s'" % st().blocker("Produce", "hire"))
	check(st().blocker("Dairy/Frozen", "hire") == "buy Dairy/Frozen first", "H5: Dairy/Frozen not owned: '%s'" % st().blocker("Dairy/Frozen", "hire"))
	check(st().blocker("Dairy/Frozen", "speed") == "nobody hired" and st().blocker("Dairy/Frozen", "fire") == "nobody hired", "H5: upgrading / letting go of nobody: '%s'" % st().blocker("Dairy/Frozen", "speed"))
	main.tutorial.active = true
	var why_practice: String = st().blocker("Produce", "speed")
	main.tutorial.active = false
	check(why_practice.begins_with("practice shift"), "H5: practice shift: '%s'" % why_practice)
	main.endless_active = true
	var why_endless: String = st().blocker("Produce", "speed")
	main.endless_active = false
	check(why_endless == "not in Endless Mode", "H5: endless: '%s'" % why_endless)
	# --- H6 the two upgrades, and what they set
	var m0: int = main.money
	await press_button("Produce:speed")
	check(st().speed_level("Produce") == 1 and main.money == m0 - st().SPEED_COSTS[0] and h.speed == st().SPEED_BY_LEVEL[1], "H6: speed -> level 2 of 3 (%d px/s), -$%d" % [int(h.speed), st().SPEED_COSTS[0]])
	m0 = main.money
	await press_button("Produce:carry")
	check(st().carry_level("Produce") == 1 and main.money == m0 - st().CARRY_COSTS[0] and h.capacity == st().CARRY_BY_LEVEL[1], "H6: carry -> level 2 of 3 (%d a trip), -$%d" % [h.capacity, st().CARRY_COSTS[0]])
	main.money = 0
	await press_button("Produce:speed")
	check(st().speed_level("Produce") == 1 and main.money == 0, "H6: broke -> the speed upgrade is refused ('%s')" % st().blocker("Produce", "speed"))
	main.money = 5000
	await press_button("Produce:speed")
	await press_button("Produce:carry")
	check(st().speed_level("Produce") == 2 and st().carry_level("Produce") == 2 and h.speed == st().SPEED_BY_LEVEL[2] and h.capacity == st().CARRY_BY_LEVEL[2], "H6: both maxed (%d px/s, %d a trip)" % [int(h.speed), h.capacity])
	check(main.money == 5000 - st().SPEED_COSTS[1] - st().CARRY_COSTS[1], "H6: charged $%d + $%d" % [st().SPEED_COSTS[1], st().CARRY_COSTS[1]])
	m0 = main.money
	b = await panel_button("Produce:speed")
	check(b != null and b.disabled and b.text.contains("MAX") and st().blocker("Produce", "speed") == "maxed out", "H6: past the top: '%s' / '%s'" % [b.text if b else "none", st().blocker("Produce", "speed")])
	await press_button("Produce:speed")
	check(main.money == m0 and st().speed_level("Produce") == 2, "H6: a maxed upgrade pressed anyway: nothing charged")
	# --- H7 walking off closes the panel; E while carrying doesn't open it
	await walk_to(st().BOARD_SPOT + Vector2(260, 0), 12.0, 10.0)
	await wait(0.2)
	check(not st().panel.visible, "H7: walked away -> the panel closed")
	await walk_to(st().BOARD_SPOT, 10.0, 10.0)
	main.spawn_product_at("Dry Goods", player().global_position + Vector2(60, 40))
	await wait(0.3)
	var held := await pickup_near_player()
	check(held != null, "H7: holding a product at the board")
	if held != null:
		await wait(0.2)
		await tap(act + "interact") # with stock in hand, E is "put it down", as always
		await wait(0.2)
		check(not st().panel.visible, "H7: E at the board with stock in hand doesn't open the panel")
	await tap(act + "interact")
	await wait(0.2)
	check(st().panel.visible, "H7: empty-handed E opens it again")
	await tap(act + "interact")
	await wait(0.2)
	check(not st().panel.visible, "H7: and E closes it")
	# --- H8 store open: no staff changes
	main.open_store(1)
	await wait(0.3)
	check(st().blocker("Produce", "fire").begins_with("staff changes during prep"), "H8: store open -> '%s'" % st().blocker("Produce", "fire"))
	check(not st().do_action("Produce", "fire", 1) and st().is_hired("Produce"), "H8: letting go with the store open is refused")
	# --- H9 payday: wages out of the bank, NOT out of lifetime earnings
	main.test_hold_customers = true
	add_sales(30)
	m0 = main.money
	var life0: int = main.lifetime_earned
	var pay := await end_day()
	check(main.money == m0 + pay - st().WAGE["Produce"], "H9: clock-out: bank %s + pay %s - wage $%d = %s" % [main._format_money(m0), main._format_money(pay), st().WAGE["Produce"], main._format_money(main.money)])
	check(main.lifetime_earned == life0 + maxi(0, pay), "H9: lifetime earned +%d — the pay, wages not taken off" % (main.lifetime_earned - life0))
	check(st().wages_today == st().WAGE["Produce"] and main.report_pay_label.text.contains("Staff wages: -$%d (Sam $%d)" % [st().WAGE["Produce"], st().WAGE["Produce"]]), "H9: the report shows the wage ('%s')" % main.report_pay_label.text.replace("\n", " / "))
	# --- H10 a shift that sells nothing: the bank dips, lifetime doesn't
	await next_day()
	check(st().on_books.has("Produce") and h.active, "H10: next shift — Sam's back on the books and on the floor")
	main.money = 20
	main.lifetime_earned = main.MANAGER_EARNED - 1
	var stage0: int = main.complication_stage
	pay = await end_day()
	check(main.money == 20 + pay - st().WAGE["Produce"] and main.lifetime_earned == main.MANAGER_EARNED - 1 + maxi(0, pay), "H10: pay %s, wage $%d -> bank %s, lifetime $%d" % [main._format_money(pay), st().WAGE["Produce"], main._format_money(main.money), main.lifetime_earned])
	await next_day()
	check(main.complication_stage >= stage0, "H10: the complication stage never steps back for wages (stage %d)" % main.complication_stage)
	# --- H11 letting go: off the floor now, this shift still paid, then no wage
	main.money = 500
	m0 = main.money
	await walk_to(st().BOARD_SPOT, 10.0, 20.0)
	await tap(act + "interact")
	await wait(0.2)
	await press_button("Produce:fire")
	check(not st().is_hired("Produce") and main.money == m0, "H11: 'Let go' — Sam's off the staff, nothing charged now")
	await wait(0.2)
	check(not h.active and not h.visible, "H11: and off the floor")
	check(st().wages_due() == st().WAGE["Produce"], "H11: this shift's wage is still owed ($%d)" % st().wages_due())
	pay = await end_day()
	check(main.money == m0 + pay - st().WAGE["Produce"], "H11: clock-out charged it (bank %s)" % main._format_money(main.money))
	await next_day()
	m0 = main.money
	check(st().on_books.is_empty() and st().wages_due() == 0, "H11: next shift: nobody on the books")
	pay = await end_day()
	check(main.money == m0 + pay and st().wages_today == 0 and not main.report_pay_label.text.contains("Staff wages"), "H11: ...and no wage at clock-out")
	# --- H12 hiring again starts from scratch
	await next_day()
	main.money = 1000
	check(st().do_action("Produce", "hire", 1) and st().speed_level("Produce") == 0 and st().carry_level("Produce") == 0 and main.money == 1000 - st().HIRE_FEE["Produce"], "H12: rehired — the fee again, upgrades back to level 1")
	finish()

## =============================================================================
## EFFECT — what a helper does and what the upgrades buy, in a controlled room:
## no customers, no trucks, the store held in prep. Two boxes' worth (12) of
## Produce unpacked on the pad; time until all 12 are on Produce's shelves,
## at base, speed-maxed, carry-maxed and both. Then the back-stock route:
## Produce's truck boxes skip Storage, the helper opens them on the pad.
##   godot --headless --path . --script res://tools/staff_test.gd -- --server --day=3 --no-save --test=effect
## =============================================================================

func _produce_filled() -> int:
	var n := 0
	for sb in helper("Produce")._shelves():
		n += sb.get_node("Shelf").filled_count()
	return n

func _clear_produce() -> void:
	for sb in helper("Produce")._shelves():
		sb.get_node("Shelf").reset()
	for obj in get_nodes_in_group("carryable"):
		obj.queue_free()
	await wait(0.3)

func _run_effect() -> void:
	await wait_until(func(): return main.shift_active, 20.0)
	main.test_hold_customers = true
	main.delivery.active = false
	await _clear_produce()
	main.money = 0
	main.staff.staff = {"Produce": {"speed": 0, "carry": 0}}
	main.staff.sync_helpers()
	var h := helper("Produce")
	var times := {}
	for cfg in [[0, 0], [2, 0], [0, 2], [2, 2]]:
		main.prep_time_left = 9999.0
		main.shift_time_left = 99999.0
		await _clear_produce()
		main.staff.staff = {"Produce": {"speed": cfg[0], "carry": cfg[1]}}
		main.staff.sync_helpers()
		h.reset_for_new_shift()
		main.delivery.unpack_into_section("Produce", "test")
		main.delivery.unpack_into_section("Produce", "test")
		await wait(0.5)
		var t := 0.0
		while _produce_filled() < 12 and t < 240.0:
			await physics_frame
			t += 1.0 / 60.0
		var key := "s%d c%d" % cfg
		times[key] = t
		print("INFO  EFFECT %s (%d px/s, %d a trip): 12 shelved in %.1fs — placed %d, picked %d, walked %.0fpx" % [key, int(h.speed), h.capacity, t, h.placed_today, h.picked_today, h.walked_px])
		check(_produce_filled() == 12, "E1 %s: all 12 units shelved by the helper alone (%d)" % [key, _produce_filled()])
	check(times["s2 c0"] < times["s0 c0"] * 0.85, "E2: the speed upgrade shelves faster (%.1fs vs %.1fs)" % [times["s2 c0"], times["s0 c0"]])
	check(times["s0 c2"] < times["s0 c0"] * 0.85, "E2: the carry upgrade shelves faster (%.1fs vs %.1fs)" % [times["s0 c2"], times["s0 c0"]])
	check(times["s2 c2"] < minf(times["s2 c0"], times["s0 c2"]), "E2: both together are fastest (%.1fs)" % times["s2 c2"])
	# --- E3 the back-stock route
	await _clear_produce()
	main.staff.staff = {"Produce": {"speed": 0, "carry": 0}}
	main.staff.sync_helpers()
	h.reset_for_new_shift()
	main.delivery.active = true
	main.delivery.reset_for_new_day()
	main.staff.reset_for_new_shift()
	main.delivery._truck_timer = 0.0
	await wait_until(func(): return main.delivery.deliveries_today >= 1, 5.0)
	check(not main.delivery.truck_load.has("Produce") and main.staff.boxes_diverted_today >= 1, "E3: the truck's Produce box went to the back stock, not the dock (load %s, diverted %d)" % [str(main.delivery.truck_load), main.staff.boxes_diverted_today])
	await wait_until(func(): return h.unpacked_today >= 1, 20.0)
	check(h.unpacked_today >= 1, "E3: the helper opened it on the pad (%d)" % h.unpacked_today)
	await wait_until(func(): return _produce_filled() >= 6, 90.0)
	check(_produce_filled() >= 6, "E3: ...and shelved it (%d on the shelves)" % _produce_filled())
	var receiving_produce := get_nodes_in_group("delivery_box").filter(func(b): return b.get_meta("section") == "Produce").size()
	check(receiving_produce == 0, "E3: no Produce box ever reached Storage (%d)" % receiving_produce)
	# Full back room: the box isn't brought at all.
	main.staff.backstock = {"Produce": main.staff.BACKSTOCK_MAX}
	var skipped0: int = main.staff.boxes_skipped_today
	var left: Array = main.staff.divert_boxes(["Produce", "Dry Goods"])
	check(left == ["Dry Goods"] and main.staff.boxes_skipped_today == skipped0 + 1 and main.staff.backstock_of("Produce") == main.staff.BACKSTOCK_MAX, "E4: a full back room (%d) turns the box away — load left %s" % [main.staff.BACKSTOCK_MAX, str(left)])
	# Let go: boxes come to the dock again.
	main.staff.staff = {}
	main.staff.sync_helpers()
	check(main.staff.divert_boxes(["Produce"]) == ["Produce"], "E5: nobody staffing Produce -> its boxes go to Storage again")
	finish()

## =============================================================================
## CO-OP — host + 2 clients (each its own process), one shared bank:
## a client walks to the board, opens ITS panel and hires through the host;
## every peer sees the same staff, back stock and helper; a forged request
## from across the store is refused; two clients hiring the same section in
## the same instant hire once and pay once; two clients buying the same
## upgrade in the same instant buy one level; wages on every peer's report.
##   godot ... -- --server --port=8973 --players=3 --day=5 --no-save --money=3000 --test=net-staff &
##   (x2) godot ... -- --client --connect-port=8973 --no-save --test=net-staff
## =============================================================================

func staff_view() -> Dictionary:
	var active := []
	for sec in st().HELPER_SECTIONS:
		if helper(sec).active:
			active.append(sec)
	return {"staff": st().staff, "active": active, "money": main.money, "owned": main.sections_owned}

func _staff_sync(ids: Array, tag: String) -> void:
	await wait(0.5)
	_step("sview", {"tag": tag, "view": JSON.parse_string(JSON.stringify(staff_view()))})
	var ans := await _answers(ids)
	for id in ans:
		check(ans[id].get("ok", false), "%s: %s sees the host's staff%s" % [tag, main.player_display_name(id), ans[id].get("why", " (no answer)")])

func _run_net_staff_host() -> void:
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
	check(main.players.size() == want and main.money == 3000 and main.sections_owned == 3 and st().staff.is_empty(), "C0: %d players, bank %s, 3 sections, nobody hired" % [main.players.size(), main._format_money(main.money)])
	_step("hello")
	await _answers(ids)
	await _staff_sync(ids, "C0")
	# C1 a client walks up, E opens THEIR panel (nobody else's), Hire -> host
	_step("hire", {"who": ids[1], "sec": "Produce"})
	var ans := await _answers(ids)
	check(not st().panel.visible, "C1: the host's own panel stayed shut")
	for id in ans:
		if id == ids[1]:
			check(ans[id].get("panel", false), "C1: %s's E at the board opened their panel" % main.player_display_name(id))
			check(str(ans[id].get("toast", "")).begins_with("You hired Sam"), "C1: %s's toast: '%s'" % [main.player_display_name(id), ans[id].get("toast", "")])
		else:
			check(not ans[id].get("panel", true), "C1: %s's panel stayed shut" % main.player_display_name(id))
	check(st().is_hired("Produce") and main.money == 3000 - st().HIRE_FEE["Produce"] and st().actions_done == 1, "C1: %s hired Sam through the host — bank %s" % [main.player_display_name(ids[1]), main._format_money(main.money)])
	await _staff_sync(ids, "C1")
	# C2 a forged request from the break room's far side is refused
	var refused0: int = st().actions_refused
	_step("forge", {"who": ids[2]})
	await _answers(ids)
	await wait(0.6)
	check(not st().is_hired("Dairy/Frozen") and st().actions_refused == refused0 + 1, "C2: %s asked to hire from across the room -> refused" % main.player_display_name(ids[2]))
	# C3 the race: both clients, at the board, hire Dairy/Frozen in one instant
	var m0: int = main.money
	var done0: int = st().actions_done
	refused0 = st().actions_refused
	_step("race", {"sec": "Dairy/Frozen", "action": "hire", "at": Time.get_unix_time_from_system() + 2.0})
	await _answers(ids)
	await wait(1.0)
	check(st().is_hired("Dairy/Frozen") and st().actions_done == done0 + 1 and main.money == m0 - st().HIRE_FEE["Dairy/Frozen"], "C3: two clients hired Alex in the same instant -> hired ONCE, charged once (bank %s)" % main._format_money(main.money))
	check(st().actions_refused == refused0 + 1, "C3: ...the other request reached the host and was refused (+%d)" % (st().actions_refused - refused0))
	await _staff_sync(ids, "C3")
	# C4 the upgrade race: both press "Faster" (from level 1) at one instant
	m0 = main.money
	done0 = st().actions_done
	_step("race", {"sec": "Produce", "action": "speed", "at": Time.get_unix_time_from_system() + 2.0})
	await _answers(ids)
	await wait(1.0)
	check(st().speed_level("Produce") == 1 and main.money == m0 - st().SPEED_COSTS[0] and st().actions_done == done0 + 1, "C4: two clients bought the same speed upgrade in one instant -> ONE level, $%d once (bank %s)" % [st().SPEED_COSTS[0], main._format_money(main.money)])
	await _staff_sync(ids, "C4")
	# C5 the helper on every screen: where the host has it, carrying what it carries
	await wait_until(func(): return not helper("Produce")._held().is_empty(), 30.0)
	var h := helper("Produce")
	var held: Array = h._held()
	_step("helper", {"sec": "Produce", "pos": [h.position.x, h.position.y], "item": String(held[0].name) if not held.is_empty() else ""})
	ans = await _answers(ids)
	for id in ans:
		check(ans[id].get("ok", false), "C5: %s sees Sam working Produce, carrying stock%s" % [main.player_display_name(id), ans[id].get("why", "")])
	# C6 payday on every peer
	main.test_hold_customers = true
	main.prep_time_left = 0.0
	await wait_until(func(): return main.store_open, 3.0)
	add_sales(20)
	m0 = main.money
	main.shift_time_left = 0.01
	await wait_until(func(): return main.is_day_report_active(), 200.0)
	await wait(0.5)
	var pay: int = main._pay_today()
	var wages: int = st().WAGE["Produce"] + st().WAGE["Dairy/Frozen"]
	check(main.money == m0 + pay - wages and st().wages_today == wages, "C6: payday — pay %s, wages $%d, bank %s" % [main._format_money(pay), wages, main._format_money(main.money)])
	_step("report", {"pay": main.report_pay_label.text})
	ans = await _answers(ids)
	for id in ans:
		check(ans[id].get("ok", false), "C6: %s's report shows the same pay + wages%s" % [main.player_display_name(id), ans[id].get("why", "")])
	await _staff_sync(ids, "C6")
	# C7 next shift: both still on staff, on the floor everywhere
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 6.0)
	await wait(0.5)
	check(st().on_books.size() == 2 and helper("Produce").active and helper("Dairy/Frozen").active, "C7: next shift — both helpers on the books and on the floor")
	await _staff_sync(ids, "C7")
	_step("done")
	await _answers(ids)
	finish()

func _run_net_staff_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 30.0)
	me = main.multiplayer.get_unique_id()
	act = "client_"
	var who: String = main.player_display_name(me)
	var n := 0
	while true:
		n += 1
		var step := await _net_read("ec_%d.json" % n, 600.0)
		var kind: String = step.get("kind", "")
		var ans := {}
		match kind:
			"sview":
				var theirs: Dictionary = step["view"]
				var ok := await wait_until(func(): return _canon(staff_view()) == _canon(theirs), 8.0)
				ans = {"ok": ok, "why": "" if ok else " — mine %s vs host %s" % [_canon(staff_view()), _canon(theirs)]}
			"hire":
				if int(step["who"]) == me:
					player().teleport_to(st().BOARD_SPOT)
					await wait(0.5)
					await tap(act + "interact")
					await wait(0.3)
					ans["panel"] = st().panel.visible
					await press_button("%s:hire" % step["sec"])
					await wait_until(func(): return st().is_hired(step["sec"]), 4.0)
					await wait(0.3)
					ans["toast"] = main._toast_label.text
					await tap(act + "interact") # close it again
				else:
					await wait(1.5)
					ans["panel"] = st().panel.visible
			"forge":
				if int(step["who"]) == me:
					player().teleport_to(Vector2(800, 400))
					await wait(0.4)
					st()._request_staff.rpc_id(1, "Dairy/Frozen", "hire", -1)
			"race":
				player().teleport_to(st().BOARD_SPOT + Vector2(0, -25 + 50 * (main.players.keys().find(me) % 2)))
				await wait(0.5)
				var lvl: int = st()._level_of(step["sec"], step["action"])
				while Time.get_unix_time_from_system() < float(step["at"]):
					await physics_frame
				# Straight to the host, both on the same instant (a click is this RPC).
				st()._request_staff.rpc_id(1, step["sec"], step["action"], lvl)
				await wait(0.5)
			"helper":
				var h := helper(step["sec"])
				var host_pos := Vector2(step["pos"][0], step["pos"][1])
				var item: Node2D = main.get_node_or_null("Products/" + str(step["item"])) if step["item"] != "" else null
				var ok: bool = h.visible and h.position.distance_to(host_pos) < 120.0 and main._grid_cell_of(h.position) == main._grid_cell_of(host_pos)
				var why := ""
				if not ok:
					why = " — visible %s at %s vs host %s" % [str(h.visible), str(h.position.round()), str(host_pos.round())]
				if item != null and ok:
					var near := await wait_until(func(): return is_instance_valid(item) and item.global_position.distance_to(h.position) < 70.0, 2.0)
					ok = near
					if not near and is_instance_valid(item):
						why = " — its item %s at %s, helper at %s" % [item.name, str(item.global_position.round()), str(h.position.round())]
				ans = {"ok": ok, "why": why}
			"report":
				var ok := await wait_until(func(): return main.report_layer.visible and main.report_pay_label.text == step["pay"], 8.0)
				ans = {"ok": ok, "why": "" if ok else " — mine '%s' vs '%s'" % [main.report_pay_label.text, step["pay"]]}
			"done":
				_net_write("ec_%d_%d.json" % [n, me], {})
				finish()
				return
		_net_write("ec_%d_%d.json" % [n, me], ans)

## =============================================================================
## SAVES — helpers are new state, so old saves need handling:
## 1: a Phase-2 (version 2) save, 3 sections, $2000 -> loads fine, nobody
##    hired; hire two, train one; the save on disk is version 3 with "staff".
## 2: relaunch -> the same staff and levels, on the floor and on the books.
## 3: a hand-edited version-3 save (a helper for a section the shop doesn't
##    own, levels out of range, junk) -> cleaned up on load.
##   godot ... -- --server --save-file=user://staff_test/save.json --test=save --phase=1   (then 2, 3)
## =============================================================================

const V2_SAVE := {
	"version": 2, "saved_at": "2026-10-03T20:00:00",
	"shop": {"completed_day": 6, "money": 2000, "lifetime_earned": 2600, "sections_owned": 3, "stage": 4, "lifetime_sold": 300},
	"endless": {"unlocked": false, "wallet": 0, "upgrades": {}, "shift_number": 0, "run_stats": {"shifts": 0, "sold": 0, "bucks": 0, "medals": [0, 0, 0, 0]}, "week_summary": {}},
}

func _prepare_staff_save_phase() -> void:
	var path := _save_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if _phase() == 1 or _phase() == 3:
		for f in [path, path + ".tmp", path + ".bad", path + ".v1.bak"]:
			if FileAccess.file_exists(f):
				DirAccess.remove_absolute(f)
		var data: Dictionary = V2_SAVE.duplicate(true)
		if _phase() == 3:
			data["version"] = 3
			data["staff"] = {"Produce": {"speed": 9, "carry": -3}, "Bakery": {"speed": 1, "carry": 1}, "Dry Goods": {"speed": 1}, "Dairy/Frozen": "junk"}
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(JSON.stringify(data, "\t"))
		f.close()

func _run_staff_save() -> void:
	var path := _save_path()
	await wait_until(func(): return main.shift_active, 20.0)
	await wait(0.5)
	var SG = load("res://SaveGame.gd")
	match _phase():
		1:
			check(main.load_status == SG.LOAD_OK and main.current_day == 7 and main.money == 2000 and main.sections_owned == 3, "V1: a Phase-2 (version 2) save loads — Day %d, bank %s, %d sections" % [main.current_day, main._format_money(main.money), main.sections_owned])
			check(st().staff.is_empty() and st().helpers.values().all(func(h): return not h.active), "V1: ...with nobody hired")
			check(st().do_action("Produce", "hire", 1) and st().do_action("Dairy/Frozen", "hire", 1) and st().do_action("Produce", "speed", 1) and st().do_action("Produce", "carry", 1) and st().do_action("Produce", "carry", 1), "V1: hired Sam (speed 2, carry 3) and Alex")
			var disk := _read_json(path)
			check(int(disk.get("version", 0)) == SG.VERSION and SG.VERSION >= 3, "V1: the save on disk is version %d" % int(disk.get("version", 0)))
			var ds: Dictionary = disk.get("staff", {})
			check(ds.size() == 2 and int(ds.get("Produce", {}).get("speed", -1)) == 1 and int(ds.get("Produce", {}).get("carry", -1)) == 2 and int(ds.get("Dairy/Frozen", {}).get("speed", -1)) == 0, "V1: ...with the staff in it (%s)" % str(ds))
			check(int(disk.get("shop", {}).get("money", 0)) == main.money, "V1: and the bank after paying for them (%s)" % main._format_money(main.money))
		2:
			check(main.load_status == SG.LOAD_OK, "V2: relaunch loads the version-3 save")
			check(st().is_hired("Produce") and st().is_hired("Dairy/Frozen") and not st().is_hired("Bakery"), "V2: Sam and Alex are still on staff (%s)" % str(st().staff))
			check(st().speed_level("Produce") == 1 and st().carry_level("Produce") == 2 and st().speed_level("Dairy/Frozen") == 0, "V2: with their training")
			check(helper("Produce").active and helper("Dairy/Frozen").active and helper("Produce").speed == st().SPEED_BY_LEVEL[1] and helper("Produce").capacity == st().CARRY_BY_LEVEL[2], "V2: on the floor at their levels")
			check(st().on_books.has("Produce") and st().on_books.has("Dairy/Frozen") and st().wages_due() == st().WAGE["Produce"] + st().WAGE["Dairy/Frozen"], "V2: on this shift's books ($%d due)" % st().wages_due())
		3:
			check(main.load_status == SG.LOAD_OK, "V3: a hand-edited save still loads")
			check(st().staff.keys() == ["Produce"], "V3: only the owned, hireable section's helper is kept (%s)" % str(st().staff))
			check(st().speed_level("Produce") == st().SPEED_BY_LEVEL.size() - 1 and st().carry_level("Produce") == 0, "V3: levels clamped (speed %d, carry %d)" % [st().speed_level("Produce"), st().carry_level("Produce")])
			check(helper("Produce").active and not helper("Bakery").active, "V3: Sam works Produce; nobody in the unowned Bakery")
	finish()

## =============================================================================
## HAZARDS — helpers among everything else (the top tier, --day=7: the
## forklift hot, the manager, priority orders, lights + spills, the biggest
## crowd), with the solo bot playing Dry Goods. A watcher runs every physics
## frame for the whole shift: a helper never overlaps the Produce forklift's
## body, never leaves its room, never stands stuck with work to do; nobody
## but a player ever gets written up; every staffed section sells.
##   godot --headless --path . --script res://tools/staff_test.gd -- --server --day=7 --no-save --test=hazards [--hire=...]
## =============================================================================

var _watch := {}
var _watching := false

func _watch_helpers() -> void:
	_watching = true
	_watch = {"frames": 0, "fk_overlap": 0, "fk_close": 0, "out_of_room": 0, "stuck": 0, "stuck_what": [], "max_still": 0.0}
	var last := {}
	var still := {}
	while _watching:
		await physics_frame
		if not main.shift_active or main.is_day_report_active():
			continue
		_watch["frames"] += 1
		_watch["rams"] = maxi(int(_watch.get("rams", 0)), fk().rams_today) # (zeroed when it parks for cleanup)
		for sec in st().HELPER_SECTIONS:
			var h := helper(sec)
			if not h.active:
				continue
			if not h._room.has_point(h.position):
				_watch["out_of_room"] += 1
			if h._in_forklift(h.position, 2.0):
				_watch["fk_overlap"] += 1
				if _watch["fk_overlap"] <= 3:
					print("INFO  WATCH %s inside the forklift's body at %s (forklift %s, rot %.2f, v %.0f)" % [sec, str(h.position.round()), str(fk().global_position.round()), fk().rotation, fk().velocity.length()])
			elif h._in_forklift(h.position, 20.0):
				_watch["fk_close"] += 1
			# Stuck: has a job that isn't waiting, isn't mid-action, and hasn't
			# moved in 8s — and isn't giving way to the forklift.
			var busy: bool = not h._job.is_empty() and h._job["kind"] != "home" and h._pause <= 0.0 and not main.cleanup_active
			var moved: bool = last.has(sec) and h.position.distance_to(last[sec]) > 0.5
			last[sec] = h.position
			var giving_way: bool = h._forklift_live() != null and h.position.distance_to(fk().global_position) < h.FORKLIFT_YIELD + 40.0
			if busy and not moved and not giving_way:
				still[sec] = still.get(sec, 0.0) + 1.0 / 60.0
				_watch["max_still"] = maxf(_watch["max_still"], still[sec])
				if still[sec] > 8.0:
					_watch["stuck"] += 1
					_watch["stuck_what"].append("%s %s at %s" % [sec, h._job["kind"], str(h.position.round())])
					still[sec] = -1000.0 # once per episode
			elif moved or not busy:
				still[sec] = 0.0

func _watch_checks(tag: String) -> void:
	_watching = false
	print("INFO  WATCH %s: %s" % [tag, str(_watch)])
	check(_watch["frames"] > 600, "%s: watched %d frames of shift" % [tag, _watch["frames"]])
	check(_watch["fk_overlap"] == 0, "%s: no helper ever inside the forklift's body (%d frames; within 20px of it %d)" % [tag, _watch["fk_overlap"], _watch["fk_close"]])
	check(_watch["out_of_room"] == 0, "%s: helpers never left their sections (%d frames)" % [tag, _watch["out_of_room"]])
	check(_watch["stuck"] == 0, "%s: no helper stuck with work to do (episodes %d %s, longest still %.1fs)" % [tag, _watch["stuck"], str(_watch["stuck_what"]), _watch["max_still"]])

func _run_staff_hazards() -> void:
	_hire_spec = _parse_hire()
	if _hire_spec.is_empty():
		_hire_spec = {"Produce": {"speed": 0, "carry": 0}, "Dairy/Frozen": {"speed": 0, "carry": 0}, "Bakery": {"speed": 0, "carry": 0}}
	await wait_until(func(): return main.players.has(1), 20.0)
	main.staff.staff = _hire_spec.duplicate(true)
	await wait_until(func(): return main.shift_active, 20.0)
	stats = {"placed": 0, "hits": 0, "watched_s": 0.0, "idle_s": 0.0, "reasons": {}, "wrecks": 0, "overlap": 0, "banner_and_busy_s": 0.0, "banner_clash": 0, "first_customer_s": -1.0, "shift_len": main.shift_time_left, "grace": main.prep_time_left, "slip_s": 0.0}
	_haul = {"walk_px": 0.0, "last_pos": null, "box_t": {}, "carry_s": [], "item_born": {}, "item_s": [], "box_items": {}, "box_cycle_s": [], "seen": {}, "last_event": dl().unpack_event_id, "last_carry": null, "open_placed": 0, "open_called": 0, "item_carry": null, "last_pos_c": null, "carry_item_s": [], "carry_item_px": []}
	check(main.complication_stage == main.STAGE_RUSH and fk().active and mgr().active, "Z0: the top tier — forklift and manager on (stage %d)" % main.complication_stage)
	check(st().helpers.values().all(func(h): return h.active), "Z0: all three helpers on the floor")
	for h in st().helpers.values():
		check(not h.is_in_group("customer") and not h.is_in_group("player") and h.carry_id < -999999, "Z0: %s is staff — not a customer, not a player, its own carry id (%d)" % [h.helper_name, h.carry_id])
	# Opened 4 minutes in (the way a crew with its aisles staffed plays), so
	# the forklift and the crowd get minutes with the helpers, not the 96s a
	# ceiling opening leaves.
	_open_after = 240.0
	_open_at(_open_after)
	_watch_helpers()
	await _play_shift()
	var rams: int = int(_watch.get("rams", 0)) # the watcher's peak: it's zeroed as the store closes
	for o in get_nodes_in_group("carryable"):
		if o.get_node("Carryable").carrier_id == me:
			await tap(act + "interact")
	await _play_cleanup(false, true)
	await wait_until(func(): return main.is_day_report_active(), 200.0)
	await wait(0.3)
	_watch_checks("Z1")
	for peer in main.writeups_by_peer:
		check(main.players.has(peer), "Z2: write-up for %s — a player" % main.player_display_name(peer))
	print("INFO  writeups %d, rams %d, sold by section %s, selling window %.0fs" % [main.writeups_today, rams, str(main.sold_by_section_today), stats["shift_len"] - stats.get("opened_at", 0.0)])
	for sec in _hire_spec:
		var h := helper(sec)
		print("INFO  %s: placed %d, unpacked %d, knocked stock reshelved %d, forklift yield %.1fs, walked %.0fpx" % [sec, h.placed_today, h.unpacked_today, h.knocked_reshelved_today, h.forklift_yield_s, h.walked_px])
		# (Sales are reported, not required: shoppers take the NEAREST stocked
		# item — Customer.gd — so the far Bakery sells next to nothing while the
		# nearer aisles are stocked. Found here; flagged in the Phase 3 report.)
		check(h.placed_today > 0, "Z3: %s's helper shelved %d (the section sold %d)" % [sec, h.placed_today, int(main.sold_by_section_today.get(sec, 0))])
	check(rams > 0, "Z4: the forklift rammed shelves this shift (%d) — the helpers worked through it" % rams)
	finish()

## =============================================================================
## SOAK — one long session, all three helpers on staff, the top tier, N
## consecutive shifts (tools/economy_test.gd's soak: the crew keeps every
## UNSTAFFED shelf stocked all shift, the helpers do theirs). Node/object/
## memory/frame drift per shift, the hazard watcher throughout, and the
## helpers keep working every shift.
##   godot --headless --path . --script res://tools/staff_test.gd -- --server --day=7 --no-save --shifts=8 --prep-seconds=180 --test=soak [--hire=...]
## (--prep-seconds keeps each shift ~5 min: the store opens at once, so the
## whole clock is selling time; the default 12-min prep makes it ~2 hours.)
## =============================================================================

## The crew leaves staffed sections to their helpers.
func _soak_crew() -> void:
	while main.shift_active and not main.cleanup_active:
		for s in main._unlocked_sections():
			var n: String = s["name"]
			if st().is_hired(n):
				continue
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

func _counts() -> Dictionary:
	var c: Dictionary = super()
	var placed := 0
	for h in st().helpers.values():
		placed += h.placed_today if h.active else 0
	c["helper_placed"] = placed
	c["helpers"] = st().helpers.values().filter(func(h): return h.active).size()
	c["wages"] = st().wages_today
	c["staffed_sold"] = 0
	for sec in st().HELPER_SECTIONS:
		c["staffed_sold"] += int(main.sold_by_section_today.get(sec, 0))
	# OCT 2026 PHASE 3D: what's lying about (the soak crew never cleans).
	if main.get("store_rating") != null:
		c["litter"] = main.cleanup.litter.size()
		c["puddles"] = main.cleanup.puddles.size()
		c["full_cans"] = main.cleanup.full_cans()
		c["bags"] = main.cleanup.bags.size()
		c["rating"] = snappedf(main.store_rating.rating, 0.01)
		c["cap"] = main.customer_cap()
	return c

func _run_staff_soak() -> void:
	_hire_spec = _parse_hire()
	if _hire_spec.is_empty():
		_hire_spec = {"Produce": {"speed": 0, "carry": 0}, "Dairy/Frozen": {"speed": 0, "carry": 0}, "Bakery": {"speed": 0, "carry": 0}}
	await wait_until(func(): return main.players.has(1), 20.0)
	main.staff.staff = _hire_spec.duplicate(true)
	_watch_helpers()
	_soak_staff_checks()
	await _run_soak()

## Per shift, at each report (alongside economy_test's own per-shift row).
func _soak_staff_checks() -> void:
	var seen := 0
	while true:
		await wait_until(func(): return main.is_day_report_active(), 100000.0)
		await wait(0.2)
		seen += 1
		var placed := []
		for sec in _hire_spec:
			placed.append(helper(sec).placed_today)
		check(placed.all(func(n): return n > 0) and st().wages_today == _hire_spec.keys().reduce(func(a, k): return a + int(st().WAGE[k]), 0), "SOAK shift %d: every helper worked (%s placed), wages $%d charged" % [seen, str(placed), st().wages_today])
		await wait_until(func(): return not main.is_day_report_active(), 100000.0)

func finish() -> void:
	if _watching:
		_watch_checks("SOAK" if _mode == "soak" else "WATCH")
	super()

## Debug probe: one section's helper alone, no customers — where does its stock go?
func _run_probe() -> void:
	var sec := "Bakery"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--sec="):
			sec = a.substr(6)
	await wait_until(func(): return main.players.has(1), 20.0)
	main.staff.staff = {sec: {"speed": 2, "carry": 0}}
	await wait_until(func(): return main.shift_active, 20.0)
	main.test_hold_customers = true
	var h := helper(sec)
	for i in 12:
		await wait(10.0)
		var fill := []
		for sb in h._shelves():
			fill.append("%s:%d/%d%s" % [sb.name, sb.get_node("Shelf").filled_count(), sb.get_node("Shelf").slot_count(), "W" if sb.get_node("Shelf").wrecked else ""])
		var loose: Array = h._loose_items()
		print("INFO  probe t=%d placed %d picked %d unpacked %d job %s pos %s fill %s loose %d %s empty %d" % [(i + 1) * 10, h.placed_today, h.picked_today, h.unpacked_today, h._job.get("kind", "-"), str(h.position.round()), str(fill), loose.size(), str(loose.map(func(o): return o.global_position.round())), h._empty_slots().size()])
	finish()
