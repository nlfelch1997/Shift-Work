extends RigidBody2D
## The shared physics object both players push. This is the actual thing
## Week 1 is testing: can two networked players agree on where this is?
##
## Design: the HOST (always peer id 1 in Godot's multiplayer API) runs the
## real physics simulation for this crate. Every other peer's copy is
## "frozen" (freeze = true) so it does NOT run its own local physics — it
## would immediately disagree with the host if it did.
##
## FREEZE_MODE_KINEMATIC (rather than the default FREEZE_MODE_STATIC) means
## a frozen body can still be moved by setting its position directly without
## the physics engine trying to resolve forces on it.
##
## SMOOTHING: the network only replicates target_position/target_rotation,
## NOT the crate's actual position/rotation directly. On the authority
## (host) those are just mirrors of the real physics transform each tick.
## On every other peer, _physics_process smoothly slides the crate's
## DISPLAYED position/rotation toward whatever the latest target is, instead
## of snapping straight to it. This is "client-side smoothing" — a standard
## netcode technique. It's necessary because Godot's built-in physics
## interpolation (project setting) only smooths physics-tick-vs-render-rate
## mismatches; it does nothing about the underlying replicated value itself
## jumping a few pixels between updates, which is what actually reads as
## "shaking" on a normal 60Hz monitor where there's no extra render frame
## for that engine feature to interpolate across.
##
## Trade-off: the display now trails the true state by a small, deliberate
## delay (a few hundredths of a second) instead of jumping to it instantly.
## That's the standard price of smoothness in networked games.
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
const SMOOTHING_RATE := 15.0 # higher = snappier but less smooth; tune by feel
const PICKUP_RANGE := 60.0
const CARRY_OFFSET := Vector2(30.0, 0.0)

var target_position: Vector2
var target_rotation: float
## 0 = nobody carrying it, else the peer id of whoever is. Deliberately NOT
## a continuously-replicated property — it only ever changes via the
## reliable broadcast RPC below (_rpc_set_carrier), same "one-shot events
## get reliable RPCs, not sync properties" reasoning as request_push.
var carrier_id: int = 0

func _ready() -> void:
	add_to_group("crate") # so Player.gd's bots can find and follow it
	set_multiplayer_authority(1)
	gravity_scale = 0.0 # top-down game: nothing to fall "down" toward
	linear_damp = 3.0
	angular_damp = 3.0

	if not is_multiplayer_authority():
		freeze = true
		freeze_mode = RigidBody2D.FREEZE_MODE_KINEMATIC

	target_position = position
	target_rotation = rotation

	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	for prop in [".:target_position", ".:target_rotation", ".:linear_velocity", ".:angular_velocity"]:
		var path := NodePath(prop)
		config.add_property(path)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config
	sync.replication_interval = replication_interval
	sync.name = "Sync" # must match across peers — see note in Player.gd
	sync.set_multiplayer_authority(1) # set before entering the tree — see Player.gd
	add_child(sync)

func _physics_process(_delta: float) -> void:
	if not Net.is_active():
		return
	if is_multiplayer_authority():
		if carrier_id != 0:
			var carrier := _find_player(carrier_id)
			if carrier:
				position = carrier.global_position + CARRY_OFFSET
				rotation = 0.0
		target_position = position
		target_rotation = rotation
	GameLog.log_crate_state(multiplayer.get_unique_id(), position, linear_velocity)

func _find_player(peer_id: int) -> Node2D:
	for p in get_tree().get_nodes_in_group("player"):
		if p.get_multiplayer_authority() == peer_id:
			return p
	return null

## The smoothing itself runs in _process (tied to actual render rate), not
## _physics_process (fixed 60Hz) — otherwise the display only updates 60
## times/sec regardless of monitor refresh rate, which still looks choppy
## on anything faster than 60Hz even with lerp softening each step.
func _process(delta: float) -> void:
	if not Net.is_active() or is_multiplayer_authority():
		return
	# Dead-reckon the target forward using the last known velocity, instead
	# of just chasing the last known position. A push impulse changes
	# velocity instantaneously, so pure position-lerp smoothing visibly lags
	# then "catches up" right at the moment of impact — extrapolating with
	# velocity reflects the speed change immediately. The network keeps
	# overwriting target_position/target_rotation with the real value each
	# time a fresh update arrives, so small prediction error here doesn't
	# accumulate — it just gets corrected on the next update.
	target_position += linear_velocity * delta
	target_rotation += angular_velocity * delta
	var t: float = clamp(SMOOTHING_RATE * delta, 0.0, 1.0)
	position = position.lerp(target_position, t)
	rotation = lerp_angle(rotation, target_rotation, t)

## A player who collided with this crate calls this (locally if they're
## already the authority, over RPC otherwise) to actually move it. Only the
## authority (host) ever applies the impulse to its real physics body — a
## frozen non-authority copy would silently ignore it anyway.
##
## Deliberately RELIABLE, unlike the continuous position/velocity sync
## above. A dropped position update just gets superseded by the next one a
## moment later — no harm done. A dropped PUSH IMPULSE is different: that
## tick's force never gets applied at all, with nothing to correct it
## afterwards, which would make the client's own pushes land unevenly
## (since only client-initiated pushes have to survive a network hop at
## all — the host's own local pushes never go through this RPC).
@rpc("any_peer", "reliable")
func request_push(impulse: Vector2) -> void:
	if not is_multiplayer_authority():
		return
	if carrier_id != 0:
		return # being carried — frozen anyway, but skip the wasted call
	apply_central_impulse(impulse)

## --- Pickup / carry ---------------------------------------------------
## A second, structurally different one-shot interaction from push, to
## check the "reliable RPC for one-shot events" lesson generalizes rather
## than being a fluke of the push case specifically. Same shape either way:
## whoever isn't the authority asks the authority; the authority validates
## and then reliably broadcasts the actual state change to everyone
## (including itself, via call_local) so every peer applies the exact same
## decision instead of each guessing independently.

func try_pickup(requester_id: int, requester_pos: Vector2) -> void:
	if is_multiplayer_authority():
		_validate_pickup(requester_id, requester_pos)
	else:
		rpc_id(get_multiplayer_authority(), "_request_pickup", requester_id, requester_pos)

func try_drop(requester_id: int) -> void:
	if is_multiplayer_authority():
		_validate_drop(requester_id)
	else:
		rpc_id(get_multiplayer_authority(), "_request_drop", requester_id)

@rpc("any_peer", "reliable")
func _request_pickup(requester_id: int, requester_pos: Vector2) -> void:
	if not is_multiplayer_authority():
		return
	_validate_pickup(requester_id, requester_pos)

@rpc("any_peer", "reliable")
func _request_drop(requester_id: int) -> void:
	if not is_multiplayer_authority():
		return
	_validate_drop(requester_id)

func _validate_pickup(requester_id: int, requester_pos: Vector2) -> void:
	if carrier_id != 0:
		return # already held — first request wins, rest are silently ignored
	if requester_pos.distance_to(position) > PICKUP_RANGE:
		return
	rpc("_rpc_set_carrier", requester_id)

func _validate_drop(requester_id: int) -> void:
	if carrier_id != requester_id:
		return # only the current carrier may drop it
	rpc("_rpc_set_carrier", 0)

## Runs on EVERY peer (call_local) — this is the actual state change, sent
## reliably so it can never be silently lost the way an unreliable message
## could be. Freeze toggling happens here too so every peer (including the
## host) stays consistent about whether this body is currently
## authority-driven-but-frozen-while-carried vs. normal free physics.
@rpc("authority", "call_local", "reliable")
func _rpc_set_carrier(id: int) -> void:
	print("[Crate] carrier -> %d (seen by peer %d)" % [id, multiplayer.get_unique_id()])
	carrier_id = id
	if id != 0:
		freeze = true
		linear_velocity = Vector2.ZERO
		angular_velocity = 0.0
	elif is_multiplayer_authority():
		freeze = false
