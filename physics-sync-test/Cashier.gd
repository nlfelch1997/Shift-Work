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

var body: StaticBody2D
var checkout: Marker2D
## Replicated so every peer can show the running total without each of
## them re-deriving it (only the authority actually processes purchases)
## — same authority-computes/everyone-displays split as Shelf's `filled`.
var total_sold: int = 0

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

func _physics_process(_delta: float) -> void:
	if not Net.is_active() or not is_multiplayer_authority():
		return
	for customer in get_tree().get_nodes_in_group("customer"):
		if customer.role != "shopper":
			continue
		if customer.global_position.distance_to(checkout.global_position) > PURCHASE_RANGE:
			continue
		var item := _carried_by(customer.carry_id)
		if item:
			_complete_purchase(item)

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
