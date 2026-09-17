extends CharacterBody2D
## A player-controlled body.
##
## Only the peer that OWNS this node (multiplayer authority == this peer's id)
## reads input and actually moves it with move_and_slide(). Every other peer
## just receives this node's target_position over the network (via the
## MultiplayerSynchronizer added below) and smoothly slides its own display
## toward that value each tick, rather than snapping straight to it — see
## the matching comment in Carryable.gd for why the snap-to-latest-value
## approach visibly "shakes" on a normal 60Hz monitor. This is
## "client-authoritative movement": each player's own machine is in charge
## of their own character, which feels responsive for the owner but means
## everyone else only sees that player where the network last said they
## were (smoothed, with a small deliberate delay, instead of snapped).
##
## bot_mode replaces keyboard input with a scripted back-and-forth walk, so
## we can run this whole test with no keyboard or display attached (headless)
## and still get several players continuously contesting objects from
## different directions — that's the actual scenario we're stress-testing.
## bot_angle spreads bots evenly around SPAWN_CENTER (2, 3, or 4 of them),
## and bot_target_name assigns each bot a specific carryable object to
## contest (round-robin across whatever objects exist) — see Main.gd's
## _spawn_player.

const SPEED := 220.0
const PUSH_FORCE := 9000.0 # tuned by testing; impulse-per-second while overlapping
const SMOOTHING_RATE := 15.0 # matches Carryable.gd — see its comment for why this exists
const INTERACT_COOLDOWN := 3.0
const BOT_PICKUP_RANGE := 55.0 # bot-side heuristic; Carryable.gd's PICKUP_RANGE is the real check
const BOT_CARRY_DURATION := 2.5

@export var bot_mode := false
@export var bot_angle := 0.0 # direction (radians) this bot approaches its target object from
@export var bot_target_name := "" # which carryable object (by node name) this bot contests

var _bot_t := 0.0
var _target_obj: Node2D # bot mode: resolved once from bot_target_name
var _last_move_dir := Vector2.RIGHT # for throw direction when standing still
var target_position: Vector2
var _bot_interact_cooldown := 0.0
var _bot_carry_timer := 0.0

func _ready() -> void:
	add_to_group("player") # so Carryable.gd can find whoever is carrying its object
	# Without this, physics interpolation (see project.godot) would try to
	# smoothly slide this node from wherever it defaulted to (0,0) to its
	# actual spawn position, producing a brief visible "zoom in" on spawn.
	reset_physics_interpolation()
	# Runs on every peer now (not just the owner) — the non-owning peers
	# need their own _physics_process tick to run the smoothing below.
	set_physics_process(true)
	target_position = position
	$Polygon2D.color = Color(0.25, 0.55, 1.0) if get_multiplayer_authority() == 1 else Color(1.0, 0.55, 0.15)

	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	config.add_property(NodePath(".:target_position"))
	config.property_set_replication_mode(NodePath(".:target_position"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config
	# Must be an explicit, identical name on every peer. Godot's replication
	# system addresses nodes by path, and an auto-generated name like
	# "@MultiplayerSynchronizer@3" is NOT guaranteed to match across peers —
	# the counter depends on how many anonymous nodes that particular process
	# happened to create first. A mismatch causes "Node not found" errors.
	sync.name = "Sync"
	# Authority must be set BEFORE the node enters the tree, not after in
	# _ready — Godot warned about this directly: setting it post-entry races
	# against replication bookkeeping that already started under the default
	# authority (1), leaving the node "unable to process the pending spawn
	# since it has no network ID".
	sync.set_multiplayer_authority(get_multiplayer_authority())
	add_child(sync)

func _physics_process(delta: float) -> void:
	if not Net.is_active():
		return
	if not is_multiplayer_authority():
		return # smoothing now happens in _process, see below

	var dir := Vector2.ZERO
	var interact_pressed := false
	var throw_pressed := false
	if bot_mode:
		dir = _bot_input(delta)
		_bot_maybe_interact(delta)
	elif multiplayer.is_server():
		# This whole branch only ever runs for the ONE player this process
		# owns (is_multiplayer_authority() above), so "is this process the
		# host" is exactly the same question as "is this the host's own
		# player" — no per-player role tracking needed.
		dir = Input.get_vector("host_move_left", "host_move_right", "host_move_up", "host_move_down")
		interact_pressed = Input.is_action_just_pressed("host_interact")
		throw_pressed = Input.is_action_just_pressed("host_throw")
	else:
		dir = Input.get_vector("client_move_left", "client_move_right", "client_move_up", "client_move_down")
		interact_pressed = Input.is_action_just_pressed("client_interact")
		throw_pressed = Input.is_action_just_pressed("client_throw")
	if dir.length() > 0.1:
		_last_move_dir = dir.normalized()
	if throw_pressed:
		_try_throw()
	elif interact_pressed:
		_try_interact()
	velocity = dir * SPEED
	move_and_slide()
	_push_rigid_bodies(delta)
	target_position = position

## Runs in _process (tied to actual render rate) rather than
## _physics_process (fixed 60Hz) — see the matching comment in Carryable.gd.
func _process(delta: float) -> void:
	if not Net.is_active() or is_multiplayer_authority():
		return
	var t: float = clamp(SMOOTHING_RATE * delta, 0.0, 1.0)
	position = position.lerp(target_position, t)

## move_and_slide() only stops the character at a RigidBody2D — it does not
## push it. We have to detect the contact and apply the force ourselves.
## Looks for a "Carryable" child on whatever we collided with, rather than
## expecting push methods directly on the body — any RigidBody2D with that
## component attached works, generically.
func _push_rigid_bodies(delta: float) -> void:
	for i in get_slide_collision_count():
		var collision := get_slide_collision(i)
		var collider := collision.get_collider()
		if not (collider is RigidBody2D):
			continue
		var carryable: Node = collider.get_node_or_null("Carryable")
		if carryable == null:
			continue
		var impulse: Vector2 = -collision.get_normal() * PUSH_FORCE * delta
		if carryable.is_multiplayer_authority():
			collider.apply_central_impulse(impulse)
		else:
			carryable.rpc_id(carryable.get_multiplayer_authority(), "request_push", impulse)

func _bot_input(delta: float) -> Vector2:
	if _target_obj == null:
		_target_obj = _resolve_bot_target()
		if _target_obj == null:
			return Vector2.ZERO
	var carryable: Node = _target_obj.get_node("Carryable")
	if carryable.carrier_id == multiplayer.get_unique_id():
		# Carrying it: walk it in a simple direction instead of "approach
		# the object," which would be a feedback loop now that the
		# object's own position is pinned to ours.
		_bot_carry_timer += delta
		return Vector2.RIGHT.rotated(bot_angle + PI * 0.5)
	# Walk toward the object's CURRENT position (not a fixed point) from
	# bot_angle, then oscillate in and out of it so every bot keeps
	# contesting its object all test long even as pushing moves it around.
	_bot_t += delta
	var offset := Vector2.RIGHT.rotated(bot_angle) * (50.0 + 35.0 * sin(_bot_t * 1.3))
	var target := _target_obj.global_position + offset
	var to_target := target - global_position
	if to_target.length() < 4.0:
		return Vector2.ZERO
	return to_target.normalized()

func _resolve_bot_target() -> Node2D:
	if bot_target_name == "":
		return null
	for obj in get_tree().get_nodes_in_group("carryable"):
		if obj.name == bot_target_name:
			return obj
	return null

## Scripted stand-in for pressing the interact/throw keys: try a pickup
## once close enough to a free object, hold it briefly, then either drop
## or throw it (picked at random so both code paths get exercised over the
## whole test) — repeated for the whole run.
func _bot_maybe_interact(delta: float) -> void:
	_bot_interact_cooldown -= delta
	if _target_obj == null or _bot_interact_cooldown > 0.0:
		return
	var carryable: Node = _target_obj.get_node("Carryable")
	var my_id := multiplayer.get_unique_id()
	if carryable.carrier_id == my_id:
		if _bot_carry_timer >= BOT_CARRY_DURATION:
			if randf() < 0.5:
				_try_throw()
			else:
				_try_interact()
			_bot_interact_cooldown = INTERACT_COOLDOWN
			_bot_carry_timer = 0.0
	elif carryable.carrier_id == 0 and global_position.distance_to(_target_obj.global_position) < BOT_PICKUP_RANGE:
		_try_interact()
		_bot_interact_cooldown = INTERACT_COOLDOWN

## Drop/pickup toggle. Bots always act on their assigned _target_obj;
## manual play acts on whatever you're already carrying, or else the
## nearest free object in range — since a human player wants to interact
## with whatever's actually nearby, not a scripted assignment.
func _try_interact() -> void:
	var my_id := multiplayer.get_unique_id()
	if bot_mode:
		if _target_obj:
			_interact_with(_target_obj, my_id)
		return
	var carried := _find_carried_object(my_id)
	if carried:
		_interact_with(carried, my_id)
		return
	var nearest := _find_nearest_free_carryable()
	if nearest:
		_interact_with(nearest, my_id)

func _interact_with(obj: Node2D, my_id: int) -> void:
	var c: Node = obj.get_node("Carryable")
	if c.carrier_id == my_id:
		c.try_drop(my_id)
	elif c.carrier_id == 0:
		c.try_pickup(my_id, global_position)

## Throw whatever I'm currently carrying, in the direction I'm currently
## moving (or last moved, if standing still). Same lookup logic as
## _try_interact: bots use their assigned target, manual play uses
## whatever's actually being carried.
func _try_throw() -> void:
	var my_id := multiplayer.get_unique_id()
	var obj := _target_obj if bot_mode else _find_carried_object(my_id)
	if obj == null:
		return
	var c: Node = obj.get_node("Carryable")
	if c.carrier_id == my_id:
		c.try_throw(my_id, _last_move_dir)

func _find_carried_object(my_id: int) -> Node2D:
	for obj in get_tree().get_nodes_in_group("carryable"):
		var c: Node = obj.get_node("Carryable")
		if c.carrier_id == my_id:
			return obj
	return null

func _find_nearest_free_carryable() -> Node2D:
	var best: Node2D = null
	var best_dist := BOT_PICKUP_RANGE * 1.2 # a bit more generous than the bot heuristic
	for obj in get_tree().get_nodes_in_group("carryable"):
		var c: Node = obj.get_node("Carryable")
		if c.carrier_id != 0:
			continue
		var d := global_position.distance_to(obj.global_position)
		if d < best_dist:
			best_dist = d
			best = obj
	return best
