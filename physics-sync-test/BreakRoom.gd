extends Node2D
## WEEK 23 — THE BREAK ROOM, DRESSED: furniture, a vending machine, the real
## Employee of the Month photo, and the COFFEE MACHINE (the one new mechanic).
## Built in code by Main.gd's _ready() (explicit name "BreakRoomProps", same on
## every peer — its synchronizer's path has to match, see Player.gd's note),
## drawn under Players like the time clock and the tool station.
##
## SET DRESSING (every peer, purely visual): Kelano Studio's Pixel Furniture
## sheet (assets/breakroom-furniture/PixelFurniture.png, 5x4 grid of 32px
## cells — 20 objects, not 30) and karsiori's CC0 vending machines. Like the
## tool station and the time clock, NONE of it has collision: nothing to snag
## a player, a thrown product or a test bot's straight-line walk on, and
## nothing can block a station. Layout (break room = grid cell (0,0), floor
## x 20..940, y 20..520):
##   top wall, left -> right: fridge, sink counter, COFFEE MACHINE (on a
##     cabinet), binder shelf, [Employee of the Month frame, unchanged at
##     (480,140)], vending machine, cubby shelf.
##   bottom-left: two staff lockers; left-middle: the table and two chairs.
##   bottom-right: two armchairs (the lounge corner).
##   Unchanged and clear of every prop: the tool station (700,280), the time
##   clock (880,300), the four spawn spots (220px around (480,270)), and the
##   whole east side (the open boundary into Dry Goods).
## The sheet has no coffee machine: it is drawn here (PLACEHOLDER ART,
## polygons) on top of the sheet's small cabinet.
##
## THE COFFEE MACHINE (locked design: per-shift, paid out of the shift's own
## payout, NOT from a wallet):
## - E at the machine, empty-handed, while a shift runs (prep or selling — not
##   cleanup, not the report) -> one cup for THAT PLAYER, once per shift.
## - Effect: +COFFEE_SPEED_BONUS walking speed (carrying or not — this game
##   has no separate carry speed: Player.speed() is the one number) for the
##   rest of the shift, cleanup included. Gone at the next shift's start.
## - STACKING (design call): ADDITIVE with Comfy Sneakers — speed =
##   SPEED x (1 + 0.08 x sneaker level + 0.20 x coffee). Max 1.44x (sneakers 3
##   + coffee) vs 1.488x multiplicative; additive keeps each source's number
##   honest ("+20%" really is +20 points) and the top end tamer.
## - COST, charged when the shift is paid, not now — you don't know yet what
##   the shift will pay:
##     story days: COFFEE_COST_DOLLARS per cup off Pay Today (and the week's
##       pay). Pay is the crew's, so every cup comes off the same number.
##     endless shifts: COFFEE_COST_BUCKS per cup off the shift's Bucks,
##       PER HEAD (cups x cost / crew, like sales/orders/write-ups in
##       Endless.compute_payout()), after the star multiplier, never below 0.
##       The shift's Pay ($) — the medal score — is untouched: coffee costs
##       Bucks there, not medal progress.
## - MULTIPLAYER (design call, flagged): PER PLAYER, SHARED TAB. A cup boosts
##   only whoever drank it; its cost comes out of the crew's shared payout.
##   So one player's coffee is the whole crew's bill — the comedic version of
##   the risk/reward, and the report names who had one.
## - Host-authoritative, like the time clock: any peer asks
##   (_request_coffee), the host checks the asker is at the machine, the
##   shift is running and they haven't had one, then writes coffee_peers.
##   coffee_peers / coffee_cups_today / coffee_cups_week ride CoffeeSync,
##   ON_CHANGE (reliable). Movement is owner-authoritative, so each owner
##   reads its own replicated copy in Player.speed(), exactly how the
##   sneakers' level already reaches every peer.
## - The vending machine is FLAVOR ONLY: E shows a local joke line. No RPC,
##   no state, no effect on anything.

## Placeholder numbers — FLAGGED for a playtest. A solo day pays ~$150-370 at
## $10 a sale; a cup is four sales. A solo endless shift pays ~25-80 Bucks.
const COFFEE_COST_DOLLARS := 40
const COFFEE_COST_BUCKS := 5
const COFFEE_SPEED_BONUS := 0.2
const COFFEE_TOAST := Color(1, 0.8, 0.45)

const COFFEE_POS := Vector2(180.0, 66.0) # the machine's footprint centre
const COFFEE_RANGE := 70.0
const VENDING_POS := Vector2(610.0, 70.0)
const VENDING_RANGE := 70.0

const FURNITURE_SHEET := "res://assets/breakroom-furniture/PixelFurniture.png"
const VENDING_TEXTURE := "res://assets/vending-machines/Vending Machine 2.1.png"
const PHOTO_TEXTURE := "res://assets/breakroom-furniture/Employee of the Month.webp"
## Tight boxes of the sheet's objects (measured off the PNG's alpha).
const R_TABLE := Rect2i(4, 9, 24, 19)
const R_CHAIR := Rect2i(40, 5, 16, 23)
const R_BOOKSHELF := Rect2i(69, 5, 22, 24)
const R_SINK := Rect2i(68, 68, 24, 26)
const R_FRIDGE := Rect2i(103, 68, 18, 26)
const R_CABINET := Rect2i(135, 77, 18, 17)
const R_LOWSHELF := Rect2i(4, 101, 23, 19)
const R_WARDROBE := Rect2i(36, 98, 24, 29)
const R_ARMCHAIR := Rect2i(69, 101, 22, 22)
const PROP_SCALE := 2.5
const WALL_Y := 22.0 # the top wall's inner face: wall props stand on it
const COFFEE_TOP_Y := 25.0 # the brewer's lid, just off the wall
## The photo's crop (1024x559 source): CaseOh and the cat, portrait, sized to
## the frame's 90x110 photo window (the frame itself is Main.tscn's, unchanged).
const PHOTO_REGION := Rect2i(395, 20, 420, 513)
const PHOTO_SIZE := Vector2(90.0, 110.0)

const VENDING_LINES := [
	"The machine takes your dollar. The machine keeps your dollar.",
	"B4 is jammed. B4 has always been jammed.",
	"You stare at the chips. The chips stare back. You have work to do.",
	"A bag of pretzels hangs on the coil, just out of reach. Forever.",
	"\"EXACT CHANGE ONLY.\" Nobody has had exact change since 2009.",
]

## --- Replicated (CoffeeSync, ON_CHANGE, host authority). Reassigned, never
## mutated, so a change is plainly a new value to the synchronizer.
var coffee_peers: Dictionary = {} # peer_id -> true: had a cup this shift
var coffee_cups_today := 0
var coffee_cups_week := 0
## Host diagnostics (tests): cups actually poured / requests refused.
var cups_poured := 0
var cups_refused := 0

var main: Node
var _coffee_hint: Label
var _vending_hint: Label
var _vending_line_left := 0.0
var _vending_line_index := 0
var _steam: Array[Polygon2D] = []
var _steam_t := 0.0

func _ready() -> void:
	main = get_parent()
	# Pixel art at 2.5x: nearest, or it smears. (The photo overrides it.)
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	for prop in [".:coffee_peers", ".:coffee_cups_today", ".:coffee_cups_week"]:
		var path := NodePath(prop)
		config.add_property(path)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE)
	sync.replication_config = config
	sync.name = "CoffeeSync"
	sync.set_multiplayer_authority(1)
	add_child(sync)
	_build_props()
	_build_coffee_machine()
	_build_vending_machine()
	_fill_photo()

## --- Set dressing --------------------------------------------------------------

## A sheet object, its bottom-centre at `foot` (so wall props line up on the
## wall's face whatever their height).
func _prop(region: Rect2i, foot: Vector2, scale_factor := PROP_SCALE, prop_name := "") -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = load(FURNITURE_SHEET)
	s.region_enabled = true
	s.region_rect = Rect2(region)
	s.scale = Vector2.ONE * scale_factor
	s.position = foot - Vector2(0, region.size.y * scale_factor * 0.5)
	if prop_name != "":
		s.name = prop_name
	add_child(s)
	return s

func _wall_prop(region: Rect2i, x: float, prop_name: String) -> Sprite2D:
	return _prop(region, Vector2(x, WALL_Y + region.size.y * PROP_SCALE), PROP_SCALE, prop_name)

func _build_props() -> void:
	# Kitchen run along the top wall (the coffee machine goes between the
	# sink and the shelf: _build_coffee_machine()).
	_wall_prop(R_FRIDGE, 62.0, "Fridge")
	_wall_prop(R_SINK, 118.0, "Sink")
	_wall_prop(R_BOOKSHELF, 300.0, "BinderShelf")
	_wall_prop(R_LOWSHELF, 800.0, "CubbyShelf")
	# Staff lockers, bottom-left corner, standing on the bottom wall.
	_prop(R_WARDROBE, Vector2(58, 512), PROP_SCALE, "LockerA")
	_prop(R_WARDROBE, Vector2(120, 512), PROP_SCALE, "LockerB")
	# The table and its chairs (chairs first: the table draws over their
	# legs, so they read as pulled up to it).
	_prop(R_CHAIR, Vector2(222, 404), PROP_SCALE, "ChairL")
	_prop(R_CHAIR, Vector2(338, 404), PROP_SCALE, "ChairR")
	_prop(R_TABLE, Vector2(280, 420), 3.0, "Table")
	_build_mug(Vector2(266, 378))
	# The lounge corner, bottom-right, clear of the time clock.
	_prop(R_ARMCHAIR, Vector2(790, 510), PROP_SCALE, "ArmchairA")
	_prop(R_ARMCHAIR, Vector2(868, 510), PROP_SCALE, "ArmchairB")

## Somebody's abandoned mug on the table.
func _build_mug(pos: Vector2) -> void:
	var mug := Polygon2D.new()
	mug.name = "Mug"
	mug.position = pos
	mug.polygon = PackedVector2Array([-4, -5, 4, -5, 4, 5, -4, 5])
	mug.color = Color(0.95, 0.95, 0.92)
	add_child(mug)
	var handle := Polygon2D.new()
	handle.polygon = PackedVector2Array([4, -2, 7, -2, 7, 3, 4, 3])
	handle.color = Color(0.95, 0.95, 0.92)
	mug.add_child(handle)
	var top := Polygon2D.new()
	top.polygon = PackedVector2Array([-3, -5, 3, -5, 3, -3, -3, -3])
	top.color = Color(0.35, 0.2, 0.1)
	mug.add_child(top)

## PLACEHOLDER ART (no coffee machine in either pack): a dark brewer on the
## sheet's small cabinet — reservoir, spout, a glass carafe half full, a red
## power light, a wisp of steam — plus a little "COFFEE" sign.
func _build_coffee_machine() -> void:
	# The cabinet's foot level with the sink's, so the counter run lines up;
	# the brewer stands on it, its top just off the wall face.
	var foot_y := WALL_Y + R_SINK.size.y * PROP_SCALE
	var stand := _prop(R_CABINET, Vector2(COFFEE_POS.x, foot_y), PROP_SCALE, "CoffeeStand")
	var top_y := COFFEE_TOP_Y
	var cab_top: float = stand.position.y - R_CABINET.size.y * PROP_SCALE * 0.5 + 4.0
	var node := Node2D.new()
	node.name = "CoffeeMachine"
	node.position = Vector2(COFFEE_POS.x, cab_top)
	add_child(node)
	var h := cab_top - top_y # how tall the brewer stands above the cabinet
	_poly(node, [Vector2(-17, -h), Vector2(17, -h), Vector2(17, 0), Vector2(-17, 0)], Color(0.16, 0.16, 0.18))
	_poly(node, [Vector2(-17, -h), Vector2(17, -h), Vector2(17, -h + 7), Vector2(-17, -h + 7)], Color(0.26, 0.26, 0.3)) # lid
	_poly(node, [Vector2(-12, -h + 9), Vector2(12, -h + 9), Vector2(12, -h + 12), Vector2(-12, -h + 12)], Color(0.08, 0.08, 0.1)) # spout
	_poly(node, [Vector2(-10, -14), Vector2(10, -14), Vector2(12, -1), Vector2(-12, -1)], Color(0.75, 0.85, 0.9, 0.55)) # carafe glass
	_poly(node, [Vector2(-11, -8), Vector2(11, -8), Vector2(12, -1), Vector2(-12, -1)], Color(0.32, 0.18, 0.08)) # coffee
	_poly(node, [Vector2(12, -10), Vector2(16, -10), Vector2(16, -5), Vector2(12, -5)], Color(0.1, 0.1, 0.1)) # handle
	_poly(node, [Vector2(-15, -h + 2), Vector2(-12, -h + 2), Vector2(-12, -h + 5), Vector2(-15, -h + 5)], Color(1, 0.2, 0.15)) # power light
	for i in 2:
		var wisp := _poly(node, [Vector2(-1.5, 0), Vector2(1.5, 0), Vector2(2.5, -8), Vector2(-0.5, -8)], Color(1, 1, 1, 0.5))
		wisp.position = Vector2(-4 + 8 * i, -h - 2)
		_steam.append(wisp)
	var sign_label := _label("COFFEE", 9, Color(1, 0.95, 0.85))
	sign_label.position = Vector2(COFFEE_POS.x - 40, foot_y + 1)
	sign_label.size = Vector2(80, 12)
	_coffee_hint = _hint_label(Vector2(COFFEE_POS.x + 60, foot_y + 14))

func _build_vending_machine() -> void:
	var s := Sprite2D.new()
	s.name = "VendingMachine"
	s.texture = load(VENDING_TEXTURE)
	var tex_size: Vector2 = s.texture.get_size()
	s.position = Vector2(VENDING_POS.x, WALL_Y + tex_size.y * 0.5)
	add_child(s)
	_vending_hint = _hint_label(Vector2(VENDING_POS.x, WALL_Y + tex_size.y + 6))

## The real photo into Main.tscn's empty frame (its grey Photo polygon is the
## size reference and stays under the picture as the mat).
func _fill_photo() -> void:
	var holder: Node2D = main.get_node_or_null("BreakRoom/EmployeePhoto")
	if holder == null:
		return
	var s := Sprite2D.new()
	s.name = "PhotoImage"
	s.texture = load(PHOTO_TEXTURE)
	s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	s.region_enabled = true
	s.region_rect = Rect2(PHOTO_REGION)
	s.scale = Vector2(PHOTO_SIZE.x / PHOTO_REGION.size.x, PHOTO_SIZE.y / PHOTO_REGION.size.y)
	holder.add_child(s)
	holder.move_child(s, holder.get_node("Photo").get_index() + 1)

func _poly(parent: Node, pts: Array, color: Color) -> Polygon2D:
	var p := Polygon2D.new()
	p.polygon = PackedVector2Array(pts)
	p.color = color
	parent.add_child(p)
	return p

func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	add_child(l)
	return l

## Same look as the time clock's "E: clock out" prompt.
func _hint_label(center: Vector2) -> Label:
	var l := _label("", 13, Color(0.55, 0.9, 1))
	l.position = center - Vector2(160, 0)
	l.size = Vector2(320, 20)
	l.z_index = 5
	l.visible = false
	return l

## --- Coffee: reads (every peer) -------------------------------------------------

func near_coffee(pos: Vector2) -> bool:
	return pos.distance_to(COFFEE_POS) <= COFFEE_RANGE

func near_vending(pos: Vector2) -> bool:
	return pos.distance_to(VENDING_POS) <= VENDING_RANGE

func has_coffee(peer_id: int) -> bool:
	return coffee_peers.has(peer_id)

## Added to the sneakers' multiplier in Player.speed() (the additive stack).
func speed_bonus(peer_id: int) -> float:
	return COFFEE_SPEED_BONUS if has_coffee(peer_id) else 0.0

## Coffee's cut from a story day's Pay ($). 0 on an endless shift: there it
## comes out of the Bucks (endless_bucks_cost()), and Pay stays the score.
func dollars_today() -> int:
	return 0 if main.is_endless() else coffee_cups_today * COFFEE_COST_DOLLARS

func dollars_week() -> int:
	return coffee_cups_week * COFFEE_COST_DOLLARS

## Per head, like the rest of an endless payout (see the header).
static func bucks_cost(cups: int, crew: int) -> int:
	return int(round(float(cups * COFFEE_COST_BUCKS) / maxi(1, crew)))

## Can a cup be poured right now? (The shift's running, the store isn't
## closing up, the report isn't up.) The host decides; peers use it for the
## prompt only.
func coffee_open() -> bool:
	return main.shift_active and not main.cleanup_active and not main.is_day_report_active()

## Who had a cup this shift, by display name, for the report.
func drinkers_text() -> String:
	var names := []
	for id in coffee_peers:
		names.append(main.player_display_name(id))
	return ", ".join(names)

## --- Coffee: requests (any peer asks, the host acts) -----------------------------

## Player.gd: the local player pressed E, empty-handed, at the machine.
func try_buy_coffee() -> void:
	if multiplayer.is_server():
		buy_coffee(multiplayer.get_unique_id())
	else:
		_request_coffee.rpc_id(1)

@rpc("any_peer", "reliable")
func _request_coffee() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	# Where the HOST sees the sender — no ordering coffee from aisle three.
	if main.players.has(sender) and near_coffee(main.players[sender].global_position):
		buy_coffee(sender)
	else:
		cups_refused += 1

## Host-only. One cup per player per shift; two presses in the same instant
## pour one.
func buy_coffee(peer_id: int) -> bool:
	if not multiplayer.is_server():
		return false
	if not coffee_open() or has_coffee(peer_id) or not main.players.has(peer_id):
		cups_refused += 1
		return false
	var next := coffee_peers.duplicate()
	next[peer_id] = true
	coffee_peers = next
	coffee_cups_today += 1
	coffee_cups_week += 1
	cups_poured += 1
	print("[Coffee] %s had a cup (%d today) — +%d%% speed this shift; %s at payday" % [main.player_display_name(peer_id), coffee_cups_today, roundi(COFFEE_SPEED_BONUS * 100.0), ("-%d Bucks per cup, per head" % COFFEE_COST_BUCKS) if main.is_endless() else ("-$%d" % COFFEE_COST_DOLLARS)])
	_announce_coffee.rpc(peer_id)
	return true

## Every peer: the toast (the state itself is already on CoffeeSync).
@rpc("authority", "call_local", "reliable")
func _announce_coffee(peer_id: int) -> void:
	var cost := ("%d Bucks" % COFFEE_COST_BUCKS) if main.is_endless() else ("$%d" % COFFEE_COST_DOLLARS)
	var whose := "this shift's Bucks" if main.is_endless() else "today's pay"
	if Net.is_active() and peer_id == multiplayer.get_unique_id():
		main.show_toast("COFFEE! +%d%% speed this shift — %s comes out of %s" % [roundi(COFFEE_SPEED_BONUS * 100.0), cost, whose], COFFEE_TOAST)
		Sfx.play("ui_buy")
	else:
		main.show_toast("%s grabbed a coffee — %s off %s" % [main.player_display_name(peer_id), cost, whose], COFFEE_TOAST)
	main.juice.coffee(peer_id) # WEEK 27

## Host-only, from Main._start_shift(): a fresh pot every shift.
func reset_for_new_shift() -> void:
	if not multiplayer.is_server():
		return
	coffee_peers = {}
	coffee_cups_today = 0

## Host-only, from Main._finish_story(): the week's tab closes with the week.
func reset_week() -> void:
	if multiplayer.is_server():
		coffee_cups_week = 0

## --- Vending machine: flavor only (local) ----------------------------------------

func poke_vending() -> void:
	_vending_line_left = 3.0
	_vending_line_index = (_vending_line_index + 1) % VENDING_LINES.size()

## --- Every frame (every peer): prompts and steam ----------------------------------

func _process(delta: float) -> void:
	_steam_t += delta
	for i in _steam.size():
		var phase := fmod(_steam_t * 0.6 + i * 0.5, 1.0)
		_steam[i].position.y = -_steam_h() - 2.0 - phase * 10.0
		_steam[i].modulate.a = (1.0 - phase) * 0.8
	_vending_line_left = maxf(0.0, _vending_line_left - delta)
	var me := multiplayer.get_unique_id() if Net.is_active() else 1
	var p = main.players.get(me)
	var here: bool = p != null and is_instance_valid(p) and not main.is_day_report_active()
	if here and near_coffee(p.global_position) and main.shift_active:
		_coffee_hint.visible = true
		if has_coffee(me):
			_coffee_hint.text = "Already had your cup. Your hands are shaking."
		elif coffee_open():
			var cost := ("-%d Bucks" % COFFEE_COST_BUCKS) if main.is_endless() else ("-$%d at payday" % COFFEE_COST_DOLLARS)
			_coffee_hint.text = "E: coffee  (+%d%% speed this shift, %s)" % [roundi(COFFEE_SPEED_BONUS * 100.0), cost]
		else:
			_coffee_hint.text = "The pot's been cleaned out for the night."
	else:
		_coffee_hint.visible = false
	if _vending_line_left > 0.0:
		_vending_hint.visible = true
		_vending_hint.text = VENDING_LINES[_vending_line_index]
	else:
		_vending_hint.visible = here and near_vending(p.global_position)
		_vending_hint.text = "E: vending machine"

func _steam_h() -> float:
	var node := get_node("CoffeeMachine") as Node2D
	return node.position.y - COFFEE_TOP_Y
