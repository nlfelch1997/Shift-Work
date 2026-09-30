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
## 1. SPILLS & KNOCKOVERS -> the MOP. Nothing new is generated for this: it's
##    what the day already left behind. Floor spills still on the floor
##    (Ambience.gd, Day 6+ — their drying clock stops at close, so what's
##    there at close stays until mopped); floor displays still knocked over
##    (Display.gd — mopping one up stands it back on its spot); and stock
##    that got KNOCKED off a shelf (a forklift wreck, a shove, a bump — not a
##    normal pickup) and never went back on one. Shelf.gd tags such an item
##    ("knocked" meta, host-side) and untags it when it settles into a slot
##    again, so putting it back by hand clears it too. Mopping a knocked item
##    bins it as damaged stock (the product is freed).
## 2. LITTER -> the BROOM. New: customers drop trash (wrappers, bottles,
##    cans) while they're in the store, at a rate per customer present — so
##    it tracks the crowd, not how well the crew plays. Litter is cosmetic
##    during the shift (no slip, no blocking). The broom sweeps up every
##    piece near its head at once into its dustpan, which holds PAN_CAPACITY
##    pieces; a full pan has to be emptied at a trash bin (E) before it
##    sweeps again.
##
## THE TOOLS are the first held objects that aren't stock, so they are NOT
## Carryables (see Ambience.gd's old "no mop" note and Display.gd's header:
## anything in the "carryable" group is sellable stock everywhere). They're
## plain replicated state here: `tools` (kind, holder peer, resting spot,
## pan fill, what it's working on). Only available once the store closes —
## during the shift they sit on the station (flagged design call: spills stay
## a selling-window hazard you route around, the manager never has to judge
## someone scrubbing, and there's one clear moment the job switches).
## E at the station picks one up (empty hands); E again puts it down where
## you stand (or empties the broom's pan, at a bin). HOLD the place key (C)
## to use it: the owner's Player.gd replicates `using_tool`, and the HOST
## does the work against its own view of the player — the same "any peer
## may ask, only the host decides" shape as the Store sign.
##
## SCORING: each category is the share of that category's mess that's gone
## at clock-out (a category with no mess at all scores 100%). The bonus is
## CLEAN_BONUS_MAX of the day's gross pay (sales + priority-order bonus,
## before write-ups), split evenly between the two categories. Mess made
## during cleanup (bumping a display over while mopping) counts too.
##
## ART: litter pieces are the supermarket pack's loose snack/drink sprites
## (assets/supermarket/4.png); the trash bin is the same pack's grey
## push-flap bin (11.png); the tool station (break room, by the time clock)
## is the warehouse pack's pegboard workbench (tile-B-03.png); the time clock is the supermarket pack's card
## kiosk (1.png). NEITHER PACK HAS A MOP OR A BROOM — both are placeholder
## Polygon2D shapes, flagged for future art sourcing.
##
## Every number below is a FLAGGED placeholder, tuned against the bot sims
## in tools/hazards_test.gd (--test=cleanup / net-cleanup / solo), not a
## human playtest.

## --- Litter generation (selling window only) ---
## Pieces per customer per second in the store (hub + unlocked sections).
## ~1 per customer-minute: Day 1-2 (5 customers) ~8 a day, Day 7 (17) ~25.
const LITTER_RATE_PER_CUSTOMER := 1.0 / 60.0
const LITTER_MAX_ON_FLOOR := 40
const LITTER_CLEAR_SLOT := 30.0 # never inside a shelf slot's capture circle
const LITTER_JITTER := 14.0 # dropped at the customer's feet, give or take
## --- Tools ---
const MOPS := 2
const BROOMS := 2
const TOOL_PICKUP_RANGE := 60.0
const MOP_HEAD_OFFSET := 30.0 # from the player's center, along their facing
const MOP_REACH := 34.0 # + the mess's own radius (26 read as fiddly: the bot sims kept stopping just short)
const MOP_TIME_SPILL_BASE := 1.0 # s — plus MOP_TIME_SPILL_PER_PX * radius (a 38-54px spill: 2.1-2.6s)
const MOP_TIME_SPILL_PER_PX := 0.03
const MOP_TIME_DISPLAY := 1.6
const MOP_TIME_STOCK := 0.8
const BROOM_HEAD_OFFSET := 30.0
const BROOM_RADIUS := 50.0
const SWEEP_TIME := 0.45 # s of sweeping over a piece to get it in the pan
const PAN_CAPACITY := 8
const BIN_RANGE := 70.0
## --- Scoring ---
const CLEAN_BONUS_MAX := 0.25 # a spotless store: +25% of the day's gross pay

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
const STATION_POS := Vector2(700.0, 280.0)
const TOOL_SPOTS := [Vector2(660.0, 320.0), Vector2(678.0, 320.0), Vector2(722.0, 320.0), Vector2(740.0, 320.0)]
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

## Host-only.
var _next_litter_id := 1
var _litter_timer := 1.0
var _progress := {} # mess key -> 0..1
var _knocked_refresh := 0.0
var litter_dropped_today := 0

## Local visuals.
var main: Node
var _litter_root: Node2D
var _litter_nodes := {} # id -> Sprite2D
var _tool_nodes: Array = []
var _bin_nodes: Array = []
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
	for prop in [".:litter", ".:tools", ".:knocked_names", ".:mop_total", ".:mop_left", ".:litter_total", ".:litter_left", ".:clean_bonus_today", ".:clean_bonus_week"]:
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
	for b in BINS:
		var bin := _sprite(BIN_SHEET, BIN_REGION, 0.8)
		bin.position = b["pos"] + Vector2(0, -18) # feet on the spot
		add_child(bin)
		_bin_nodes.append(bin)
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
func reset_for_new_day() -> void:
	if not multiplayer.is_server():
		return
	litter = []
	tools = _fresh_tools()
	knocked_names = []
	_progress = {}
	_litter_timer = randf_range(0.6, 1.4)
	litter_dropped_today = 0
	mop_total = 0
	mop_left = 0
	litter_total = 0
	litter_left = 0
	clean_bonus_today = 0

## --- Host: during the selling window ------------------------------------

## Host-only, every frame the store is open (Main.gd's _process()).
func tick_selling(delta: float) -> void:
	if not multiplayer.is_server():
		return
	var inside: Array = get_tree().get_nodes_in_group("customer").filter(func(c): return _litter_zone_ok(c.global_position))
	if inside.is_empty():
		return
	_litter_timer -= delta * inside.size() * LITTER_RATE_PER_CUSTOMER
	if _litter_timer > 0.0:
		return
	_litter_timer = randf_range(0.6, 1.4)
	if litter.size() >= LITTER_MAX_ON_FLOOR:
		return
	var who: Node2D = inside[randi() % inside.size()]
	for attempt in 6:
		var pos := who.global_position + Vector2(randf_range(-LITTER_JITTER, LITTER_JITTER), randf_range(-LITTER_JITTER, LITTER_JITTER))
		if _litter_spot_ok(pos):
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

## Host-only, every frame of the cleanup phase.
func tick_cleanup(delta: float) -> void:
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
				work = _mop_at(head, delta)
			else:
				var r := _sweep_at(head, delta, t["pan"])
				work = r[0]
				if r[1] > 0:
					t["pan"] = int(t["pan"]) + int(r[1])
					changed = true
		if t["kind"] == "broom":
			full = int(t["pan"]) >= PAN_CAPACITY
		if not is_equal_approx(float(t["work"]), work) or t["full"] != full:
			t["work"] = work
			t["full"] = full
			changed = true
	if changed:
		tools = next_tools
	_knocked_refresh -= delta
	if _knocked_refresh <= 0.0:
		_knocked_refresh = 0.25
		_refresh_knocked()
		_update_left()

## Every mop-category mess on the floor right now:
## [{"key", "kind", "pos", "r", "time", "ref"}]
func _mop_messes() -> Array:
	var out := []
	for s in main.ambience.spills:
		out.append({"key": "s%d" % s["id"], "kind": "spill", "pos": s["pos"], "r": s["r"], "time": MOP_TIME_SPILL_BASE + MOP_TIME_SPILL_PER_PX * s["r"], "ref": s["id"]})
	for i in main.displays.size():
		var d: Node = main.displays[i]
		if d.get_node("Display").toppled:
			out.append({"key": "d%d" % i, "kind": "display", "pos": d.global_position, "r": 24.0, "time": MOP_TIME_DISPLAY, "ref": d})
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
func _mop_at(head: Vector2, delta: float) -> float:
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
	var prog: float = _progress.get(k, 0.0) + delta / float(best["time"])
	if prog < 1.0:
		_progress[k] = prog
		return prog
	_progress.erase(k)
	match String(best["kind"]):
		"spill":
			main.ambience.remove_spill(best["ref"])
		"display":
			best["ref"].get_node("Display").reset_to_home()
		"stock":
			best["ref"].queue_free()
	print("[Cleanup] mopped up a %s" % best["kind"])
	_update_left()
	return 1.0

## Sweeps every piece in the broom's reach. Returns [progress of the
## furthest-along piece or -1, pieces that went in the pan].
func _sweep_at(head: Vector2, delta: float, pan: int) -> Array:
	var room := PAN_CAPACITY - pan
	var best := -1.0
	var swept := []
	for piece in litter:
		if head.distance_to(piece["pos"]) > BROOM_RADIUS:
			continue
		var k := "l%d" % piece["id"]
		if room <= 0:
			best = maxf(best, _progress.get(k, 0.0))
			continue
		var prog: float = _progress.get(k, 0.0) + delta / SWEEP_TIME
		if prog >= 1.0 and swept.size() < room:
			swept.append(piece["id"])
			_progress.erase(k)
			best = 1.0
		else:
			_progress[k] = minf(prog, 0.99)
			best = maxf(best, _progress[k])
	if not swept.is_empty():
		litter = litter.filter(func(p): return not (p["id"] in swept))
		_update_left()
	return [best, swept.size()]

## Host-only, at clock-out (Main.gd's clock_out()): score it, pay it.
## gross = the day's pay before write-ups.
func finish_cleanup(gross: int) -> void:
	if not multiplayer.is_server():
		return
	_update_left()
	var bonus := int(round(maxf(0.0, float(gross)) * CLEAN_BONUS_MAX * (0.5 * mop_fraction() + 0.5 * litter_fraction())))
	clean_bonus_today = bonus
	clean_bonus_week += bonus
	var next := _fresh_tools()
	tools = next # everyone's hands free for the report
	print("[Cleanup] Day %d scored — spills & knockovers %d/%d cleaned (%d%%), litter %d/%d (%d%%) -> +$%d" % [main.current_day, mop_total - mop_left, mop_total, roundi(mop_fraction() * 100.0), litter_total - litter_left, litter_total, roundi(litter_fraction() * 100.0), bonus])

## Every peer (replicated counters): share of the category cleaned.
func mop_fraction() -> float:
	return 1.0 if mop_total <= 0 else clampf(1.0 - float(mop_left) / float(mop_total), 0.0, 1.0)

func litter_fraction() -> float:
	return 1.0 if litter_total <= 0 else clampf(1.0 - float(litter_left) / float(litter_total), 0.0, 1.0)

## --- Tools: any peer asks, the host decides ---------------------------------

## Index of the tool this peer holds, or -1.
func tool_of(peer: int) -> int:
	for i in tools.size():
		if tools[i]["holder"] == peer:
			return i
	return -1

## Any peer: is there something for E to do with a tool here? (Player.gd
## asks before trying to pick up stock.)
func wants_interact(peer: int, pos: Vector2) -> bool:
	if tool_of(peer) >= 0:
		return true
	return main.cleanup_active and _nearest_free_tool(pos) >= 0

## Any peer: the local player pressed E with (or reaching for) a tool.
func try_interact() -> void:
	if multiplayer.is_server():
		_tool_interact(multiplayer.get_unique_id())
	else:
		_request_tool_interact.rpc_id(1)

@rpc("any_peer", "reliable")
func _request_tool_interact() -> void:
	if multiplayer.is_server():
		_tool_interact(multiplayer.get_remote_sender_id())

## Host-only. Holding one: empty the pan at a bin, else set it down.
## Empty-handed during cleanup: pick up the nearest free one in reach.
## Checked against where the HOST sees the player.
func _tool_interact(peer: int) -> void:
	var p = main.players.get(peer)
	if p == null or not is_instance_valid(p):
		return
	var pos: Vector2 = p.global_position
	var next := tools.duplicate(true)
	var held := tool_of(peer)
	if held >= 0:
		var t: Dictionary = next[held]
		if t["kind"] == "broom" and int(t["pan"]) > 0 and _near_bin(pos):
			print("[Cleanup] %s emptied a dustpan (%d pieces)" % [main.player_display_name(peer), t["pan"]])
			t["pan"] = 0
			t["full"] = false
		else:
			t["holder"] = 0
			t["pos"] = pos
			t["work"] = -1.0
	elif main.cleanup_active:
		var i := _nearest_free_tool(pos)
		if i < 0:
			return
		next[i]["holder"] = peer
	tools = next

func _nearest_free_tool(pos: Vector2) -> int:
	var best := -1
	var best_d := TOOL_PICKUP_RANGE
	for i in tools.size():
		if tools[i]["holder"] != 0:
			continue
		var d: float = pos.distance_to(tools[i]["pos"])
		if d < best_d:
			best_d = d
			best = i
	return best

func _near_bin(pos: Vector2) -> bool:
	for i in BINS.size():
		if _bin_open(i) and pos.distance_to(BINS[i]["pos"]) <= BIN_RANGE:
			return true
	return false

func _bin_open(i: int) -> bool:
	var sec: String = BINS[i]["section"]
	if sec == "":
		return true
	for s in main.SECTIONS:
		if s["name"] == sec:
			return main.current_day >= s["required_day"]
	return false

## Host-only: a player who leaves drops their tool where they were.
func drop_tools_of(peer: int) -> void:
	if not multiplayer.is_server():
		return
	var i := tool_of(peer)
	if i < 0:
		return
	var next := tools.duplicate(true)
	var p = main.players.get(peer)
	next[i]["holder"] = 0
	next[i]["pos"] = p.global_position if p != null and is_instance_valid(p) else TOOL_SPOTS[i]
	next[i]["work"] = -1.0
	tools = next

## --- Every peer: visuals ------------------------------------------------------

func _sprite(sheet: String, region: Rect2i, scale_factor: float) -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = load(sheet)
	s.region_enabled = true
	s.region_rect = Rect2(region)
	s.scale = Vector2.ONE * scale_factor
	return s

func _build_station() -> void:
	var station := _sprite(STATION_SHEET, STATION_REGION, 0.75)
	station.name = "ToolStation"
	station.position = STATION_POS
	add_child(station)
	var label := Label.new()
	label.text = "CLEANING SUPPLIES"
	label.position = STATION_POS + Vector2(-60, -52)
	label.size = Vector2(120, 16)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", Color(1, 1, 1))
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(label)

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

func _process(_delta: float) -> void:
	var cleanup: bool = main.cleanup_active
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
	# Bins: only the open sections'.
	for i in _bin_nodes.size():
		_bin_nodes[i].visible = _bin_open(i)
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
			var k := clampf(float(t["pan"]) / PAN_CAPACITY, 0.0, 1.0)
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

## The contextual hint over my own player's head.
func _update_hint(me: int, cleanup: bool) -> void:
	_hint.visible = false
	if not cleanup or not main.players.has(me) or main.is_day_report_active():
		return
	var p: Node2D = main.players[me]
	if main.near_time_clock(p.global_position):
		return # E clocks out there (Main.gd's own hint)
	var held := tool_of(me)
	var text := ""
	if held >= 0:
		var t: Dictionary = tools[held]
		if t["kind"] == "broom" and int(t["pan"]) > 0 and _near_bin(p.global_position):
			text = "E: empty the dustpan (%d)" % t["pan"]
		elif t["kind"] == "broom" and t["full"]:
			text = "Dustpan full — empty it at a trash bin"
		elif float(t["work"]) < 0.0:
			text = "Hold C: %s  ·  E: put it down" % ("mop" if t["kind"] == "mop" else "sweep")
	elif _nearest_free_tool(p.global_position) >= 0:
		var i := _nearest_free_tool(p.global_position)
		text = "E: pick up the %s" % tools[i]["kind"]
	if text == "":
		return
	_hint.text = text
	_hint.position = p.global_position + Vector2(-130, -62)
	_hint.visible = true
