extends Node
class_name Cashier
## Checkout point for shopper transactions. Mirrors Shelf.gd's shape
## deliberately: the authority watches, every physics tick, for a shopper
## customer carrying something within range of the checkout point, and
## completes the purchase itself. Customer.gd doesn't need to "announce" a
## purchase or know a Cashier exists beyond walking toward one — same
## "the stationary structure watches, the carrier doesn't need to know
## about it" split Shelf.gd already uses for placement.
##
## Freeing a MultiplayerSpawner-spawned node on its authority side is what
## propagates the despawn to every other peer — see Main.gd's own note on
## this (originally written for the disconnect-safety sweep); that's why
## _complete_purchase can just queue_free() the item directly instead of
## needing a dedicated purchase RPC of its own.
##
## QUEUE LINE (playtest request): rebuilt this session from "every shopper
## in PURCHASE_RANGE gets served independently" (fine with 1-2 shoppers,
## but had no concept of order — several could physically overlap right at
## the checkout point) into an explicit queue. A shopper commits to a
## specific cashier once (Customer.gd's _shopper_input(),
## request_join_queue()); only whoever is CURRENTLY CLOSEST among everyone
## queued (_queue_by_distance(), a later playtest fix — NOT stored
## join-order, which turned out to let one delayed customer freeze the
## whole line forever) is ever checked for a purchase, everyone else just
## walks toward their own queue slot (queue_slot_position()), which shifts
## as the effective order changes. Plain direct method calls, not RPCs,
## throughout: both Cashier.gd and Customer.gd are host-authority-only for
## this logic (see each one's own is_multiplayer_authority()/authority
## guard), so there's never a cross-peer call to make here.

const PURCHASE_RANGE := 40.0
## How long a shopper has to stand continuously at checkout, carrying the
## item, before the purchase completes. Not in the code before this
## session — the brief described it as already-confirmed Week 5B behavior,
## but the actual _physics_process below fired the purchase the instant a
## shopper came in range, no wait at all. Added now to match the
## description rather than argued about, since it's small, self-contained,
## and a beat of "checking out" reads better than an instant transaction
## anyway.
const CHECKOUT_WAIT_SECONDS := 3.0

## Central-checkout consolidation: Main.tscn now places up to
## CASHIER_COUNT_BY_TIER.max() stations in one shared CentralCheckout area
## instead of one per section, and Main.gd's _configure_cashiers() enables
## only the first N of them (N scaling with the customer cap — see that
## constant's comment) via set_active() below, toggling both this flag and
## visibility. Not replicated: like Gate.gd's required_day/configure(), every
## peer runs the exact same host-authoritative current_day through the exact
## same _active_cashier_count() formula and gets the identical result
## independently, so there's no live, unpredictable state here that needs a
## broadcast source of truth.
var active := true

var body: StaticBody2D
var checkout: Marker2D
## Populated in _ready() from every Marker2D child named "Queue*"
## (Cashier.tscn declares Queue1/Queue2/Queue3, in that order — sibling
## declaration order is what get_children() returns, same assumption
## Shelf.gd's own `slots` collection already relies on). Slot 0 is closest
## to the register, each further slot a step further back.
var queue_slots: Array[Marker2D] = []
## Everyone currently waiting at this cashier, carry_ids, membership only —
## NOT serving order (see _queue_by_distance()'s own comment for why array
## position stopped meaning "position in line" this session). Authority-
## only, not replicated — same "authority computes, clients just see the
## customer walk toward wherever queue_slot_position() currently says"
## split as everything else host-only in this project.
var _queue: Array[int] = []
## Replicated so every peer can show the running total without each of
## them re-deriving it (only the authority actually processes purchases)
## — same authority-computes/everyone-displays split as Shelf's `filled`.
var total_sold: int = 0
## Authority-only bookkeeping: carry_id -> seconds spent continuously in
## range at THIS cashier so far. Not replicated — only the authority needs
## it, the same "no sync needed" reasoning as Shelf.gd's _occupant array.
## Only ever has an entry for whoever's currently closest (see
## _queue_by_distance()) — the only one ever checked for a purchase — at a
## time; entries for a customer who leaves range or stops being closest
## just go stale and sit here harmlessly, negligible at this session's scale.
var _waiting: Dictionary = {}

func _ready() -> void:
	body = get_parent()
	body.add_to_group("cashier")
	checkout = body.get_node("Checkout")
	for child in body.get_children():
		if child is Marker2D and child.name.begins_with("Queue"):
			queue_slots.append(child)
	set_multiplayer_authority(1)

	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	var path := NodePath(".:total_sold")
	config.add_property(path)
	config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config
	sync.name = "Sync" # explicit, identical name on every peer — see Shelf.gd's matching note
	sync.set_multiplayer_authority(1)
	add_child(sync)

## Called by Main.gd's _configure_cashiers() — see `active`'s own comment.
## Hiding the whole body cascades to its children (Polygon2D, the NPC
## visual — see Cashier.tscn), so an inactive station's cashier NPC and
## queue markers all disappear together with no extra code needed here.
func set_active(v: bool) -> void:
	active = v
	body.visible = v

## Called by Customer.gd's _shopper_input() once, the moment a shopper
## commits to this cashier. Idempotent (a customer already in line calling
## again is a no-op) — cheap safety net, not something expected to happen
## in the normal flow.
func request_join_queue(carry_id: int) -> void:
	if carry_id in _queue:
		return
	_queue.append(carry_id)

## Called by Customer.gd's _leave() on whatever cashier it was queued at,
## covering every exit path (successful purchase — see _complete_purchase()
## below, which calls this too — lifetime timeout, and the day-boundary
## force-despawn) so a customer that's gone never leaves a permanently
## stuck gap in the line.
func leave_queue(carry_id: int) -> void:
	_queue.erase(carry_id)

## Public read of how many customers are currently queued here (membership
## only — see `_queue`'s own comment on why array position isn't serving
## order). Used by Customer.gd's cashier-picking to spread shoppers across
## every active register instead of piling onto whichever is geometrically
## nearest — see that function's own comment for the playtest bug this fixes.
func queue_length() -> int:
	return _queue.size()

## PLAYTEST ROOT-CAUSE FIX: the queue used to be strict join-order — whoever
## called request_join_queue() first stayed "at the front" (_queue[0]) no
## matter what, even if something delayed them physically (a longer detour,
## a shove, a temporary collision snag against a neighboring station — see
## Main.tscn's CentralCheckout layout comment for why that specific
## collision risk existed). Since only _queue[0] was ever checked for a
## purchase, ONE delayed customer froze the ENTIRE line forever, even with
## other queued customers standing right at the register. Recomputing the
## effective order by CURRENT distance every call — both here and in
## queue_slot_position() below — instead of trusting stored join-order
## fixes that at the root: whoever is actually closest is always "at the
## front," both for serving purposes and for where everyone else visibly
## stands in line, so a delayed customer just naturally falls back instead
## of blocking anyone.
func _queue_by_distance() -> Array:
	var ordered := _queue.duplicate()
	ordered.sort_custom(func(a, b):
		var ca := _customer_by_carry_id(a)
		var cb := _customer_by_carry_id(b)
		if ca == null or cb == null:
			return false
		var da: float = ca.global_position.distance_to(checkout.global_position)
		var db: float = cb.global_position.distance_to(checkout.global_position)
		return da < db
	)
	return ordered

## Where carry_id should currently be standing: the checkout counter itself
## if it's currently closest among everyone queued here (see
## _queue_by_distance() above) or not found (not our problem to resolve
## here — Customer.gd only ever calls this after joining), otherwise the
## queue slot matching its current position in that distance ordering.
## Overflow (more customers queued than physical slots) stacks everyone
## past the last slot there rather than inventing more positions — a rare
## edge case at this session's population caps, not worth extra layout
## logic for.
func queue_slot_position(carry_id: int) -> Vector2:
	var ordered := _queue_by_distance()
	var idx := ordered.find(carry_id)
	if idx <= 0:
		return checkout.global_position
	var slot_idx: int = idx - 1
	if slot_idx < queue_slots.size():
		return queue_slots[slot_idx].global_position
	return queue_slots[queue_slots.size() - 1].global_position

func _physics_process(delta: float) -> void:
	if not Net.is_active() or not is_multiplayer_authority() or not active:
		return
	# PLAYTEST BUG FIX ("world keeps simulating during the end-of-day
	# report"): without this, a shopper already standing in PURCHASE_RANGE
	# when the day ended kept accumulating CHECKOUT_WAIT_SECONDS and could
	# complete a purchase while the report screen was up — see Customer.gd's
	# matching freeze for the fuller reasoning.
	if get_tree().current_scene.is_day_report_active():
		return
	# Defensive cleanup: a customer that stopped existing without calling
	# leave_queue() for some reason (there shouldn't be one, but this is a
	# cheap guarantee against a permanently jammed line) is dropped here
	# rather than trusted to have cleaned up after itself.
	_queue = _queue.filter(func(cid): return _customer_by_carry_id(cid) != null)
	if _queue.is_empty():
		return
	# Whoever is CURRENTLY closest is served, not whoever joined first —
	# see _queue_by_distance()'s own comment for why. Removed by VALUE
	# (erase), not pop_front(): the closest customer isn't guaranteed to
	# still be at array index 0 any more.
	var front_id: int = _queue_by_distance()[0]
	var customer := _customer_by_carry_id(front_id)
	if customer.global_position.distance_to(checkout.global_position) > PURCHASE_RANGE:
		return # nobody in line has reached the register yet
	var item := _carried_by(front_id)
	if item == null:
		_queue.erase(front_id)
		return
	var elapsed: float = _waiting.get(front_id, 0.0) + delta
	if elapsed >= CHECKOUT_WAIT_SECONDS:
		_waiting.erase(front_id)
		_complete_purchase(item, front_id)
		_queue.erase(front_id)
	else:
		_waiting[front_id] = elapsed

func _customer_by_carry_id(carry_id: int) -> Node:
	for c in get_tree().get_nodes_in_group("customer"):
		if c.get("carry_id") == carry_id:
			return c
	return null

func _carried_by(carry_id: int) -> Node2D:
	for obj in get_tree().get_nodes_in_group("carryable"):
		var c: Node = obj.get_node("Carryable")
		if c.carrier_id == carry_id:
			return obj
	return null

## carry_id (added this session, for the queue rework) is who was just
## served — the caller (_physics_process above) already removes it from
## _queue right after this returns, so this only needs to tell the
## CUSTOMER a purchase completed, via record_purchase() — multi-item
## shopping trips (playtest request) need that so a shopper knows to look
## for its next item instead of assuming its trip is over.
func _complete_purchase(item: Node2D, carry_id: int) -> void:
	total_sold += 1
	print("[%s] purchase complete: %s (total_sold=%d)" % [body.name, item.name, total_sold])
	# WEEK 11 — before the item is freed: Main.gd reads its priority-order
	# tag (if any) to decide whether this sale earns the order multiplier.
	get_tree().current_scene.note_sale(item)
	item.queue_free()
	var customer := _customer_by_carry_id(carry_id)
	if customer:
		customer.record_purchase()
