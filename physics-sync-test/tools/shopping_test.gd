extends "res://tools/economy_test.gd"
## OCT 2026 PHASE 3B — SHOPPING LISTS AND CARTS (Customer.gd's shopping_list /
## cart, Main.gd's make_shopping_list(), Cashier.gd ringing up a cart). Reuses
## tools/economy_test.gd's helpers (and through it tools/hazards_test.gd's)
## and drives the real Main.tscn through the real game code. Not part of the
## game. Real wall-clock time throughout (no --fixed-fps).
##
## LISTS — what make_shopping_list() can draw: only open + stocked sections,
## the tier's length bounds, no more of a section than its shelves hold, and
## spread evenly across sections (Bakery as likely as Dry Goods):
##   godot --headless --path . --script res://tools/shopping_test.gd -- --server --day=7 --no-save --test=lists
## PURCHASE — one shopper at a time, by hand-made list: it collects exactly
## what's on the list into its cart, checks out once, the register rings each
## item as its own sale; sold-out items wait LIST_PATIENCE then get crossed
## off (or picked up if restocked meanwhile); an empty cart leaves without a
## sale; out of time mid-list checks out instead of dumping the cart; a forced
## leave drops the whole cart as plain (not knocked) stock; the cart, its
## contents and the list bubble as drawn:
##   godot --headless --path . --script res://tools/shopping_test.gd -- --server --day=7 --no-save --test=purchase
## TRAFFIC — THE REGRESSION THIS PHASE EXISTS FOR. Every section owned and
## kept fully stocked by the test, the store open with the real crowd for
## --seconds=N (default 300): what each section sells. Before this phase
## Bakery (the farthest from the door) sold 0-7 a shift while Produce/Dairy
## sold 40+. Also watches pathing (shoppers that stop making progress), the
## registers, and the forklift/manager/spills/disruptive crowd on top:
##   godot --headless --path . --script res://tools/shopping_test.gd -- --server --day=7 --no-save --test=traffic [--seconds=300] [--hire=...]
## CO-OP (host + 2 clients): every peer sees each shopper's list, its cart and
## what's in it, the list bubble shrinking as items go in, the checkout, and
## the same lists across a live crowd:
##   godot ... -- --server --port=8975 --players=3 --day=7 --no-save --test=net-shopping &
##   (x2) godot ... -- --client --connect-port=8975 --no-save --test=net-shopping
## SHOTS — a shopper with its cart and list for a look (needs a display):
##   xvfb-run -a godot --path . --script res://tools/shopping_test.gd -- --server --day=7 --no-save --test=shots


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--test="):
			_mode = a.substr(7)
	shots = _mode == "shots" and DisplayServer.get_name() != "headless"
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	careless = true
	main.cleanup_ceiling_override = 0.0
	var client := "--client" in args
	match _mode:
		"lists": _run_lists.call_deferred()
		"purchase": _run_purchase.call_deferred()
		"traffic": _run_traffic.call_deferred()
		"shots": _run_shots.call_deferred()
		"net-shopping": (_run_net_shop_client if client else _run_net_shop_host).call_deferred()
		_:
			print("FAIL  unknown --test=%s" % _mode)
			quit(1)

## --- helpers ------------------------------------------------------------------

func shelves_of(sec: String) -> Array:
	var cell: Vector2i = section_by_name(sec)["grid_pos"]
	return main.shelves.filter(func(sb): return main._grid_cell_of(sb.global_position) == cell)

func stocked_in(sec: String) -> int:
	var n := 0
	for sb in shelves_of(sec):
		n += _filled(sb.get_node("Shelf")).size()
	return n

## Shelf.filled_objects(), or the same read on a pre-3B Shelf.gd (so TRAFFIC
## can measure clean main for the before/after comparison).
func _filled(shelf: Node) -> Array:
	if shelf.has_method("filled_objects"):
		return shelf.filled_objects()
	return shelf._occupant.filter(func(o): return o != null and is_instance_valid(o))

func slots_in(sec: String) -> int:
	var n := 0
	for sb in shelves_of(sec):
		n += sb.get_node("Shelf").slots.size()
	return n

## Spawns a new unit straight onto every empty slot of a section (up to
## `limit` units) and waits for the shelves to count them.
func fill_section(sec: String, limit := 999) -> void:
	var want := mini(slots_in(sec), stocked_in(sec) + limit)
	for sb in shelves_of(sec):
		var shelf: Node = sb.get_node("Shelf")
		if shelf.wrecked:
			continue
		for i in shelf.slots.size():
			if stocked_in(sec) + _pending >= want:
				break
			var occ = shelf._occupant[i]
			var empty: bool = occ == null or not is_instance_valid(occ) or occ.is_queued_for_deletion()
			if empty and not _slot_claimed(shelf.slots[i].global_position):
				main.spawn_product_at(sec, shelf.slots[i].global_position)
				_claimed.append(shelf.slots[i].global_position)
				_pending += 1
	await wait_until(func(): return stocked_in(sec) >= want, 4.0)
	_pending = 0
	_claimed.clear()

var _pending := 0
var _claimed: Array = []
func _slot_claimed(p: Vector2) -> bool:
	return _claimed.any(func(q): return q.distance_to(p) < 4.0)

## Takes every unit off a section's shelves (freed, like a sale).
func empty_section(sec: String) -> void:
	for sb in shelves_of(sec):
		for o in _filled(sb.get_node("Shelf")):
			o.queue_free()
	await wait_until(func(): return stocked_in(sec) == 0, 3.0)
	await wait(0.2) # the shelves notice the empty slots

## Frees every free-standing (unshelved, uncarried) product — so a test's
## counts are only about the shelves.
func clear_loose_stock() -> void:
	for o in get_nodes_in_group("carryable"):
		if o.is_in_group("delivery_box") or o.get_node("Carryable").carrier_id != 0 or _is_placed(o):
			continue
		o.queue_free()
	await physics_frame

func shoppers() -> Array:
	return get_nodes_in_group("customer").filter(func(c): return c.role == "shopper" and not c.is_queued_for_deletion())

## One shopper with a hand-made list, walked in through the real spawner
## (the same data Main.gd's _spawn_customer() sends every peer).
func spawn_shopper(list: Array) -> Node:
	var cid: int = main._next_customer_carry_id
	main._next_customer_carry_id -= 1
	main.customer_spawner.spawn({
		"index": main._customer_spawn_index,
		"pos": main._store_entrance_pos(),
		"role": "shopper",
		"carry_id": cid,
		"items_target": list.size(),
		"list": PackedStringArray(list),
		"look": 1,
	})
	main._customer_spawn_index += 1
	await physics_frame
	for c in get_nodes_in_group("customer"):
		if c.carry_id == cid:
			return c
	return null

func sold_now() -> int:
	return main._total_sold()

func sold_of(sec: String) -> int:
	return int(main.sold_by_section_today.get(sec, 0))

func sorted(a: Array) -> Array:
	var b := a.duplicate()
	b.sort()
	return b

## A Day-7 floor, open, nobody else shopping, the clocks parked.
func quiet_open_store() -> void:
	await wait_until(func(): return main.shift_active, 30.0)
	await wait(0.5)
	main.test_hold_customers = true
	main.prep_time_left = 9999.0
	main.shift_time_left = 99999.0
	main.open_store(1)
	await wait_until(func(): return main.store_open, 3.0)
	for c in get_nodes_in_group("customer"):
		c.force_leave()
	# Park the hazards out of the way: this is about lists, not chaos.
	main.forklift.set_physics_process(false)
	main.manager.set_physics_process(false)
	await clear_loose_stock()
	await wait(0.3)

## =============================================================================
## LISTS
## =============================================================================

func _draw_lists(n: int) -> Array:
	var out := []
	for i in n:
		out.append(Array(main.make_shopping_list()))
	return out

func _run_lists() -> void:
	await quiet_open_store()
	for sec in ["Dry Goods", "Produce", "Dairy/Frozen", "Bakery"]:
		await empty_section(sec)
	check(main.sections_owned == 4, "L0: Day 7 economy — all four sections owned")
	# L1 nothing stocked -> no list
	check(main.make_shopping_list().is_empty(), "L1: nothing stocked -> an empty list (the shopper browses and asks again)")
	# L2 only Dry Goods stocked -> only Dry Goods, at most MAX_PER_SECTION
	await fill_section("Dry Goods")
	var lists := _draw_lists(200)
	check(lists.all(func(l): return l.all(func(s): return s == "Dry Goods")), "L2: only Dry Goods stocked -> every list is Dry Goods only")
	check(lists.all(func(l): return l.size() >= 1 and l.size() <= main.SHOPPING_LIST_MAX_PER_SECTION), "L2: ...each 1..%d long (capped per section)" % main.SHOPPING_LIST_MAX_PER_SECTION)
	# L3 one Bakery unit on the shelves (and Dry Goods) -> Bakery at most once
	await fill_section("Bakery", 1)
	check(stocked_in("Bakery") == 1, "L3: exactly one Bakery unit on its shelves")
	lists = _draw_lists(200)
	check(lists.all(func(l): return l.count("Bakery") <= 1), "L3: a list never wants more Bakery than its shelves hold (1)")
	check(lists.any(func(l): return "Bakery" in l), "L3: ...but Bakery does appear")
	# L4 everything stocked: tier bounds, per-section cap, spread
	for sec in ["Produce", "Dairy/Frozen", "Bakery"]:
		await fill_section(sec)
	var bounds: Array = main.SHOPPING_LIST_BY_TIER[3]
	lists = _draw_lists(1000)
	var lens := {}
	var share := {}
	var total := 0
	var with_sec := {}
	for l in lists:
		lens[l.size()] = lens.get(l.size(), 0) + 1
		for s in l:
			share[s] = share.get(s, 0) + 1
			total += 1
		for s in sorted(l).reduce(func(acc, x): return acc if x in acc else acc + [x], []):
			with_sec[s] = with_sec.get(s, 0) + 1
	print("INFO lists (all stocked): lengths %s, entries by section %s, lists with each section %s" % [str(lens), str(share), str(with_sec)])
	check(lists.all(func(l): return l.size() >= int(bounds[0]) and l.size() <= int(bounds[1])), "L4: every list is %d..%d long (tier 4)" % [bounds[0], bounds[1]])
	check(lens.size() == int(bounds[1]) - int(bounds[0]) + 1, "L4: ...and every length in that range comes up")
	check(lists.all(func(l): return main.SECTIONS.all(func(s): return l.count(s["name"]) <= main.SHOPPING_LIST_MAX_PER_SECTION)), "L4: no section more than %d times on a list" % main.SHOPPING_LIST_MAX_PER_SECTION)
	for s in ["Dry Goods", "Produce", "Dairy/Frozen", "Bakery"]:
		var f := float(share.get(s, 0)) / maxf(1.0, total)
		check(f > 0.20 and f < 0.30, "L4: %s is %.1f%% of all entries (even spread: 25%%)" % [s, f * 100.0])
	check(lists.all(func(l): return sorted(l).reduce(func(acc, x): return acc if x in acc else acc + [x], []).size() == mini(l.size(), 4)), "L4: distinct sections before any repeat (a 3-item list = 3 sections)")
	# L5 Bakery owned but empty -> never on a list
	await empty_section("Bakery")
	lists = _draw_lists(300)
	check(lists.all(func(l): return not "Bakery" in l), "L5: Bakery owned but sold out -> never on a list")
	# L6 an unowned section never appears, even with stock on its shelves
	await fill_section("Bakery")
	main.sections_owned = 3
	await wait(0.3) # (the gates reconfigure on the next frame)
	lists = _draw_lists(300)
	check(lists.all(func(l): return not "Bakery" in l), "L6: Bakery not owned (stock on its shelves) -> never on a list")
	check(lists.all(func(l): return l.size() >= int(main.SHOPPING_LIST_BY_TIER[2][0]) and l.size() <= int(main.SHOPPING_LIST_BY_TIER[2][1])), "L6: ...and lists take the 3-section tier's length %s" % str(main.SHOPPING_LIST_BY_TIER[2]))
	main.sections_owned = 1
	await wait(0.3)
	lists = _draw_lists(200)
	check(lists.all(func(l): return l.size() >= 1 and l.size() <= int(main.SHOPPING_LIST_BY_TIER[0][1]) and l.all(func(s): return s == "Dry Goods")), "L7: one section owned -> Dry Goods lists, %s long" % str(main.SHOPPING_LIST_BY_TIER[0]))
	main.sections_owned = 4
	await wait(0.3)
	# L8 real spawns carry a list, in the spawn data
	main.test_hold_customers = false
	await wait_until(func(): return shoppers().size() >= 4, 15.0)
	var all_listed := shoppers().all(func(c): return not c.shopping_list.is_empty() or not c.cart_items().is_empty() or c._checking_out)
	check(all_listed, "L8: real shoppers walk in with a list (%s)" % ", ".join(shoppers().map(func(c): return "%s:%s" % [c.name, ",".join(c.shopping_list)])))
	var reds := get_nodes_in_group("customer").filter(func(c): return c.role == "disruptive")
	check(reds.all(func(c): return c.shopping_list.is_empty() and c.get_node_or_null("Cart") == null and c.get_node_or_null("ListBubble") == null), "L8: disruptive customers have no list, cart or bubble (%d of them)" % reds.size())
	finish()

## =============================================================================
## PURCHASE
## =============================================================================

## Waits for a shopper to leave (freed); returns false on timeout.
func gone(c: Node, timeout: float) -> bool:
	return await wait_until(func(): return not is_instance_valid(c) or c.is_queued_for_deletion(), timeout)

## One line of a shopper's state (for the log, when a step fails).
func trace_shopper(c: Node) -> void:
	if not is_instance_valid(c) or c.is_queued_for_deletion():
		return
	var ci = c._committed_item
	print("TRACE %s pos=%s cell=%s list=%s cart=%d committed=%s at=%s life=%.1f/%.1f checking_out=%s wait=%.1f" % [c.name, str(c.global_position.round()), main._section_name_at(c.global_position), ",".join(c.shopping_list), c.cart_items().size(), ci.name if ci != null and is_instance_valid(ci) else "-", str(ci.global_position.round()) if ci != null and is_instance_valid(ci) else "-", c._lifetime, c._lifetime_budget, str(c._checking_out), c._list_wait])

func _run_purchase() -> void:
	await quiet_open_store()
	for sec in ["Dry Goods", "Produce", "Dairy/Frozen", "Bakery"]:
		await fill_section(sec)
	# P1 a three-section list: exactly those three into the cart, one checkout
	var sold0 := sold_now()
	var by0 := {}
	for s in ["Bakery", "Produce", "Dairy/Frozen", "Dry Goods"]:
		by0[s] = sold_of(s)
	var stock0 := {}
	for s in ["Bakery", "Produce", "Dairy/Frozen", "Dry Goods"]:
		stock0[s] = stocked_in(s)
	var c := await spawn_shopper(["Bakery", "Produce", "Dairy/Frozen"])
	check(c != null and c.get_node_or_null("Cart") != null and c.get_node_or_null("ListBubble") != null, "P1: the shopper walks in pushing a cart, a list bubble over its head")
	check(c._bubble.visible and _bubble_icons(c) == 3, "P1: the bubble shows 3 items (%d icons)" % _bubble_icons(c))
	var max_cart := 0
	var queued_items := -1
	var hidden_ok := true
	var bubble_tracks := true
	var t := 0.0
	while is_instance_valid(c) and not c.is_queued_for_deletion() and t < 150.0:
		var items: Array = c.cart_items()
		max_cart = maxi(max_cart, items.size())
		if c._checking_out and queued_items < 0:
			queued_items = items.size()
		await wait(0.25)
		t += 0.25
		if is_instance_valid(c) and not c.is_queued_for_deletion():
			for o in c.cart_items():
				if o.visible and c._cart_refresh <= 0.05:
					pass
			# the real items ride hidden; the basket draws a copy of each
			var now: Array = c.cart_items()
			if not now.is_empty() and now.any(func(o): return o.visible) and c._hidden_items.size() == now.size():
				hidden_ok = false
			if c._bubble_list != c.shopping_list:
				await wait(0.1)
				if is_instance_valid(c) and c._bubble_list != c.shopping_list:
					bubble_tracks = false
	var picked: Array = []
	check(t < 150.0, "P1: the shopper finished its trip and left (%.0fs)" % t)
	check(sold_now() - sold0 == 3, "P1: three sales rung up (%d)" % (sold_now() - sold0))
	for s in ["Bakery", "Produce", "Dairy/Frozen"]:
		check(sold_of(s) - by0[s] == 1, "P1: ...one %s sale" % s)
	check(sold_of("Dry Goods") == by0["Dry Goods"], "P1: ...and nothing it didn't want (no Dry Goods)")
	check(max_cart == 3 and queued_items == 3, "P1: all three were in the cart together, and it went to the register with all three (max %d, at checkout %d)" % [max_cart, queued_items])
	check(stocked_in("Bakery") == stock0["Bakery"] - 1 and stocked_in("Produce") == stock0["Produce"] - 1 and stocked_in("Dairy/Frozen") == stock0["Dairy/Frozen"] - 1 and stocked_in("Dry Goods") == stock0["Dry Goods"], "P1: one unit off each of those shelves, none off Dry Goods")
	check(hidden_ok, "P1: the items in the cart were hidden (drawn by the cart instead)")
	check(bubble_tracks, "P1: the bubble followed the list as items went in")
	check(main.cashiers.all(func(cb): return cb.get_node("Cashier").queue_length() == 0), "P1: no register left holding a queue entry")
	await clear_loose_stock()
	for sec in ["Produce", "Dairy/Frozen", "Bakery"]:
		await fill_section(sec)

	# P2 sold out mid-list: Produce empty -> Bakery bought, Produce crossed off after the wait
	await empty_section("Produce")
	sold0 = sold_now()
	var bak0 := sold_of("Bakery")
	c = await spawn_shopper(["Produce", "Bakery"])
	var t_cross := -1.0
	var t_cart := -1.0
	t = 0.0
	var skipped: Array = []
	var picked_p2: Array = []
	while is_instance_valid(c) and not c.is_queued_for_deletion() and t < 120.0:
		if t_cart < 0.0 and c.cart_items().size() == 1:
			t_cart = t
		if t_cross < 0.0 and not "Produce" in c.shopping_list and c.skipped_sections.has("Produce"):
			t_cross = t
		skipped = c.skipped_sections.duplicate()
		picked_p2 = c.picked_sections.duplicate()
		if fmod(t, 3.0) < 0.1:
			trace_shopper(c)
		await wait(0.1)
		t += 0.1
	check(sold_now() - sold0 == 1 and sold_of("Bakery") - bak0 == 1, "P2: Produce sold out -> it bought the Bakery item only (%d sale)" % (sold_now() - sold0))
	check(skipped == ["Produce"] and picked_p2 == ["Bakery"], "P2: ...Produce crossed off (skipped %s, picked %s)" % [str(skipped), str(picked_p2)])
	check(t_cross > 0.0 and t_cart > 0.0 and t_cross - t_cart >= main.CustomerScript.LIST_PATIENCE - 1.0, "P2: ...after waiting ~%.0fs for a restock (crossed off %.1fs after the Bakery pickup)" % [main.CustomerScript.LIST_PATIENCE, t_cross - t_cart])
	await clear_loose_stock()

	# P3 restocked during the wait: picked up after all, nothing crossed off
	sold0 = sold_now()
	c = await spawn_shopper(["Produce"])
	await wait(4.0)
	check(is_instance_valid(c) and c.cart_items().is_empty() and c.shopping_list.size() == 1, "P3: Produce sold out — the shopper waits (browsing), list intact")
	await fill_section("Produce", 1)
	var left := await gone(c, 90.0)
	check(left and sold_now() - sold0 == 1, "P3: one unit restocked mid-wait -> it fetched it and bought it (%d sale)" % (sold_now() - sold0))
	await clear_loose_stock()

	# P4 everything on the list sold out -> leaves with nothing, no sale, no mess
	await empty_section("Produce")
	sold0 = sold_now()
	c = await spawn_shopper(["Produce", "Produce"])
	var t0 := _wall()
	left = await gone(c, 60.0)
	var waited := _wall() - t0
	check(left and sold_now() == sold0, "P4: its whole list sold out -> it left without buying (%.0fs, %d sales)" % [waited, sold_now() - sold0])
	check(waited >= main.CustomerScript.LIST_PATIENCE - 1.0, "P4: ...after the %.0fs wait (%.1fs)" % [main.CustomerScript.LIST_PATIENCE, waited])
	await fill_section("Produce")

	# P5 out of time mid-list with a full cart -> checks out, nothing dropped
	sold0 = sold_now()
	c = await spawn_shopper(["Dairy/Frozen", "Bakery", "Produce"])
	await wait_until(func(): return is_instance_valid(c) and c.cart_items().size() >= 1, 60.0)
	c._lifetime_budget = c._lifetime - 1.0
	await physics_frame
	await physics_frame
	check(is_instance_valid(c) and not c.is_queued_for_deletion() and c._checking_out and c.shopping_list.is_empty(), "P5: out of time mid-list with %d in the cart -> crossed the rest off and went to check out" % (c.cart_items().size() if is_instance_valid(c) else -1))
	var in_cart: int = c.cart_items().size() if is_instance_valid(c) else 0
	left = await gone(c, 60.0)
	check(left and sold_now() - sold0 == in_cart, "P5: ...and paid for all %d (%d sales)" % [in_cart, sold_now() - sold0])
	await clear_loose_stock()
	for sec in ["Produce", "Dairy/Frozen", "Bakery"]:
		await fill_section(sec)

	# P6 a forced leave (store closing / shift start) with items in the cart:
	# they go out of play with the shopper — nothing dumped on the floor, so
	# no stock to settle onto a shelf and be bumped off as cleanup mess
	c = await spawn_shopper(["Bakery", "Dry Goods", "Produce"])
	await wait_until(func(): return is_instance_valid(c) and c.cart_items().size() >= 2, 90.0)
	await wait(0.3)
	var held: Array = c.cart_items()
	check(held.size() >= 2 and held.all(func(o): return not o.visible), "P6: %d items in the cart, hidden" % held.size())
	var sold6 := sold_now()
	c.force_leave()
	await wait(0.5)
	check(held.all(func(o): return not is_instance_valid(o)), "P6: force_leave took the cart's items out of play (none left on the floor)")
	check(sold_now() == sold6, "P6: ...unpaid (no sale)")
	check(get_nodes_in_group("carryable").all(func(o): return o.visible or o.get_node("Carryable").carrier_id != 0), "P6: ...no hidden item left behind")
	await clear_loose_stock()

	# P6b a timeout at the register (the rare case) still drops the cart as
	# plain loose stock, side by side, shown again
	c = await spawn_shopper(["Bakery", "Dry Goods"])
	await wait_until(func(): return is_instance_valid(c) and c._checking_out, 120.0)
	await wait(0.3)
	held = c.cart_items()
	c._lifetime_budget = c._lifetime - 1.0
	await wait(0.5)
	check(held.size() == 2 and held.all(func(o): return is_instance_valid(o) and o.get_node("Carryable").carrier_id == 0 and o.visible), "P6b: out of time at the register -> both items set down, shown again")
	var spread: bool = held.size() == 2 and held[0].global_position.distance_to(held[1].global_position) >= 20.0
	check(spread, "P6b: ...side by side, not in one pile")
	await clear_loose_stock()

	# P7 the cart and its contents, as drawn; a shove keeps the cart full
	await fill_section("Bakery")
	await fill_section("Produce")
	c = await spawn_shopper(["Bakery", "Produce"])
	await wait_until(func(): return is_instance_valid(c) and c.cart_items().size() >= 1, 60.0)
	await wait(0.3)
	check(c._cart_items.get_child_count() == c.cart_items().size(), "P7: the basket draws one copy per item in the cart (%d/%d)" % [c._cart_items.get_child_count(), c.cart_items().size()])
	check(c._bubble.visible and _bubble_icons(c) == c.shopping_list.size(), "P7: the bubble shows what's still wanted (%d icons, list %s)" % [_bubble_icons(c), ",".join(c.shopping_list)])
	var n_before: int = c.cart_items().size()
	c.request_shove(c.global_position + Vector2(30, 0))
	await wait(1.0)
	check(is_instance_valid(c) and c.cart_items().size() == n_before, "P7: shoved -> knocked back, the cart keeps its items")
	var rows := {}
	c.set_physics_process(false) # hold its AI still while it's turned by hand
	for ang in [0.0, PI / 2.0, PI, -PI / 2.0]:
		c.facing_angle = ang
		await wait(0.15)
		rows[c._cart_row] = [c._cart.position, c._cart_sprite.flip_h]
	c.set_physics_process(true)
	check(rows.size() == 4, "P7: the cart turns with its shopper (4 facings: %s)" % str(rows))
	check(c.cart_point().distance_to(c.global_position + c._cart.position) < 0.5, "P7: carried items ride at the cart")
	await gone(c, 90.0)
	finish()

func _bubble_icons(c: Node) -> int:
	return c._bubble.get_children().filter(func(n): return n is Sprite2D and not n.is_queued_for_deletion()).size()

## =============================================================================
## TRAFFIC — fully stocked, real crowd, real hazards, per-section sales
## =============================================================================

func _run_traffic() -> void:
	var secs := float(_arg_int("--seconds=", 300))
	var spec := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--hire=") and a.length() > 7:
			for part in a.substr(7).split(","):
				var f := part.split(":")
				spec[f[0]] = {"speed": int(f[1]) if f.size() > 1 else 0, "carry": int(f[2]) if f.size() > 2 else 0}
	await wait_until(func(): return main.players.has(1), 20.0)
	main.staff.staff = spec
	await wait_until(func(): return main.shift_active, 30.0)
	await wait(0.5)
	main.prep_time_left = 9999.0
	main.shift_time_left = 99999.0
	for sec in ["Dry Goods", "Produce", "Dairy/Frozen", "Bakery"]:
		await fill_section(sec)
	var lv: Dictionary = main.hazard_levels()
	print("INFO hazards on: %s; helpers: %s" % [str(lv), str(spec)])
	main.open_store(1)
	var sold0 := {}
	for s in ["Dry Goods", "Produce", "Dairy/Frozen", "Bakery"]:
		sold0[s] = sold_of(s)
	var total0 := sold_now()
	# Watch every shopper: progress (stuck = trying to get somewhere and not
	# getting closer for 20s straight), lists, checkouts.
	var track := {} # name -> {"pos", "since", "stuck"}
	var stuck := []
	var seen := {}
	var list_lens := []
	var t := 0.0
	var refill_t := 0.0
	var max_customers := 0
	var max_cart := 0
	var frame_ms := []
	var last := _wall()
	var start_w := _wall()
	while t < secs:
		await wait(0.5)
		t = _wall() - start_w # wall clock: refills below can take a while
		var now_w := _wall()
		frame_ms.append((now_w - last) * 1000.0)
		last = now_w
		if t >= refill_t:
			refill_t = t + 2.0
			for sec in ["Dry Goods", "Produce", "Dairy/Frozen", "Bakery"]:
				await fill_section(sec)
		var live := shoppers()
		max_customers = maxi(max_customers, get_nodes_in_group("customer").size())
		for c in live:
			if not seen.has(c.name):
				seen[c.name] = true
				list_lens.append(c.items_target)
			if c.has_method("cart_items"):
				max_cart = maxi(max_cart, c.cart_items().size())
			var moving: bool = c.velocity.length() > 1.0
			var tr: Dictionary = track.get(c.name, {"pos": c.global_position, "since": t, "stuck": false})
			if c.global_position.distance_to(tr["pos"]) > 40.0 or not moving:
				tr["pos"] = c.global_position
				tr["since"] = t
			elif t - float(tr["since"]) >= 20.0 and not tr["stuck"]:
				tr["stuck"] = true
				stuck.append("%s at %s (%s)" % [c.name, str(c.global_position.round()), main._section_name_at(c.global_position)])
			track[c.name] = tr
	var by := {}
	var total := 0
	for s in ["Dry Goods", "Produce", "Dairy/Frozen", "Bakery"]:
		by[s] = sold_of(s) - int(sold0[s])
		total += by[s]
	frame_ms.sort()
	var lens := {}
	for l in list_lens:
		lens[l] = lens.get(l, 0) + 1
	print("TRAFFIC seconds=%d helpers=%s | sold %d: %s | shoppers seen %d, list lengths %s, max cart %d, max crowd %d | rams %d | stuck %d %s" % [int(secs), str(spec.keys()), total, str(by), seen.size(), str(lens), max_cart, max_customers, main.forklift.rams_today, stuck.size(), str(stuck)])
	check(total == sold_now() - total0, "T0: per-section sales add up to the registers' total (%d)" % total)
	check(total >= 40, "T1: the store sold steadily (%d in %ds)" % [total, int(secs)])
	for s in ["Dry Goods", "Produce", "Dairy/Frozen", "Bakery"]:
		var f := float(by[s]) / maxf(1.0, total)
		check(f >= 0.15, "T2: %s gets real traffic: %d sales, %.0f%% of the total" % [s, by[s], f * 100.0])
	check(float(by["Bakery"]) >= 0.6 * float(by.values().max()), "T3: Bakery (farthest from the door) sells within 60%% of the best section (%d vs %d)" % [by["Bakery"], by.values().max()])
	check(stuck.size() <= maxi(1, seen.size() / 50), "T4: shoppers with carts don't get stuck (%d of %d stalled 20s+)" % [stuck.size(), seen.size()])
	check(max_cart >= 3, "T5: carts carry several items at once (max %d)" % max_cart)
	finish()

## =============================================================================
## CO-OP — host + 2 clients
## =============================================================================

func shop_view(c: Node) -> Dictionary:
	if c == null or not is_instance_valid(c):
		return {}
	return {"list": Array(c.shopping_list), "cart": c.cart_items().map(func(o): return String(o.name))}

func _client_shop_view(c: Node) -> Dictionary:
	var v := shop_view(c)
	if v.is_empty():
		return v
	v["has_cart"] = c.get_node_or_null("Cart") != null and c._cart.visible
	v["basket"] = c._cart_items.get_children().filter(func(n): return not n.is_queued_for_deletion()).size()
	v["icons"] = _bubble_icons(c)
	v["bubble"] = c._bubble.visible
	v["hidden"] = c.cart_items().all(func(o): return not o.visible)
	return v

func _all_lists() -> Dictionary:
	var out := {}
	for c in get_nodes_in_group("customer"):
		if not c.is_queued_for_deletion():
			out[String(c.name)] = Array(c.shopping_list)
	return out

func _run_net_shop_host() -> void:
	var want := _arg_int("--players=", 3)
	if DirAccess.dir_exists_absolute(NET_DIR):
		for f in DirAccess.get_files_at(NET_DIR):
			DirAccess.remove_absolute(NET_DIR + f)
	await wait_until(func(): return main.shift_active and main.players.size() >= want, 60.0)
	await wait(1.0)
	var ids: Array = main.players.keys()
	ids.sort()
	check(main.players.size() == want, "N0: %d players connected" % main.players.size())
	await quiet_open_store()
	for sec in ["Dry Goods", "Produce", "Dairy/Frozen", "Bakery"]:
		await fill_section(sec)
	_step("hello")
	await _answers(ids)
	# N1 a new shopper: same list on every peer from its first moment, a cart, a 3-icon bubble
	var c := await spawn_shopper(["Bakery", "Dairy/Frozen", "Produce"])
	await wait(0.6)
	_step("view", {"name": String(c.name), "view": shop_view(c), "basket": 0, "icons": 3, "tag": "N1"})
	var ans := await _answers(ids)
	for id in ans:
		check(ans[id].get("ok", false), "N1: %s sees the new shopper's list %s, its cart and a 3-icon bubble%s" % [main.player_display_name(id), str(Array(c.shopping_list)), ans[id].get("why", "")])
	# N2 first item in: the list shrinks, the cart shows one, the item hidden — everywhere
	await wait_until(func(): return c.cart_items().size() == 1, 60.0)
	await wait(0.6)
	_step("view", {"name": String(c.name), "view": shop_view(c), "basket": 1, "icons": c.shopping_list.size(), "tag": "N2"})
	ans = await _answers(ids)
	for id in ans:
		check(ans[id].get("ok", false), "N2: %s sees 1 item in the cart, list now %s%s" % [main.player_display_name(id), str(Array(c.shopping_list)), ans[id].get("why", "")])
	# N3 the full cart at the register
	await wait_until(func(): return c.cart_items().size() == 3, 90.0)
	await wait(0.6)
	_step("view", {"name": String(c.name), "view": shop_view(c), "basket": -1, "icons": 0, "tag": "N3"})
	ans = await _answers(ids)
	for id in ans:
		check(ans[id].get("ok", false), "N3: %s sees the full cart (3), the list done, bubble gone%s" % [main.player_display_name(id), ans[id].get("why", "")])
	# N4 checked out: the registers' total on every peer, the shopper gone
	var sold0 := sold_now()
	var cname := String(c.name)
	await gone(c, 90.0)
	await wait(0.6)
	check(sold_now() - sold0 == 3, "N4: the cart rang up as 3 sales (%d)" % (sold_now() - sold0))
	_step("gone", {"name": cname, "sold": sold_now()})
	ans = await _answers(ids)
	for id in ans:
		check(ans[id].get("ok", false), "N4: %s sees the shopper gone and %d sold, no item left hidden%s" % [main.player_display_name(id), sold_now(), ans[id].get("why", "")])
	# N5 the live crowd: every customer's list identical on every peer, twice
	main.test_hold_customers = false
	main.forklift.set_physics_process(true)
	main.manager.set_physics_process(true)
	for k in 2:
		await wait(20.0)
		_step("crowd", {"lists": _all_lists(), "tag": "N5.%d" % (k + 1)})
		ans = await _answers(ids)
		for id in ans:
			check(ans[id].get("ok", false), "N5.%d: %s sees every customer's list as the host does (%d customers)%s" % [k + 1, main.player_display_name(id), _all_lists().size(), ans[id].get("why", "")])
	_step("done")
	await _answers(ids)
	finish()

func _run_net_shop_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 30.0)
	me = main.multiplayer.get_unique_id()
	act = "client_"
	_record_lists()
	var n := 0
	while true:
		n += 1
		var step := await _net_read("ec_%d.json" % n, 600.0)
		var kind: String = step.get("kind", "")
		var ans := {}
		match kind:
			"view":
				var c: Node = main.get_node_or_null("Customers/" + str(step["name"]))
				if c == null:
					for cc in get_nodes_in_group("customer"):
						if String(cc.name) == str(step["name"]):
							c = cc
				var theirs: Dictionary = step["view"]
				var check_view := func() -> bool:
					var v := _client_shop_view(c)
					if v.is_empty():
						return false
					var ok: bool = _canon(v["list"]) == _canon(theirs["list"]) and _canon(v["cart"]) == _canon(theirs["cart"]) and v["has_cart"] and v["hidden"]
					if int(step["basket"]) >= 0:
						ok = ok and v["basket"] == int(step["basket"])
					ok = ok and v["icons"] == int(step["icons"]) and v["bubble"] == (int(step["icons"]) > 0)
					return ok
				var ok := await wait_until(check_view, 8.0)
				ans = {"ok": ok, "why": "" if ok else " — mine %s vs host %s (want basket %s, icons %s)" % [str(_client_shop_view(c)), str(theirs), step["basket"], step["icons"]]}
			"gone":
				var ok := await wait_until(func(): return get_nodes_in_group("customer").all(func(cc): return String(cc.name) != str(step["name"]) or cc.is_queued_for_deletion()) and main._total_sold() == int(step["sold"]), 8.0)
				var hidden := get_nodes_in_group("carryable").filter(func(o): return not o.visible and o.get_node("Carryable").carrier_id == 0)
				ok = ok and hidden.is_empty()
				ans = {"ok": ok, "why": "" if ok else " — sold %d vs %d, hidden loose items %d" % [main._total_sold(), int(step["sold"]), hidden.size()]}
			"crowd":
				# Lists shrink as the crowd shops, so "the same" means: every
				# list state the host had at its snapshot is one this client
				# showed too (its history, recorded every frame), for every
				# customer it has — and it has (nearly) all of them.
				var theirs: Dictionary = step["lists"]
				var same := func() -> bool:
					for k in theirs:
						if _list_seen.has(k) and not _canon(theirs[k]) in _list_seen[k]:
							return false
					return theirs.keys().filter(func(k): return _list_seen.has(k)).size() >= theirs.size() - 2
				var ok := await wait_until(same, 6.0)
				var bad := theirs.keys().filter(func(k): return _list_seen.has(k) and not _canon(theirs[k]) in _list_seen[k])
				ans = {"ok": ok, "why": "" if ok else " — never showed %s" % str(bad.map(func(k): return "%s=%s (saw %s)" % [k, theirs[k], _list_seen[k].keys()]))}
			"done":
				_net_write("ec_%d_%d.json" % [n, me], {})
				finish()
				return
		_net_write("ec_%d_%d.json" % [n, me], ans)

## Client: customer name -> {list state (canon JSON): true} it has shown.
var _list_seen := {}
func _record_lists() -> void:
	while true:
		var now := _all_lists()
		for k in now:
			var seen: Dictionary = _list_seen.get(k, {})
			seen[_canon(now[k])] = true
			_list_seen[k] = seen
		await physics_frame

## =============================================================================
## SHOTS
## =============================================================================

func _run_shots() -> void:
	main.debug_label.visible = false
	await quiet_open_store()
	for sec in ["Dry Goods", "Produce", "Dairy/Frozen", "Bakery"]:
		await fill_section(sec)
	var c := await spawn_shopper(["Bakery", "Dairy/Frozen", "Produce", "Dry Goods"])
	player().teleport_to(main._store_entrance_pos() + Vector2(0, -60))
	await wait(1.2)
	await shot_follow(c, "shopper_walks_in_full_list")
	await wait_until(func(): return c.cart_items().size() >= 1, 60.0)
	await wait(0.4)
	await shot_follow(c, "shopper_first_item_in_cart")
	await wait_until(func(): return c.cart_items().size() >= 2, 60.0)
	await wait(0.4)
	await shot_follow(c, "shopper_two_in_cart")
	await wait_until(func(): return c._checking_out, 90.0)
	await wait(1.0)
	await shot_follow(c, "shopper_heading_to_checkout")
	await wait_until(func(): return c._at_a_register(), 60.0)
	await wait(1.5)
	await shot_follow(c, "shopper_at_register")
	# The crowd: real spawns, Bakery from the player's view.
	main.test_hold_customers = false
	main.forklift.set_physics_process(true)
	main.manager.set_physics_process(true)
	await wait(35.0)
	for sec in ["Dry Goods", "Produce", "Dairy/Frozen", "Bakery"]:
		await fill_section(sec)
	player().teleport_to(Vector2(2000, 400))
	await wait(6.0)
	await shot("crowd_bakery")
	player().teleport_to(Vector2(1440, 1200))
	await wait(1.0)
	await shot("crowd_checkout")
	player().teleport_to(Vector2(480, 940))
	await wait(1.0)
	await shot("crowd_dairy")
	finish()

## The host's own player stands next to the shopper so the camera frames it.
func shot_follow(c: Node, shot_name: String) -> void:
	if is_instance_valid(c):
		player().teleport_to(c.global_position + Vector2(-60, 40))
		await wait(0.5)
	await shot(shot_name)
