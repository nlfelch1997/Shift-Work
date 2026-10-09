extends RefCounted
## PHASE 5B PART 2B — test spots, shared by every test and screenshot tool
## (tools/hazards_test.gd and the standalone ones). Not part of the game.
##
## area_spot(main, id, offset): a spot in a named room of the layout table
## (StoreLayout.gd) — its reference point (reference_of()) plus an offset, kept
## in the world and, if it lands on something solid, moved to the nearest
## open floor of the store's real geometry (tools/bot_nav.gd: walls, closed
## barriers, shelves, registers, displays, furniture). Part 2A's offsets
## were chosen for the old nine rooms' interiors (open boxes); Plan B's
## rooms have gondolas, registers and pads inside. A test that needs one
## particular spot names it in the table (an anchor) instead.

const BotNav := preload("res://tools/bot_nav.gd")

static var _navs := {} # main instance id -> its BotNav

static func nav(main: Node) -> RefCounted:
	var k := main.get_instance_id()
	if not _navs.has(k):
		_navs[k] = BotNav.new(main)
	return _navs[k]

static func area_spot(main: Node, id: String, offset := Vector2.ZERO) -> Vector2:
	var p: Vector2 = reference_of(main, id) + offset
	var w: Rect2 = main.areas.world_rect().grow(-30.0)
	if main.areas.role_of(id) == "sidewalk":
		w = main.areas.rect_of(id).grow(-20.0) # (a shallow strip: keep it on the pavement)
	p = Vector2(clampf(p.x, w.position.x, w.end.x), clampf(p.y, w.position.y, w.end.y))
	# Not in a wing that isn't bought yet (an empty lot): pulled back into the
	# nearest open room of the one asked for and its neighbours.
	var a: RefCounted = main.areas
	var here: String = a.area_at(p)
	if here != "" and not a.is_open(here) and a.role_of(here) == "section":
		var best := p
		var best_d := INF
		for r in [id] + a.area(id).get("links", []):
			if not a.is_open(r) or a.role_of(r) == "sidewalk" and r != id:
				continue
			var rr: Rect2 = a.rect_of(r).grow(-30.0)
			var q := Vector2(clampf(p.x, rr.position.x, rr.end.x), clampf(p.y, rr.position.y, rr.end.y))
			if q.distance_to(p) < best_d:
				best_d = q.distance_to(p)
				best = q
		p = best
	return open_floor_near(main, p)

## The point a room's test offsets are measured from. They were written
## against the old rooms' centres, so this is the place in Plan B that plays
## the same part, read from the layout table: the checkout's is 250 px inside
## the front door (the old hub's centre was 250 px from its open south edge,
## the way out); a section's is the middle of its open floor (its spawn band —
## the old sections' centre was their open middle aisle); anything else's
## (the break room, which didn't move; Storage, which moved as one block)
## its centre.
static func reference_of(main: Node, id: String) -> Vector2:
	var a: RefCounted = main.areas
	if a.role_of(id) == "hub":
		return a.anchor("front_door") + Vector2(0.0, -250.0)
	if a.role_of(id) == "section":
		return a.spawn_band_of(id).get_center()
	return a.center_of(id)

## The nearest point of open floor to `p` (itself if it's open), on the
## store's structure as it stands now (closed barriers solid).
static func open_floor_near(main: Node, p: Vector2) -> Vector2:
	var n: RefCounted = nav(main)
	n.path(p, p) # (re)builds the grid if it's stale
	var c: Vector2i = n._to_cell(p)
	if not n._astar.is_point_solid(c):
		return p
	var o: Vector2i = n._open_cell_near(c)
	return p if o == Vector2i(-1, -1) else n._cell_center(o)

## Somewhere nobody works (the far west pavement): where tests park the
## manager so his vision cone can't catch anyone (was the old empty lot).
static func out_of_the_way(main: Node, offset := Vector2.ZERO) -> Vector2:
	return main.areas.anchor("out_of_the_way") + offset
