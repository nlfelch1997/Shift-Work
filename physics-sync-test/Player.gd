extends CharacterBody2D
## A player-controlled body.
##
## Only the peer that OWNS this node (multiplayer authority == this peer's id)
## reads input and actually moves it with move_and_slide(). Every other peer
## just receives this node's position over the network (via the
## MultiplayerSynchronizer added below) and displays it wherever it's told.
## This is "client-authoritative movement": each player's own machine is in
## charge of their own character, which feels responsive for the owner but
## means everyone else only sees that player where the network last said
## they were.
##
## bot_mode replaces keyboard input with a scripted back-and-forth walk, so
## we can run this whole test with no keyboard or display attached (headless)
## and still get two players continuously pushing a crate from opposite
## sides — that's the actual scenario we're trying to stress-test.

const SPEED := 220.0
const PUSH_FORCE := 9000.0 # tuned by testing; impulse-per-second while overlapping

@export var bot_mode := false
@export var bot_side := -1.0 # -1 = approaches from the left, 1 = from the right

var _bot_t := 0.0
var _crate: Node2D

func _ready() -> void:
	# Only the owning peer simulates this body; everyone else just displays
	# whatever the MultiplayerSynchronizer tells them.
	set_physics_process(is_multiplayer_authority())
	$Polygon2D.color = Color(0.25, 0.55, 1.0) if get_multiplayer_authority() == 1 else Color(1.0, 0.55, 0.15)

	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	config.add_property(NodePath(".:position"))
	config.property_set_replication_mode(NodePath(".:position"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
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
	var dir := Vector2.ZERO
	if bot_mode:
		dir = _bot_input(delta)
	elif multiplayer.is_server():
		# This whole branch only ever runs for the ONE player this process
		# owns (see set_physics_process above), so "is this process the
		# host" is exactly the same question as "is this the host's own
		# player" — no per-player role tracking needed.
		dir = Input.get_vector("host_move_left", "host_move_right", "host_move_up", "host_move_down")
	else:
		dir = Input.get_vector("client_move_left", "client_move_right", "client_move_up", "client_move_down")
	velocity = dir * SPEED
	move_and_slide()
	_push_rigid_bodies(delta)

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
	# Walk toward the crate's CURRENT position (not a fixed point) from
	# bot_side, then oscillate in and out of it so both players keep
	# contesting the crate all test long even as pushing moves it around.
	if _crate == null:
		_crate = get_tree().get_first_node_in_group("crate")
		if _crate == null:
			return Vector2.ZERO
	_bot_t += delta
	var target := _crate.global_position + Vector2(bot_side * (50.0 + 35.0 * sin(_bot_t * 1.3)), 0.0)
	var to_target := target - global_position
	if to_target.length() < 4.0:
		return Vector2.ZERO
	return to_target.normalized()
