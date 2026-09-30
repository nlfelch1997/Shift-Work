extends Node2D
## WEEK 11 (Day 6+) — THE ENVIRONMENTAL TWIST. Not a new NPC: the store
## itself gets worse. Two passive layers, both day-gated on every peer by
## configure() (called from Main.gd's _configure_hazards(), same as the
## forklift and the manager), both host-authoritative and replicated through
## this node's own "Sync" synchronizer (built in _ready(), same pattern as
## Main.gd's DaySync). Built entirely in code — nothing new in a .tscn, see
## Main.gd's header note on .tscn comments.
##
## 1. FLICKERING LIGHTS. There was no lighting system to hook into (no
##    Light2D, CanvasModulate or shaders anywhere; every visual is a flat
##    Polygon2D at the default z_index), so darkness is a world-space overlay
##    (a Polygon2D covering the whole map at Z_DARKNESS) plus a vignette that
##    follows this peer's own camera. Every so often the host starts a
##    "lights event": a burst of flicker, a brownout hold (dim, with the
##    occasional buzz-dip), then a flicker back up. The whole pattern comes
##    from a seed — the host replicates only (lights_event_id,
##    lights_event_seed) and every peer builds the identical pattern locally
##    and plays it from the moment the id changes, so a flicker looks the
##    same on everyone's screen (offset by latency only) without streaming
##    a brightness value every frame.
##    FAIRNESS: the darkness never hides a WARNING. Everything a player
##    reacts to is drawn above the overlay (Z_EMISSIVE, _mark_emissive()):
##    the forklift's beacon and BEEP, the manager's "?"/"!", his name tag
##    and vision cone, the shelves' "C" prompts, and the spills' wet-floor
##    signs. Nothing mechanical reads the light level — the manager's
##    detection and the forklift are unchanged. The UI (CanvasLayers) is
##    untouched by construction. Floors: brownout LIGHTS_DIM_LEVEL, flicker
##    dips to LIGHTS_FLICKER_LOW only for a split second.
##
## 2. FLOOR SPILLS. Random leaks in an unlocked section's open aisle band
##    (the same band products spawn in). Each one spends SPILL_FORM_TIME
##    spreading (visible, harmless — the telegraph, same spirit as the
##    forklift's beacon), then is wet for SPILL_WET_TIME, then drying for
##    SPILL_DRY_TIME (still slippery, visibly fading), then gone. Standing in
##    a wet spill (Player.gd): top speed x SPILL_SPEED_FACTOR and low
##    traction — velocity eases toward your input at SPILL_TRACTION instead
##    of snapping to it, so you slide on turns and stops, and keep that
##    slide for SPILL_SLIDE_OUT after stepping off. It never blocks you.
##    Movement is client-authoritative, so each peer checks its OWN player
##    against the replicated `spills` list (slippery_at()).
##    WHERE THEY DON'T GO (checked at spawn, _spill_spot_ok()): near a
##    player (never forms under your feet), on the forklift's lane (a slide
##    into its path is the one combination that reads as cheap), in front
##    of a shelf slot (you'd have no dry place to stock from), or on
##    another spill.
##    PASSIVE THIS WEEK, NO MOP (flagged design decision): spills dry up on
##    their own. A mop would be the first held object that isn't stock, and
##    the only held-object system here is Carryable, which IS stock (product
##    cap, day reset, shoppers buy it, shelves take it, priority orders tag
##    it) — the same trap Display.gd had to route around. Mop/broom/trash
##    want one shared "tool" carry path, built once for the cleanup week.
##    remove_spill() is the hook a mop would call. (WEEK 19: it does — the
##    end-of-shift cleanup phase, Cleanup.gd. Spills are still passive during
##    the shift; whatever's on the floor at close stops drying and gets
##    mopped, or costs cleanliness bonus.)
##    NOT from toppled displays (considered first, since Display.tscn already
##    draws a little spill when one tips over): the Meat/Deli sample table
##    sits right on the forklift's lane and gets knocked over by it most
##    laps, so it would pin a slip hazard onto the lane every lap. The
##    display's own cosmetic spill art is unchanged.
##    The manager doesn't write you up for sliding into stock or a display
##    while on a spill (Manager.gd's note_push(), SPILL_EXCUSE_MARGIN).
##
## Every number below is a FLAGGED placeholder, tuned against the solo and
## co-op bot passes in tools/hazards_test.gd, not a human playtest.

const LIGHTS_START_DAY := 6
const SPILLS_START_DAY := 6

## --- Lights ---
const LIGHTS_FIRST_DELAY := 14.0 # s into the shift before the first event
const LIGHTS_INTERVAL_MIN := 18.0 # s of normal light between events
const LIGHTS_INTERVAL_MAX := 30.0
const LIGHTS_FLICKER_IN_MIN := 1.2 # s of on/off flicker going down
const LIGHTS_FLICKER_IN_MAX := 2.0
const LIGHTS_DIM_MIN := 5.0 # s of brownout
const LIGHTS_DIM_MAX := 9.0
const LIGHTS_FLICKER_OUT_MIN := 0.6 # s of flicker coming back up
const LIGHTS_FLICKER_OUT_MAX := 1.0
const LIGHTS_DIM_LEVEL := 0.55 # brightness during the brownout (1 = normal)
const LIGHTS_BUZZ_LEVEL := 0.42 # the occasional dip during the brownout
const LIGHTS_FLICKER_LOW := 0.3 # darkest a flicker gets — for <= 0.16s at a time
const VIGNETTE_STRENGTH := 0.6 # edge darkness at full brownout, on top of the dim
const DARKNESS_COLOR := Color(0.02, 0.02, 0.07)

## --- Spills ---
const SPILL_FIRST_DELAY := 8.0
const SPILL_INTERVAL_MIN := 16.0
const SPILL_INTERVAL_MAX := 26.0
const SPILL_MAX := 3
## WEEK 12 — Day 7 finale (configure()'s is_finale): one more spill allowed
## at once (on top of the per-extra-player +1), and they come a bit faster —
## at the Day 6 cadence (one every ~21s, each ~41s long) the cap of 3 almost
## never binds, so raising it alone would change nothing. Lights: the same
## event (depth and length are the readability-tuned part), shorter gaps.
## FLAGGED placeholders.
const FINALE_SPILL_MAX_BONUS := 1
const FINALE_SPILL_INTERVAL_MIN := 12.0
const FINALE_SPILL_INTERVAL_MAX := 20.0
const FINALE_LIGHTS_INTERVAL_MIN := 12.0
const FINALE_LIGHTS_INTERVAL_MAX := 22.0
const SPILL_MAX_PER_EXTRA_PLAYER := 1
const SPILL_RADIUS_MIN := 38.0
const SPILL_RADIUS_MAX := 54.0
const SPILL_FORM_TIME := 1.5
const SPILL_WET_TIME := 34.0
const SPILL_DRY_TIME := 6.0
const SPILL_SPEED_FACTOR := 0.7 # Player.gd: top speed on a wet spill
const SPILL_TRACTION := 420.0 # Player.gd: px/s^2 — how fast velocity follows input (off a spill: instant)
const SPILL_SLIDE_OUT := 0.3 # Player.gd: s of low traction after stepping off
const SPILL_EXCUSE_MARGIN := 70.0 # Manager.gd: within this of a spill's edge, a push isn't chaos
const SPILL_CLEAR_PLAYER := 130.0 # spawn clearances, from the spill's center
const SPILL_CLEAR_FORKLIFT_LANE := 60.0 # + radius, either side of the lane
const SPILL_CLEAR_SLOT := 45.0 # + radius
const SPILL_CLEAR_SPILL := 50.0 # + both radii
## WEEK 16: 28 (was 14). The new wall shelves (Main.gd's WEEK 16 note) left
## less open aisle, so more random picks land in front of a slot; with 14 tries
## about a fifth of spill rounds found no spot at all (the round is skipped),
## which quietly thinned Day 6+ spills. More tries restores the rate without
## touching where a spill is allowed. Plumbing, not a balance knob.
const SPILL_SPAWN_ATTEMPTS := 28
const SPILL_COLOR := Color(0.55, 0.75, 0.35, 0.72) # something green and regrettable

const Z_DARKNESS := 100
const Z_EMISSIVE := 110
const PHASE_FORMING := 0
const PHASE_WET := 1
const PHASE_DRYING := 2

## Every peer, from configure(): is today a Day 6+ day. Not replicated —
## each peer derives it from the replicated current_day, like the forklift.
var active := false
var finale := false

## Host-written, replicated (see _ready()).
var lights_event_id := 0 # 0 = no event (lights normal)
var lights_event_seed := 0
## [{"id": int, "pos": Vector2, "r": float, "phase": int}] — reassigned, never
## mutated in place, on every change.
var spills: Array = []

## Host-only.
var _lights_timer := 0.0
var _lights_clear_timer := 0.0 # counts down the event's length; then the id goes back to 0
var _next_lights_id := 1
var _spill_timer := 0.0
var _next_spill_id := 1
var _spill_age := {} # id -> s since it appeared
var spills_today := 0
var lights_events_today := 0

## Every peer: local playback of the current lights event.
var brightness := 1.0
var _played_event_id := 0
var _pattern: Array = [] # [[end_time, level], ...]
var _pattern_t := 0.0
var _overlay: Polygon2D
var _vignette: Sprite2D
var _spill_root: Node2D
var _spill_nodes := {} # id -> Node2D
var _spill_local_age := {} # id -> s since this peer first saw it

var main: Node

func _ready() -> void:
	main = get_parent()
	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	for prop in [".:lights_event_id", ".:lights_event_seed", ".:spills"]:
		var path := NodePath(prop)
		config.add_property(path)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config
	sync.name = "Sync" # explicit, identical name on every peer — see Player.gd's note
	sync.set_multiplayer_authority(1)
	add_child(sync)

	# Spills sit ON the floor: their own container right after the room
	# backgrounds in tree order, so they draw under shelves, stock and people.
	_spill_root = Node2D.new()
	_spill_root.name = "Spills"
	main.add_child(_spill_root)
	main.move_child(_spill_root, main.get_node("RoomBackgrounds").get_index() + 1)

	_overlay = Polygon2D.new()
	_overlay.name = "Darkness"
	_overlay.polygon = PackedVector2Array([Vector2(0, 0), Vector2(main.WORLD_WIDTH, 0), Vector2(main.WORLD_WIDTH, main.WORLD_HEIGHT), Vector2(0, main.WORLD_HEIGHT)])
	_overlay.color = Color(DARKNESS_COLOR, 0.0)
	_overlay.z_index = Z_DARKNESS
	add_child(_overlay)

	var gradient := Gradient.new()
	gradient.set_offset(0, 0.0)
	gradient.set_color(0, Color(DARKNESS_COLOR, 0.0))
	gradient.set_offset(1, 1.0)
	gradient.set_color(1, Color(DARKNESS_COLOR, 1.0))
	gradient.add_point(0.5, Color(DARKNESS_COLOR, 0.0))
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.width = 256
	tex.height = 256
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	_vignette = Sprite2D.new()
	_vignette.name = "Vignette"
	_vignette.texture = tex
	_vignette.z_index = Z_DARKNESS
	_vignette.modulate.a = 0.0
	add_child(_vignette)

	_mark_emissive()

## The warning tells stay readable in the dark (see the header's FAIRNESS
## note). z_index is relative to the parent, and every parent here is at 0.
func _mark_emissive() -> void:
	# WEEK 15: the Storage delivery forklift's tells too.
	for fk in [main.forklift, main.delivery_forklift]:
		for n in ["Beacon", "BeepAnchor"]:
			fk.get_node(n).z_index = Z_EMISSIVE
	var mgr: Node = main.manager
	for n in ["AlertLabel", "NameLabel", "Facing/Cone"]:
		mgr.get_node(n).z_index = Z_EMISSIVE
	for shelf_body in main.shelves:
		for slot in shelf_body.get_node("Shelf")._all_slots:
			var prompt: Node = slot.get_node_or_null("Prompt")
			if prompt:
				prompt.z_index = Z_EMISSIVE

func configure(day: int, is_finale := false) -> void:
	finale = is_finale
	active = day >= LIGHTS_START_DAY or day >= SPILLS_START_DAY
	if not active:
		_clear_local()

func lights_enabled() -> bool:
	return active and main.current_day >= LIGHTS_START_DAY

func spills_enabled() -> bool:
	return active and main.current_day >= SPILLS_START_DAY

## Host-only, from Main.gd's _start_shift().
func reset_for_new_day() -> void:
	if not multiplayer.is_server():
		return
	spills = []
	_spill_age = {}
	spills_today = 0
	lights_events_today = 0
	lights_event_id = 0
	_lights_timer = LIGHTS_FIRST_DELAY
	_spill_timer = SPILL_FIRST_DELAY

## Host-only, from Main.gd's _end_shift(): lights back on for the report.
func end_shift() -> void:
	if not multiplayer.is_server():
		return
	lights_event_id = 0

## Host-only, every frame of a running shift (Main.gd's _process()).
func tick_host(delta: float) -> void:
	if not multiplayer.is_server():
		return
	if lights_event_id != 0:
		# Back to "no event" a beat after the pattern ends (every peer has
		# finished its own playback by then), so a player who joins later
		# doesn't replay a stale flicker.
		_lights_clear_timer -= delta
		if _lights_clear_timer <= 0.0:
			lights_event_id = 0
	if lights_enabled():
		_lights_timer -= delta
		if _lights_timer <= 0.0:
			start_lights_event()
	if spills_enabled():
		_tick_spills(delta)

## --- Lights ------------------------------------------------------------------

## Host-only. Public so tests can trigger one on demand.
func start_lights_event() -> void:
	if not multiplayer.is_server():
		return
	lights_event_seed = randi()
	lights_event_id = _next_lights_id
	_next_lights_id += 1
	lights_events_today += 1
	var pattern := build_pattern(lights_event_seed)
	_lights_clear_timer = pattern[-1][0] + 0.5
	_lights_timer = pattern[-1][0] + (randf_range(FINALE_LIGHTS_INTERVAL_MIN, FINALE_LIGHTS_INTERVAL_MAX) if finale else randf_range(LIGHTS_INTERVAL_MIN, LIGHTS_INTERVAL_MAX))
	print("[Ambience] Lights event #%d (%.1fs)" % [lights_event_id, pattern[-1][0]])

## Deterministic from the seed alone, so every peer builds the same one.
## Steps of [end_time, brightness]; the last step always ends at 1.0.
static func build_pattern(event_seed: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = event_seed
	var out := []
	var t := 0.0
	# Flicker down: alternating dips and recoveries.
	var flicker_end := rng.randf_range(LIGHTS_FLICKER_IN_MIN, LIGHTS_FLICKER_IN_MAX)
	var low := true
	while t < flicker_end:
		t += rng.randf_range(0.04, 0.16)
		out.append([t, LIGHTS_FLICKER_LOW if low else rng.randf_range(0.75, 1.0)])
		low = not low
	# Brownout hold, in chunks, with the odd quick buzz-dip between them.
	var dim_end := t + rng.randf_range(LIGHTS_DIM_MIN, LIGHTS_DIM_MAX)
	while t < dim_end:
		t = minf(dim_end, t + rng.randf_range(0.8, 2.0))
		out.append([t, LIGHTS_DIM_LEVEL])
		if t < dim_end and rng.randf() < 0.45:
			t += rng.randf_range(0.05, 0.1)
			out.append([t, LIGHTS_BUZZ_LEVEL])
	# Flicker back up, ending on.
	var up_end := t + rng.randf_range(LIGHTS_FLICKER_OUT_MIN, LIGHTS_FLICKER_OUT_MAX)
	var on := true
	while t < up_end:
		t += rng.randf_range(0.05, 0.14)
		out.append([t, 1.0 if on else LIGHTS_DIM_LEVEL])
		on = not on
	out.append([t + 0.01, 1.0])
	return out

func _level_at(t: float) -> float:
	for step in _pattern:
		if t < step[0]:
			return step[1]
	return 1.0

func event_playing() -> bool:
	return _played_event_id != 0 and not _pattern.is_empty() and _pattern_t < _pattern[-1][0]

## --- Spills ------------------------------------------------------------------

func spill_cap() -> int:
	return SPILL_MAX + (FINALE_SPILL_MAX_BONUS if finale else 0) + SPILL_MAX_PER_EXTRA_PLAYER * maxi(0, main.players.size() - 1)

func _tick_spills(delta: float) -> void:
	var changed := false
	var keep := []
	for s in spills:
		var id: int = s["id"]
		var age: float = _spill_age.get(id, 0.0) + delta
		_spill_age[id] = age
		var phase := PHASE_FORMING
		if age >= SPILL_FORM_TIME + SPILL_WET_TIME + SPILL_DRY_TIME:
			_spill_age.erase(id)
			changed = true
			continue
		elif age >= SPILL_FORM_TIME + SPILL_WET_TIME:
			phase = PHASE_DRYING
		elif age >= SPILL_FORM_TIME:
			phase = PHASE_WET
		if phase != s["phase"]:
			s = s.duplicate()
			s["phase"] = phase
			changed = true
		keep.append(s)
	if changed:
		spills = keep
	_spill_timer -= delta
	if _spill_timer <= 0.0:
		_spill_timer = randf_range(FINALE_SPILL_INTERVAL_MIN, FINALE_SPILL_INTERVAL_MAX) if finale else randf_range(SPILL_INTERVAL_MIN, SPILL_INTERVAL_MAX)
		if spills.size() < spill_cap():
			var pos = pick_spill_spot()
			if pos != null:
				spawn_spill(pos, randf_range(SPILL_RADIUS_MIN, SPILL_RADIUS_MAX))

## A random spot that passes _spill_spot_ok(), or null if none turned up
## (the round is simply skipped — never forced into a bad spot).
func pick_spill_spot() -> Variant:
	var r := SPILL_RADIUS_MAX
	for attempt in SPILL_SPAWN_ATTEMPTS:
		var section: Dictionary = main._pick_unlocked_section()
		var cell: Vector2i = section["grid_pos"]
		var pos := Vector2(randf_range(cell.x * main.ROOM_WIDTH + 180.0, cell.x * main.ROOM_WIDTH + 780.0), randf_range(cell.y * main.ROOM_HEIGHT + 120.0, cell.y * main.ROOM_HEIGHT + 360.0))
		if _spill_spot_ok(pos, r):
			return pos
	return null

func _spill_spot_ok(pos: Vector2, r: float) -> bool:
	for id in main.players:
		var p = main.players[id]
		if is_instance_valid(p) and pos.distance_to(p.global_position) < SPILL_CLEAR_PLAYER:
			return false
	var fk: Node2D = main.forklift
	if fk.active and main._grid_cell_of(pos) == main._grid_cell_of(fk.home_position):
		if absf(pos.y - fk.home_position.y) < r + SPILL_CLEAR_FORKLIFT_LANE:
			return false
	for shelf_body in main.shelves:
		for slot in shelf_body.get_node("Shelf").slots:
			if pos.distance_to(slot.global_position) < r + SPILL_CLEAR_SLOT:
				return false
	for s in spills:
		if pos.distance_to(s["pos"]) < r + s["r"] + SPILL_CLEAR_SPILL:
			return false
	return true

## Host-only. Public for tests (and for whatever spawns spills next).
func spawn_spill(pos: Vector2, r: float) -> int:
	if not multiplayer.is_server():
		return 0
	var id := _next_spill_id
	_next_spill_id += 1
	_spill_age[id] = 0.0
	var next := spills.duplicate()
	next.append({"id": id, "pos": pos, "r": r, "phase": PHASE_FORMING})
	spills = next
	spills_today += 1
	print("[Ambience] Spill #%d at (%.0f, %.0f) r=%.0f in %s" % [id, pos.x, pos.y, r, _section_name_at(pos)])
	return id

## Host-only — the mop calls it (Cleanup.gd, WEEK 19).
func remove_spill(id: int) -> void:
	if not multiplayer.is_server():
		return
	_spill_age.erase(id)
	spills = spills.filter(func(s): return s["id"] != id)

func _section_name_at(pos: Vector2) -> String:
	var cell: Vector2i = main._grid_cell_of(pos)
	for s in main.SECTIONS:
		if s["grid_pos"] == cell:
			return s["name"]
	return "?"

## Every peer (Player.gd for its own player, Manager.gd on the host): is this
## point on a spill that's wet (or drying)? margin widens the test.
func slippery_at(pos: Vector2, margin := 0.0) -> bool:
	if not spills_enabled():
		return false
	for s in spills:
		if s["phase"] != PHASE_FORMING and pos.distance_to(s["pos"]) < s["r"] + margin:
			return true
	return false

## --- Every peer: visuals -----------------------------------------------------

func _process(delta: float) -> void:
	var report: bool = main.is_day_report_active()
	# Lights.
	var target := 1.0
	if lights_enabled() and main.shift_active and not report and lights_event_id != 0:
		if lights_event_id != _played_event_id:
			_played_event_id = lights_event_id
			_pattern = build_pattern(lights_event_seed)
			_pattern_t = 0.0
		else:
			_pattern_t += delta
		target = _level_at(_pattern_t)
	elif lights_event_id == 0:
		_played_event_id = 0
	brightness = target
	_overlay.color.a = 1.0 - brightness
	var dim_amount := clampf((1.0 - brightness) / (1.0 - LIGHTS_DIM_LEVEL), 0.0, 1.0)
	_vignette.modulate.a = dim_amount * VIGNETTE_STRENGTH
	var cam := get_viewport().get_camera_2d()
	if cam:
		_vignette.global_position = cam.get_screen_center_position()
		var view: Vector2 = get_viewport().get_visible_rect().size / cam.zoom
		_vignette.scale = view * 1.15 / 256.0
	_vignette.visible = _vignette.modulate.a > 0.0
	# Spills.
	var live := {}
	for s in (spills if spills_enabled() else []):
		var id: int = s["id"]
		live[id] = true
		if not _spill_nodes.has(id):
			_spill_nodes[id] = _build_spill_node(s)
			_spill_root.add_child(_spill_nodes[id])
			_spill_local_age[id] = 0.0
		_spill_local_age[id] += delta
		_update_spill_node(_spill_nodes[id], s, _spill_local_age[id])
	for id in _spill_nodes.keys():
		if not live.has(id):
			_spill_nodes[id].queue_free()
			_spill_nodes.erase(id)
			_spill_local_age.erase(id)

func _clear_local() -> void:
	for id in _spill_nodes:
		_spill_nodes[id].queue_free()
	_spill_nodes.clear()
	_spill_local_age.clear()
	brightness = 1.0
	if _overlay:
		_overlay.color.a = 0.0
		_vignette.modulate.a = 0.0

## A lumpy blob (same shape on every peer — seeded by the spill's id) with a
## glossy highlight, and a yellow WET FLOOR sign at its edge.
func _build_spill_node(s: Dictionary) -> Node2D:
	var node := Node2D.new()
	node.name = "Spill%d" % s["id"]
	node.position = s["pos"]
	var rng := RandomNumberGenerator.new()
	rng.seed = int(s["id"]) * 7919
	var r: float = s["r"]
	var pts := PackedVector2Array()
	for i in 14:
		var a := TAU * i / 14.0
		pts.append(Vector2.RIGHT.rotated(a) * r * rng.randf_range(0.82, 1.1))
	var blob := Polygon2D.new()
	blob.name = "Blob"
	blob.polygon = pts
	blob.color = SPILL_COLOR
	node.add_child(blob)
	var shine := Polygon2D.new()
	shine.name = "Shine"
	shine.polygon = PackedVector2Array([Vector2(-0.45, -0.35) * r, Vector2(-0.1, -0.5) * r, Vector2(0.05, -0.38) * r, Vector2(-0.3, -0.2) * r])
	shine.color = Color(1, 1, 1, 0.35)
	node.add_child(shine)
	var sign_node := Node2D.new()
	sign_node.name = "Sign"
	sign_node.position = Vector2(r * 0.8, -r * 0.8)
	sign_node.z_index = Z_EMISSIVE
	var tri := Polygon2D.new()
	tri.polygon = PackedVector2Array([Vector2(0, -16), Vector2(14, 10), Vector2(-14, 10)])
	tri.color = Color(1, 0.85, 0.1)
	sign_node.add_child(tri)
	var bang := Label.new()
	bang.text = "!"
	bang.position = Vector2(-4, -12)
	bang.add_theme_font_size_override("font_size", 16)
	bang.add_theme_color_override("font_color", Color(0.1, 0.1, 0.1))
	sign_node.add_child(bang)
	var wet := Label.new()
	wet.text = "WET FLOOR"
	wet.position = Vector2(-30, 10)
	wet.add_theme_font_size_override("font_size", 10)
	wet.add_theme_color_override("font_color", Color(1, 0.9, 0.2))
	wet.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	wet.add_theme_constant_override("shadow_offset_x", 1)
	wet.add_theme_constant_override("shadow_offset_y", 1)
	sign_node.add_child(wet)
	node.add_child(sign_node)
	return node

func _update_spill_node(node: Node2D, s: Dictionary, local_age: float) -> void:
	match int(s["phase"]):
		PHASE_FORMING:
			# Spreading: grows in over the form time; the sign blinks.
			var k := clampf(local_age / SPILL_FORM_TIME, 0.0, 1.0)
			node.get_node("Blob").scale = Vector2.ONE * lerpf(0.25, 1.0, k)
			node.get_node("Shine").visible = false
			node.modulate.a = lerpf(0.5, 0.85, k)
			node.get_node("Sign").visible = fmod(local_age, 0.4) < 0.25
		PHASE_WET:
			node.get_node("Blob").scale = Vector2.ONE
			node.get_node("Shine").visible = true
			node.modulate.a = 1.0
			node.get_node("Sign").visible = true
		PHASE_DRYING:
			node.get_node("Blob").scale = Vector2.ONE
			node.get_node("Shine").visible = false
			node.modulate.a = 0.55
			node.get_node("Sign").visible = true
