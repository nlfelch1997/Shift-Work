extends Node2D
## WEEK 19 — END-OF-SHIFT CLEANUP. The prep phase's shape, inverted: when the
## selling window runs out the store CLOSES, customers leave, the hazards
## stand down, and the crew cleans up the day's mess before clocking out.
## Anyone can clock out early at the time clock in the break room (Main.gd's
## clock_out(), host-authoritative, like the Store sign); a ceiling timer
## clocks everyone out on its own if nobody does. Cleanliness pays a BONUS on
## the day's pay — never a fail state (same spirit as write-ups: pay, not
## game over). Main.gd owns the phase itself (cleanup_active and its clock,
## replicated in DaySync); this node owns the mess, the tools, the scoring
## and every visual for them. Built in code from Main.gd's _ready(), like
## Delivery.gd and Ambience.gd (nothing new in a .tscn — see Main.gd's
## header note on .tscn comments).
##
## TWO MESS CATEGORIES, TWO TOOLS (the PlateUp!-style split bonus):
## 1. SPILLS & KNOCKOVERS -> the MOP. Floor spills (Ambience.gd, complication
##    stage 4 — their drying clock stops at close, so what's there at close
##    stays until mopped); sticky drink PUDDLES (Phase 3D, below); floor
##    displays knocked over (Display.gd — mopping one up stands it back on its
##    spot); and, at close only, stock that got KNOCKED off a shelf (a forklift
##    wreck, a shove, a bump — not a normal pickup) and never went back on one.
##    Shelf.gd tags such an item ("knocked" meta, host-side) and untags it when
##    it settles into a slot again, so putting it back by hand clears it too.
##    Mopping a knocked item bins it as damaged stock (the product is freed).
## 2. LITTER -> the BROOM (or hands). Customers drop trash (wrappers, bottles,
##    cans) while they're in the store, at a rate per customer present — so
##    it tracks the crowd, not how well the crew plays. The broom sweeps up
##    every piece near its head at once into its dustpan, which holds
##    PAN_CAPACITY pieces; the pan is emptied into a trash can (E).
##
## ============================================================================
## OCT 2026 PHASE 3D — STORE UPKEEP (playtest: "brooms and mops are pointless,
## trash vanishes when you grab it, bins aren't needed, and keeping the store
## clean doesn't matter"). The loop is now a real chore, all shift long:
##
##   litter on the floor --E (one piece at a time, HAND_MAX in hand)-->
##   --or the broom (a whole pile at once, PAN_CAPACITY in the pan)-->
##   a TRASH CAN (E: in it goes, +$LITTER_PAY_PER_PIECE a piece) -->
##   the can fills (CAN_CAPACITY) and a FULL can overflows -->
##   E at a can: lift its BAG out --carry it--> the DUMPSTER (E: tip it in).
##
## - HAND TRASH: E on litter puts it IN YOUR HAND (`hands`), up to HAND_MAX
##   pieces. While you hold trash your hands are full: no stock, no tools, no
##   grabbing a customer — E bins it at a can, picks up another piece, or (with
##   nothing else to do) drops the handful back on the floor (the "let go"
##   escape hatch E always is). It pays when it goes IN A CAN, not when it
##   leaves the floor: trash in a pocket isn't thrown away.
## - CANS (`cans`, one fill count per BINS spot): the old visual-only bins. A
##   can holds CAN_CAPACITY pieces; a full can refuses more and OVERFLOWS — trash
##   heaped on and around it, flies, a red FULL tag — and counts against the
##   store rating (StoreRating.gd). Cans are NOT emptied overnight: a full can
##   at clock-out is still full next shift (saved, SaveGame.gd v4).
## - BAGS (`bags`): E at a can with nothing in your hands lifts its bag out
##   (the can is empty again). You carry it (a little slower, BAG_SPEED_MULT);
##   E at the DUMPSTER tips it in, E anywhere else sets it down (a bag on the
##   floor is a mess, rated like a full can). A bag left out at clock-out goes
##   back into the can it came from (the night crew won't touch it either).
## - THE DUMPSTER: out back, Storage's south-west corner, never fills — it's
##   the end of the line (the truck empties it overnight). It's solid
##   (StaticBody2D) and on the shoppers' navigation grid ("nav_obstacle"),
##   though shoppers never go into Storage anyway.
## - THE MOP's job hands can't do: anything wet. Ambience.gd's spills (stage
##   4+) still dry on their own (the hazard tests rely on it), but customers
##   now also knock over drinks — sticky PUDDLES (`puddles`): never dry, not
##   slippery, mop only, and they drag the rating down. With the knocked-over
##   floor display (stood back up by mopping), that gives the mop work from
##   the very first shift.
## - THE BROOM's job: piles. Hands carry HAND_MAX; a broom takes everything
##   in BROOM_RADIUS into a PAN_CAPACITY pan in one pass — a big mess is a
##   broom job.
## - TOOLS ARE OUT ALL DAY (they were cleanup-only): on the break room
##   station as before, plus one mop and one broom on a HUB RACK by the
##   checkout, so a spill mid-shift is a few steps away, not a trip out back.
##   Holding a tool is holding something: no stock until you put it down.
## - Helpers don't clean (Phase 3, unchanged) — flagged in the Phase 3D report.
##
## Every number here is a FLAGGED placeholder, tuned against the bot sims
## (tools/hazards_test.gd --test=cleanup / net-cleanup / solo,
## tools/upkeep_test.gd), not a human playtest.
##
## ART: litter pieces are the supermarket pack's loose snack/drink sprites
## (assets/supermarket/4.png); the trash can is the same pack's grey
## push-flap bin (11.png); the tool station (break room, by the time clock)
## is the warehouse pack's pegboard workbench (tile-B-03.png); the time clock is the supermarket pack's card
## kiosk (1.png). NO PACK HAS A MOP, A BROOM, A BIN BAG, A DUMPSTER OR A
## PUDDLE — all placeholder Polygon2D shapes, flagged for future art sourcing.

## --- Litter generation (selling window only) ---
## Pieces per customer per second in the store (hub + unlocked sections).
## ~1 per customer-minute: Day 1-2 (5 customers) ~8 a day, Day 7 (17) ~25.
const LITTER_RATE_PER_CUSTOMER := 1.0 / 60.0
const LITTER_MAX_ON_FLOOR := 40
const LITTER_CLEAR_SLOT := 30.0 # never inside a shelf slot's capture circle
const LITTER_JITTER := 14.0 # dropped at the customer's feet, give or take
## PHASE 3D: this share of drops is a knocked-over drink instead — a sticky
## puddle (mop only, never dries, not slippery), up to PUDDLE_MAX at once.
const PUDDLE_CHANCE := 0.15
const PUDDLE_MAX := 6
const PUDDLE_R_MIN := 15.0
const PUDDLE_R_MAX := 21.0
## --- Tools ---
## PHASE 3D: 3 + 3 (was 2 + 2): the break room station keeps its two of each,
## the hub rack has one of each.
const MOPS := 3
const BROOMS := 3
const TOOL_PICKUP_RANGE := 60.0
const MOP_HEAD_OFFSET := 30.0 # from the player's center, along their facing
const MOP_REACH := 34.0 # + the mess's own radius (26 read as fiddly: the bot sims kept stopping just short)
const MOP_TIME_SPILL_BASE := 1.0 # s — plus MOP_TIME_SPILL_PER_PX * radius (a 38-54px spill: 2.1-2.6s)
const MOP_TIME_SPILL_PER_PX := 0.03
const MOP_TIME_PUDDLE := 1.2
const MOP_TIME_DISPLAY := 1.6
const MOP_TIME_STOCK := 0.8
const BROOM_HEAD_OFFSET := 30.0
const BROOM_RADIUS := 50.0
const SWEEP_TIME := 0.45 # s of sweeping over a piece to get it in the pan
const PAN_CAPACITY := 8
const BIN_RANGE := 70.0
## --- Phase 3D: hands, cans, bags, the dumpster ---
const HAND_MAX := 3 # pieces of trash in one hand-held load
const CAN_CAPACITY := 15 # pieces a trash can holds; full = overflowing. Was 10: the solo upkeep bot made ~3 dumpster runs a busy Day 3 shift (Phase 3D income notes)
const BAG_RANGE := 60.0 # E reach for a bag set down on the floor
const BAG_SPEED_MULT := 0.85 # walking with a full bin bag (Player.gd's speed())
const DUMPSTER_POS := Vector2(2030.0, 1530.0)
const DUMPSTER_SIZE := Vector2(110.0, 56.0) # collision box
const DUMPSTER_RANGE := 95.0 # from its center: the box's half-width + an arm
## --- Scoring ---
const CLEAN_BONUS_MAX := 0.25 # a spotless store: +25% of the day's gross pay
## PLAYTEST FIX (Oct 2026 outside playtest): every piece of litter pays
## LITTER_PAY_PER_PIECE, with a "+$1" popup. PHASE 3D: paid when it goes INTO A
## CAN (by hand or out of a dustpan), not when it leaves the floor. Its own
## line on the report (Main.gd's _pay_today()/_pay_week()), ON TOP of the
## cleanliness bonus: the bonus formula (finish_cleanup()) is untouched — it
## still scores whatever's on the floor at close, and isn't a share of this.
const LITTER_PAY_PER_PIECE := 1
## E-by-hand reach for a piece of litter: the store's shared E radius (see
## Carryable.gd's PICKUP_RANGE); the host allows a little net slack on top.
const LITTER_HAND_RANGE := 70.0
const LITTER_HAND_NET_SLACK := 12.0

## Layout. WEEK 20 (playtest): the tool station lives in the BREAK ROOM,
## just west of the time clock, so grabbing the tools and clocking out are
## the same trip (it was in the checkout hub's north-west corner). Kept
## far enough from the clock that no spot is in both reaches — the clock
## wins an E press (Player.gd), and picking up a mop must never clock the
## whole crew out: nearest tool spot to TIME_CLOCK_POS is 141px, more than
## TOOL_PICKUP_RANGE + TIME_CLOCK_RANGE (130). Break Room is customer-free
## (Customer.gd), so no shopper stands on the tools either. The bins did NOT
## move: one in the hub's north-west corner (where the station used to be)
## and one inside each section's hub-side doorway (hidden while the section
## is locked). Visual only — no collision, nothing to snag on.
## PHASE 3D: TOOL_SPOTS in tool order (mops, then brooms): the station's two
## of each, then the hub rack's one of each (its north-east corner, clear of
## the register rows and the Produce doorway's can).
const STATION_POS := Vector2(700.0, 280.0)
const RACK_POS := Vector2(1822.0, 588.0)
const TOOL_SPOTS := [Vector2(660.0, 320.0), Vector2(678.0, 320.0), Vector2(1800.0, 612.0), Vector2(722.0, 320.0), Vector2(740.0, 320.0), Vector2(1844.0, 612.0)]
const BINS := [
	{"pos": Vector2(1110.0, 590.0), "section": ""}, # hub, north-west corner
	{"pos": Vector2(1300.0, 500.0), "section": "Dry Goods"},
	{"pos": Vector2(1975.0, 620.0), "section": "Produce"},
	{"pos": Vector2(905.0, 620.0), "section": "Dairy/Frozen"},
	{"pos": Vector2(1975.0, 300.0), "section": "Bakery"},
]

const MARKET_SHEET_4 := "res://assets/supermarket/4.png"
const LITTER_REGIONS := [
	Rect2i(448, 676, 17, 41), # orange soda bottle
	Rect2i(496, 676, 17, 41), # water bottle
	Rect2i(538, 678, 29, 37), # chip bag
	Rect2i(726, 679, 36, 35), # candy bar
	Rect2i(448, 724, 17, 41), # green bottle
	Rect2i(496, 723, 17, 42), # cola bottle
	Rect2i(541, 726, 23, 38), # soda can
	Rect2i(682, 679, 29, 35), # snack bag
]
const LITTER_SCALE := 0.42
const BIN_SHEET := "res://assets/supermarket/11.png"
const BIN_REGION := Rect2i(534, 124, 33, 65)
const STATION_SHEET := "res://assets/warehouse/tile-B-03.png"
const STATION_REGION := Rect2i(2, 203, 92, 83)
const PUDDLE_COLOR := Color(0.62, 0.36, 0.12, 0.8) # cola, mostly
const Z_ON_FLOOR := 0
const Z_HELD := 2

## Host-written, replicated (see _ready()). Reassigned, never mutated in
## place, whenever they change.
## [{"id": int, "pos": Vector2, "v": int (art variant), "rot": float}]
var litter: Array = []
## [{"kind": "mop"/"broom", "holder": peer id or 0, "pos": Vector2 (resting
## spot when not held), "pan": int, "work": float (0-1, the thing it's on
## now; -1 = idle), "full": bool}]
var tools: Array = []
## Names of products tagged knocked (for the cleanup markers), cleanup only.
var knocked_names: Array = []
## Today's cleanup tally (host-written at close and at clock-out).
var mop_total := 0
var mop_left := 0
var litter_total := 0
var litter_left := 0
var clean_bonus_today := 0
var clean_bonus_week := 0
## Pieces of litter that left the floor today (into hands or a dustpan —
## the cleanup score and the Juice sparkle read it), and this week's
## LITTER_PAY_PER_PIECE total (paid at the can) — host-written, replicated.
var litter_collected_today := 0
var litter_pay_week := 0
## --- PHASE 3D (host-written, replicated) ---
## [{"id": int, "pos": Vector2, "r": float}] — sticky drink puddles.
var puddles: Array = []
## peer id -> pieces of trash in that player's hand.
var hands := {}
## One fill count per BINS entry (persists across shifts; saved).
var cans: Array = [0, 0, 0, 0, 0]
## [{"id": int, "holder": peer id or 0, "pos": Vector2, "n": int, "can": int}]
var bags: Array = []
## Pieces binned today / bags tipped into the dumpster today.
var trash_binned_today := 0
var bags_dumped_today := 0
## peer id -> {"binned", "swept", "mopped", "dumped"} today (the practice
## shift's steps and the tests read it).
var stats := {}

## Host-only.
var _next_litter_id := 1
var _next_puddle_id := 1
var _next_bag_id := 1
var _litter_timer := 1.0
var _progress := {} # mess key -> 0..1
var _knocked_refresh := 0.0
var litter_dropped_today := 0
var puddles_dropped_today := 0

## Local visuals.
var main: Node
var _litter_root: Node2D
var _litter_nodes := {} # id -> Sprite2D
var _puddle_nodes := {} # id -> Node2D
var _tool_nodes: Array = []
var _bin_nodes: Array = []
var _can_fx: Array = [] # per BINS: Node2D with the fill meter and the overflow heap
var _bag_nodes := {} # id -> Node2D
var _hand_nodes := {} # peer -> Node2D
var _dumpster: StaticBody2D
var _marker_root: Node2D
var _markers := {} # product name -> Node2D
var _hint: Label

func _ready() -> void:
	main = get_parent()
	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	# WEEK 20 BUG FIX: ON_CHANGE, not ALWAYS. ALWAYS state goes out every tick
	# as ONE unreliable packet, and Godot drops any node state over the MTU
	# (1350 bytes) outright ("Node states bigger than MTU will not be sent")
	# — with ~10+ litter pieces on the floor this node's state is past that,
	# so clients' litter, tools and tallies froze for the rest of the day (a
	# client's own mop pickup never showed up in their hands). Found by the
	# net-polish test's long selling window; net-cleanup's 60s shift never
	# dropped enough litter to hit it. ON_CHANGE state goes out as reliable
	# deltas (fragmented, no MTU cap), and only when a value changes — every
	# one of these is reassigned, never mutated in place (see `litter`).
	for prop in [".:litter", ".:tools", ".:knocked_names", ".:mop_total", ".:mop_left", ".:litter_total", ".:litter_left", ".:clean_bonus_today", ".:clean_bonus_week", ".:litter_collected_today", ".:litter_pay_week", ".:puddles", ".:hands", ".:cans", ".:bags", ".:trash_binned_today", ".:bags_dumped_today", ".:stats"]:
		var path := NodePath(prop)
		config.add_property(path)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE)
	sync.replication_config = config
	sync.name = "Sync" # explicit, identical name on every peer — see Player.gd's note
	sync.set_multiplayer_authority(1)
	add_child(sync)
	tools = _fresh_tools()
	# Litter lies on the floor: its own container right after the spills
	# (Ambience.gd), under shelves, stock and people.
	_litter_root = Node2D.new()
	_litter_root.name = "Litter"
	main.add_child(_litter_root)
	main.move_child(_litter_root, main.get_node("Spills").get_index() + 1)
	_marker_root = Node2D.new()
	_marker_root.name = "MessMarkers"
	_marker_root.z_index = 5
	add_child(_marker_root)
	_build_station()
	_build_rack()
	_build_dumpster()
	for i in BINS.size():
		var b: Dictionary = BINS[i]
		var bin := _sprite(BIN_SHEET, BIN_REGION, 0.8)
		bin.position = b["pos"] + Vector2(0, -18) # feet on the spot
		add_child(bin)
		_bin_nodes.append(bin)
		var fx := _build_can_fx()
		fx.position = b["pos"]
		add_child(fx)
		_can_fx.append(fx)
	for i in MOPS + BROOMS:
		var node := _build_tool_node("mop" if i < MOPS else "broom")
		add_child(node)
		_tool_nodes.append(node)
	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 14)
	_hint.add_theme_color_override("font_color", Color(1, 0.9, 0.3))
	_hint.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_hint.add_theme_constant_override("shadow_offset_x", 1)
	_hint.add_theme_constant_override("shadow_offset_y", 1)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.size = Vector2(260, 22)
	_hint.z_index = 20
	_hint.visible = false
	add_child(_hint)

func _fresh_tools() -> Array:
	var out := []
	for i in MOPS + BROOMS:
		out.append({"kind": "mop" if i < MOPS else "broom", "holder": 0, "pos": TOOL_SPOTS[i], "pan": 0, "work": -1.0, "full": false})
	return out

## Host-only, from Main.gd's _start_shift(): a clean floor, tools on the rack.
## PHASE 3D: the cans keep what's in them (they're not emptied overnight); a
## bag left out goes back into its can (see the header).
func reset_for_new_day() -> void:
	if not multiplayer.is_server():
		return
	_return_bags()
	litter = []
	puddles = []
	hands = {}
	tools = _fresh_tools()
	knocked_names = []
	_progress = {}
	_litter_timer = randf_range(0.6, 1.4)
	litter_dropped_today = 0
	puddles_dropped_today = 0
	litter_collected_today = 0
	trash_binned_today = 0
	bags_dumped_today = 0
	stats = {}
	mop_total = 0
	mop_left = 0
	litter_total = 0
	litter_left = 0
	clean_bonus_today = 0

## Host: every bag (held or set down) back into the can it came from.
func _return_bags() -> void:
	if bags.is_empty():
		return
	var next := cans.duplicate()
	for b in bags:
		var i: int = b["can"]
		if i >= 0 and i < next.size():
			next[i] = mini(can_capacity(), int(next[i]) + int(b["n"]))
	cans = next
	bags = []

## --- Host: during the selling window ------------------------------------

## Host-only, every frame the store is open (Main.gd's _process()).
func tick_selling(delta: float) -> void:
	if not multiplayer.is_server():
		return
	var inside: Array = get_tree().get_nodes_in_group("customer").filter(func(c): return _litter_zone_ok(c.global_position) and not c.get("escorted_by"))
	if inside.is_empty():
		return
	_litter_timer -= delta * inside.size() * LITTER_RATE_PER_CUSTOMER
	if _litter_timer > 0.0:
		return
	_litter_timer = randf_range(0.6, 1.4)
	var who: Node2D = inside[randi() % inside.size()]
	var puddle := randf() < PUDDLE_CHANCE and puddles.size() < PUDDLE_MAX
	if not puddle and litter.size() >= LITTER_MAX_ON_FLOOR:
		return
	for attempt in 6:
		var pos := who.global_position + Vector2(randf_range(-LITTER_JITTER, LITTER_JITTER), randf_range(-LITTER_JITTER, LITTER_JITTER))
		if _litter_spot_ok(pos):
			if puddle:
				drop_puddle(pos)
			else:
				drop_litter(pos)
			return

## The hub and the unlocked sections — where shoppers actually shop. Not
## the Sidewalk, Storage or the break room.
func _litter_zone_ok(pos: Vector2) -> bool:
	var cell: Vector2i = main._grid_cell_of(pos)
	return cell == main.ENTRANCE_GRID_POS or main.is_unlocked_at_pos(pos)

func _litter_spot_ok(pos: Vector2) -> bool:
	if not _litter_zone_ok(pos) or main._is_out_of_bounds(pos):
		return false
	for shelf_body in main.shelves:
		for slot in shelf_body.get_node("Shelf").slots:
			if pos.distance_to(slot.global_position) < LITTER_CLEAR_SLOT:
				return false
	return true

## Host-only. Public for tests.
func drop_litter(pos: Vector2) -> int:
	if not multiplayer.is_server():
		return 0
	var id := _next_litter_id
	_next_litter_id += 1
	var next := litter.duplicate()
	next.append({"id": id, "pos": pos, "v": randi() % LITTER_REGIONS.size(), "rot": randf_range(-PI, PI)})
	litter = next
	litter_dropped_today += 1
	return id

## Host-only. Public for tests (and the practice shift).
func drop_puddle(pos: Vector2, r := -1.0) -> int:
	if not multiplayer.is_server():
		return 0
	var id := _next_puddle_id
	_next_puddle_id += 1
	var next := puddles.duplicate()
	next.append({"id": id, "pos": pos, "r": r if r > 0.0 else randf_range(PUDDLE_R_MIN, PUDDLE_R_MAX)})
	puddles = next
	puddles_dropped_today += 1
	return id

func remove_puddle(id: int) -> void:
	if multiplayer.is_server():
		puddles = puddles.filter(func(p): return p["id"] != id)

## --- Host: the cleanup phase ----------------------------------------------

## Host-only, from Main.gd's start_cleanup(): snapshot today's mess.
func begin_cleanup() -> void:
	if not multiplayer.is_server():
		return
	_progress = {}
	mop_total = _mop_messes().size()
	mop_left = mop_total
	litter_total = litter.size()
	litter_left = litter_total
	_refresh_knocked()
	print("[Cleanup] Store closed on Day %d — mess: %d spills/knockovers, %d litter" % [main.current_day, mop_total, litter_total])

## A rough measure of how much work is on the floor — Main.gd's cleanup
## ceiling reads it at close.
func mess_count() -> int:
	return mop_total + litter_total

## Host-only, every frame of the shift (prep, selling and cleanup — PHASE 3D:
## the tools work all day). Mopping, sweeping, and (cleanup only) the
## knocked-stock bookkeeping.
func tick_tools(delta: float) -> void:
	if not multiplayer.is_server():
		return
	var next_tools := tools.duplicate(true)
	var changed := false
	for i in next_tools.size():
		var t: Dictionary = next_tools[i]
		var holder: int = t["holder"]
		var work := -1.0
		var full := false
		var p = main.players.get(holder) if holder != 0 else null
		if p != null and is_instance_valid(p) and p.using_tool:
			var head: Vector2 = p.global_position + Vector2.RIGHT.rotated(p.facing_angle) * (MOP_HEAD_OFFSET if t["kind"] == "mop" else BROOM_HEAD_OFFSET)
			if t["kind"] == "mop":
				work = _mop_at(head, delta, holder)
			else:
				var r := _sweep_at(head, delta, t["pan"], holder)
				work = r[0]
				if r[1] > 0:
					t["pan"] = int(t["pan"]) + int(r[1])
					changed = true
		if t["kind"] == "broom":
			full = int(t["pan"]) >= pan_capacity()
		if not is_equal_approx(float(t["work"]), work) or t["full"] != full:
			t["work"] = work
			t["full"] = full
			changed = true
	if changed:
		tools = next_tools
	if main.cleanup_active:
		_knocked_refresh -= delta
		if _knocked_refresh <= 0.0:
			_knocked_refresh = 0.25
			_refresh_knocked()
			_update_left()

## Kept for anything that still calls the Week 19 name.
func tick_cleanup(delta: float) -> void:
	tick_tools(delta)

## Every mop-category mess on the floor right now:
## [{"key", "kind", "pos", "r", "time", "ref"}]. Knocked stock only counts
## during cleanup — mid-shift it's just loose stock to put back.
func _mop_messes(include_knocked: Variant = null) -> Array:
	var knocked: bool = main.cleanup_active if include_knocked == null else include_knocked
	var out := []
	for s in main.ambience.spills:
		out.append({"key": "s%d" % s["id"], "kind": "spill", "pos": s["pos"], "r": s["r"], "time": MOP_TIME_SPILL_BASE + MOP_TIME_SPILL_PER_PX * s["r"], "ref": s["id"]})
	for pd in puddles:
		out.append({"key": "u%d" % pd["id"], "kind": "puddle", "pos": pd["pos"], "r": pd["r"], "time": MOP_TIME_PUDDLE, "ref": pd["id"]})
	for i in main.displays.size():
		var d: Node = main.displays[i]
		if d.get_node("Display").toppled:
			out.append({"key": "d%d" % i, "kind": "display", "pos": d.global_position, "r": 24.0, "time": MOP_TIME_DISPLAY, "ref": d})
	if knocked:
		for obj in _knocked_products():
			out.append({"key": "p" + String(obj.name), "kind": "stock", "pos": obj.global_position, "r": 14.0, "time": MOP_TIME_STOCK, "ref": obj})
	return out

## Host-only: loose, uncarried products still tagged knocked (Shelf.gd).
func _knocked_products() -> Array:
	var out := []
	for obj in get_tree().get_nodes_in_group("carryable"):
		if obj.has_meta("knocked") and not obj.is_queued_for_deletion() and obj.get_node("Carryable").carrier_id == 0:
			out.append(obj)
	return out

func _refresh_knocked() -> void:
	var names := []
	for obj in _knocked_products():
		names.append(String(obj.name))
	names.sort()
	if names != knocked_names:
		knocked_names = names

func _update_left() -> void:
	var m := _mop_messes().size()
	if m != mop_left:
		mop_left = m
	# Made during cleanup (a display bumped over) — it's mess all the same.
	if mop_left > mop_total:
		mop_total = mop_left
	if litter.size() != litter_left:
		litter_left = litter.size()

## Scrubs the nearest mess in reach of the mop head. Returns its progress
## (0-1), or -1 if there's nothing in reach.
func _mop_at(head: Vector2, delta: float, peer := 0) -> float:
	var best = null
	var best_d := INF
	for m in _mop_messes():
		var d: float = head.distance_to(m["pos"]) - m["r"]
		if d <= MOP_REACH and d < best_d:
			best_d = d
			best = m
	if best == null:
		return -1.0
	var k: String = best["key"]
	var prog: float = _progress.get(k, 0.0) + delta / (float(best["time"]) * main.endless.cleanup_time_mult())
	if prog < 1.0:
		_progress[k] = prog
		return prog
	_progress.erase(k)
	match String(best["kind"]):
		"spill":
			main.ambience.remove_spill(best["ref"])
		"puddle":
			remove_puddle(best["ref"])
		"display":
			best["ref"].get_node("Display").reset_to_home()
		"stock":
			best["ref"].queue_free()
	print("[Cleanup] mopped up a %s" % best["kind"])
	_bump_stat(peer, "mopped", 1)
	if main.cleanup_active:
		_update_left()
	return 1.0

## Sweeps every piece in the broom's reach. Returns [progress of the
## furthest-along piece or -1, pieces that went in the pan].
func _sweep_at(head: Vector2, delta: float, pan: int, peer := 0) -> Array:
	var room := pan_capacity() - pan
	var best := -1.0
	var swept := []
	for piece in litter:
		if head.distance_to(piece["pos"]) > BROOM_RADIUS:
			continue
		var k := "l%d" % piece["id"]
		if room <= 0:
			best = maxf(best, _progress.get(k, 0.0))
			continue
		var prog: float = _progress.get(k, 0.0) + delta / (SWEEP_TIME * main.endless.cleanup_time_mult())
		if prog >= 1.0 and swept.size() < room:
			swept.append(piece["id"])
			_progress.erase(k)
			best = 1.0
		else:
			_progress[k] = minf(prog, 0.99)
			best = maxf(best, _progress[k])
	if not swept.is_empty():
		litter = litter.filter(func(p): return not (p["id"] in swept))
		_note_collected(swept.size())
		_bump_stat(peer, "swept", swept.size())
		if main.cleanup_active:
			_update_left()
	return [best, swept.size()]

## Host: n pieces just left the floor into someone's hands or dustpan.
func _note_collected(n: int) -> void:
	litter_collected_today += n

## Host: n pieces just went into can `i` (by hand or from a pan) — that's
## when they pay.
func _bin(i: int, n: int, peer: int) -> void:
	var next := cans.duplicate()
	next[i] = int(next[i]) + n
	cans = next
	trash_binned_today += n
	litter_pay_week += n * LITTER_PAY_PER_PIECE
	_bump_stat(peer, "binned", n)

func _bump_stat(peer: int, key: String, n: int) -> void:
	if peer <= 0 or n == 0:
		return
	var next := stats.duplicate(true)
	var s: Dictionary = next.get(peer, {})
	s[key] = int(s.get(key, 0)) + n
	next[peer] = s
	stats = next

func stat(peer: int, key: String) -> int:
	return int(stats.get(peer, {}).get(key, 0))

## Every peer (replicated counter): today's pay from trash binned.
func litter_pay_today() -> int:
	return trash_binned_today * LITTER_PAY_PER_PIECE

## --- Litter by hand (PLAYTEST FIX, see LITTER_PAY_PER_PIECE) ----------------

## Any peer: the piece of litter nearest `pos` within LITTER_HAND_RANGE, as
## [id, distance], or [0, INF]. Player.gd compares it with the nearest stock.
func nearest_litter(pos: Vector2, reach := LITTER_HAND_RANGE) -> Array:
	var best_id := 0
	var best_d := INF
	for piece in litter:
		var d: float = pos.distance_to(piece["pos"])
		if d <= reach and d < best_d:
			best_d = d
			best_id = piece["id"]
	return [best_id, best_d]

## Kept for the old call site and tests: E on litter.
func try_pick_litter() -> void:
	request("pick_trash")

## Host-only. Checked against where the HOST sees the player, like the tools.
func _pick_litter(peer: int, p: Node2D) -> bool:
	if hand_count(peer) >= HAND_MAX:
		return false
	var hit := nearest_litter(p.global_position, LITTER_HAND_RANGE + LITTER_HAND_NET_SLACK)
	if hit[0] == 0:
		return false
	var id: int = hit[0]
	litter = litter.filter(func(piece): return piece["id"] != id)
	_note_collected(1)
	var next := hands.duplicate()
	next[peer] = hand_count(peer) + 1
	hands = next
	if main.cleanup_active:
		_update_left()
	return true

## Host-only, at clock-out (Main.gd's clock_out()): score it, pay it.
## gross = the day's pay before write-ups.
func finish_cleanup(gross: int) -> void:
	if not multiplayer.is_server():
		return
	_update_left()
	var bonus := bonus_for(gross)
	clean_bonus_today = bonus
	clean_bonus_week += bonus
	var next := _fresh_tools()
	tools = next # everyone's hands free for the report
	# PHASE 3D: trash still in hand or in a pan was never thrown away — the
	# night crew bins it, unpaid; a bag goes back in its can.
	hands = {}
	_return_bags()
	print("[Cleanup] Day %d scored — spills & knockovers %d/%d cleaned (%d%%), litter %d/%d (%d%%) -> +$%d; %d binned, %d bag(s) dumped, cans %s" % [main.current_day, mop_total - mop_left, mop_total, roundi(mop_fraction() * 100.0), litter_total - litter_left, litter_total, roundi(litter_fraction() * 100.0), bonus, trash_binned_today, bags_dumped_today, str(cans)])

## The cleanliness bonus `gross` would earn with the floor as it is now (the
## counters are replicated: every peer can say). PHASE 3D: the HUD's "Today"
## counter shows it live during cleanup, so the number at clock-out is
## exactly what's banked.
func bonus_for(gross: int) -> int:
	return int(round(maxf(0.0, float(gross)) * CLEAN_BONUS_MAX * (0.5 * mop_fraction() + 0.5 * litter_fraction())))

## Every peer (replicated counters): share of the category cleaned.
## WEEK 21: + the Break Room's Janitor's Kit (Endless.gd). Every peer (the
## pan's fill art reads it too).
func pan_capacity() -> int:
	return PAN_CAPACITY + main.endless.pan_bonus()

func can_capacity() -> int:
	return CAN_CAPACITY

func mop_fraction() -> float:
	return 1.0 if mop_total <= 0 else clampf(1.0 - float(mop_left) / float(mop_total), 0.0, 1.0)

func litter_fraction() -> float:
	return 1.0 if litter_total <= 0 else clampf(1.0 - float(litter_left) / float(litter_total), 0.0, 1.0)

## --- Phase 3D: what's in whose hands -------------------------------------------

func hand_count(peer: int) -> int:
	return int(hands.get(peer, 0))

## Index into `bags` of the bag this peer carries, or -1.
func bag_of(peer: int) -> int:
	for i in bags.size():
		if bags[i]["holder"] == peer:
			return i
	return -1

## Index of the tool this peer holds, or -1.
func tool_of(peer: int) -> int:
	for i in tools.size():
		if tools[i]["holder"] == peer:
			return i
	return -1

## True while this peer's hands hold anything of this node's (a tool, trash,
## a bag): E goes to it, and stock / customers wait. Every peer.
func holds_anything(peer: int) -> bool:
	return tool_of(peer) >= 0 or hand_count(peer) > 0 or bag_of(peer) >= 0

## Player.gd's speed(): carrying a full bin bag slows you a little.
func speed_mult(peer: int) -> float:
	return BAG_SPEED_MULT if bag_of(peer) >= 0 else 1.0

## --- Phase 3D: cans --------------------------------------------------------------

func can_open(i: int) -> bool:
	return _bin_open(i)

func can_full(i: int) -> bool:
	return int(cans[i]) >= can_capacity()

## Open cans that are full right now (rating input).
func full_cans() -> int:
	var n := 0
	for i in BINS.size():
		if _bin_open(i) and can_full(i):
			n += 1
	return n

## Bags lying on the floor right now (rating input: as bad as a full can).
func loose_bags() -> int:
	return bags.filter(func(b): return b["holder"] == 0).size()

## The open can nearest `pos` within BIN_RANGE (-1 if none); with
## `needs_room`, only one that isn't full; with `needs_trash`, only one with
## something in it.
func can_near(pos: Vector2, needs_room := false, needs_trash := false, slack := 0.0) -> int:
	var best := -1
	var best_d := BIN_RANGE + slack
	for i in BINS.size():
		if not _bin_open(i):
			continue
		if needs_room and can_full(i):
			continue
		if needs_trash and int(cans[i]) <= 0:
			continue
		var d: float = pos.distance_to(BINS[i]["pos"])
		if d <= best_d:
			best_d = d
			best = i
	return best

func near_dumpster(pos: Vector2, slack := 0.0) -> bool:
	return pos.distance_to(DUMPSTER_POS) <= DUMPSTER_RANGE + slack

## Kept from Week 19 (tests read it): any open can in reach.
func _near_bin(pos: Vector2) -> bool:
	return can_near(pos) >= 0

func _bin_open(i: int) -> bool:
	var sec: String = BINS[i]["section"]
	if sec == "":
		return true
	for s in main.SECTIONS:
		if s["name"] == sec:
			return main.is_section_open(s) # WEEK 21: story day or endless posting
	return false

## The cans as they'd be with every bag back in its can (the save).
func cans_with_bags_returned() -> Array:
	var out := cans.duplicate()
	for b in bags:
		var i: int = b["can"]
		if i >= 0 and i < out.size():
			out[i] = mini(can_capacity(), int(out[i]) + int(b["n"]))
	return out

## Practice shift / tests: set a can's fill directly (host).
func set_can(i: int, n: int) -> void:
	if not multiplayer.is_server():
		return
	var next := cans.duplicate()
	next[i] = clampi(n, 0, can_capacity())
	cans = next

## Save/load: the whole array (host). Unknown sizes are padded/cut.
func set_cans(arr: Array) -> void:
	var next := [0, 0, 0, 0, 0]
	for i in mini(arr.size(), next.size()):
		next[i] = clampi(int(arr[i]), 0, can_capacity())
	cans = next

## --- E: any peer asks, the host decides ----------------------------------------
##
## action_for() is what an E press would do here, from THIS peer's view (the
## hint shows it, Player.gd sends it); the host re-checks that exact action
## from its own view in _do() and does nothing if it no longer holds — a
## stale or forged request never turns into a different action.
##   Holding something of ours (always consumes the press):
##     tool:  "pan_empty" (broom with trash, at a can with room) | "tool_put"
##     bag:   "bag_dump" (at the dumpster) | "bag_put"
##     trash: "bin_trash" (at a can with room) | "pick_trash" (more in reach,
##            room in hand) | "hands_full" (more in reach, no room — nothing)
##            | "can_full" (only full cans here — nothing) | "drop_trash"
##   Empty-handed (Player.gd asks only when it holds no stock):
##     "tool_pick" | "bag_pick" | "pick_trash" | "bag_take" | ""
## `stock_in_reach`: loose stock is within E reach — stocking is the job, so
## the empty-handed actions (a tool on the rack, a can's bag, litter) never
## steal an E meant for a product (the 3-player net-orders lesson, see
## Player.gd's litter_beats_stock()). During cleanup tools win, as before.
func action_for(peer: int, pos: Vector2, stock_in_reach: bool, slack := 0.0) -> String:
	var held := tool_of(peer)
	if held >= 0:
		var t: Dictionary = tools[held]
		if t["kind"] == "broom" and int(t["pan"]) > 0 and can_near(pos, true, false, slack) >= 0:
			return "pan_empty"
		return "tool_put"
	if bag_of(peer) >= 0:
		return "bag_dump" if near_dumpster(pos, slack) else "bag_put"
	if hand_count(peer) > 0:
		if can_near(pos, true, false, slack) >= 0:
			return "bin_trash"
		if nearest_litter(pos, LITTER_HAND_RANGE + slack)[0] != 0:
			return "pick_trash" if hand_count(peer) < HAND_MAX else "hands_full"
		if can_near(pos, false, false, slack) >= 0:
			return "can_full"
		return "drop_trash"
	if _nearest_free_tool(pos, slack) >= 0 and (main.cleanup_active or not stock_in_reach):
		return "tool_pick"
	if stock_in_reach:
		return ""
	if _nearest_loose_bag(pos, slack) >= 0:
		return "bag_pick"
	if nearest_litter(pos, LITTER_HAND_RANGE + slack)[0] != 0:
		return "pick_trash"
	if can_near(pos, false, true, slack) >= 0:
		return "bag_take"
	return ""

## Kept for the Week 19 call sites: is there something for E to do with a
## tool here? (True while holding one.)
func wants_interact(peer: int, pos: Vector2) -> bool:
	if tool_of(peer) >= 0:
		return true
	return main.cleanup_active and _nearest_free_tool(pos) >= 0

## Kept for the Week 19 call sites and tests: E with (or reaching for) a tool.
func try_interact() -> void:
	var me := multiplayer.get_unique_id()
	var p = main.players.get(me)
	if p == null:
		return
	var a := action_for(me, p.global_position, false)
	if a in ["pan_empty", "tool_put", "tool_pick"]:
		request(a)

## Any peer: ask the host to do `action` (see action_for()).
func request(action: String) -> void:
	if action in ["", "can_full", "hands_full"]:
		return
	if multiplayer.is_server():
		_do(multiplayer.get_unique_id(), action)
	else:
		_request.rpc_id(1, action)

@rpc("any_peer", "reliable")
func _request(action: String) -> void:
	if multiplayer.is_server():
		_do(multiplayer.get_remote_sender_id(), action)

## Kept for the Week 19 RPC name (an older client build still sends it).
@rpc("any_peer", "reliable")
func _request_tool_interact() -> void:
	if multiplayer.is_server():
		var peer := multiplayer.get_remote_sender_id()
		var p = main.players.get(peer)
		if p != null:
			_do(peer, action_for(peer, p.global_position, false, LITTER_HAND_NET_SLACK))

@rpc("any_peer", "reliable")
func _request_pick_litter() -> void:
	if multiplayer.is_server():
		_do(multiplayer.get_remote_sender_id(), "pick_trash")

## Host-only: do `action` for `peer` if it still makes sense from the host's
## view of them (with a little net slack on every reach). Returns whether it
## happened (tests read it).
func _do(peer: int, action: String) -> bool:
	var p = main.players.get(peer)
	if p == null or not is_instance_valid(p) or main.is_day_report_active() or not main.shift_active:
		return false
	var pos: Vector2 = p.global_position
	var slack := LITTER_HAND_NET_SLACK
	var ok := false
	match action:
		"tool_put":
			var i := tool_of(peer)
			if i >= 0:
				var next := tools.duplicate(true)
				next[i]["holder"] = 0
				next[i]["pos"] = pos
				next[i]["work"] = -1.0
				tools = next
				ok = true
		"pan_empty":
			var i := tool_of(peer)
			var c := can_near(pos, true, false, slack)
			if i >= 0 and c >= 0 and tools[i]["kind"] == "broom" and int(tools[i]["pan"]) > 0:
				var n := mini(int(tools[i]["pan"]), can_capacity() - int(cans[c]))
				var next := tools.duplicate(true)
				next[i]["pan"] = int(next[i]["pan"]) - n
				next[i]["full"] = int(next[i]["pan"]) >= pan_capacity()
				tools = next
				_bin(c, n, peer)
				print("[Cleanup] %s emptied a dustpan (%d pieces) into can %d (%d/%d)" % [main.player_display_name(peer), n, c, cans[c], can_capacity()])
				ok = true
		"tool_pick":
			if not _hands_free(peer):
				return false
			var i := _nearest_free_tool(pos, slack)
			if i >= 0:
				var next := tools.duplicate(true)
				next[i]["holder"] = peer
				tools = next
				ok = true
		"bin_trash":
			var c := can_near(pos, true, false, slack)
			if hand_count(peer) > 0 and c >= 0:
				var n := mini(hand_count(peer), can_capacity() - int(cans[c]))
				var next := hands.duplicate()
				next[peer] = hand_count(peer) - n
				if int(next[peer]) <= 0:
					next.erase(peer)
				hands = next
				_bin(c, n, peer)
				ok = true
		"pick_trash":
			if tool_of(peer) >= 0 or bag_of(peer) >= 0 or _carries_other(peer):
				return false
			ok = _pick_litter(peer, p)
		"drop_trash":
			var n := hand_count(peer)
			if n > 0:
				var next := hands.duplicate()
				next.erase(peer)
				hands = next
				var dir := Vector2.RIGHT.rotated(p.facing_angle)
				for k in n:
					drop_litter(pos + dir * 26.0 + Vector2(randf_range(-12, 12), randf_range(-12, 12)))
				# Back on the floor: it no longer counts as collected.
				litter_collected_today = maxi(0, litter_collected_today - n)
				if main.cleanup_active:
					_update_left()
				ok = true
		"bag_take":
			if not _hands_free(peer):
				return false
			var c := can_near(pos, false, true, slack)
			if c >= 0:
				var next := bags.duplicate(true)
				next.append({"id": _next_bag_id, "holder": peer, "pos": pos, "n": int(cans[c]), "can": c})
				_next_bag_id += 1
				bags = next
				set_can(c, 0)
				ok = true
		"bag_pick":
			if not _hands_free(peer):
				return false
			var b := _nearest_loose_bag(pos, slack)
			if b >= 0:
				var next := bags.duplicate(true)
				next[b]["holder"] = peer
				bags = next
				ok = true
		"bag_put":
			var b := bag_of(peer)
			if b >= 0:
				var next := bags.duplicate(true)
				next[b]["holder"] = 0
				next[b]["pos"] = pos + Vector2.RIGHT.rotated(p.facing_angle) * 28.0
				bags = next
				ok = true
		"bag_dump":
			var b := bag_of(peer)
			if b >= 0 and near_dumpster(pos, slack):
				var n: int = bags[b]["n"]
				bags = bags.filter(func(x): return x["holder"] != peer)
				bags_dumped_today += 1
				_bump_stat(peer, "dumped", 1)
				_announce_dump.rpc(n)
				print("[Cleanup] %s tipped a bag (%d pieces) into the dumpster" % [main.player_display_name(peer), n])
				ok = true
	if ok:
		# Cleaning is work, as far as the manager's concerned.
		var manager := get_tree().get_first_node_in_group("manager")
		if manager:
			manager.note_work(peer)
	return ok

## Every peer: the bag went in — a clang over the dumpster.
@rpc("authority", "call_local", "reliable")
func _announce_dump(n: int) -> void:
	Sfx.play_at("pan_dump", DUMPSTER_POS, 3.0, 0.8)
	var juice = main.get("juice")
	if juice:
		juice.burst(DUMPSTER_POS + Vector2(0, -30), 40.0)
		juice.popup(DUMPSTER_POS + Vector2(0, -60), n, "TRASH OUT! (%d)", juice.C_GOOD, null, true, 1.4)
		juice.spray(juice.particles, DUMPSTER_POS + Vector2(0, -30), 10, juice.C_DUST, Vector2(40, 120), Vector2(0.3, 0.6), 0.0, 0, 3.0)

## Host: nothing in this peer's hands at all — no tool, trash, bag, stock or
## customer.
func _hands_free(peer: int) -> bool:
	return not holds_anything(peer) and not _carries_other(peer)

## Host: carrying stock, or hauling a customer out (Customer.gd's escorted_by).
func _carries_other(peer: int) -> bool:
	for obj in get_tree().get_nodes_in_group("carryable"):
		if obj.get_node("Carryable").carrier_id == peer:
			return true
	for c in get_tree().get_nodes_in_group("customer"):
		if int(c.get("escorted_by")) == peer:
			return true
	return false

func _nearest_free_tool(pos: Vector2, slack := 0.0) -> int:
	var best := -1
	var best_d := TOOL_PICKUP_RANGE + slack
	for i in tools.size():
		if tools[i]["holder"] != 0:
			continue
		var d: float = pos.distance_to(tools[i]["pos"])
		if d < best_d:
			best_d = d
			best = i
	return best

func _nearest_loose_bag(pos: Vector2, slack := 0.0) -> int:
	var best := -1
	var best_d := BAG_RANGE + slack
	for i in bags.size():
		if bags[i]["holder"] != 0:
			continue
		var d: float = pos.distance_to(bags[i]["pos"])
		if d < best_d:
			best_d = d
			best = i
	return best

## Host-only: a player who leaves drops their tool, trash and bag where they
## were.
func drop_tools_of(peer: int) -> void:
	if not multiplayer.is_server():
		return
	var p = main.players.get(peer)
	var at: Vector2 = p.global_position if p != null and is_instance_valid(p) else Vector2.INF
	var i := tool_of(peer)
	if i >= 0:
		var next := tools.duplicate(true)
		next[i]["holder"] = 0
		next[i]["pos"] = at if at != Vector2.INF else TOOL_SPOTS[i]
		next[i]["work"] = -1.0
		tools = next
	var b := bag_of(peer)
	if b >= 0:
		if at == Vector2.INF:
			_return_one_bag(b)
		else:
			var nb := bags.duplicate(true)
			nb[b]["holder"] = 0
			nb[b]["pos"] = at
			bags = nb
	var n := hand_count(peer)
	if n > 0:
		var nh := hands.duplicate()
		nh.erase(peer)
		hands = nh
		if at != Vector2.INF:
			for k in n:
				drop_litter(at + Vector2(randf_range(-14, 14), randf_range(-14, 14)))

func _return_one_bag(b: int) -> void:
	var bag: Dictionary = bags[b]
	var next := bags.duplicate(true)
	next.remove_at(b)
	bags = next
	var c: int = bag["can"]
	if c >= 0 and c < cans.size():
		set_can(c, int(cans[c]) + int(bag["n"]))

## --- Every peer: visuals ------------------------------------------------------

func _sprite(sheet: String, region: Rect2i, scale_factor: float) -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = load(sheet)
	s.region_enabled = true
	s.region_rect = Rect2(region)
	s.scale = Vector2.ONE * scale_factor
	return s

func _small_label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	return label

func _build_station() -> void:
	var station := _sprite(STATION_SHEET, STATION_REGION, 0.75)
	station.name = "ToolStation"
	station.position = STATION_POS
	add_child(station)
	var label := _small_label("CLEANING SUPPLIES", 10, Color(1, 1, 1))
	label.position = STATION_POS + Vector2(-60, -52)
	label.size = Vector2(120, 16)
	add_child(label)

## PHASE 3D — the hub's tool rack: a wall board with two hooks (placeholder
## art, drawn in the station's colors) and a label.
func _build_rack() -> void:
	var rack := Node2D.new()
	rack.name = "ToolRack"
	rack.position = RACK_POS
	var board := Polygon2D.new()
	board.polygon = PackedVector2Array([Vector2(-40, -14), Vector2(40, -14), Vector2(40, 6), Vector2(-40, 6)])
	board.color = Color(0.42, 0.45, 0.5)
	rack.add_child(board)
	var trim := Polygon2D.new()
	trim.polygon = PackedVector2Array([Vector2(-40, 6), Vector2(40, 6), Vector2(40, 9), Vector2(-40, 9)])
	trim.color = Color(0.25, 0.27, 0.3)
	rack.add_child(trim)
	var label := _small_label("MOP & BROOM", 9, Color(1, 1, 1))
	label.position = Vector2(-50, -30)
	label.size = Vector2(100, 14)
	rack.add_child(label)
	add_child(rack)

## PHASE 3D — the dumpster (placeholder art: no pack has one). A dark green
## bin with a lid, wheels and a label; solid, and on the shoppers' grid.
func _build_dumpster() -> void:
	_dumpster = StaticBody2D.new()
	_dumpster.name = "Dumpster"
	_dumpster.position = DUMPSTER_POS
	_dumpster.add_to_group("nav_obstacle")
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = DUMPSTER_SIZE
	shape.shape = rect
	_dumpster.add_child(shape)
	var hw := DUMPSTER_SIZE.x * 0.5
	var body := Polygon2D.new()
	body.polygon = PackedVector2Array([Vector2(-hw, -34), Vector2(hw, -34), Vector2(hw - 6, 24), Vector2(-hw + 6, 24)])
	body.color = Color(0.16, 0.42, 0.24)
	_dumpster.add_child(body)
	var band := Polygon2D.new()
	band.polygon = PackedVector2Array([Vector2(-hw + 2, -8), Vector2(hw - 2, -8), Vector2(hw - 3, -2), Vector2(-hw + 3, -2)])
	band.color = Color(0.1, 0.3, 0.16)
	_dumpster.add_child(band)
	var lid := Polygon2D.new()
	lid.name = "Lid"
	lid.polygon = PackedVector2Array([Vector2(-hw - 3, -44), Vector2(hw + 3, -44), Vector2(hw + 3, -34), Vector2(-hw - 3, -34)])
	lid.color = Color(0.1, 0.12, 0.12)
	_dumpster.add_child(lid)
	for x in [-hw + 14, hw - 14]:
		var wheel := Polygon2D.new()
		var pts := PackedVector2Array()
		for a in 10:
			pts.append(Vector2(x, 26) + Vector2.RIGHT.rotated(TAU * a / 10.0) * 6.0)
		wheel.polygon = pts
		wheel.color = Color(0.08, 0.08, 0.08)
		_dumpster.add_child(wheel)
	var label := _small_label("TRASH", 14, Color(0.9, 1, 0.9))
	label.position = Vector2(-40, -30)
	label.size = Vector2(80, 20)
	_dumpster.add_child(label)
	var tag := _small_label("DUMPSTER — bags go here", 10, Color(1, 1, 1))
	tag.position = Vector2(-80, 34)
	tag.size = Vector2(160, 16)
	_dumpster.add_child(tag)
	add_child(_dumpster)

## PHASE 3D — per can: a fill meter beside it, and (full) a heap of trash on
## and around it, flies, and a red FULL tag. Read off `cans` every frame.
func _build_can_fx() -> Node2D:
	var fx := Node2D.new()
	fx.z_index = 1
	var meter_bg := Polygon2D.new()
	meter_bg.name = "MeterBg"
	meter_bg.polygon = PackedVector2Array([Vector2(16, -42), Vector2(22, -42), Vector2(22, 2), Vector2(16, 2)])
	meter_bg.color = Color(0, 0, 0, 0.65)
	fx.add_child(meter_bg)
	var meter := Polygon2D.new()
	meter.name = "Meter"
	meter.polygon = PackedVector2Array([Vector2(17, 1), Vector2(21, 1), Vector2(21, -41), Vector2(17, -41)])
	fx.add_child(meter)
	var heap := Node2D.new()
	heap.name = "Heap"
	var spots := [Vector2(-8, -46), Vector2(4, -50), Vector2(-2, -42), Vector2(-20, 2), Vector2(16, 6), Vector2(-10, 10)]
	for i in spots.size():
		var s := _sprite(MARKET_SHEET_4, LITTER_REGIONS[(i * 3) % LITTER_REGIONS.size()], LITTER_SCALE)
		s.position = spots[i]
		s.rotation = (i * 1.7) - 2.0
		heap.add_child(s)
	var full := _small_label("FULL", 12, Color(1, 0.3, 0.25))
	full.name = "Full"
	full.position = Vector2(-24, -76)
	full.size = Vector2(48, 16)
	heap.add_child(full)
	var flies := Node2D.new()
	flies.name = "Flies"
	for i in 3:
		var f := Polygon2D.new()
		f.polygon = PackedVector2Array([Vector2(-1.5, -1.5), Vector2(1.5, -1.5), Vector2(1.5, 1.5), Vector2(-1.5, 1.5)])
		f.color = Color(0.08, 0.08, 0.08)
		flies.add_child(f)
	heap.add_child(flies)
	heap.visible = false
	fx.add_child(heap)
	return fx

## PLACEHOLDER ART (no mop or broom in either pack): a handle, and a mop head
## (grey-white strands, blue bucket-band) or a broom head (straw bristles +
## a dustpan whose fill shows the pan). Drawn standing up, head down.
func _build_tool_node(kind: String) -> Node2D:
	var node := Node2D.new()
	node.name = "Mop" if kind == "mop" else "Broom"
	# The tool itself under "Art" (it wiggles while working); the progress
	# bar on the node, so it stays level and readable.
	var art := Node2D.new()
	art.name = "Art"
	art.scale = Vector2(1.35, 1.35)
	node.add_child(art)
	var handle := Polygon2D.new()
	handle.polygon = PackedVector2Array([Vector2(-1.5, -34), Vector2(1.5, -34), Vector2(1.5, 0), Vector2(-1.5, 0)])
	handle.color = Color(0.55, 0.38, 0.2) if kind == "broom" else Color(0.75, 0.75, 0.8)
	art.add_child(handle)
	var head := Polygon2D.new()
	head.name = "Head"
	if kind == "mop":
		head.polygon = PackedVector2Array([Vector2(-9, 0), Vector2(9, 0), Vector2(11, 12), Vector2(6, 9), Vector2(3, 13), Vector2(0, 9), Vector2(-3, 13), Vector2(-6, 9), Vector2(-11, 12)])
		head.color = Color(0.92, 0.92, 0.85)
		var band := Polygon2D.new()
		band.polygon = PackedVector2Array([Vector2(-9, -3), Vector2(9, -3), Vector2(9, 1), Vector2(-9, 1)])
		band.color = Color(0.2, 0.45, 0.85)
		art.add_child(head)
		art.add_child(band)
	else:
		head.polygon = PackedVector2Array([Vector2(-4, 0), Vector2(4, 0), Vector2(11, 12), Vector2(-11, 12)])
		head.color = Color(0.9, 0.75, 0.35)
		art.add_child(head)
		var pan := Polygon2D.new()
		pan.name = "Pan"
		pan.polygon = PackedVector2Array([Vector2(8, 6), Vector2(20, 6), Vector2(20, 16), Vector2(8, 16)])
		pan.color = Color(0.25, 0.3, 0.35)
		art.add_child(pan)
		var fill := Polygon2D.new()
		fill.name = "Fill"
		fill.polygon = PackedVector2Array([Vector2(9, 15), Vector2(19, 15), Vector2(19, 7), Vector2(9, 7)])
		fill.color = Color(0.6, 0.5, 0.35)
		art.add_child(fill)
	var bar_bg := Polygon2D.new()
	bar_bg.name = "BarBg"
	bar_bg.polygon = PackedVector2Array([Vector2(-20, -50), Vector2(20, -50), Vector2(20, -42), Vector2(-20, -42)])
	bar_bg.color = Color(0, 0, 0, 0.7)
	node.add_child(bar_bg)
	var bar := Polygon2D.new()
	bar.name = "Bar"
	bar.polygon = PackedVector2Array([Vector2(0, -49), Vector2(38, -49), Vector2(38, -43), Vector2(0, -43)])
	bar.position = Vector2(-19, 0) # grows rightward from the left edge
	bar.color = Color(0.4, 1, 0.5)
	node.add_child(bar)
	return node

## PLACEHOLDER ART — a black bin bag, tied at the top. Bigger with more in it.
func _build_bag_node() -> Node2D:
	var node := Node2D.new()
	var sack := Polygon2D.new()
	sack.name = "Sack"
	sack.polygon = PackedVector2Array([Vector2(-4, -14), Vector2(4, -14), Vector2(11, -6), Vector2(13, 4), Vector2(9, 11), Vector2(-9, 11), Vector2(-13, 4), Vector2(-11, -6)])
	sack.color = Color(0.12, 0.12, 0.14)
	node.add_child(sack)
	var shine := Polygon2D.new()
	shine.polygon = PackedVector2Array([Vector2(-8, -4), Vector2(-5, -8), Vector2(-4, 2), Vector2(-7, 4)])
	shine.color = Color(1, 1, 1, 0.18)
	node.add_child(shine)
	var tie := Polygon2D.new()
	tie.polygon = PackedVector2Array([Vector2(-5, -20), Vector2(0, -14), Vector2(5, -20), Vector2(0, -17)])
	tie.color = Color(0.85, 0.75, 0.2)
	node.add_child(tie)
	return node

## PLACEHOLDER ART — a sticky puddle: a lumpy brown blob and a tipped cup.
func _build_puddle_node(pd: Dictionary) -> Node2D:
	var node := Node2D.new()
	node.position = pd["pos"]
	var rng := RandomNumberGenerator.new()
	rng.seed = int(pd["id"]) * 4241
	var r: float = pd["r"]
	var pts := PackedVector2Array()
	for i in 12:
		pts.append(Vector2.RIGHT.rotated(TAU * i / 12.0) * r * rng.randf_range(0.75, 1.15) * Vector2(1.0, 0.7))
	var blob := Polygon2D.new()
	blob.polygon = pts
	blob.color = PUDDLE_COLOR
	node.add_child(blob)
	var shine := Polygon2D.new()
	shine.polygon = PackedVector2Array([Vector2(-0.4, -0.3) * r, Vector2(-0.05, -0.4) * r, Vector2(0.0, -0.3) * r, Vector2(-0.3, -0.18) * r])
	shine.color = Color(1, 1, 1, 0.3)
	node.add_child(shine)
	var cup := _sprite(MARKET_SHEET_4, LITTER_REGIONS[6], LITTER_SCALE)
	cup.position = Vector2(r * 0.7, -r * 0.3)
	cup.rotation = PI * 0.5
	node.add_child(cup)
	return node

func _process(_delta: float) -> void:
	var cleanup: bool = main.cleanup_active
	var t_now := Time.get_ticks_msec() / 1000.0
	# Litter.
	var live := {}
	for piece in litter:
		var id: int = piece["id"]
		live[id] = true
		if not _litter_nodes.has(id):
			var s := _sprite(MARKET_SHEET_4, LITTER_REGIONS[int(piece["v"]) % LITTER_REGIONS.size()], LITTER_SCALE)
			s.position = piece["pos"]
			s.rotation = piece["rot"]
			s.modulate = Color(0.85, 0.82, 0.78) # a little scuffed
			_litter_root.add_child(s)
			_litter_nodes[id] = s
	for id in _litter_nodes.keys():
		if not live.has(id):
			_litter_nodes[id].queue_free()
			_litter_nodes.erase(id)
	# Puddles (on the floor, with the litter).
	var live_p := {}
	for pd in puddles:
		var id: int = pd["id"]
		live_p[id] = true
		if not _puddle_nodes.has(id):
			_puddle_nodes[id] = _build_puddle_node(pd)
			_litter_root.add_child(_puddle_nodes[id])
	for id in _puddle_nodes.keys():
		if not live_p.has(id):
			_puddle_nodes[id].queue_free()
			_puddle_nodes.erase(id)
	# Cans: only the open sections', with their fill and overflow.
	for i in _bin_nodes.size():
		var open := _bin_open(i)
		_bin_nodes[i].visible = open
		var fx: Node2D = _can_fx[i]
		fx.visible = open
		if not open or i >= cans.size():
			continue
		var k := clampf(float(cans[i]) / can_capacity(), 0.0, 1.0)
		var meter: Polygon2D = fx.get_node("Meter")
		meter.visible = k > 0.0
		meter.scale = Vector2(1.0, k)
		meter.position = Vector2(0, 1.0 - k)
		meter.color = Color(0.35, 0.9, 0.4) if k < 0.6 else (Color(1, 0.8, 0.2) if k < 1.0 else Color(1, 0.25, 0.2))
		var heap: Node2D = fx.get_node("Heap")
		heap.visible = k >= 1.0
		if heap.visible:
			heap.get_node("Full").modulate.a = 0.55 + 0.45 * sin(t_now * 6.0)
			var flies: Node2D = heap.get_node("Flies")
			for f in flies.get_child_count():
				var a := t_now * (3.0 + f) + f * 2.1
				flies.get_child(f).position = Vector2(cos(a) * 14.0, -54.0 + sin(a * 1.3) * 7.0)
	# Bags: in someone's hands (in front of them) or on the floor.
	var live_b := {}
	for b in bags:
		var id: int = b["id"]
		live_b[id] = true
		if not _bag_nodes.has(id):
			_bag_nodes[id] = _build_bag_node()
			add_child(_bag_nodes[id])
		var node: Node2D = _bag_nodes[id]
		node.scale = Vector2.ONE * lerpf(0.8, 1.25, clampf(float(b["n"]) / can_capacity(), 0.0, 1.0))
		var holder: int = b["holder"]
		var hp = main.players.get(holder) if holder != 0 else null
		if hp != null and is_instance_valid(hp):
			node.position = hp.global_position + Vector2.RIGHT.rotated(hp.facing_angle) * 26.0 + Vector2(0, -6)
			node.rotation = sin(t_now * 9.0) * 0.12
			node.z_index = Z_HELD
		else:
			node.position = b["pos"]
			node.rotation = 0.0
			node.z_index = Z_ON_FLOOR
	for id in _bag_nodes.keys():
		if not live_b.has(id):
			_bag_nodes[id].queue_free()
			_bag_nodes.erase(id)
	# Trash in hand: a little stack in front of whoever's holding it.
	for peer in _hand_nodes.keys():
		if hand_count(peer) <= 0 or not main.players.has(peer):
			_hand_nodes[peer].queue_free()
			_hand_nodes.erase(peer)
	for peer in hands:
		var hp = main.players.get(peer)
		if hp == null or not is_instance_valid(hp) or hand_count(peer) <= 0:
			continue
		if not _hand_nodes.has(peer):
			var hn := Node2D.new()
			hn.z_index = Z_HELD
			add_child(hn)
			_hand_nodes[peer] = hn
		var hn: Node2D = _hand_nodes[peer]
		var n := hand_count(peer)
		while hn.get_child_count() < n:
			var s := _sprite(MARKET_SHEET_4, LITTER_REGIONS[(hn.get_child_count() * 5 + 2) % LITTER_REGIONS.size()], LITTER_SCALE)
			s.rotation = hn.get_child_count() * 0.9 - 0.6
			s.position = Vector2(0, -7.0 * hn.get_child_count())
			hn.add_child(s)
		while hn.get_child_count() > n:
			var last := hn.get_child(hn.get_child_count() - 1)
			hn.remove_child(last)
			last.queue_free()
		hn.position = hp.global_position + Vector2.RIGHT.rotated(hp.facing_angle) * 22.0 + Vector2(0, -4)
	# Tools.
	var me := multiplayer.get_unique_id() if Net.is_active() else 0
	for i in mini(tools.size(), _tool_nodes.size()):
		var t: Dictionary = tools[i]
		var node: Node2D = _tool_nodes[i]
		var holder: int = t["holder"]
		var p = main.players.get(holder) if holder != 0 else null
		if p != null and is_instance_valid(p):
			# Held out in front, head on the floor where it's working.
			var dir := Vector2.RIGHT.rotated(p.facing_angle)
			node.position = p.global_position + dir * (MOP_HEAD_OFFSET if t["kind"] == "mop" else BROOM_HEAD_OFFSET) + Vector2(0, -8)
			node.z_index = Z_HELD
			var working := float(t["work"]) >= 0.0
			node.get_node("Art").rotation = sin(Time.get_ticks_msec() * 0.02) * 0.35 if working else 0.0
		else:
			node.position = t["pos"]
			node.get_node("Art").rotation = 0.0
			node.z_index = Z_ON_FLOOR
		var work := float(t["work"])
		node.get_node("Bar").visible = work >= 0.0 and work < 1.0
		node.get_node("BarBg").visible = node.get_node("Bar").visible
		if work >= 0.0:
			node.get_node("Bar").scale.x = clampf(work, 0.05, 1.0)
		if t["kind"] == "broom":
			var k := clampf(float(t["pan"]) / pan_capacity(), 0.0, 1.0)
			var fill: Polygon2D = node.get_node("Art/Fill")
			fill.visible = k > 0.0
			fill.scale = Vector2(1.0, k)
			fill.position = Vector2(0, 15.0 * (1.0 - k))
			fill.color = Color(0.85, 0.3, 0.2) if t["full"] else Color(0.6, 0.5, 0.35)
	# Markers on knocked stock (cleanup only) — a small ring under each, so the
	# mess that counts reads at a glance.
	var want := {}
	if cleanup:
		for n in knocked_names:
			want[n] = true
	for n in _markers.keys():
		if not want.has(n):
			_markers[n].queue_free()
			_markers.erase(n)
	for n in want:
		var obj: Node2D = main.products_root.get_node_or_null(NodePath(n))
		if obj == null:
			continue
		if not _markers.has(n):
			var ring := Line2D.new()
			var pts := PackedVector2Array()
			for a in 13:
				pts.append(Vector2.RIGHT.rotated(TAU * a / 12.0) * 20.0)
			ring.points = pts
			ring.width = 2.0
			ring.default_color = Color(1, 0.55, 0.15, 0.85)
			_marker_root.add_child(ring)
			_markers[n] = ring
		_markers[n].position = obj.global_position
	_update_hint(me, cleanup)
	# PHASE 3D: hauling a troublemaker — a chevron at my feet toward the door.
	var hauling: bool = _my_player(me) != null and _my_player(me).escorting()
	if hauling or _drew_door_arrow:
		queue_redraw()
	_drew_door_arrow = hauling

const FRONT_DOOR := Vector2(1440.0, 1100.0)
var _drew_door_arrow := false
func _draw() -> void:
	var me := multiplayer.get_unique_id() if Net.is_active() else 0
	var p: Node2D = _my_player(me)
	if p == null or not p.escorting():
		return
	var to := FRONT_DOOR - p.global_position
	if to.length() < 120.0:
		return
	var dir := to.normalized()
	var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.01)
	var tip := p.global_position + dir * (100.0 + 6.0 * pulse) # past the one being hauled
	var side := dir.orthogonal() * 11.0
	draw_colored_polygon(PackedVector2Array([tip, tip - dir * 16.0 + side, tip - dir * 10.0, tip - dir * 16.0 - side]), Color(1, 0.4, 0.3, 0.7 + 0.3 * pulse))
	draw_string(ThemeDB.fallback_font, tip + dir * 6.0 + Vector2(-40, -6), "FRONT DOOR", HORIZONTAL_ALIGNMENT_CENTER, 80, 11, Color(1, 0.45, 0.35))

## The contextual hint over my own player's head — the same action_for() an
## E press would send, so it always tells the truth.
var hint_text := "" # tests read it
func _update_hint(me: int, cleanup: bool) -> void:
	_hint.visible = false
	hint_text = ""
	var p: Node2D = _my_player(me)
	if p == null or main.is_day_report_active() or not main.shift_active:
		return
	if cleanup and main.near_time_clock(p.global_position) and not holds_anything(me):
		return # E clocks out there (Main.gd's own hint)
	if p.carried_count(me) > 0 or p.escorting():
		return
	var text := ""
	var a := action_for(me, p.global_position, p.loose_stock_in_reach())
	var held := tool_of(me)
	match a:
		"pan_empty":
			text = "E: empty the dustpan into the can (%d)" % tools[held]["pan"]
		"tool_put":
			var t: Dictionary = tools[held]
			if t["kind"] == "broom" and t["full"]:
				text = "Dustpan full — empty it at a trash can"
			elif float(t["work"]) < 0.0:
				text = "Hold %s: %s  ·  E: put it down" % [_place_key(me), "mop" if t["kind"] == "mop" else "sweep"]
		"tool_pick":
			text = "E: pick up the %s" % tools[_nearest_free_tool(p.global_position)]["kind"]
		"bag_dump":
			text = "E: into the dumpster!"
		"bag_put":
			text = "Take the bag to the DUMPSTER (out back, Storage)  ·  E: set it down"
		"bin_trash":
			text = "E: throw it in the can  (+$%d)" % (hand_count(me) * LITTER_PAY_PER_PIECE)
		"pick_trash":
			text = "E: pick up trash" + (" (%d/%d in hand)" % [hand_count(me), HAND_MAX] if hand_count(me) > 0 else "")
		"can_full":
			text = "This can's FULL — take its bag to the dumpster"
		"hands_full":
			text = "Hands full (%d) — throw it in a trash can" % hand_count(me)
		"drop_trash":
			text = "Trash in hand (%d) — throw it in a trash can  ·  E: drop it" % hand_count(me)
		"bag_pick":
			text = "E: pick up the bin bag"
		"bag_take":
			var c := can_near(p.global_position, false, true)
			text = "E: take the bag out (%d/%d)" % [cans[c], can_capacity()] + ("  — it's FULL!" if can_full(c) else "")
	if text == "":
		return
	hint_text = text
	_hint.text = text
	_hint.size = Vector2(maxf(260.0, text.length() * 7.5), 22)
	_hint.position = p.global_position + Vector2(-_hint.size.x * 0.5, -62)
	_hint.visible = true

## This peer's own player, if it's (still) there.
func _my_player(me: int) -> Node2D:
	var p = main.players.get(me)
	return p if p != null and is_instance_valid(p) and p.is_inside_tree() else null

func _place_key(me: int) -> String:
	return "C" if me == 1 else "/"
