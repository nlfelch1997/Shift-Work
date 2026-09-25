extends Node
class_name Display
## WEEK 8 — a knock-over-able floor display (sample table, sale bin — see
## Main.tscn's Displays node). Attach as a child node named exactly
## "Display" of a RigidBody2D, same composition shape as Carryable.gd.
##
## WHY NOT JUST REUSE Carryable.gd: anything in the "carryable" group is
## treated as sellable stock everywhere — Main.gd's _restock_products()
## counts it against the product cap, _reset_shelves_and_products_for_new_day()
## queue_free()s EVERY carryable at the start of each day (a static scene
## prop would be deleted on Day 2 and never come back), Shelf.gd would try to
## settle it into slots, and shoppers/bots would pick it up. A display needs
## the same host-authoritative physics sync and the same request_push()
## entry point (so players, disruptive customers and the forklift can all
## knock it around through the exact code path they already use for
## products), but none of the stock semantics — so this is Carryable's
## sync/push half on its own, deliberately duplicated rather than shared,
## matching this project's existing per-script style.
##
## "Knocked over" is real physics (it slides and spins as a RigidBody2D)
## plus a replicated `toppled` flag once it's been hit hard enough, which
## swaps its art to the tipped-over version. Main.gd's _start_shift() puts
## every display back upright at home each day (reset_to_home()).

const SMOOTHING_RATE := 15.0 # matches Carryable.gd
const MAX_SPEED := 900.0 # same defensive clamp as Carryable.gd — see its comment
## Moving faster than this counts as "knocked over". A player walking into
## it (Player.gd's PUSH_FORCE) only nudges it along well under this; a
## forklift hit or a thrown product at full speed tips it. Placeholder.
const TOPPLE_SPEED := 200.0

var body: RigidBody2D
var target_position: Vector2
var target_rotation: float
var toppled := false
var home_position: Vector2
var home_rotation: float

func _ready() -> void:
	body = get_parent()
	body.add_to_group("display")
	set_multiplayer_authority(1)
	body.continuous_cd = RigidBody2D.CCD_MODE_CAST_SHAPE # same tunneling fix as Carryable.gd
	if not is_multiplayer_authority():
		body.freeze = true
		body.freeze_mode = RigidBody2D.FREEZE_MODE_KINEMATIC
	home_position = body.position
	home_rotation = body.rotation
	target_position = body.position
	target_rotation = body.rotation

	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	for prop in [".:target_position", ".:target_rotation", ".:toppled", "../:linear_velocity", "../:angular_velocity"]:
		var path := NodePath(prop)
		config.add_property(path)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config
	sync.name = "Sync" # explicit, identical name on every peer — see Player.gd's note
	sync.set_multiplayer_authority(1)
	add_child(sync)

func _physics_process(_delta: float) -> void:
	if not Net.is_active() or not is_multiplayer_authority():
		return
	var speed := body.linear_velocity.length()
	if speed > MAX_SPEED:
		body.linear_velocity = body.linear_velocity.normalized() * MAX_SPEED
	if speed > TOPPLE_SPEED and not toppled:
		toppled = true
		print("[%s] knocked over (speed %.0f)" % [body.name, speed])
	target_position = body.position
	target_rotation = body.rotation

func _process(delta: float) -> void:
	if not Net.is_active():
		return
	body.get_node("Upright").visible = not toppled
	body.get_node("Toppled").visible = toppled
	if is_multiplayer_authority():
		return
	# Same dead-reckoned smoothing as Carryable.gd, plus a snap for the
	# once-a-day reset_to_home() teleport so it doesn't visibly slide back
	# across the room on clients.
	if body.position.distance_to(target_position) > 150.0:
		body.position = target_position
		body.rotation = target_rotation
		return
	target_position += body.linear_velocity * delta
	target_rotation += body.angular_velocity * delta
	var t: float = clamp(SMOOTHING_RATE * delta, 0.0, 1.0)
	body.position = body.position.lerp(target_position, t)
	body.rotation = lerp_angle(body.rotation, target_rotation, t)

## Identical signature and semantics to Carryable.gd's request_push(), so
## Player.gd/Customer.gd/Forklift.gd can treat a Display and a Carryable
## interchangeably when they bump into one.
@rpc("any_peer", "reliable")
func request_push(impulse: Vector2) -> void:
	if not is_multiplayer_authority():
		return
	body.apply_central_impulse(impulse)

## Host-only. Called by Main.gd's _start_shift() every day, and by its
## _rescue_stranded_products() if a display somehow ends up outside the map.
func reset_to_home() -> void:
	if not is_multiplayer_authority():
		return
	body.linear_velocity = Vector2.ZERO
	body.angular_velocity = 0.0
	body.global_position = home_position
	body.rotation = home_rotation
	target_position = body.position
	target_rotation = body.rotation
	toppled = false
