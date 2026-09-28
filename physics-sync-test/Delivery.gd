extends Node2D
## WEEK 15 — STORAGE DELIVERIES. Where the store's stock actually comes from.
## Before this, Main.gd's _restock_products() conjured product straight onto
## each section's floor whenever the count dipped — the planned placeholder
## for exactly this system. Now every unit of stock arrives by truck:
##
##   truck backs up to the LOADING DOCK in Storage's east wall
##   -> the delivery forklift (DeliveryForklift.gd) unloads it one pallet box
##      at a time into the RECEIVING row
##   -> a player carries a box to the UNPACK PAD and sets it down
##   -> the box becomes BACKSTOCK for its section (UNITS_PER_BOX units)
##   -> Main.gd's _restock_products() sends backstock out to that section's
##      floor, same spots and same floor cap as before, as sales make room.
##
## So the old floor cap and spawn band are untouched (every clock/grace number
## tuned since Week 6 was tuned against stock appearing in the section); what
## changed is that the floor only refills from backstock, and backstock only
## grows when somebody unpacks a box. No one on the box run = the floor drains.
## The opening floor (Main.gd's _start_shift()) is still stocked on the clock:
## the day starts with one floor's worth already in backstock ("unpacked by
## the night crew"), see OPENING in the header of Main.gd's WEEK 15 note.
##
## Built in code from Main.gd's _ready() like Ambience.gd (nothing new in a
## .tscn — see Main.gd's header note on .tscn comments). Host-authoritative:
## the truck's schedule, what's on it, the pad, and backstock are all decided
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
const TRUCK_FIRST_DELAY := 8.0 # s into the shift before the first truck pulls in
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
const UNITS_PER_BOX := 6 # backstock one box turns into
## The pad: a box SET DOWN on it unpacks at once (_on_box_set_down()). One
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
## Where unpacked stock goes. true (default): backstock, sent out to its own
## section's floor by Main.gd's _restock_products(). false: the box's units
## spawn loose around the pad, inside Storage, for the crew to carry out by
## hand — the more literal version, left one switch away for a playtest
## comparison (see the Week 15 report for the sim numbers on both).
const UNPACK_TO_SECTION := true

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
const PAD_CENTER := Vector2(2090.0, 1330.0) # near Storage's open west side, toward the hub
const PAD_HALF := 56.0
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
var backstock := {} # section name -> units waiting (reassigned on change, never mutated in place)
var unpack_event_id := 0
var unpack_event_text := ""
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
var _pad_label: Label
var _stock_label: Label
var _unpack_label: Label
var _unpack_shown := 0
var _unpack_t := 0.0
var _last_load_key := ""

func _ready() -> void:
	main = get_parent()
	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	for prop in [".:truck_offset", ".:truck_load", ".:backstock", ".:unpack_event_id", ".:unpack_event_text", ".:deliveries_today", ".:boxes_unpacked_today"]:
		var path := NodePath(prop)
		config.add_property(path)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config
	sync.name = "Sync" # explicit, identical name on every peer — see Player.gd's note
	sync.set_multiplayer_authority(1)
	add_child(sync)
	_build_dock()
	_build_receiving()
	_build_pad()
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
## `opening` is section name -> units: the day's opening floor, put in
## backstock so _restock_products() lays it out exactly like before.
func reset_for_new_day(opening: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	backstock = opening.duplicate()
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

## Host: a box was just SET DOWN (not thrown). On the pad -> it unpacks now,
## at its exact drop spot. FOUND BY THE 2-PLAYER NET TEST: two players setting
## boxes down on the pad at the same moment overlapped them, the physics
## engine pushed both apart and off the pad, and neither ever settled on it.
## The settle rule in _tick_pad() still catches a box that slides or gets
## shoved onto the pad and comes to rest there.
func _on_box_set_down(box: RigidBody2D) -> void:
	if multiplayer.is_server() and on_pad(box.global_position):
		unpack.call_deferred(box)

func on_pad(pos: Vector2) -> bool:
	return absf(pos.x - PAD_CENTER.x) <= PAD_HALF and absf(pos.y - PAD_CENTER.y) <= PAD_HALF

func _tick_pad(delta: float) -> void:
	var seen := {}
	for box in get_tree().get_nodes_in_group("delivery_box"):
		if box.is_queued_for_deletion():
			continue
		if box.get_node("Carryable").carrier_id != 0 or not on_pad(box.global_position) or box.linear_velocity.length() > PAD_REST_SPEED:
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
	unpack_event_id += 1
	if UNPACK_TO_SECTION:
		var stock := backstock.duplicate()
		stock[section] = stock.get(section, 0) + UNITS_PER_BOX
		backstock = stock
		unpack_event_text = "+%d %s" % [UNITS_PER_BOX, section]
		# Straight out to the floor if there's room, not on the next 3s tick.
		main._restock_products()
	else:
		for i in UNITS_PER_BOX:
			main.spawn_product_at(section, PAD_CENTER + Vector2(randf_range(-80, 80), randf_range(-110, 110)))
		unpack_event_text = "%d x %s" % [UNITS_PER_BOX, section]
	print("[Delivery] Unpacked a %s box (%d today) — backstock %s" % [section, boxes_unpacked_today, str(backstock)])

## Main.gd's _restock_products() draws from here: one unit of `section`.
func take_backstock(section: String) -> bool:
	if backstock.get(section, 0) <= 0:
		return false
	var stock := backstock.duplicate()
	stock[section] -= 1
	backstock = stock
	return true

func backstock_total() -> int:
	var n := 0
	for s in backstock:
		n += backstock[s]
	return n

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

## The unpack pad: the A2 sheet's hazard-bordered concrete square, a sign, the
## backstock readout, and a floating "+6 Dry Goods" when a box unpacks.
func _build_pad() -> void:
	var pad := Sprite2D.new()
	pad.name = "UnpackPad"
	pad.texture = _a2_block(Vector2i(1, 1))
	pad.position = PAD_CENTER
	pad.scale = Vector2.ONE * (PAD_HALF * 2.0 + 16.0) / 96.0
	add_child(pad)
	_pad_label = _label("UNPACK PAD\ndrop boxes here", PAD_CENTER + Vector2(-130, -PAD_HALF - 60), 16, Color(1, 0.85, 0.3, 0.95))
	_pad_label.size.y = 50
	_stock_label = _label("", PAD_CENTER + Vector2(-130, PAD_HALF + 12), 14)
	_stock_label.size.y = 90
	_unpack_label = _label("", PAD_CENTER + Vector2(-130, -20), 22, Color(0.5, 1, 0.5, 1))
	_unpack_label.visible = false
	_unpack_label.z_index = 20

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
	var lines := []
	for s in main._unlocked_sections():
		lines.append("%s: %d" % [s["name"], backstock.get(s["name"], 0)])
	_stock_label.text = "BACKSTOCK\n" + "\n".join(lines)
	if unpack_event_id != _unpack_shown:
		_unpack_shown = unpack_event_id
		_unpack_t = 1.6
		_unpack_label.text = unpack_event_text
	_unpack_t = maxf(0.0, _unpack_t - delta)
	_unpack_label.visible = _unpack_t > 0.0
	_unpack_label.position.y = PAD_CENTER.y - 20 - (1.6 - _unpack_t) * 25.0
	_unpack_label.modulate.a = minf(1.0, _unpack_t / 0.5)
