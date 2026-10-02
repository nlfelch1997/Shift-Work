extends Sprite2D
## WEEK 25 — real character art for every person in the store: customers,
## cashiers, the manager and the players. Each look is a sheet made with the
## Universal LPC Spritesheet Character Generator (assets/characters/, credits
## in assets/CREDITS.md; how they were made in tools/lpc/): 9 columns (a
## standing frame, then the 8-frame walk cycle) x 4 rows, one per facing —
## up, left, down, right — 64x64 px per frame.
##
## Purely a visual layer. It never moves its owner or touches gameplay
## state, and it needs no networking of its own:
## - facing comes from a property the owner already replicates (Player/
##   Customer `facing_angle`, Manager `facing`) — read every frame, so every
##   peer turns the sprite the same way at the same time;
## - walking vs standing comes from how fast the owner is actually moving
##   on THIS peer's screen (its replicated, interpolated position), so the
##   legs move exactly when the body visibly moves, on every peer;
## - which look is worn is picked once, by the host or by a fixed rule (see
##   Main.gd's spawn data and Cashier.gd), never randomly per peer.
##
## The owners keep their old Polygon2D (hidden) since their code still sets
## its color/rotation; the color lives on as a ring under the feet — the
## host-blue/client-orange player tell and the shopper-teal/disruptive-red
## customer tell (see attach()).

const FRAME := 64
const COLUMNS := 9
const ROWS := 4
const WALK_FRAMES := 8
## The art is drawn ~49 px tall; 0.75 puts a person at ~37 px, a bit taller
## than their 28 px collision box, next to 60 px shelves and 30 px tiles.
const ART_SCALE := 0.75
## Frame pixel right under the feet, and where that lands on the owner
## (the bottom edge of the 28 px box, so the body stands on its collider).
const FEET_PX := Vector2(32, 61)
const FEET_AT := Vector2(0, 13)
const WALK_FPS := 10.0
## Owner speed (px/s, smoothed) above which the walk cycle plays. Slow
## enough that a browsing customer animates, high enough that the jitter of
## a remote peer's interpolation settling doesn't twitch the legs.
const WALK_MIN_SPEED := 14.0
const ROW_UP := 0
const ROW_LEFT := 1
const ROW_DOWN := 2
const ROW_RIGHT := 3
## Extra angle past a 45-degree boundary before the facing row flips — keeps
## a body moving diagonally from strobing between two rows.
const ROW_HYSTERESIS := 0.15

## Look name = file name under assets/characters/ ("customer_3", "manager"...).
var look := ""
## Owner property holding its facing angle (radians, Vector2.angle()
## convention). Empty = never turns (stays on `fixed_row`).
var facing_property := "facing_angle"
var fixed_row := ROW_DOWN
var _row := ROW_DOWN
var _walk_t := 0.0
var _speed := 0.0
var _last_pos := Vector2.INF

static func texture_path(look_name: String) -> String:
	return "res://assets/characters/%s.png" % look_name

## Builds the sprite (plus a colored ring under the feet when ring_color has
## any alpha) on `owner_node` and returns it.
static func attach(owner_node: Node2D, look_name: String, facing_prop: String, ring_color: Color = Color(0, 0, 0, 0)) -> Sprite2D:
	if ring_color.a > 0.0:
		var ring := Polygon2D.new()
		ring.name = "FootRing"
		var pts := PackedVector2Array()
		for i in 20:
			var a := TAU * i / 20.0
			pts.append(FEET_AT + Vector2(cos(a) * 14.0, sin(a) * 6.0) + Vector2(0, -1))
		ring.polygon = pts
		ring.color = Color(ring_color.r, ring_color.g, ring_color.b, 0.6)
		owner_node.add_child(ring)
	var s: Sprite2D = load("res://CharacterSprite.gd").new()
	s.name = "CharacterSprite"
	s.facing_property = facing_prop
	s.set_look(look_name)
	owner_node.add_child(s)
	return s

func set_look(look_name: String) -> void:
	look = look_name
	texture = load(texture_path(look_name))
	hframes = COLUMNS
	vframes = ROWS
	centered = false
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	scale = Vector2(ART_SCALE, ART_SCALE)
	position = FEET_AT - FEET_PX * ART_SCALE
	_row = fixed_row
	frame = _row * COLUMNS

## Row (ROW_*) currently shown — read by the tests.
func row() -> int:
	return _row

## True while the walk cycle is playing — read by the tests.
func is_walking() -> bool:
	return frame % COLUMNS != 0

static func row_for_angle(angle: float) -> int:
	var a := wrapf(angle, -PI, PI)
	if absf(a) <= PI / 4.0:
		return ROW_RIGHT
	if absf(a) >= 3.0 * PI / 4.0:
		return ROW_LEFT
	return ROW_DOWN if a > 0.0 else ROW_UP

static func _row_center(r: int) -> float:
	return [-PI / 2.0, PI, PI / 2.0, 0.0][r]

func _process(delta: float) -> void:
	var owner_node := get_parent() as Node2D
	if owner_node == null:
		return
	if facing_property != "":
		var angle: float = owner_node.get(facing_property)
		if absf(angle_difference(angle, _row_center(_row))) > PI / 4.0 + ROW_HYSTERESIS:
			_row = row_for_angle(angle)
	var p := owner_node.global_position
	if _last_pos != Vector2.INF and delta > 0.0:
		var inst := p.distance_to(_last_pos) / delta
		# A teleport (day start, respawn) is not a walk.
		if inst > 2000.0:
			inst = 0.0
		_speed = lerpf(_speed, inst, clampf(delta * 12.0, 0.0, 1.0))
	_last_pos = p
	if _speed > WALK_MIN_SPEED:
		_walk_t += delta * WALK_FPS
		frame = _row * COLUMNS + 1 + int(_walk_t) % WALK_FRAMES
	else:
		_walk_t = 0.0
		frame = _row * COLUMNS
