extends RefCounted
## PHASE 5B PART 2A — THE NAMED-AREA REGISTRY (owned by Main.gd: main.areas).
##
## Answers "what is at this position?" from the layout table
## (StoreLayout.gd) instead of from 960 x 540 screen-cell arithmetic, which
## used to be repeated in about a dozen scripts. See StoreLayout.gd's header
## for what an area is.
##
## SAME ANSWER ON EVERY PEER, NO NEW NETWORK STATE: the table is a constant,
## and the only live input — whether a section is open — is asked of
## Main.is_section_open() at the moment of the question, which already reads
## replicated state (sections_owned, the practice flag). So a client answers
## exactly as the host does, a frame lag included, as before.
##
## COST: area_at() is called a lot (customers, helpers, cans, spills every
## tick). It looks a point up in a 20 px index built once from the table
## (one array read for any point well inside a room); only an index cell that
## straddles a room edge falls back to testing the rooms that touch it. On
## today's table every room edge is on the 20 px grid, so the fallback never
## runs. Equal to the old floor(x / 960) everywhere: a room includes its
## top/left edge and excludes its bottom/right edge, as the cell math did.
##
## Hooks for growth (Part 2B): area_opened / area_closed fire, on every peer,
## when a room or feature tied to a section changes state; Main calls
## refresh_open_state() wherever it already re-applies the locked look.

signal area_opened(id: String)
signal area_closed(id: String)

const Layout := preload("res://StoreLayout.gd")
const INDEX_CELL := 20.0

var _rooms: Array = [] # the table's ROOMS, in table order
var _features: Array = []
var _by_id := {} # id -> its dictionary (rooms and features)
var _room_of_section := {} # section name -> room id
var _index := PackedInt32Array() # per index cell: room index, -1 none, -2 "test the candidates"
var _candidates := {} # index cell number -> [room index, ...]
var _index_size := Vector2i.ZERO
var _world := Rect2()
## Callable(section_name: String) -> bool. Main.gd binds its own check.
var _section_open: Callable
var _open_state := {} # id -> last open state refresh_open_state() saw

func _init(section_open: Callable = Callable()) -> void:
	_section_open = section_open
	_world = Layout.WORLD
	for r in Layout.ROOMS:
		_rooms.append(r)
		_by_id[r["id"]] = r
		if r.get("section", "") != "":
			_room_of_section[r["section"]] = r["id"]
	for f in Layout.FEATURES:
		_features.append(f)
		_by_id[f["id"]] = f
	_build_index()

## --- what is where ---------------------------------------------------------

## The id of the room `pos` is in ("" outside every room).
func area_at(pos: Vector2) -> String:
	var i := _room_index_at(pos)
	return _rooms[i]["id"] if i >= 0 else ""

## The room's role ("section", "hub", "storage", ...; "" outside every room).
func role_at(pos: Vector2) -> String:
	var i := _room_index_at(pos)
	return _rooms[i]["role"] if i >= 0 else ""

## The section (Main.SECTIONS name) `pos` is in, "" outside the sections.
func section_of(pos: Vector2) -> String:
	var i := _room_index_at(pos)
	return _rooms[i].get("section", "") if i >= 0 else ""

## The room that holds a section ("" if none).
func room_of_section(sec_name: String) -> String:
	return _room_of_section.get(sec_name, "")

func has_area(id: String) -> bool:
	return _by_id.has(id)

## The area's table entry (a room or a feature), read-only.
func area(id: String) -> Dictionary:
	return _by_id.get(id, {})

func rect_of(id: String) -> Rect2:
	var a: Dictionary = _by_id.get(id, {})
	if a.has("rect"):
		return a["rect"]
	if a.has("polygon"):
		var pts: PackedVector2Array = a["polygon"]
		var r := Rect2(pts[0], Vector2.ZERO)
		for p in pts:
			r = r.expand(p)
		return r
	return Rect2()

func center_of(id: String) -> Vector2:
	return rect_of(id).get_center()

func role_of(id: String) -> String:
	return _by_id.get(id, {}).get("role", "")

## Every room's id, in table order.
func room_ids() -> Array:
	return _rooms.map(func(r): return r["id"])

## Every room (or feature, with features=true) of a role, in table order.
func ids_with_role(role: String, features := false) -> Array:
	var out := []
	for a in (_features if features else _rooms):
		if a["role"] == role:
			out.append(a["id"])
	return out

## The first feature of a role whose area contains `pos` ("" if none).
func feature_at(pos: Vector2, role: String) -> String:
	for f in _features:
		if f["role"] == role and _contains(f, pos):
			return f["id"]
	return ""

## Rooms, then features, whose table entry sets `flag` ("shoppers",
## "janitor") to false — the walkers' nav grids leave them out.
func ids_without(flag: String) -> Array:
	var out := []
	for a in _rooms + _features:
		if not a.get(flag, true):
			out.append(a["id"])
	return out

func in_area(id: String, pos: Vector2) -> bool:
	return _by_id.has(id) and _contains(_by_id[id], pos)

func world_rect() -> Rect2:
	return _world

## --- open / closed ---------------------------------------------------------

## A section's room (or feature) is open while its section is; an "empty" lot
## never is; everything else always is.
func is_open(id: String) -> bool:
	var a: Dictionary = _by_id.get(id, {})
	if a.is_empty() or a.get("role", "") == "empty":
		return false
	var sec: String = a.get("section", "")
	if sec == "" and a.has("room"):
		sec = _by_id.get(a["room"], {}).get("section", "")
	if sec == "":
		return true
	return _section_open.is_valid() and _section_open.call(sec)

## In a SECTION that's open (Main.is_unlocked_at_pos()): false on the hub,
## Storage, the break room and the sidewalk — they have no shelves.
func is_section_open_at(pos: Vector2) -> bool:
	var i := _room_index_at(pos)
	if i < 0 or _rooms[i].get("section", "") == "":
		return false
	return _section_open.is_valid() and _section_open.call(_rooms[i]["section"])

## Open shop floor: the hub, or an open section (litter, the janitor's work).
func is_open_shop_floor_at(pos: Vector2) -> bool:
	var i := _room_index_at(pos)
	if i < 0 or not _rooms[i].get("shop_floor", false):
		return false
	return _rooms[i].get("section", "") == "" or is_section_open_at(pos)

## Customers may be here (not the break room, not Storage).
func shoppers_allowed_at(pos: Vector2) -> bool:
	var i := _room_index_at(pos)
	return i < 0 or _rooms[i].get("shoppers", true)

## Re-reads every section-tied area's state and fires area_opened /
## area_closed for any that changed since the last call (the first call only
## records). Local to each peer; derived from replicated state.
func refresh_open_state() -> void:
	var first := _open_state.is_empty()
	for id in _by_id:
		var a: Dictionary = _by_id[id]
		if a.get("section", "") == "" and not (a.has("room") and _by_id.get(a["room"], {}).get("section", "") != ""):
			continue
		var now := is_open(id)
		if not first and _open_state.get(id, now) != now:
			if now:
				area_opened.emit(id)
			else:
				area_closed.emit(id)
		_open_state[id] = now

## --- walking between rooms -------------------------------------------------

## Rooms to walk through from `from_id` to `to_id` (from excluded, to
## included) over the table's links, stepping only through rooms `via`
## accepts (a Callable(id) -> bool). Breadth-first in link order, so the same
## table always gives the same route. [to_id] if there's no such route.
func route(from_id: String, to_id: String, via: Callable) -> Array:
	if from_id == to_id:
		return [to_id]
	var came := {from_id: ""}
	var queue := [from_id]
	while not queue.is_empty():
		var cur: String = queue.pop_front()
		for n in _by_id.get(cur, {}).get("links", []):
			if came.has(n):
				continue
			if n == to_id:
				var path := [to_id]
				var back := cur
				while back != from_id:
					path.push_front(back)
					back = came[back]
				return path
			if via.call(n):
				came[n] = cur
				queue.append(n)
	return [to_id]

## --- anchors ---------------------------------------------------------------

## A named point from the table's ANCHORS.
func anchor(name: String) -> Vector2:
	return Layout.ANCHORS[name]

## A section's unpack pad.
func pad_of(sec_name: String) -> Vector2:
	return Layout.PADS[sec_name]

## A room's room-local spawn band as a world Rect2 (sections only).
func spawn_band_of(id: String) -> Rect2:
	var r := rect_of(id)
	var b: Rect2 = _by_id[id]["spawn_band"]
	return Rect2(r.position + b.position, b.size)

## --- the snapshot (tools/areas_test.gd) --------------------------------------

## A plain-text dump of the whole table as the registry reads it, one line
## per fact, for comparing against a saved copy.
func snapshot() -> String:
	var out := PackedStringArray()
	out.append("world %s" % str(_world))
	for r in _rooms:
		out.append("room %s role=%s rect=%s section=%s shoppers=%s janitor=%s shop_floor=%s bg=%s wall_art=%s links=%s band=%s helper=%s" % [
			r["id"], r["role"], str(rect_of(r["id"])), r.get("section", ""), str(r.get("shoppers", true)), str(r.get("janitor", true)),
			str(r.get("shop_floor", false)), r.get("bg", ""), r.get("wall_art", ""), str(r.get("links", [])),
			str(r.get("spawn_band", "")), str(r.get("helper", ""))])
	for f in _features:
		out.append("feature %s role=%s room=%s rect=%s janitor=%s" % [f["id"], f["role"], f.get("room", ""), str(rect_of(f["id"])), str(f.get("janitor", true))])
	var names := Layout.ANCHORS.keys()
	names.sort()
	for n in names:
		out.append("anchor %s %s" % [n, str(Layout.ANCHORS[n])])
	for s in Layout.PADS:
		out.append("pad %s %s" % [s, str(Layout.PADS[s])])
	for i in Layout.CANS.size():
		out.append("can %d %s %s" % [i, str(Layout.CANS[i]["pos"]), Layout.CANS[i]["section"]])
	out.append("tools %s" % str(Layout.TOOL_SPOTS))
	out.append("practice_litter %s" % str(Layout.PRACTICE_LITTER))
	out.append("dock lane_y=%s dock_x=%s receiving=%s" % [str(Layout.DOCK_LANE_Y), str(Layout.DOCK_X), str(Layout.RECEIVING_SPOTS)])
	out.append("checkout %s" % str(Layout.CHECKOUT))
	return "\n".join(out) + "\n"

## --- the index -------------------------------------------------------------

func _contains(a: Dictionary, pos: Vector2) -> bool:
	if a.has("rect"):
		return (a["rect"] as Rect2).has_point(pos)
	if a.has("polygon"):
		return Geometry2D.is_point_in_polygon(pos, a["polygon"])
	return false

func _room_index_at(pos: Vector2) -> int:
	var cx := int(floor(pos.x / INDEX_CELL))
	var cy := int(floor(pos.y / INDEX_CELL))
	if cx < 0 or cy < 0 or cx >= _index_size.x or cy >= _index_size.y:
		return -1 # (outside the world: no room is — Layout.WORLD holds them all)
	var k := cy * _index_size.x + cx
	var i := _index[k]
	if i != -2:
		return i
	for j in _candidates[k]:
		if _contains(_rooms[j], pos):
			return j
	return -1

## Each 20 px cell of the world: the one room that covers all of it, nobody,
## or (-2) the rooms that touch it, tested point by point.
func _build_index() -> void:
	_index_size = Vector2i(int(ceil(_world.end.x / INDEX_CELL)), int(ceil(_world.end.y / INDEX_CELL)))
	_index.resize(_index_size.x * _index_size.y)
	_index.fill(-1)
	for cy in _index_size.y:
		for cx in _index_size.x:
			var cell := Rect2(Vector2(cx, cy) * INDEX_CELL, Vector2(INDEX_CELL, INDEX_CELL))
			var touching := []
			var covered := -1
			for j in _rooms.size():
				var bounds := rect_of(_rooms[j]["id"])
				if not bounds.intersects(cell):
					continue
				touching.append(j)
				if _rooms[j].has("rect") and bounds.encloses(cell):
					covered = j
			var k := cy * _index_size.x + cx
			if touching.size() == 1 and covered == touching[0]:
				_index[k] = covered
			elif not touching.is_empty():
				_index[k] = -2
				_candidates[k] = touching
