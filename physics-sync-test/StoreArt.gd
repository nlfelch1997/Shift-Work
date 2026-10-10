extends Node2D
## WEEK 13 — ART PASS, FLOORS + WALLS ONLY. Purely visual: nothing here has
## collision, reads game state, or is replicated. Built in code from Main.gd's
## _ready() (nothing new in a .tscn — see Main.gd's header note on .tscn
## comments), BEFORE Main caches the original floor colors, so the existing
## locked-section dimming (_apply_section_lock_visuals(), which multiplies
## each RoomBackgrounds polygon's color) keeps working unchanged on the new
## textured floors.
##
## THE PACKS (both RPG Maker MV format, 48px tiles):
## - assets/supermarket/Tile_A2-2.png: A2 floor autotiles, 16 floor types in
##   96x144 blocks. The lower 96x96 of each block (4 tiles) repeats
##   seamlessly, which is all a flat room floor needs.
## - assets/*/Auto-tile-A4-walls-*.png: A4 wall autotiles, 8x3 blocks of a
##   96x144 wall-top + a 96x96 wall face. The game's walls are 20px strips
##   seen straight from above, so each strip is textured with a wall FACE
##   (squashed to the strip's thickness) — the colour and material read, the
##   3/4-view perspective of the face doesn't matter at 20px.
## - The warehouse pack has NO floor tiles (walls + B-sheet objects only), so
##   Storage's concrete floor comes from the supermarket pack's A2 sheet,
##   which has an industrial row (concrete / hazard-stripe / diamond plate).
## - B-sheet objects: most supermarket fixtures aren't on the 48px grid, so
##   they're cut as exact per-object regions (Sprite2D region_rect), never as
##   TileSet cells. See the SHELF STOCKING VISUALS note below.
##
## SCALE: pack tiles are drawn for ~48px characters; ours are 28px, so every
## pack texture is drawn at ART_SCALE (48px -> 30px) to keep the floor grain
## in proportion to the players and stock.

const ART_SCALE := 0.625

const A2_PATH := "res://assets/supermarket/Tile_A2-2.png"
const MARKET_WALLS_PATH := "res://assets/supermarket/Auto-tile-A4-walls-3.png"
const WAREHOUSE_WALLS_PATH := "res://assets/warehouse/Auto-tile-A4-walls-2.png"

## RoomBackgrounds node -> A2 block (col, row). Only the zones in scope:
## the four sales sections, the checkout hub, and Storage — and (WEEK 23) the
## break room. The sidewalk and the reserved cell keep their placeholder floors.
const FLOORS := {
	"DryGoodsBg": Vector2i(3, 0), # large white tile
	"MeatDeliBg": Vector2i(0, 2), # small white cold-room tile
	"DairyFrozenBg": Vector2i(1, 0), # pale blue checker
	"BakeryBg": Vector2i(2, 0), # brown checker
	"EntranceBg": Vector2i(3, 1), # cream tile (the checkout hub)
	"StorageBg": Vector2i(0, 1), # grey concrete panels
	"BreakRoomBg": Vector2i(5, 2), # WEEK 23: beige vinyl with grey insets — staff-room floor
	"StaffHallBg": Vector2i(0, 1), # PHASE 5B PART 2B: the staff hall, the back room's concrete
}
## Which A4 sheet + face block the walls take. PHASE 5B PART 2A: WHICH walls
## take which is each room's "wall_art" in the layout table (StoreLayout.gd:
## "market" for the four sections and the hub, "warehouse" for Storage,
## "break_room"; the sidewalk and the empty lot have none) — was a list of
## grid cells here.
const MARKET_WALL_FACE := Vector2i(3, 1) # blue tile
const WAREHOUSE_WALL_FACE := Vector2i(6, 1) # corrugated metal
## WEEK 23: the break room's own walls (top and left — its seal with
## Dairy/Frozen keeps the market tile, that's Dairy's side): cream paint over a
## wood baseboard, the same market sheet.
const BREAK_ROOM_WALL_FACE := Vector2i(7, 1)
var _break_room_face: Texture2D

var main: Node

func _ready() -> void:
	main = get_parent()
	_texture_floors()
	_build_walls()
	_dress_shelves()
	_dress_registers()
	_dress_displays()
	main.products_root.child_entered_tree.connect(_dress_product)

## PHASE 5B PART 2B: the shop's wall face, for StoreGrowth.gd's knock-out
## walls (the same blue tile as every other sales-floor wall).
func market_wall_face() -> Texture2D:
	return _a4_face(MARKET_WALLS_PATH, MARKET_WALL_FACE)

## Lower 96x96 of an A2 block, as a repeatable texture.
func _a2_floor(block: Vector2i) -> Texture2D:
	var img: Image = load(A2_PATH).get_image()
	return ImageTexture.create_from_image(img.get_region(Rect2i(block.x * 96, block.y * 144 + 48, 96, 96)))

## The 96x96 wall face under an A4 block's 144px top.
func _a4_face(path: String, block: Vector2i) -> Texture2D:
	var img: Image = load(path).get_image()
	return ImageTexture.create_from_image(img.get_region(Rect2i(block.x * 96, block.y * 240 + 144, 96, 96)))

## Each in-scope room floor becomes the full cell (so open doorways between
## sections are floored too — the walls are drawn separately, below), white
## (so the locked-section dim multiplies the texture), and tiled.
func _texture_floors() -> void:
	for node_name in FLOORS:
		var bg: Polygon2D = main.get_node("RoomBackgrounds/" + node_name)
		# The room this floor sits in (its polygon is centred on the room).
		var half: Vector2 = main.areas.rect_of(main.areas.area_at(bg.position)).size * 0.5
		bg.polygon = PackedVector2Array([-half, Vector2(half.x, -half.y), half, Vector2(-half.x, half.y)])
		bg.uv = PackedVector2Array() # UVs follow the vertices
		bg.texture = _a2_floor(FLOORS[node_name])
		bg.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
		bg.texture_scale = Vector2.ONE / ART_SCALE
		bg.texture_offset = half # tile grid starts at the cell's corner
		bg.color = Color(1, 1, 1, 1)

## A textured strip over every piece of real wall (Main.tscn's Walls: the
## perimeter and the three interior seals), cut per grid cell so each piece
## takes its zone's material; pieces in out-of-scope cells stay as they were
## (the dark gap). Read from the collision shapes themselves, so the art can
## never drift from where the walls actually are.
func _build_walls() -> void:
	var market := _a4_face(MARKET_WALLS_PATH, MARKET_WALL_FACE)
	var warehouse := _a4_face(WAREHOUSE_WALLS_PATH, WAREHOUSE_WALL_FACE)
	_break_room_face = _a4_face(MARKET_WALLS_PATH, BREAK_ROOM_WALL_FACE)
	for body in main.get_node("Walls").get_children():
		var shape: CollisionShape2D = body.get_node("CollisionShape2D")
		var size: Vector2 = (shape.shape as RectangleShape2D).size
		var rect := Rect2(body.global_position + shape.position - size * 0.5, size)
		var along_x := size.x >= size.y
		var cuts := _room_edges(along_x)
		var start: float = rect.position.x if along_x else rect.position.y
		var stop: float = rect.end.x if along_x else rect.end.y
		var a := start
		while a < stop - 0.5:
			var b := stop
			for e in cuts:
				if e > a:
					b = minf(stop, e)
					break
			var piece := Rect2(Vector2(a, rect.position.y), Vector2(b - a, rect.size.y)) if along_x else Rect2(Vector2(rect.position.x, a), Vector2(rect.size.x, b - a))
			var tex := _wall_texture_for(piece, market, warehouse)
			if tex:
				_add_strip(piece, tex, along_x)
			a = b

## Every room's edges along one axis, sorted: a wall strip is cut at each so
## each piece takes the material of the room it borders (was: at every
## multiple of the 960 x 540 cell).
func _room_edges(along_x: bool) -> Array:
	var out := []
	for id in main.areas.room_ids():
		var r: Rect2 = main.areas.rect_of(id)
		for e in ([r.position.x, r.end.x] if along_x else [r.position.y, r.end.y]):
			if not e in out:
				out.append(e)
	out.sort()
	return out

## The zone a wall piece belongs to: an interior seal sits on a room boundary,
## so look just inside both sides and take whichever is in scope (Storage
## wins — the seal between Meat/Deli and Storage is the warehouse's wall).
func _wall_texture_for(piece: Rect2, market: Texture2D, warehouse: Texture2D) -> Texture2D:
	var c := piece.get_center()
	var probes: Array = [c]
	if piece.size.x >= piece.size.y:
		probes = [c + Vector2(0, -piece.size.y), c + Vector2(0, piece.size.y)]
	else:
		probes = [c + Vector2(-piece.size.x, 0), c + Vector2(piece.size.x, 0)]
	var arts := probes.map(func(p): return main.areas.area(main.areas.area_at(p)).get("wall_art", ""))
	if "warehouse" in arts:
		return warehouse
	if "market" in arts:
		return market
	if "break_room" in arts:
		return _break_room_face
	return null

## One strip: the face texture repeated along it, squashed so one face tile
## fills the strip's thickness.
func _add_strip(r: Rect2, tex: Texture2D, along_x: bool) -> void:
	var strip := Polygon2D.new()
	strip.polygon = PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])
	strip.texture = tex
	strip.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	var thickness: float = r.size.y if along_x else r.size.x
	strip.texture_scale = Vector2.ONE * (96.0 / thickness)
	strip.texture_offset = Vector2.ZERO
	add_child(strip)

## --- SHELF STOCKING VISUALS (Week 13 follow-up) ------------------------------
## Pure visual layer over the existing shelf/stock state; no logic reads any of
## it. Per section, chosen after a sweep of all 522 separable sprites in both
## packs (the warehouse pack has no food at all):
## - Dry Goods: real products (cans, cereal/snack boxes, chip bags — 4.png).
## - Bakery: real products (cakes, slices, loaves — 2.png).
## - Dairy/Frozen: cold drinks (water, juice carton, sodas — 4.png). A loose
##   fit: the pack has no milk/cheese/yogurt/ice cream anywhere.
## - Produce (follow-up #4 — was Meat/Deli, which had NOTHING genuine: every
##   meat/fish item in the pack is baked into a refrigerated case, so the
##   section now sells what the packs do support): 18 real items — fruit and
##   veg bowls, apple baskets, a greens crate, a pineapple (4.png, 2.png).
##
## HOW A SLOT RENDERS (every section, ART_SECTIONS):
## - Every slot gets one bay of the pack's EMPTY metal shelving (11.png)
##   under its existing accent-colored outline — the empty-shelf look, and
##   the outline still says which color goes there (a gameplay cue).
## - The product itself draws as its section's sprite (PRODUCT_SPRITES,
##   picked from its node name — identical on every peer, since spawned
##   names are replicated). So a stocked slot shows the real item that the
##   shelf's own state says is sitting in it, on the empty bay; loose and
##   carried stock look like the same products. The product's colored
##   Polygon2D stays (its color IS the item type the stock/order logic
##   reads) — only its fill is made invisible (self_modulate).
##
## SHELF FURNITURE (the long body behind the slots), follow-up #4 — one style
## everywhere: a row of the same empty metal bays the slots use, laid along
## the body's long axis (three per 180px shelf), each drawn UPRIGHT whatever
## way the shelf faces. That's what lets Dry Goods' sideways shelves (turned
## 90 degrees) share it: a stack of upright bays reads as shelving, where one
## front-view unit rotated 90 degrees would lie on its side. The art is grey;
## each section's color comes from the shelf body's own existing tint
## (Main.tscn's per-section shelf modulate), untouched, so sections stay
## color-coded exactly as before. Same body, same collision, same slots.

## WEEK 20 (playtest: "leftover grey shelves behind the real ones in Dry
## Goods"). There was no leftover geometry — every drawn node in every
## section belongs to a live shelf (checked node by node). What read as a
## ghost is each Dry Goods shelf's own BODY (the bays above, where its
## collision is): the other three sections tint the whole shelf with their
## color (Main.tscn's per-section shelf modulate), so body and slots read as
## one unit, but Dry Goods had no tint — plain grey bays behind yellow-
## outlined ones. Dry Goods' bays (body and slots) now take a yellow of their
## own. Bay sprites only, not the shelf root: a root modulate would also tint
## the slot outlines and the stocked products' facings.
const BAY_TINT := {"Dry Goods": Color(1.25, 1.1, 0.55)}
const SHELF_SHEET := "res://assets/supermarket/11.png"
const EMPTY_SHELF_BAY := Rect2i(0, 390, 96, 92) # one empty metal bay
const BODY_BAYS := 3 # bays along each shelf body
const PRODUCT_SIZE := 30.0 # px, longest side — products are 28px bodies
const SLOT_BAY_SIZE := Vector2(46, 44) # inside the 52px outline
const ART_SECTIONS := ["Dry Goods", "Produce", "Dairy/Frozen", "Bakery"]
const PRODUCT_SPRITES := {
	"Dry Goods": ["res://assets/supermarket/4.png", [
		Rect2i(683, 3, 27, 43), Rect2i(682, 534, 29, 37), Rect2i(730, 534, 29, 37), Rect2i(680, 581, 33, 39),
		Rect2i(728, 581, 33, 39), Rect2i(397, 582, 23, 36), Rect2i(445, 582, 23, 36), Rect2i(493, 582, 23, 36),
		Rect2i(541, 582, 23, 36), Rect2i(589, 582, 23, 36), Rect2i(637, 582, 23, 36), Rect2i(488, 628, 33, 41),
		Rect2i(536, 628, 33, 41), Rect2i(583, 628, 35, 40), Rect2i(394, 630, 29, 37), Rect2i(442, 630, 29, 37),
		Rect2i(633, 630, 31, 37), Rect2i(681, 630, 31, 37), Rect2i(729, 630, 31, 37), Rect2i(386, 674, 45, 44),
		Rect2i(578, 674, 44, 46), Rect2i(626, 674, 44, 46), Rect2i(537, 677, 31, 39), Rect2i(681, 678, 31, 37),
		Rect2i(394, 726, 29, 37)]],
	"Bakery": ["res://assets/supermarket/2.png", [
		Rect2i(722, 244, 44, 45), Rect2i(627, 245, 44, 44), Rect2i(674, 245, 44, 44), Rect2i(100, 387, 41, 46),
		Rect2i(145, 389, 47, 44), Rect2i(3, 390, 43, 43), Rect2i(51, 390, 43, 43), Rect2i(193, 393, 47, 40),
		Rect2i(241, 393, 47, 40), Rect2i(289, 393, 47, 40), Rect2i(97, 437, 47, 43), Rect2i(4, 439, 42, 41),
		Rect2i(145, 439, 47, 41), Rect2i(50, 440, 45, 40), Rect2i(193, 440, 47, 40), Rect2i(290, 440, 45, 40),
		Rect2i(241, 445, 47, 35)]],
	"Dairy/Frozen": ["res://assets/supermarket/4.png", [
		Rect2i(447, 675, 19, 43), Rect2i(495, 675, 19, 43), Rect2i(495, 722, 19, 44), Rect2i(447, 723, 19, 43),
		Rect2i(540, 725, 25, 40)]],
	"Produce": ["res://assets/supermarket/4.png", [
		Rect2i(626, 388, 44, 41), Rect2i(578, 389, 44, 40), Rect2i(674, 390, 44, 39), Rect2i(722, 390, 44, 39),
		Rect2i(579, 437, 43, 40), Rect2i(626, 437, 44, 40), Rect2i(674, 438, 44, 39), Rect2i(722, 440, 44, 37),
		Rect2i(731, 482, 26, 44), Rect2i(578, 483, 44, 42), Rect2i(678, 483, 37, 43), Rect2i(626, 486, 44, 39),
		Rect2i(631, 533, 36, 41), Rect2i(580, 537, 40, 36)]],
	# (+ four baskets/crates from 2.png, merged into the same pool below)
}
## Produce's other four items live on a different sheet: [path, region].
const PRODUCE_EXTRA := [
	["res://assets/supermarket/2.png", Rect2i(529, 674, 47, 47)], ["res://assets/supermarket/2.png", Rect2i(481, 722, 47, 46)],
	["res://assets/supermarket/2.png", Rect2i(529, 722, 47, 46)], ["res://assets/supermarket/2.png", Rect2i(433, 728, 47, 40)],
]

func _region_sprite(path: String, region: Rect2i) -> Sprite2D:
	var spr := Sprite2D.new()
	spr.texture = load(path)
	spr.region_enabled = true
	spr.region_rect = Rect2(region)
	return spr

func _dress_shelves() -> void:
	for shelf_body in main.shelves:
		var section: String = main.areas.section_of(shelf_body.global_position)
		var shelf: Node = shelf_body.get_node("Shelf")
		var upright: float = -shelf_body.global_rotation
		if section in ART_SECTIONS:
			# Children of the body polygon, so they keep the wreck tilt Shelf.gd
			# puts on that polygon; each counter-rotated so it's never sideways
			# or upside down. A bay's on-screen footprint is its slice of the
			# body, rotated into world axes.
			var polygon: Polygon2D = shelf_body.get_node("Polygon2D")
			var bounds := Rect2(polygon.polygon[0], polygon.polygon[2] - polygon.polygon[0])
			var cell := Vector2(bounds.size.x / BODY_BAYS, bounds.size.y)
			var world_cell := cell.rotated(shelf_body.global_rotation).abs()
			var art := Node2D.new()
			art.name = "ShelfArt"
			for n in BODY_BAYS:
				var bay := _region_sprite(SHELF_SHEET, EMPTY_SHELF_BAY)
				bay.position = Vector2(bounds.position.x + cell.x * (n + 0.5), bounds.get_center().y)
				bay.rotation = upright
				bay.scale = world_cell / Vector2(EMPTY_SHELF_BAY.size)
				art.add_child(bay)
			art.modulate = BAY_TINT.get(section, Color.WHITE)
			polygon.self_modulate.a = 0.0
			polygon.add_child(art)
		if section in ART_SECTIONS:
			for slot in shelf._all_slots:
				var bay := _region_sprite(SHELF_SHEET, EMPTY_SHELF_BAY)
				bay.name = "EmptyShelfArt"
				bay.modulate = BAY_TINT.get(section, Color.WHITE)
				bay.rotation = upright
				bay.scale = SLOT_BAY_SIZE / Vector2(EMPTY_SHELF_BAY.size)
				slot.add_child(bay)
				slot.move_child(bay, 0) # under the outline and the C prompt
				var facings := Node2D.new()
				facings.name = "Facings"
				facings.rotation = upright
				facings.scale = bay.scale # laid out in the bay art's own pixels
				facings.visible = false
				slot.add_child(facings)
				slot.move_child(facings, 1)
				_faced_slots.append([shelf, shelf._all_slots.find(slot), slot, facings])

## Every peer, as each product spawns (its color is set before it enters
## the tree — Main.gd's _spawn_product_node()).
func _dress_product(node: Node) -> void:
	var visual := node.get_node_or_null("Polygon2D") as Polygon2D
	if visual == null or node.has_node("ProductArt"):
		return
	var section := ""
	for sec_name in main.SECTION_COLORS:
		if visual.color.is_equal_approx(main.SECTION_COLORS[sec_name]):
			section = sec_name
	if not PRODUCT_SPRITES.has(section):
		return # Meat/Deli: stays the placeholder square
	var pool := _sprite_pool(section)
	var pick: Array = pool[absi(String(node.name).hash()) % pool.size()]
	var region: Rect2i = pick[1]
	var spr := _region_sprite(pick[0], region)
	spr.name = "ProductArt"
	spr.scale = Vector2.ONE * (PRODUCT_SIZE / float(maxi(region.size.x, region.size.y)))
	visual.self_modulate.a = 0.0
	node.add_child(spr)

## --- STOCKED FACINGS (Week 13 follow-up #2) ---------------------------------
## Playtest: a stocked slot read as "one small item in an empty bay". Measured:
## the bay is 46x44px on screen (the 96x92 art at 0.48x) and the product
## sprite 30px on its longest side — under 30% of the bay, floating over the
## grate instead of standing on any of its three shelves. A slot holds
## exactly ONE item (Shelf.gd's filled[i] / _occupant[i]; the HUD's "1/3" is
## slots filled per shelf, not a quantity), so this isn't a quantity display:
## it's merchandising. While a slot is filled, its bay shows the item that's
## in it FACED — a row of that same product standing on each of the bay's
## three shelf lips, as many across as fit — and the item's own single
## sprite is hidden (it's represented by the facings until it leaves the
## slot: picked up, knocked off, bought). Every peer does this from the
## replicated `filled` flags; which item is in a slot comes from Shelf.gd's
## replicated occupant_names (follow-up #4 — a client's nearest-item guess
## could pick a neighbour). Nothing reads any of it back.

## In the bay art's own pixels (96x92, centered): the top of each shelf lip
## (from its luminance profile), and how tall a faced item stands on it —
## the opening above the lip plus a little overlap onto the lip above.
const FACING_BASELINES := [-14.0, 10.0, 32.0]
const FACING_HEIGHT := 22.0
const FACING_ROW_WIDTH := 88.0
const FACING_GAP := 2.0
const FACING_MAX_ACROSS := 5

var _faced_slots: Array = [] # [shelf, slot index, slot Marker2D, Facings node]
var _hidden_art := {} # product -> true while it's shown as facings

func _process(delta: float) -> void:
	_run_conveyors(delta)
	var now_hidden := {}
	for entry in _faced_slots:
		var shelf: Node = entry[0]
		var i: int = entry[1]
		var slot: Node2D = entry[2]
		var facings: Node2D = entry[3]
		var item: Node2D = null
		if i < shelf.slots.size() and shelf._is_filled(i) and not shelf.wrecked:
			item = _item_in_slot(shelf, i, slot)
		var art: Sprite2D = item.get_node_or_null("ProductArt") if item else null
		if art == null:
			facings.visible = false
			continue
		_show_facings(facings, art)
		now_hidden[item] = true
		art.visible = false
	for item in _hidden_art:
		if not now_hidden.has(item) and is_instance_valid(item):
			item.get_node("ProductArt").visible = true
	_hidden_art = now_hidden

## The item the authority counted in this slot (Shelf.gd's replicated
## occupant_names), looked up by its spawner name — identical on every peer.
func _item_in_slot(shelf: Node, i: int, _slot: Node2D) -> Node2D:
	if i >= shelf.occupant_names.size() or shelf.occupant_names[i] == "":
		return null
	return main.products_root.get_node_or_null(NodePath(shelf.occupant_names[i]))

## (Re)builds the rows only when the product in the slot changes.
func _show_facings(facings: Node2D, art: Sprite2D) -> void:
	facings.visible = true
	var key := "%s|%s" % [art.texture.resource_path, str(art.region_rect)]
	if facings.get_meta("key", "") == key:
		return
	facings.set_meta("key", key)
	for c in facings.get_children():
		c.queue_free()
	var region: Rect2 = art.region_rect
	var k: float = FACING_HEIGHT / region.size.y
	var w: float = region.size.x * k
	var across: int = clampi(int((FACING_ROW_WIDTH + FACING_GAP) / (w + FACING_GAP)), 1, FACING_MAX_ACROSS)
	var span: float = across * w + (across - 1) * FACING_GAP
	for baseline in FACING_BASELINES:
		for n in across:
			var f := Sprite2D.new()
			f.texture = art.texture
			f.region_enabled = true
			f.region_rect = region
			f.scale = Vector2(k, k)
			f.position = Vector2(-span * 0.5 + w * 0.5 + n * (w + FACING_GAP), baseline - FACING_HEIGHT * 0.5)
			facings.add_child(f)

## Every [path, region] a section's products can be drawn as.
func _sprite_pool(section: String) -> Array:
	var entry: Array = PRODUCT_SPRITES[section]
	var pool := []
	for r in entry[1]:
		pool.append([entry[0], r])
	if section == "Produce":
		pool.append_array(PRODUCE_EXTRA)
	return pool

## --- CHECKOUT LANES (Week 20 playtest polish) --------------------------------
## Purely visual, like everything in this file: no logic reads any of it,
## nothing new is replicated, checkout timing/scoring are Cashier.gd's and
## untouched. Checked both packs first: the warehouse pack has no retail
## counters; the supermarket pack (1.png) has two complete checkout lanes —
## counter, register, card reader, bagging well and a CONVEYOR BELT built
## into the counter — one red, one blue. Every register now draws as one of
## those (alternating), in place of the blue placeholder box. The body's
## Polygon2D stays (hidden) and the collision is untouched; the lane is sized
## to sit on that 60x40 footprint, nudged west so its belt end meets the
## Checkout marker (+50,0) where a shopper stands to pay.
##
## THE BELT: the lane art's own belt, animated. While a shopper is being
## rung up, the belt strip scrolls toward the register (a strip cut from the
## same art, one belt segment tiled) and the item slides along it, from the
## shopper's end to the register, over the Cashier's CHECKOUT_WAIT_SECONDS; the
## item's own sprite (still carried by the shopper as far as the game is
## concerned) is hidden meanwhile. Every peer works this out on its own from
## state it already has: a customer standing within the Cashier's PURCHASE_RANGE of
## a register's Checkout marker while carrying something (carrier_id and
## carry_id reach every peer) is the one being served — the queue's other
## slots all sit outside that range. Each peer times the slide from when it
## first sees that, so a client can be a frame or two off the host; the host
## alone decides when the sale actually happens (the item vanishes then).

const LANE_SHEET := "res://assets/supermarket/1.png"
const LANE_REGIONS := [Rect2i(386, 207, 142, 81), Rect2i(386, 303, 142, 81)] # red lane, blue lane
const LANE_STRAY_CUT := Rect2i(66, 0, 28, 34) # lane-local: the card machine above, not the counter
const LANE_SCALE := 0.55 # 142x81 -> 78x45 on the 60x40 counter
const LANE_OFFSET := Vector2(-6, 0)
## The belt inside a lane region (lane-local pixels) and one belt segment
## (sheet pixels, same rows) to tile for the moving strip.
const BELT_RECT := Rect2(95, 40, 46, 15)
const BELT_SEGMENT := Rect2i(491, 247, 9, 15) # +96 rows for the blue lane
const BELT_SPEED := 18.0 # sheet px per second
const BELT_ITEM_SIZE := 15.0 # px, longest side of the item riding the belt

var _lanes: Array = [] # [{"body", "cashier", "belt", "rider", "item", "t"}]

func _dress_registers() -> void:
	var bodies := get_tree().get_nodes_in_group("cashier")
	bodies.sort_custom(func(a, b): return String(a.name) < String(b.name))
	for i in bodies.size():
		var body: Node2D = bodies[i]
		var region: Rect2i = LANE_REGIONS[i % LANE_REGIONS.size()]
		(body.get_node("Polygon2D") as Polygon2D).self_modulate.a = 0.0
		var lane := Sprite2D.new()
		lane.texture = _lane_texture(region)
		lane.name = "LaneArt"
		lane.scale = Vector2.ONE * LANE_SCALE
		lane.position = LANE_OFFSET
		body.add_child(lane)
		# Over the cashier NPC's lower half: they stand behind the counter.
		body.move_child(lane, body.get_node("CashierNPC").get_index() + 1)
		# The moving strip, exactly over the lane's own belt.
		var seg_img: Image = load(LANE_SHEET).get_image().get_region(Rect2i(BELT_SEGMENT.position + Vector2i(0, region.position.y - LANE_REGIONS[0].position.y), BELT_SEGMENT.size))
		var belt := Sprite2D.new()
		belt.name = "Belt"
		belt.texture = ImageTexture.create_from_image(seg_img)
		belt.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
		belt.region_enabled = true
		belt.region_rect = Rect2(Vector2.ZERO, BELT_RECT.size)
		belt.centered = false
		belt.position = BELT_RECT.position - Vector2(region.size) * 0.5
		lane.add_child(belt)
		var rider := Sprite2D.new()
		rider.name = "BeltItem"
		rider.visible = false
		body.add_child(rider)
		_lanes.append({"body": body, "cashier": body.get_node("Cashier"), "belt": belt, "rider": rider, "item": null, "t": 0.0})

## The lane cut out of the sheet, minus the separate card-machine sprite that
## sits in the tile above each lane (it overlaps the region's top edge and
## would float over the cashier).
func _lane_texture(region: Rect2i) -> Texture2D:
	var img: Image = load(LANE_SHEET).get_image().get_region(region)
	img.fill_rect(LANE_STRAY_CUT, Color(0, 0, 0, 0))
	return ImageTexture.create_from_image(img)

## Lane-local belt ends -> the body's own space.
func _belt_point(lane_x: float) -> Vector2:
	var region: Rect2i = LANE_REGIONS[0]
	var local := Vector2(lane_x, BELT_RECT.get_center().y) - Vector2(region.size) * 0.5
	return LANE_OFFSET + local * LANE_SCALE + Vector2(0, -2)

func _run_conveyors(delta: float) -> void:
	if _lanes.is_empty():
		return
	# carrier id -> the item it rings up next (OCT 2026 PHASE 3B: a cart holds
	# several — the first one in, the same pick Cashier.next_item_of() makes).
	var carried := {}
	var seqs := {}
	for obj in get_tree().get_nodes_in_group("carryable"):
		var c: Node = obj.get_node_or_null("Carryable")
		if c and c.carrier_id != 0 and not obj.is_queued_for_deletion() and (not seqs.has(c.carrier_id) or c.carry_seq < seqs[c.carrier_id]):
			carried[c.carrier_id] = obj
			seqs[c.carrier_id] = c.carry_seq
	var customers := get_tree().get_nodes_in_group("customer")
	for lane in _lanes:
		var body: Node2D = lane["body"]
		var item: Node2D = null
		if body.visible:
			var checkout: Vector2 = body.get_node("Checkout").global_position
			# The CLOSEST carrying customer in range — the one the register
			# serves (Cashier.gd's _queue_by_distance()). OCT 2026 PHASE 3B:
			# shoppers pass through each other now, so two can stand in range
			# at once, and "the first one found" could slide the wrong item.
			# Sticky, like the register itself (Cashier.gd's _serving): the
			# customer already on this belt stays on it while in range with
			# something left to ring up, whoever walks past.
			var best_d := INF
			var held_cid = lane.get("cid", null)
			for cust in customers:
				var cid = cust.get("carry_id")
				var d: float = cust.global_position.distance_to(checkout)
				if cid != null and carried.has(cid) and d <= lane["cashier"].PURCHASE_RANGE:
					if cid == held_cid:
						item = carried[cid]
						break
					if d < best_d:
						best_d = d
						item = carried[cid]
			lane["cid"] = null
			if item != null:
				lane["cid"] = item.get_node("Carryable").carrier_id
		var prev = lane["item"]
		if item != prev:
			if prev != null and is_instance_valid(prev):
				_set_item_art_hidden(prev, false)
			lane["item"] = item
			lane["t"] = 0.0
			if item != null:
				_load_rider(lane["rider"], item)
		var rider: Sprite2D = lane["rider"]
		rider.visible = item != null
		if item == null:
			continue
		_set_item_art_hidden(item, true)
		lane["t"] = float(lane["t"]) + delta
		var k := clampf(float(lane["t"]) / lane["cashier"].CHECKOUT_WAIT_SECONDS, 0.0, 1.0)
		rider.position = _belt_point(BELT_RECT.end.x - 6.0).lerp(_belt_point(BELT_RECT.position.x + 4.0), k)
		if k < 1.0:
			var belt: Sprite2D = lane["belt"]
			belt.region_rect.position.x = fposmod(belt.region_rect.position.x + BELT_SPEED * delta, float(BELT_SEGMENT.size.x))

## The rider copies the item's own art (or, with none, its color).
func _load_rider(rider: Sprite2D, item: Node2D) -> void:
	var art: Sprite2D = item.get_node_or_null("ProductArt")
	if art:
		rider.texture = art.texture
		rider.region_enabled = true
		rider.region_rect = art.region_rect
		rider.modulate = Color.WHITE
		rider.scale = Vector2.ONE * (BELT_ITEM_SIZE / maxf(art.region_rect.size.x, art.region_rect.size.y))
	else:
		var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		rider.texture = ImageTexture.create_from_image(img)
		rider.region_enabled = false
		rider.modulate = (item.get_node("Polygon2D") as Polygon2D).color
		rider.scale = Vector2.ONE * BELT_ITEM_SIZE * 0.8

## Alpha on the item's own art only — `visible` belongs to the facings above.
func _set_item_art_hidden(item: Node2D, hidden: bool) -> void:
	var a := 0.0 if hidden else 1.0
	var art: CanvasItem = item.get_node_or_null("ProductArt")
	if art:
		art.self_modulate.a = a
	else:
		(item.get_node("Polygon2D") as Polygon2D).modulate.a = a

## --- PRODUCE FLOOR DISPLAYS (Week 20 playtest polish) -----------------------
## The two floor displays (Main.tscn's Displays — knock-over-able RigidBody2D
## props, Display.gd; a mop job at cleanup) were still Week 8 placeholders:
## a tan square with two red dots. They stay exactly the same props (same
## body, collision, physics, knock-over and mop behaviour) and only their
## art changes. Checked both packs: the warehouse pack has nothing produce;
## the supermarket pack's 1.png has a row of wooden two-tier produce crates
## with price plaques (potatoes/tomatoes, peppers, eggplant, greens/oranges,
## lettuce/squash, tomatoes/spinach, broccoli/mushrooms). Each display is a
## pair of those crates side by side (Display.tscn's 44x44 footprint); the
## sale bin gets the pack's "1.99" price sign on a post beside it. Knocked
## over, the pair lies tipped on its side with a few of the section's own
## produce sprites spilled around it (where the old spill shapes were).
const DISPLAY_ART := {
	"MeatDeliSampleTable": Rect2i(0, 309, 96, 76), # potatoes/tomatoes + peppers
	"MeatDeliSaleBin": Rect2i(240, 305, 96, 80), # lettuce/squash + tomatoes/spinach
}
const DISPLAY_SCALE := 0.55
const SALE_SIGN := Rect2i(585, 145, 31, 47) # "1.99" on a post
const DISPLAY_SPILLS := [[Vector2(30, -6), 0], [Vector2(-26, 18), 5], [Vector2(28, 18), 9]] # [offset, Produce sprite index]

func _dress_displays() -> void:
	for d in get_tree().get_nodes_in_group("display"):
		if not DISPLAY_ART.has(String(d.name)):
			continue
		var region: Rect2i = DISPLAY_ART[d.name]
		var upright: Node2D = d.get_node("Upright")
		var toppled: Node2D = d.get_node("Toppled")
		for n in upright.get_children() + toppled.get_children():
			if n is Polygon2D:
				n.visible = false
		var crates := _region_sprite(LANE_SHEET, region)
		crates.name = "CrateArt"
		crates.scale = Vector2.ONE * DISPLAY_SCALE
		upright.add_child(crates)
		if String(d.name).ends_with("SaleBin"):
			var sign := _region_sprite(LANE_SHEET, SALE_SIGN)
			sign.name = "SaleSign"
			sign.scale = Vector2.ONE * 0.6
			sign.position = Vector2(-16, -24)
			upright.add_child(sign)
		var tipped := _region_sprite(LANE_SHEET, region)
		tipped.name = "CrateArt"
		tipped.scale = Vector2.ONE * DISPLAY_SCALE
		tipped.rotation = -1.35
		tipped.modulate = Color(0.85, 0.85, 0.85)
		toppled.add_child(tipped)
		var pool := _sprite_pool("Produce")
		for spill in DISPLAY_SPILLS:
			var pick: Array = pool[int(spill[1]) % pool.size()]
			var s := _region_sprite(pick[0], pick[1])
			s.scale = Vector2.ONE * (16.0 / float(maxi(pick[1].size.x, pick[1].size.y)))
			s.position = spill[0]
			toppled.add_child(s)
