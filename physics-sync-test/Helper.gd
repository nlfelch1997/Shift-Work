extends Node2D
## OCT 2026 PIVOT, PHASE 3 — A HIRED HELPER: one staff NPC working ONE
## section (Staff.gd owns the hiring, the wages and the board; this is the
## person on the floor). Built in code by Staff.gd, one per hireable section,
## on every peer, with an explicit name (HelperProduce...) so its "Sync"
## matches across peers; hidden until that section has someone on the books.
##
## WHAT A HELPER DOES — the in-section half of the stocking chain, start to
## finish, so a section keeps selling while nobody from the crew is in it:
##   1. its section's truck boxes don't go to Storage's RECEIVING row any more
##      — Delivery.gd hands them to the section's BACK STOCK (Staff.gd);
##   2. when its floor is out of loose stock and a shelf has room, the helper
##      walks to the section's unpack pad and opens a back-stock box there
##      (Delivery.gd's ordinary unpack spill, six units round the pad);
##   3. it picks loose stock of ITS section's color up off ITS room's floor
##      (unpacked units, anything the crew dropped there, stock a forklift
##      ram or a shove knocked off a shelf), up to its carry capacity, and
##      shelves it, one slot at a time.
## It never leaves its room: no hub crowds, no Storage, no forklift lane in
## Storage, no gate traffic to path through. SPEED (walking px/s) and CARRY
## (items per trip) are the two upgrade knobs (Staff.gd's tables).
##
## WHY THIS SHAPE (and not a passive multiplier or a store-roaming hauler):
## every unit it sells is a real unit that came off a real truck and went onto
## a real shelf through the same Carryable/Shelf code the crew's stock goes
## through — a clip of a staffed aisle shows a person in a green polo
## carrying product from the pad to the shelves, which is exactly the claim.
## Confining it to one room is what keeps it simple: the room is open floor
## with shelves on two walls, so a small grid path (Godot's AStarGrid2D, with
## the room's shelves and floor displays marked solid) is always enough.
##
## WHY A PLAIN Node2D (NO COLLISION) — the same call as Manager.gd: a body
## could only add ways to get stuck (wedged on a customer, pinned by the
## Produce forklift) or to cause chaos (shoving loose stock and displays it
## walks past). It walks AROUND shelves and displays by its path, and THROUGH
## people, like the manager. Customers never target it (it isn't in the
## "player" group, nor "customer"), the manager never watches it (his
## detection only reads players), and a player's shove (customers only)
## can't touch it. The one moving hazard in a hireable room — the Produce
## forklift — it simply gives way to (see _forklift_step()).
##
## CARRYING reuses Carryable.gd as-is, the way customers do: a unique,
## negative carry_id (well clear of the customers' -1, -2, ... range), found
## by Carryable._find_carrier() through the "helper" group. Pickup, the
## stacked armful (Week 21's carry_seq order), drop position, network sync
## and the manager/sound hooks all come for free; the manager ignores
## negative ids like it does a customer's. A drop from the stand point (the
## slot + SLOT_STAND along the shelf's facing, the same stand-off the solo
## bot uses) lands the item on the slot, and Shelf.gd settles it as it would
## a player's — priority orders, the knocked-stock tag, all unchanged.
##
## AUTHORITY: the host thinks and moves it; every peer smooths toward the
## replicated target_position (Manager.gd's split, same numbers).

const CharacterSpriteScript := preload("res://CharacterSprite.gd")

## Path grid over the room (px per cell) and the clearance kept from shelves
## and floor displays — a person is ~28px wide (Player/Customer collision).
const GRID := 20.0
const CLEARANCE := 18.0
const DISPLAY_RADIUS := 32.0 # a 44px display, any rotation
## Close enough to an item to take it (Carryable's own reach is 70 + slack).
const PICK_REACH := 24.0
## Short beats so each action reads on screen (and costs a little time).
const PICK_TIME := 0.3
const PLACE_TIME := 0.4
const UNPACK_TIME := 1.2
## Stand-off from a slot: the drop lands CARRY_OFFSET (30px) ahead, so 29
## puts the item on the slot's marker (well inside Shelf.CAPTURE_RADIUS).
const SLOT_STAND := 29.0
## The pad is opened from the aisle side (south: every pad has open floor
## below it — Delivery.gd), and that spot is also where the helper waits.
const PAD_STAND := Vector2(0.0, 78.0)
## Stock moving faster than this is still flying (a ram, a throw) — wait.
const ITEM_REST_SPEED := 30.0
## An item lying on an EMPTY slot is about to settle by itself (Shelf.gd's
## SETTLE_TIME is a fraction of a second); left alone this long, it isn't
## going to, so it's fair game.
const SETTLING_GRACE := 2.0
## THE PRODUCE FORKLIFT. Wherever it is, its body (plus FORKLIFT_PAD) is
## solid in the helper's path grid — a parked forklift is just furniture to
## walk round, and a slot behind it waits. While it's MOVING (or flashing
## before a ram): inside YIELD the helper takes no step closer to it; inside
## FLEE it steps away, along the open aisle band of the room.
## FOUND BY THE FIRST SMOKE RUN: yielding to it parked (prep: it sits at
## home until the store opens) froze a helper beside it for good.
const FORKLIFT_YIELD := 130.0
const FORKLIFT_FLEE := 95.0
const FORKLIFT_PAD := 22.0
const FORKLIFT_HALF := Vector2(46.0, 22.0) # Forklift.tscn's 92x44 box...
const FORKLIFT_BOX_OFFSET := 6.0 # ...centred 6px ahead of its origin
## A slot whose job timed out is passed over for this long (something keeps
## it out of reach — the forklift parked in front of it, a crowd).
const SLOT_COOLDOWN := 10.0
const REPLAN_EVERY := 1.0
## A job that hasn't finished in this long is dropped and re-chosen (a slot
## that keeps getting taken from under it, an item a customer keeps nudging).
const JOB_TIMEOUT := 12.0
## The open band of a hireable room (room-local y) — between the two shelf
## walls' slot rows, where fleeing the forklift keeps to.
const BAND_Y := Vector2(150.0, 395.0)

var section := ""
var helper_name := ""
var carry_id := 0
var cell := Vector2i.ZERO
var color := Color.WHITE

## --- Replicated (Sync, host authority) ---
var target_position := Vector2.ZERO
var facing_angle := PI * 0.5
var active := false
var status := "" # a word over the head while busy at the pad ("unpacking")

## --- Host-only ---
var speed := 80.0
var capacity := 1
var _job := {}
var _job_t := 0.0
var _path := PackedVector2Array()
var _path_goal := Vector2.INF
var _pause := 0.0
var _pause_action := ""
var _settling_seen := {} # instance id -> first time (_clock) seen lying on an empty slot
var _clock := 0.0 # this helper's own game-time clock (deltas, so --fixed-fps runs agree)
var _slot_skip := {} # "shelf id:slot" -> _clock until which it's passed over
var _replan_t := 0.0
var _delivering := false
var _astar := AStarGrid2D.new()
var _room := Rect2()
## Diagnostics read by the tests.
var placed_today := 0
var picked_today := 0
var unpacked_today := 0
var knocked_reshelved_today := 0 # stock a ram/shove knocked down, picked back up
var forklift_yield_s := 0.0
var walked_px := 0.0

var main: Node
var _sprite: Sprite2D
var _tag: Label

func setup(sec_name: String, index: int, name_text: String, look: String, accent: Color) -> void:
	section = sec_name
	helper_name = name_text
	carry_id = -1000000 - index
	color = accent
	name = "Helper" + sec_name.replace("/", "")
	_sprite = CharacterSpriteScript.attach(self, look, "facing_angle", accent)
	# One line over the head (FOUND BY THE SCREENSHOTS: a second status line
	# stacked onto the pad's own sign): "Sam · staff", or what they're busy at.
	_tag = _label("", 11, accent.lerp(Color.WHITE, 0.55))
	_tag.position = Vector2(-70, -46)

func _label(text: String, size: int, c: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.size = Vector2(140, 14)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", c)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	add_child(l)
	return l

func _ready() -> void:
	main = get_parent().main # Staff.gd's (current_scene isn't set yet while Main is still in _ready())
	add_to_group("helper")
	var s: Dictionary = main.SECTIONS[main.section_index(section)]
	cell = s["grid_pos"]
	_room = Rect2(Vector2(cell.x * main.ROOM_WIDTH, cell.y * main.ROOM_HEIGHT), Vector2(main.ROOM_WIDTH, main.ROOM_HEIGHT))
	_astar.region = Rect2i(0, 0, int(main.ROOM_WIDTH / GRID), int(main.ROOM_HEIGHT / GRID))
	_astar.cell_size = Vector2(GRID, GRID)
	_astar.offset = _room.position + Vector2(GRID, GRID) * 0.5
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_astar.update()
	position = home()
	target_position = position
	visible = false
	set_multiplayer_authority(1)
	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	for prop in [".:target_position", ".:facing_angle", ".:active", ".:status"]:
		var path := NodePath(prop)
		config.add_property(path)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config
	sync.name = "Sync" # explicit, identical name on every peer — see Player.gd's note
	sync.set_multiplayer_authority(1)
	add_child(sync)

## Where the helper stands when there's nothing to do: by the pad, aisle side.
func home() -> Vector2:
	return main.delivery.pad_center(section) + PAD_STAND

## Host: on (hired, section open, a real shift) or off (Staff.gd decides).
## Clocking in puts them at their spot by the pad; clocking off sets down
## anything in hand (ordinary loose stock in their own room).
func set_active(on: bool) -> void:
	if on == active:
		return
	active = on
	_put_down_all()
	_reset_brain()
	position = home()
	target_position = position
	facing_angle = PI * 0.5
	reset_physics_interpolation()

## Host, every shift start (the floor and the shelves were just cleared).
func reset_for_new_shift() -> void:
	_reset_brain()
	position = home()
	target_position = position
	facing_angle = PI * 0.5
	reset_physics_interpolation()
	placed_today = 0
	picked_today = 0
	unpacked_today = 0
	knocked_reshelved_today = 0
	forklift_yield_s = 0.0
	walked_px = 0.0

func _reset_brain() -> void:
	_job = {}
	_path = PackedVector2Array()
	_path_goal = Vector2.INF
	_pause = 0.0
	_pause_action = ""
	_settling_seen = {}
	_slot_skip = {}
	_delivering = false
	status = ""

## --- Every peer: smoothing + visuals ---------------------------------------

func _process(delta: float) -> void:
	visible = active
	if not Net.is_active() or not active:
		return
	if not is_multiplayer_authority():
		if position.distance_to(target_position) > 150.0:
			position = target_position
			reset_physics_interpolation()
		else:
			position = position.lerp(target_position, clampf(10.0 * delta, 0.0, 1.0))
	_tag.text = "%s · %s" % [helper_name, status if status != "" else "staff"]

## --- Host: the brain ----------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not Net.is_active() or not is_multiplayer_authority() or not active:
		return
	_clock += delta
	# Frozen under the report like everything else (Shelf/Customer do the same).
	if main.is_day_report_active():
		return
	# Off the clock once the store closes for cleanup (that's the crew's job):
	# whatever's in hand goes down where they stand, and they wait by the pad.
	if not main.shift_active or main.cleanup_active:
		if not _held().is_empty():
			_put_down_all()
		_job = {"kind": "home"}
		status = ""
		_walk_toward(home(), delta)
		return
	if _pause > 0.0:
		_pause -= delta
		if _pause <= 0.0:
			_finish_action()
		return
	_job_t += delta
	if not _job.is_empty() and _job_t > JOB_TIMEOUT and _job["kind"] == "place":
		_slot_skip["%d:%d" % [_job["shelf"].get_instance_id(), _job["i"]]] = _clock + SLOT_COOLDOWN
	if _job.is_empty() or not _job_valid() or _job_t > JOB_TIMEOUT or (_job["kind"] == "home" and _job_t > 0.5):
		_choose_job()
	var goal := _job_goal()
	if position.distance_to(goal) <= 1.5:
		_arrive()
		return
	_walk_toward(goal, delta)

func _walk_toward(goal: Vector2, delta: float) -> void:
	_replan_t -= delta
	if goal != _path_goal or (_replan_t <= 0.0 and _forklift_live() != null):
		_replan_t = REPLAN_EVERY
		_plan(goal)
	var step := speed * delta
	var flee := _forklift_step(delta)
	if flee != Vector2.INF:
		_move_to(flee)
		_path_goal = Vector2.INF # re-plan from wherever this leaves us
		return
	while step > 0.0 and not _path.is_empty():
		var nxt: Vector2 = _path[0]
		var d := position.distance_to(nxt)
		if _forklift_blocks(nxt):
			forklift_yield_s += delta
			return
		if d <= step:
			_move_to(nxt)
			step -= d
			_path.remove_at(0)
		else:
			_move_to(position + (nxt - position) / d * step)
			step = 0.0

func _move_to(p: Vector2) -> void:
	var d := p - position
	if d.length() > 0.01:
		facing_angle = d.angle()
		walked_px += d.length()
	position = p
	target_position = p

## --- Jobs -------------------------------------------------------------------

## The one decision: shelve what's in hand, pick more up, open a box, or wait.
func _choose_job() -> void:
	_job_t = 0.0
	var held := _held()
	var loose := _loose_items()
	var empty := _empty_slots()
	var room_for := empty.size() - held.size() # open slots nothing in hand is already going to
	if held.is_empty():
		_delivering = false
	# An armful goes out in one round: once the helper starts shelving it, it
	# shelves all of it before picking more up (FOUND BY THE EFFECT TEST: going
	# back for one more after every slot made the carry upgrade worth ~5%).
	if not held.is_empty() and (_delivering or held.size() >= capacity or loose.is_empty() or room_for <= 0):
		_delivering = true
		if empty.is_empty():
			_job = {"kind": "home"} # nowhere to put it (shelves full or wrecked): hold it
		else:
			_job = _nearest(empty, position)
			_job["kind"] = "place"
	elif held.size() < capacity and not loose.is_empty() and room_for > 0:
		var obj: Node2D = _nearest_node(loose, position)
		_job = {"kind": "pick", "obj": obj}
	elif held.is_empty() and loose.is_empty() and not empty.is_empty() and main.staff.backstock_of(section) > 0:
		_job = {"kind": "unpack"}
	else:
		_job = {"kind": "home"}

func _job_valid() -> bool:
	match _job["kind"]:
		"pick":
			var obj = _job["obj"]
			return is_instance_valid(obj) and not obj.is_queued_for_deletion() and _is_loose(obj)
		"place":
			var shelf: Node = _job["shelf"]
			return not shelf.wrecked and not shelf.filled[_job["i"]] and not _held().is_empty() and not _slot_claimed(shelf, _job["i"])
		"unpack":
			return main.staff.backstock_of(section) > 0
	return true

func _job_goal() -> Vector2:
	match _job["kind"]:
		"pick":
			var obj: Node2D = _job["obj"]
			var to := position - obj.global_position
			# Stop just short of it, on whichever side we're coming from.
			return obj.global_position + (to.normalized() * PICK_REACH if to.length() > PICK_REACH else to)
		"place":
			return _job["stand"]
		"unpack":
			return home()
	return home()

func _arrive() -> void:
	match _job["kind"]:
		"pick":
			var obj: Node2D = _job["obj"]
			facing_angle = (obj.global_position - position).angle()
			if obj.has_meta("knocked"):
				knocked_reshelved_today += 1 # (counted on the pick: it's on its way back)
			obj.get_node("Carryable").try_pickup(carry_id, position)
			_pause_with(PICK_TIME, "pick")
		"place":
			facing_angle = _job["face"]
			var held := _held()
			if not held.is_empty():
				held[-1].get_node("Carryable").try_drop(carry_id)
			_pause_with(PLACE_TIME, "place")
		"unpack":
			facing_angle = -PI * 0.5 # facing the pad
			status = "unpacking…"
			_pause_with(UNPACK_TIME, "unpack")
		_:
			facing_angle = PI * 0.5
			_job = {}

func _pause_with(t: float, action: String) -> void:
	_pause = t
	_pause_action = action

func _finish_action() -> void:
	match _pause_action:
		"pick":
			if is_instance_valid(_job.get("obj")) and _job["obj"].get_node("Carryable").carrier_id == carry_id:
				picked_today += 1
		"place":
			placed_today += 1
		"unpack":
			status = ""
			if main.staff.open_backstock_box(section):
				unpacked_today += 1
	_pause_action = ""
	_job = {}

## --- What's where (host) --------------------------------------------------------

func _held() -> Array:
	var out := []
	for obj in get_tree().get_nodes_in_group("carryable"):
		if obj.get_node("Carryable").carrier_id == carry_id:
			out.append(obj)
	out.sort_custom(func(a, b): return a.get_node("Carryable").carry_seq < b.get_node("Carryable").carry_seq)
	return out

func _put_down_all() -> void:
	var held := _held()
	for i in held.size():
		held[i].get_node("Carryable").try_drop(carry_id, i)

func in_room(p: Vector2) -> bool:
	return _room.grow(-24.0).has_point(p)

func _is_loose(obj: Node2D) -> bool:
	if obj.is_in_group("delivery_box") or not in_room(obj.global_position):
		return false
	var visual := obj.get_node_or_null("Polygon2D")
	if visual == null or not visual.color.is_equal_approx(color):
		return false
	var c: Node = obj.get_node("Carryable")
	if c.carrier_id != 0 or c.shelved or obj.linear_velocity.length() > ITEM_REST_SPEED:
		return false
	for shelf_body in _shelves():
		if shelf_body.get_node("Shelf").contains(obj):
			return false
	# Lying on an empty slot: it's settling in by itself — leave it a moment.
	if _on_empty_slot(obj.global_position):
		var id := obj.get_instance_id()
		if not _settling_seen.has(id):
			_settling_seen[id] = _clock
		return _clock - float(_settling_seen[id]) > SETTLING_GRACE
	return true

func _loose_items() -> Array:
	var out := []
	for obj in get_tree().get_nodes_in_group("carryable"):
		if not obj.is_queued_for_deletion() and _is_loose(obj):
			out.append(obj)
	return out

func _shelves() -> Array:
	return main.shelves.filter(func(s): return main._grid_cell_of(s.global_position) == cell)

func _on_empty_slot(p: Vector2) -> bool:
	for shelf_body in _shelves():
		var shelf: Node = shelf_body.get_node("Shelf")
		for i in shelf.slots.size():
			if not shelf.filled[i] and p.distance_to(shelf.slots[i].global_position) <= shelf.CAPTURE_RADIUS + 4.0:
				return true
	return false

## Something loose (anyone's) already lying on this empty slot — it's taken.
func _slot_claimed(shelf: Node, i: int) -> bool:
	var at: Vector2 = shelf.slots[i].global_position
	for obj in get_tree().get_nodes_in_group("carryable"):
		if obj.get_node("Carryable").carrier_id == 0 and obj.global_position.distance_to(at) <= shelf.CAPTURE_RADIUS:
			return true
	return false

## Every open slot in the room: [{shelf, i, stand, face, pos}].
func _empty_slots() -> Array:
	var out := []
	for shelf_body in _shelves():
		var shelf: Node = shelf_body.get_node("Shelf")
		if shelf.wrecked:
			continue
		var outward: Vector2 = -shelf_body.global_transform.y.normalized()
		for i in shelf.slots.size():
			if shelf.filled[i] or _slot_claimed(shelf, i) or _clock < float(_slot_skip.get("%d:%d" % [shelf.get_instance_id(), i], -1.0)):
				continue
			var at: Vector2 = shelf.slots[i].global_position
			var stand := at + outward * SLOT_STAND
			if _in_forklift(stand, CLEARANCE):
				continue # it's parked (or working) right there: another slot first
			out.append({"shelf": shelf, "i": i, "stand": stand, "face": (-outward).angle(), "pos": at})
	return out

func _nearest(jobs: Array, from: Vector2) -> Dictionary:
	var best := {}
	var best_d := INF
	for j in jobs:
		var d: float = from.distance_to(j["stand"])
		if d < best_d:
			best_d = d
			best = j
	return best.duplicate()

func _nearest_node(nodes: Array, from: Vector2) -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for n in nodes:
		var d: float = from.distance_to(n.global_position)
		if d < best_d:
			best_d = d
			best = n
	return best

## --- Paths (host) ------------------------------------------------------------------

## Grid path from here to goal around the room's shelves and floor displays
## (re-read every plan: displays get knocked about), straightened by line of
## sight. The goal's own cell may be next to a shelf (stock knocked into a
## corner): the path ends at the nearest open cell, then goes straight in.
func _plan(goal: Vector2) -> void:
	_path_goal = goal
	_astar.fill_solid_region(_astar.region, false)
	_mark_walls()
	for shelf_body in _shelves():
		var cs: CollisionShape2D = shelf_body.get_node("CollisionShape2D")
		var r: RectangleShape2D = cs.shape
		var xf: Transform2D = cs.global_transform
		_mark_solid_rect(xf, r.size * 0.5 + Vector2(CLEARANCE, CLEARANCE))
	for d in main.displays:
		_mark_solid_circle(d.global_position, DISPLAY_RADIUS + CLEARANCE)
	var fk := _forklift_live()
	if fk != null:
		_mark_solid_rect(Transform2D(fk.rotation, fk.global_position + Vector2.RIGHT.rotated(fk.rotation) * FORKLIFT_BOX_OFFSET), FORKLIFT_HALF + Vector2(FORKLIFT_PAD, FORKLIFT_PAD))
	var from_c := _open_cell_near(_to_cell(position))
	var to_c := _open_cell_near(_to_cell(goal))
	var pts := PackedVector2Array()
	if from_c != Vector2i(-1, -1) and to_c != Vector2i(-1, -1):
		pts = _astar.get_point_path(from_c, to_c)
	if pts.is_empty():
		_path = PackedVector2Array([goal])
		return
	pts.append(goal)
	_path = _smooth(pts)

func _to_cell(p: Vector2) -> Vector2i:
	var local := p - _room.position
	return Vector2i(clampi(int(local.x / GRID), 0, _astar.region.size.x - 1), clampi(int(local.y / GRID), 0, _astar.region.size.y - 1))

func _cell_center(c: Vector2i) -> Vector2:
	return _room.position + (Vector2(c) + Vector2(0.5, 0.5)) * GRID

func _mark_solid_rect(xf: Transform2D, half: Vector2) -> void:
	var inv := xf.affine_inverse()
	for x in _astar.region.size.x:
		for y in _astar.region.size.y:
			var local: Vector2 = inv * _cell_center(Vector2i(x, y))
			if absf(local.x) <= half.x and absf(local.y) <= half.y:
				_astar.set_point_solid(Vector2i(x, y), true)

## The room's own walls (20px thick) plus clearance.
func _mark_walls() -> void:
	var edge := int(ceil((20.0 + CLEARANCE) / GRID))
	for x in _astar.region.size.x:
		for y in _astar.region.size.y:
			if x < edge or y < edge or x >= _astar.region.size.x - edge or y >= _astar.region.size.y - edge:
				_astar.set_point_solid(Vector2i(x, y), true)

func _mark_solid_circle(center: Vector2, radius: float) -> void:
	if not _room.grow(radius).has_point(center):
		return
	for x in _astar.region.size.x:
		for y in _astar.region.size.y:
			if _cell_center(Vector2i(x, y)).distance_to(center) <= radius:
				_astar.set_point_solid(Vector2i(x, y), true)

func _open_cell_near(c: Vector2i) -> Vector2i:
	if not _astar.is_point_solid(c):
		return c
	for r in range(1, 8):
		var best := Vector2i(-1, -1)
		var best_d := INF
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var n := c + Vector2i(dx, dy)
				if _astar.is_in_boundsv(n) and not _astar.is_point_solid(n):
					var d := Vector2(dx, dy).length()
					if d < best_d:
						best_d = d
						best = n
		if best != Vector2i(-1, -1):
			return best
	return Vector2i(-1, -1)

## Drop every waypoint the one before it can see past (sampled line of sight
## against the solid cells), so the walk is straight lines, not grid steps.
func _smooth(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	var from := position
	var i := 0
	while i < pts.size():
		var j := pts.size() - 1
		while j > i and not _clear_line(from, pts[j]):
			j -= 1
		out.append(pts[j])
		from = pts[j]
		i = j + 1
	return out

func _clear_line(a: Vector2, b: Vector2) -> bool:
	var n := int(a.distance_to(b) / (GRID * 0.5)) + 1
	for k in range(1, n):
		var c := _to_cell(a.lerp(b, float(k) / n))
		if _astar.is_point_solid(c):
			return false
	return true

## --- The Produce forklift (host) ------------------------------------------------

func _forklift_live() -> Node2D:
	var fk: Node2D = main.forklift
	if fk == null or not fk.active or not fk.visible or main._grid_cell_of(fk.global_position) != cell:
		return null
	return fk

## Moving, or flashing its beacon before a ram.
func _forklift_moving(fk: Node2D) -> bool:
	return fk.velocity.length() > 5.0 or fk.alert

## Inside the forklift's body grown by `margin` (false if it isn't here).
func _in_forklift(p: Vector2, margin: float) -> bool:
	var fk := _forklift_live()
	if fk == null:
		return false
	var local: Vector2 = (p - fk.global_position).rotated(-fk.rotation) - Vector2(FORKLIFT_BOX_OFFSET, 0.0)
	return absf(local.x) < FORKLIFT_HALF.x + margin and absf(local.y) < FORKLIFT_HALF.y + margin

## Inside FLEE of a moving forklift: a step directly away from it, kept in the
## room's open band (Vector2.INF = no need).
func _forklift_step(delta: float) -> Vector2:
	var fk := _forklift_live()
	if fk == null or not _forklift_moving(fk):
		return Vector2.INF
	var away := position - fk.global_position
	if away.length() >= FORKLIFT_FLEE:
		return Vector2.INF
	forklift_yield_s += delta
	if away.length() < 0.01:
		away = Vector2.UP
	var p := position + away.normalized() * speed * delta
	p.x = clampf(p.x, _room.position.x + 60.0, _room.end.x - 60.0)
	p.y = clampf(p.y, _room.position.y + BAND_Y.x, _room.position.y + BAND_Y.y)
	return p

## Inside YIELD: don't take a step that gets any closer to it.
func _forklift_blocks(nxt: Vector2) -> bool:
	var fk := _forklift_live()
	if fk == null or not _forklift_moving(fk):
		return false
	var d := position.distance_to(fk.global_position)
	if d >= FORKLIFT_YIELD:
		return false
	var step_dir := (nxt - position).normalized()
	return step_dir.dot((fk.global_position - position).normalized()) > 0.2
