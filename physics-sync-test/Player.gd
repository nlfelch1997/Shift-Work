extends CharacterBody2D
## A player-controlled body.
##
## Only the peer that OWNS this node (multiplayer authority == this peer's id)
## reads input and actually moves it with move_and_slide(). Every other peer
## just receives this node's target_position over the network (via the
## MultiplayerSynchronizer added below) and smoothly slides its own display
## toward that value each tick, rather than snapping straight to it — see
## the matching comment in Carryable.gd for why the snap-to-latest-value
## approach visibly "shakes" on a normal 60Hz monitor. This is
## "client-authoritative movement": each player's own machine is in charge
## of their own character, which feels responsive for the owner but means
## everyone else only sees that player where the network last said they
## were (smoothed, with a small deliberate delay, instead of snapped).
##
## bot_mode replaces keyboard input with a scripted back-and-forth walk, so
## we can run this whole test with no keyboard or display attached (headless)
## and still get several players continuously contesting objects from
## different directions — that's the actual scenario we're stress-testing.
## bot_angle spreads bots evenly around SPAWN_CENTER (2, 3, or 4 of them),
## and bot_target_name assigns each bot a specific carryable object to
## contest (round-robin across whatever objects exist) — see Main.gd's
## _spawn_player.

const SPEED := 220.0
const PUSH_FORCE := 9000.0 # tuned by testing; impulse-per-second while overlapping
const SMOOTHING_RATE := 15.0 # matches Carryable.gd — see its comment for why this exists
const INTERACT_COOLDOWN := 3.0
## Week 6 — the defend/shove counter-play, built alongside re-enabling
## disruptive customers (see Main.gd's CUSTOMER_DISRUPTIVE_RATIO) so there's
## actually a response available once they go live. Radius and cooldown are
## placeholders, same as this project's other unplaytested tuning constants
## — a shorter cooldown than INTERACT_COOLDOWN on purpose, since this is
## meant to be a reactive move you can use again quickly, not a deliberate
## one like pickup.
const DEFEND_RANGE := 70.0
const DEFEND_COOLDOWN := 0.8
## WEEK 8 — getting clipped by the forklift (Forklift.gd -> forklift_hit()
## below). Same knockback-then-stun shape as Customer.gd's DEFEND_KNOCKBACK_*,
## just harder, since it's a vehicle. Placeholders.
const FORKLIFT_KNOCKBACK_SPEED := 520.0
const FORKLIFT_KNOCKBACK_DECEL := 1000.0
const FORKLIFT_STUN_DURATION := 0.6
## Week 6 Part 1 — the store became bigger than the fixed 960x540 window,
## so this project needed its first-ever scrolling camera. Duplicated from
## Main.gd's WORLD_WIDTH/WORLD_HEIGHT rather than preloaded from there —
## Main.gd already preloads Player.tscn (to spawn players), so preloading
## Main.gd back from here would be a CYCLIC preload, a real GDScript
## failure mode, not just messier style. Must be kept in sync by hand with
## Main.gd's own ROOM_WIDTH x ROOM_HEIGHT x GRID_COLS x GRID_ROWS math (960
## x 540 x 3 x 3 = 2880 x 1620 as of this session's hub-and-spoke reshape —
## see Main.gd's GRID MAP comment). UPGRADED this session: the store is now
## bigger than one screen in BOTH dimensions (a 3x3 grid, not a 1x7 row), so
## limit_bottom actually matters now too, not just limit_right.
const WORLD_WIDTH := 2880.0
const WORLD_HEIGHT := 1620.0
const BOT_PICKUP_RANGE := 55.0 # bot-side heuristic; Carryable.gd's PICKUP_RANGE is the real check
const BOT_CARRY_DURATION := 2.5
## Referenced via preload rather than the global "Carryable" class_name —
## global class_name lookups depend on an editor-built class cache that
## doesn't exist for a project that's only ever been run headless/CLI, and
## fails to resolve at parse time without it. preload() doesn't have that
## dependency.
const CarryableScript := preload("res://Carryable.gd")
const CharacterSpriteScript := preload("res://CharacterSprite.gd")

@export var bot_mode := false
@export var bot_angle := 0.0 # direction (radians) this bot approaches its target object from
@export var bot_target_name := ""
## WEEK 25 — which staff look this player wears (assets/characters/
## player_<n>.png): same store uniform as the cashiers, a different face per
## player slot. Picked by the host in Main.gd's _spawn_player() and carried
## in the spawn data, so every peer dresses this player identically.
@export var look_index := 1 # which carryable object (by node name) this bot contests ("contest" role only)
## Which scripted behavior this bot runs. "contest" is the original Week
## 1-3 tug-of-war test (unchanged). Week 4 adds "stocker" (fetches free
## product and stocks it onto the nearest open shelf slot) and "interferer"
## (hunts down placed items to knock loose, either by ramming them via the
## ordinary push-on-collision mechanic or by snatching and re-throwing
## them) — both drive the SAME pickup/carry/throw/drop calls a human player
## would use, nothing shelf-specific lives in Carryable.gd.
@export var bot_role := "contest"

var _bot_t := 0.0
var _target_obj: Node2D # "contest" role only: resolved once from bot_target_name
var _last_move_dir := Vector2.RIGHT # for throw direction when standing still
var target_position: Vector2
## Cosmetic only — mirrors _last_move_dir as an angle so it can replicate
## (a Vector2 would work too, but an angle is what Polygon2D.rotation wants
## directly). Deliberately NOT read by throw logic anywhere: Week 3 decided
## throws stay tied to movement with no separate aim input, and this only
## fixes the sprite not showing which way that direction currently is.
var facing_angle := 0.0
var _bot_interact_cooldown := 0.0
var _bot_carry_timer := 0.0
var _defend_cooldown := 0.0
var _stun_timer := 0.0
var _knockback_velocity := Vector2.ZERO
## Local-only (never replicated — this is per-viewer UI, not shared game
## state, same reasoning as the "C" prompt it drives): which slot, if any,
## carrying-and-aiming would currently place into. Recomputed every tick
## for the human-controlled local player only; bots don't use it, they
## still call try_drop()/try_throw() directly exactly as before.
var _place_target_slot: Marker2D = null
var _slip_timer := 0.0 # see _apply_move_input()
## WEEK 19 — true while this player holds the place key (C) with a cleanup
## tool in hand. Owner-written, replicated; the host does the mopping/
## sweeping against it (Cleanup.gd's tick_cleanup()).
var using_tool := false
var _badge: Label
var body_sprite: Sprite2D # WEEK 25 — CharacterSprite.gd
var _coffee_cup: Label

func _ready() -> void:
	add_to_group("player") # so Carryable.gd can find whoever is carrying its object
	# MULTIPLAYER BUG FIX (found by tools/hazards_test.gd --test=net-orders,
	# scenario N0): players pass through each other. Movement is client-
	# authoritative — each process simulates only its OWN player; every other
	# player is a synced copy running a few frames behind. Two overlapping
	# players each got depenetrated out of the other's LAGGING copy, which is
	# always behind, so both were pushed the same way forever: carried
	# backwards against their input, still sliding after letting go, and out
	# through the perimeter wall (~900px in 3s). One player alone never
	# showed it. Player-vs-player blocking can't be resolved consistently
	# without one side owning both bodies, so players simply don't collide
	# with each other; everything else (walls, shelves, stock, customers, the
	# forklift) is unchanged. Both directions, for every pair — whoever joins
	# later sets up the pair with everyone already here.
	for other in get_tree().get_nodes_in_group("player"):
		if other != self:
			add_collision_exception_with(other)
			other.add_collision_exception_with(self)
	# Without this, physics interpolation (see project.godot) would try to
	# smoothly slide this node from wherever it defaulted to (0,0) to its
	# actual spawn position, producing a brief visible "zoom in" on spawn.
	reset_physics_interpolation()
	# Runs on every peer now (not just the owner) — the non-owning peers
	# need their own _physics_process tick to run the smoothing below.
	set_physics_process(true)
	target_position = position
	$Polygon2D.color = Color(0.25, 0.55, 1.0) if get_multiplayer_authority() == 1 else Color(1.0, 0.55, 0.15)
	# WEEK 25 — real character art. The arrow polygon stays (hidden) since
	# the code below still steers its rotation; its host/client color moves
	# to a ring under the feet.
	$Polygon2D.visible = false
	body_sprite = CharacterSpriteScript.attach(self, "player_%d" % look_index, "facing_angle", $Polygon2D.color)

	# Week 6 Part 1: only the LOCAL peer's own player should drive this
	# process's view — every peer's Player.tscn instances include one for
	# every connected player (host and every client, replicated via
	# MultiplayerSpawner), but host and client are always separate OS
	# processes/windows (see Main.gd's --server/--client split), so only
	# one Camera2D should ever be enabled per process: this one, if and
	# only if it's the player this process actually controls. Created in
	# code rather than baked into Player.tscn, same reasoning as the Sync
	# node below — it needs is_multiplayer_authority() to decide, which
	# isn't known until the node's authority is set (before this runs).
	var camera := Camera2D.new()
	camera.name = "Camera"
	camera.enabled = is_multiplayer_authority()
	camera.limit_left = 0
	camera.limit_top = 0
	camera.limit_right = int(WORLD_WIDTH)
	camera.limit_bottom = int(WORLD_HEIGHT)
	add_child(camera)

	# WEEK 21 — the Break Room's cosmetic: a gold star over every crew member.
	_badge = Label.new()
	_badge.name = "Badge"
	_badge.text = "★"
	_badge.position = Vector2(-12, -46)
	_badge.size = Vector2(24, 24)
	_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_badge.add_theme_font_size_override("font_size", 20)
	_badge.add_theme_color_override("font_color", Color(1, 0.82, 0.25))
	_badge.add_theme_color_override("font_outline_color", Color(0.25, 0.15, 0))
	_badge.add_theme_constant_override("outline_size", 4)
	_badge.visible = false
	add_child(_badge)
	# WEEK 23 — a little steaming cup over anyone who had a coffee this shift
	# (every peer: it's the replicated coffee_peers), so the crew can see
	# whose speed — and whose tab — it is.
	_coffee_cup = Label.new()
	_coffee_cup.name = "CoffeeCup"
	_coffee_cup.text = "☕"
	_coffee_cup.position = Vector2(8, -40)
	_coffee_cup.size = Vector2(22, 22)
	_coffee_cup.add_theme_font_size_override("font_size", 15)
	_coffee_cup.add_theme_color_override("font_color", Color(1, 0.85, 0.6))
	_coffee_cup.add_theme_color_override("font_outline_color", Color(0.2, 0.1, 0.0))
	_coffee_cup.add_theme_constant_override("outline_size", 4)
	_coffee_cup.visible = false
	add_child(_coffee_cup)

	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	for prop in [".:target_position", ".:facing_angle", ".:using_tool"]:
		var path := NodePath(prop)
		config.add_property(path)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config
	# Must be an explicit, identical name on every peer. Godot's replication
	# system addresses nodes by path, and an auto-generated name like
	# "@MultiplayerSynchronizer@3" is NOT guaranteed to match across peers —
	# the counter depends on how many anonymous nodes that particular process
	# happened to create first. A mismatch causes "Node not found" errors.
	sync.name = "Sync"
	# Authority must be set BEFORE the node enters the tree, not after in
	# _ready — Godot warned about this directly: setting it post-entry races
	# against replication bookkeeping that already started under the default
	# authority (1), leaving the node "unable to process the pending spawn
	# since it has no network ID".
	sync.set_multiplayer_authority(get_multiplayer_authority())
	add_child(sync)

func _physics_process(delta: float) -> void:
	if not Net.is_active():
		return
	if not is_multiplayer_authority():
		return # smoothing now happens in _process, see below
	# PLAYTEST BUG FIX ("world keeps simulating during the end-of-day
	# report"): players should freeze along with customer AI for the
	# duration of the report screen — see Customer.gd's matching freeze for
	# the fuller reasoning (a customer left an item stranded at checkout
	# when the day ended under it).
	if get_tree().current_scene.is_day_report_active():
		return
	# WEEK 8 forklift knockback — input ignored until it wears off, same
	# shape as Customer.gd's shove stun.
	if _stun_timer > 0.0:
		_stun_timer -= delta
		using_tool = false
		velocity = _knockback_velocity
		_knockback_velocity = _knockback_velocity.move_toward(Vector2.ZERO, FORKLIFT_KNOCKBACK_DECEL * delta)
		move_and_slide()
		_push_rigid_bodies(delta)
		target_position = position
		return

	var dir := Vector2.ZERO
	var interact_pressed := false
	var throw_pressed := false
	var place_pressed := false
	var defend_pressed := false
	var place_held := false
	if bot_mode:
		dir = _bot_input(delta)
		_bot_maybe_interact(delta)
	elif multiplayer.is_server():
		# This whole branch only ever runs for the ONE player this process
		# owns (is_multiplayer_authority() above), so "is this process the
		# host" is exactly the same question as "is this the host's own
		# player" — no per-player role tracking needed.
		dir = Input.get_vector("host_move_left", "host_move_right", "host_move_up", "host_move_down")
		interact_pressed = Input.is_action_just_pressed("host_interact")
		throw_pressed = Input.is_action_just_pressed("host_throw")
		place_pressed = Input.is_action_just_pressed("host_place")
		place_held = Input.is_action_pressed("host_place")
		defend_pressed = Input.is_action_just_pressed("host_defend")
	else:
		dir = Input.get_vector("client_move_left", "client_move_right", "client_move_up", "client_move_down")
		interact_pressed = Input.is_action_just_pressed("client_interact")
		throw_pressed = Input.is_action_just_pressed("client_throw")
		place_pressed = Input.is_action_just_pressed("client_place")
		place_held = Input.is_action_pressed("client_place")
		defend_pressed = Input.is_action_just_pressed("client_defend")
	if dir.length() > 0.1:
		_last_move_dir = dir.normalized()
		facing_angle = _last_move_dir.angle()
		$Polygon2D.rotation = facing_angle
	var cleanup: Node = get_tree().current_scene.cleanup
	using_tool = place_held and cleanup.tool_of(multiplayer.get_unique_id()) >= 0
	if not bot_mode:
		_update_place_target()
	if throw_pressed:
		_try_throw()
	elif interact_pressed:
		_try_interact()
	if place_pressed:
		_try_place()
	_defend_cooldown -= delta
	if defend_pressed and _defend_cooldown <= 0.0:
		_try_defend()
		_defend_cooldown = DEFEND_COOLDOWN
	_apply_move_input(dir, delta)
	move_and_slide()
	_push_rigid_bodies(delta)
	target_position = position

## WEEK 11 (Day 6+) — floor spills (Ambience.gd). On dry floor velocity is the
## input, instantly, exactly as before. On a wet spill, and for
## SPILL_SLIDE_OUT after stepping off one, it only EASES toward the input at
## SPILL_TRACTION, so you slide on turns and stops, and the top speed is
## SPILL_SPEED_FACTOR of normal while you're on it. Never zero: a spill
## slows and slides you, it doesn't hold you. Runs on the owning peer only
## (movement is client-authoritative), against the replicated spill list.
func _apply_move_input(dir: Vector2, delta: float) -> void:
	var ambience: Node = get_tree().current_scene.ambience
	var endless: Node = get_tree().current_scene.endless
	var on_spill: bool = ambience.slippery_at(global_position)
	if on_spill:
		_slip_timer = ambience.SPILL_SLIDE_OUT
	if _slip_timer > 0.0:
		if not on_spill:
			_slip_timer -= delta
		var top: float = speed() * (endless.spill_speed_factor(ambience.SPILL_SPEED_FACTOR) if on_spill else 1.0)
		velocity = velocity.move_toward(dir * top, ambience.SPILL_TRACTION * endless.spill_traction_mult() * delta)
	else:
		velocity = dir * speed()

## WEEK 21: SPEED x the Break Room's Comfy Sneakers (Endless.gd, replicated to
## every peer; movement runs on the owner, which reads its own copy).
## WEEK 23: + the coffee machine's cup (BreakRoom.gd), ADDED to the sneakers'
## multiplier — 1 + 0.08 x level + 0.20 with a cup — not multiplied with it.
func speed() -> float:
	var main = get_tree().current_scene
	return SPEED * (main.endless.speed_mult() + main.break_room.speed_bonus(get_multiplayer_authority()))

## True while this player's movement is on low traction (on a spill or just
## off one) — read by the test harness.
func is_slipping() -> bool:
	return _slip_timer > 0.0

## Runs in _process (tied to actual render rate) rather than
## _physics_process (fixed 60Hz) — see the matching comment in Carryable.gd.
func _process(delta: float) -> void:
	# WEEK 21 — the Employee of the Month star (cosmetic, Endless.gd), every peer.
	_badge.visible = get_tree().current_scene.endless.has_badge()
	_coffee_cup.visible = get_tree().current_scene.break_room.has_coffee(get_multiplayer_authority())
	if not Net.is_active() or is_multiplayer_authority():
		return
	var t: float = clamp(SMOOTHING_RATE * delta, 0.0, 1.0)
	position = position.lerp(target_position, t)
	# Snapped straight to the replicated value, not lerped like position —
	# facing only changes when the owner's movement direction changes
	# (not continuously like position does), so there's no per-tick jitter
	# to smooth out here.
	$Polygon2D.rotation = facing_angle

## move_and_slide() only stops the character at a RigidBody2D — it does not
## push it. We have to detect the contact and apply the force ourselves.
## Looks for a "Carryable" child on whatever we collided with, rather than
## expecting push methods directly on the body — any RigidBody2D with that
## component attached works, generically.
func _push_rigid_bodies(delta: float) -> void:
	for i in get_slide_collision_count():
		var collision := get_slide_collision(i)
		var collider := collision.get_collider()
		if not (collider is RigidBody2D):
			continue
		var carryable: Node = collider.get_node_or_null("Carryable")
		if carryable == null:
			# WEEK 8 floor displays (Display.gd) expose the same
			# request_push() with the same authority, so they're pushed
			# through the exact same path — without this a player would
			# treat one as an immovable wall.
			carryable = collider.get_node_or_null("Display")
		if carryable == null:
			continue
		var impulse: Vector2 = -collision.get_normal() * PUSH_FORCE * delta
		if carryable.is_multiplayer_authority():
			collider.apply_central_impulse(impulse)
			# WEEK 9: this is the HOST's own player (a remote player's push
			# goes through request_push(), which attributes it there) — tell
			# the manager in case that was shelved stock or a display.
			var manager := get_tree().get_first_node_in_group("manager")
			if manager:
				manager.note_push(get_multiplayer_authority(), collider)
		else:
			carryable.rpc_id(carryable.get_multiplayer_authority(), "request_push", impulse)

func _bot_input(delta: float) -> Vector2:
	match bot_role:
		"stocker":
			return _bot_stocker_input(delta)
		"interferer":
			return _bot_interferer_input(delta)
		_:
			return _bot_contest_input(delta)

func _bot_contest_input(delta: float) -> Vector2:
	if _target_obj == null:
		_target_obj = _resolve_bot_target()
		if _target_obj == null:
			return Vector2.ZERO
	var carryable: Node = _target_obj.get_node("Carryable")
	if carryable.carrier_id == multiplayer.get_unique_id():
		# Carrying it: walk it in a simple direction instead of "approach
		# the object," which would be a feedback loop now that the
		# object's own position is pinned to ours.
		_bot_carry_timer += delta
		return Vector2.RIGHT.rotated(bot_angle + PI * 0.5)
	# Walk toward the object's CURRENT position (not a fixed point) from
	# bot_angle, then oscillate in and out of it so every bot keeps
	# contesting its object all test long even as pushing moves it around.
	_bot_t += delta
	var offset := Vector2.RIGHT.rotated(bot_angle) * (50.0 + 35.0 * sin(_bot_t * 1.3))
	var target := _target_obj.global_position + offset
	var to_target := target - global_position
	if to_target.length() < 4.0:
		return Vector2.ZERO
	return to_target.normalized()

func _resolve_bot_target() -> Node2D:
	if bot_target_name == "":
		return null
	for obj in get_tree().get_nodes_in_group("carryable"):
		if obj.name == bot_target_name:
			return obj
	return null

## Scripted stand-in for pressing the interact/throw keys: try a pickup
## once close enough to a free object, hold it briefly, then either drop
## or throw it (picked at random so both code paths get exercised over the
## whole test) — repeated for the whole run.
func _bot_maybe_interact(delta: float) -> void:
	match bot_role:
		"stocker":
			_bot_stocker_maybe_interact(delta)
		"interferer":
			_bot_interferer_maybe_interact(delta)
		_:
			_bot_contest_maybe_interact(delta)

func _bot_contest_maybe_interact(delta: float) -> void:
	_bot_interact_cooldown -= delta
	if _target_obj == null or _bot_interact_cooldown > 0.0:
		return
	var carryable: Node = _target_obj.get_node("Carryable")
	var my_id := multiplayer.get_unique_id()
	if carryable.carrier_id == my_id:
		if _bot_carry_timer >= BOT_CARRY_DURATION:
			if randf() < 0.5:
				_try_throw()
			else:
				_try_interact()
			_bot_interact_cooldown = INTERACT_COOLDOWN
			_bot_carry_timer = 0.0
	elif carryable.carrier_id == 0 and global_position.distance_to(_target_obj.global_position) < BOT_PICKUP_RANGE:
		_try_interact()
		_bot_interact_cooldown = INTERACT_COOLDOWN

## --- Stocker bot: fetch a free product, carry it to the nearest open
## shelf slot, drop it there. No shelf-specific interaction needed —
## dropping accurately within a slot's capture radius IS placing it, per
## Shelf.gd's own per-tick check. Repeats until no free product or no open
## slot remains.
##
## FOUND BY TESTING: re-querying "nearest empty slot" every tick while
## walking caused the target to flip between two similarly-close slots as
## the bot moved, so it converged on a point between them instead of either
## one — a wide miss on drop, not a near-miss. Committing to ONE slot for
## the whole carry trip (cleared only once the trip ends) fixes it.
var _bot_committed_slot_pos = null # Variant: Vector2 once committed, else null

func _bot_stocker_input(_delta: float) -> Vector2:
	var my_id := multiplayer.get_unique_id()
	var carried := _find_carried_object(my_id)
	if carried == null:
		_bot_committed_slot_pos = null
		var target := _bot_find_product_target()
		if target == null:
			return Vector2.ZERO
		var to_product := target.global_position - global_position
		if to_product.length() < BOT_PICKUP_RANGE:
			return Vector2.ZERO
		return to_product.normalized()
	if _bot_committed_slot_pos == null:
		_bot_committed_slot_pos = _bot_find_empty_slot()
	if _bot_committed_slot_pos == null:
		return Vector2.ZERO # nothing open anywhere right now
	# Walk STRAIGHT at the slot rather than at a precomputed offset point —
	# now that Carryable.gd rotates CARRY_OFFSET to match facing direction,
	# "the direction I'm walking" and "the direction the item trails toward"
	# are the same thing, so stopping CARRY_OFFSET's own length away from
	# the slot lands the item on it regardless of which side the bot
	# approached from (a fixed offset point only worked from one side).
	var to_slot: Vector2 = _bot_committed_slot_pos - global_position
	if to_slot.length() < CarryableScript.CARRY_OFFSET.length():
		return Vector2.ZERO
	return to_slot.normalized()

func _bot_stocker_maybe_interact(delta: float) -> void:
	_bot_interact_cooldown -= delta
	if _bot_interact_cooldown > 0.0:
		return
	var my_id := multiplayer.get_unique_id()
	var carried := _find_carried_object(my_id)
	if carried == null:
		var target := _bot_find_product_target()
		if target and global_position.distance_to(target.global_position) < BOT_PICKUP_RANGE:
			_interact_with(target, my_id)
			_bot_interact_cooldown = INTERACT_COOLDOWN
	elif _bot_committed_slot_pos != null and global_position.distance_to(_bot_committed_slot_pos) < CarryableScript.CARRY_OFFSET.length() + 4.0:
		# Explicitly face the slot right before dropping, rather than trusting
		# whatever facing_angle happens to hold — found by testing: if the
		# picked-up product was already sitting within CARRY_OFFSET's length
		# of the slot (leftover from an earlier failed placement), the "stop
		# once close enough" check can trigger on the very first carrying
		# tick, before the bot ever actually walks toward the SLOT at all —
		# facing_angle would still reflect whichever direction it was walking
		# to reach the PRODUCT, unrelated to the slot, and the rotated offset
		# would fling the item in a stale, essentially arbitrary direction.
		var to_slot: Vector2 = _bot_committed_slot_pos - global_position
		if to_slot.length() > 0.01:
			facing_angle = to_slot.angle()
			$Polygon2D.rotation = facing_angle
		_interact_with(carried, my_id)
		_bot_interact_cooldown = INTERACT_COOLDOWN
		_bot_committed_slot_pos = null

func _bot_find_product_target() -> Node2D:
	var best: Node2D = null
	var best_dist := INF
	for obj in get_tree().get_nodes_in_group("carryable"):
		var c: Node = obj.get_node("Carryable")
		if c.carrier_id != 0 or _bot_is_placed(obj):
			continue
		var d := global_position.distance_to(obj.global_position)
		if d < best_dist:
			best_dist = d
			best = obj
	return best

func _bot_find_empty_slot() -> Variant:
	var best_pos = null
	var best_dist := INF
	for shelf_body in get_tree().get_nodes_in_group("shelf"):
		var shelf: Node = shelf_body.get_node("Shelf")
		var pos = shelf.nearest_empty_slot_position(global_position)
		if pos == null:
			continue
		var d: float = global_position.distance_to(pos)
		if d < best_dist:
			best_dist = d
			best_pos = pos
	return best_pos

func _bot_is_placed(obj: Node2D) -> bool:
	for shelf_body in get_tree().get_nodes_in_group("shelf"):
		var shelf: Node = shelf_body.get_node("Shelf")
		if shelf.contains(obj):
			return true
	return false

## --- Interferer bot: the placeholder chaos source for multi-bot testing.
## Hunts down whatever's currently placed on a shelf and disrupts it —
## either by simply walking into it (the existing move_and_slide()-vs-
## RigidBody2D push mechanic fires automatically on approach, no special
## code needed) or by picking it up outright and lobbing it elsewhere
## (picking a placed item back up already un-places it — Shelf.gd notices
## carrier_id != 0 next tick — the throw afterward is just extra chaos on
## top, not load-bearing for proving knockdown works). Falls back to
## harassing any free carryable if nothing's currently placed to knock over.
func _bot_interferer_input(delta: float) -> Vector2:
	var my_id := multiplayer.get_unique_id()
	var carried := _find_carried_object(my_id)
	if carried:
		_bot_carry_timer += delta
		return Vector2.RIGHT.rotated(bot_angle + PI * 0.5)
	var target := _bot_find_disruption_target()
	if target == null:
		return Vector2.ZERO
	var to_target := target.global_position - global_position
	if to_target.length() < 4.0:
		return Vector2.ZERO
	return to_target.normalized()

func _bot_interferer_maybe_interact(delta: float) -> void:
	_bot_interact_cooldown -= delta
	var my_id := multiplayer.get_unique_id()
	var carried := _find_carried_object(my_id)
	if carried:
		if _bot_carry_timer >= BOT_CARRY_DURATION:
			_try_throw()
			_bot_interact_cooldown = INTERACT_COOLDOWN
			_bot_carry_timer = 0.0
		return
	if _bot_interact_cooldown > 0.0:
		return
	var target := _bot_find_disruption_target()
	if target and global_position.distance_to(target.global_position) < BOT_PICKUP_RANGE:
		if randf() < 0.5:
			_interact_with(target, my_id)
			_bot_interact_cooldown = INTERACT_COOLDOWN

func _bot_find_disruption_target() -> Node2D:
	for shelf_body in get_tree().get_nodes_in_group("shelf"):
		var shelf: Node = shelf_body.get_node("Shelf")
		var occupant = shelf.any_filled_object()
		if occupant:
			return occupant
	return _find_nearest_free_carryable()

## Drop/pickup toggle, bound to "E" — DECIDED, not guessed: E keeps this
## exact unconditional behavior (pick up if empty-handed, else drop right
## here, no slot check) whether or not a shelf is nearby, unchanged from
## before "C" existed. "C" (_try_place, below) is purely additive: a second,
## more deliberate action that only ever does anything when the on-screen
## prompt says it will succeed. Reasoning: E remains the always-available
## "let go of what I'm holding" escape hatch (put something down without
## committing to a shelf, or without throwing it), while C becomes the
## confident, prompted way to place precisely — splitting the KEYS without
## removing any existing behavior seemed better than making plain drop
## impossible outside a slot, which would leave no way to just set
## something down. If playtesting says E dropping near a slot (and
## incidentally landing inside CAPTURE_RADIUS, same as it always could) is
## confusing alongside C, that's the next thing to reconsider — flagging
## rather than deciding it silently.
##
## A "contest" bot always acts on its assigned _target_obj; every other
## case (manual play, and the "stocker"/"interferer" bot roles, which pick
## a fresh target each cycle rather than a fixed one) acts on whatever's
## already carried, or else the nearest free object in range — since a
## human player wants to interact with whatever's actually nearby, not a
## scripted assignment.
func _try_interact() -> void:
	var my_id := multiplayer.get_unique_id()
	if bot_mode and bot_role == "contest":
		if _target_obj:
			_interact_with(_target_obj, my_id)
		return
	var carried := _find_carried_object(my_id)
	if carried:
		# WEEK 21 — Back Brace (carry capacity > 1): E fills your arms — with
		# room and a product in reach it grabs another — and E on FULL arms
		# sets the whole armful down, side by side. (Put-down-the-top-one on
		# a partial armful would loop: next to loose stock, E would grab,
		# drop, grab... and never empty your hands.) With nothing in reach,
		# E puts the top one down as always; C places the top one on a shelf.
		var more := _stackable_in_reach(carried, my_id)
		if more:
			_interact_with(more, my_id)
			return
		var count := carried_count(my_id)
		if count > 1 and count >= get_tree().current_scene.endless.carry_capacity():
			_set_down_armful(my_id)
			return
		_interact_with(carried, my_id)
		return
	var main = get_tree().current_scene
	# WEEK 19: the time clock in the break room ends the day — first, so a
	# tool still in hand doesn't turn the press into "put it down" (tools go
	# back to the station at clock-out anyway)...
	if main.cleanup_active and main.near_time_clock(global_position):
		main.try_clock_out()
		return
	# ...then a cleanup tool in hand (put it down / empty the pan), or one
	# within reach once the store's closed — before stock, so a product lying
	# at the tool station can't swallow the press.
	if main.cleanup.wants_interact(my_id, global_position):
		main.cleanup.try_interact()
		return
	# WEEK 16: empty-handed at the Store sign while the store is still closed
	# -> flip it open (Main.gd decides on the host). Checked before picking
	# anything up, so a product lying by the sign can't swallow the press.
	if not main.store_open and main.shift_active and main.near_store_sign(global_position):
		main.try_flip_sign()
		return
	# WEEK 23: empty-handed at the coffee machine -> a cup (the host decides:
	# once per shift, not during cleanup). At the vending machine -> a joke
	# line, local only. Before picking anything up, like the sign.
	if main.shift_active and main.break_room.near_coffee(global_position):
		if not main.break_room.has_coffee(my_id) and main.break_room.coffee_open():
			main.break_room.try_buy_coffee()
		return
	if main.break_room.near_vending(global_position):
		main.break_room.poke_vending()
		return
	# OCT 2026 PHASE 2: empty-handed at a for-sale section's gate -> buy it
	# (the host decides: prep only, next in line, enough in the bank). When it
	# can't be bought right now, the press only says why if there's nothing
	# to pick up here instead (the prompt over the gate already shows why).
	var for_sale: String = main.for_sale_gate_at(global_position)
	if for_sale != "" and main.shift_active:
		if main.purchase_blocker(for_sale) == "":
			main.try_buy_section(for_sale)
			return
		if _find_nearest_free_carryable() == null and not litter_beats_stock():
			main.show_toast("%s: %s" % [for_sale, main.purchase_blocker(for_sale)], Color(1, 0.85, 0.3), 2.5)
			return
	# PLAYTEST FIX: trash by hand, any time — when litter is in reach and no
	# loose stock is (Cleanup.gd's LITTER_PAY_PER_PIECE).
	if litter_beats_stock():
		main.cleanup.try_pick_litter()
		return
	var nearest := _find_nearest_free_carryable()
	if nearest:
		_interact_with(nearest, my_id)

func _interact_with(obj: Node2D, my_id: int) -> void:
	var c: Node = obj.get_node("Carryable")
	if c.carrier_id == my_id:
		c.try_drop(my_id)
	elif c.carrier_id == 0:
		c.try_pickup(my_id, global_position)

## Throw whatever I'm currently carrying, in the direction I'm currently
## moving (or last moved, if standing still). This is the confirmed,
## intended long-term control scheme, not a placeholder — no aim input,
## consistent with keeping controls instantly legible for the genre. Same
## lookup logic as _try_interact: a "contest" bot uses its assigned target,
## everyone else (manual play, "stocker"/"interferer") uses whatever's
## actually being carried.
func _try_throw() -> void:
	var my_id := multiplayer.get_unique_id()
	var obj := _target_obj if (bot_mode and bot_role == "contest") else _find_carried_object(my_id)
	if obj == null:
		return
	var c: Node = obj.get_node("Carryable")
	if c.carrier_id == my_id:
		c.try_throw(my_id, _last_move_dir)

## Human-only (see the "not bot_mode" guard where this is called): recomputes
## every physics tick whether placing right now would land in an empty
## slot, and shows/hides that slot's "C" prompt (see Shelf.tscn) to match.
## Uses the EXACT same formula Carryable.gd's drop/throw finalization uses
## — carrier position + CARRY_OFFSET rotated by facing — so "the prompt is
## showing" and "placing will succeed" can never disagree with each other.
## Passes the carried object itself through to placeable_slot_at() now too
## (slot color-matching, this session's request) — the prompt would
## otherwise show over a color-mismatched slot promising a placement that
## Shelf.gd's own settle check would silently refuse.
func _update_place_target() -> void:
	var my_id := multiplayer.get_unique_id()
	var carried := _find_carried_object(my_id)
	var new_target: Marker2D = null
	if carried:
		var predicted := global_position + CarryableScript.CARRY_OFFSET.rotated(facing_angle)
		for shelf_body in get_tree().get_nodes_in_group("shelf"):
			var shelf: Node = shelf_body.get_node("Shelf")
			var slot: Marker2D = shelf.placeable_slot_at(predicted, carried)
			if slot:
				new_target = slot
				break
	if new_target != _place_target_slot:
		if _place_target_slot:
			_place_target_slot.get_node("Prompt").visible = false
		if new_target:
			new_target.get_node("Prompt").visible = true
		_place_target_slot = new_target

## Bound to "C" — only does anything when _update_place_target() found a
## valid slot this tick (i.e. the prompt is actually showing). Calls the
## same try_drop() as E; the only difference is WHEN each key does
## something, not what happens once it does — see the design-decision
## comment on _try_interact().
func _try_place() -> void:
	if _place_target_slot == null:
		return
	var my_id := multiplayer.get_unique_id()
	var carried := _find_carried_object(my_id)
	if carried:
		var c: Node = carried.get_node("Carryable")
		if c.carrier_id == my_id:
			c.try_drop(my_id)

## Week 6 defend/shove — radial, hits every customer in DEFEND_RANGE
## regardless of role (see the matching note on Customer.gd's request_shove
## for why this deliberately doesn't special-case shopper vs. disruptive).
## Bound to Space for both host and client; bots don't use it (out of scope
## — this is the human counter-play to disruptive customers, not something
## the contest/stocker/interferer test bots need to exercise).
func _try_defend() -> void:
	for customer in get_tree().get_nodes_in_group("customer"):
		if global_position.distance_to(customer.global_position) > DEFEND_RANGE:
			continue
		# Same "call locally if I'm already the authority, else RPC the
		# authority" split as _push_rigid_bodies uses for request_push —
		# customer authority is always host (peer 1), so this is exactly
		# "am I the host" in practice, but written generically like the
		# original so it doesn't hardcode that assumption.
		if customer.is_multiplayer_authority():
			customer.request_shove(global_position)
		else:
			customer.rpc_id(customer.get_multiplayer_authority(), "request_shove", global_position)

## Week 7 — called by Main.gd at the start of each day
## (_reset_players_to_break_room()) to move every player back to the break
## room. "any_peer", not "authority": the HOST isn't necessarily THIS
## player's own multiplayer authority (a client's own player node has that
## client as its authority, not the host), so an "authority"-restricted
## RPC would block the host from commanding anyone but its own player.
## The is_multiplayer_authority() check inside is what keeps this safe
## despite "any_peer" — broadcasting the call reaches every peer, but only
## the ACTUAL OWNER of this specific player node ever passes that check
## and actually moves; everyone else's invocation is a silent no-op, the
## same "any peer may ask, only the authority ever acts" shape as
## Carryable.gd's request_*() functions. reset_physics_interpolation() is
## required here for the same reason _ready() already calls it once at
## spawn: without it, physics interpolation would try to smoothly SLIDE
## this node across the whole map from its old position to the break
## room instead of snapping there instantly.
@rpc("any_peer", "call_local", "reliable")
func teleport_to(pos: Vector2) -> void:
	if not is_multiplayer_authority():
		return
	position = pos
	target_position = pos
	velocity = Vector2.ZERO # no spill slide carried through a teleport
	_slip_timer = 0.0
	reset_physics_interpolation()

## WEEK 8 — the forklift (Forklift.gd, host-only) drove into this player.
## Movement here is client-authoritative, so the host can't shove a remote
## player's node itself; it broadcasts this and only the owner acts — the
## same "any_peer + is_multiplayer_authority() gate" shape as teleport_to()
## above, plus a sender check so only the HOST can trigger it (a client
## calling it on someone else's player is ignored; get_remote_sender_id()
## is 0 when invoked locally outside an RPC context, so that's allowed too).
## Getting hit also fumbles whatever's being carried: it's thrown in the
## knockback direction via the normal try_throw() path, so it lands as
## ordinary loose stock someone has to pick back up — the "physical chaos"
## cost of not getting out of the way.
@rpc("any_peer", "call_local", "reliable")
func forklift_hit(from_position: Vector2) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 1 and sender != 0:
		return
	# WEEK 22: every peer gets this broadcast — everyone near hears the bonk.
	Sfx.play_at("forklift_bonk", global_position)
	var juice = get_tree().current_scene.get("juice") # WEEK 27: the visual BONK, every peer
	if juice:
		juice.forklift_hit(self)
	if not is_multiplayer_authority():
		return
	var dir := global_position - from_position
	if dir.length() < 0.01:
		dir = Vector2.RIGHT.rotated(randf_range(0.0, TAU))
	dir = dir.normalized()
	_knockback_velocity = dir * FORKLIFT_KNOCKBACK_SPEED
	_stun_timer = FORKLIFT_STUN_DURATION * get_tree().current_scene.endless.forklift_stun_mult() # WEEK 21: Steel-Toe Boots
	var my_id := multiplayer.get_unique_id()
	# WEEK 21: the whole stack goes flying, not just the top of it.
	var fumbled := 0
	for obj in get_tree().get_nodes_in_group("carryable"):
		if obj.get_node("Carryable").carrier_id == my_id:
			obj.get_node("Carryable").try_throw(my_id, dir if fumbled == 0 else dir.rotated(randf_range(-0.35, 0.35)))
			fumbled += 1
	print("[Player %d] hit by forklift" % my_id)

## WEEK 21: the TOP of the stack (newest pickup) when the Back Brace lets a
## player hold more than one — what E drops, C places and F throws.
func _find_carried_object(my_id: int) -> Node2D:
	var best: Node2D = null
	var best_seq := -1
	for obj in get_tree().get_nodes_in_group("carryable"):
		var c: Node = obj.get_node("Carryable")
		if c.carrier_id == my_id and c.carry_seq > best_seq:
			best = obj
			best_seq = c.carry_seq
	return best

## WEEK 21 — everything in my arms onto the floor, top of the stack first,
## spread sideways (Carryable.gd's try_drop() side) so nothing lands in a pile.
func _set_down_armful(my_id: int) -> void:
	var held := []
	for obj in get_tree().get_nodes_in_group("carryable"):
		if obj.get_node("Carryable").carrier_id == my_id:
			held.append(obj)
	held.sort_custom(func(a, b): return a.get_node("Carryable").carry_seq > b.get_node("Carryable").carry_seq)
	for i in held.size():
		held[i].get_node("Carryable").try_drop(my_id, i)

func carried_count(my_id: int) -> int:
	var n := 0
	for obj in get_tree().get_nodes_in_group("carryable"):
		if obj.get_node("Carryable").carrier_id == my_id:
			n += 1
	return n

## WEEK 21 — a free PRODUCT in reach to stack on top, or null: needs the Back
## Brace's room, and never a delivery box (either side). The host re-checks
## (Carryable.gd's _player_has_room()).
func _stackable_in_reach(carried: Node2D, my_id: int) -> Node2D:
	if carried.is_in_group("delivery_box"):
		return null
	if carried_count(my_id) >= get_tree().current_scene.endless.carry_capacity():
		return null
	var best: Node2D = null
	var best_dist := CarryableScript.PICKUP_RANGE
	for obj in get_tree().get_nodes_in_group("carryable"):
		if obj.is_in_group("delivery_box") or obj.get_node("Carryable").carrier_id != 0:
			continue
		if obj.get_node("Carryable").shelved:
			continue # filling your arms never strips a shelf
		var d := global_position.distance_to(obj.global_position)
		if d < best_dist:
			best_dist = d
			best = obj
	return best

## True when an empty-handed E here would pick up litter rather than stock:
## a piece is in reach and NO loose stock is (stocking is the job — trash
## never steals an E press meant for a product; found by the 3-player
## net-orders test, where a crew member kept grabbing wrappers lying beside
## the stock they were reaching for and fell 30s behind). Shelved stock
## doesn't count — trash beside a stocked shelf is fair game. Every peer
## (the "E: pick up trash" hint uses it, so it always tells the truth).
func litter_beats_stock() -> bool:
	var main = get_tree().current_scene
	var hit: Array = main.cleanup.nearest_litter(global_position)
	if hit[0] == 0:
		return false
	var nearest := _find_nearest_free_carryable()
	return nearest == null or nearest.get_node("Carryable").shelved

## The item E picks up: the nearest free one within Carryable.PICKUP_RANGE
## (see that constant for the playtest fix). PLAYTEST FIX: loose stock wins
## over shelved stock — with the wider reach, E beside a stocked shelf would
## otherwise often grab a shelved item instead of the loose one you walked
## up to. A shelved item is still yours to take back when nothing loose is
## in reach.
func _find_nearest_free_carryable() -> Node2D:
	var best: Node2D = null
	var best_dist := CarryableScript.PICKUP_RANGE
	var best_shelved := true
	for obj in get_tree().get_nodes_in_group("carryable"):
		var c: Node = obj.get_node("Carryable")
		if c.carrier_id != 0:
			continue
		var d := global_position.distance_to(obj.global_position)
		if d > CarryableScript.PICKUP_RANGE:
			continue
		var is_shelved: bool = c.shelved
		if (best_shelved and not is_shelved) or (is_shelved == best_shelved and d < best_dist) or best == null:
			best_dist = d
			best = obj
			best_shelved = is_shelved
	return best
