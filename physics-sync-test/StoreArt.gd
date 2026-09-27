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
## - The B-sheet objects (fixtures, products) are NOT used here — see the
##   Week 13 report: most supermarket fixtures aren't on the 48px grid, and
##   only some sections have separable product sprites.
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
