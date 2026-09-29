extends Node2D
## WEEK 15 — STORAGE DELIVERIES. Where the store's stock actually comes from.
## Before this, Main.gd's _restock_products() conjured product straight onto
## each section's floor whenever the count dipped — the planned placeholder
## for exactly this system. Now every unit of stock arrives by truck:
##
##   truck backs up to the LOADING DOCK in Storage's east wall
##   -> the delivery forklift (DeliveryForklift.gd) unloads it one pallet box
##      at a time into the RECEIVING row
##   -> a player carries a box to ITS SECTION'S UNPACK PAD and sets it down
##   -> WEEK 16: the box comes apart into UNITS_PER_BOX loose products of its
##      section, spilled around the pad, which the crew carries to that
##      section's shelves by hand like any other carried item.
##
## WEEK 18 — ONE PAD PER SECTION, IN THE SECTION. Week 15-17 had a single pad
## in Storage: every unit that came out of a box then had to be walked from
## Storage, through the Sidewalk and the hub, into its section — a 6-unit box
## was up to six long cross-store trips, and the solo sim's priority-order
## fill rate (~36%) was bottlenecked on that walking, not on the order
## window. Now the box makes the long trip once (Storage -> its section) and
## every unit's trip is pad -> shelf inside the same room. The truck, dock,
## delivery forklift and RECEIVING are untouched: only where a box goes after
## a player picks it up changed. A box only unpacks on ITS OWN section's pad
## (PAD_CENTERS, keyed by section name — the same name the box was tagged
## with on the truck); set down on another section's pad it just sits there
## and the pad flashes "wrong pad", the same spirit as an item only settling
## into a slot of its own color. Boxes (and whoever's carrying them) now
## cross the hub during the selling phase, since trucks keep coming all
## shift — delivery chaos on the sales floor, on purpose.
##
## (Week 15 fed unpacked stock into a per-section backstock that Main.gd laid
## out on the section's floor by itself; Week 16 made it manual, per the final
## design — the backstock, the auto-feed and the UNPACK_TO_SECTION switch are
## gone.) No one on the box run = no stock anywhere. The store also opens with
## no stock of its own (Main.gd's OPENING_STOCK_FRACTION = 0): the first
## trucks arrive during the prep phase, so there's work from the first minute.
##
## Built in code from Main.gd's _ready() like Ambience.gd (nothing new in a
## .tscn — see Main.gd's header note on .tscn comments). Host-authoritative:
## the truck's schedule, what's on it and the pad are all decided
## on the host and replicated through this node's "Sync"; clients only draw.
## RANDOMNESS (host rolls, peers copy — the same rule as the lights' seed and
## the priority orders): the gap between trucks and which section each box is
## for are rolled on the host only; the load goes out as the replicated
## truck_load list, and each box's section rides in its MultiplayerSpawner
## spawn data, so every peer sees the same boxes with the same labels.
##
## WHY STORAGE'S EAST WALL: Storage (grid (2,2)) is the far corner from the
## Break Room (0,0) and off the customers' path (they enter at the Sidewalk
## strip and Customer.gd already keeps them out of Storage), and its east wall
## is the outside edge of the building — a truck can back up to it without
## ever crossing the store. The camera stops at the world edge, so the truck's
## cab is simply never on screen: what you see is the back of a box truck
## sitting in the dock door. The dock bay (where the truck parks) is solid
## (a StaticBody2D, permanent), so nobody can stand where the truck goes.

## --- TUNABLE (every one a FLAGGED placeholder, tuned against the bot sims) ---
const DELIVERY_START_DAY := 1 # Storage is open from Day 1, and so is receiving
## WEEK 16: 3s (was 8) — prep starts the moment the shift does, and the first
## truck is the only work there is until it arrives.
const TRUCK_FIRST_DELAY := 3.0 # s into the shift before the first truck pulls in
## Arrival to next arrival. The timer runs while a truck is parked too, but a
## truck never arrives while the last one is still there — a slow unload
## pushes the next one back rather than stacking them.
const TRUCK_INTERVAL_MIN := 24.0
const TRUCK_INTERVAL_MAX := 32.0
const TRUCK_ARRIVE_TIME := 2.5 # s backing in
const TRUCK_DEPART_TIME := 2.0 # s pulling out
const TRUCK_LINGER := 1.0 # s parked after the last box comes off
## Pallet boxes per truck, tiered like Main.gd's density tables (indexed by
## unlocked sections - 1: Day 1-2, 3-4, 5-6, 7), + more with a bigger crew
## (who also get a bigger floor cap and more customers).
const BOXES_PER_TRUCK_BY_TIER := [2, 3, 4, 5]
const BOXES_PER_EXTRA_PLAYER := 1
const UNITS_PER_BOX := 6 # loose products one box comes apart into
## A pad: a box SET DOWN on its own section's pad unpacks at once (_on_box_set_down()). One
## that ends up there any other way (slid, shoved, thrown short) — a free box
## with its center on the pad, moving slower than
## PAD_REST_SPEED, for PAD_SETTLE_TIME unpacks — the same "settle, then count"
## shape as a shelf slot (Shelf.gd's SETTLE_TIME), so a box thrown or shoved
## hard across it doesn't. FOUND BY THE SOLO SIM: the first version wanted a
## box fully at rest (30px/s) for 0.5s and most drops silently didn't unpack
## (walking back over it nudged it off; the rest was the carry-offset fling
## Carryable.gd's carry_distance fixes). A walking nudge is well under
## 150px/s; a throw starts at 620.
const PAD_SETTLE_TIME := 0.3
const PAD_REST_SPEED := 150.0
## Unpacked stock spills in a ring around the pad (clear of the pad itself, so
## a product never sits where the next box has to go), this far from center.
const SPILL_RING_MIN := 80.0
const SPILL_RING_MAX := 150.0
const SPILL_ATTEMPTS := 12

## --- LAYOUT (world px; Storage is x 1920-2880, y 1080-1620) ---
const LANE_Y := 1250.0 # the forklift's east-west lane, dock door centered on it
const DOCK_X := 2740.0 # the dock edge: the truck's back doors, and the bay's west face
const DOCK_HALF_WIDTH := 75.0 # the bay (and the truck) span LANE_Y +- this
const TRUCK_LENGTH := 330.0
const TRUCK_AWAY_OFFSET := 420.0 # fully past the world's east edge
const FORKLIFT_HOME := Vector2(2270.0, LANE_Y)
## The receiving row: where the forklift sets boxes down, south of its lane.
## 75px apart: the forklift (44 wide) drives down between two parked boxes
## (44 wide) with ~15px to spare on each side. FOUND BY THE 4-PLAYER NET TEST:
## the first row had 5 spots and a 4-crew truck carries 6-8 boxes, so the
## forklift sat at the row holding the 6th. 7 spots now; if nobody hauls and
## the row does fill, the forklift waits with the next box on its forks and
## the truck waits for it — the backlog shows instead of piling up.
## Filled from the dock end first (free_receiving_spot() takes the first free
## one): the forklift's shortest trip, and its trips are the delivery chain's
## bottleneck — the crew walks the rest.
const RECEIVING_SPOTS := [Vector2(2680, 1450), Vector2(2605, 1450), Vector2(2530, 1450), Vector2(2455, 1450), Vector2(2380, 1450), Vector2(2305, 1450), Vector2(2230, 1450)]
const SPOT_CLEAR_RADIUS := 36.0 # a spot with a box (or anything) within this is taken
## WEEK 18: one pad per section, keyed by the section's name (Main.gd's
## SECTIONS). Each sits in open floor that no customer has to cross to reach a
## shelf, clear of every shelf slot (two-deep rows included) by 40px+:
## - Produce, Dairy/Frozen, Bakery (same room layout, shelves on the top and
##   bottom walls): the alcove between the two top-wall shelves, below the
##   section sign (low enough not to cover it) — a dead end nobody walks
##   through, central to all five shelves. Produce's sale bin sat in that
##   alcove (Main.tscn 2400,690); it moved to the alcove's east side
##   (2520,700), off the way in from the hub and clear of the forklift's lane.
## - Dry Goods (shelves on the side walls and the top wall, entered from the
##   south): the middle of the room, in the open floor between the side
##   shelves' slot columns and below the top shelves' — the only floor that
##   size in there. Shoppers heading for the top shelves walk round it.
const PAD_CENTERS := {
	"Dry Goods": Vector2(1440.0, 300.0),
	"Produce": Vector2(2400.0, 665.0),
	"Dairy/Frozen": Vector2(480.0, 665.0),
	"Bakery": Vector2(2400.0, 125.0),
}
const PAD_HALF := 56.0
## Spilled stock stays this far inside its section's room edges.
const SPILL_ROOM_MARGIN := 40.0
## ...and this far from every shelf slot. FOUND BY THE BOX-CYCLE BENCHMARK:
## Dry Goods' spill ring reaches the top-wall shelves' slot rows, and with
## Main.gd's 40px spawn clearance a unit could land (or get nudged) in front
## of an already-stocked slot — clutter right where the crew and the
## shoppers reach the shelf.
const SPILL_SLOT_CLEARANCE := 70.0
const BOX_SIZE := 44.0
const BOX_COLOR := Color(0.72, 0.56, 0.36, 1) # matches no section: a box never shelves

const A2_PATH := "res://assets/supermarket/Tile_A2-2.png"
const PALLET_SHEET := "res://assets/warehouse/tile-B-05.png"
## Pallet-with-boxes sprites (warehouse pack, tile-B-05): the delivery box, on
## the truck, on the forks and on the floor. One per box, picked from its name.
const BOX_ART := [Rect2i(295, 7, 83, 83), Rect2i(582, 6, 83, 84), Rect2i(679, 5, 82, 86), Rect2i(679, 106, 82, 77)]
const Z_TRUCK := 3 # over the east wall strip (StoreArt), under nothing that matters

var active := false
var finale := false

## Host-written, replicated (see _ready()).
var truck_offset := TRUCK_AWAY_OFFSET # 0 = parked at the dock, TRUCK_AWAY_OFFSET = gone
var truck_load: Array = [] # section names still on the truck, first one comes off first
var unpack_event_id := 0
var unpack_event_text := ""
var unpack_event_pad := "" # WEEK 18: which section's pad the last event was at
var unpack_event_ok := true # false: a box set down on the wrong pad
var deliveries_today := 0
var boxes_unpacked_today := 0

## Host-only.
enum { TRUCK_AWAY, TRUCK_ARRIVING, TRUCK_PARKED, TRUCK_LEAVING }
var _truck_state := TRUCK_AWAY
var _truck_timer := 0.0 # to the next arrival
var _linger := 0.0
var _pad_settle := {} # box -> s resting on the pad
var _next_box_index := 0
var boxes_delivered_today := 0

## Every peer: visuals.
var main: Node
var _truck: Node2D
var _truck_cargo: Node2D
var _pad_nodes := {} # section -> [sprite, sign, section name label] (lock dimming)
var _unpack_labels := {} # section -> its pad's floating event label
var _unpack_shown := 0 # the last unpack_event_id this peer showed
var _unpack_t := 0.0
var _last_load_key := ""

func _ready() -> void:
	main = get_parent()
	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	for prop in [".:truck_offset", ".:truck_load", ".:unpack_event_id", ".:unpack_event_text", ".:unpack_event_pad", ".:unpack_event_ok", ".:deliveries_today", ".:boxes_unpacked_today"]:
		var path := NodePath(prop)
		config.add_property(path)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config
	sync.name = "Sync" # explicit, identical name on every peer — see Player.gd's note
	sync.set_multiplayer_authority(1)
	add_child(sync)
	_build_dock()
	_build_receiving()
	for section in PAD_CENTERS:
		_build_pad(section)
	_build_truck()

func configure(day: int, is_finale := false) -> void:
	finale = is_finale
	active = day >= DELIVERY_START_DAY

## Tier index, the same (unlocked sections - 1) Main.gd's density tables use.
func _tier() -> int:
	return clampi(main._unlocked_sections().size() - 1, 0, BOXES_PER_TRUCK_BY_TIER.size() - 1)

func boxes_per_truck() -> int:
	return BOXES_PER_TRUCK_BY_TIER[_tier()] + BOXES_PER_EXTRA_PLAYER * maxi(0, main.players.size() - 1)

func truck_interval() -> float:
	return randf_range(TRUCK_INTERVAL_MIN, TRUCK_INTERVAL_MAX)

## Host-only, from Main.gd's _start_shift(), after the floor was cleared.
func reset_for_new_day() -> void:
	if not multiplayer.is_server():
		return
	truck_load = []
	truck_offset = TRUCK_AWAY_OFFSET
	_truck_state = TRUCK_AWAY
	_truck_timer = TRUCK_FIRST_DELAY
	_pad_settle = {}
	deliveries_today = 0
	boxes_unpacked_today = 0
	boxes_delivered_today = 0

## Host-only, every frame of a running shift (Main.gd's _process()).
func tick_host(delta: float) -> void:
	if not multiplayer.is_server() or not active:
		return
	_tick_truck(delta)
	_tick_pad(delta)

## --- Truck ------------------------------------------------------------------

func _tick_truck(delta: float) -> void:
	_truck_timer -= delta
	match _truck_state:
		TRUCK_AWAY:
			if _truck_timer <= 0.0:
				start_delivery()
		TRUCK_ARRIVING:
			truck_offset = maxf(0.0, truck_offset - TRUCK_AWAY_OFFSET / TRUCK_ARRIVE_TIME * delta)
			if truck_offset <= 0.0:
				_truck_state = TRUCK_PARKED
				_linger = TRUCK_LINGER
		TRUCK_PARKED:
			if truck_load.is_empty():
				_linger -= delta
				if _linger <= 0.0:
					_truck_state = TRUCK_LEAVING
		TRUCK_LEAVING:
			truck_offset = minf(TRUCK_AWAY_OFFSET, truck_offset + TRUCK_AWAY_OFFSET / TRUCK_DEPART_TIME * delta)
			if truck_offset >= TRUCK_AWAY_OFFSET:
				_truck_state = TRUCK_AWAY
				# Overdue while it was here: give the dock a beat before the next.
				_truck_timer = maxf(_truck_timer, 2.0)

## Host-only. Rolls the load and sends the truck in. Public so tests can call
## a delivery on demand. Every unlocked section gets a box before any section
## gets a second (shuffled, so which comes off first varies); extra boxes past
## one each go to random sections.
func start_delivery() -> void:
	if not multiplayer.is_server() or _truck_state != TRUCK_AWAY:
		return
	var names: Array = main._unlocked_sections().map(func(s): return s["name"])
	names.shuffle()
	var cargo := []
	for i in boxes_per_truck():
		cargo.append(names[i] if i < names.size() else names[randi() % names.size()])
	truck_load = cargo
	_truck_state = TRUCK_ARRIVING
	_truck_timer = truck_interval()
	deliveries_today += 1
	print("[Delivery] Truck #%d arriving with %d box(es): %s" % [deliveries_today, cargo.size(), str(cargo)])

func truck_parked() -> bool:
	return truck_offset <= 0.0

## Host-only, from the delivery forklift: the next box off the truck.
func take_box_from_truck() -> String:
	if not multiplayer.is_server() or not truck_parked() or truck_load.is_empty():
		return ""
	var rest := truck_load.duplicate()
	var section: String = rest.pop_front()
	truck_load = rest
	return section

## --- Receiving --------------------------------------------------------------

## The first receiving spot nothing is sitting on, or null if the row is full.
func free_receiving_spot() -> Variant:
	for spot in RECEIVING_SPOTS:
		var taken := false
		for obj in get_tree().get_nodes_in_group("carryable"):
			if obj.global_position.distance_to(spot) < SPOT_CLEAR_RADIUS:
				taken = true
				break
		if not taken:
			for p in main.players.values():
				if p.global_position.distance_to(spot) < SPOT_CLEAR_RADIUS:
					taken = true
					break
		if not taken:
			return spot
	return null

## Host-only, from the delivery forklift setting a box down.
func drop_box(pos: Vector2, section: String) -> void:
	if not multiplayer.is_server() or section == "":
		return
	main.product_spawner.spawn({"kind": "box", "index": _next_box_index, "pos": pos, "section": section})
	_next_box_index += 1
	boxes_delivered_today += 1

## Every peer (the spawner's spawn_function): builds a box from its spawn data.
## A RigidBody2D with the same Carryable component every product uses — so
## pickup, carry, throw, pushes and sync all just work — plus a pallet sprite
## and a stripe in its section's color, so you can read what's in it.
func build_box(data: Dictionary) -> RigidBody2D:
	var box := RigidBody2D.new()
	box.name = "Box%d" % data["index"]
	box.position = data["pos"]
	box.mass = 1.5
	box.gravity_scale = 0.0
	box.linear_damp = 4.0
	box.angular_damp = 4.0
	box.set_meta("section", data["section"])
	box.add_to_group("delivery_box")
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(BOX_SIZE, BOX_SIZE)
	shape.shape = rect
	box.add_child(shape)
	# Shelf.gd reads an item's color off "Polygon2D": this one matches no
	# section, so a box can never settle into a shelf slot. Hidden under the art.
	var poly := Polygon2D.new()
	poly.name = "Polygon2D"
	var h := BOX_SIZE * 0.5
	poly.polygon = PackedVector2Array([Vector2(-h, -h), Vector2(h, -h), Vector2(h, h), Vector2(-h, h)])
	poly.color = BOX_COLOR
	poly.self_modulate.a = 0.0
	box.add_child(poly)
	var art := box_sprite(String(box.name), BOX_SIZE + 8.0)
	art.name = "BoxArt"
	box.add_child(art)
	box.add_child(_section_tag(data["section"]))
	var comp := Node.new()
	comp.name = "Carryable"
	comp.set_script(preload("res://Carryable.gd"))
	# Clear of the carrier's 28px body with room to spare (see Carryable.gd).
	comp.carry_distance = BOX_SIZE * 0.5 + 14.0 + 4.0
	comp.dropped.connect(_on_box_set_down.bind(box))
	box.add_child(comp)
	return box

func box_sprite(key: String, size: float) -> Sprite2D:
	var spr := Sprite2D.new()
	spr.texture = load(PALLET_SHEET)
	spr.region_enabled = true
	var r: Rect2i = BOX_ART[absi(key.hash()) % BOX_ART.size()]
	spr.region_rect = Rect2(r)
	spr.scale = Vector2.ONE * (size / float(maxi(r.size.x, r.size.y)))
	return spr

## A colored band across the box: which section it's for (same accent colors
## as that section's shelf slots and products).
func _section_tag(section: String) -> Polygon2D:
	var tag := Polygon2D.new()
	tag.name = "SectionTag"
	tag.polygon = PackedVector2Array([Vector2(-18, -4), Vector2(18, -4), Vector2(18, 5), Vector2(-18, 5)])
	tag.color = main.SECTION_COLORS.get(section, Color.WHITE)
	return tag

## --- Pad --------------------------------------------------------------------

## Host: a box was just SET DOWN (not thrown). On its own section's pad -> it
## unpacks now,
## at its exact drop spot. FOUND BY THE 2-PLAYER NET TEST: two players setting
## boxes down on the pad at the same moment overlapped them, the physics
## engine pushed both apart and off the pad, and neither ever settled on it.
## The settle rule in _tick_pad() still catches a box that slides or gets
## shoved onto the pad and comes to rest there.
## WEEK 18: on another section's pad it stays a box, and that pad says so.
func _on_box_set_down(box: RigidBody2D) -> void:
	if not multiplayer.is_server():
		return
	var section: String = box.get_meta("section")
	if on_pad(box.global_position, section):
		unpack.call_deferred(box)
	else:
		var at := pad_at(box.global_position)
		if at != "":
			_pad_event(at, "%s box —\nwrong pad" % section, false)

func pad_center(section: String) -> Vector2:
	return PAD_CENTERS[section]

## The section whose pad `pos` is on, or "" if it's on none.
func pad_at(pos: Vector2) -> String:
	for section in PAD_CENTERS:
		var c: Vector2 = PAD_CENTERS[section]
		if absf(pos.x - c.x) <= PAD_HALF and absf(pos.y - c.y) <= PAD_HALF:
			return section
	return ""

## On `section`'s pad — or, with no section, on any pad.
func on_pad(pos: Vector2, section := "") -> bool:
	var at := pad_at(pos)
	return at != "" if section == "" else at == section

## Host-only: the floating line over a pad, on every peer (replicated).
func _pad_event(section: String, text: String, ok: bool) -> void:
	unpack_event_pad = section
	unpack_event_text = text
	unpack_event_ok = ok
	unpack_event_id += 1

func _tick_pad(delta: float) -> void:
	var seen := {}
	for box in get_tree().get_nodes_in_group("delivery_box"):
		if box.is_queued_for_deletion():
			continue
		if box.get_node("Carryable").carrier_id != 0 or not on_pad(box.global_position, box.get_meta("section")) or box.linear_velocity.length() > PAD_REST_SPEED:
			continue
		seen[box] = true
		_pad_settle[box] = _pad_settle.get(box, 0.0) + delta
		if _pad_settle[box] >= PAD_SETTLE_TIME:
			unpack(box)
	for box in _pad_settle.keys():
		if not seen.has(box):
			_pad_settle.erase(box)

## Host-only. Public so tests can unpack a box directly.
func unpack(box) -> void: # untyped: may arrive (deferred) already freed
	if not multiplayer.is_server() or not is_instance_valid(box) or box.is_queued_for_deletion():
		return
	var section: String = box.get_meta("section")
	_pad_settle.erase(box)
	box.queue_free()
	boxes_unpacked_today += 1
	var spots := []
	for i in UNITS_PER_BOX:
		var pos := _spill_spot(section, spots)
		spots.append(pos)
		main.spawn_product_at(section, pos)
	_pad_event(section, "%d x %s" % [UNITS_PER_BOX, section], true)
	print("[Delivery] Unpacked a %s box (%d today) -> %d loose on the floor by its pad" % [section, boxes_unpacked_today, UNITS_PER_BOX])

## Host-only: somewhere in the ring round the section's pad that isn't on top
## of other stock, a box, a player, a forklift, a display or a shelf slot (a
## RigidBody spawned overlapping one gets flung, and one on a slot would stock
## itself — Main.gd's _spawn_pos_is_clear() covers all of those), nor inside a
## shelf or a wall. WEEK 18: the pads sit among shelves now, not in an empty
## room, so a spot is also kept inside the section's room and tested against
## every static collider. Takes the last clear-of-walls roll if the ring is
## crowded, like Main.gd does.
func _spill_spot(section: String, taken: Array) -> Vector2:
	var c: Vector2 = PAD_CENTERS[section]
	var cell: Vector2i = main._grid_cell_of(c)
	var room := Rect2(Vector2(cell.x * main.ROOM_WIDTH, cell.y * main.ROOM_HEIGHT), Vector2(main.ROOM_WIDTH, main.ROOM_HEIGHT)).grow(-SPILL_ROOM_MARGIN)
	var fallback := c + Vector2(0, SPILL_RING_MIN) # the pad's open (aisle) side
	for attempt in SPILL_ATTEMPTS * 2:
		var pos := c + Vector2.RIGHT.rotated(randf() * TAU) * randf_range(SPILL_RING_MIN, SPILL_RING_MAX)
		if not room.has_point(pos) or _hits_static(pos):
			continue
		fallback = pos
		var clear: bool = main._spawn_pos_is_clear(pos) and not _near_a_slot(pos)
		for q in taken:
			if pos.distance_to(q) < main.SPAWN_CLEARANCE_PRODUCT:
				clear = false
		for p in main.players.values():
			if pos.distance_to(p.global_position) < 36.0:
				clear = false
		if clear:
			return pos
	return fallback

func _near_a_slot(pos: Vector2) -> bool:
	for shelf_body in main.shelves:
		for slot in shelf_body.get_node("Shelf").slots:
			if pos.distance_to(slot.global_position) < SPILL_SLOT_CLEARANCE:
				return true
	return false

## True if a product-sized square at `pos` would overlap a wall, a shelf, a
## gate or anything else static.
func _hits_static(pos: Vector2) -> bool:
	var q := PhysicsShapeQueryParameters2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(36, 36) # a 28px product plus margin
	q.shape = rect
	q.transform = Transform2D(0.0, pos)
	q.collide_with_areas = false
	for hit in get_world_2d().direct_space_state.intersect_shape(q, 8):
		if hit["collider"] is StaticBody2D:
			return true
	return false

## Boxes that exist right now: on the truck, on the forks, on the floor.
func boxes_waiting() -> int:
	return get_tree().get_nodes_in_group("delivery_box").filter(func(b): return not b.is_queued_for_deletion()).size()

## --- Visuals (every peer) ---------------------------------------------------

func _label(text: String, pos: Vector2, size: int, color := Color(1, 1, 1, 0.9)) -> Label:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.size = Vector2(260, 30)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	add_child(l)
	return l

func _a2_block(block: Vector2i) -> Texture2D:
	var img: Image = load(A2_PATH).get_image()
	return ImageTexture.create_from_image(img.get_region(Rect2i(block.x * 96, block.y * 144 + 48, 96, 96)))

## The dock bay behind the dock edge (solid, the truck's space), the open door
## in the east wall, and a hazard-striped bumper along the dock edge.
func _build_dock() -> void:
	var y0 := LANE_Y - DOCK_HALF_WIDTH
	var y1 := LANE_Y + DOCK_HALF_WIDTH
	var bay := Polygon2D.new()
	bay.name = "DockBay"
	bay.polygon = PackedVector2Array([Vector2(DOCK_X, y0), Vector2(main.WORLD_WIDTH, y0), Vector2(main.WORLD_WIDTH, y1), Vector2(DOCK_X, y1)])
	bay.color = Color(0.2, 0.2, 0.22, 1) # outside: the asphalt gap the truck backs into
	bay.z_index = Z_TRUCK - 1
	add_child(bay)
	var body := StaticBody2D.new()
	body.name = "DockBayBody"
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(main.WORLD_WIDTH - DOCK_X, y1 - y0)
	shape.shape = rect
	body.position = Vector2((DOCK_X + main.WORLD_WIDTH) * 0.5, LANE_Y)
	body.add_child(shape)
	add_child(body)
	# Hazard-striped bumper: the A2 sheet's striped industrial tile.
	var bumper := Polygon2D.new()
	bumper.name = "DockBumper"
	bumper.polygon = PackedVector2Array([Vector2(DOCK_X - 10, y0 - 6), Vector2(DOCK_X, y0 - 6), Vector2(DOCK_X, y1 + 6), Vector2(DOCK_X - 10, y1 + 6)])
	bumper.texture = _a2_block(Vector2i(1, 1))
	bumper.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	bumper.texture_scale = Vector2(9.6, 1.6)
	bumper.z_index = Z_TRUCK + 1
	add_child(bumper)
	_label("LOADING DOCK", Vector2(DOCK_X - 230, y0 - 40), 18, Color(1, 0.85, 0.3, 0.95))

## Painted spots where the forklift sets boxes down, and a RECEIVING sign.
func _build_receiving() -> void:
	for spot in RECEIVING_SPOTS:
		var mark := Line2D.new()
		var h := BOX_SIZE * 0.5 + 8.0
		mark.points = PackedVector2Array([spot + Vector2(-h, -h), spot + Vector2(h, -h), spot + Vector2(h, h), spot + Vector2(-h, h), spot + Vector2(-h, -h)])
		mark.width = 2.0
		mark.default_color = Color(1, 0.85, 0.2, 0.55)
		add_child(mark)
	_label("RECEIVING", Vector2(RECEIVING_SPOTS[3].x - 130, RECEIVING_SPOTS[0].y + 42), 18, Color(1, 0.85, 0.3, 0.95))

## An unpack pad: the A2 sheet's hazard-bordered concrete square (the same
## pack tile as Week 15's Storage pad), "UNPACK PAD" and the section's name in
## its accent color (the same color as the stripe on its boxes) printed on
## the pad itself (WEEK 18: one per section, among shelves and stock — a sign
## off the pad landed on a slot row or under loose stock), and a floating
## "6 x Dry Goods" (or "wrong pad") when a box is set down on it.
func _build_pad(section: String) -> void:
	var c: Vector2 = PAD_CENTERS[section]
	var pad := Sprite2D.new()
	pad.name = "UnpackPad" + String(section).replace("/", "")
	pad.texture = _a2_block(Vector2i(1, 1))
	pad.position = c
	pad.scale = Vector2.ONE * (PAD_HALF * 2.0 + 16.0) / 96.0
	add_child(pad)
	var sign_label := _label("UNPACK\nPAD", c + Vector2(-130, -40), 15, Color(1, 0.85, 0.3, 0.95))
	sign_label.size.y = 44
	var name_label := _label(section.to_upper(), c + Vector2(-130, 10), 13, main.SECTION_COLORS[section].lightened(0.25))
	_pad_nodes[section] = [pad, sign_label, name_label]
	var ev := _label("", c + Vector2(-130, -20), 22, Color(0.5, 1, 0.5, 1))
	ev.size.y = 60
	ev.visible = false
	ev.z_index = 20
	_unpack_labels[section] = ev

## Placeholder box truck (neither pack has a vehicle): a white cargo box with
## its back doors open at the dock, the load visible inside as the pack's
## pallet art, and a cab past the world edge that you never actually see.
func _build_truck() -> void:
	_truck = Node2D.new()
	_truck.name = "Truck"
	_truck.z_index = Z_TRUCK
	add_child(_truck)
	var hw := DOCK_HALF_WIDTH - 6.0
	var cargo := Polygon2D.new()
	cargo.polygon = PackedVector2Array([Vector2(0, -hw), Vector2(TRUCK_LENGTH, -hw), Vector2(TRUCK_LENGTH, hw), Vector2(0, hw)])
	cargo.color = Color(0.9, 0.91, 0.93, 1)
	_truck.add_child(cargo)
	var floor_ := Polygon2D.new()
	floor_.polygon = PackedVector2Array([Vector2(8, -hw + 8), Vector2(TRUCK_LENGTH - 10, -hw + 8), Vector2(TRUCK_LENGTH - 10, hw - 8), Vector2(8, hw - 8)])
	floor_.color = Color(0.35, 0.33, 0.3, 1)
	_truck.add_child(floor_)
	for side in [-1.0, 1.0]:
		var door := Polygon2D.new() # back doors swung open against the dock
		door.polygon = PackedVector2Array([Vector2(-4, side * hw), Vector2(4, side * hw), Vector2(4, side * (hw + 16)), Vector2(-4, side * (hw + 16))])
		door.color = Color(0.75, 0.76, 0.8, 1)
		_truck.add_child(door)
	var cab := Polygon2D.new()
	cab.polygon = PackedVector2Array([Vector2(TRUCK_LENGTH + 6, -hw + 6), Vector2(TRUCK_LENGTH + 90, -hw + 14), Vector2(TRUCK_LENGTH + 90, hw - 14), Vector2(TRUCK_LENGTH + 6, hw - 6)])
	cab.color = Color(0.2, 0.45, 0.8, 1)
	_truck.add_child(cab)
	_truck_cargo = Node2D.new()
	_truck.add_child(_truck_cargo)
	_update_truck_visual()

func _update_truck_visual() -> void:
	_truck.position = Vector2(DOCK_X + truck_offset, LANE_Y)
	_truck.visible = truck_offset < TRUCK_AWAY_OFFSET - 0.5
	var key := str(truck_load)
	if key == _last_load_key:
		return
	_last_load_key = key
	for c in _truck_cargo.get_children():
		c.queue_free()
	# Two rows of pallets from the doors inward, next one off at the doors.
	for i in truck_load.size():
		var spr := box_sprite("truck%d" % i, 50.0)
		spr.position = Vector2(34 + (i / 2) * 58, -30 + (i % 2) * 60)
		_truck_cargo.add_child(spr)
		var tag := _section_tag(truck_load[i])
		tag.position = spr.position
		_truck_cargo.add_child(tag)

func _process(delta: float) -> void:
	_update_truck_visual()
	# A locked section's pad dims with the rest of the room (Main.gd's LOCKED_DIM).
	for section in _pad_nodes:
		var tint: Color = Color.WHITE if main.is_unlocked_at_pos(PAD_CENTERS[section]) else main.LOCKED_DIM
		for n in _pad_nodes[section]:
			n.modulate = tint
	if unpack_event_id != _unpack_shown:
		_unpack_shown = unpack_event_id
		_unpack_t = 1.6
		for section in _unpack_labels:
			_unpack_labels[section].visible = false
	var ev: Label = _unpack_labels.get(unpack_event_pad)
	_unpack_t = maxf(0.0, _unpack_t - delta)
	if ev == null:
		return
	ev.text = unpack_event_text
	ev.add_theme_color_override("font_color", Color(0.5, 1, 0.5, 1) if unpack_event_ok else Color(1, 0.4, 0.35, 1))
	ev.visible = _unpack_t > 0.0
	ev.position.y = PAD_CENTERS[unpack_event_pad].y - 20 - (1.6 - _unpack_t) * 25.0
	ev.modulate.a = minf(1.0, _unpack_t / 0.5)
