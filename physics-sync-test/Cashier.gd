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
## Replicated so every peer can show the running total without each of
## them re-deriving it (only the authority actually processes purchases)
## — same authority-computes/everyone-displays split as Shelf's `filled`.
var total_sold: int = 0
## Authority-only bookkeeping: carry_id -> seconds spent continuously in
## range at THIS cashier so far. Not replicated — only the authority needs
## it, the same "no sync needed" reasoning as Shelf.gd's _occupant array.
## Entries for a customer who leaves range (or despawns) just go stale and
## sit here harmlessly rather than being actively cleaned up — negligible
## at this session's scale, not worth extra bookkeeping to avoid.
var _waiting: Dictionary = {}

func _ready() -> void:
	body = get_parent()
	body.add_to_group("cashier")
	checkout = body.get_node("Checkout")
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
func set_active(v: bool) -> void:
	active = v
	body.visible = v

func _physics_process(delta: float) -> void:
	if not Net.is_active() or not is_multiplayer_authority() or not active:
		return
	for customer in get_tree().get_nodes_in_group("customer"):
		if customer.role != "shopper":
			continue
		var carry_id: int = customer.carry_id
		if customer.global_position.distance_to(checkout.global_position) > PURCHASE_RANGE:
			_waiting.erase(carry_id) # stepped out of range — the wait doesn't carry over if they wander back later
			continue
		var item := _carried_by(carry_id)
		if item == null:
			_waiting.erase(carry_id)
			continue
		var elapsed: float = _waiting.get(carry_id, 0.0) + delta
		if elapsed >= CHECKOUT_WAIT_SECONDS:
			_waiting.erase(carry_id)
			_complete_purchase(item)
		else:
			_waiting[carry_id] = elapsed

func _carried_by(carry_id: int) -> Node2D:
	for obj in get_tree().get_nodes_in_group("carryable"):
		var c: Node = obj.get_node("Carryable")
		if c.carrier_id == carry_id:
			return obj
	return null

func _complete_purchase(item: Node2D) -> void:
	total_sold += 1
	print("[%s] purchase complete: %s (total_sold=%d)" % [body.name, item.name, total_sold])
	item.queue_free()
