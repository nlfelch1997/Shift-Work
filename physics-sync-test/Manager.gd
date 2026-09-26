extends Node2D
## WEEK 9 — the Day 4+ store manager. A host-driven NPC that walks between
## the checkout hub and whichever retail sections are unlocked today, and
## enforces "look busy": a player he can SEE standing around doing nothing,
## or caught mid-chaos (a throw, shoving stock off a shelf, bowling over a
## floor display), gets watched, warned, and — if they don't fix it — written
## up, which docks crew pay on the end-of-day report (Main.gd's
## record_writeup()/WRITEUP_PENALTY).
##
## AUTHORITY: always the host (peer 1), same as Forklift.gd/customers. Only
## the host runs the patrol and the detection; every other peer smooths
## toward the replicated target_position/facing and draws the tell off the
## replicated watch_* values. The write-up itself is recorded by Main.gd
## (host) into replicated counters, so the report reads the same everywhere.
##
## WHY A PLAIN Node2D (NO COLLISION): he only ever walks a fixed set of
## open-floor waypoints (hub center, each section's aisle — see _visit_legs())
## through boundaries that are guaranteed open, because he only visits
## UNLOCKED sections. Giving him a body would only add ways to get stuck —
## wedged against the forklift in Meat/Deli's lane, or body-blocked by a
## customer queue — for no gameplay gain; the forklift already covers
## "something big to route around". Players walk through him, which reads
## fine for a supervisor who's just looking.
##
## DETECTION — what counts as what (host-side, per player, see
## _update_player_state()). Everything here is read off state the host
## already owns; nothing new is trusted from clients:
## - BUSY (never suspicious unless also chaos): carrying something
##   (Carryable.carrier_id — host-authoritative), standing at an active
##   register (within REGISTER_RANGE of an active Cashier), actually moving,
##   or within WORK_GRACE of a pickup/drop/place (so the half-second you
##   stand still after slotting an item onto a shelf isn't "idle").
## - IDLE: stationary (hasn't left a STILL_RADIUS circle) for IDLE_DELAY
##   and not busy.
## - CHAOS: within CHAOS_MEMORY of a validated throw (Carryable.gd's
##   _validate_throw()), or of shoving a shelved item / a floor display
##   (Carryable.gd/Display.gd request_push(), plus the host's own player's
##   direct-impulse branch in Player.gd). Chaos overrides busy — carrying an
##   item right after you've thrown one doesn't launder it. Walking into a
##   loose product on the floor is NOT chaos; that's just walking.
## Shoving customers (Space) is deliberately neutral: it's the existing
## counter-play to disruptive customers, and punishing it would make the
## Week 6 mechanic a trap.
##
## FORKLIFT (WEEK 10 — Day 5 is the first day both hazards are live at once,
## and two interaction bugs turned up the first time they ran together):
## - He has no collision and the forklift can't see him, so his old Meat/Deli
##   lookouts — the section center and a point deeper along the same line,
##   i.e. ON the forklift's lane (and on top of the sample-table display) —
##   had it driving straight through him. Lookouts in a forklift's section
##   now sit LANE_OFFSET off its lane (_plan_visit()), and he yields to it
##   at all times (_avoid_forklift()): waits rather than walk into its
##   footprint, steps aside if it comes at him. He yields, never the
##   forklift — its route is the confirmed-fun part and stays as it was.
## - A forklift hit read as chaos: Player.gd's forklift_hit() fumbles the
##   carried item through the normal try_throw() ("throwing stock"), and the
##   knockback slide pushes whatever it slides into ("knocking over a
##   display"). The forklift now reports each hit (note_forklift_hit()), and
##   for FORKLIFT_EXCUSE after it nothing that player does counts as chaos.
##
## THE TELL (reactable, not a gotcha — same spirit as the forklift's
## beacon + "!!"): the moment someone suspicious is in his sight (range +
## cone + line of sight — shelves block it), he STOPS walking and turns to
## face them, a "?" pops over his head and his vision cone goes yellow; past
## the halfway mark it's a red "!", and the watched player's own screen shows
## a "LOOK BUSY" warning with a meter (Main.gd). The meter needs CATCH_TIME of
## continuous suspicion-in-sight to land. Pick something up, start moving,
## get to a register, or duck behind a shelf, and it drains at DECAY_RATE —
## once it's empty he shrugs and goes back to his rounds. Every number is a
## placeholder, same as this project's other untuned constants.

const WALK_SPEED := 95.0 # slower than a player (220) and the forklift (120): he strolls
const TURN_RATE := 5.0 # rad/s for the cosmetic facing
const ARRIVE_DIST := 6.0
const HUB_PAUSE := 2.5
const LOOKOUT_PAUSE := 2.2 # standing at each spot in a section, looking around
const START_PAUSE := 8.0 # after every day's reset — lets the crew walk out of the break room first
## How far a lookout point sits from a section's center, as a fraction of
## the room size, along the direction he entered from — i.e. "deeper into the
## aisle". 0.2 keeps it well inside every section's interior.
const LOOKOUT_DEPTH := 0.2
## While paused at a lookout he sweeps his gaze this far either side of his
## heading, so standing still doesn't mean a fixed blind side.
const LOOK_SWEEP := 1.1 # radians
const LOOK_SWEEP_RATE := 1.4

const DETECT_RANGE := 280.0
const DETECT_HALF_ANGLE := deg_to_rad(65.0) # 130° cone
## Very close = seen regardless of which way he's facing (he'd hear you).
const DETECT_NEAR_RANGE := 70.0
const CATCH_TIME := 2.5 # seconds of continuous suspicion-in-sight to get written up
const DECAY_RATE := 0.6 # meter units per second while not suspicious / out of sight
const WARN_LEVEL := 0.5 # "?" -> "!" threshold
const CAUGHT_COOLDOWN := 10.0 # per player — no chain write-ups for one mistake
const CAUGHT_PAUSE := 2.0 # he lingers (writing you up) before moving on

const IDLE_DELAY := 1.0
const STILL_RADIUS := 10.0
const WORK_GRACE := 2.0
## Shorter than CATCH_TIME on purpose: ONE throw in full view pushes the
## meter past the "!" (a real warning) but decays before it lands. Keep
## throwing / keep bowling over stock and it lands.
const CHAOS_MEMORY := 1.5
const REGISTER_RANGE := 110.0
## WEEK 10 — forklift coexistence (see the FORKLIFT note in the header).
## After the forklift clips a player, nothing that player "does" for this
## long counts as chaos: covers the 0.6s knockback slide (Player.gd's
## FORKLIFT_STUN_DURATION) plus the fumble throw's round trip from a client.
const FORKLIFT_EXCUSE := 1.5
## Lookouts in a forklift section sit this far off its lane's center line —
## the lane's swept width (its turning circle) is ~56px either side.
const LANE_OFFSET := 100.0
## Gap he keeps between his ~17px body and the forklift's collision box.
const FORKLIFT_CLEARANCE := 34.0
## How far ahead of a MOVING forklift its footprint is projected, so he's
## already out of the way when it arrives instead of being touched first.
const FORKLIFT_LOOKAHEAD := 0.6
const DODGE_SPEED := 150.0 # a quick step back — faster than his stroll
## Waiting on the forklift this long mid-walk gives up on the leg — it never
## blocks his rounds for good.
const YIELD_GIVE_UP := 6.0

## Replicated (see _ready()).
var target_position := Vector2.ZERO
var facing := PI * 0.5
var watch_peer := 0 # who he's currently staring down (0 = nobody)
var watch_level := 0.0 # that player's meter, 0..1
var writing_up := false # true for CAUGHT_PAUSE after a catch — drives the "WRITE-UP!" label
var active := false

var home_position := Vector2.ZERO
var writeups_today := 0 # diagnostic, host-only (the replicated numbers live in Main.gd)

var _legs: Array = []
var _pause_timer := 0.0
var _caught_timer := 0.0
var _sweep_t := 0.0
var _look_heading := 0.0
var _last_section := ""
var _blink_t := 0.0
var _yield_timer := 0.0
## Host-only per-player bookkeeping, keyed by peer id:
## {anchor, still_time, last_work, last_chaos, meter, cooldown, reason}
var _state := {}

func _ready() -> void:
	add_to_group("manager")
	home_position = position
	target_position = position
	reset_physics_interpolation()
	set_multiplayer_authority(1)
	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	for prop in [".:target_position", ".:facing", ".:watch_peer", ".:watch_level", ".:writing_up"]:
		var path := NodePath(prop)
		config.add_property(path)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config
	sync.name = "Sync" # explicit, identical name on every peer — see Player.gd's note
	sync.set_multiplayer_authority(1)
	add_child(sync)
	configure(false)

## Called by Main.gd's _configure_hazards() on EVERY peer whenever
## current_day changes — same shape as Forklift.gd's configure().
func configure(is_active: bool) -> void:
	active = is_active
	visible = is_active
	if not is_active:
		watch_peer = 0
		watch_level = 0.0

## Host-only, from Main.gd's _start_shift() every day.
func reset_for_new_day() -> void:
	if not is_multiplayer_authority():
		return
	position = home_position
	target_position = position
	facing = PI * 0.5
	_look_heading = facing
	_sweep_t = 0.0
	reset_physics_interpolation()
	_legs.clear()
	_pause_timer = START_PAUSE
	_caught_timer = 0.0
	_last_section = ""
	_yield_timer = 0.0
	_state.clear()
	watch_peer = 0
	watch_level = 0.0
	writing_up = false
	writeups_today = 0

## --- Hooks other scripts call on the host ---------------------------------

## A legitimate work action (pickup, drop, place) — Carryable.gd, host-side.
func note_work(peer_id: int) -> void:
	if peer_id > 0:
		_player_state(peer_id)["last_work"] = _now()

## A chaotic action (throw, knocking shelved stock / a display).
func note_chaos(peer_id: int, what: String) -> void:
	if peer_id <= 0 or _excused(peer_id):
		return
	var s := _player_state(peer_id)
	s["last_chaos"] = _now()
	s["chaos_what"] = what

## WEEK 10: the forklift just clipped this player (Forklift.gd, host-side).
## Whatever the hit makes them do next — fumble their item, slide into stock
## or a display — is the forklift's doing, not theirs.
func note_forklift_hit(peer_id: int) -> void:
	if peer_id > 0:
		_player_state(peer_id)["forklift_until"] = _now() + FORKLIFT_EXCUSE

func _excused(peer_id: int) -> bool:
	return _now() < _player_state(peer_id)["forklift_until"]

## A player shoved a RigidBody2D (Player.gd push-on-contact, arriving via
## request_push() for remote players or directly for the host's own). Only
## counts as chaos if the thing was stock sitting on a shelf, or a display.
func note_push(peer_id: int, body: Node) -> void:
	if peer_id <= 0 or body == null or _excused(peer_id):
		return
	if body.is_in_group("display"):
		note_chaos(peer_id, "knocking over a display")
		return
	for shelf_body in get_tree().get_nodes_in_group("shelf"):
		if shelf_body.get_node("Shelf").contains(body):
			note_chaos(peer_id, "knocking stock off a shelf")
			return

## --- Host simulation ------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not Net.is_active() or not is_multiplayer_authority() or not active:
		return
	var main = get_tree().current_scene
	if main.is_day_report_active() or not main.shift_active:
		return
	_update_detection(delta, main)
	writing_up = _caught_timer > 0.0
	var forklift = _live_forklift()
	if forklift and _dodge_forklift(forklift, delta):
		target_position = position
		return
	if watch_peer != 0 or _caught_timer > 0.0:
		_caught_timer = maxf(0.0, _caught_timer - delta)
		var p = main.players.get(watch_peer)
		if p and is_instance_valid(p):
			_turn_toward((p.global_position - global_position).angle(), delta)
	else:
		_walk(delta, main)
	target_position = position

func _walk(delta: float, main) -> void:
	if _pause_timer > 0.0:
		# Standing at a stop: sweep the gaze around the heading he arrived
		# with, so a pause doesn't mean one fixed blind side.
		_pause_timer -= delta
		_sweep_t += delta
		facing = _look_heading + sin(_sweep_t * LOOK_SWEEP_RATE) * LOOK_SWEEP
		return
	if _legs.is_empty():
		_plan_visit(main)
		if _legs.is_empty():
			return
	var leg: Dictionary = _legs[0]
	var to_target: Vector2 = leg["pos"] - global_position
	var dist := to_target.length()
	if dist <= ARRIVE_DIST:
		_legs.pop_front()
		_pause_timer = leg.get("pause", 0.0)
		_sweep_t = 0.0
		_look_heading = facing
		return
	_turn_toward(to_target.angle(), delta)
	var step := to_target / dist * minf(WALK_SPEED * delta, dist)
	var forklift = _live_forklift()
	if forklift and _forklift_gap(forklift, position + step) < FORKLIFT_CLEARANCE \
			and _forklift_gap(forklift, position + step) <= _forklift_gap(forklift, position):
		# Let it pass. Watch it go by rather than stare at the waypoint.
		_yield_timer += delta
		_turn_toward((forklift.global_position - global_position).angle(), delta)
		if _yield_timer >= YIELD_GIVE_UP:
			_yield_timer = 0.0
			_legs.pop_front()
		return
	_yield_timer = 0.0
	position += step

func _turn_toward(angle: float, delta: float) -> void:
	var diff := wrapf(angle - facing, -PI, PI)
	facing = wrapf(facing + clampf(diff, -TURN_RATE * delta, TURN_RATE * delta), -PI, PI)

## One round: from wherever he is, to the hub, then out to a random unlocked
## section (not the one he just did, when there's a choice), through its
## lookout points, and back to the hub. Sections come from Main.gd's live
## _unlocked_sections() — the same SECTIONS table every other gate reads —
## so a section opening on Day 5/7 joins his rounds with no change here.
func _plan_visit(main) -> void:
	var hub: Vector2 = _cell_center(main, main.ENTRANCE_GRID_POS)
	var unlocked: Array = main._unlocked_sections()
	var choices := unlocked.filter(func(s): return s["name"] != _last_section)
	if choices.is_empty():
		choices = unlocked
	if choices.is_empty():
		return
	var section: Dictionary = choices[randi() % choices.size()]
	_last_section = section["name"]
	_legs.append({"pos": hub, "pause": HUB_PAUSE})
	var path := _cell_path(main, section["grid_pos"])
	for cell in path:
		_legs.append({"pos": _cell_center(main, cell)})
	var prev: Vector2i = path[-2] if path.size() > 1 else main.ENTRANCE_GRID_POS
	# Lookouts: the section's center, then deeper along the direction he
	# walked in from. Every section's center is on its own aisle (see
	# Main.gd's layout notes), so both points are open floor.
	var last: Vector2i = path[-1]
	var dir := Vector2(last - prev)
	var center := _cell_center(main, last)
	var depth := LOOKOUT_DEPTH
	# WEEK 10: a section with a forklift has its lane down the middle — the
	# center line these lookouts sit on. Stand beside the lane instead, and
	# not as deep (the deeper point would otherwise sit right in front of a
	# shelf the forklift pulls up to).
	var forklift = _live_forklift()
	if forklift and _cell_of(main, forklift.home_position) == last:
		center.y = forklift.home_position.y + LANE_OFFSET
		depth *= 0.5
		_legs[-1]["pos"] = center
	var deeper := center + dir * Vector2(main.ROOM_WIDTH, main.ROOM_HEIGHT) * depth
	_legs[-1]["pause"] = LOOKOUT_PAUSE
	_legs.append({"pos": deeper, "pause": LOOKOUT_PAUSE})
	_legs.append({"pos": center})
	var back := path.duplicate()
	back.reverse()
	for i in range(1, back.size()):
		_legs.append({"pos": _cell_center(main, back[i])})

## Cells to walk through from the hub to a section, hub excluded. Every
## section that touches the hub is one hop; Bakery hangs off Dry Goods (see
## Main.gd's GRID MAP) so it's reached THROUGH Dry Goods — the only route
## that doesn't cross a WallSeal. Derived by checking which unlocked section
## is adjacent to both, not a hardcoded Bakery special case. The same-row
## requirement is what rules out the sealed boundaries: every WallSeal in
## Main.tscn sits between two vertically stacked cells (Break Room/Dairy,
## Bakery/Meat-Deli, Meat-Deli/Storage), so a same-row hop is always open.
func _cell_path(main, target: Vector2i) -> Array:
	var hub: Vector2i = main.ENTRANCE_GRID_POS
	if _adjacent(hub, target):
		return [target]
	for s in main._unlocked_sections():
		var mid: Vector2i = s["grid_pos"]
		if _adjacent(hub, mid) and _adjacent(mid, target) and mid.y == target.y:
			return [mid, target]
	return [target] # unreachable in the current map; a straight walk is the least-bad fallback

func _cell_of(main, pos: Vector2) -> Vector2i:
	return Vector2i(int(floor(pos.x / main.ROOM_WIDTH)), int(floor(pos.y / main.ROOM_HEIGHT)))

## --- Forklift avoidance (WEEK 10) -------------------------------------------

func _live_forklift() -> CharacterBody2D:
	var f := get_tree().get_first_node_in_group("forklift") as CharacterBody2D
	return f if f and f.active else null

## Distance from a point to the forklift's collision box (Forklift.tscn: 92x44,
## offset +6 along its heading) — and, while it's moving, to where that box
## will be FORKLIFT_LOOKAHEAD from now, whichever is closer.
func _forklift_gap(forklift: CharacterBody2D, pos: Vector2) -> float:
	var gap := _box_gap(forklift.global_position, forklift.rotation, pos)
	if forklift.velocity.length() > 1.0:
		gap = minf(gap, _box_gap(forklift.global_position + forklift.velocity * FORKLIFT_LOOKAHEAD, forklift.rotation, pos))
	return gap

func _box_gap(origin: Vector2, rot: float, pos: Vector2) -> float:
	var local := (pos - origin).rotated(-rot) - Vector2(6, 0)
	return Vector2(maxf(absf(local.x) - 46.0, 0.0), maxf(absf(local.y) - 22.0, 0.0)).length()

## Returns true if he spent this tick stepping out of the forklift's way.
## Moving forklift: step sideways off its line of travel (backing away along
## it would lose — it's faster than him). Stopped or turning in place: step
## straight away from it. Never steps into a wall or shelf.
func _dodge_forklift(forklift: CharacterBody2D, delta: float) -> bool:
	if _forklift_gap(forklift, position) >= FORKLIFT_CLEARANCE:
		return false
	var away := position - forklift.global_position
	if away.length() < 0.01:
		away = Vector2.DOWN
	var dirs: Array[Vector2] = []
	if forklift.velocity.length() > 1.0:
		var side := forklift.velocity.normalized().orthogonal()
		if side.dot(away) < 0.0:
			side = -side
		dirs = [side, (side + away.normalized()).normalized(), -side]
	else:
		dirs = [away.normalized(), away.normalized().orthogonal(), -away.normalized().orthogonal()]
	for d in dirs:
		var next := position + d * DODGE_SPEED * delta
		if not _blocked(next):
			position = next
			_turn_toward((forklift.global_position - position).angle(), delta)
			return true
	return false

func _blocked(pos: Vector2) -> bool:
	var shape := CircleShape2D.new()
	shape.radius = 14.0
	var q := PhysicsShapeQueryParameters2D.new()
	q.shape = shape
	q.transform = Transform2D(0.0, pos)
	for hit in get_world_2d().direct_space_state.intersect_shape(q, 4):
		if hit["collider"] is StaticBody2D:
			return true
	return false

func _adjacent(a: Vector2i, b: Vector2i) -> bool:
	return absi(a.x - b.x) + absi(a.y - b.y) == 1

func _cell_center(main, cell: Vector2i) -> Vector2:
	return Vector2((cell.x + 0.5) * main.ROOM_WIDTH, (cell.y + 0.5) * main.ROOM_HEIGHT)

## --- Detection ------------------------------------------------------------

func _update_detection(delta: float, main) -> void:
	var best_peer := 0
	var best_level := 0.0
	for peer_id in main.players:
		var p = main.players[peer_id]
		if not is_instance_valid(p):
			continue
		var s := _player_state(peer_id)
		s["cooldown"] = maxf(0.0, s["cooldown"] - delta)
		var reason := _suspicion(peer_id, p, s, delta, main)
		var seen: bool = reason != "" and s["cooldown"] <= 0.0 and _can_see(p)
		if seen:
			s["meter"] = minf(1.0, s["meter"] + delta / CATCH_TIME)
			s["reason"] = reason
		else:
			s["meter"] = maxf(0.0, s["meter"] - DECAY_RATE * delta)
		if s["meter"] >= 1.0:
			s["meter"] = 0.0
			s["cooldown"] = CAUGHT_COOLDOWN
			_caught_timer = CAUGHT_PAUSE
			writeups_today += 1
			print("[Manager] CAUGHT player %d (%s) — write-up #%d today" % [peer_id, s["reason"], writeups_today])
			main.record_writeup(peer_id, s["reason"])
			continue
		if s["meter"] > best_level:
			best_level = s["meter"]
			best_peer = peer_id
	if best_peer != watch_peer and best_peer != 0 and watch_peer == 0:
		print("[Manager] watching player %d (%s)" % [best_peer, _state[best_peer]["reason"]])
	elif best_peer == 0 and watch_peer != 0 and _caught_timer <= 0.0:
		print("[Manager] stopped watching player %d" % watch_peer)
	watch_peer = best_peer
	watch_level = best_level

## "" if this player currently looks fine, else a short human-readable reason.
func _suspicion(peer_id: int, p: Node2D, s: Dictionary, delta: float, main) -> String:
	var now := _now()
	if now - s["last_chaos"] < CHAOS_MEMORY:
		return s.get("chaos_what", "causing chaos")
	# Stationary tracking — an anchor circle rather than per-tick velocity,
	# so a remote player's smoothing jitter on the host doesn't read as motion.
	if p.global_position.distance_to(s["anchor"]) > STILL_RADIUS:
		s["anchor"] = p.global_position
		s["still_time"] = 0.0
	else:
		s["still_time"] += delta
	if s["still_time"] < IDLE_DELAY:
		return "" # moving
	if now - s["last_work"] < WORK_GRACE:
		return ""
	if _is_carrying(peer_id):
		return ""
	if _at_register(p, main):
		return ""
	return "standing around"

func _is_carrying(peer_id: int) -> bool:
	for obj in get_tree().get_nodes_in_group("carryable"):
		if obj.get_node("Carryable").carrier_id == peer_id:
			return true
	return false

func _at_register(p: Node2D, main) -> bool:
	for cashier_body in main.cashiers:
		if cashier_body.get_node("Cashier").active and p.global_position.distance_to(cashier_body.global_position) < REGISTER_RANGE:
			return true
	return false

func _can_see(p: Node2D) -> bool:
	var to_p := p.global_position - global_position
	var dist := to_p.length()
	if dist > DETECT_RANGE:
		return false
	if dist > DETECT_NEAR_RANGE and absf(wrapf(to_p.angle() - facing, -PI, PI)) > DETECT_HALF_ANGLE:
		return false
	# Line of sight: only static geometry (shelves, walls, gates) blocks it.
	# The ray stops at the FIRST thing it hits, so moving bodies (products,
	# customers, the forklift, other players) are added to the exclude list
	# and it's re-cast, a bounded number of times.
	var space := get_world_2d().direct_space_state
	var query := PhysicsRayQueryParameters2D.create(global_position, p.global_position)
	var exclude: Array[RID] = [p.get_rid()]
	for i in 8:
		query.exclude = exclude
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			return true
		if hit["collider"] is StaticBody2D:
			return false
		exclude.append(hit["rid"])
	return true

func _player_state(peer_id: int) -> Dictionary:
	if not _state.has(peer_id):
		_state[peer_id] = {"anchor": Vector2.INF, "still_time": 0.0, "last_work": -INF, "last_chaos": -INF, "meter": 0.0, "cooldown": 0.0, "reason": "", "forklift_until": -INF}
	return _state[peer_id]

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

## --- Every peer: smoothing + the tell -------------------------------------

func _process(delta: float) -> void:
	if not Net.is_active() or not active:
		return
	if not is_multiplayer_authority():
		if position.distance_to(target_position) > 150.0:
			position = target_position
			reset_physics_interpolation()
		else:
			position = position.lerp(target_position, clampf(10.0 * delta, 0.0, 1.0))
	$Facing.rotation = facing
	_blink_t += delta
	var cone: Polygon2D = $Facing/Cone
	var alert: Label = $AlertLabel
	if writing_up:
		cone.color = Color(1, 0.2, 0.15, 0.30)
		alert.visible = true
		alert.text = "WRITE-UP!"
		alert.add_theme_color_override("font_color", Color(1, 0.25, 0.15))
	elif watch_peer != 0 and watch_level > 0.0:
		var hot := watch_level >= WARN_LEVEL
		cone.color = Color(1, 0.2, 0.15, 0.30) if hot else Color(1, 0.85, 0.2, 0.24)
		alert.visible = not hot or fmod(_blink_t, 0.3) < 0.2
		alert.text = "!" if hot else "?"
		alert.add_theme_color_override("font_color", Color(1, 0.25, 0.15) if hot else Color(1, 0.85, 0.2))
	else:
		cone.color = Color(1, 1, 1, 0.10)
		alert.visible = false
