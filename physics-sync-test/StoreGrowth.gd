extends Node2D
## PHASE 5B PART 2B — THE STORE GROWS (Plan B, "Grows Outward"), GREYBOX.
## Purely visual, every peer, nothing replicated: what a wing looks like
## before it's bought (an empty lot behind the shop's outside wall) and the
## moment it's bought (the wall comes down, the lot gives way to the wing).
## Every shape here is a code-drawn PLACEHOLDER (docs/store-layout-art-needs.md
## lists the art that replaces each one).
##
## WHAT DECIDES IT. A wing is open exactly when its section is
## (Areas.is_open(), from the replicated sections_owned — the host decides,
## every peer follows). The barrier's collision is Gate.gd's, configured from
## the same state, so a lot can't be walked into before it's bought. This
## script only draws: each lot's cover (gravel ground, construction fence,
## FOR SALE board) and its knock-out wall (the shop's outside wall with a
## FOR SALE banner; a roller shutter for Produce's back door into Storage).
##
## THE MOMENT. areas.area_opened(room) (fired by Main._reconfigure_world() on
## every peer when a section's room opens) starts the knock-out: the wall
## shakes, breaks into chunks that tumble into the wing, dust puffs, and the
## lot fades away to reveal the wing (KNOCK_SECONDS). It plays only for a
## purchase someone just made: the host's purchase announcement
## (Main._announce_purchase(), an RPC every connected peer gets) must arrive
## within ANNOUNCE_WINDOW of the flip, in either order. A wing that is simply
## open when a peer arrives — a late joiner catching up, a save reloading,
## the practice shift ending — snaps open with no animation (and a peer that
## joins mid-animation just sees the result).
##
## DRAW ORDER. The lot cover sits over the wing's own furniture (its shelves,
## pad, can, label, displays stay where they are — they're just not there
## yet) and under the people: Main adds this node just before Players, at
## z_index Z (over floor-level things such as Delivery's pads and the truck,
## Z_TRUCK 3; under Juice/lights/prompts). Nobody can stand in a closed lot,
## so the cover never hides a person; the wall strip is 20 px, like every
## other wall.

## ART SWAP HOOK. Every look here is a code-drawn placeholder until a texture
## is named for it below: put a res:// path in and that placeholder gives way
## to the art (a data change, nothing else). Sizes are world px at the game's
## art scale (a floor tile is 30 px — StoreArt.ART_SCALE; see
## docs/store-layout-art-needs.md for each piece).
const ART := {
	"lot_ground": "", # tiling ground for an unbought wing (gravel / old asphalt), drawn at StoreArt.ART_SCALE
	"fence": "", # tiling construction-fence strip round a lot, 12 px tall
	"for_sale_board": "", # the FOR SALE board mid-lot, 280 x 120 (+ posts): text is drawn over it
	"banner": "", # a FOR SALE banner hung on the knock-out wall, 168 x 18: text is drawn over it
	"shutter": "", # tiling roller-shutter face (Produce's back door), 20 px thick
}

const Z := 4
const ANNOUNCE_WINDOW := 1.5 # s: a flip and a purchase announcement this close are one purchase
const KNOCK_SECONDS := 1.8
const SHAKE_SECONDS := 0.35
const CHUNK_PX := 60.0
const GROUND := Color(0.33, 0.34, 0.31, 1) # gravel / old asphalt
const FENCE := Color(0.72, 0.74, 0.7, 0.9)
const FENCE_POST := Color(0.45, 0.46, 0.44, 1)
const SHUTTER := Color(0.5, 0.52, 0.55, 1)
const BANNER_BG := Color(0.78, 0.14, 0.12, 1)
const SIGN_BG := Color(0.96, 0.95, 0.9, 1)

var main: Node
## section -> {"room", "root" (Node2D), "wall" (Node2D: the knock-out wall pieces),
## "board_text" (Label), "banners" ([Label]), "open", "flip_t", "anim_t"}
var _lots := {}
var _clock := 0.0
var _announced := {} # section -> _clock of its last purchase announcement
var _banner_t := 0.0
## Tests: how many knock-out animations this peer has played, per section.
var animations_played := {}

func _ready() -> void:
	main = get_parent()
	z_index = Z
	var rng := RandomNumberGenerator.new()
	for s in main.SECTIONS:
		var pieces: Array = main.areas.barriers().filter(func(b): return b["section"] == s["name"])
		if pieces.is_empty():
			continue # Dry Goods: the shop itself, always there
		rng.seed = hash(s["name"]) # the same speckles on every peer, every run
		_build_lot(s, pieces, rng)
	main.areas.area_opened.connect(_on_area_changed.bind(true))
	main.areas.area_closed.connect(_on_area_changed.bind(false))

## Main._announce_purchase(), on every peer: someone just bought `sec_name`.
func note_purchase(sec_name: String) -> void:
	_announced[sec_name] = _clock
	var lot: Dictionary = _lots.get(sec_name, {})
	if not lot.is_empty() and lot["open"] and lot["anim_t"] < 0.0 and _clock - float(lot["flip_t"]) <= ANNOUNCE_WINDOW:
		_start_knockout(sec_name)

## "closed" (the lot), "opening" (the knock-out playing), "open" (the wing).
func lot_state(sec_name: String) -> String:
	var lot: Dictionary = _lots.get(sec_name, {})
	if lot.is_empty():
		return "open"
	if not lot["open"]:
		return "closed"
	return "opening" if lot["anim_t"] >= 0.0 else "open"

func _on_area_changed(id: String, now_open: bool) -> void:
	for sec in _lots:
		if _lots[sec]["room"] == id:
			_set_open(sec, now_open, true)

func _process(delta: float) -> void:
	_clock += delta
	for sec in _lots:
		var lot: Dictionary = _lots[sec]
		# Catch-up for state that was already there before the first signal
		# (the registry's first refresh only records): no animation.
		var want: bool = main.areas.is_open(lot["room"])
		if want != lot["open"]:
			_set_open(sec, want, false)
		if lot["anim_t"] >= 0.0:
			_animate(sec, delta)
	_banner_t -= delta
	if _banner_t <= 0.0:
		_banner_t = 0.5
		for sec in _lots:
			var i: int = main.section_index(sec)
			var price := "$%d" % main.section_price(sec)
			var banner := "COMING SOON" if main.tutorial.active else "FOR SALE · %s" % price
			var board := "buy it in a real shift" if main.tutorial.active else (price if i <= main.sections_owned else "%s · after %s" % [price, main.SECTIONS[i - 1]["name"]])
			_lots[sec]["board_text"].text = board
			for b in _lots[sec]["banners"]:
				b.text = banner

func _set_open(sec: String, now_open: bool, from_signal: bool) -> void:
	var lot: Dictionary = _lots[sec]
	if lot["open"] == now_open:
		return
	lot["open"] = now_open
	lot["flip_t"] = _clock
	if not now_open:
		_reset_closed(sec)
		return
	if from_signal and _clock - float(_announced.get(sec, -INF)) <= ANNOUNCE_WINDOW:
		_start_knockout(sec)
	else:
		# Snapped open now; if the announcement turns up within the window
		# (a client whose state arrived first), note_purchase() plays it.
		lot["root"].visible = false

func _start_knockout(sec: String) -> void:
	var lot: Dictionary = _lots[sec]
	_reset_closed(sec) # from the closed look, whatever this peer showed
	lot["anim_t"] = 0.0
	animations_played[sec] = int(animations_played.get(sec, 0)) + 1
	# Dust along every knock-out piece.
	for piece in lot["wall"].get_children():
		for chunk in piece.get_children():
			if chunk.has_meta("home"):
				_dust(lot, chunk.position + piece.position)

func _reset_closed(sec: String) -> void:
	var lot: Dictionary = _lots[sec]
	lot["anim_t"] = -1.0
	var root: Node2D = lot["root"]
	root.visible = true
	root.modulate = Color.WHITE
	for piece in lot["wall"].get_children():
		piece.modulate = Color.WHITE
		for chunk in piece.get_children():
			if chunk.has_meta("home"):
				chunk.position = chunk.get_meta("home")
				chunk.rotation = 0.0
	for d in lot["dust"].get_children():
		d.queue_free()

func _animate(sec: String, delta: float) -> void:
	var lot: Dictionary = _lots[sec]
	var t: float = lot["anim_t"] + delta
	lot["anim_t"] = t
	var root: Node2D = lot["root"]
	var cover: Node2D = lot["cover"]
	# 1. The wall shakes, then 2. its chunks tumble into the wing and fade.
	for piece in lot["wall"].get_children():
		var into: Vector2 = piece.get_meta("into")
		for chunk in piece.get_children():
			if not chunk.has_meta("home"):
				continue
			var home: Vector2 = chunk.get_meta("home")
			if t < SHAKE_SECONDS:
				chunk.position = home + Vector2(randf_range(-2.0, 2.0), randf_range(-2.0, 2.0))
			else:
				var k := clampf((t - SHAKE_SECONDS) / (KNOCK_SECONDS - SHAKE_SECONDS), 0.0, 1.0)
				var ease_k := 1.0 - pow(1.0 - k, 2.0)
				var spin: float = chunk.get_meta("spin")
				chunk.position = home + into * float(chunk.get_meta("throw")) * ease_k
				chunk.rotation = spin * ease_k
		piece.modulate.a = 1.0 - clampf((t - SHAKE_SECONDS) / (KNOCK_SECONDS - SHAKE_SECONDS), 0.0, 1.0)
	# 3. The lot (ground, fence, board) fades to show the wing behind it.
	cover.modulate.a = 1.0 - clampf((t - SHAKE_SECONDS * 0.6) / (KNOCK_SECONDS * 0.8), 0.0, 1.0)
	for d in lot["dust"].get_children():
		var age: float = t - float(d.get_meta("born"))
		d.scale = Vector2.ONE * (0.6 + age * 1.6)
		d.modulate.a = clampf(0.7 - age * 0.55, 0.0, 1.0)
	if t >= KNOCK_SECONDS:
		lot["anim_t"] = -1.0
		root.visible = false
		cover.modulate.a = 1.0

func _dust(lot: Dictionary, at: Vector2) -> void:
	for i in 2:
		var p := Polygon2D.new()
		var pts := PackedVector2Array()
		var r := randf_range(10.0, 18.0)
		for a in 10:
			pts.append(Vector2.RIGHT.rotated(TAU * a / 10.0) * r * randf_range(0.8, 1.1))
		p.polygon = pts
		p.color = Color(0.78, 0.76, 0.72, 0.8)
		p.position = at + Vector2(randf_range(-20.0, 20.0), randf_range(-20.0, 20.0))
		p.set_meta("born", float(lot["anim_t"]) + randf_range(0.0, 0.25))
		lot["dust"].add_child(p)

## --- building one lot (once, at start-up) -----------------------------------

func _build_lot(s: Dictionary, pieces: Array, rng: RandomNumberGenerator) -> void:
	var room: String = s["area"]
	var r: Rect2 = main.areas.rect_of(room)
	var root := Node2D.new()
	root.name = "Lot" + s["node_name"]
	add_child(root)
	var cover := Node2D.new()
	cover.name = "Cover"
	root.add_child(cover)
	# The ground: the whole wing, gravel with a scatter of stones and two ruts.
	var ground := _rect_poly(r, GROUND)
	cover.add_child(ground)
	if _art("lot_ground") != null:
		ground.color = Color.WHITE
		ground.texture = _art("lot_ground")
		ground.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
		ground.texture_scale = Vector2.ONE / 0.625
	for i in (0 if _art("lot_ground") != null else 220):
		var dot := Polygon2D.new()
		var c := Vector2(rng.randf_range(r.position.x, r.end.x), rng.randf_range(r.position.y, r.end.y))
		var sz := rng.randf_range(2.0, 5.0)
		dot.polygon = PackedVector2Array([c, c + Vector2(sz, 0), c + Vector2(sz, sz), c + Vector2(0, sz)])
		dot.color = GROUND.lightened(rng.randf_range(0.08, 0.3)) if rng.randf() < 0.6 else GROUND.darkened(rng.randf_range(0.1, 0.3))
		cover.add_child(dot)
	for i in (0 if _art("lot_ground") != null else 2):
		var rut := Line2D.new()
		var y0 := rng.randf_range(r.position.y + 80.0, r.end.y - 80.0)
		rut.points = PackedVector2Array([Vector2(r.position.x + 40.0, y0), Vector2(r.get_center().x, y0 + rng.randf_range(-60.0, 60.0)), Vector2(r.end.x - 40.0, y0 + rng.randf_range(-90.0, 90.0))])
		rut.width = 10.0
		rut.default_color = GROUND.darkened(0.18)
		cover.add_child(rut)
	# The construction fence round the lot, inside its edges.
	var f := r.grow(-14.0)
	var corners := [f.position, Vector2(f.end.x, f.position.y), f.end, Vector2(f.position.x, f.end.y), f.position]
	var fence := Line2D.new()
	fence.points = PackedVector2Array(corners)
	fence.width = 3.0
	fence.default_color = FENCE
	if _art("fence") != null:
		fence.width = 12.0
		fence.default_color = Color.WHITE
		fence.texture = _art("fence")
		fence.texture_mode = Line2D.LINE_TEXTURE_TILE
		fence.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	cover.add_child(fence)
	for i in 4:
		var a: Vector2 = corners[i]
		var b: Vector2 = corners[i + 1]
		var n := int(a.distance_to(b) / 60.0)
		for k in n + 1:
			var p: Vector2 = a.lerp(b, float(k) / maxf(1.0, n))
			cover.add_child(_rect_poly(Rect2(p - Vector2(3, 3), Vector2(6, 6)), FENCE_POST))
	# The FOR SALE board, mid-lot.
	var board := Node2D.new()
	board.position = r.get_center()
	cover.add_child(board)
	board.add_child(_rect_poly(Rect2(-96, 50, 8, 46), FENCE_POST))
	board.add_child(_rect_poly(Rect2(88, 50, 8, 46), FENCE_POST))
	if _art("for_sale_board") != null:
		board.add_child(_sprite(_art("for_sale_board"), Rect2(-140, -64, 280, 120)))
	else:
		board.add_child(_rect_poly(Rect2(-140, -64, 280, 120), Color(0.2, 0.2, 0.2, 1)))
		board.add_child(_rect_poly(Rect2(-134, -58, 268, 108), SIGN_BG))
	board.add_child(_label("FOR SALE", Vector2(-134, -56), Vector2(268, 40), 32, BANNER_BG))
	board.add_child(_label("%s WING" % s["name"].to_upper(), Vector2(-134, -14), Vector2(268, 26), 18, Color(0.15, 0.15, 0.15)))
	var board_text := _label("", Vector2(-134, 14), Vector2(268, 26), 15, Color(0.25, 0.25, 0.25))
	board.add_child(board_text)
	# The knock-out wall(s): the shop's outside wall (or the back door's
	# shutter), in chunks so it can come down.
	var wall := Node2D.new()
	wall.name = "Wall"
	root.add_child(wall)
	var banners := []
	var face: Texture2D = main.get_node("StoreArt").market_wall_face() if main.has_node("StoreArt") else null
	for b in pieces:
		var br: Rect2 = b["rect"]
		var along_x := br.size.x > br.size.y
		var piece := Node2D.new()
		piece.position = br.get_center()
		# Into the wing: from the barrier's line toward the room's centre.
		var into: Vector2 = (r.get_center() - br.get_center())
		into = Vector2(signf(into.x), 0.0) if not along_x else Vector2(0.0, signf(into.y))
		piece.set_meta("into", into)
		wall.add_child(piece)
		var length: float = br.size.x if along_x else br.size.y
		var n := maxi(1, int(round(length / CHUNK_PX)))
		for k in n:
			var a := -length * 0.5 + length * k / n
			var seg := Rect2(Vector2(a, -10.0), Vector2(length / n, 20.0)) if along_x else Rect2(Vector2(-10.0, a), Vector2(20.0, length / n))
			var chunk := Node2D.new()
			var home := seg.get_center()
			chunk.position = home
			chunk.set_meta("home", home)
			chunk.set_meta("throw", rng.randf_range(24.0, 80.0))
			chunk.set_meta("spin", rng.randf_range(-1.6, 1.6))
			var local := Rect2(seg.position - home, seg.size)
			if b.get("back_door", false):
				var face_poly := _rect_poly(local, SHUTTER)
				if _art("shutter") != null:
					face_poly.color = Color.WHITE
					face_poly.texture = _art("shutter")
					face_poly.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
				chunk.add_child(face_poly)
				var slat := Line2D.new()
				slat.points = PackedVector2Array([local.position + Vector2(0, 10), local.position + Vector2(local.size.x, 10)]) if along_x else PackedVector2Array([local.position + Vector2(10, 0), local.position + Vector2(10, local.size.y)])
				slat.width = 2.0
				slat.default_color = SHUTTER.darkened(0.3)
				chunk.add_child(slat)
			else:
				var strip := _rect_poly(local, Color.WHITE if face else Color(0.35, 0.5, 0.75))
				if face:
					strip.texture = face
					strip.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
					strip.texture_scale = Vector2.ONE * (96.0 / 20.0)
				chunk.add_child(strip)
			piece.add_child(chunk)
		if b.get("back_door", false):
			continue
		# FOR SALE banners hung along the wall, every ~300 px.
		var m := maxi(1, int(length / 320.0))
		for k in m:
			var at := -length * 0.5 + length * (k + 0.5) / m
			var holder := Node2D.new()
			holder.position = Vector2(at, 0.0) if along_x else Vector2(0.0, at)
			holder.rotation = 0.0 if along_x else -PI * 0.5
			holder.add_child(_sprite(_art("banner"), Rect2(-84, -9, 168, 18)) if _art("banner") != null else _rect_poly(Rect2(-84, -9, 168, 18), BANNER_BG))
			var lab := _label("", Vector2(-84, -10), Vector2(168, 20), 12, Color(1, 0.96, 0.9))
			holder.add_child(lab)
			banners.append(lab)
			piece.add_child(holder)
	var dust := Node2D.new()
	dust.name = "Dust"
	root.add_child(dust)
	_lots[s["name"]] = {"room": room, "root": root, "cover": cover, "wall": wall, "dust": dust,
		"board_text": board_text, "banners": banners, "open": false, "flip_t": -INF, "anim_t": -1.0}

## The art named for `key` in ART (null = keep the placeholder).
func _art(key: String) -> Texture2D:
	var path: String = ART.get(key, "")
	return load(path) if path != "" and ResourceLoader.exists(path) else null

func _sprite(tex: Texture2D, r: Rect2) -> Sprite2D:
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.centered = false
	spr.position = r.position
	spr.scale = r.size / tex.get_size()
	return spr

func _rect_poly(r: Rect2, c: Color) -> Polygon2D:
	var p := Polygon2D.new()
	p.polygon = PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])
	p.color = c
	return p

func _label(text: String, pos: Vector2, size: Vector2, font: int, c: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.size = size
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", font)
	l.add_theme_color_override("font_color", c)
	return l
