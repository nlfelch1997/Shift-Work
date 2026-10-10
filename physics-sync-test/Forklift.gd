extends CharacterBody2D
## WEEK 8 — the Day 3+ forklift hazard. A host-driven vehicle that patrols
## the aisle of whichever section it's placed in (Meat/Deli — see Main.tscn's
## Forklift node and Main.gd's _configure_hazards()), periodically pulls up
## to a shelf, and every so often RAMS one: the shelf's stock gets flung
## across the aisle as real RigidBody2D physics (the same request_push()
## impulse path every other knock in this project already uses) and the
## shelf itself is wrecked for a while (Shelf.gd's wreck()). Players and
## customers it drives into get knocked aside, not blocked or killed — it's
## meant to be something to route around and clean up after, never a wall.
##
## AUTHORITY: always the host (peer 1), same as customers/products/shelves.
## Only the host runs the patrol state machine and move_and_slide(); every
## other peer just smooths toward the replicated target_position/
## target_rotation, same split as Customer.gd. The client-side copy still
## has a live CollisionShape2D at its smoothed position, which is what lets
## a client's own (client-authoritative) player physically bump into it
## locally instead of walking through it.
##
## WHY CharacterBody2D AND NOT AnimatableBody2D/RigidBody2D: an
## AnimatableBody2D is moved by script with effectively infinite mass and
## ignores static geometry — it would happily squeeze a product between its
## forks and a shelf or wall until the physics engine's depenetration flung
## it off the map (the same class of bug Carryable.gd's MAX_SPEED clamp and
## "collision disabled while carried" fix were both written to stop). A
## CharacterBody2D's move_and_slide() STOPS at whatever it touches and
## reports it via get_slide_collision(), which is exactly the hook this
## script needs: every contact becomes an explicit, bounded impulse /
## knockback / wreck decision (see _handle_contacts()), never an unbounded
## physics shove. A RigidBody2D forklift would itself get knocked around by
## thrown products, which isn't the fantasy either.
##
## DAY GATING: Main.gd calls configure(active) whenever current_day changes
## (on every peer, same poll that drives gates/cashiers). "Active" is NOT a
## hardcoded "day >= 3" in here — it's whether the forklift's own section is
## unlocked (Main.gd's is_unlocked_at_pos(home_position)), so the SECTIONS
## table stays the single source of truth for "when does Meat/Deli open":
## if that section's required_day ever moves, the forklift moves with it
## instead of silently patrolling a locked, unreachable room. While
## inactive it's hidden AND its collision is disabled — not merely parked —
## so nothing can snag on an invisible body on Days 1-2.
##
## PATROL SHAPE: derived at runtime from the shelves actually in this
## section (_build_lap()), not a hand-typed waypoint list, for the same
## reason Main.gd matches shelves to sections by grid cell rather than node
## name: moving a shelf in Main.tscn can't silently desync the patrol from
## the layout. The lap drives the section's central aisle lane end to end
## and back, stopping at every shelf "station" on the way — a short
## pull-up-and-back-out (a near-miss "loading" feint) at most of them, and a
## telegraphed RAM at RAMS_PER_LAP of them. Every number below is a
## placeholder, same as this project's other untuned constants.

const DRIVE_SPEED := 120.0 # well under Player.gd's 220 — outrunnable on purpose
const RAM_SPEED := 175.0
const REVERSE_SPEED := 85.0
const TURN_RATE := 3.2 # rad/s, turning in place
const ALIGN_TOLERANCE := 0.06
const ARRIVE_DIST := 5.0
## How far the forks' tip reaches in front of the body origin — must match
## Forklift.tscn's CollisionShape2D (92 wide, centered at x=+6 -> front edge
## at +52). Used to stop a near-miss short of the shelf's slot line.
const FRONT_REACH := 52.0
## Gap left between the forks and the front edge of a stocked product on a
## near-miss pull-up. Products are 28x28 (Product.tscn), so slot line + 14 is
## their front face.
const NEAR_MISS_CLEARANCE := 22.0
const PRODUCT_HALF_SIZE := 14.0
## Distance in from the section's east/west edges for the lane's end points.
## 110 keeps the forks (FRONT_REACH=52) clear of the 20px perimeter wall
## (inner edge 20px in from the cell edge) and of the gate line on the hub
## side, with room to turn around (the rotated collision box's corner
## radius is ~56px).
const LANE_END_MARGIN := 110.0
const LOAD_PAUSE := 1.2 # stopped at a shelf on a near-miss
const END_PAUSE := 1.6 # stopped at each end of the lane
const TELEGRAPH_TIME := 0.9 # stopped, facing the shelf, beacon flashing, before a ram
const RAMS_PER_LAP := 1
const START_PAUSE := 4.0 # after every day's reset, before the first move
## WEEK 12 — Day 7 finale (Main.gd's FINALE_START_DAY): the same lap with the
## stops cut short, so passes come around faster. The TELEGRAPH_TIME before a
## ram and every speed are deliberately untouched — the warning and
## "outrunnable" are what keep it fair. FLAGGED placeholders.
const FINALE_LOAD_PAUSE := 0.7
const FINALE_END_PAUSE := 0.8
## Leg skipped if distance-to-target hasn't improved for this long while
## actively driving — something (a pinned display, a player deliberately
## body-blocking) is in the way and isn't moving. No navmesh here either
## (same as Customer.gd), so "give up on this leg, carry on with the lap"
## is the generic fix; the forklift never gets permanently stuck.
const STALL_TIMEOUT := 1.5
## Impulse-per-unit-mass handed to a RigidBody2D it drives into — expressed
## as a target speed (impulse = speed * mass) so a 0.4-mass product and a
## heavier display both visibly get knocked, rather than one shared raw
## impulse sending products to MAX_SPEED and barely nudging displays.
const KNOCK_SPEED_PRODUCT := 480.0
const KNOCK_SPEED_DISPLAY := 360.0
## Random sideways share added to every knock (fraction of the forward
## direction) — knocked things spray aside instead of being plowed straight
## ahead and pinned between the forks and the next wall.
const KNOCK_SPREAD := 0.8
const BODY_HIT_COOLDOWN := 0.35 # per RigidBody2D — no fresh impulse every single tick of one contact
const ACTOR_HIT_COOLDOWN := 1.0 # per player/customer — one knockback per bump, not an RPC every tick
## FOUND BY TESTING (headless host+client run): a stocked product sits only
## ~8px in front of its shelf's collision box, so a ram could pin the
## shelf's own stock between the forks and the shelf and stall there without
## the forks ever touching the shelf body itself. During a ram, touching
## any loose body within this distance of the TARGET shelf's origin counts
## as hitting that shelf. 100 covers every slot (they sit 70-92px out) but
## not loose items further up the aisle, so it can't trigger from the lane.
const RAM_STOCK_CONTACT_RADIUS := 100.0

## WEEK 19 — both forklifts wear the same warehouse-pack sprite (was: the
## Produce one kept the Week 8 placeholder polygons, still in Forklift.tscn
## and hidden here). Tile-B-04's orange counterbalance forklift: side view
## with the forks pointing left (flipped for east), the same truck from the
## front. Drawn upright whatever the collision box's rotation. The pack has
## no rear view, so heading north (only the Produce forklift does, ramming a
## shelf above the lane) keeps the side view it last had.
const ART_SHEET := "res://assets/warehouse/tile-B-04.png"
const ART_SIDE := Rect2i(99, 102, 91, 89)
const ART_FRONT := Rect2i(204, 99, 71, 92)
const ART_SCALE := 0.95

## WEEK 26 — a driver in the seat. Each forklift has one fixed driver
## (driver_look(): never random, never synced — every peer derives the same
## look from which forklift it is). The sheet is the LPC generator's seated-
## on-a-chair frame in the 4 facings (tools/lpc/post.py), so the driver is a
## plain Sprite2D on top of the truck art, not a CharacterSprite: it never
## walks, and its facing is exactly the truck art's own (side view left/
## right, front view = facing the camera), decided in _update_art() from the
## already-replicated rotation — so it can't disagree with the truck.
## Offsets are in truck-art pixels from the art's center, for the side view
## with the forks pointing left (mirrored when the art is flipped).
const CharacterSpriteScript := preload("res://CharacterSprite.gd")
const DRIVER_SCALE := 0.68
const DRIVER_SIDE_AT := Vector2(15, 4)
const DRIVER_FRONT_AT := Vector2(0, 2)
## Rows of the seated frame that are drawn: down to just below the knees, so
## the lower legs/boots stay "inside" the cab (behind the body panel).
const DRIVER_CROP_H := 52
## A little bounce in the seat while the truck is actually moving.
const DRIVER_BOB_PX := 1.0
const DRIVER_BOB_HZ := 7.0

@export var home_rotation := PI # parked facing west (toward the hub) at the lane's east end

## Replicated (see _ready()). target_* are the host's real pose, smoothed
## toward on clients; reversing/alert only drive visuals.
var target_position: Vector2
var target_rotation := 0.0
var reversing := false
var alert := false

var active := false
## Set in _ready() from the scene placement; reset_for_new_day() returns
## here, and Main.gd reads it to decide which section this forklift belongs
## to (see the DAY GATING note above).
var home_position := Vector2.ZERO

var _legs: Array = []
var _pause_timer := 0.0
var _stall_timer := 0.0
var _leg_best_dist := INF
var _hit_cooldowns := {} # instance_id -> seconds left
var _blink_t := 0.0
## Diagnostic only — how many rams landed this day; printed and shown on the
## debug HUD so a playtest log can confirm the hazard actually did something.
var rams_today := 0
var _art: Sprite2D
var _facing_east := true
var _driver: Sprite2D
var _driver_row := -1
var _driver_last_pos := Vector2.INF
var _driver_speed := 0.0
var _driver_t := 0.0

func _ready() -> void:
	add_to_group("forklift")
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING # top-down: no floor/wall distinction
	# PLAYTEST FIX: shelved stock is on its own layer that players and loose
	# stock pass through (Carryable.gd's LAYER_SHELF_STOCK) — a forklift is a
	# real hazard, so it still hits it (and a ram still wrecks the shelf).
	collision_mask |= preload("res://Carryable.gd").LAYER_SHELF_STOCK
	home_position = position
	rotation = home_rotation
	target_position = position
	target_rotation = rotation
	reset_physics_interpolation()
	set_multiplayer_authority(1)

	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	for prop in [".:target_position", ".:target_rotation", ".:reversing", ".:alert"]:
		var path := NodePath(prop)
		config.add_property(path)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config
	sync.name = "Sync" # explicit, identical name on every peer — see Player.gd's note on why an auto-generated name breaks replication
	sync.set_multiplayer_authority(1)
	add_child(sync)
	for n in ["ForkLeft", "ForkRight", "Body", "Stripes", "Mast", "Seat"]:
		get_node(n).visible = false
	_art = Sprite2D.new()
	_art.name = "Art"
	_art.texture = load(ART_SHEET)
	_art.region_enabled = true
	_art.scale = Vector2.ONE * ART_SCALE
	add_child(_art)
	move_child(_art, 0)
	_driver = Sprite2D.new()
	_driver.name = "Driver"
	_driver.texture = load(CharacterSpriteScript.texture_path(driver_look()))
	_driver.region_enabled = true
	_driver.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# The truck art's scale is applied on top (child of _art).
	_driver.scale = Vector2.ONE * (DRIVER_SCALE / ART_SCALE)
	_art.add_child(_driver)
	configure(false)

## Which assets/characters/ sheet sits in the seat. Fixed per forklift.
func driver_look() -> String:
	return "driver_produce"

## Driver row (CharacterSpriteScript.ROW_*) currently shown — read by the tests.
func driver_row() -> int:
	return _driver_row

## Called by Main.gd on EVERY peer whenever current_day changes (see
## _configure_hazards()). Pure local state — visibility and collision —
## derived from the already-replicated day, same shape as Gate.gd's
## configure(). Collision is toggled with set_deferred(): this can run from
## a Continue-button RPC mid-frame, and flipping a shape's disabled flag
## while the physics server is flushing queries is an engine error.
## Finale pacing on/off — host-side only matters (it builds the laps), but
## set on every peer from the replicated day like `active`.
var finale := false

func configure(is_active: bool, is_finale := false) -> void:
	finale = is_finale
	active = is_active
	visible = is_active
	$CollisionShape2D.set_deferred("disabled", not is_active)
	if not is_active:
		reversing = false
		alert = false

## Host-only: called by Main.gd's _start_shift() every day. Puts the forklift
## back at its home spot with a fresh lap and a START_PAUSE grace before it
## moves, so a new day never begins with it wedged against whatever the last
## day left it touching.
func reset_for_new_day() -> void:
	if not is_multiplayer_authority():
		return
	position = home_position
	rotation = home_rotation
	target_position = position
	target_rotation = rotation
	velocity = Vector2.ZERO
	reset_physics_interpolation()
	_legs.clear()
	_pause_timer = START_PAUSE
	_stall_timer = 0.0
	_leg_best_dist = INF
	_hit_cooldowns.clear()
	reversing = false
	alert = false
	rams_today = 0

func _physics_process(delta: float) -> void:
	if not Net.is_active() or not is_multiplayer_authority():
		return
	if not active:
		return
	var main = get_tree().current_scene
	if not _running(main):
		velocity = Vector2.ZERO
		return
	_tick_cooldowns(delta)
	_drive(delta)
	target_position = position
	target_rotation = rotation

## Frozen for the end-of-day report (same PLAYTEST BUG FIX as Customer.gd/
## Player.gd/Shelf.gd) and before the first shift has actually started.
## WEEK 17: and through the prep phase — the Produce forklift's patrol is
## part of the chaos that starts when the store opens (Main.gd's
## open_store()); it sits parked at its home spot until then, and its
## START_PAUSE counts from the opening. DeliveryForklift.gd overrides this:
## deliveries run through prep.
func _running(main) -> bool:
	return not main.is_day_report_active() and main.shift_active and main.store_open and not main.cleanup_active

func _drive(delta: float) -> void:
	if _pause_timer > 0.0:
		_pause_timer -= delta
		velocity = Vector2.ZERO
		if _pause_timer <= 0.0:
			alert = false
		return
	if _legs.is_empty():
		_build_lap()
		if _legs.is_empty():
			return # no shelves found in this section — nothing to patrol
	var leg: Dictionary = _legs[0]
	var to_target: Vector2 = leg["pos"] - global_position
	var dist := to_target.length()
	var mode: String = leg["mode"]
	reversing = mode == "reverse"
	if dist <= ARRIVE_DIST:
		_finish_leg()
		return
	var desired := to_target.angle() + (PI if mode == "reverse" else 0.0)
	var diff := wrapf(desired - rotation, -PI, PI)
	if absf(diff) > ALIGN_TOLERANCE:
		# Turn in place, don't move — a forklift pivots, it doesn't drift
		# sideways, and it keeps every move below a straight line the
		# stall check can measure honestly.
		rotation += clampf(diff, -TURN_RATE * delta, TURN_RATE * delta)
		velocity = Vector2.ZERO
		return
	rotation = desired
	if leg.get("telegraph", false) and not leg.get("telegraphed", false):
		leg["telegraphed"] = true
		alert = true
		_pause_timer = TELEGRAPH_TIME
		return
	var speed := DRIVE_SPEED
	if mode == "ram":
		speed = RAM_SPEED
	elif mode == "reverse":
		speed = REVERSE_SPEED
	# Clamp to the remaining distance so a plain drive leg lands on its
	# point instead of oscillating around it; a ram never arrives (its target
	# is inside the shelf body), it ends on contact instead.
	velocity = to_target / dist * minf(speed, dist / delta)
	move_and_slide()
	if _handle_contacts(mode, leg.get("shelf")):
		_finish_leg()
		return
	if dist < _leg_best_dist - 1.0:
		_leg_best_dist = dist
		_stall_timer = 0.0
	else:
		_stall_timer += delta
		if _stall_timer >= STALL_TIMEOUT:
			print("[Forklift] leg (%s -> %s) stalled, skipping" % [mode, leg["pos"]])
			_finish_leg()

## Returns true if this tick's contacts ended the current leg (a ram hit
## its shelf).
func _handle_contacts(mode: String, ram_shelf: Node2D) -> bool:
	var ended := false
	var forward := Vector2.RIGHT.rotated(rotation)
	var travel := -forward if mode == "reverse" else forward
	for i in get_slide_collision_count():
		var col := get_slide_collision(i)
		var other := col.get_collider() as Node
		if other == null:
			continue
		if other is RigidBody2D:
			_knock_body(other as RigidBody2D, -col.get_normal(), travel)
			if mode == "ram" and ram_shelf and other.global_position.distance_to(ram_shelf.global_position) <= RAM_STOCK_CONTACT_RADIUS:
				_ram(ram_shelf)
				ended = true
		elif other.is_in_group("shelf"):
			if mode == "ram":
				_ram(other)
				ended = true
		elif other.is_in_group("player"):
			if _cooldown_ready(other, ACTOR_HIT_COOLDOWN):
				# WEEK 10: tell the manager first — the fumble and knockback
				# slide this hit causes aren't the player's chaos (see
				# Manager.gd's note_forklift_hit()).
				var manager := get_tree().get_first_node_in_group("manager")
				if manager:
					manager.note_forklift_hit(other.get_multiplayer_authority())
				# Player movement is client-authoritative, so the host can't
				# move a remote player itself — it asks that player's owner
				# to, the same broadcast-and-only-the-owner-acts shape as
				# Player.gd's teleport_to().
				other.rpc("forklift_hit", global_position)
		elif other.is_in_group("customer"):
			if _cooldown_ready(other, ACTOR_HIT_COOLDOWN):
				# Customers are host-authority, so this is a direct local
				# call — reuses the Week 6 defend/shove knockback+stun
				# verbatim rather than inventing a second one.
				other.request_shove(global_position)
	return ended

func _ram(shelf_body: Node) -> void:
	if shelf_body.get_node("Shelf").wreck(global_position):
		rams_today += 1
		print("[Forklift] RAM -> %s wrecked (rams today: %d)" % [shelf_body.get_path(), rams_today])

func _knock_body(other: RigidBody2D, into: Vector2, travel: Vector2) -> void:
	var comp: Node = other.get_node_or_null("Carryable")
	var knock_speed := KNOCK_SPEED_PRODUCT
	if comp == null:
		comp = other.get_node_or_null("Display")
		knock_speed = KNOCK_SPEED_DISPLAY
	if comp == null:
		return
	if not _cooldown_ready(other, BODY_HIT_COOLDOWN):
		return
	var dir := (into + travel).normalized()
	dir = (dir + dir.orthogonal() * randf_range(-KNOCK_SPREAD, KNOCK_SPREAD)).normalized()
	# request_push() called directly (not over RPC): this only ever runs on
	# the host, which is every Carryable/Display's authority. Carryable's
	# own version already skips anything currently being carried.
	comp.request_push(dir * knock_speed * other.mass)

func _cooldown_ready(obj: Object, cooldown: float) -> bool:
	var id := obj.get_instance_id()
	if _hit_cooldowns.get(id, 0.0) > 0.0:
		return false
	_hit_cooldowns[id] = cooldown
	return true

func _tick_cooldowns(delta: float) -> void:
	for id in _hit_cooldowns.keys():
		_hit_cooldowns[id] -= delta
		if _hit_cooldowns[id] <= 0.0:
			_hit_cooldowns.erase(id)

func _finish_leg() -> void:
	var leg: Dictionary = _legs.pop_front()
	_pause_timer = leg.get("pause", 0.0)
	_stall_timer = 0.0
	_leg_best_dist = INF
	velocity = Vector2.ZERO
	reversing = false
	alert = false

## One full lap: from its home end, drive the lane to the far end stopping at
## each shelf station, pause, then back doing the same. Every station gets
## visited once per pass — its shelf on one side of the lane on the way
## out, the other side on the way back (which side comes first is random)
## — and RAMS_PER_LAP of those visits, chosen at random, are rams instead of
## near-misses, so which shelf gets hit is never predictable lap to lap.
## PHASE 5B PART 2B: along either axis — the lane's long side is its axis
## (Plan B's Produce lane runs north-south; the old one ran east-west, which
## this reproduces exactly: "along" = x, "across" = y, home at the east end).
func _build_lap() -> void:
	var main = get_tree().current_scene
	# PHASE 5B PART 2A: the lane is the layout's "forklift_lane" area at its
	# home (StoreLayout.gd); the stations are the shelves in that room.
	var areas: RefCounted = main.areas
	var lane: Rect2 = areas.rect_of(areas.feature_at(home_position, "forklift_lane"))
	var room: String = areas.area_at(home_position)
	var axis := Vector2.RIGHT if lane.size.x >= lane.size.y else Vector2.DOWN
	var across_axis := Vector2(axis.y, axis.x)
	var lane_lo: float = lane.position.dot(axis)
	var lane_hi: float = lane.end.dot(axis)
	var lane_across: float = home_position.dot(across_axis)
	var at := func(along: float, across: float) -> Vector2: return axis * along + across_axis * across
	var stations := {}
	for shelf_body in get_tree().get_nodes_in_group("shelf"):
		var p: Vector2 = shelf_body.global_position
		if areas.area_at(p) != room:
			continue
		var key := roundi(p.dot(axis))
		if not stations.has(key):
			stations[key] = {}
		stations[key]["above" if p.dot(across_axis) < lane_across else "below"] = shelf_body
	var keys := stations.keys()
	keys.sort()
	if keys.is_empty():
		return
	# Out from home to the far end first, then back.
	var home_high: bool = home_position.dot(axis) >= (lane_lo + lane_hi) * 0.5
	var out_pass := keys.duplicate()
	if home_high:
		out_pass.reverse()
	var back_pass := out_pass.duplicate()
	back_pass.reverse()
	var visits := [] # [{x, shelf}] in driving order ("x" = along the lane)
	var first_side := {}
	for x in out_pass:
		var sides: Array = stations[x].keys()
		first_side[x] = sides[randi() % sides.size()]
		visits.append({"x": x, "shelf": stations[x][first_side[x]]})
	visits.append({"end": (lane_lo + LANE_END_MARGIN) if home_high else (lane_hi - LANE_END_MARGIN)})
	for x in back_pass:
		var other_side: String = "below" if first_side[x] == "above" else "above"
		var shelf_body = stations[x].get(other_side, stations[x][first_side[x]])
		visits.append({"x": x, "shelf": shelf_body})
	visits.append({"end": (lane_hi - LANE_END_MARGIN) if home_high else (lane_lo + LANE_END_MARGIN)})
	var shelf_visit_indices := []
	for i in visits.size():
		if visits[i].has("shelf"):
			shelf_visit_indices.append(i)
	shelf_visit_indices.shuffle()
	var ram_indices := shelf_visit_indices.slice(0, RAMS_PER_LAP)
	for i in visits.size():
		var v: Dictionary = visits[i]
		if v.has("end"):
			_legs.append({"pos": at.call(v["end"], lane_across), "mode": "drive", "pause": FINALE_END_PAUSE if finale else END_PAUSE})
			continue
		var station: Vector2 = at.call(float(v["x"]), lane_across)
		_legs.append({"pos": station, "mode": "drive"})
		var shelf_body: Node2D = v["shelf"]
		if i in ram_indices:
			var aim: Vector2 = shelf_body.get_node("CollisionShape2D").global_position
			_legs.append({"pos": at.call(float(v["x"]), aim.dot(across_axis)), "mode": "ram", "telegraph": true, "shelf": shelf_body})
		else:
			var slot_across: float = shelf_body.to_global(Vector2(0, -shelf_body.get_node("Shelf").outermost_slot_offset())).dot(across_axis)
			var toward_lane := signf(lane_across - slot_across)
			var stop := slot_across + toward_lane * (PRODUCT_HALF_SIZE + NEAR_MISS_CLEARANCE + FRONT_REACH)
			_legs.append({"pos": at.call(float(v["x"]), stop), "mode": "drive", "pause": FINALE_LOAD_PAUSE if finale else LOAD_PAUSE})
		_legs.append({"pos": station, "mode": "reverse"})

func _process(delta: float) -> void:
	if not Net.is_active() or not active:
		return
	if not is_multiplayer_authority():
		# A reset_for_new_day() teleport would otherwise be lerped across
		# the whole section — a big collidable body sliding through
		# whatever's in the way on this client for a few frames.
		if position.distance_to(target_position) > 150.0:
			position = target_position
			rotation = target_rotation
			reset_physics_interpolation()
		else:
			var t: float = clampf(15.0 * delta, 0.0, 1.0)
			position = position.lerp(target_position, t)
			rotation = wrapf(lerp_angle(rotation, target_rotation, t), -PI, PI)
	_blink_t += delta
	var fast := alert
	var on := fmod(_blink_t, 0.18 if fast else 0.6) < (0.09 if fast else 0.3)
	$Beacon.color = Color(1, 0.15, 0.1, 1) if fast else Color(1, 0.6, 0.1, 1)
	$Beacon.visible = on
	$BeepAnchor/BeepLabel.visible = (reversing or alert) and on
	$BeepAnchor/BeepLabel.text = "!!" if alert else "BEEP"
	$BeepAnchor.rotation = -rotation # label stays upright and above the forklift whichever way it faces
	_update_art()

## Every peer, every frame (see ART_SHEET): side view east/west, front view
## heading south.
func _update_art() -> void:
	var dir := Vector2.RIGHT.rotated(rotation)
	var front := dir.y > 0.7
	if absf(dir.x) > 0.3:
		_facing_east = dir.x > 0.0
	_art.rotation = -rotation
	_art.region_rect = Rect2(ART_FRONT if front else ART_SIDE)
	_art.flip_h = _facing_east and not front
	# Wheels on the collision box's footprint, the rest standing up from it.
	_art.position = Vector2(0, -28).rotated(-rotation)
	# The beacon on the cab roof, BEEP above it.
	$Beacon.position = Vector2(16, 0) + Vector2(0, -62).rotated(-rotation)
	_update_driver(front)

## Every peer, every frame: the driver faces where the truck art faces —
## toward the camera in the front view, else toward the forks (the side
## view's facing, which is also what it keeps while heading north).
func _update_driver(front: bool) -> void:
	if _driver == null:
		return
	if front:
		_driver_row = CharacterSpriteScript.ROW_DOWN
	else:
		_driver_row = CharacterSpriteScript.ROW_RIGHT if _facing_east else CharacterSpriteScript.ROW_LEFT
	var fr := CharacterSpriteScript.FRAME
	_driver.region_rect = Rect2(0, _driver_row * fr, fr, DRIVER_CROP_H)
	var at := DRIVER_FRONT_AT if front else DRIVER_SIDE_AT
	if _facing_east and not front:
		at.x = -at.x
	# Bounce only while the truck visibly moves on THIS peer (its replicated,
	# smoothed position) — same rule as CharacterSprite's walk cycle.
	var delta := get_process_delta_time()
	var p := global_position
	if _driver_last_pos != Vector2.INF and delta > 0.0:
		var inst := p.distance_to(_driver_last_pos) / delta
		if inst > 2000.0: # a day-reset teleport is not driving
			inst = 0.0
		_driver_speed = lerpf(_driver_speed, inst, clampf(delta * 12.0, 0.0, 1.0))
	_driver_last_pos = p
	var bob := 0.0
	if _driver_speed > 20.0:
		_driver_t += delta
		bob = -DRIVER_BOB_PX if fmod(_driver_t * DRIVER_BOB_HZ, 1.0) < 0.5 else 0.0
	# region_rect is centered on the sprite's position; anchor its bottom
	# (the knees) at `at`.
	_driver.position = at + Vector2(0, -DRIVER_CROP_H * 0.5 * _driver.scale.y + bob)
