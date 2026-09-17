extends Node
class_name Carryable
## Reusable pickup/carry/throw/push/network-sync component. Attach as a
## child node (named exactly "Carryable") of ANY RigidBody2D to make that
## object work over the network, using the same host-authoritative pattern
## validated across Weeks 1-2: this component's OWN multiplayer authority
## (always the host, peer id 1) is the only one who ever actually changes
## the object's real physics state. Every other peer's request travels
## there over a reliable RPC and gets applied identically everywhere via a
## broadcast.
##
## This exact script, completely unmodified, is used by every carryable
## object in the test project (crate, can, box) — the only differences
## between them are scene-level properties (mass, damping, collision
## shape, visual) set on the RigidBody2D itself. That's the actual proof
## this generalizes: nothing in here is crate-specific, or object-specific
## in any way. A new object type needs zero new code — just add this same
## node as a child.
##
## WHY A CHILD COMPONENT RATHER THAN A BASE CLASS: composition, not
## inheritance. A base class every carryable object's script extends would
## force them all into one shared script hierarchy even though a can and a
## crate have nothing to do with each other except "both happen to be
## carryable." A child node can be bolted onto any RigidBody2D — including
## one that already has its own unrelated script for some other reason —
## without touching its class hierarchy at all.
##
## Responsibilities:
## - Network position/rotation/velocity sync + client-side smoothing
##   (identical mechanism to Week 1-2's Crate.gd, just operating on `body`
##   — the parent this node is attached to — instead of `self`)
## - Push (when a CharacterBody2D walks into this object without picking
##   it up; see the gotcha note near request_push)
## - Pickup / drop / throw: one-shot events, all reliable RPCs, all the
##   same shape (whoever isn't the authority asks the authority; the
##   authority validates and reliably broadcasts the actual decision to
##   everyone, including itself via call_local, so nobody ever has to
##   guess or can end up disagreeing about what happened)

const PICKUP_RANGE := 60.0
const CARRY_OFFSET := Vector2(30.0, 0.0)
const THROW_SPEED := 620.0
const SMOOTHING_RATE := 15.0 # higher = snappier but less smooth; tune by feel

@export var replication_interval := 0.0

var body: RigidBody2D # the object this component is attached to
var target_position: Vector2
var target_rotation: float
## 0 = nobody carrying it, else the peer id of whoever is. Deliberately NOT
## a continuously-replicated property — it only ever changes via the
## reliable broadcast RPCs below, same "one-shot events get reliable RPCs,
## not sync properties" reasoning as request_push.
var carrier_id: int = 0

func _ready() -> void:
	body = get_parent()
	body.add_to_group("carryable") # so Player.gd can find any carryable object generically
	set_multiplayer_authority(1)
	# Found by testing: a thrown object moving at THROW_SPEED (620px/s, ~10px
	# per physics tick) can occasionally tunnel straight through the thin
	# (20px) boundary walls under Godot's default discrete collision
	# detection, then settle to rest far outside the map with nothing left
	# to stop it. Continuous Collision Detection checks the swept path a
	# fast body travels each tick, not just its start/end position, which
	# is exactly the fix for this class of bug.
	body.continuous_cd = RigidBody2D.CCD_MODE_CAST_SHAPE

	# IMPORTANT GOTCHA (carried over from Week 1): a CharacterBody2D's
	# move_and_slide() does NOT automatically push a RigidBody2D it walks
	# into — Godot treats it as an immovable obstacle unless you explicitly
	# apply an impulse (see request_push below and Player.gd's
	# _push_rigid_bodies).
	if not is_multiplayer_authority():
		body.freeze = true
		body.freeze_mode = RigidBody2D.FREEZE_MODE_KINEMATIC

	target_position = body.position
	target_rotation = body.rotation

	# One synchronizer covers both this component's own properties
	# (target_position/target_rotation) and two of the BODY's properties
	# (linear_velocity/angular_velocity, reached via "../" since a property
	# path is relative to the synchronizer's root_path, which defaults to
	# its own parent — this node).
	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	for prop in [".:target_position", ".:target_rotation", "../:linear_velocity", "../:angular_velocity"]:
		var path := NodePath(prop)
		config.add_property(path)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config
	sync.replication_interval = replication_interval
	# Must be an explicit, identical name on every peer — see Player.gd's
	# note on why an auto-generated name breaks replication across peers.
	sync.name = "Sync"
	sync.set_multiplayer_authority(1) # set before entering the tree — see Player.gd
	add_child(sync)

func _physics_process(_delta: float) -> void:
	if not Net.is_active():
		return
	if is_multiplayer_authority():
		if carrier_id != 0:
			var carrier := _find_player(carrier_id)
			if carrier:
				body.position = carrier.global_position + CARRY_OFFSET
				body.rotation = 0.0
		target_position = body.position
		target_rotation = body.rotation
	GameLog.log_object_state(body.name, multiplayer.get_unique_id(), body.position, body.linear_velocity)

func _find_player(peer_id: int) -> Node2D:
	for p in get_tree().get_nodes_in_group("player"):
		if p.get_multiplayer_authority() == peer_id:
			return p
	return null

## Smoothing runs in _process (tied to actual render rate), not
## _physics_process (fixed 60Hz) — otherwise the display only updates 60
## times/sec regardless of monitor refresh rate, which still looks choppy
## on anything faster than 60Hz even with lerp softening each step.
func _process(delta: float) -> void:
	if not Net.is_active() or is_multiplayer_authority():
		return
	# Dead-reckon the target forward using the last known velocity, instead
	# of just chasing the last known position — a push/throw changes
	# velocity instantaneously, so pure position-lerp smoothing visibly
	# lags then "catches up" right at that moment. The network keeps
	# overwriting target_position/target_rotation with the real value each
	# time a fresh update arrives, so small prediction error here doesn't
	# accumulate — it just gets corrected on the next update.
	target_position += body.linear_velocity * delta
	target_rotation += body.angular_velocity * delta
	var t: float = clamp(SMOOTHING_RATE * delta, 0.0, 1.0)
	body.position = body.position.lerp(target_position, t)
	body.rotation = lerp_angle(body.rotation, target_rotation, t)

## A player who collided with this object calls this (locally if they're
## already the authority, over RPC otherwise) to actually move it.
## Deliberately RELIABLE, unlike the continuous position/velocity sync
## above — a dropped position update just gets superseded by the next one
## moments later, no harm done, but a dropped PUSH IMPULSE never gets
## applied at all, with nothing to correct it afterwards.
@rpc("any_peer", "reliable")
func request_push(impulse: Vector2) -> void:
	if not is_multiplayer_authority():
		return
	if carrier_id != 0:
		return # being carried — frozen anyway, but skip the wasted call
	body.apply_central_impulse(impulse)

## --- Pickup / drop / throw ---------------------------------------------

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

func try_throw(requester_id: int, direction: Vector2) -> void:
	if is_multiplayer_authority():
		_validate_throw(requester_id, direction)
	else:
		rpc_id(get_multiplayer_authority(), "_request_throw", requester_id, direction)

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

@rpc("any_peer", "reliable")
func _request_throw(requester_id: int, direction: Vector2) -> void:
	if not is_multiplayer_authority():
		return
	_validate_throw(requester_id, direction)

func _validate_pickup(requester_id: int, requester_pos: Vector2) -> void:
	if carrier_id != 0:
		return # already held — first request wins, rest are silently ignored
	if requester_pos.distance_to(body.position) > PICKUP_RANGE:
		return
	rpc("_rpc_set_carrier", requester_id)

func _validate_drop(requester_id: int) -> void:
	if carrier_id != requester_id:
		return # only the current carrier may drop it
	rpc("_rpc_set_carrier", 0)

func _validate_throw(requester_id: int, direction: Vector2) -> void:
	if carrier_id != requester_id:
		return # only the current carrier may throw it
	rpc("_rpc_throw", direction.normalized())

## Called by Main.gd when ANY peer disconnects. Without this, a carrier who
## disconnects mid-carry leaves the object permanently frozen and stuck —
## nobody left connected has that peer id, so _validate_drop's "only the
## carrier may drop it" check can never pass again. Safe to call on every
## peer: only the authority actually acts, and only if that peer was in
## fact the carrier.
func force_drop_if_carrier(id: int) -> void:
	if is_multiplayer_authority() and carrier_id == id:
		rpc("_rpc_set_carrier", 0)

## Runs on EVERY peer (call_local) — this is the actual state change, sent
## reliably so it can never be silently lost the way an unreliable message
## could be. Freeze toggling happens here too so every peer (including the
## host) stays consistent about whether this body is currently
## authority-driven-but-frozen-while-carried vs. normal free physics.
##
## COLLISION DISABLED WHILE CARRIED: found by testing, not designed in up
## front. The carried object's collision shape gets re-teleported to
## carrier.position + CARRY_OFFSET every tick — but that fixed 30px offset
## isn't guaranteed clearance for every object's collision shape against
## the carrying player's own shape (Box's half-width alone is 18px, plus
## the player's 14px, already exceeds the 30px offset). When they overlap,
## the physics engine tries to resolve the interpenetration every single
## tick, and since script code keeps forcing the overlap right back, that
## resolution can runaway into flinging things hundreds of pixels off the
## map. Making the offset bigger only postpones this for the next, larger
## object; disabling collision entirely while held removes the problem at
## its root — and is correct gameplay behavior anyway, since nobody should
## get stuck on the thing they're personally holding.
@rpc("authority", "call_local", "reliable")
func _rpc_set_carrier(id: int) -> void:
	print("[%s] carrier -> %d (seen by peer %d)" % [body.name, id, multiplayer.get_unique_id()])
	carrier_id = id
	if id != 0:
		body.linear_velocity = Vector2.ZERO
		body.angular_velocity = 0.0
		body.freeze = true
		body.collision_layer = 0
		body.collision_mask = 0
	else:
		body.collision_layer = 1
		body.collision_mask = 1
		if is_multiplayer_authority():
			body.freeze = false

## Same shape as _rpc_set_carrier(0) (releases the object) but also gives
## it velocity in the throw direction, instead of leaving it at rest.
@rpc("authority", "call_local", "reliable")
func _rpc_throw(direction: Vector2) -> void:
	print("[%s] thrown dir=%s (seen by peer %d)" % [body.name, direction, multiplayer.get_unique_id()])
	carrier_id = 0
	body.collision_layer = 1
	body.collision_mask = 1
	if is_multiplayer_authority():
		body.freeze = false
		body.linear_velocity = direction * THROW_SPEED
