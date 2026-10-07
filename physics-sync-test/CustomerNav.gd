extends RefCounted
## OCT 2026 PHASE 3B — WHERE SHOPPERS WALK (host only, owned by Main.gd).
##
## Before this phase a shopper walked in a straight line at the nearest
## stocked item, with Customer.gd's stuck-detection nudging it sideways off
## whatever it hit. "Nearest" kept it in the hub's own spokes, so that mostly
## worked. A shopping list sends it anywhere: to Bakery (which hangs off Dry
## Goods — the straight line from the door runs into the sealed Bakery/Produce
## wall), round the back of a shelf, across the checkout rows. Found by
## tools/shopping_test.gd's traffic test: shoppers pinned against the Bakery
## seal, the far end of Produce's bottom shelf, the backs of Dry Goods' east
## shelves and the register counters, until their time ran out — and clean
## main showed the same pins, just less often (it rarely sent anyone there).
##
## So shoppers path, the way Helper.gd already does in its one room: a grid
## over the whole store (Godot's AStarGrid2D), with every wall, closed gate,
## shelf, register and floor display marked solid (plus a body's clearance),
## and the Break Room and Storage left out (customers never go there — see
## Customer.gd's _keep_outside_excluded_zones()). Paths are straightened by
## line of sight, so a walk is a few straight legs, not grid steps. Moving
## loose stock and delivery boxes on the floor are in it too (a shopper never
## pushes them). People aren't: shoppers pass through each other (Customer.gd's
## _ready()), and the existing stuck-detection handles players and disruptive
## customers, with a stall re-planning. The Produce forklift is, where it
## stands at each rebuild (Helper.gd does the same). Disruptive
## customers don't use this (their whole point is bumping into things).
##
## Cost: the grid is rebuilt at most every REBUILD_EVERY seconds, and only
## when a shopper asks for a path (displays get knocked about; gates open when
## a section is bought); marking only touches each obstacle's own cells. A
## path is a few hundred cells of A* — each shopper asks again only when its
## goal changes, it stalls, or every Customer.REPLAN_EVERY seconds.

const GRID := 20.0
## Half a customer (a 28px box) plus a little: the gap a path keeps.
const CLEARANCE := 16.0
const DISPLAY_RADIUS := 32.0 # a 44px display, any rotation (Helper.gd's number)
const REBUILD_EVERY := 1.0
const LOOSE_RADIUS := 16.0 # a 28px product lying anywhere (a box is bigger, but rarer on the floor)

## OCT 2026 PHASE 4B: the janitor (Janitor.gd) walks this same grid, in its
## own instance with Storage left IN (the dumpster is out there) and the
## delivery forklift's working floor — its lane, the dock and the receiving
## row — marked solid instead (JANITOR_KEEP_OUT), so a path to the dumpster
## goes round the forklift's floor, never across it. Customers' grid is
## unchanged (false).
var for_janitor := false
## Storage's forklift floor (world rect): the lane (Delivery.LANE_Y 1250 +-
## the forklift's half-length and a body), the receiving row (y 1450) and
## everything east to the dock. The dumpster (x 1975-2085) is west of it.
const JANITOR_KEEP_OUT := Rect2(2150.0, 1150.0, 730.0, 360.0)

var main: Node
var _astar := AStarGrid2D.new()
var _built_at := -INF
## Host diagnostics (tools/shopping_test.gd prints them): what it costs.
var builds := 0
var build_us := 0
var paths := 0
var path_us := 0
var path_us_max := 0

func _init(main_node: Node) -> void:
	main = main_node
	var size := Vector2(main.ROOM_WIDTH * 3.0, main.ROOM_HEIGHT * 3.0)
	_astar.region = Rect2i(0, 0, int(size.x / GRID), int(size.y / GRID))
	_astar.cell_size = Vector2(GRID, GRID)
	_astar.offset = Vector2(GRID, GRID) * 0.5
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_astar.update()

## Waypoints from `from` to `to` (the last one is `to` itself). Just [to] when
## there's no grid route (the caller then walks straight, as before).
func path(from: Vector2, to: Vector2) -> PackedVector2Array:
	var t0 := Time.get_ticks_usec()
	var now := t0 / 1000000.0
	if now - _built_at >= REBUILD_EVERY:
		_build()
		_built_at = now
		builds += 1
		build_us += Time.get_ticks_usec() - t0
	var t1 := Time.get_ticks_usec()
	var out := _path(from, to)
	var took := Time.get_ticks_usec() - t1
	paths += 1
	path_us += took
	path_us_max = maxi(path_us_max, took)
	return out

func _path(from: Vector2, to: Vector2) -> PackedVector2Array:
	var a := _open_cell_near(_to_cell(from))
	var b := _open_cell_near(_to_cell(to))
	if a == Vector2i(-1, -1) or b == Vector2i(-1, -1):
		return PackedVector2Array([to])
	var pts := _astar.get_point_path(a, b)
	if pts.is_empty():
		return PackedVector2Array([to])
	pts.append(to)
	return _smooth(from, pts)

## Forces the next path() to rebuild (a section was bought, a new shift).
func invalidate() -> void:
	_built_at = -INF

func _build() -> void:
	_astar.fill_solid_region(_astar.region, false)
	for zone in ([main.BREAK_ROOM_GRID_POS] if for_janitor else [main.BREAK_ROOM_GRID_POS, main.STORAGE_GRID_POS]):
		_solid_world_rect(Rect2(Vector2(zone.x * main.ROOM_WIDTH, zone.y * main.ROOM_HEIGHT), Vector2(main.ROOM_WIDTH, main.ROOM_HEIGHT)))
	if for_janitor:
		_solid_world_rect(JANITOR_KEEP_OUT)
	for body in main.get_node("Walls").get_children():
		_solid_body(body)
	for gate in main.get_node("Gates").get_children():
		var cs := gate.get_node_or_null("CollisionShape2D") as CollisionShape2D
		if cs != null and not cs.disabled:
			_solid_body(gate)
	for shelf_body in main.shelves:
		_solid_body(shelf_body)
	for cashier_body in main.cashiers:
		_solid_body(cashier_body)
	for d in main.displays:
		_solid_circle(d.global_position, DISPLAY_RADIUS + CLEARANCE)
	# OCT 2026 PHASE 3D: anything solid placed in code (the dumpster,
	# Cleanup.gd) joins "nav_obstacle". Trash cans have no collision.
	for body in main.get_tree().get_nodes_in_group("nav_obstacle"):
		_solid_body(body)
	# Loose stock and delivery boxes on the floor (a shopper never pushes them).
	for obj in main.get_tree().get_nodes_in_group("carryable"):
		var c: Node = obj.get_node("Carryable")
		if c.carrier_id == 0 and not c.shelved and not obj.is_queued_for_deletion():
			_solid_circle(obj.global_position, LOOSE_RADIUS + CLEARANCE)
	# The Produce forklift where it is right now (it patrols, pauses at its
	# lane's ends and parks — a shopper re-plans round it, as a helper does).
	if main.forklift.visible:
		_solid_body(main.forklift)
	if for_janitor and main.delivery_forklift != null and main.delivery_forklift.visible:
		_solid_body(main.delivery_forklift)

func _solid_body(body: Node) -> void:
	for cs in body.get_children():
		if cs is CollisionShape2D and cs.shape is RectangleShape2D:
			_solid_rect(cs.global_transform, (cs.shape as RectangleShape2D).size * 0.5 + Vector2(CLEARANCE, CLEARANCE))

## Every cell whose centre is inside the (rotated) rectangle — only the cells
## under its bounding box are looked at.
func _solid_rect(xf: Transform2D, half: Vector2) -> void:
	var corners := [xf * Vector2(-half.x, -half.y), xf * Vector2(half.x, -half.y), xf * Vector2(half.x, half.y), xf * Vector2(-half.x, half.y)]
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c in corners:
		lo = lo.min(c)
		hi = hi.max(c)
	var inv := xf.affine_inverse()
	var c0 := _to_cell(lo)
	var c1 := _to_cell(hi)
	for x in range(c0.x, c1.x + 1):
		for y in range(c0.y, c1.y + 1):
			var local: Vector2 = inv * _cell_center(Vector2i(x, y))
			if absf(local.x) <= half.x and absf(local.y) <= half.y:
				_astar.set_point_solid(Vector2i(x, y), true)

func _solid_world_rect(r: Rect2) -> void:
	var c0 := _to_cell(r.position)
	var c1 := _to_cell(r.end - Vector2(0.01, 0.01))
	for x in range(c0.x, c1.x + 1):
		for y in range(c0.y, c1.y + 1):
			_astar.set_point_solid(Vector2i(x, y), true)

func _solid_circle(center: Vector2, radius: float) -> void:
	var c0 := _to_cell(center - Vector2(radius, radius))
	var c1 := _to_cell(center + Vector2(radius, radius))
	for x in range(c0.x, c1.x + 1):
		for y in range(c0.y, c1.y + 1):
			if _cell_center(Vector2i(x, y)).distance_to(center) <= radius:
				_astar.set_point_solid(Vector2i(x, y), true)

## Phase 4B (the janitor): is there a grid route at all (path() falls back to
## a straight line when there isn't)?
func reachable(from: Vector2, to: Vector2) -> bool:
	var a := _open_cell_near(_to_cell(from))
	var b := _open_cell_near(_to_cell(to))
	return a != Vector2i(-1, -1) and b != Vector2i(-1, -1) and not _astar.get_id_path(a, b).is_empty()

## Phase 4B (the janitor): is this world point on open floor in the grid as
## last built? (Its forklift side-step only steps onto open cells.)
func is_open(p: Vector2) -> bool:
	return not _astar.is_point_solid(_to_cell(p))

func _to_cell(p: Vector2) -> Vector2i:
	return Vector2i(clampi(int(floor(p.x / GRID)), 0, _astar.region.size.x - 1), clampi(int(floor(p.y / GRID)), 0, _astar.region.size.y - 1))

func _cell_center(c: Vector2i) -> Vector2:
	return (Vector2(c) + Vector2(0.5, 0.5)) * GRID

## The goal (or the shopper) can sit in a solid cell — a slot's stand point
## close to a shelf, a shopper shoved against one: use the nearest open cell.
func _open_cell_near(c: Vector2i) -> Vector2i:
	if not _astar.is_point_solid(c):
		return c
	for r in range(1, 6):
		var best := Vector2i(-1, -1)
		var best_d := INF
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var n := c + Vector2i(dx, dy)
				if _astar.is_in_boundsv(n) and not _astar.is_point_solid(n):
					var d := Vector2(dx, dy).length()
					if d < best_d:
						best_d = d
						best = n
		if best != Vector2i(-1, -1):
			return best
	return Vector2i(-1, -1)

## Straightens the grid path: from each anchor, walk forward while the next
## point is still in plain sight, and keep the last one that was. Linear in
## the path's length (Helper.gd's version tries every later point from every
## anchor, which is fine in one room but quadratic on a store-wide path —
## found as frame spikes in the soak).
func _smooth(from: Vector2, pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	var anchor := from
	var i := 0
	while i < pts.size():
		var j := i
		while j + 1 < pts.size() and _clear_line(anchor, pts[j + 1]):
			j += 1
		out.append(pts[j])
		anchor = pts[j]
		i = j + 1
	return out

func _clear_line(a: Vector2, b: Vector2) -> bool:
	var n := int(a.distance_to(b) / (GRID * 0.5)) + 1
	for k in range(1, n):
		var c := _to_cell(a.lerp(b, float(k) / n))
		if _astar.is_point_solid(c):
			return false
	return true
