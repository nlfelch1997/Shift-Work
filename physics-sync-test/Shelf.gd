extends Node
class_name Shelf
## Reusable shelf/stocking-surface component. Attach as a child node (named
## exactly "Shelf") of any StaticBody2D that has one or more Marker2D
## children — each Marker2D is a "slot" an item can be stocked into. Mirrors
## Carryable.gd's shape: host-authoritative, generic, works on any shelf
## layout with zero shelf-specific code elsewhere.
##
## DELIBERATE DESIGN CHOICE: this component does NOT add any pickup/place
## RPC of its own, and Carryable.gd has zero knowledge shelves exist. An
## item gets "placed" simply by being carried near a slot and dropped with
## the existing try_drop() — this component just watches, every physics
## tick, whether a free (uncarried) carryable object is resting close
## enough to a slot marker to count. That reuses the entire pickup/carry/
## throw system unmodified and, as a side effect, makes knockdown nearly
## free: a placed item is ordinary un-frozen physics (nothing pins it down),
## so any real collision — a pushed crate, a thrown object, a player body —
## moves it exactly like any other RigidBody2D, and this component just
## notices next tick that it's no longer resting in its slot.
##
## FLAG FOR DESIGN INPUT: "placed" currently means "carried an item within
## CAPTURE_RADIUS of a slot marker and it came to rest there" — no separate
## aim-assist/snap, no dedicated "place" button distinct from drop. That's a
## placeholder; if free-hand placement proves too fiddly in practice, the
## fix is either a bigger CAPTURE_RADIUS or an actual snap-to-slot assist.
## KNOCK_SPEED (how hard a hit has to be to dislodge a placed item) and
## SETTLE_TIME (how long it must rest before it counts) are placeholder
## numbers too — real values want playtesting, not a guess made in code.
##
## VISUAL NOTE (in code, not the .tscn — Godot's scene-file format doesn't
## reliably support inline comments; one placed directly above a property
## line there once silently dropped that property's value entirely instead
## of erroring, which is exactly the kind of thing to catch by checking the
## actual loaded value, not just "did it fail to load"): each shelf's drawn
## Polygon2D is deeper than its CollisionShape2D on purpose. Slots sit in
## FRONT of the collision box (see slots' local y vs. the collision shape's
## half-height), so a player/bot can physically reach them instead of the
## shelf's own solid body blocking that space — the drawing just extends to
## match, so placed items look like they're sitting on the shelf instead of
## floating in the open floor in front of it.

const CAPTURE_RADIUS := 26.0 # how close to a slot marker counts as "placed" — placeholder
const LEAVE_RADIUS := CAPTURE_RADIUS * 1.5 # hysteresis band so a placed item doesn't flicker right at the boundary
const REST_SPEED := 40.0 # must be moving slower than this to start settling into an empty slot
const KNOCK_SPEED := 120.0 # moving faster than this while placed immediately un-places it — placeholder
const SETTLE_TIME := 0.35 # seconds of continuous rest before a candidate actually counts as placed

## Color-coordination follow-up (playtest feedback): each section's slot
## Indicator outlines get recolored to match that section's product
## accent color, via apply_accent_color() below, so a product's own color
## and the outline of the shelf it belongs on visually pair up at a
## glance — the request was explicitly framed as "similar to how the
## shelf slot markers already make placement targets clear," so extending
## the EXISTING indicator rather than adding new markers. Defaults to the
## original always-yellow indicator color, so a shelf nobody bothers to
## configure looks exactly like it always did — no visual regression risk
## from a missed wiring step.
@export var accent_color := Color(1, 0.9, 0.3, 1)

## WEEK 8 — forklift wreck (see Forklift.gd and wreck() below). A wrecked
## shelf spills everything stocked on it and can't hold stock again until
## WRECK_DURATION has passed. Placeholders, same as the rest of this block.
##
## FLAGGED DESIGN LIMIT: the shelf BODY itself doesn't physically move —
## it's a StaticBody2D, and every other system that touches shelves
## (slot positions, Main.gd's grid-cell section matching and lock-dimming,
## customer shelf-front approach geometry, the product spawn band's
## clearance math) assumes it never does. Making shelves RigidBody2Ds that
## could be shoved out of alignment would ripple through all of that, so
## the physical chaos lives in what the shelf was HOLDING (flung as real
## RigidBody2D impulses) and nearby displays, while the shelf itself gets
## a replicated wrecked state: tilted/darkened art, no stock accepted.
const WRECK_DURATION := 7.0
const WRECK_SPILL_RADIUS := 130.0 # from the shelf origin — slots sit ~70-92px out, so this catches every slot plus loose items right in front
const WRECK_SPILL_SPEED := 460.0 # impulse = speed * mass, same convention as Forklift.gd's knocks
const WRECK_TILT := 0.14 # radians, cosmetic

var body: StaticBody2D # the shelf this component is attached to
var slots: Array[Marker2D] = []
## Replicated so every peer can render "how full" this shelf is without
## each of them re-deriving it from raw physics state (which only the
## authority actually evaluates) — same "authority computes, clients just
## display" split as Carryable's target_position/target_rotation.
var filled: Array = []
var _settle_timers: Array = []
## Authority-only bookkeeping: which object (if any) currently occupies
## each slot. Not replicated — only the authority needs it, to know which
## body to keep checking and to stop two slots claiming the same object.
var _occupant: Array = []
## Replicated (added to the same Sync as `filled`) so every peer draws the
## wrecked art; the countdown itself is authority-only.
var wrecked := false
var _wreck_timer := 0.0
var _polygon_rotation := 0.0
var _polygon_color := Color.WHITE
var _wreck_label: Label

func _ready() -> void:
	body = get_parent()
	body.add_to_group("shelf")
	for child in body.get_children():
		if child is Marker2D:
			slots.append(child)
	filled.resize(slots.size())
	filled.fill(false)
	_settle_timers.resize(slots.size())
	_settle_timers.fill(0.0)
	_occupant.resize(slots.size())
	set_multiplayer_authority(1)

	var polygon: Polygon2D = body.get_node("Polygon2D")
	_polygon_rotation = polygon.rotation
	_polygon_color = polygon.color
	# Built in code rather than Shelf.tscn — see this file's VISUAL NOTE on
	# why nothing new goes into a .tscn that doesn't have to.
	_wreck_label = Label.new()
	_wreck_label.name = "WreckLabel"
	_wreck_label.text = "WRECKED"
	_wreck_label.add_theme_font_size_override("font_size", 18)
	_wreck_label.add_theme_color_override("font_color", Color(1, 0.35, 0.2, 1))
	_wreck_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_wreck_label.position = Vector2(-45, -14)
	_wreck_label.size = Vector2(90, 28)
	_wreck_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wreck_label.visible = false
	var anchor := Node2D.new()
	anchor.name = "WreckLabelAnchor"
	anchor.add_child(_wreck_label)
	body.add_child.call_deferred(anchor)

	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	for prop in [".:filled", ".:wrecked"]:
		var path := NodePath(prop)
		config.add_property(path)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config
	# Must be an explicit, identical name on every peer — see Carryable.gd's
	# matching note on why an auto-generated name breaks replication.
	sync.name = "Sync"
	sync.set_multiplayer_authority(1)
	add_child(sync)

func _physics_process(delta: float) -> void:
	if not Net.is_active() or not is_multiplayer_authority():
		return
	# PLAYTEST BUG FIX ("world keeps simulating during the end-of-day
	# report"): without this, an item mid-SETTLE_TIME when the day ended
	# could finish settling into a slot while the report screen was up —
	# see Customer.gd's matching freeze for the fuller reasoning.
	if get_tree().current_scene.is_day_report_active():
		return
	if wrecked:
		# Nothing settles into a wrecked shelf — reset() already cleared
		# every slot at wreck time, so there's nothing occupied to recheck.
		_wreck_timer -= delta
		if _wreck_timer <= 0.0:
			wrecked = false
		return
	for i in slots.size():
		if _occupant[i] != null:
			_recheck_occupied(i)
		else:
			_settle_check_empty(i, delta)

## Runs on EVERY peer (no authority check) — purely visual, driven off the
## already-replicated `filled` array, same split as the rest of this file:
## authority computes, everyone just displays. Each slot's "Indicator" child
## (see Shelf.tscn) is the empty-slot outline box; visible exactly when
## that slot isn't filled, regardless of whether anyone's currently near it
## or carrying anything — a permanent "stock goes here" reference, not a
## contextual prompt (that's the separate "Prompt" child, driven per-peer
## from Player.gd instead, since it depends on which player is carrying
## what, not on shared shelf state).
func _process(_delta: float) -> void:
	if not Net.is_active():
		return
	for i in slots.size():
		slots[i].get_node("Indicator").visible = not filled[i] and not wrecked
	var polygon: Polygon2D = body.get_node("Polygon2D")
	polygon.rotation = _polygon_rotation + (WRECK_TILT if wrecked else 0.0)
	polygon.color = _polygon_color * Color(0.55, 0.5, 0.5, 1) if wrecked else _polygon_color
	_wreck_label.visible = wrecked
	# Upright regardless of the shelf's own rotation (the Indicator/Prompt
	# art doesn't do this — see Main.gd's KNOWN COSMETIC QUIRK note — but a
	# warning that's upside-down on half the shelves is worth one line).
	_wreck_label.get_parent().rotation = -body.global_rotation

## An occupied slot's item is un-placed the instant it's picked back up,
## drifts out past LEAVE_RADIUS, or gets knocked hard enough — no grace
## period on the way OUT (only settling IN is debounced), so a knockdown
## reads as instant and decisive, not laggy.
func _recheck_occupied(i: int) -> void:
	var obj: RigidBody2D = _occupant[i]
	var carryable: Node = obj.get_node("Carryable")
	var knocked: bool = carryable.carrier_id != 0 \
		or obj.global_position.distance_to(slots[i].global_position) > LEAVE_RADIUS \
		or obj.linear_velocity.length() > KNOCK_SPEED
	if knocked:
		_occupant[i] = null
		filled[i] = false
		_settle_timers[i] = 0.0

func _settle_check_empty(i: int, delta: float) -> void:
	var candidate := _find_settling_candidate(i)
	if candidate == null:
		_settle_timers[i] = 0.0
		return
	_settle_timers[i] += delta
	if _settle_timers[i] >= SETTLE_TIME:
		_occupant[i] = candidate
		filled[i] = true

func _find_settling_candidate(slot_index: int) -> RigidBody2D:
	for obj in get_tree().get_nodes_in_group("carryable"):
		if obj in _occupant:
			continue # already claimed by another slot (this shelf or another)
		var carryable: Node = obj.get_node("Carryable")
		if carryable.carrier_id != 0:
			continue
		if obj.global_position.distance_to(slots[slot_index].global_position) > CAPTURE_RADIUS:
			continue
		if obj.linear_velocity.length() > REST_SPEED:
			continue
		if not _color_matches(obj):
			continue
		return obj
	return null

## Slot color-matching (playtest request): an item only counts as placed if
## its own color matches this shelf's accent_color — a Dry Goods product can
## no longer settle into a Meat/Deli shelf's slot just because it physically
## fits within CAPTURE_RADIUS. No rejection animation/sound yet, per the
## request — a non-matching item just never settles; it sits there as an
## ordinary free object, same as standing anywhere else on the open floor,
## and _find_settling_candidate() above keeps re-checking it every tick like
## any other nearby candidate in case it's later replaced by a matching one.
## Reads color generically off the object's "Polygon2D" child — the same
## node Main.gd's _spawn_product_node already colors at spawn time — rather
## than adding a dedicated color property to Carryable.gd, matching this
## component's existing "stay ignorant of what kind of object this is"
## style (see the file header). An object with no Polygon2D (only the
## unused Week 1-3 Can/Box/Crate test props, never spawned by default) has
## no color to check against, so it's let through rather than silently made
## unplaceable on every shelf everywhere.
func _color_matches(obj: Node) -> bool:
	var visual := obj.get_node_or_null("Polygon2D")
	if visual == null:
		return true
	return visual.color.is_equal_approx(accent_color)

## Called explicitly by Main.gd right after it sets accent_color (this
## component's own _ready() already ran by then, driven by Godot's
## children-before-parent order, so it can't pick up a later override on
## its own) — same "export var + explicit apply call, run by Main.gd after
## setting it" shape as Gate.gd's configure().
func apply_accent_color() -> void:
	for slot in slots:
		slot.get_node("Indicator").default_color = accent_color

## Called by Main.gd at the start of every new day
## (_reset_shelves_and_products_for_new_day()) — playtest root-cause fix for
## "Day 2 starts fully stocked, nothing to do": nothing previously reset a
## shelf's fill state between days, so whatever got stocked during the
## previous day just carried over untouched. Clears this shelf back to
## fully empty; the CALLER is responsible for actually removing the
## physical objects that were occupying these slots — this only forgets
## the shelf's OWN bookkeeping, it doesn't touch any object directly.
func reset() -> void:
	for i in slots.size():
		_occupant[i] = null
		filled[i] = false
		_settle_timers[i] = 0.0
	wrecked = false
	_wreck_timer = 0.0

## WEEK 8 — called by Forklift.gd (host only) when a ram connects. Returns
## false (and does nothing) if this shelf is already wrecked, so a forklift
## grinding against it doesn't re-fling the same pile every tick. Spills
## every stocked item AND any loose carryable/display within
## WRECK_SPILL_RADIUS: each one gets flung along the shelf's length, away
## from the side the forklift hit, with some outward (into-the-aisle) spread
## — sideways rather than straight away from the forklift, since "away from
## the forklift" for anything between it and the shelf means INTO the
## shelf, where it would just bounce back under the forks. Goes through
## each object's own request_push(), same entry point every other knock
## uses, so carried items are skipped by Carryable's existing check.
func wreck(from_pos: Vector2) -> bool:
	if not is_multiplayer_authority() or wrecked:
		return false
	for i in slots.size():
		_occupant[i] = null
		filled[i] = false
		_settle_timers[i] = 0.0
	wrecked = true
	_wreck_timer = WRECK_DURATION
	var along: Vector2 = body.global_transform.x.normalized()
	var outward: Vector2 = -body.global_transform.y.normalized() # slots sit at local -y, so this points from the shelf into its aisle
	var hit_side := signf((body.global_position - from_pos).dot(along)) # which way along the shelf is AWAY from the impact
	var targets: Array = get_tree().get_nodes_in_group("carryable") + get_tree().get_nodes_in_group("display")
	for obj in targets:
		if obj.global_position.distance_to(body.global_position) > WRECK_SPILL_RADIUS:
			continue
		var comp: Node = obj.get_node_or_null("Carryable")
		if comp == null:
			comp = obj.get_node_or_null("Display")
		if comp == null:
			continue
		# Items on the far side of the impact point fly that way; items on
		# the near side fly the other way — a burst out from the hit, not
		# everything sliding the same direction.
		var side := signf((obj.global_position - from_pos).dot(along))
		if side == 0.0:
			side = hit_side if hit_side != 0.0 else (1.0 if randf() < 0.5 else -1.0)
		var dir := (along * side + outward * randf_range(0.3, 0.9)).normalized()
		comp.request_push(dir * WRECK_SPILL_SPEED * obj.mass)
	return true

func contains(obj: Node) -> bool:
	return obj in _occupant

func any_filled_object() -> RigidBody2D:
	for o in _occupant:
		if o != null:
			return o
	return null

func filled_count() -> int:
	var n := 0
	for f in filled:
		if f:
			n += 1
	return n

func slot_count() -> int:
	return slots.size()

## Returns the Vector2 global position of the nearest currently-empty slot,
## or null if this shelf is full. Used by stocker bots (and will be used by
## any future "walk to an open slot" UI prompt) to pick a target generically
## without needing to know this shelf's specific layout.
func nearest_empty_slot_position(from: Vector2) -> Variant:
	var best_pos = null
	var best_dist := INF
	if wrecked:
		return null
	for i in slots.size():
		if filled[i]:
			continue
		var d := from.distance_to(slots[i].global_position)
		if d < best_dist:
			best_dist = d
			best_pos = slots[i].global_position
	return best_pos

## Used by the local player's "C" placement prompt/key (see Player.gd) to
## find which of THIS shelf's empty slots (if any) a given predicted drop
## position — carrier position + the rotated carry offset, i.e. "where the
## item would land if dropped right now" — actually lands inside. Distinct
## from nearest_empty_slot_position(): that one always returns the closest
## slot regardless of distance (for bots walking toward one); this one
## returns null unless the position is ACTUALLY within CAPTURE_RADIUS,
## matching the real placement condition exactly — the prompt should show
## if and only if pressing place right now would actually succeed. Safe to
## call from any peer: read-only, uses only the already-replicated `filled`
## array and static slot positions.
func placeable_slot_at(predicted_pos: Vector2, obj: Node = null) -> Marker2D:
	# Wrecked shelves refuse stock (see wreck()), so the "C" prompt must not
	# promise a placement that the settle check will silently ignore.
	if wrecked:
		return null
	for i in slots.size():
		if filled[i]:
			continue
		if predicted_pos.distance_to(slots[i].global_position) <= CAPTURE_RADIUS:
			if obj != null and not _color_matches(obj):
				continue
			return slots[i]
	return null
