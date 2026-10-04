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

## PLAYTEST FIX (Oct 2026 outside playtest: "grabbing product off a crate
## means chasing it around"): 60 -> 70, the radius every other E
## interaction in the store already uses (Main.gd's STORE_SIGN_RANGE /
## TIME_CLOCK_RANGE, BreakRoom.gd's COFFEE_RANGE / VENDING_RANGE, Cleanup.gd's
## BIN_RANGE), and now the ONE number both sides use: Player.gd picks the
## nearest item within it, and the host accepts within it plus
## PICKUP_NET_SLACK. Before, the player picked within 66 but the host
## refused past 60, so a press from 60-66px away (or a client a few px out
## of step with the host's copy) silently did nothing — you had to keep
## shuffling into the item, which nudged it away.
const PICKUP_RANGE := 70.0
## Host-side allowance on top of PICKUP_RANGE for a client's view of an
## item trailing the host's by a few px of smoothing.
const PICKUP_NET_SLACK := 12.0
const CARRY_OFFSET := Vector2(30.0, 0.0)
## Fixed speed regardless of what's thrown (confirmed decision, not a
## placeholder) — a feather and a crate fly identically. Simpler and more
## predictable mid-chaos than mass-scaled impulse would be.
const THROW_SPEED := 620.0
const SMOOTHING_RATE := 15.0 # higher = snappier but less smooth; tune by feel
## Defensive hard cap, well above THROW_SPEED. Found by testing: a moving
## object picked back up mid-flight and re-thrown could occasionally spike
## to several thousand px/s for a few ticks — looks like an interaction
## between Godot's continuous-collision-detection and a body being frozen/
## repositioned by script mid-motion, not something traced to a specific
## line in this file. Rather than chase every possible trigger of that
## interaction, clamp velocity unconditionally every tick so a spike, if
## one occurs, can never actually carry the object off the map.
const MAX_SPEED := 900.0

@export var replication_interval := 0.0
## WEEK 15 — authority only: a carrier just SET THIS DOWN (E / C), at its
## final drop position, before physics has touched it. Not for throws. The
## unpack pads (Delivery.gd) listen so that "set down on the pad"
## counts at once, even if another box set down beside it shoves it a moment
## later. Keeps this component ignorant of what listens, like everything else
## here.
signal dropped
## WEEK 15 — how far in front of its carrier a BIGGER-than-stock object rides
## and is set down. 0 (every product, and the default) = the plain
## CARRY_OFFSET, exactly as before. FOUND BY THE CO-OP DELIVERY TEST: the 30px
## offset only clears the carrier's 28px body for a 28px product; a 44px
## delivery box set down there overlapped its carrier by 6px, and the physics
## engine threw it clear at ~840px/s — across the pad and into the wall. An
## object with carry_distance set is kept that far out along whichever axis
## it's facing most (carry_offset(): the distance grows toward diagonals, so
## two axis-aligned squares never overlap at any facing).
var carry_distance := 0.0

var body: RigidBody2D # the object this component is attached to
var target_position: Vector2
var target_rotation: float
## 0 = nobody carrying it, else the peer id of whoever is. Deliberately NOT
## a continuously-replicated property — it only ever changes via the
## reliable broadcast RPCs below, same "one-shot events get reliable RPCs,
## not sync properties" reasoning as request_push.
var carrier_id: int = 0
## WEEK 21 — the Back Brace upgrade (Endless.gd's carry_capacity()) lets a
## player hold more than one product. carry_seq orders a carrier's stack: set
## from a per-process counter as each pickup RPC lands, and reliable RPCs from
## the host land in the same order on every peer, so "the newest one" (the
## top of the stack, what E/C/F act on) is the same item everywhere.
var carry_seq := 0
static var _seq_counter := 0
## Pixels each item above the bottom of a stack is drawn (screen-up).
const STACK_STEP := 9.0
## Side-to-side spacing of an armful set down at once (a product is 28px).
const ARMFUL_SPREAD := 34.0
var _drop_side := 0 # host, for the one drop being processed (see try_drop())

## PLAYTEST FIX (Oct 2026 outside playtest: "bumping a shelf knocks my stock
## off, stocking turns into cleanup") — SHELVED STOCK. While Shelf.gd counts
## this item as placed in a slot, it moves to its own physics layer that
## players, customers and loose stock don't collide with, so walking past a
## stocked shelf, brushing it with a box, or a thrown can landing on it no
## longer dislodges anything. Pickup is untouched (it's a range check, not a
## collision). The REAL hazards still get through on purpose: the forklifts
## and disruptive customers add LAYER_SHELF_STOCK to their collision masks
## (Forklift.gd / Customer.gd), and a forklift ram's wreck() pushes every
## slot's item directly — any shove that actually moves a shelved item
## un-shelves it at once (_physics_process below), so it flies and lands as
## ordinary stock again. Host decides (Shelf.gd is host-authoritative); the
## layer switch goes to every peer through a reliable call_local RPC, since
## a client's own player collides against that client's copy of the item.
const LAYER_FREE := 1
const LAYER_SHELF_STOCK := 4 # physics layer 3
## Anything moving faster than this while shelved was knocked by a hazard
## (Shelf.gd's own KNOCK_SPEED-scale threshold; a resting item reads ~0).
const SHELVED_KNOCK_SPEED := 60.0
var shelved := false

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
	# Every loose item stops against shelved stock from the start (spawned and
	# unpacked stock too, not just after its first drop) — see _apply_free_layers().
	_apply_free_layers()

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

## Where this object sits relative to its carrier, facing `facing`.
func carry_offset(facing: float) -> Vector2:
	if carry_distance <= 0.0:
		return CARRY_OFFSET.rotated(facing)
	var dir := Vector2.RIGHT.rotated(facing)
	return dir * carry_distance / maxf(absf(dir.x), absf(dir.y))

func _physics_process(_delta: float) -> void:
	if not Net.is_active():
		return
	if is_multiplayer_authority():
		if carrier_id != 0:
			var carrier := _find_carrier(carrier_id)
			if carrier:
				# Rotated by the carrier's own facing so the item stays
				# "in front of you" as you turn, instead of pinned to a
				# fixed world-space offset regardless of which way you're
				# looking. Read dynamically via get() rather than a typed
				# reference — this component stays deliberately ignorant
				# of what kind of node carries it (see the header comment
				# on why Carryable.gd doesn't know shelves exist either);
				# a carrier with no facing_angle just falls back to 0.0.
				var facing: float = carrier.get("facing_angle")
				if facing == null:
					facing = 0.0
				body.position = carrier.global_position + carry_offset(facing) + Vector2(0.0, -STACK_STEP * _stack_index())
				body.rotation = 0.0
			# FREEZE_MODE_KINEMATIC infers a velocity from how far the body's
			# position moved this tick (see the longer note on _rpc_set_carrier)
			# — found by testing this needs suppressing EVERY tick while
			# carried, not just at the pickup/drop transition: a laggy
			# carrier's own reported position isn't perfectly stable tick to
			# tick, and each little correction was enough to let a large
			# inferred velocity build up mid-carry, not just at the moment of
			# picking up or dropping.
			body.linear_velocity = Vector2.ZERO
			body.angular_velocity = 0.0
		elif body.linear_velocity.length() > MAX_SPEED:
			body.linear_velocity = body.linear_velocity.normalized() * MAX_SPEED
		if shelved and carrier_id == 0 and body.linear_velocity.length() > SHELVED_KNOCK_SPEED:
			set_shelved(false) # a hazard knocked it: back to ordinary loose stock this tick
		target_position = body.position
		target_rotation = body.rotation
	GameLog.log_object_state(body.name, multiplayer.get_unique_id(), body.position, body.linear_velocity)

## Renamed from _find_player: as of Week 5B, "who's carrying this" isn't
## always a Player. Customer.gd (shopper NPCs) can carry things too, but
## unlike a Player they don't have a unique real multiplayer authority to
## match on -- every customer is host-authority (peer 1), same as every
## OTHER customer, so matching by get_multiplayer_authority() would be
## ambiguous the moment two customers carry two different items at once.
## Customers instead get a unique synthetic "carry_id" (a negative int,
## assigned by Main.gd at spawn -- negative so it can never collide with a
## real peer id, which ENet always assigns as positive) and are matched by
## that instead. Carryable.gd stays exactly as ignorant of "customer" as it
## already is of "shelf" -- this just widens WHERE it looks, not what it
## assumes about what it finds.
func _find_carrier(id: int) -> Node2D:
	for p in get_tree().get_nodes_in_group("player"):
		if p.get_multiplayer_authority() == id:
			return p
	for c in get_tree().get_nodes_in_group("customer"):
		if c.get("carry_id") == id:
			return c
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
	# WEEK 15 FIX (found by the co-op delivery test, reproduced on the Week 14
	# code too): setting a frozen RigidBody2D's position here never reached
	# the physics server, and every physics tick the server wrote its own
	# stale transform back — so once the host pushed or knocked a loose item,
	# a client's copy crept a few px toward the new spot each frame, snapped
	# back each tick, and settled nowhere near where the host had it (a box
	# still on the pad on the client's screen, 160px away on the host's).
	# Telling the server directly makes the smoothed pose stick.
	PhysicsServer2D.body_set_state(body.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, body.global_transform)

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
	# WEEK 9: a remote PLAYER's push arrives here as an RPC (sender > 0); the
	# forklift/customers call this locally on the host (sender 0) and are
	# never attributed. The host's own player is attributed in Player.gd's
	# _push_rigid_bodies() instead, since it doesn't come through here.
	var sender := multiplayer.get_remote_sender_id()
	# Shelved stock ignores player bumps (see LAYER_SHELF_STOCK). A client
	# that hasn't heard it's shelved yet (a late joiner) can still collide
	# with its own copy and ask — the host says no.
	if shelved and sender > 0:
		return
	if sender > 0:
		_notify_manager("note_push", sender, body)
	if shelved:
		set_shelved(false)
	body.apply_central_impulse(impulse)

## Host-only (Shelf.gd): this item started / stopped counting as placed.
func set_shelved(v: bool) -> void:
	if not is_multiplayer_authority() or shelved == v:
		return
	rpc("_rpc_set_shelved", v)

@rpc("authority", "call_local", "reliable")
func _rpc_set_shelved(v: bool) -> void:
	shelved = v
	if carrier_id == 0:
		_apply_free_layers()
		# Host: shelved stock is also FROZEN (the host's default static freeze,
		# at rest) — loose stock still bumps into it (below) but can't budge
		# it. Clients' copies are always frozen anyway. Every hazard push
		# un-shelves (unfreezes) it first (request_push()).
		if is_multiplayer_authority():
			if v:
				body.linear_velocity = Vector2.ZERO
				body.angular_velocity = 0.0
			body.freeze = v

## The layers of an item nobody is holding: shelved stock on its own layer
## that players and customers don't mask (they walk through it); loose stock
## on the shared layer 1 and ALSO masking the shelved layer, so a loose item
## stops against stocked stock instead of coming to rest inside an occupied
## slot — FOUND BY THE 3-PLAYER net-orders TEST: with no collision at all, a
## dropped or spilled product could sit overlapping a stocked item and then
## drop into the slot the moment a shopper bought it (a free "restock"
## nobody did, which also beat the crew to a priority order).
func _apply_free_layers() -> void:
	body.collision_layer = LAYER_SHELF_STOCK if shelved else LAYER_FREE
	body.collision_mask = 0 if shelved else (LAYER_FREE | LAYER_SHELF_STOCK)

## --- Pickup / drop / throw ---------------------------------------------

func try_pickup(requester_id: int, requester_pos: Vector2) -> void:
	if is_multiplayer_authority():
		_validate_pickup(requester_id, requester_pos)
	else:
		rpc_id(get_multiplayer_authority(), "_request_pickup", requester_id, requester_pos)

## side (WEEK 21): 0 = straight ahead, as always; n > 0 = setting down an
## armful — item n lands n steps to the side (alternating), so the armful
## doesn't land in one overlapping pile the physics engine flings apart.
func try_drop(requester_id: int, side := 0) -> void:
	if is_multiplayer_authority():
		_validate_drop(requester_id, side)
	else:
		rpc_id(get_multiplayer_authority(), "_request_drop", requester_id, side)

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
func _request_drop(requester_id: int, side: int) -> void:
	if not is_multiplayer_authority():
		return
	_validate_drop(requester_id, side)

@rpc("any_peer", "reliable")
func _request_throw(requester_id: int, direction: Vector2) -> void:
	if not is_multiplayer_authority():
		return
	_validate_throw(requester_id, direction)

## WEEK 21 — how many of this item's carrier's other items sit below it.
func _stack_index() -> int:
	var n := 0
	for obj in get_tree().get_nodes_in_group("carryable"):
		var c: Node = obj.get_node("Carryable")
		if c != self and c.carrier_id == carrier_id and c.carry_seq < carry_seq:
			n += 1
	return n

## WEEK 21 — host: may this PLAYER take one more item? Their capacity (1, or
## more with the Back Brace), and a delivery box is always a one-item load —
## no stacking a box, or onto one. Customers (negative ids) always hold one
## at most by their own AI.
func _player_has_room(requester_id: int) -> bool:
	if requester_id <= 0:
		return true
	var held := 0
	var holds_box := false
	for obj in get_tree().get_nodes_in_group("carryable"):
		if obj.get_node("Carryable").carrier_id == requester_id:
			held += 1
			holds_box = holds_box or obj.is_in_group("delivery_box")
	if held == 0:
		return true
	if holds_box or body.is_in_group("delivery_box"):
		return false
	return held < get_tree().current_scene.endless.carry_capacity()

func _validate_pickup(requester_id: int, requester_pos: Vector2) -> void:
	if not _player_has_room(requester_id):
		return
	if carrier_id != 0:
		return # already held — first request wins, rest are silently ignored
	if requester_pos.distance_to(body.position) > PICKUP_RANGE + PICKUP_NET_SLACK:
		return
	_notify_manager("note_work", requester_id)
	rpc("_rpc_set_carrier", requester_id)

func _validate_drop(requester_id: int, side := 0) -> void:
	if carrier_id != requester_id:
		return # only the current carrier may drop it
	_drop_side = side
	_notify_manager("note_work", requester_id)
	rpc("_rpc_set_carrier", 0)

func _validate_throw(requester_id: int, direction: Vector2) -> void:
	if carrier_id != requester_id:
		return # only the current carrier may throw it
	_notify_manager("note_chaos", requester_id, "throwing stock")
	rpc("_rpc_throw", direction.normalized())

## WEEK 9 — tells the manager (Manager.gd, host-only detection) about a
## pickup/drop (legit work) or a throw/push (possible chaos). Always runs on
## the host: every caller above is inside an authority-only path. Customers
## use negative carry ids, which the manager ignores.
func _notify_manager(method: String, peer_id: int, arg: Variant = null) -> void:
	var manager := get_tree().get_first_node_in_group("manager")
	if manager == null:
		return
	if arg == null:
		manager.call(method, peer_id)
	else:
		manager.call(method, peer_id, arg)

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
	var old_carrier_id := carrier_id
	carrier_id = id
	_own_carry_sound("pickup" if id != 0 else "drop", id if id != 0 else old_carrier_id)
	if id != 0 or old_carrier_id != 0:
		_juice("pickup" if id != 0 else "drop")
	if id != 0:
		_seq_counter += 1
		carry_seq = _seq_counter
	if id != 0:
		body.linear_velocity = Vector2.ZERO
		body.angular_velocity = 0.0
		body.freeze = true
		body.collision_layer = 0
		body.collision_mask = 0
	else:
		# Finalize the drop position HERE, at the exact moment of the
		# transition — found by testing: _physics_process's own repositioning
		# (further down) only runs `if carrier_id != 0`, which is now false,
		# so it would otherwise leave the item exactly one physics tick
		# stale — wherever it was computed on the tick BEFORE the drop, not
		# at the drop itself. With a fixed carry offset that was a few
		# invisible pixels; now that the offset rotates with facing (see
		# below), a tick of stale facing can miss by a lot more.
		if is_multiplayer_authority() and old_carrier_id != 0:
			var carrier := _find_carrier(old_carrier_id)
			if carrier:
				var facing: float = carrier.get("facing_angle")
				if facing == null:
					facing = 0.0
				body.position = carrier.global_position + carry_offset(facing)
				if _drop_side > 0:
					body.position += Vector2.DOWN.rotated(facing) * ARMFUL_SPREAD * ceili(_drop_side / 2.0) * (1.0 if _drop_side % 2 == 1 else -1.0)
		_drop_side = 0
		shelved = false # a carried item left its slot; dropping never lands it shelved
		_apply_free_layers()
		if is_multiplayer_authority():
			# FREEZE_MODE_KINEMATIC infers a velocity from how far the body's
			# position moved each tick (that's what lets a frozen "platform"
			# push other bodies it touches) — found by testing: this inferred
			# velocity kept accumulating in linear_velocity every tick while
			# carried (each tick re-teleports the body to the carrier's
			# position), even with collision disabled, so dropping it without
			# resetting velocity first launched it at whatever huge speed the
			# last teleport happened to imply — sometimes far above even
			# THROW_SPEED. A plain drop should leave the object at rest.
			body.linear_velocity = Vector2.ZERO
			body.angular_velocity = 0.0
			body.freeze = false
			if old_carrier_id != 0:
				dropped.emit()

## Same shape as _rpc_set_carrier(0) (releases the object) but also gives
## it velocity in the throw direction, instead of leaving it at rest.
##
## Confirmed decision: a thrown object hitting a player is currently pure
## physics (it just bounces off them like a wall) — no knockback, no
## stagger, no reaction. Deferred on purpose until Week 4+ content exists
## for it to react against, not an oversight.
@rpc("authority", "call_local", "reliable")
func _rpc_throw(direction: Vector2) -> void:
	print("[%s] thrown dir=%s (seen by peer %d)" % [body.name, direction, multiplayer.get_unique_id()])
	var old_carrier_id := carrier_id
	carrier_id = 0
	_own_carry_sound("throw", old_carrier_id)
	if old_carrier_id != 0:
		_juice("throw")
	# Same one-tick-stale-position fix as _rpc_set_carrier(0) — see its
	# comment. Matters less here (a thrown object is about to move anyway),
	# but launching from a stale position is still a real, if smaller, aim
	# error, so fixed the same way for consistency.
	if is_multiplayer_authority() and old_carrier_id != 0:
		var carrier := _find_carrier(old_carrier_id)
		if carrier:
			var facing: float = carrier.get("facing_angle")
			if facing == null:
				facing = 0.0
			body.position = carrier.global_position + carry_offset(facing)
	shelved = false
	_apply_free_layers()
	if is_multiplayer_authority():
		body.freeze = false
		body.linear_velocity = direction * THROW_SPEED

## WEEK 22 — your own pickup / drop / throw sound, on your own machine only
## (Sfx.gd). Hooked here, in the reliable call_local RPCs, rather than on the
## key press: this is where the host has actually accepted it, so a pickup
## someone else won first never plays a sound for the one who lost.
## WEEK 27 — the item pops / squashes / stretches (Juice.gd), every peer:
## same reliable call_local moment as the sound above, so it never fires for
## a pickup the host refused.
func _juice(kind: String) -> void:
	var scene := get_tree().current_scene
	var juice = scene.get("juice") if scene else null
	if juice:
		juice.carry(body, kind)

func _own_carry_sound(sound: String, peer_id: int) -> void:
	if peer_id > 0 and Net.is_active() and peer_id == multiplayer.get_unique_id():
		Sfx.play(sound)
