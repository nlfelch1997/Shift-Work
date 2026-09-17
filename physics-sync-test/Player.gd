extends CharacterBody2D
## A player-controlled body.
##
## Only the peer that OWNS this node (multiplayer authority == this peer's id)
## reads input and actually moves it with move_and_slide(). Every other peer
## just receives this node's target_position over the network (via the
## MultiplayerSynchronizer added below) and smoothly slides its own display
## toward that value each tick, rather than snapping straight to it — see
## the matching comment in Crate.gd for why the snap-to-latest-value
## approach visibly "shakes" on a normal 60Hz monitor. This is
## "client-authoritative movement": each player's own machine is in charge
## of their own character, which feels responsive for the owner but means
## everyone else only sees that player where the network last said they
## were (smoothed, with a small deliberate delay, instead of snapped).
##
## bot_mode replaces keyboard input with a scripted back-and-forth walk, so
## we can run this whole test with no keyboard or display attached (headless)
## and still get two players continuously pushing a crate from opposite
## sides — that's the actual scenario we're trying to stress-test.

const SPEED := 220.0
const PUSH_FORCE := 9000.0 # tuned by testing; impulse-per-second while overlapping
const SMOOTHING_RATE := 15.0 # matches Crate.gd — see its comment for why this exists
const INTERACT_COOLDOWN := 3.0
const BOT_PICKUP_RANGE := 55.0 # bot-side heuristic; Crate.gd's PICKUP_RANGE is the real check
const BOT_CARRY_DURATION := 2.5

@export var bot_mode := false
@export var bot_side := -1.0 # -1 = approaches from the left, 1 = from the right

var _bot_t := 0.0
var _crate: Node2D
var target_position: Vector2
var _bot_interact_cooldown := 0.0
var _bot_carry_timer := 0.0

func _ready() -> void:
	add_to_group("player") # so Crate.gd can find whoever is carrying it
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
	else:
		dir = Input.get_vector("client_move_left", "client_move_right", "client_move_up", "client_move_down")
		interact_pressed = Input.is_action_just_pressed("client_interact")
	if interact_pressed:
		_try_interact_with_crate()
	velocity = dir * SPEED
	move_and_slide()
	_push_rigid_bodies(delta)
	target_position = position

## Runs in _process (tied to actual render rate) rather than
## _physics_process (fixed 60Hz) — see the matching comment in Crate.gd.
func _process(delta: float) -> void:
	if not Net.is_active() or is_multiplayer_authority():
		return
	var t: float = clamp(SMOOTHING_RATE * delta, 0.0, 1.0)
	position = position.lerp(target_position, t)

## move_and_slide() only stops the character at a RigidBody2D — it does not
## push it. We have to detect the contact and apply the force ourselves.
func _push_rigid_bodies(delta: float) -> void:
	for i in get_slide_collision_count():
		var collision := get_slide_collision(i)
		var collider := collision.get_collider()
		if collider is RigidBody2D and collider.has_method("request_push"):
			var impulse: Vector2 = -collision.get_normal() * PUSH_FORCE * delta
			if collider.is_multiplayer_authority():
				collider.apply_central_impulse(impulse)
			else:
				collider.rpc_id(collider.get_multiplayer_authority(), "request_push", impulse)

func _bot_input(delta: float) -> Vector2:
	if _crate == null:
		_crate = get_tree().get_first_node_in_group("crate")
		if _crate == null:
			return Vector2.ZERO
	if _crate.carrier_id == multiplayer.get_unique_id():
		# Carrying it: walk it in a simple direction instead of "approach
		# the crate," which would be a feedback loop now that the crate's
		# own position is pinned to ours.
		_bot_carry_timer += delta
		return Vector2(bot_side, 0.3).normalized()
	# Walk toward the crate's CURRENT position (not a fixed point) from
	# bot_side, then oscillate in and out of it so both players keep
	# contesting the crate all test long even as pushing moves it around.
	_bot_t += delta
	var target := _crate.global_position + Vector2(bot_side * (50.0 + 35.0 * sin(_bot_t * 1.3)), 0.0)
	var to_target := target - global_position
	if to_target.length() < 4.0:
		return Vector2.ZERO
	return to_target.normalized()

## Scripted stand-in for pressing the interact key: try a pickup once close
## enough to a free crate, hold it briefly, then drop it — repeatedly, for
## the whole test — so the automated run exercises pickup/drop the same way
## the manual push test exercised pushing.
func _bot_maybe_interact(delta: float) -> void:
	_bot_interact_cooldown -= delta
	if _crate == null or _bot_interact_cooldown > 0.0:
		return
	var my_id := multiplayer.get_unique_id()
	if _crate.carrier_id == my_id:
		if _bot_carry_timer >= BOT_CARRY_DURATION:
			_try_interact_with_crate()
			_bot_interact_cooldown = INTERACT_COOLDOWN
			_bot_carry_timer = 0.0
	elif _crate.carrier_id == 0 and global_position.distance_to(_crate.global_position) < BOT_PICKUP_RANGE:
		_try_interact_with_crate()
		_bot_interact_cooldown = INTERACT_COOLDOWN

func _try_interact_with_crate() -> void:
	if _crate == null:
		_crate = get_tree().get_first_node_in_group("crate")
		if _crate == null:
			return
	var my_id := multiplayer.get_unique_id()
	if _crate.carrier_id == my_id:
		_crate.try_drop(my_id)
	elif _crate.carrier_id == 0:
		_crate.try_pickup(my_id, global_position)
