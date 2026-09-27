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
## the four sales sections, the checkout hub, and Storage. The break room,
## sidewalk and the reserved cell keep their placeholder floors.
const FLOORS := {
	"DryGoodsBg": Vector2i(3, 0), # large white tile
	"MeatDeliBg": Vector2i(0, 2), # small white cold-room tile
	"DairyFrozenBg": Vector2i(1, 0), # pale blue checker
	"BakeryBg": Vector2i(2, 0), # brown checker
	"EntranceBg": Vector2i(3, 1), # cream tile (the checkout hub)
	"StorageBg": Vector2i(0, 1), # grey concrete panels
}
## Grid cells whose walls get pack art, and which A4 sheet + face block.
const MARKET_CELLS := [Vector2i(1, 0), Vector2i(2, 1), Vector2i(0, 1), Vector2i(2, 0), Vector2i(1, 1)]
const STORAGE_CELL := Vector2i(2, 2)
const MARKET_WALL_FACE := Vector2i(3, 1) # blue tile
const WAREHOUSE_WALL_FACE := Vector2i(6, 1) # corrugated metal

var main: Node

func _ready() -> void:
	main = get_parent()
	_texture_floors()
	_build_walls()
	_dress_shelves()
	main.products_root.child_entered_tree.connect(_dress_product)

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
	var half := Vector2(main.ROOM_WIDTH, main.ROOM_HEIGHT) * 0.5
	for node_name in FLOORS:
		var bg: Polygon2D = main.get_node("RoomBackgrounds/" + node_name)
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
	for body in main.get_node("Walls").get_children():
		var shape: CollisionShape2D = body.get_node("CollisionShape2D")
		var size: Vector2 = (shape.shape as RectangleShape2D).size
		var rect := Rect2(body.global_position + shape.position - size * 0.5, size)
		var along_x := size.x >= size.y
		var cell_len: float = main.ROOM_WIDTH if along_x else main.ROOM_HEIGHT
		var start: float = rect.position.x if along_x else rect.position.y
		var stop: float = rect.end.x if along_x else rect.end.y
		var a := start
		while a < stop - 0.5:
			var b := minf(stop, (floor(a / cell_len) + 1.0) * cell_len)
			var piece := Rect2(Vector2(a, rect.position.y), Vector2(b - a, rect.size.y)) if along_x else Rect2(Vector2(rect.position.x, a), Vector2(rect.size.x, b - a))
			var tex := _wall_texture_for(piece, market, warehouse)
			if tex:
				_add_strip(piece, tex, along_x)
			a = b

## The zone a wall piece belongs to: an interior seal sits on a cell boundary,
## so look just inside both sides and take whichever is in scope (Storage
## wins — the seal between Meat/Deli and Storage is the warehouse's wall).
func _wall_texture_for(piece: Rect2, market: Texture2D, warehouse: Texture2D) -> Texture2D:
	var c := piece.get_center()
	var probes: Array = [c]
	if piece.size.x >= piece.size.y:
		probes = [c + Vector2(0, -piece.size.y), c + Vector2(0, piece.size.y)]
	else:
		probes = [c + Vector2(-piece.size.x, 0), c + Vector2(piece.size.x, 0)]
	var cells := probes.map(func(p): return main._grid_cell_of(p))
	if STORAGE_CELL in cells:
		return warehouse
	for cell in cells:
		if cell in MARKET_CELLS:
			return market
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
## - Meat/Deli: NOTHING genuine — every meat/fish item in the pack is baked
##   into a refrigerated case. Kept as the placeholder (colored squares,
##   outline slots, flat shelf) rather than forcing a mismatch.
##
## HOW A SLOT RENDERS (sections in SLOT_ART_SECTIONS):
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
## SHELF FURNITURE (the long body behind the slots) is a separate call,
## FURNITURE_SECTIONS: the pack's shelving is front-view art. On shelves
## that sit at 0/180 degrees (Bakery, Dairy/Frozen) it's drawn upright and
## reads as a shelving unit. Dry Goods' shelves are turned 90 degrees to
## face sideways, where front-view art would read as a shelf lying on its
## side, so Dry Goods keeps the flat placeholder body (products + slot art
## still swapped). Meat/Deli keeps it too, to match its placeholder stock.

const SHELF_SHEET := "res://assets/supermarket/11.png"
const EMPTY_SHELF_UNIT := Rect2i(0, 390, 193, 92) # two empty metal bays
const EMPTY_SHELF_BAY := Rect2i(0, 390, 96, 92) # one of them
const PRODUCT_SIZE := 30.0 # px, longest side — products are 28px bodies
const SLOT_BAY_SIZE := Vector2(46, 44) # inside the 52px outline
const SLOT_ART_SECTIONS := ["Dry Goods", "Bakery", "Dairy/Frozen"]
const FURNITURE_SECTIONS := ["Bakery", "Dairy/Frozen"]
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
}

func _section_of_cell(cell: Vector2i) -> String:
	for sec in main.SECTIONS:
		if sec["grid_pos"] == cell:
			return sec["name"]
	return ""

func _region_sprite(path: String, region: Rect2i) -> Sprite2D:
	var spr := Sprite2D.new()
	spr.texture = load(path)
	spr.region_enabled = true
	spr.region_rect = Rect2(region)
	return spr

func _dress_shelves() -> void:
	for shelf_body in main.shelves:
		var section := _section_of_cell(main._grid_cell_of(shelf_body.global_position))
		var shelf: Node = shelf_body.get_node("Shelf")
		var upright: float = -shelf_body.global_rotation
		if section in FURNITURE_SECTIONS:
			# A child of the body polygon, so it keeps the wreck tilt Shelf.gd
			# puts on that polygon; counter-rotated so it's never upside down.
			var polygon: Polygon2D = shelf_body.get_node("Polygon2D")
			var bounds := Rect2(polygon.polygon[0], polygon.polygon[2] - polygon.polygon[0])
			var unit := _region_sprite(SHELF_SHEET, EMPTY_SHELF_UNIT)
			unit.name = "ShelfArt"
			unit.position = bounds.get_center()
			unit.rotation = upright
			unit.scale = bounds.size / Vector2(EMPTY_SHELF_UNIT.size)
			polygon.self_modulate.a = 0.0
			polygon.add_child(unit)
		if section in SLOT_ART_SECTIONS:
			for slot in shelf._all_slots:
				var bay := _region_sprite(SHELF_SHEET, EMPTY_SHELF_BAY)
				bay.name = "EmptyShelfArt"
				bay.rotation = upright
				bay.scale = SLOT_BAY_SIZE / Vector2(EMPTY_SHELF_BAY.size)
				slot.add_child(bay)
				slot.move_child(bay, 0) # under the outline and the C prompt

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
	var entry: Array = PRODUCT_SPRITES[section]
	var regions: Array = entry[1]
	var region: Rect2i = regions[absi(String(node.name).hash()) % regions.size()]
	var spr := _region_sprite(entry[0], region)
	spr.name = "ProductArt"
	spr.scale = Vector2.ONE * (PRODUCT_SIZE / float(maxi(region.size.x, region.size.y)))
	visual.self_modulate.a = 0.0
	node.add_child(spr)
