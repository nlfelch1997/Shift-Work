extends RigidBody2D
## The shared physics object both players push. This is the actual thing
## Week 1 is testing: can two networked players agree on where this is?
##
## Design: the HOST (always peer id 1 in Godot's multiplayer API) runs the
## real physics simulation for this crate. Every other peer's copy is
## "frozen" (freeze = true) so it does NOT run its own local physics — it
## would immediately disagree with the host if it did. Instead, its
## position/rotation/velocity are overwritten every network sync by a
## MultiplayerSynchronizer, driven by whatever the host is doing. This is
## the standard, textbook-recommended pattern for a networked RigidBody in
## Godot 4.
##
## FREEZE_MODE_KINEMATIC (rather than the default FREEZE_MODE_STATIC) means
## a frozen body can still be moved by setting its position directly (which
## is exactly what the synchronizer does) without the physics engine trying
## to resolve forces on it.
##
## Tune replication_interval to see how sync rate affects smoothness:
## 0.0 = sync as often as possible (every network process step).
##
## IMPORTANT GOTCHA: a CharacterBody2D's move_and_slide() does NOT
## automatically push a RigidBody2D it walks into — Godot treats the
## RigidBody as an immovable obstacle from the character's point of view
## unless you explicitly apply an impulse to it. Player.gd detects the
## collision and calls request_push() below. Since only the host's copy of
## this crate is unfrozen, a client's own push attempt has to travel to the
## host over RPC before it actually moves anything — that round trip is
## itself part of what this test measures.

@export var replication_interval := 0.0

func _ready() -> void:
	add_to_group("crate") # so Player.gd's bots can find and follow it
	set_multiplayer_authority(1)
	gravity_scale = 0.0 # top-down game: nothing to fall "down" toward
	linear_damp = 3.0
	angular_damp = 3.0

	if not is_multiplayer_authority():
		freeze = true
		freeze_mode = RigidBody2D.FREEZE_MODE_KINEMATIC

	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	for prop in [".:position", ".:rotation", ".:linear_velocity", ".:angular_velocity"]:
		var path := NodePath(prop)
		config.add_property(path)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config
	sync.replication_interval = replication_interval
	sync.name = "Sync" # must match across peers — see note in Player.gd
	sync.set_multiplayer_authority(1) # set before entering the tree — see Player.gd
	add_child(sync)

func _physics_process(_delta: float) -> void:
	GameLog.log_crate_state(multiplayer.get_unique_id(), position, linear_velocity)

## A player who collided with this crate calls this (locally if they're
## already the authority, over RPC otherwise) to actually move it. Only the
## authority (host) ever applies the impulse to its real physics body — a
## frozen non-authority copy would silently ignore it anyway.
@rpc("any_peer", "unreliable")
func request_push(impulse: Vector2) -> void:
	if not is_multiplayer_authority():
		return
	apply_central_impulse(impulse)
