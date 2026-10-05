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
## OCT 2026 PHASE 3B — SHOPPING LISTS AND CARTS. A shopper no longer walks to
## whatever stocked item is nearest. Playtest income testing found that capped
## sales at "who is nearest the Sidewalk": a fully stocked Bakery, the
## farthest section, sold 0-7 items a shift while Produce/Dairy sold 40+. Now:
## - THE LIST (shopping_list): drawn by the host at spawn (Main.gd's
##   make_shopping_list()) from the sections that are open AND stocked, spread
##   evenly across them however far each is from the door. One entry per item
##   wanted. The shopper fetches the nearest stocked item that is ON its list,
##   crossing each off as it goes into the cart.
## - SOLD OUT: when nothing left on the list is on a shelf, the shopper browses
##   for LIST_PATIENCE seconds (a helper or player may restock it), then
##   crosses those items off and checks out with what it has, or leaves
##   without buying anything if the cart is still empty.
## - THE CART: purely cosmetic, pushed in front (side view facing left/right,
##   front view facing up/down, from the supermarket pack's own cart art).
##   Everything picked up still goes through Carryable.gd exactly as before (a
##   reliable pickup, carrier_id = carry_id); the items ride hidden at
##   cart_point() and the cart draws a small copy of each in its basket. No
##   collision of its own, so speed, the 28px body, pathing, the forklift
##   knockback and the checkout queue are all exactly what they were.
## - CHECKOUT: one trip to the register with the whole cart, rung up one item
##   at a time — each the same Cashier.CHECKOUT_WAIT_SECONDS a single item
##   always took, each its own sale through note_sale() (Cashier.gd).
## Every peer draws the cart and the list bubble from replicated state: the
## list (spawn data, then this node's synchronizer) and who carries what
## (Carryable.gd's reliable carrier_id). Disruptive customers have neither.
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
const MAX_LIFETIME_SHOPPER := 30.0 # initial budget before any real target (a stocked item, then its checkout) is ever picked — see _lifetime_budget below for how this grows once one is
## PLAYTEST FIX (Oct 2026, see Main.gd's _restock_customers()): each
## disruptive customer stays a random 60-100% of MAX_LIFETIME_DISRUPTIVE —
## host-only (this runs where the AI runs), cosmetic to peers. The opening
## wave spawns in one tick, and with a flat 45s every red customer in it
## walked out in the same second; jittered, they leave (and get replaced)
## spread across a ~18s window, so new ones trickle in all shift.
const DISRUPTIVE_LIFETIME_JITTER := 0.6
const MAX_LIFETIME_DISRUPTIVE := 45.0 # disruptive never commits to one distant target (its retargets are all local, BROWSE/RETARGET_RADIUS-scale), so this stays a flat cap
## DYNAMIC LIFETIME BUDGET — PATTERN-LEVEL PLAYTEST ROOT-CAUSE FIX. This is
## the THIRD round of "customers are timing out" reported after a map-length
## change (centralized checkout, then the entrance/checkout split, now the
## Sidewalk room), and each previous round was "fixed" by bumping a flat
## constant (MAX_LIFETIME_SHOPPER used to also gate the whole walk to a
## committed item; MAX_CARRY_LIFETIME, formerly here, gated the carry-to-
## checkout walk) to comfortably cover whatever the map's total length
## happened to be AT THE TIME — which quietly breaks again the next time a
## room is added, exactly as it just did. Fixed at the root instead:
## _lifetime_budget (declared below, replacing the old separate
## _carry_timer/MAX_CARRY_LIFETIME pair with ONE clock — _lifetime — compared
## against ONE budget) starts at the flat MAX_LIFETIME_SHOPPER/DISRUPTIVE
## value above, then _extend_lifetime_budget() grows it, using the ACTUAL
## straight-line distance from this customer's own spawn point to whatever
## it just committed to (a stocked item, later that item's checkout),
## every time _shopper_input() picks one. A shopper walking to a section
## that just unlocked this session automatically gets a budget sized for
## THAT walk, whatever the map looks like by then — nothing here to
## re-tune the next time a room gets added.
const LIFETIME_DISTANCE_MULTIPLIER := 2.0 # travel time is distance/SPEED; multiplied up to cover browsing detours, the generic stuck-detection's sideways nudges, and time spent standing in a queue — not just a bare straight-line walk
const LIFETIME_BASE_BUFFER := 15.0 # flat floor added on top of travel time, so an already-close target still gets a reasonable window for pickup fumbling / queue wait / CHECKOUT_WAIT_SECONDS dwell
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
## GENERIC STUCK-DETECTION (playtest request): rather than patching each
## specific obstacle that can block a customer's straight "walk directly at
## the target" path (a cashier counter, a shelf just stocked from, another
## customer, a player, whatever gets added later — this project has no
## navigation mesh/pathfinding to route around any of them), this applies
## uniformly to EVERY customer (shopper or disruptive) and EVERY target
## (an item, the checkout queue, a browse point, a disruptive retarget) by
## watching actual position over time instead of trusting the intended
## direction. See _apply_stuck_avoidance() below for the mechanism.
##
## PLAYTEST ROOT-CAUSE FIX ("customers getting stuck behind shelves"): the
## metric below used to be RAW distance moved per check, in any direction —
## which is exactly the wrong test against a shelf specifically. A shelf's
## collision box (180x66, see Shelf.tscn) is long and thin compared to a
## customer (28x28) or another customer/player, so a customer approaching
## one at anything but a dead-on angle doesn't stop against it, it SLIDES
## along its face — move_and_slide()'s normal, correct behavior for hitting
## a wall at an angle. That sliding easily covers more than
## STALL_DISTANCE_THRESHOLD per check, so the raw-distance metric read it as
## "still making progress" indefinitely: a customer could crawl along a
## shelf's 180px face for as long as its lifetime budget lasted without the
## stall counter ever incrementing, since it never stopped moving, it just
## never got any closer to where it was actually trying to go. Other
## obstacles (a cashier, another customer, a player) are compact enough that
## hitting them reads as a genuine stop, which is why this read as a
## shelf-specific bug rather than a generic one. Fixed by measuring
## progress PROJECTED ONTO the direction the customer is actually trying to
## move (see _apply_stuck_avoidance()'s dot-product check) instead of raw
## displacement — sliding sideways along a shelf now correctly nets close to
## zero progress toward the target, however far it actually traveled.
const STALL_CHECK_INTERVAL := 0.5 # how often to sample position for progress
const STALL_DISTANCE_THRESHOLD := 6.0 # must gain at least this much progress ALONG the intended direction per check to count as "making progress" — not just move, in any direction, this far (see this section's own root-cause comment)
const STALL_CHECKS_TO_TRIGGER := 3 # consecutive no-progress checks before reacting (~1.5s)
const DETOUR_DURATION := 1.0 # how long to hold a sideways detour before aiming at the target directly again
## PLAYTEST ROOT-CAUSE FIX ("customers sway side-to-side stuck at shelves,
## can't escape"): each detour episode used to pick its side (left/right of
## the intended direction) with an independent coin flip, with nothing
## remembering the previous episode's choice. Against a compact obstacle
## (a cashier, a player, another customer) one DETOUR_DURATION-long episode
## is enough to slip past regardless, so this never showed up. Against a
## wide obstacle needing more than one episode's worth of sideways travel
## to actually clear — which is also measured pessimistically, since
## progress is judged against the ORIGINAL target direction the whole
## time, so a detour that's genuinely working still reads as "stalled"
## until it's fully clear — a coin flip every episode meant the customer
## was about as likely to undo an escape already in progress as to
## continue it, which is exactly the side-to-side sway that got reported.
## MAX_DETOUR_EPISODES_PER_SIDE is the escape hatch for the other failure
## mode: if a customer commits to one side and it genuinely doesn't work
## either (e.g. boxed into a corner), it isn't allowed to commit to that
## side forever — after this many consecutive episodes without progress
## resuming, it tries the other side instead. See _apply_stuck_avoidance()
## for the mechanism.
const MAX_DETOUR_EPISODES_PER_SIDE := 3

## OCT 2026 PHASE 3B — FLAGGED, tunable. How long a shopper waits (browsing)
## when nothing left on its list is stocked, before crossing those items off.
const LIST_PATIENCE := 10.0
## The cart and list art: the supermarket pack's own (assets/supermarket/1.png
## carts; the list icons are product sprites StoreArt.gd already uses).
const CART_SHEET := "res://assets/supermarket/1.png"
const CART_SIDE := Rect2i(625, 256, 47, 57) # grey cart, red handle, basket left
const CART_FRONT := Rect2i(678, 170, 37, 70) # grey cart seen end-on, handle up
const CART_SIDE_SCALE := 0.62 # ~29x35 px beside a ~37 px person
const CART_FRONT_SCALE := 0.5 # ~18x35 px
## Cart centre relative to the customer, per CharacterSprite row (up, left,
## down, right). Wheels on the feet line (FEET_AT y=13) beside the body.
const CART_OFFSETS := [Vector2(0, -10), Vector2(-25, -4), Vector2(0, 24), Vector2(25, -4)]
const CART_ITEM_SIZE := 13.0 # px, the copy of each carried item in the basket
const CART_REFRESH := 0.1 # s between re-reads of what's in the cart
## Where the basket's heap sits, in cart-sprite pixels from its centre (side
## view facing left; mirrored facing right), and the copies' scatter.
const CART_BASKET_SIDE := Vector2(-4, -12)
const CART_BASKET_FRONT := Vector2(0, -16)
const CART_HEAP := [Vector2(-5, 3), Vector2(6, 2), Vector2(0, -4), Vector2(-8, -6), Vector2(8, -7), Vector2(1, -11)]
const LIST_ICONS := {
	"Dry Goods": ["res://assets/supermarket/4.png", Rect2i(488, 628, 33, 41)],
	"Produce": ["res://assets/supermarket/4.png", Rect2i(626, 388, 44, 41)],
	"Dairy/Frozen": ["res://assets/supermarket/4.png", Rect2i(447, 675, 19, 43)],
	"Bakery": ["res://assets/supermarket/2.png", Rect2i(722, 244, 44, 45)],
}
const LIST_ICON_SIZE := 13.0
## OCT 2026 PHASE 3B — CELL ROUTING (FOUND BY THE PURCHASE TEST). Shoppers
## walk straight at their target (there's no navigation mesh), which was fine
## while "nearest item" kept them in the hub's own spokes. A list sends them
## to Bakery, which hangs off Dry Goods: the straight line from the door cuts
## through Produce into the sealed Bakery/Produce wall (Main.gd's GRID MAP),
## and a shopper leaned on it until it timed out — likely part of why Bakery
## sold so little before. The open connections a customer may walk, from the
## same map (Break Room and Storage are off limits, see
## _keep_outside_excluded_zones()): Sidewalk-hub, hub-Dry Goods, hub-Produce,
## hub-Dairy/Frozen, Dry Goods-Bakery. Within one cell, or into a cell that
## shares an open edge, the walk stays the plain straight line it always was.
const ROUTE_LINKS := {
	Vector2i(1, 2): [Vector2i(1, 1)],
	Vector2i(1, 1): [Vector2i(1, 2), Vector2i(1, 0), Vector2i(2, 1), Vector2i(0, 1)],
	Vector2i(1, 0): [Vector2i(1, 1), Vector2i(2, 0)],
	Vector2i(2, 0): [Vector2i(1, 0)],
	Vector2i(2, 1): [Vector2i(1, 1)],
	Vector2i(0, 1): [Vector2i(1, 1)],
}
## A doorway waypoint sits this far into the next cell (so reaching it means
## having crossed), and at least this far from the edge's corners.
const ROUTE_STEP_IN := 60.0
const ROUTE_EDGE_MARGIN := 160.0
const LIST_BUBBLE_Y := -44.0 # above the head (a person's art tops out ~-24)

@export var role := "shopper" # "shopper" or "disruptive"
@export var carry_id := 0 # unique negative int, assigned by Main.gd — see Carryable.gd's _find_carrier()
## Multi-item shopping trips (playtest request), shopper-only — set by
## Main.gd at spawn from ITEMS_TARGET_BY_TIER (see that constant's own
## comment for the actual day-tiered numbers and reasoning). How many
## successful purchases this shopper aims to complete before leaving
## voluntarily, tracked by _items_bought below and record_purchase().
@export var items_target := 1
## OCT 2026 PHASE 3B — what this shopper still wants: one section name per
## item (Main.gd's make_shopping_list()). Host-written; reaches every peer in
## the spawn data, then on change through this node's synchronizer, which is
## all the list bubble reads. items_target is now its starting length.
@export var shopping_list := PackedStringArray()
## WEEK 25 — which everyday-clothes look this customer wears (assets/
## characters/customer_<n>.png, 1..LOOK_COUNT). Dealt by the host in
## Main.gd's _spawn_customer() and carried in the spawn data, so every peer
## sees the same face on the same customer.
@export var look_index := 1
const LOOK_COUNT := 6
const CharacterSpriteScript := preload("res://CharacterSprite.gd")
var body_sprite: Sprite2D

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
## Recorded once in _ready(), never updated again. _extend_lifetime_budget()
## measures distance FROM here (not from wherever the customer currently
## happens to be) so the budget reflects the actual worst-case walk for
## this trip regardless of how much browsing/detouring already happened
## before the target was picked.
var _spawn_position := Vector2.ZERO
## The total _lifetime this customer is allowed before _leave() fires —
## starts at MAX_LIFETIME_SHOPPER/DISRUPTIVE and only ever grows, via
## _extend_lifetime_budget(), each time a new, potentially-distant target
## is committed to. See that constant's own header comment.
var _lifetime_budget := 0.0

# --- OCT 2026 PHASE 3B: list + cart (host: shopping state) ---
var _list_made := false # a list was ever drawn (an empty one at spawn is retried)
var _list_wait := 0.0 # seconds nothing left on the list has been stocked
var _checking_out := false
## Host diagnostics, read by the tests: sections picked into the cart, and
## list entries crossed off unbought.
var picked_sections: Array = []
var skipped_sections: Array = []
# (every peer: the drawn cart and bubble)
var _cart: Node2D
var _cart_sprite: Sprite2D
var _cart_items: Node2D
var _cart_row := -1
var _cart_refresh := 0.0
var _cart_names: Array = [] # item names currently drawn in the basket
var _hidden_items: Array = [] # items this peer hid because they're in the cart
var _bubble: Node2D
var _bubble_list := PackedStringArray()

# --- disruptive state ---
var _retarget_timer := 0.0
var _retarget_pos := Vector2.ZERO

# --- generic stuck-detection state (see STALL_* consts above) ---
var _stall_check_timer := 0.0
var _stall_check_pos := Vector2.ZERO
var _stall_count := 0
var _detour_dir := Vector2.ZERO # ZERO = not currently detouring
var _detour_timer := 0.0
## Which side of the intended direction is currently committed to, across
## consecutive detour episodes against the same stall — 1.0, -1.0, or 0.0
## (nothing committed yet: the next stall picks a fresh random side). See
## MAX_DETOUR_EPISODES_PER_SIDE's own comment for the full reasoning.
var _detour_side := 0.0
var _detour_episodes_on_side := 0 # consecutive episodes spent on _detour_side without progress resuming

func _ready() -> void:
	add_to_group("customer")
	reset_physics_interpolation()
	set_physics_process(true)
	target_position = position
	_spawn_position = position
	_lifetime_budget = MAX_LIFETIME_SHOPPER if role == "shopper" else MAX_LIFETIME_DISRUPTIVE * randf_range(DISRUPTIVE_LIFETIME_JITTER, 1.0)
	# PLAYTEST FIX: shelved stock sits on its own layer that players, shoppers
	# and loose stock pass through (Carryable.gd's LAYER_SHELF_STOCK). A
	# disruptive customer's whole job is knocking it off, so it still collides.
	if role == "disruptive":
		collision_mask |= CarryableScript.LAYER_SHELF_STOCK
	_stall_check_pos = position # seed with spawn position, not ZERO — a ZERO default would register a false "moved a huge distance" on the very first check
	# items_target included here (Week 7 multi-item playtest gap): the log
	# previously had no way to distinguish "this shopper was only ever
	# asked to buy 1 item" from "it was asked for 2+ but something stopped
	# it after the first" — see _leave()'s own matching addition below.
	_list_made = not shopping_list.is_empty()
	print("[%s] spawned role=%s carry_id=%d items_target=%d list=%s pos=%s" % [name, role, carry_id, items_target, ",".join(shopping_list), position])
	# Shopper = calm blue-green ("good pressure"), disruptive = red ("bad
	# pressure") — visually distinct at a glance, same reasoning as
	# Player.gd coloring host vs. client differently.
	$Polygon2D.color = Color(0.4, 0.75, 0.8, 1) if role == "shopper" else Color(0.85, 0.25, 0.25, 1)
	# WEEK 25 — real character art; the role color lives on as the ring
	# under the feet (the polygon stays hidden, its rotation code untouched).
	$Polygon2D.visible = false
	body_sprite = CharacterSpriteScript.attach(self, "customer_%d" % look_index, "facing_angle", $Polygon2D.color)
	if role == "shopper":
		_build_cart()
		_build_bubble()
	set_multiplayer_authority(1)

	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	for prop in [".:target_position", ".:facing_angle"]:
		var path := NodePath(prop)
		config.add_property(path)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	# The list: only when it changes (a pickup, a cross-off, a late draw).
	var list_path := NodePath(".:shopping_list")
	config.add_property(list_path)
	config.property_set_replication_mode(list_path, SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE)
	sync.replication_config = config
	sync.name = "Sync" # explicit, identical name on every peer — see Player.gd's note on why an auto-generated name breaks replication
	sync.set_multiplayer_authority(1)
	add_child(sync)

func _physics_process(delta: float) -> void:
	if not Net.is_active():
		return
	if not is_multiplayer_authority():
		return # smoothing happens in _process, see below
	# PLAYTEST BUG FIX ("world keeps simulating during the end-of-day
	# report"): the report used to leave every customer's AI running full
	# speed underneath it — a shopper mid-walk when the day ended could keep
	# walking, pick up, or even complete a purchase for however long the
	# report happened to stay up, which is exactly how an item ended up
	# stranded somewhere unreachable once the NEXT day's force-despawn
	# dropped whatever that customer was carrying at that point. Freezing
	# here (before ANY movement/AI/lifetime-timer work below) means a
	# customer is exactly where the day left it for the whole time the
	# report is up, and force-despawn on Continue always drops an item
	# somewhere the customer was actually standing during active play.
	if get_tree().current_scene.is_day_report_active():
		return

	if _stun_timer > 0.0:
		_stun_timer -= delta
		velocity = _knockback_velocity
		_knockback_velocity = _knockback_velocity.move_toward(Vector2.ZERO, DEFEND_KNOCKBACK_DECEL * delta)
		move_and_slide()
		_push_rigid_bodies(delta)
		target_position = position
		return # normal shopper/disruptive AI suppressed for the whole stun

	_lifetime += delta
	# See _lifetime_budget's own comment / LIFETIME_DISTANCE_MULTIPLIER's
	# header above: one clock, compared against one budget that grows each
	# time a new target is committed to, replacing the old separate
	# browsing-vs-carrying comparisons.
	if _lifetime > _lifetime_budget:
		# OCT 2026 PHASE 3B: out of time mid-list with something in the cart —
		# cross off the rest and check out with it, rather than dumping a
		# cart's worth of stock on the floor. Out of time again at the
		# register (or with an empty cart): leave, as before.
		if role == "shopper" and not _checking_out and not cart_items().is_empty():
			_cross_off(shopping_list.duplicate(), "out of time")
			_start_checkout()
		else:
			_leave()
			return

	_interact_cooldown -= delta
	var dir := Vector2.ZERO
	if role == "shopper":
		dir = _shopper_input(delta)
		_shopper_maybe_interact()
	else:
		dir = _disruptive_input(delta)
	dir = _apply_stuck_avoidance(dir, delta)

	if dir.length() > 0.1:
		_last_move_dir = dir.normalized()
		facing_angle = _last_move_dir.angle()
		$Polygon2D.rotation = facing_angle
	velocity = dir * SPEED
	move_and_slide()
	# PLAYTEST BUG FIX: this used to run for BOTH roles unconditionally —
	# pre-existing since Week 6, not something this session introduced, but
	# rarely triggered before since a shopper's old per-section cashier was
	# right next to whatever it was shopping for. Now that every shopping
	# trip is a long walk across the whole store, shoppers brush past far
	# more shelves along the way, and this let them knock placed items over
	# exactly like a disruptive customer would — "good pressure" and "bad
	# pressure" blurring together, which the brief has asked to keep
	# distinct since Week 6 (see the file header). Disruptive-only now: a
	# shopper just walks past a shelf without disturbing it, matching "should
	# navigate around placed items/players normally."
	if role == "disruptive":
		_push_rigid_bodies(delta)
	target_position = position

## GENERIC STUCK-DETECTION (playtest request — see the STALL_* consts'
## own comment for the full reasoning, including the shelf-sliding
## root-cause fix to the metric itself). Wraps whatever direction
## _shopper_input()/_browse_input()/_disruptive_input() computed — this
## doesn't know or care WHAT the target was, only whether actually trying
## to move toward it is producing real progress. Every STALL_CHECK_INTERVAL
## seconds, projects how far the customer has actually moved onto the
## direction it was trying to move in (a dot product, not a raw distance —
## see the STALL_DISTANCE_THRESHOLD comment for why raw distance let a
## customer sliding along a shelf's face pass this check indefinitely): if
## that projected progress is less than STALL_DISTANCE_THRESHOLD while
## actively trying to move (dir non-zero — a customer intentionally
## standing still, e.g. waiting at the front of a queue, is NOT "stuck" and
## must not trigger this), that counts as a stall; STALL_CHECKS_TO_TRIGGER
## consecutive stalls (~1.5s) means something is physically in the way
## move_and_slide() is sliding along rather than getting past. The reaction
## is a temporary sideways detour — perpendicular to the intended
## direction — blended into the steering for DETOUR_DURATION seconds. This
## project has no navigation mesh to actually repath with (every
## target-seeking function here is "walk in a straight line at the
## target," full stop), so "nudge sideways for a bit, then try the direct
## line again" is the generic fix that works without one — usually enough
## to clear whatever edge it was snagged on, and if not, the stall counter
## just starts climbing again and triggers another detour episode.
##
## PLAYTEST ROOT-CAUSE FIX ("customers sway side-to-side stuck at shelves,
## can't escape" — see MAX_DETOUR_EPISODES_PER_SIDE's own comment for the
## full story): which side (left/right of the intended direction) a NEW
## detour episode picks is no longer an independent coin flip every time.
## _detour_side remembers the committed side across consecutive episodes
## against the same stall, so a customer that needs more than one
## DETOUR_DURATION-long episode to actually clear a wide obstacle keeps
## making headway in the same direction instead of a fresh 50/50 roll
## potentially undoing it. It resets back to "undecided" (0.0) the moment
## real progress resumes (the plain `else` branch below) — that's the
## signal whatever was blocking is now cleared, so a later, unrelated
## stall starts fresh rather than being biased by ancient history.
func _apply_stuck_avoidance(dir: Vector2, delta: float) -> Vector2:
	if _detour_timer > 0.0:
		_detour_timer -= delta
		if _detour_timer <= 0.0:
			_detour_dir = Vector2.ZERO
	_stall_check_timer -= delta
	if _stall_check_timer <= 0.0:
		_stall_check_timer = STALL_CHECK_INTERVAL
		var displacement := global_position - _stall_check_pos
		_stall_check_pos = global_position
		# Progress ALONG the intended heading, not raw distance in any
		# direction — sliding sideways along a long obstacle like a shelf
		# can rack up plenty of raw distance while netting close to zero
		# progress toward the target, which is exactly the "stuck" case
		# this whole system exists to catch (see this function's own header
		# comment and the STALL_DISTANCE_THRESHOLD comment for the story).
		var progress := displacement.dot(dir.normalized()) if dir.length() > 0.1 else 0.0
		if dir.length() > 0.1 and progress < STALL_DISTANCE_THRESHOLD:
			_stall_count += 1
			if _stall_count >= STALL_CHECKS_TO_TRIGGER and _detour_dir == Vector2.ZERO:
				if _detour_side == 0.0:
					_detour_side = 1.0 if randf() < 0.5 else -1.0
				elif _detour_episodes_on_side >= MAX_DETOUR_EPISODES_PER_SIDE:
					_detour_side = -_detour_side # that side isn't working either — try the other one
					_detour_episodes_on_side = 0
				_detour_dir = dir.orthogonal() * _detour_side
				_detour_timer = DETOUR_DURATION
				_detour_episodes_on_side += 1
				_stall_count = 0
		else:
			_stall_count = 0
			_detour_side = 0.0
			_detour_episodes_on_side = 0
	if _detour_dir != Vector2.ZERO and dir.length() > 0.1:
		return (dir + _detour_dir).normalized()
	return dir

func _process(delta: float) -> void:
	if not Net.is_active():
		return
	if _cart != null:
		_update_cart(delta)
	if _bubble != null and shopping_list != _bubble_list:
		_rebuild_bubble()
	if is_multiplayer_authority():
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
	# OCT 2026 PHASE 3B: being rung up is progress — a long cart never times
	# out at the register mid-scan.
	_lifetime_budget = max(_lifetime_budget, _lifetime + LIFETIME_BASE_BUFFER)

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
	# items_bought/items_target included here (Week 7 multi-item playtest
	# gap, matching _ready()'s own addition): "leaving" fires from THREE
	# different causes (satisfied — see _shopper_input()'s
	# _items_bought >= items_target check, lifetime timeout, or a forced
	# day-boundary despawn) that used to be indistinguishable in the log.
	# A shopper leaving with items_bought < items_target on a day that
	# targets more than 1 didn't run out of things to buy — the browsing
	# fallback (_browse_input) never extends the lifetime budget the way
	# committing to a real target does, so a shopper that's simply WAITING
	# for a second item to be stocked (shelves only fill when something —
	# a player, or a stocker bot — carries a floor product onto a slot;
	# customers never stock shelves themselves) can time out looking
	# identical, from outside the log, to one that was only ever asked to
	# buy 1.
	print("[%s] leaving (role=%s, items_bought=%d/%d, skipped=%s, cart=%d)" % [name, role, _items_bought, items_target, ",".join(skipped_sections), cart_items().size()])
	if _committed_cashier and is_instance_valid(_committed_cashier):
		_committed_cashier.get_node("Cashier").leave_queue(carry_id)
	# OCT 2026 PHASE 3B: the whole cart, spread side by side (Carryable.gd's
	# armful drop) so the items don't land in one pile.
	var side := 0
	for carried in cart_items():
		carried.get_node("Carryable").try_drop(carry_id, side)
		side += 1
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
##
## OCT 2026 PHASE 3B: a forced leave (the store closing for cleanup, a new
## shift starting) takes the cart's unpaid items with it — they go back to
## the stockroom, out of play — instead of dumping up to a list's worth of
## stock on the floor beside whatever shelf the shopper was at. Every product
## is reset at the next shift start anyway, and dropped stock that settles
## onto a shelf and is bumped off again counts as cleanup mess (Shelf.gd's
## "knocked"), which a full cart would add where one held item rarely did.
func force_leave() -> void:
	for item in cart_items():
		item.queue_free()
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
			carryable = collider.get_node_or_null("Display") # WEEK 8 floor displays — see Player.gd's matching note
		if carryable == null:
			continue
		var impulse: Vector2 = -collision.get_normal() * PUSH_FORCE * delta
		if carryable.is_multiplayer_authority():
			# Through request_push() (a local call: sender 0, unattributed, as
			# before) so a shelved item is un-shelved before it moves.
			carryable.request_push(impulse)
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

## Called the moment _shopper_input() below commits this customer to a new,
## potentially-distant target — a stocked item to fetch, then later that
## item's checkout — with the target's CURRENT position. Grows
## _lifetime_budget (never shrinks it: max() against whatever's already
## been granted, so a second, nearer target committed to later can't claw
## back time already promised) to comfortably cover the straight-line walk
## from spawn to that target. See LIFETIME_DISTANCE_MULTIPLIER's own header
## comment for the full reasoning.
func _extend_lifetime_budget(target_pos: Vector2) -> void:
	# OCT 2026 PHASE 3B: a list sends a shopper section to section, so the next
	# leg can start far from the door (Dairy -> Bakery crosses the store) —
	# the longer of the two walks, from here or from the spawn.
	var travel_time := maxf(_spawn_position.distance_to(target_pos), global_position.distance_to(target_pos)) / SPEED
	_lifetime_budget = max(_lifetime_budget, _lifetime + LIFETIME_BASE_BUFFER + travel_time * LIFETIME_DISTANCE_MULTIPLIER)

## OCT 2026 PHASE 3B — the list-driven trip (see the file header): fetch
## the nearest stocked item that's on the list, into the cart, until the list
## is done or crossed off; then one trip to the register with the cart.
func _shopper_input(delta: float) -> Vector2:
	if _checking_out:
		if cart_items().is_empty():
			_leave() # all rung up (record_purchase() counted each)
			return Vector2.ZERO
		return _checkout_input()
	if not _list_made:
		# Nothing was stocked when this shopper walked in: browse, and draw
		# the list the moment there's something to put on it.
		if _browse_timer <= 0.0:
			_take_list(get_tree().current_scene.make_shopping_list())
		if not _list_made:
			return _browse_input(delta)
	if _committed_item and (not is_instance_valid(_committed_item) or _item_taken_by_someone_else(_committed_item) or not _is_still_stocked(_committed_item) or not _wanted(_committed_item)):
		_committed_item = null
	if _committed_item == null:
		if shopping_list.is_empty():
			if cart_items().is_empty():
				_leave() # everything on the list was crossed off unbought
				return Vector2.ZERO
			_start_checkout()
			return _checkout_input()
		_committed_item = _find_wanted_item()
		if _committed_item == null:
			# Sold out of everything left on the list: give a restock a
			# moment (browsing), then cross those items off.
			if _list_wait == 0.0:
				_lifetime_budget = max(_lifetime_budget, _lifetime + LIST_PATIENCE + LIFETIME_BASE_BUFFER)
			_list_wait += delta
			if _list_wait >= LIST_PATIENCE:
				_list_wait = 0.0
				_cross_off(shopping_list.duplicate(), "sold out")
			return _browse_input(delta)
		_list_wait = 0.0
		_extend_lifetime_budget(_committed_item.global_position)
	var to_item := _committed_item.global_position - global_position
	if to_item.length() < PICKUP_RANGE:
		return Vector2.ZERO
	return _steer(_committed_item.global_position)

## Carrying the cart to a spot in the shortest cashier queue (NPC cashier +
## queue line, playtest request) and waiting there — Cashier.gd's own watch
## rings each item up once this shopper is at the front. request_join_queue()
## is a plain direct call, not an RPC: Cashier.gd is host-authority and this
## only ever runs on the host too.
func _checkout_input() -> Vector2:
	if _committed_cashier == null or not is_instance_valid(_committed_cashier):
		_committed_cashier = _find_nearest_cashier()
		if _committed_cashier == null:
			return Vector2.ZERO
		var committed_cashier_comp: Node = _committed_cashier.get_node("Cashier")
		committed_cashier_comp.request_join_queue(carry_id)
		_extend_lifetime_budget(committed_cashier_comp.checkout.global_position)
	var cashier: Node = _committed_cashier.get_node("Cashier")
	var target_pos: Vector2 = cashier.queue_slot_position(carry_id)
	var to_target := target_pos - global_position
	if to_target.length() < CHECKOUT_STOP_RANGE:
		return Vector2.ZERO
	return _steer(target_pos)

func _start_checkout() -> void:
	_checking_out = true
	_committed_item = null
	_committed_cashier = null
	# The ring-up itself: CHECKOUT_WAIT_SECONDS an item, on top of the walk
	# (_checkout_input() adds that when it joins a queue).
	_lifetime_budget = max(_lifetime_budget, _lifetime + LIFETIME_BASE_BUFFER + CashierScript.CHECKOUT_WAIT_SECONDS * cart_items().size())
	print("[%s] checking out with %d item(s)" % [name, cart_items().size()])

## Host: a freshly drawn list (Main.gd's make_shopping_list()). An empty one
## changes nothing — this shopper keeps browsing and asks again.
func _take_list(list: PackedStringArray) -> void:
	if list.is_empty():
		return
	shopping_list = list
	items_target = list.size()
	_list_made = true
	print("[%s] list=%s" % [name, ",".join(list)])

## Host: crosses `sections` off the list unbought (one entry each).
func _cross_off(sections: PackedStringArray, why: String) -> void:
	if sections.is_empty():
		return
	var left := shopping_list.duplicate()
	for sec in sections:
		var i := left.find(sec)
		if i >= 0:
			left.remove_at(i)
			skipped_sections.append(sec)
	shopping_list = left
	print("[%s] crossed off %s (%s)" % [name, ",".join(sections), why])

## The section an item belongs to, by its color (the same rule Main.gd's
## note_sale() and Shelf.gd's _color_matches() use).
func _section_of(item: Node) -> String:
	var visual := item.get_node_or_null("Polygon2D") as Polygon2D
	if visual == null:
		return ""
	return get_tree().current_scene._section_of_color(visual.color)

func _wanted(item: Node) -> bool:
	return _section_of(item) in shopping_list

## Host: the nearest item on an open section's shelf that's on the list and
## nobody holds.
func _find_wanted_item() -> Node2D:
	var main = get_tree().current_scene
	var best: Node2D = null
	var best_dist := INF
	for shelf_body in get_tree().get_nodes_in_group("shelf"):
		if not _is_section_unlocked(shelf_body.global_position):
			continue
		if not main._section_name_at(shelf_body.global_position) in shopping_list:
			continue
		for occ in shelf_body.get_node("Shelf").filled_objects():
			if occ.get_node("Carryable").carrier_id != 0 or not _wanted(occ):
				continue
			var d := global_position.distance_to(occ.global_position)
			if d < best_dist:
				best_dist = d
				best = occ
	return best

func _shopper_maybe_interact() -> void:
	if _interact_cooldown > 0.0 or _checking_out:
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
		# On the host the pickup is decided (and broadcast) synchronously.
		if c.carrier_id == carry_id:
			var sec := _section_of(_committed_item)
			var left := shopping_list.duplicate()
			var i := left.find(sec)
			if i >= 0:
				left.remove_at(i)
			shopping_list = left
			picked_sections.append(sec)
			_committed_item = null

## Everything in this shopper's cart, first in first (carry_seq order — the
## order the register rings it up in). Every peer (carrier_id is replicated).
func cart_items() -> Array:
	var out := []
	for obj in get_tree().get_nodes_in_group("carryable"):
		if obj.is_queued_for_deletion():
			continue
		if obj.get_node("Carryable").carrier_id == carry_id:
			out.append(obj)
	out.sort_custom(func(x, y): return x.get_node("Carryable").carry_seq < y.get_node("Carryable").carry_seq)
	return out

## Where Carryable.gd keeps an item this shopper holds: in the cart.
func cart_point() -> Vector2:
	if _cart == null:
		return global_position
	return global_position + _cart.position

## Host: the direction to walk toward `goal`, by the open connections (see
## ROUTE_LINKS): straight at it in the same or a neighbouring cell, else
## through the doorway into the next cell on the way.
func _steer(goal: Vector2) -> Vector2:
	var to := _route_point(goal) - global_position
	return to.normalized() if to.length() > 0.5 else Vector2.ZERO

func _route_point(goal: Vector2) -> Vector2:
	var main = get_tree().current_scene
	var a: Vector2i = main._grid_cell_of(global_position)
	var b: Vector2i = main._grid_cell_of(goal)
	if a == b or not ROUTE_LINKS.has(a) or not ROUTE_LINKS.has(b) or b in ROUTE_LINKS[a]:
		return goal
	var nxt := _route_next(a, b)
	if nxt == a:
		return goal
	# The doorway: across the shared edge, level with where this shopper
	# already is (kept off the edge's ends), ROUTE_STEP_IN into the next cell.
	var w: float = main.ROOM_WIDTH
	var h: float = main.ROOM_HEIGHT
	if nxt.x != a.x:
		var edge_x: float = maxf(a.x, nxt.x) * w
		var y := clampf(global_position.y, a.y * h + ROUTE_EDGE_MARGIN, (a.y + 1) * h - ROUTE_EDGE_MARGIN)
		return Vector2(edge_x + ROUTE_STEP_IN * signf(nxt.x - a.x), y)
	var edge_y: float = maxf(a.y, nxt.y) * h
	var x := clampf(global_position.x, a.x * w + ROUTE_EDGE_MARGIN, (a.x + 1) * w - ROUTE_EDGE_MARGIN)
	return Vector2(x, edge_y + ROUTE_STEP_IN * signf(nxt.y - a.y))

## First step of the shortest open route a -> b (breadth-first over
## ROUTE_LINKS); a itself if there's none.
func _route_next(a: Vector2i, b: Vector2i) -> Vector2i:
	var came := {a: a}
	var frontier: Array = [a]
	while not frontier.is_empty():
		var c: Vector2i = frontier.pop_front()
		if c == b:
			break
		for n in ROUTE_LINKS.get(c, []):
			if not came.has(n):
				came[n] = c
				frontier.append(n)
	if not came.has(b):
		return a
	var step := b
	while came[step] != a:
		step = came[step]
	return step

## --- OCT 2026 PHASE 3B: the cart and list bubble (every peer, cosmetic) -----

static var _region_textures := {}
## One texture per sheet region, shared by every customer.
static func _region_texture(path: String, region: Rect2i) -> Texture2D:
	var key := "%s|%s" % [path, region]
	if not _region_textures.has(key):
		var atlas := AtlasTexture.new()
		atlas.atlas = load(path)
		atlas.region = Rect2(region)
		_region_textures[key] = atlas
	return _region_textures[key]

func _build_cart() -> void:
	_cart = Node2D.new()
	_cart.name = "Cart"
	_cart_sprite = Sprite2D.new()
	_cart_sprite.name = "CartArt"
	_cart_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_cart.add_child(_cart_sprite)
	_cart_items = Node2D.new()
	_cart_items.name = "CartItems"
	_cart.add_child(_cart_items)
	add_child(_cart)
	_set_cart_row(CharacterSpriteScript.ROW_DOWN)

## Faces the cart the way the customer faces: side view to the left or
## right, end-on above (behind the body) or below (in front of it).
func _set_cart_row(r: int) -> void:
	_cart_row = r
	var side := r == CharacterSpriteScript.ROW_LEFT or r == CharacterSpriteScript.ROW_RIGHT
	_cart_sprite.texture = _region_texture(CART_SHEET, CART_SIDE if side else CART_FRONT)
	_cart_sprite.scale = Vector2.ONE * (CART_SIDE_SCALE if side else CART_FRONT_SCALE)
	_cart_sprite.flip_h = r == CharacterSpriteScript.ROW_RIGHT
	_cart.position = CART_OFFSETS[r]
	var basket: Vector2 = CART_BASKET_SIDE if side else CART_BASKET_FRONT
	if r == CharacterSpriteScript.ROW_RIGHT:
		basket.x = -basket.x
	_cart_items.position = basket * _cart_sprite.scale.x
	# Behind the body going up, in front of it otherwise.
	if body_sprite != null:
		move_child(_cart, body_sprite.get_index() if r == CharacterSpriteScript.ROW_UP else get_child_count() - 1)

func _update_cart(delta: float) -> void:
	var r: int = body_sprite.row() if body_sprite != null else CharacterSpriteScript.ROW_DOWN
	if r != _cart_row:
		_set_cart_row(r)
	_cart_refresh -= delta
	if _cart_refresh > 0.0:
		return
	_cart_refresh = CART_REFRESH
	var items := cart_items()
	# The real items ride hidden in the cart; anything that left it (dropped
	# when this shopper left) is shown again.
	for obj in items:
		obj.visible = false
	for obj in _hidden_items:
		if is_instance_valid(obj) and not obj in items:
			obj.visible = true
	_hidden_items = items
	# The item on the register's belt (StoreArt.gd draws it there) is out of
	# the basket.
	if not items.is_empty() and _at_a_register():
		items = items.slice(1)
	var names := items.map(func(o): return o.name)
	if names == _cart_names:
		return
	_cart_names = names
	for ch in _cart_items.get_children():
		ch.queue_free()
	for i in items.size():
		var spr := _item_copy(items[i])
		spr.position = CART_HEAP[i % CART_HEAP.size()] + Vector2(0, -6) * floorf(i / float(CART_HEAP.size()))
		_cart_items.add_child(spr)

## This customer is in purchase range of an active register's Checkout spot
## (where StoreArt.gd's conveyor takes the next item onto the belt).
func _at_a_register() -> bool:
	for cashier_body in get_tree().get_nodes_in_group("cashier"):
		var c: Node = cashier_body.get_node("Cashier")
		if c.active and global_position.distance_to(c.checkout.global_position) <= CashierScript.PURCHASE_RANGE:
			return true
	return false

## A small copy of an item's own art (or, with none, its color).
func _item_copy(item: Node2D) -> Sprite2D:
	var spr := Sprite2D.new()
	var art: Sprite2D = item.get_node_or_null("ProductArt")
	if art != null:
		spr.texture = art.texture
		spr.region_enabled = art.region_enabled
		spr.region_rect = art.region_rect
		var size: Vector2 = art.region_rect.size if art.region_enabled else art.texture.get_size()
		spr.scale = Vector2.ONE * (CART_ITEM_SIZE / maxf(size.x, size.y))
	else:
		var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		spr.texture = ImageTexture.create_from_image(img)
		spr.modulate = (item.get_node("Polygon2D") as Polygon2D).color
		spr.scale = Vector2.ONE * CART_ITEM_SIZE * 0.8
	return spr

func _build_bubble() -> void:
	_bubble = Node2D.new()
	_bubble.name = "ListBubble"
	_bubble.position = Vector2(0, LIST_BUBBLE_Y)
	_bubble.z_index = 5 # over neighbouring shelves and people
	add_child(_bubble)
	_rebuild_bubble()

## A white speech bubble holding one icon per item still wanted (the
## section's own product art), hidden once the list is done.
func _rebuild_bubble() -> void:
	_bubble_list = shopping_list.duplicate()
	for ch in _bubble.get_children():
		ch.queue_free()
	_bubble.visible = not _bubble_list.is_empty()
	if _bubble_list.is_empty():
		return
	var n := _bubble_list.size()
	var step := LIST_ICON_SIZE + 2.0
	var w := n * step + 4.0
	var h := LIST_ICON_SIZE + 6.0
	var bg := Polygon2D.new()
	bg.name = "Bg"
	var pts := PackedVector2Array()
	var hw := w * 0.5
	var hh := h * 0.5
	for p in [Vector2(-hw + 3, -hh), Vector2(hw - 3, -hh), Vector2(hw, -hh + 3), Vector2(hw, hh - 3), Vector2(hw - 3, hh),
			Vector2(3, hh), Vector2(0, hh + 4), Vector2(-3, hh), # the tail, pointing at the head
			Vector2(-hw + 3, hh), Vector2(-hw, hh - 3), Vector2(-hw, -hh + 3)]:
		pts.append(p)
	bg.polygon = pts
	bg.color = Color(1, 1, 1, 0.92)
	_bubble.add_child(bg)
	var edge := Line2D.new()
	edge.points = pts
	edge.closed = true
	edge.width = 1.0
	edge.default_color = Color(0.2, 0.25, 0.3, 0.9)
	_bubble.add_child(edge)
	for i in n:
		var entry: Array = LIST_ICONS.get(_bubble_list[i], [])
		if entry.is_empty():
			continue
		var icon := Sprite2D.new()
		icon.texture = _region_texture(entry[0], entry[1])
		var region: Rect2i = entry[1]
		icon.scale = Vector2.ONE * (LIST_ICON_SIZE / float(maxi(region.size.x, region.size.y)))
		icon.position = Vector2(-hw + 2.0 + step * (i + 0.5), 0)
		_bubble.add_child(icon)

func _exit_tree() -> void:
	for obj in _hidden_items:
		if is_instance_valid(obj):
			obj.visible = true
	_hidden_items = []

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
	return _steer(_browse_pos)

## Biased toward shelves ("browsing" reads as walking up to look at
## shelves, not aimless wandering) with a chance of a plain nearby point so
## it doesn't look like it's beelining to a shelf every single retarget —
## same candidates-plus-random-fallback shape as _pick_disruptive_target()
## below, for the same reason: a shopper here isn't picking a stocked item
## (that's _find_wanted_item's job, checked first in _shopper_input), just
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
		if not _is_section_unlocked(shelf_body.global_position):
			continue
		var shelf: Node = shelf_body.get_node("Shelf")
		var slot_pos = shelf.nearest_empty_slot_position(global_position)
		if slot_pos != null:
			candidates.append(slot_pos)
	if candidates.is_empty() or randf() < 0.3:
		var wander := global_position + Vector2(randf_range(-BROWSE_RADIUS, BROWSE_RADIUS), randf_range(-BROWSE_RADIUS, BROWSE_RADIUS))
		return _keep_outside_excluded_zones(wander)
	return candidates[randi() % candidates.size()]

## PLAYTEST ROOT-CAUSE FIX: shelf/cashier candidates above can never land in
## the break room (neither exists there), but the plain random-offset
## fallback had no such guarantee — a shopper/disruptive customer standing
## near the break room's boundary could roll a wander target that happened
## to fall inside it, for no reason at all (see Main.gd's
## is_break_room_at_pos() for the fuller story on why that's actively
## harmful, not just odd-looking). Nudges a candidate that lands inside an
## excluded zone out to whichever edge is closer instead of picking a whole
## new random point — keeps the wander feeling like a small correction, not
## a teleport. UPGRADED to 2D alongside Main.gd's is_break_room_at_pos():
## an excluded zone is a grid CELL (a column range AND a row range), not
## just an x-range, so "closer edge" means whichever of the cell's four
## sides — not just left/right — the candidate is actually nearest to.
##
## GENERALIZED this session (PLAYTEST BUG FIX "customers can enter
## Storage") from a break-room-only check to a shared helper covering every
## AI-excluded zone: Storage is player-only (WEEK 15: it's the crew's back
## room — loading dock, delivery forklift, receiving — nothing
## there for a customer), same "exclusion zone, not a physical door" treatment the break
## room already established, so it plugs into the exact same nudge rather
## than needing its own parallel copy of this logic.
func _keep_outside_excluded_zones(pos: Vector2) -> Vector2:
	var main = get_tree().current_scene
	if main.is_break_room_at_pos(pos):
		return _push_out_of_cell(pos, main.BREAK_ROOM_GRID_POS, main)
	if main.is_storage_at_pos(pos):
		return _push_out_of_cell(pos, main.STORAGE_GRID_POS, main)
	return pos

## Shared by every branch of _keep_outside_excluded_zones() above — nudges
## `pos` out through whichever of `cell`'s four edges is nearest, 20px past
## the boundary so the result doesn't land right back on the line.
func _push_out_of_cell(pos: Vector2, cell: Vector2i, main) -> Vector2:
	var room_x_start: float = cell.x * main.ROOM_WIDTH
	var room_x_end: float = room_x_start + main.ROOM_WIDTH
	var room_y_start: float = cell.y * main.ROOM_HEIGHT
	var room_y_end: float = room_y_start + main.ROOM_HEIGHT
	# Distance to each of the four edges; push out through whichever is nearest.
	var d_left := pos.x - room_x_start
	var d_right := room_x_end - pos.x
	var d_top := pos.y - room_y_start
	var d_bottom := room_y_end - pos.y
	var smallest: float = min(min(d_left, d_right), min(d_top, d_bottom))
	if smallest == d_left:
		pos.x = room_x_start - 20.0
	elif smallest == d_right:
		pos.x = room_x_end + 20.0
	elif smallest == d_top:
		pos.y = room_y_start - 20.0
	else:
		pos.y = room_y_end + 20.0
	return pos

## Wraps Main.gd's is_break_room_at_pos()/is_storage_at_pos() the same way
## _is_section_unlocked() below wraps is_unlocked_at_pos() — see that
## function's own comment for why this is a live scene-tree lookup rather
## than a preload. Used by _pick_disruptive_target() to keep a player
## standing inside an excluded zone from being offered as a chase target:
## neither zone has a shelf/cashier, so every OTHER candidate source there
## is already naturally empty, but a disruptive customer's player-candidate
## list has no location filter of its own, and a player IS allowed in both
## (Break Room is where players clock in; Storage is player-only, not
## fully unreachable).
##
## PLAYTEST BUG FIX: originally written Storage-only (this session's
## earlier Storage-exclusion fix), which left the exact same gap open for
## the Break Room — a player idling there could still be handed to a
## disruptive customer as a chase target, walking it straight in as a
## bypass around _keep_outside_excluded_zones()'s wander-nudge. Generalized
## to check both, matching that function's own "one shared check covering
## every excluded zone" shape.
func _is_excluded_zone(world_pos: Vector2) -> bool:
	var main = get_tree().current_scene
	return main.is_break_room_at_pos(world_pos) or main.is_storage_at_pos(world_pos)

## Week 6 Part 1 follow-up (playtest feedback): every target search below
## (this one, _find_wanted_item, _find_nearest_cashier,
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
func _is_section_unlocked(world_pos: Vector2) -> bool:
	return get_tree().current_scene.is_unlocked_at_pos(world_pos)

func _item_taken_by_someone_else(item: Node2D) -> bool:
	var c: Node = item.get_node("Carryable")
	return c.carrier_id != 0 and c.carrier_id != carry_id

## WEEK 8 — a shopper only ever COMMITS to a stocked item
## (_find_wanted_item(), above), but nothing used to re-check that while it
## walked over: an item knocked off its shelf mid-approach stayed the
## target, and the shopper would chase it across the floor and buy it
## anyway. That was a rare pre-existing gap (a disruptive customer's bump),
## but a forklift wreck flings a whole shelf's stock at once, and if
## shoppers still bought all of it off the floor the wreck would cost the
## players nothing — no restocking needed. Re-picking the moment it's no
## longer on a shelf keeps "knocked off = has to be restocked before it
## sells" true. Host-only data (Shelf.gd's _occupant), fine since customer
## AI only runs on the host.
func _is_still_stocked(item: Node2D) -> bool:
	for shelf_body in get_tree().get_nodes_in_group("shelf"):
		if shelf_body.get_node("Shelf").contains(item):
			return true
	return false

## Central-checkout consolidation: cashiers no longer live inside any of the
## SECTIONS rooms (they're all in one shared CentralCheckout area — see
## Main.tscn), so the section-lock skip every OTHER target search here still
## uses no longer applies to this one — a cashier's reachability is never
## gated by a Gate, only by whether Main.gd's _configure_cashiers() has
## currently activated that particular station (see Cashier.gd's `active`).
## PLAYTEST BUG FIX ("customers only use one of two active registers on Day
## 2"): this used to just return the geometrically NEAREST active cashier.
## Harmless with a single station, but every customer walks in from
## roughly the same direction (the Sidewalk strip), so with several
## stations active (CASHIER_COUNT_BY_TIER, Day 2+) "nearest" resolved to
## the SAME one station for nearly every shopper — the others sat empty no
## matter how long that one line got. Picks by shortest CURRENT queue
## instead (ties broken by distance, so an empty tie still prefers the
## closer station) — this naturally spreads shoppers across however many
## stations happen to be active that day, instead of piling onto whichever
## one is found/declared first.
func _find_nearest_cashier() -> Node:
	var best: Node = null
	var best_queue_len := INF
	var best_dist := INF
	for cashier_body in get_tree().get_nodes_in_group("cashier"):
		var cashier: Node = cashier_body.get_node("Cashier")
		if not cashier.active:
			continue
		var queue_len: int = cashier.queue_length()
		var d := global_position.distance_to(cashier_body.global_position)
		if queue_len < best_queue_len or (queue_len == best_queue_len and d < best_dist):
			best_queue_len = queue_len
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
##
## PLAYTEST BUG FIX ("customers can enter Storage"; generalized to also
## close the identical Break Room gap): the player-candidate loop below has
## no location filter of its own, unlike every other candidate source here
## (shelf/cashier searches are already empty in both excluded zones, since
## neither has one) — a player IS allowed in Break Room or Storage (that's
## where players clock in / the player-only delivery room), so without
## this check a disruptive customer could still get a legitimate-looking
## committed target that walks it straight into either zone to chase them,
## bypassing the wander-nudge in _keep_outside_excluded_zones() entirely.
## Skipped outright, same "no awareness it exists" treatment
## _is_section_unlocked() already gives a locked section's shelves/
## cashiers, rather than only catching it after the fact.
func _pick_disruptive_target() -> Vector2:
	var candidates: Array[Vector2] = []
	for shelf_body in get_tree().get_nodes_in_group("shelf"):
		if not _is_section_unlocked(shelf_body.global_position):
			continue
		var shelf: Node = shelf_body.get_node("Shelf")
		var occ: RigidBody2D = shelf.any_filled_object()
		if occ:
			candidates.append(occ.global_position)
	for p in get_tree().get_nodes_in_group("player"):
		if not _is_excluded_zone(p.global_position):
			candidates.append(p.global_position)
	if candidates.is_empty() or randf() < 0.3:
		var wander := global_position + Vector2(randf_range(-150.0, 150.0), randf_range(-150.0, 150.0))
		return _keep_outside_excluded_zones(wander)
	return candidates[randi() % candidates.size()]
