extends Node2D
## OCT 2026 PIVOT, PHASE 4 — RANDOM EVENTS. Built in code by Main.gd's
## _ready() (explicit name "Events", same on every peer — its synchronizer's
## path must match), drawn over the floor and under the alert HUD.
##
## WHERE THEY CAME FROM: Week 21's Endless Mode handed the crew a SHIFT BOARD
## of randomized postings between shifts — which sections were open, each
## hazard at level 0/1/2, a tight clock, medal targets and a star-rated Bucks
## multiplier. Phase 2 parked that mode behind a debug flag; Phase 4 retires
## it and folds what still fits into ONGOING PLAY: no menu, no pick — an
## event rolls in during a shift, says so plainly, asks for one thing for a
## bounded time, and pays a bonus if the crew pulls it off. (The full
## scenario-by-scenario mapping is in the Phase 4 report; in short: the
## priority-orders knob became the CATERING ORDER, the spills knob the LEAKY
## ROOF, the manager knob the SURPRISE INSPECTION, the medal targets became
## each event's goal + bonus, the postings' names became the events' names;
## the section/forklift/lights/tight-clock knobs and the star multiplier were
## dropped.)
##
## THE POINT (the pivot doc): an event demands VARIETY — it can't be handled
## by camping one section. Every one sends the crew somewhere else:
## - LUNCH RUSH: shoppers want ONE section — the open one with the fewest of
##   the crew in it right now: a few extra shoppers come in, and every new
##   list has it on while its shelves have stock. Sell RUSH_GOAL from it in
##   time.
## - CATERING ORDER: a bulk order across 2-3 sections at once — stock N into
##   each (the priority orders' own tagging, several sections at a time).
## - SURPRISE DELIVERY: extra boxes for section after section (every open
##   section for a crew, two for a solo player) on the next truck in — or,
##   if one's already at the dock, first off it — each to be unpacked on its
##   own section's pad. (A staffed section's box goes to its helper's back
##   room, as always — that one's done for you.)
## - SURPRISE INSPECTION: an inspector is coming — the store-wide mess
##   (StoreRating.gd's mess points: trash, spills, full cans, in every open
##   section) must be under the bar when they arrive. Pass: a bonus and a
##   bump to the store rating.
## - LEAKY ROOF: the roof leaks puddles into section after section — mop
##   every one before time's up (they're mop-only, like drink puddles, and
##   drag the rating like any spill until they're gone).
##
## PACING AND GATING (all FLAGGED, tunable — the NUMBERS block below):
## - Each event unlocks like a complication does: by sections owned and/or
##   lifetime earned (EVENTS[...]["sections"/"earned"]) — never by day. A
##   brand-new crew in Dry Goods only never sees one.
## - When the store OPENS, the host rolls this shift: EVENT_CHANCE (higher at
##   the top tier) that an event comes, and when (FIRST_AFTER_OPEN_*). The
##   first event a crew EVER sees is guaranteed and gets a longer warning that
##   says what an event is (the clip test: it explains itself).
## - At most ONE event is ever active (never two at once), at most
##   max_per_shift() a shift (1; 2 at the top tier, with EVENT_GAP between),
##   and never on the shift a NEW complication stage starts (that shift's
##   banner gets the stage to itself), never in the practice shift.
## - An event only starts if it can finish before the store closes (warning
##   + duration + END_MARGIN within the selling time left); if none fits, the
##   shift simply has no (more) events.
## - PRIORITY ORDERS step aside: no call-out while an event is warning or
##   running, nor when one is due before the order could close; an event
##   waits for an open order to close before it starts. One objective on the
##   bottom banner row at a time.
## - The regular truck holds while a Surprise Delivery is warning, so the
##   event's truck is the one that comes.
##
## THE REWARD: one flat bonus per event completed (BONUS, x crew scale),
## credited to Pay Today the moment it's earned (bonus_today, its own line
## outside the gross — like the trash and bounce pay — so the cleanliness
## bonus is unchanged) and banked with the rest at clock-out through Main.gd's
## _bank_shift_pay(). The one payout path; a bonus is never negative, so it
## only ever adds to lifetime_earned. A missed event costs nothing.
##
## NETWORKING: host-authoritative. The host rolls, starts, counts and ends
## every event; the state rides EventSync (ALWAYS mode — a handful of small
## values, like DaySync's order fields) and the one-shot moments (warning,
## result) are reliable call_local RPCs for the sound and the pop. Every
## counter is bumped in one host call (a shelf settle, a sale, an unpack, a
## mop stroke), so two players finishing the same requirement in the same
## instant complete it exactly once: the event is over the moment the first
## one lands, and the second finds nothing left to count.

## ============================================================================
## NUMBERS — every one a FLAGGED, tunable placeholder (Phase 5 balances).
## ============================================================================
const PHASE_IDLE := 0
const PHASE_WARN := 1
const PHASE_ACTIVE := 2

## Pacing.
const EVENT_CHANCE := 0.6 # a shift gets an event (once any are unlocked)
const EVENT_CHANCE_TOP := 0.8 # ...at the top tier (stage 5)
const FIRST_AFTER_OPEN_MIN := 12.0 # s after the store opens
const FIRST_AFTER_OPEN_MAX := 25.0
const EVENT_GAP := 40.0 # s between one event's end and the next's warning (top tier)
const WARN_SECONDS := 6.0 # the heads-up before it starts
const WARN_SECONDS_FIRST := 10.0 # the first one this crew ever sees
const END_MARGIN := 5.0 # an event ends at least this long before close
const RESULT_SECONDS := 3.5 # the result line on the banner row
const RETRY_SECONDS := 2.0 # an event that can't start yet tries again...
const MAX_RETRIES := 10 # ...this many times (20 s), then this shift lets it go
const ORDER_GAP := 5.0 # an order can't be called if an event is due within window + this
## Bonus scale for a crew (the goals grow with it too): x(1 + this per extra player).
const CREW_BONUS_SCALE := 0.5

## The events. sections/earned: unlock (sections owned, lifetime earned $).
## weight: relative odds among the unlocked ones. bonus: $ for a solo crew.
## seconds: how long it runs once active (Catering's is by crew size).
const EVENTS := {
	"rush": {"name": "Lunch Rush", "sections": 2, "earned": 0, "weight": 3, "bonus": 50, "seconds": 45.0,
		"line": "Shoppers want %s — every bit you shelve there sells!",
		"how": "Sell %d from %s before time's up."},
	"inspection": {"name": "Surprise Inspection", "sections": 2, "earned": 600, "weight": 2, "bonus": 40, "seconds": 35.0,
		"line": "An inspector is on the way — clean up the WHOLE store!",
		"how": "Trash, spills and full cans in every open section: get the mess under the bar."},
	"leak": {"name": "Leaky Roof", "sections": 2, "earned": 1000, "weight": 2, "bonus": 40, "seconds": 55.0,
		"line": "The roof's leaking all over the store — grab a mop!",
		"how": "Mop up every leak before time's up."},
	"catering": {"name": "Catering Order", "sections": 3, "earned": 0, "weight": 3, "bonus": 60, "seconds": 0.0,
		"line": "A big order across the store — stock every section on the list!",
		"how": "Stock what's listed in each section before time's up."},
	"delivery": {"name": "Surprise Delivery", "sections": 3, "earned": 2000, "weight": 2, "bonus": 60, "seconds": 65.0,
		"line": "An extra load with a box for section after section — unpack them all!",
		"how": "Get one box unpacked on each section's pad."},
}
const EVENT_ORDER := ["rush", "inspection", "leak", "catering", "delivery"]

## Lunch Rush: units to sell from the section (+ per extra player), and the
## extra crowd it draws (+ per extra player) on top of the store's cap.
const RUSH_GOAL := 4 # solo 1-of-2 at 5 in the feasibility sim (the rush is, by design, where the crew isn't)
const RUSH_GOAL_PER_EXTRA := 3
const RUSH_EXTRA_CUSTOMERS := 3
const RUSH_EXTRA_PER_EXTRA := 1
## Catering Order: sections on it (at most), units per section (+ per extra
## player), capped by what each section can take right now (open slots,
## loose stock) — never an impossible order. Window by crew size.
const CATERING_SECTIONS := 3
const CATERING_PER_SECTION := 2
const CATERING_PER_EXTRA := 1
const CATERING_WINDOW_BY_PLAYERS := [60.0, 55.0, 50.0, 45.0]
## Surprise Delivery: one box per open section — at most DELIVERY_SOLO_SECTIONS
## of them for a solo crew (the solo feasibility sim, top tier: four boxes
## never fit; three got 2/3 in 65s with the third in hand — two different
## sections still sends a solo player across the store) — + this many per
## extra player to random ones.
const DELIVERY_SOLO_SECTIONS := 2
const DELIVERY_EXTRA_PER_EXTRA := 1
## Surprise Inspection: pass when the store's mess points are at most this
## many stars' worth (StoreRating.mess_per_star(): 6 + 3 per section past the
## first) — i.e. the store would rate 4 stars or better. Pass bumps the rating.
const INSPECTION_PASS_STARS := 1.0
const INSPECTION_RATING_BUMP := 0.3
## Leaky Roof: leaks (+ per extra player), dropped one every LEAK_DROP_GAP,
## round-robin over the open sections so they're spread out. Solo 3 (was 4:
## the solo feasibility sim, top tier, mopped 1 of 4 in 50s — a mop to fetch
## and four rooms to cross; 3 in 55s leaves room for the walk).
const LEAK_COUNT := 3
const LEAK_PER_EXTRA := 1
const LEAK_DROP_GAP := 2.5
const LEAK_RADIUS := 20.0
const LEAK_PAD_CLEARANCE := 100.0

## Colors: purple — never the cyan of a priority order or the yellow/red of
## LOOK BUSY.
const C_EVENT := Color(0.85, 0.55, 1.0)
const C_WIN := Color(0.5, 1, 0.5)
const C_MISS := Color(0.75, 0.75, 0.75)

## --- Replicated (EventSync, ALWAYS, host authority). Dictionaries/arrays are
## reassigned, never mutated, so every change is plainly a new value.
var phase := PHASE_IDLE
var key := "" # the event warning/running ("" when idle)
var time_left := 0.0 # in the current phase
var event_id := 0 # bumps per event (tests, the HUD's first-time line)
## Event-specific state: "section", "goal", "done" (rush); "needs"/"have"
## (catering, delivery: section -> count); "mess"/"pass_at"/"parts"
## (inspection); "leaks" (ids still on the floor), "to_drop" (leak);
## "bonus"; "first" (this crew's first event ever).
var data: Dictionary = {}
var bonus_today := 0
var bonus_week := 0
## Today's events: [[name, completed, bonus], ...] for the report.
var log_today: Array = []
## The last result for the banner row: [text, ok, seconds left].
var result_text := ""
var result_ok := false
var result_left := 0.0
## Event keys this crew has ever had (saved; host-written, replicated so every
## peer's report can say events are new).
var seen: Dictionary = {}

## --- Host-only ---
## Off: Main.events_on (--events=off, the income baseline; test harnesses).

var completed_total := 0 # saved: events completed, ever
var fired_today := 0
var _countdown := -1.0 # s of store-open time to the next warning (-1: none due)
var _skip_shift := false
var _last_key := ""
var _leak_timer := 0.0
var _forced := "" # tests: the next event is this one
var _retries := 0
## Tests: false keeps a finished event from scheduling the next one (the top
## tier's second event), so a scripted test controls every start.
var reschedule := true
## Host diagnostics (tests): completions/failures this session, and
## completion calls that found the event already over (the race guard).
var completions := 0
var failures := 0
var late_completions := 0

var main: Node
var _markers := {} # section -> Label (world-space, over the section's pad)
var _drew := false # the last frame drew leak drips

func _ready() -> void:
	main = get_parent()
	z_index = 110 # over the floor, the crowd and the lights' darkness (the E prompts are 120)
	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	for prop in [".:phase", ".:key", ".:time_left", ".:event_id", ".:data", ".:bonus_today", ".:bonus_week", ".:log_today", ".:result_text", ".:result_ok", ".:result_left", ".:seen"]:
		var path := NodePath(prop)
		config.add_property(path)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config
	sync.name = "EventSync" # explicit, identical name on every peer
	sync.set_multiplayer_authority(1)
	add_child(sync)
	for s in main.SECTIONS:
		var l := Label.new()
		l.name = "Marker" + s["node_name"]
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override("font_size", 26)
		l.add_theme_color_override("font_color", C_EVENT)
		l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
		l.add_theme_constant_override("shadow_offset_x", 2)
		l.add_theme_constant_override("shadow_offset_y", 2)
		l.size = Vector2(420, 70)
		l.pivot_offset = l.size / 2.0
		l.position = main.delivery.pad_center(s["name"]) + Vector2(-210, -120)
		l.visible = false
		add_child(l)
		_markers[s["name"]] = l

## --- Reads (every peer) ------------------------------------------------------

func active() -> bool:
	return phase == PHASE_ACTIVE

func warning() -> bool:
	return phase == PHASE_WARN

func busy() -> bool:
	return phase != PHASE_IDLE

func name_of(k: String) -> String:
	return str(EVENTS.get(k, {}).get("name", k))

## The crew size an event is sized for (the players here now).
func crew() -> int:
	return maxi(1, main.players.size())

func bonus_for(k: String) -> int:
	return int(round(int(EVENTS[k]["bonus"]) * (1.0 + CREW_BONUS_SCALE * (crew() - 1)) / 5.0)) * 5

func unlocked(k: String) -> bool:
	var e: Dictionary = EVENTS[k]
	return main.sections_owned >= int(e["sections"]) and main.lifetime_earned >= int(e["earned"])

func unlocked_keys() -> Array:
	return EVENT_ORDER.filter(func(k): return unlocked(k))

func max_per_shift() -> int:
	return 2 if main.complication_stage >= main.STAGE_RUSH else 1

## Lunch Rush: the extra crowd while it runs (Main.gd's customer_cap()).
func extra_customers() -> int:
	if active() and key == "rush":
		return RUSH_EXTRA_CUSTOMERS + RUSH_EXTRA_PER_EXTRA * (crew() - 1)
	return 0

## Lunch Rush: every list drawn while it runs has the rush section on it
## (Main.gd's make_shopping_list()) — as long as its shelves have stock. FOUND
## BY THE SOLO FEASIBILITY SIM: adding it to lists while the section stood
## empty turned shoppers who'd have browsed and come back into shoppers who
## waited at bare shelves and left with nothing — a missed rush cost sales.
## Now demand follows stock: keep it full and it sells as fast as it's
## shelved; leave it empty and the store is exactly as it would have been.
func adjust_list(list: PackedStringArray) -> PackedStringArray:
	if not (active() and key == "rush"):
		return list
	var sec: String = data.get("section", "")
	if sec == "" or list.has(sec) or not main.stocked_units_by_section().has(sec):
		return list
	var out := PackedStringArray([sec])
	out.append_array(list)
	return out

## Priority orders step aside (see the header). window = the order's window.
func blocks_orders(window: float) -> bool:
	if busy():
		return true
	return _countdown >= 0.0 and _countdown < window + ORDER_GAP

## The regular truck waits while a Surprise Delivery is warning.
func holds_truck() -> bool:
	return warning() and key == "delivery"

## --- Host: the shift ------------------------------------------------------------

## Main.gd's _start_shift(): a fresh shift — nothing pending, nothing running.
## skip: this shift starts a new complication stage, or it's practice.
func reset_for_new_shift(skip: bool) -> void:
	if not multiplayer.is_server():
		return
	_clear()
	result_left = 0.0
	result_text = ""
	bonus_today = 0
	log_today = []
	fired_today = 0
	_countdown = -1.0
	_skip_shift = skip

## Main.gd's open_store(): roll whether (and when) this shift gets an event.
func on_store_open() -> void:
	if not multiplayer.is_server() or not main.events_on or _skip_shift or main.tutorial.active:
		return
	if unlocked_keys().is_empty():
		return
	var chance := EVENT_CHANCE_TOP if main.complication_stage >= main.STAGE_RUSH else EVENT_CHANCE
	# The crew's very first event is guaranteed: the system introduces itself.
	if seen.is_empty() or _forced != "" or randf() < chance:
		_countdown = randf_range(FIRST_AFTER_OPEN_MIN, FIRST_AFTER_OPEN_MAX)
		print("[Events] This shift gets an event in ~%.0fs" % _countdown)

## Main.gd's start_cleanup(): the store closed — anything still pending or
## running is called off (it can't be finished on a closed store). The fit
## rule means this only happens to a debug-shortened clock.
func on_store_close() -> void:
	if not multiplayer.is_server():
		return
	_countdown = -1.0
	if busy():
		_finish(false, "the store closed")

## Host, every frame the store is open (Main.gd's _process()).
func tick_host(delta: float) -> void:
	if not multiplayer.is_server():
		return
	result_left = maxf(0.0, result_left - delta)
	match phase:
		PHASE_IDLE:
			if _countdown >= 0.0:
				_countdown -= delta
				if _countdown <= 0.0:
					_try_start()
		PHASE_WARN:
			time_left = maxf(0.0, time_left - delta)
			if time_left <= 0.0:
				_activate()
		PHASE_ACTIVE:
			time_left = maxf(0.0, time_left - delta)
			_tick_active(delta)
			if phase == PHASE_ACTIVE and time_left <= 0.0:
				_on_time_up()

## Tests: the next event is `k`, and it's due now (still through every rule:
## the store must be open, the event must fit and be possible).
func force_next(k: String, in_seconds := 0.5) -> void:
	if multiplayer.is_server():
		_forced = k
		_countdown = in_seconds

## --- Host: starting one -----------------------------------------------------------

func _event_seconds(k: String) -> float:
	if k == "catering":
		return CATERING_WINDOW_BY_PLAYERS[clampi(crew() - 1, 0, CATERING_WINDOW_BY_PLAYERS.size() - 1)]
	return float(EVENTS[k]["seconds"])

func _warn_seconds() -> float:
	return WARN_SECONDS_FIRST if seen.is_empty() else WARN_SECONDS

## Can `k` run right now, start to finish, before the store closes?
func _fits(k: String) -> bool:
	return main.shift_time_left >= _warn_seconds() + _event_seconds(k) + END_MARGIN

func _try_start() -> void:
	# One objective at a time: an order that's open finishes first.
	if main._order_id != 0:
		_countdown = RETRY_SECONDS
		return
	var pool: Array = []
	if _forced != "":
		pool = [_forced]
	else:
		pool = unlocked_keys()
		if pool.size() > 1:
			pool.erase(_last_key) # never the same one twice running
	pool = pool.filter(func(k): return _fits(k) and _plan(k).size() > 0)
	if pool.is_empty():
		var any_fits := (unlocked_keys() if _forced == "" else [_forced]).any(func(k): return _fits(k))
		_retries += 1
		if any_fits and _retries <= MAX_RETRIES:
			_countdown = RETRY_SECONDS # possible soon (stock to order, the truck away...)
		else:
			_countdown = -1.0 # nothing fits in what's left of the shift (or never became possible)
			_forced = ""
			_retries = 0
			print("[Events] No event fits/is possible with %.0fs left — none this time" % main.shift_time_left)
		return
	_retries = 0
	var k: String = _pick(pool)
	_forced = ""
	_countdown = -1.0
	var plan := _plan(k)
	var first := seen.is_empty()
	key = k
	event_id += 1
	plan["bonus"] = bonus_for(k)
	plan["first"] = first
	data = plan
	phase = PHASE_WARN
	time_left = _warn_seconds()
	fired_today += 1
	var next_seen := seen.duplicate()
	next_seen[k] = true
	seen = next_seen
	print("[Events] WARNING: %s in %.0fs — %s (bonus $%d)" % [name_of(k), time_left, str(plan), int(plan["bonus"])])
	_announce_warn.rpc(k, first)

func _pick(pool: Array) -> String:
	var total := 0
	for k in pool:
		total += int(EVENTS[k]["weight"])
	var r := randi() % maxi(1, total)
	for k in pool:
		r -= int(EVENTS[k]["weight"])
		if r < 0:
			return k
	return pool[0]

## The concrete plan for `k` right now ({} = not possible right now).
func _plan(k: String) -> Dictionary:
	var open: Array = main._unlocked_sections().map(func(s): return s["name"])
	match k:
		"rush":
			if open.size() < 2:
				return {}
			return {"section": _rush_section(open), "goal": RUSH_GOAL + RUSH_GOAL_PER_EXTRA * (crew() - 1), "done": 0}
		"catering":
			var cap := {}
			for s in main._unlocked_sections():
				var c: int = mini(main._open_slots_in_section(s), main._loose_stock_for_section(s))
				if c >= 1:
					cap[s["name"]] = c
			if cap.size() < 2:
				return {}
			var secs: Array = cap.keys()
			secs.shuffle()
			# The roomiest first, so the order is as big as it can honestly be.
			secs.sort_custom(func(a, b): return int(cap[a]) > int(cap[b]))
			var needs := {}
			var have := {}
			for sec in secs.slice(0, CATERING_SECTIONS):
				needs[sec] = mini(CATERING_PER_SECTION + CATERING_PER_EXTRA * (crew() - 1), int(cap[sec]))
				have[sec] = 0
			return {"needs": needs, "have": have}
		"delivery":
			if open.size() < 2 or not main.delivery.can_take_event_load():
				return {}
			var secs := open.duplicate()
			secs.shuffle()
			if crew() == 1:
				secs = secs.slice(0, DELIVERY_SOLO_SECTIONS)
			var needs := {}
			for sec in open:
				if sec in secs:
					needs[sec] = 1
			for i in DELIVERY_EXTRA_PER_EXTRA * (crew() - 1):
				var sec: String = secs[randi() % secs.size()]
				needs[sec] = int(needs[sec]) + 1
			var have := {}
			for sec in needs:
				have[sec] = 0
			return {"needs": needs, "have": have}
		"inspection":
			return {"mess": 0.0, "pass_at": _inspection_bar(), "parts": [0, 0, 0]}
		"leak":
			var n := LEAK_COUNT + LEAK_PER_EXTRA * (crew() - 1)
			return {"to_drop": n, "total": n, "leaks": [], "mopped": 0}
	return {}

## The open section with the fewest of the crew in it right now (ties: not
## Dry Goods — the room everyone walks through — then random).
func _rush_section(open: Array) -> String:
	var count := {}
	for sec in open:
		count[sec] = 0
	for p in main.players.values():
		if is_instance_valid(p):
			var sec: String = main._section_name_at(p.global_position)
			if count.has(sec):
				count[sec] += 1
	var best: Array = []
	var low := 1 << 30
	for sec in open:
		var c: int = count[sec]
		if c < low:
			low = c
			best = [sec]
		elif c == low:
			best.append(sec)
	if best.size() > 1:
		best.erase("Dry Goods")
	return best[randi() % best.size()]

func _inspection_bar() -> float:
	return snappedf(main.store_rating.mess_per_star() * INSPECTION_PASS_STARS, 0.1)

## --- Host: running one ------------------------------------------------------------

func _activate() -> void:
	phase = PHASE_ACTIVE
	time_left = _event_seconds(key)
	var d := data.duplicate(true)
	match key:
		"delivery":
			# A staffed section's box goes to its helper's back room (Staff.gd)
			# — the helper's on it: that one counts as done.
			var cargo := []
			for sec in d["needs"]:
				for i in int(d["needs"][sec]):
					cargo.append(sec)
				if main.staff.working(sec):
					d["have"][sec] = int(d["needs"][sec])
			cargo.shuffle()
			main.delivery.start_event_delivery(cargo)
		"leak":
			_leak_timer = 0.0
	data = d
	print("[Events] %s STARTS — %.0fs: %s" % [name_of(key), time_left, str(data)])
	_check_done()

func _tick_active(delta: float) -> void:
	match key:
		"inspection":
			var d := data.duplicate()
			d["mess"] = snappedf(main.store_rating.mess_points(), 0.1)
			d["parts"] = main.store_rating._mess_parts_now()
			if d != data:
				data = d
		"leak":
			var d := data.duplicate(true)
			if int(d["to_drop"]) > 0:
				_leak_timer -= delta
				if _leak_timer <= 0.0:
					_leak_timer = LEAK_DROP_GAP
					var id := _drop_leak(int(d["total"]) - int(d["to_drop"]))
					if id > 0:
						d["leaks"] = d["leaks"] + [id]
					d["to_drop"] = int(d["to_drop"]) - 1
			# Mopped = no longer on the floor (Cleanup.gd's mop removes it).
			var live := {}
			for pd in main.cleanup.puddles:
				live[int(pd["id"])] = true
			var left: Array = d["leaks"].filter(func(id): return live.has(int(id)))
			if left.size() != d["leaks"].size():
				d["mopped"] = int(d["mopped"]) + d["leaks"].size() - left.size()
				d["leaks"] = left
			if d != data:
				data = d
			_check_done()

## Host: a leak in the i-th open section (round-robin), on open floor clear
## of the pads and the shelves.
func _drop_leak(i: int) -> int:
	var open: Array = main._unlocked_sections()
	var section: Dictionary = open[i % open.size()]
	for attempt in 12:
		var pos: Vector2 = main._spawn_pos_in_section(section)
		if pos.distance_to(main.delivery.pad_center(section["name"])) < LEAK_PAD_CLEARANCE:
			continue
		if not main.cleanup._litter_spot_ok(pos):
			continue
		return main.cleanup.drop_puddle(pos, LEAK_RADIUS, true)
	return main.cleanup.drop_puddle(main._spawn_pos_in_section(section), LEAK_RADIUS, true)

## Completion check for the counted events (rush/catering/delivery/leak).
func _check_done() -> void:
	if not active():
		return
	var done := false
	match key:
		"rush":
			done = int(data["done"]) >= int(data["goal"])
		"catering", "delivery":
			done = true
			for sec in data["needs"]:
				if int(data["have"].get(sec, 0)) < int(data["needs"][sec]):
					done = false
		"leak":
			done = int(data["to_drop"]) <= 0 and data["leaks"].is_empty()
	if done:
		_finish(true, "")

func _on_time_up() -> void:
	if key == "inspection":
		var mess: float = main.store_rating.mess_points()
		var ok := mess <= float(data["pass_at"])
		if ok:
			main.store_rating.rating = minf(main.store_rating.MAX_RATING, main.store_rating.rating + INSPECTION_RATING_BUMP)
		var d := data.duplicate()
		d["mess"] = snappedf(mess, 0.1)
		data = d
		_finish(ok, "mess %s, needed %s or less" % [_num(mess), _num(float(data["pass_at"]))])
		return
	_finish(false, "time's up")

## The one place an event ends. ok: the bonus is paid, here, once.
func _finish(ok: bool, why: String) -> void:
	if not busy():
		late_completions += 1
		return
	var k := key
	var ev_name := name_of(k)
	var bonus := int(data.get("bonus", 0)) if ok else 0
	var was_active := active()
	if ok:
		bonus_today += bonus
		bonus_week += bonus
		completed_total += 1
		completions += 1
	else:
		failures += 1
	# Called off before it started (the store closed in the warning): it
	# never happened, so it's not on the report.
	if was_active or ok:
		log_today = log_today + [[ev_name, ok, bonus]]
	if ok:
		result_text = "%s COMPLETE!  +$%d" % [ev_name.to_upper(), bonus]
	elif k == "inspection" and why != "the store closed":
		result_text = "INSPECTION FAILED — %s" % why
	else:
		result_text = "%s missed — %s, no bonus" % [ev_name, why]
	result_ok = ok
	result_left = RESULT_SECONDS if (was_active or ok) else 0.0
	print("[Events] %s %s%s — bonus $%d (today $%d) — at the end: %s" % [ev_name, "COMPLETE" if ok else "missed", ("" if why == "" else " (%s)" % why), bonus, bonus_today, str(data)])
	_last_key = k
	_clear()
	if was_active or ok:
		_announce_result.rpc(ok, bonus)
	# Another one later this shift? (Top tier only: max_per_shift() 2.)
	if reschedule and fired_today < max_per_shift() and main.store_open and not main.cleanup_active:
		var chance := EVENT_CHANCE_TOP if main.complication_stage >= main.STAGE_RUSH else EVENT_CHANCE
		if randf() < chance:
			_countdown = EVENT_GAP + randf_range(0.0, 10.0)

func _clear() -> void:
	phase = PHASE_IDLE
	key = ""
	time_left = 0.0
	data = {}

static func _num(v: float) -> String:
	return str(int(v)) if is_equal_approx(v, round(v)) else "%.1f" % v

## --- Host: hooks from the systems an event counts --------------------------------

## Main.gd's note_sale(): a unit of `section` just sold.
func note_sale(section: String) -> void:
	if not multiplayer.is_server() or not active() or key != "rush" or section != data.get("section", ""):
		return
	var d := data.duplicate()
	d["done"] = int(d["done"]) + 1
	data = d
	_check_done()

## Main.gd's note_item_stocked(): an item settled into a slot of `section`.
## Returns whether the Catering Order took it (tagged, like an order item).
func note_item_stocked(obj: Node, section: String) -> bool:
	if not multiplayer.is_server() or not active() or key != "catering" or obj.has_meta("event_item"):
		return false
	var needs: Dictionary = data["needs"]
	if not needs.has(section) or int(data["have"][section]) >= int(needs[section]):
		return false
	obj.set_meta("event_item", event_id)
	var d := data.duplicate(true)
	d["have"][section] = int(d["have"][section]) + 1
	data = d
	_check_done()
	return true

## Delivery.gd's unpack: a box of `section` came apart on its pad.
func note_unpack(section: String) -> void:
	if not multiplayer.is_server() or not active() or key != "delivery":
		return
	var needs: Dictionary = data["needs"]
	if not needs.has(section) or int(data["have"][section]) >= int(needs[section]):
		return
	var d := data.duplicate(true)
	d["have"][section] = int(d["have"][section]) + 1
	data = d
	_check_done()

## --- One-shot moments (every peer) ----------------------------------------------

@rpc("authority", "call_local", "reliable")
func _announce_warn(k: String, first: bool) -> void:
	Sfx.play("final_shift" if first else "order_chime")

@rpc("authority", "call_local", "reliable")
func _announce_result(ok: bool, bonus: int) -> void:
	Sfx.play("order_filled" if ok else "order_missed")
	if main.juice:
		main.juice.order_result(ok)
		if ok and bonus > 0:
			var vp := get_viewport().get_visible_rect().size
			main.juice.ui_popup(Vector2(vp.x / 2.0, vp.y * 0.62), "+$%d EVENT BONUS" % bonus, main.juice.C_MONEY, true, 1.8)

## --- What the HUD shows (every peer, from replicated state) ------------------------

## The warning banner: [big, small, detail] (Main.gd's banner band).
func banner_lines() -> Array:
	if not warning():
		return []
	var big := "INCOMING: %s" % name_of(key).to_upper()
	var small := _line_text()
	var detail := "%s   Bonus +$%d   ·   starts in %ds" % [_how_text(), int(data.get("bonus", 0)), ceili(time_left)]
	if data.get("first", false):
		detail = "RANDOM EVENT — a bonus if the crew pulls it off, nothing lost if not.\n" + detail
	return [big, small, detail]

func _line_text() -> String:
	var e: Dictionary = EVENTS.get(key, {})
	var line: String = e.get("line", "")
	if key == "rush":
		return line % str(data.get("section", "")).to_upper()
	return line

func _how_text() -> String:
	var e: Dictionary = EVENTS.get(key, {})
	match key:
		"rush":
			return e["how"] % [int(data.get("goal", 0)), data.get("section", "")]
		"catering":
			return "Stock " + ", ".join(_needs_list(false)) + "."
		"delivery":
			return "Unpack a box on each pad: " + ", ".join(data.get("needs", {}).keys()) + "."
		"inspection":
			return "Get the mess to %s or less (trash 1, spill 3, full can 4)." % _num(float(data.get("pass_at", 0)))
		"leak":
			return "Mop up all %d leaks before time's up." % int(data.get("total", 0))
	return str(e.get("how", ""))

## ["2 Produce", "1 more Bakery"...] for catering/delivery.
func _needs_list(left: bool) -> Array:
	var out := []
	var needs: Dictionary = data.get("needs", {})
	var have: Dictionary = data.get("have", {})
	for sec in needs:
		var n: int = int(needs[sec]) - (int(have.get(sec, 0)) if left else 0)
		if n > 0:
			out.append("%d %s" % [n, sec])
	return out

## The live line on the bottom banner row (the priority order's row — orders
## are off while an event runs).
func status_line() -> String:
	if not active():
		return ""
	var t := ceili(time_left)
	match key:
		"rush":
			return "LUNCH RUSH — sell from %s: %d/%d   %ds   +$%d" % [data["section"], int(data["done"]), int(data["goal"]), t, int(data["bonus"])]
		"catering":
			var left := _needs_list(true)
			return "CATERING — stock %s   %ds   +$%d" % [" · ".join(left) if not left.is_empty() else "done!", t, int(data["bonus"])]
		"delivery":
			var left := []
			for sec in data["needs"]:
				if int(data["have"].get(sec, 0)) < int(data["needs"][sec]):
					left.append(sec)
			return "DELIVERY — a box on each pad: %s   %ds   +$%d" % [" · ".join(left) if not left.is_empty() else "done!", t, int(data["bonus"])]
		"inspection":
			var mess := float(data.get("mess", 0.0))
			var ok := mess <= float(data["pass_at"])
			return "INSPECTOR IN %ds — mess %s, pass at %s %s   +$%d" % [t, _num(mess), _num(float(data["pass_at"])), "✓" if ok else "— clean up!", int(data["bonus"])]
		"leak":
			var left: int = data["leaks"].size() + int(data["to_drop"])
			return "LEAKY ROOF — mop up %d leak%s   %ds   +$%d" % [left, "" if left == 1 else "s", t, int(data["bonus"])]
	return ""

## Hurry colour in the last 8s.
func status_color() -> Color:
	if key == "inspection" and float(data.get("mess", 0.0)) > float(data.get("pass_at", 0.0)) and time_left <= 10.0:
		return Color(1, 0.4, 0.3)
	return Color(1, 0.85, 0.2) if time_left <= 8.0 else C_EVENT

## Today's events, for the report ("" when there were none).
func report_line() -> String:
	if log_today.is_empty():
		return ""
	var parts := []
	for e in log_today:
		parts.append("%s %s%s" % [e[0], "✓" if e[1] else "✗", (" +$%d" % int(e[2])) if e[1] else ""])
	return "Events: " + "   ·   ".join(parts)

## --- World markers (every peer) ---------------------------------------------------

func _process(_delta: float) -> void:
	var t := Time.get_ticks_msec() / 1000.0
	var on := {}
	if (active() or warning()) and not main.is_day_report_active():
		match key:
			"rush":
				on[data.get("section", "")] = "RUSH HERE!\n%d/%d sold" % [int(data.get("done", 0)), int(data.get("goal", 0))] if active() else "RUSH COMING!"
			"catering", "delivery":
				var needs: Dictionary = data.get("needs", {})
				var have: Dictionary = data.get("have", {})
				for sec in needs:
					var n := int(needs[sec]) - int(have.get(sec, 0))
					if n > 0:
						on[sec] = ("STOCK %d MORE" % n if key == "catering" else ("BOX NEEDED" if n == 1 else "%d BOXES NEEDED" % n)) if active() else ("ORDER COMING" if key == "catering" else "BOX COMING")
	for sec in _markers:
		var l: Label = _markers[sec]
		l.visible = on.has(sec)
		if l.visible:
			l.text = on[sec]
			l.scale = Vector2.ONE * (1.0 + 0.06 * sin(t * 6.0))
	# Only the Leaky Roof draws (its drips); one more redraw clears them after.
	var drawing := active() and key == "leak"
	if drawing or _drew:
		queue_redraw()
	_drew = drawing

## Leaky Roof: a drip and a pulsing ring over every leak still on the floor;
## Surprise Inspection: nothing in the world — the whole store is the ask.
func _draw() -> void:
	if not active() or key != "leak":
		return
	var t := Time.get_ticks_msec() / 1000.0
	var live := {}
	for id in data.get("leaks", []):
		live[int(id)] = true
	for pd in main.cleanup.puddles:
		if not live.has(int(pd["id"])):
			continue
		var p: Vector2 = pd["pos"]
		var r: float = pd["r"] + 10.0 + 6.0 * sin(t * 5.0)
		draw_arc(p, r, 0.0, TAU, 28, Color(0.55, 0.8, 1.0, 0.9), 3.0)
		var drip_y := fmod(t * 120.0, 60.0)
		draw_circle(p + Vector2(0, -70 + drip_y), 4.0, Color(0.55, 0.8, 1.0, 0.85))
		draw_line(p + Vector2(0, -96), p + Vector2(0, -78), Color(0.55, 0.8, 1.0, 0.5), 2.0)
