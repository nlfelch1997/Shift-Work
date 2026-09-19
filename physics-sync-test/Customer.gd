extends CharacterBody2D
## An NPC customer. Always host-authority (peer 1) — there's no human
## controlling a customer, they're a spawned, continuously-replenished
## population (see Main.gd's restock system), the same shape as Products,
## just ones that move and interact like a player would.
##
## Two roles, picked by Main.gd at spawn time via the shopper/disruptive
## ratio:
## - "shopper" (the ongoing demand loop): seeks a currently-placed (filled-
##   slot) item, picks it up using the existing Carryable pickup system,
##   carries it to the nearest Cashier, and just stands near the checkout
##   point while carrying — Cashier.gd's own per-tick watch (mirroring
##   Shelf.gd's "authority watches, carrier doesn't need to announce
##   anything" pattern) does the actual purchase. Despawns once it's sold
##   its item (or after MAX_LIFETIME, if it never managed to find one —
##   Main.gd's population cap spawns a replacement either way). While
##   nothing's stocked yet, wanders the store (_browse_input) rather than
##   standing frozen in place — added by request after playtesting showed
##   an idle shopper reading as a stuck/broken prop, not a customer.
## - "disruptive": erratic movement that actively retargets toward whatever
##   placed item or player is nearest every RETARGET_INTERVAL, so it reads
##   as "aiming to get in the way" rather than ambient wander. No Carryable
##   interaction at all — its only effect is the same push-on-collision
##   mechanic Player.gd already has (reused verbatim below), same
##   mechanism that already lets a player's own foot traffic knock things
##   over. Deliberately does NOT pick up or steal items — that's the
##   shopper's job; mixing the two would blur "good pressure" and "bad
##   pressure" into one behavior, which is exactly what this session's
##   brief asked to keep distinct.
##
## carry_id: see the long comment on Carryable.gd's _find_carrier() for why
## this exists instead of reusing multiplayer authority.
##
## Week 6: the spacebar defend/shove action (Player.gd's _try_defend(), this
## file's request_shove()) is now live, which is what makes turning
## CUSTOMER_DISRUPTIVE_RATIO back on in Main.gd a fair fight instead of pure
## chaos with no counter-play — a shoved customer (either role) goes into a
## brief knockback/stun and its normal AI picks back up once that ends.

## Slowed 160->120->90 by request, across two rounds of feedback — 120 still
## read as too close to a player's own pace (Player.gd's SPEED is 220).
## Shoppers should read as unhurried browsing, disruptive should read as a
## reactable annoyance, not something that closes distance as fast as a
## player can. Shared by both roles, same as before.
const SPEED := 90.0
const PUSH_FORCE := 9000.0 # matches Player.gd's — identical push mechanic, duplicated rather than shared, consistent with this project's existing per-script style
const PICKUP_RANGE := 55.0
const SMOOTHING_RATE := 15.0
const INTERACT_COOLDOWN := 1.0
const RETARGET_INTERVAL := 1.5 # disruptive: how often to pick a new thing to bump toward — short, so it reads as erratic, not a smooth pursuit
## Shopper: how often an idle shopper (nothing currently stocked to buy)
## picks a new spot to wander toward. By request — a shopper used to just
## stand frozen in place until a slot filled, which read as a static prop
## rather than a customer. Longer than RETARGET_INTERVAL on purpose: this is
## meant to read as unhurried browsing, not the same erratic energy as
## disruptive's retargeting.
const BROWSE_RETARGET_INTERVAL := 2.5
const BROWSE_RADIUS := 200.0 # how far a browse destination can land from the shopper's current spot
const MAX_LIFETIME_SHOPPER := 30.0 # safety valve: if nothing's ever stocked, don't camp forever — leave and let the population cap spawn a replacement
const MAX_LIFETIME_DISRUPTIVE := 45.0
## PLAYTEST ROOT-CAUSE FIX: MAX_LIFETIME_SHOPPER (30s, above) was tuned back
## when checkout was always in the shopper's own section, a few hundred px
## away — it was never meant to also cover the walk to a now-centralized
## checkout, which can be 4000+ px one-way from the farthest section
## (Bakery) at this file's SPEED (90px/s), i.e. 45+ seconds just to get
## there, before even factoring in the walk IN from the entrance or any
## browsing beforehand. A shopper hitting the OLD single lifetime cap
## mid-walk while still holding an item is exactly what read as "customers
## disappear while carrying an item" in playtest — they weren't disappearing,
## they were timing out. Fix: once a shopper is actually carrying something
## (i.e. has committed to a purchase, not just idly searching), its lifetime
## budget resets and switches to this much larger cap instead of continuing
## to count against MAX_LIFETIME_SHOPPER — see _physics_process()'s lifetime
## check and _carry_timer below. Sized generously above the worst-case
## Bakery-to-Entrance round trip (~55-60s of walking alone) rather than
## tightly, since a cutoff that's merely "usually enough" would just
## reintroduce the same bug on an unlucky detour. FLAGGED, not a confirmed
## tuned value — if a centralized checkout this large turns out to make
## far-section purchases rare/slow even with this budget, the fix might
## eventually be a different one (e.g. a second, closer checkout), not a
## bigger number here.
const MAX_CARRY_LIFETIME := 75.0
## Week 6 — the defend/shove counter-play (see Player.gd's _try_defend()).
## Knocks ANY nearby customer away, not just disruptive ones: this component
## stays as ignorant of "which role is being shoved" as it already is of
## which role is doing the shoving, matching this project's existing
## "components don't special-case each other" style (Carryable doesn't know
## about shelves; Shelf doesn't add its own pickup RPC). A shopper caught in
## the blast just gets knocked off its current approach and re-evaluates
## once the stun ends — no extra bookkeeping needed since _shopper_input()
## already re-resolves _committed_item/_committed_cashier from scratch.
const DEFEND_KNOCKBACK_SPEED := 380.0 # placeholder — wants playtesting, same as this file's other tuning constants
const DEFEND_KNOCKBACK_DECEL := 700.0 # px/s^2 — brings knockback to rest a bit before the stun ends, so it doesn't carry all the way to STUN_DURATION at full speed
const DEFEND_STUN_DURATION := 0.6 # seconds normal AI (shopper seeking/disruptive retargeting) is suppressed after being shoved
const CarryableScript := preload("res://Carryable.gd")
const CashierScript := preload("res://Cashier.gd")
## Stop walking toward the cashier once safely inside its own purchase-
## detection radius, not just "close enough to feel arrived" — found by
## testing: using PICKUP_RANGE (55, a different constant, tuned for
## product pickup) here as well let a shopper stop walking at a distance
## OUTSIDE Cashier.gd's own PURCHASE_RANGE (40), so it would carry an item
## right up to the counter and then freeze there forever, never actually
## within range to trigger the purchase, until the lifetime timeout gave
## up on it. Referencing CashierScript.PURCHASE_RANGE directly (with
## margin) instead of a second hardcoded number means the two can't drift
## out of sync like that again.
const CHECKOUT_STOP_RANGE := CashierScript.PURCHASE_RANGE - 15.0

@export var role := "shopper" # "shopper" or "disruptive"
@export var carry_id := 0 # unique negative int, assigned by Main.gd — see Carryable.gd's _find_carrier()
## Multi-item shopping trips (playtest request), shopper-only — set by
## Main.gd at spawn from ITEMS_TARGET_BY_TIER (see that constant's own
## comment for the actual day-tiered numbers and reasoning). How many
## successful purchases this shopper aims to complete before leaving
## voluntarily, tracked by _items_bought below and record_purchase().
@export var items_target := 1

var target_position: Vector2
var facing_angle := 0.0
var _last_move_dir := Vector2.RIGHT
var _interact_cooldown := 0.0
var _lifetime := 0.0
var _stun_timer := 0.0
var _knockback_velocity := Vector2.ZERO

# --- shopper state ---
var _committed_item: Node2D = null
var _committed_cashier: Node = null
var _browse_timer := 0.0
var _browse_pos := Vector2.ZERO
## How many purchases THIS shopper has completed so far this trip —
## incremented by record_purchase() (called by Cashier.gd's
## _complete_purchase() once it knows which customer it just served, via
## the queue system — see Cashier.gd's own comments). Compared against
## items_target in _shopper_input() to decide when to leave satisfied
## instead of searching for yet another item.
var _items_bought := 0
## Counts UP from 0 only while actually carrying an item toward checkout,
## reset to 0 whenever not carrying — see MAX_CARRY_LIFETIME's comment for
## why this needs to be separate from _lifetime (which keeps counting the
## whole time, including idle browsing, and is tuned for that instead).
var _carry_timer := 0.0

# --- disruptive state ---
var _retarget_timer := 0.0
var _retarget_pos := Vector2.ZERO

func _ready() -> void:
	add_to_group("customer")
	reset_physics_interpolation()
	set_physics_process(true)
	target_position = position
	print("[%s] spawned role=%s carry_id=%d pos=%s" % [name, role, carry_id, position])
	# Shopper = calm blue-green ("good pressure"), disruptive = red ("bad
	# pressure") — visually distinct at a glance, same reasoning as
	# Player.gd coloring host vs. client differently.
	$Polygon2D.color = Color(0.4, 0.75, 0.8, 1) if role == "shopper" else Color(0.85, 0.25, 0.25, 1)
	set_multiplayer_authority(1)

	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	for prop in [".:target_position", ".:facing_angle"]:
		var path := NodePath(prop)
		config.add_property(path)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config
	sync.name = "Sync" # explicit, identical name on every peer — see Player.gd's note on why an auto-generated name breaks replication
	sync.set_multiplayer_authority(1)
	add_child(sync)

func _physics_process(delta: float) -> void:
	if not Net.is_active():
		return
	if not is_multiplayer_authority():
		return # smoothing happens in _process, see below

	if _stun_timer > 0.0:
		_stun_timer -= delta
		velocity = _knockback_velocity
		_knockback_velocity = _knockback_velocity.move_toward(Vector2.ZERO, DEFEND_KNOCKBACK_DECEL * delta)
		move_and_slide()
		_push_rigid_bodies(delta)
		target_position = position
		return # normal shopper/disruptive AI suppressed for the whole stun

	_lifetime += delta
	# PLAYTEST ROOT-CAUSE FIX — see MAX_CARRY_LIFETIME's own comment: a
	# shopper actively carrying an item toward checkout is judged against
	# its OWN, much larger budget (_carry_timer/MAX_CARRY_LIFETIME) instead
	# of the browsing-tuned _lifetime/MAX_LIFETIME_SHOPPER — the two are
	# mutually exclusive per tick, never summed, so switching from
	# browsing to carrying doesn't inherit however much of the OLD budget
	# was already spent searching.
	if role == "shopper" and _find_carried_by_me() != null:
		_carry_timer += delta
		if _carry_timer > MAX_CARRY_LIFETIME:
			_leave()
			return
	else:
		_carry_timer = 0.0
		var max_lifetime := MAX_LIFETIME_SHOPPER if role == "shopper" else MAX_LIFETIME_DISRUPTIVE
		if _lifetime > max_lifetime:
			_leave()
			return

	_interact_cooldown -= delta
	var dir := Vector2.ZERO
	if role == "shopper":
		dir = _shopper_input(delta)
		_shopper_maybe_interact()
	else:
		dir = _disruptive_input(delta)

	if dir.length() > 0.1:
		_last_move_dir = dir.normalized()
		facing_angle = _last_move_dir.angle()
		$Polygon2D.rotation = facing_angle
	velocity = dir * SPEED
	move_and_slide()
	_push_rigid_bodies(delta)
	target_position = position

func _process(delta: float) -> void:
	if not Net.is_active() or is_multiplayer_authority():
		return
	var t: float = clamp(SMOOTHING_RATE * delta, 0.0, 1.0)
	position = position.lerp(target_position, t)
	$Polygon2D.rotation = facing_angle

## Called by Cashier.gd's _complete_purchase() once it's finished serving
## THIS customer (identified by carry_id via its queue — see Cashier.gd's
## own comments on the queue rework). Multi-item shopping trips (playtest
## request): a shopper keeps buying — _shopper_input() below re-enters the
## item-search loop once _committed_item/carried both go null again, same
## as it always did — until _items_bought reaches items_target, then
## leaves satisfied instead of looking for another item.
func record_purchase() -> void:
	_items_bought += 1

## If still carrying something (e.g. it timed out before ever reaching a
## cashier), drop it first so it doesn't vanish along with a held item —
## same reasoning as Main.gd's force_drop_if_carrier on disconnect. Shared by
## the lifetime timeout above and Main.gd's force_leave() below (day-start
## population clear), not just the timeout case any more. Also releases
## this customer's spot in its committed cashier's queue, if it had one —
## without this, a shopper that times out (or gets force-despawned at a day
## boundary) mid-queue would leave a permanently unfillable gap, since
## nothing else would ever call leave_queue() for it.
func _leave() -> void:
	print("[%s] leaving (role=%s)" % [name, role])
	if _committed_cashier and is_instance_valid(_committed_cashier):
		_committed_cashier.get_node("Cashier").leave_queue(carry_id)
	var carried := _find_carried_by_me()
	if carried:
		var c: Node = carried.get_node("Carryable")
		c.try_drop(carry_id)
	queue_free()

## Called by Main.gd's _despawn_all_customers() at the start of every day's
## shift (see that function's comment for why this exists — a leftover
## customer from the previous day surviving into the new one was the real
## root cause behind "grace period only works on Day 1" and "customers don't
## spawn from the entrance": both fixes only affect the NEXT customer
## spawned, so an existing one just standing there since before the day
## rolled over made both look broken on Day 2+ even though they were working
## correctly for anything actually newly spawned. Thin public wrapper around
## the existing _leave() cleanup (drop-if-carrying, then queue_free) rather
## than duplicating it — this isn't a lifetime timeout, but the cleanup work
## is identical.
func force_leave() -> void:
	_leave()

## move_and_slide() doesn't push a RigidBody2D it walks into on its own —
## identical mechanic and reasoning to Player.gd's own _push_rigid_bodies,
## duplicated here rather than shared so this script stays a self-contained
## drop-in, matching how Can/Crate/Box each carry their own near-identical
## scene definitions rather than a shared base.
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

## Week 6 defend/shove counter-play. Called by Player.gd's _try_defend()
## either locally (if the calling process IS this customer's authority —
## always host, peer 1) or via rpc_id otherwise — identical call-site shape
## to Carryable.gd's request_push, and reliable for the same reason: a
## dropped shove impulse never gets applied at all, unlike a dropped
## position-sync packet which just gets superseded by the next one.
@rpc("any_peer", "reliable")
func request_shove(from_position: Vector2) -> void:
	if not is_multiplayer_authority():
		return
	var dir := global_position - from_position
	if dir.length() < 0.01:
		dir = Vector2.RIGHT.rotated(randf_range(0.0, TAU)) # shover standing exactly on top of us — pick an arbitrary direction rather than dividing by ~zero
	_knockback_velocity = dir.normalized() * DEFEND_KNOCKBACK_SPEED
	_stun_timer = DEFEND_STUN_DURATION

## --- Shopper -------------------------------------------------------------

func _shopper_input(delta: float) -> Vector2:
	var carried := _find_carried_by_me()
	if carried == null:
		if _committed_item and (not is_instance_valid(_committed_item) or _item_taken_by_someone_else(_committed_item)):
			_committed_item = null
		# FOUND WHILE WIRING multi-item trips: the only way `carried` goes
		# from non-null back to null is a completed purchase (a shove/stun
		# doesn't drop the item — see request_shove()'s own comment; nothing
		# else un-carries it) or this customer's own _leave(), which frees
		# the whole node anyway. So reaching here with a still-set
		# _committed_cashier ALWAYS means "I just finished with that
		# cashier" — clearing it forces the NEXT item (if items_target > 1)
		# to call request_join_queue() again for its own trip, instead of
		# skipping straight to walking to the bare checkout position with
		# no queue entry at all (queue_slot_position() falls back to the
		# checkout marker for an unrecognized carry_id) and then just
		# standing there forever, since Cashier.gd only ever processes
		# whoever is actually at the front of _queue.
		_committed_cashier = null
		if _committed_item == null:
			# Multi-item shopping trips (playtest request): a satisfied
			# shopper (already bought items_target items this trip) leaves
			# on its own instead of looking for one more — see
			# record_purchase()'s own comment for the full loop shape.
			if _items_bought >= items_target:
				_leave()
				return Vector2.ZERO
			_committed_item = _find_stocked_item()
			if _committed_item == null:
				return _browse_input(delta) # nothing stocked to buy right now — browse instead of standing frozen
		var to_item := _committed_item.global_position - global_position
		if to_item.length() < PICKUP_RANGE:
			return Vector2.ZERO
		return to_item.normalized()
	# Carrying: head for a spot in the nearest cashier's queue (NPC
	# cashier + queue line, playtest request) and just wait there —
	# Cashier.gd's own watch completes the purchase once we're at the
	# front, this script doesn't need to "announce" anything (see the file
	# header). request_join_queue() is a plain direct call, not an RPC —
	# Cashier.gd is host-authority and Customer.gd only ever runs this
	# branch on the host too (see the is_multiplayer_authority() guard in
	# _physics_process), so both sides are always the same process.
	if _committed_cashier == null or not is_instance_valid(_committed_cashier):
		_committed_cashier = _find_nearest_cashier()
		if _committed_cashier == null:
			return Vector2.ZERO
		_committed_cashier.get_node("Cashier").request_join_queue(carry_id)
	var cashier: Node = _committed_cashier.get_node("Cashier")
	var target_pos: Vector2 = cashier.queue_slot_position(carry_id)
	var to_target := target_pos - global_position
	if to_target.length() < CHECKOUT_STOP_RANGE:
		return Vector2.ZERO
	return to_target.normalized()

func _shopper_maybe_interact() -> void:
	if _interact_cooldown > 0.0:
		return
	if _find_carried_by_me() != null:
		return
	if _committed_item == null or not is_instance_valid(_committed_item):
		return
	if global_position.distance_to(_committed_item.global_position) >= PICKUP_RANGE:
		return
	var c: Node = _committed_item.get_node("Carryable")
	if c.carrier_id == 0:
		print("[%s] attempting pickup of %s" % [name, _committed_item.name])
		c.try_pickup(carry_id, global_position)
		_interact_cooldown = INTERACT_COOLDOWN

## Nothing's currently stocked to buy — wander instead of standing frozen,
## same "erratic every RETARGET_INTERVAL" shape as disruptive's
## _disruptive_input, just on a slower, calmer cadence (BROWSE_RETARGET_
## INTERVAL) since this should read as idle browsing, not chaos-seeking.
## Checked for a stocked item again every tick regardless (that check lives
## in _shopper_input, above, which calls this only when there isn't one) —
## a shelf filling mid-wander is picked up on the very next physics tick.
func _browse_input(delta: float) -> Vector2:
	_browse_timer -= delta
	if _browse_timer <= 0.0:
		_browse_timer = BROWSE_RETARGET_INTERVAL
		_browse_pos = _pick_browse_target()
	var to_target := _browse_pos - global_position
	if to_target.length() < 8.0:
		return Vector2.ZERO
	return to_target.normalized()

## Biased toward shelves ("browsing" reads as walking up to look at
## shelves, not aimless wandering) with a chance of a plain nearby point so
## it doesn't look like it's beelining to a shelf every single retarget —
## same candidates-plus-random-fallback shape as _pick_disruptive_target()
## below, for the same reason: a shopper here isn't picking a stocked item
## (that's _find_stocked_item's job, checked first in _shopper_input), just
## somewhere plausible to walk toward while waiting for one to appear.
##
## FOUND BY TESTING (well, by the report that customers still weren't
## moving): the first version of this used shelf_body.global_position
## directly as the candidate. That's the ShelfBody's own local origin,
## which sits INSIDE its own CollisionShape2D (the shape is offset (0,-15)
## with half-height 33, so it spans y -48..+18 — right through y=0). A
## StaticBody2D obviously isn't walkable, so a browsing shopper would head
## straight for an unreachable point, get physically stopped at the
## shelf's edge, and just sit there leaning into it every retarget — which
## looks exactly like standing still, not "still moving, just badly aimed."
## nearest_empty_slot_position() is the fix: it's the same guaranteed-
## reachable, open-floor point stocker bots already walk to and
## successfully place items at (see Shelf.gd's header on why slots sit in
## front of the collision box specifically so they CAN be reached), so
## using it here can't reproduce the same class of bug.
func _pick_browse_target() -> Vector2:
	var candidates: Array[Vector2] = []
	for shelf_body in get_tree().get_nodes_in_group("shelf"):
		if not _is_section_unlocked(shelf_body.global_position.x):
			continue
		var shelf: Node = shelf_body.get_node("Shelf")
		var slot_pos = shelf.nearest_empty_slot_position(global_position)
		if slot_pos != null:
			candidates.append(slot_pos)
	if candidates.is_empty() or randf() < 0.3:
		var wander := global_position + Vector2(randf_range(-BROWSE_RADIUS, BROWSE_RADIUS), randf_range(-BROWSE_RADIUS, BROWSE_RADIUS))
		return _keep_outside_break_room(wander)
	return candidates[randi() % candidates.size()]

## PLAYTEST ROOT-CAUSE FIX: shelf/cashier candidates above can never land in
## the break room (neither exists there), but the plain random-offset
## fallback had no such guarantee — a shopper/disruptive customer standing
## near the break room's boundary could roll a wander target that happened
## to fall inside it, for no reason at all (see Main.gd's
## is_break_room_at_x() for the fuller story on why that's actively
## harmful, not just odd-looking). Nudges a candidate that lands inside the
## break room out to whichever edge is closer instead of picking a whole
## new random point — keeps the wander feeling like a small correction, not
## a teleport.
func _keep_outside_break_room(pos: Vector2) -> Vector2:
	var main = get_tree().current_scene
	if not main.is_break_room_at_x(pos.x):
		return pos
	var room_x_start: float = main.BREAK_ROOM_ROOM_INDEX * main.ROOM_WIDTH
	var room_x_end: float = room_x_start + main.ROOM_WIDTH
	var mid := (room_x_start + room_x_end) * 0.5
	pos.x = room_x_start - 20.0 if pos.x < mid else room_x_end + 20.0
	return pos

## Week 6 Part 1 follow-up (playtest feedback): every target search below
## (this one, _find_stocked_item, _find_nearest_cashier,
## _pick_disruptive_target) used to consider EVERY shelf/cashier in the
## game regardless of section-lock state, picking whichever was
## geometrically nearest — a shopper standing near a boundary could end up
## targeting a locked section's cashier, then get stuck trying to reach
## it, which read as "the barrier isn't really blocking anything" even
## when it was. Fixed by having customers skip locked-section shelves/
## cashiers outright: no awareness they exist, not just a physical
## inability to reach them, matching the brief's explicit ask. Not
## preloaded from Main.gd — Main.gd already preloads Customer.tscn to
## spawn customers, so preloading Main.gd back from here would be a
## cyclic preload, a real GDScript failure mode, not just messier style
## (see Player.gd's WORLD_WIDTH/HEIGHT comment for the same reasoning).
## get_tree().current_scene is a live node reference, not a parse-time
## import, so it doesn't have that restriction.
func _is_section_unlocked(world_x: float) -> bool:
	return get_tree().current_scene.is_unlocked_at_x(world_x)

func _find_carried_by_me() -> Node2D:
	for obj in get_tree().get_nodes_in_group("carryable"):
		var c: Node = obj.get_node("Carryable")
		if c.carrier_id == carry_id:
			return obj
	return null

func _item_taken_by_someone_else(item: Node2D) -> bool:
	var c: Node = item.get_node("Carryable")
	return c.carrier_id != 0 and c.carrier_id != carry_id

func _find_stocked_item() -> Node2D:
	var best: Node2D = null
	var best_dist := INF
	for shelf_body in get_tree().get_nodes_in_group("shelf"):
		if not _is_section_unlocked(shelf_body.global_position.x):
			continue
		var shelf: Node = shelf_body.get_node("Shelf")
		var occ: RigidBody2D = shelf.any_filled_object()
		if occ == null:
			continue
		var d := global_position.distance_to(occ.global_position)
		if d < best_dist:
			best_dist = d
			best = occ
	return best

## Central-checkout consolidation: cashiers no longer live inside any of the
## SECTIONS rooms (they're all in one shared CentralCheckout area — see
## Main.tscn), so the section-lock skip every OTHER target search here still
## uses no longer applies to this one — a cashier's reachability is never
## gated by a Gate, only by whether Main.gd's _configure_cashiers() has
## currently activated that particular station (see Cashier.gd's `active`).
func _find_nearest_cashier() -> Node:
	var best: Node = null
	var best_dist := INF
	for cashier_body in get_tree().get_nodes_in_group("cashier"):
		if not cashier_body.get_node("Cashier").active:
			continue
		var d := global_position.distance_to(cashier_body.global_position)
		if d < best_dist:
			best_dist = d
			best = cashier_body
	return best

## --- Disruptive ------------------------------------------------------------

func _disruptive_input(delta: float) -> Vector2:
	_retarget_timer -= delta
	if _retarget_timer <= 0.0:
		_retarget_timer = RETARGET_INTERVAL
		_retarget_pos = _pick_disruptive_target()
	var to_target := _retarget_pos - global_position
	if to_target.length() < 8.0:
		return Vector2.ZERO
	return to_target.normalized()

## Prefers whatever's currently placed on a shelf or wherever a player is —
## "actively contribute to chaos" per the brief, not neutral wandering —
## with a chance of a plain random nearby point so it doesn't read as
## perfectly homing in every single retarget.
func _pick_disruptive_target() -> Vector2:
	var candidates: Array[Vector2] = []
	for shelf_body in get_tree().get_nodes_in_group("shelf"):
		if not _is_section_unlocked(shelf_body.global_position.x):
			continue
		var shelf: Node = shelf_body.get_node("Shelf")
		var occ: RigidBody2D = shelf.any_filled_object()
		if occ:
			candidates.append(occ.global_position)
	for p in get_tree().get_nodes_in_group("player"):
		candidates.append(p.global_position)
	if candidates.is_empty() or randf() < 0.3:
		var wander := global_position + Vector2(randf_range(-150.0, 150.0), randf_range(-150.0, 150.0))
		return _keep_outside_break_room(wander)
	return candidates[randi() % candidates.size()]
