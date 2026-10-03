extends Node2D
## PRACTICE SHIFT (Oct 2026, first outside playtest: "we got dropped straight
## into a live shift and had no idea what anything was"). A guided, no-stakes
## run of the real Day 1 store before the first real shift: no clock, no
## customers, no pay, no save, write-ups shown but never docked. It teaches,
## one step at a time, exactly what the playtesters found confusing:
##   move -> pick up a delivery crate -> set it down on its unpack pad ->
##   carry stock and place it on a shelf (C) -> the registers (working spot)
##   -> the manager's vision cone -> a forklift's beacon/BEEP -> flip the
##   Store sign, which ends practice and starts Day 1 for real.
##
## WHEN IT RUNS: offered automatically only to a brand-new crew — the host
## clicked Host Game with no save file at all (a returning save never sees
## it). The menu's "Practice Shift" button runs it on demand for anyone, then
## carries on into wherever the save resumes. Tab skips it (for the whole
## crew), and flipping the sign at any step ends it early, so anyone who
## already knows the job is never stuck in it. --practice forces it (tests).
##
## SHAPE: the real game, not a separate scene. Main.gd runs a normal Day 1
## shift underneath with three practice switches (active, below): the store
## never opens on its own (the prep clock is pinned), the manager walks the
## floor (hazard_levels() turns him on — he's normally Day 4+), and a
## write-up is a toast with no penalty (Main.gd's record_writeup()). The
## delivery forklift with its beacon already runs from Day 1, so the forklift
## step points at the real one. When practice ends the host resets the world
## exactly like any new day (Main.gd's _start_shift()).
##
## AUTHORITY: `active` is host-written and replicated. Each peer walks its OWN
## steps, judged on its own player from state every peer already has
## (carrier ids, shelved flags, cashier/manager/forklift positions, the
## manager's replicated watch_peer) — each player learns at their own pace,
## nothing new goes over the network but the start/end and the skip.
##
## SCREEN SPACE (locked design rule: never cover hazard cues or banners): the
## step card sits at the left edge, mid-height — clear of the top prep/finale
## bands, the bottom alert rows (LOOK BUSY, write-up toast, order banner) and
## the corner status line — on the alert layer, so the report and debug HUD
## still draw over it. The world marker draws at Z_MARKER, under Juice's
## popups and well under every hazard cue (Ambience.Z_EMISSIVE: the forklift
## beacon, the manager's "?"/"!" and cone, wet-floor signs).

const Z_MARKER := 85
const CARD_WIDTH := 270.0
const CARD_MARGIN := 12.0
## How close (screen px) to the card a hazard or the step's target can be
## before the card gets out of its way.
const CARD_CLEARANCE := 40.0
const STOCK_TO_PLACE := 2
const REGISTER_HOLD := 1.0 # s standing at a register
## The forklift step: it's on my screen (the camera follows my player; the
## view is 960x540) for FORKLIFT_LOOK_TIME — watching from a safe distance
## counts, no need to walk up to it.
const FORKLIFT_ON_SCREEN := Vector2(440.0, 240.0)
const FORKLIFT_LOOK_TIME := 2.0
const MANAGER_FALLBACK_TIME := 25.0 # s near him without ever being watched still counts

## The steps, in order. text may use {key} for the player's own keys.
const STEPS := [
	{"id": "move", "title": "Clock in", "text": "Practice shift — no clock, no customers, no pay.\n\nWalk out of the Break Room ({move})."},
	{"id": "crate", "title": "Delivery crates", "text": "Trucks drop crates at Receiving (Storage, bottom right).\n\nWalk up to one and press {interact} — just get close, no lining up."},
	{"id": "unpack", "title": "Unpack it", "text": "Carry it to its section's UNPACK PAD (follow the arrow) and press {interact} to set it down. It breaks open into stock."},
	{"id": "stock", "title": "Stock the shelf", "text": "Grab a product ({interact}), take it to the shelf of the same color, and press {place} when a slot lights up.\n\nStocked items stay put when the shelf gets bumped."},
	{"id": "register", "title": "The registers", "text": "Customers pay at the registers. Standing at one counts as working.\n\nWalk up to a register."},
	{"id": "manager", "title": "The manager", "text": "His cone is what he sees. Idle in it = WRITTEN UP (docks pay).\n\nStand still until his ? pops, then get busy: carry, keep moving, or work a register. (Free in practice.)"},
	{"id": "forklift", "title": "Forklifts", "text": "Flashing beacon + BEEP = forklift. It does NOT stop for you.\n\nGo watch the one in Storage — from a safe distance."},
	{"id": "open", "title": "Open the store", "text": "Red-ringed customers make trouble: {defend} shoves them. Trash on the floor: {interact}, +$1 a piece.\n\nWhen the crew's ready, flip the STORE SIGN ({interact}) to start Day 1."},
]

## Host-written, replicated (own Sync, reliable ON_CHANGE).
var active := false
## Host only: where the save resumes once practice ends.
var _resume := "story"
var _saved_day := 1

## Local: this peer's own progress.
var step := 0
var _step_t := 0.0
var _placed := 0
var _hold_t := 0.0
var _near_t := 0.0
var _seen_watch := false
var _was_active := false
var _start_pos := Vector2.INF
var _dropped: Array = [] # products I set down, waiting to see if they land shelved
var _held_last: Array = [] # what I held last frame
var _skipped_local := false

## Diagnostics the tests read.
signal step_done(id: String)
var completed: Array = [] # step ids, in the order this peer finished them

var main: Node
var _layer: CanvasLayer
var _card: PanelContainer
var _title: Label
var _body: Label
var _foot: Label
var _marker_pos := Vector2.INF
var _pulse := 0.0

func _ready() -> void:
	main = get_parent()
	z_index = Z_MARKER
	z_as_relative = false
	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	var path := NodePath(".:active")
	config.add_property(path)
	config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE)
	sync.replication_config = config
	sync.name = "Sync" # explicit, identical name on every peer — see Player.gd's note
	sync.set_multiplayer_authority(1)
	add_child(sync)
	_build_card()

func _build_card() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "PracticeLayer"
	_layer.layer = main.UI_LAYER_ALERTS
	add_child(_layer)
	_card = PanelContainer.new()
	_card.name = "PracticeCard"
	_card.anchor_top = 0.22
	_card.anchor_bottom = 0.22
	_card.offset_left = CARD_MARGIN
	_card.offset_right = CARD_MARGIN + CARD_WIDTH
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.06, 0.04, 0.78)
	style.border_color = Color(1, 0.85, 0.3, 0.9)
	style.set_border_width_all(0)
	style.border_width_left = 4
	style.set_corner_radius_all(6)
	style.content_margin_left = 12
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	_card.add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(box)
	_title = _label(13, Color(1, 0.85, 0.3))
	_body = _label(14, Color(1, 0.97, 0.9))
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.custom_minimum_size = Vector2(CARD_WIDTH - 22.0, 0)
	_foot = _label(12, Color(0.75, 0.72, 0.65))
	_foot.text = "Tab: skip practice (whole crew)"
	for l in [_title, _body, _foot]:
		box.add_child(l)
	_card.visible = false
	_layer.add_child(_card)

func _label(size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

## --- Host: start / end ---------------------------------------------------

## Host-only, from Main.gd's _on_host_pressed(): run practice first, then
## carry on to `resume` (what the save said: "story" or a past-the-story
## screen). The world runs Day 1 for practice whatever day the save is on.
func begin(resume: String) -> void:
	if not multiplayer.is_server():
		return
	_resume = resume
	_saved_day = main.current_day
	main.current_day = 1
	active = true
	print("[Practice] Practice shift starting (then: %s, Day %d)" % [resume, _saved_day])
	get_tree().create_timer(main.PRODUCT_SPAWN_DELAY).timeout.connect(main._start_shift)

## Host-only, every frame of a practice shift (Main.gd's _process()): no
## clock — the prep ceiling and the day clock stay pinned.
func tick_host() -> void:
	if not active or not main.shift_active:
		return
	main.prep_time_left = 1.0e6
	main.shift_time_left = 1.0e6

## Host-only: the sign was flipped, or someone skipped. Resets the world like
## any new day and starts the real one.
func finish(why: String) -> void:
	if not multiplayer.is_server() or not active:
		return
	active = false
	print("[Practice] Practice over (%s) — on to %s" % [why, ("Day %d" % _saved_day) if _resume == "story" else _resume])
	_announce_over.rpc(why)
	main.current_day = _saved_day
	main.shift_active = false
	if _resume == "story":
		main._reconfigure_world()
		main._start_shift()
	else:
		main._despawn_all_customers()
		main._reset_shelves_and_products_for_new_day()
		main._reconfigure_world()
		main._resume_past_story(_resume)

@rpc("authority", "call_local", "reliable")
func _announce_over(why: String) -> void:
	var text := "Practice over — clock's running. Good luck!" if why != "skipped" else "Practice skipped — clock's running."
	main.show_toast(text, Color(0.55, 1, 0.6), 4.0)

## Any peer: Tab. Ends practice for the whole crew (the host decides).
func request_skip() -> void:
	if multiplayer.is_server():
		finish("skipped")
	else:
		_request_skip.rpc_id(1)

@rpc("any_peer", "reliable")
func _request_skip() -> void:
	if multiplayer.is_server():
		finish("skipped")

func _unhandled_input(event: InputEvent) -> void:
	if active and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB:
		request_skip()
		get_viewport().set_input_as_handled()

## --- Every peer: my own steps ---------------------------------------------

func _process(delta: float) -> void:
	_pulse += delta
	var on: bool = active and Net.is_active() and main.shift_active and not main.is_day_report_active()
	if on and not _was_active:
		_reset_progress()
	_was_active = on
	var me := multiplayer.get_unique_id() if Net.is_active() else 0
	var p: Node2D = main.players.get(me) if on else null
	if p == null or not is_instance_valid(p):
		_card.visible = false
		_marker_pos = Vector2.INF
		queue_redraw()
		return
	_track_items(me)
	if step < STEPS.size():
		_step_t += delta
		_check_step(p, me, delta)
	_show(p, me)
	queue_redraw()

func _reset_progress() -> void:
	step = 0
	_step_t = 0.0
	_placed = 0
	_hold_t = 0.0
	_near_t = 0.0
	_seen_watch = false
	_start_pos = Vector2.INF
	_dropped = []
	_held_last = []
	_my_box = null
	completed = []

func current_id() -> String:
	return STEPS[step]["id"] if step < STEPS.size() else "done"

func _advance() -> void:
	var id := current_id()
	completed.append(id)
	print("[Practice] peer %d finished step '%s' (%.1fs)" % [multiplayer.get_unique_id(), id, _step_t])
	step_done.emit(id)
	Sfx.play("clean_chime")
	step += 1
	_step_t = 0.0
	_hold_t = 0.0
	_near_t = 0.0

## What I'm holding, and products I've set down (to catch them landing
## shelved — a placement counts for whoever set it down).
func _track_items(me: int) -> void:
	var held := []
	for obj in get_tree().get_nodes_in_group("carryable"):
		if obj.get_node("Carryable").carrier_id == me:
			held.append(obj)
	for obj in _held_last:
		if is_instance_valid(obj) and not obj in held and not obj.is_in_group("delivery_box"):
			_dropped.append({"obj": obj, "t": 0.0})
	_held_last = held
	for i in range(_dropped.size() - 1, -1, -1):
		var d: Dictionary = _dropped[i]
		var obj = d["obj"]
		d["t"] += get_process_delta_time()
		if not is_instance_valid(obj) or d["t"] > 3.0 or obj.get_node("Carryable").carrier_id != 0:
			_dropped.remove_at(i)
		elif obj.get_node("Carryable").shelved:
			_dropped.remove_at(i)
			_placed += 1

func _holding(kind: String) -> Node2D:
	for obj in _held_last:
		if is_instance_valid(obj) and (obj.is_in_group("delivery_box") == (kind == "box")):
			return obj
	return null

func _check_step(p: Node2D, me: int, delta: float) -> void:
	var id := current_id()
	# Ahead of the script (already carrying stock, or a shelf got stocked):
	# skip to stocking rather than make anyone go back for a crate.
	if id in ["move", "crate", "unpack"] and (_holding("product") != null or _placed > 0):
		while current_id() != "stock":
			_advance()
		return
	match id:
		"move":
			if _start_pos == Vector2.INF:
				_start_pos = p.global_position
			if not main.is_break_room_at_pos(p.global_position) or p.global_position.distance_to(_start_pos) > 400.0:
				_advance()
		"crate":
			if _holding("box") != null:
				_my_box = _holding("box")
				_advance()
		"unpack":
			# Done when MY crate came apart on its pad (it's gone from the
			# world). Dropped somewhere else — or knocked out of my hands by
			# the forklift — it's still lying there: pick it back up.
			var b := _holding("box")
			if b != null:
				_my_box = b
			elif _my_box == null or not is_instance_valid(_my_box) or _my_box.is_queued_for_deletion():
				_advance()
		"stock":
			if _placed >= STOCK_TO_PLACE:
				_advance()
		"register":
			if _at_register(p):
				_hold_t += delta
				if _hold_t >= REGISTER_HOLD:
					_advance()
			else:
				_hold_t = 0.0
		"manager":
			var m: Node2D = main.manager
			if m.watch_peer == me and m.watch_level > 0.0:
				_seen_watch = true
			elif _seen_watch and m.watch_peer != me:
				_advance()
				return
			if p.global_position.distance_to(m.global_position) < 400.0:
				_near_t += delta
				if _near_t >= MANAGER_FALLBACK_TIME:
					_advance()
		"forklift":
			var off: Vector2 = (main.delivery_forklift.global_position - p.global_position).abs()
			if off.x < FORKLIFT_ON_SCREEN.x and off.y < FORKLIFT_ON_SCREEN.y:
				_near_t += delta
				if _near_t >= FORKLIFT_LOOK_TIME:
					_advance()
		"open":
			pass # the sign ends practice for everyone (Main.gd's open_store())

var _my_box: Node2D = null

func _at_register(p: Node2D) -> bool:
	for cashier_body in main.cashiers:
		if cashier_body.get_node("Cashier").active and p.global_position.distance_to(cashier_body.global_position) < main.manager.REGISTER_RANGE:
			return true
	return false

## --- Card + marker -----------------------------------------------------------

func _keys(me: int) -> Dictionary:
	var host: bool = me == 1
	return {
		"move": "WASD" if host else "arrow keys",
		"interact": "E" if host else "Enter",
		"place": "C" if host else "/",
		"defend": "Space",
	}

func _show(p: Node2D, me: int) -> void:
	var s: Dictionary = STEPS[mini(step, STEPS.size() - 1)]
	var k := _keys(me)
	var text: String = s["text"]
	for key in k:
		text = text.replace("{%s}" % key, k[key])
	if s["id"] == "stock" and _placed > 0:
		text = "Nice — that one's staying put. Place one more.\n\n" + text
	_title.text = "PRACTICE SHIFT  ·  %d/%d  ·  %s" % [mini(step + 1, STEPS.size()), STEPS.size(), s["title"]]
	_body.text = text
	_card.visible = true
	_marker_pos = _target(p, s["id"])
	_place_card()

## Locked rule: never cover a hazard cue. The card sits on whichever side
## (left or right edge) has no manager, forklift or the step's own target
## behind it; if both sides do, it fades so they show through.
var card_side := 0 # 0 left, 1 right (tests read it)
func _place_card() -> void:
	var vp := get_viewport().get_visible_rect().size
	var ct := get_viewport().get_canvas_transform()
	var keep_clear: Array[Vector2] = []
	for n in [main.manager, main.forklift, main.delivery_forklift]:
		if n != null and n.visible and (n.get("active") == null or n.active):
			keep_clear.append(ct * n.global_position)
	if _marker_pos != Vector2.INF:
		keep_clear.append(ct * _marker_pos)
	var h := maxf(_card.size.y, 80.0)
	var top := vp.y * _card.anchor_top
	var rects := [Rect2(CARD_MARGIN, top, CARD_WIDTH, h), Rect2(vp.x - CARD_MARGIN - CARD_WIDTH, top, CARD_WIDTH, h)]
	var blocked := [0, 0]
	for i in 2:
		var r: Rect2 = rects[i].grow(CARD_CLEARANCE)
		for pt in keep_clear:
			if r.has_point(pt):
				blocked[i] += 1
	if blocked[card_side] > 0 and blocked[1 - card_side] < blocked[card_side]:
		card_side = 1 - card_side
	_card.offset_left = rects[card_side].position.x
	_card.offset_right = rects[card_side].position.x + CARD_WIDTH
	_card.modulate.a = 0.45 if blocked[card_side] > 0 else 1.0

## Where the current step wants me to go (INF = nowhere in particular).
func _target(p: Node2D, id: String) -> Vector2:
	match id:
		"crate":
			var best := Vector2.INF
			for b in get_tree().get_nodes_in_group("delivery_box"):
				if b.get_node("Carryable").carrier_id == 0 and (best == Vector2.INF or p.global_position.distance_to(b.global_position) < p.global_position.distance_to(best)):
					best = b.global_position
			return best if best != Vector2.INF else main.delivery.RECEIVING_SPOTS[0]
		"unpack":
			var b := _holding("box")
			if b == null and _my_box != null and is_instance_valid(_my_box):
				return _my_box.global_position # set down off its pad: go get it
			if b != null and b.has_meta("section") and main.delivery.PAD_CENTERS.has(b.get_meta("section")):
				return main.delivery.pad_center(b.get_meta("section"))
			return main.delivery.pad_center("Dry Goods")
		"stock":
			var held := _holding("product")
			if held != null:
				return _nearest_slot_for(p.global_position, held)
			return _nearest_loose_product(p.global_position)
		"register":
			var best := Vector2.INF
			for cashier_body in main.cashiers:
				if cashier_body.get_node("Cashier").active and (best == Vector2.INF or p.global_position.distance_to(cashier_body.global_position) < p.global_position.distance_to(best)):
					best = cashier_body.global_position
			return best
		"manager":
			return main.manager.global_position
		"forklift":
			return main.delivery_forklift.global_position
		"open":
			return main.STORE_SIGN_POS
	return Vector2.INF

func _nearest_slot_for(from: Vector2, obj: Node) -> Vector2:
	var best := Vector2.INF
	for shelf_body in main.shelves:
		if not main.is_unlocked_at_pos(shelf_body.global_position):
			continue
		var shelf: Node = shelf_body.get_node("Shelf")
		if not shelf._color_matches(obj):
			continue
		var pos = shelf.nearest_empty_slot_position(from)
		if pos != null and (best == Vector2.INF or from.distance_to(pos) < from.distance_to(best)):
			best = pos
	return best

func _nearest_loose_product(from: Vector2) -> Vector2:
	var best := Vector2.INF
	for obj in get_tree().get_nodes_in_group("carryable"):
		var c: Node = obj.get_node("Carryable")
		if obj.is_in_group("delivery_box") or c.carrier_id != 0 or c.shelved:
			continue
		if best == Vector2.INF or from.distance_to(obj.global_position) < from.distance_to(best):
			best = obj.global_position
	return best

func _draw() -> void:
	if _marker_pos == Vector2.INF or not _card.visible:
		return
	# A pulsing ring on the target...
	var k := 0.5 + 0.5 * sin(_pulse * 5.0)
	var c := Color(1, 0.85, 0.3, 0.55 + 0.35 * k)
	draw_arc(_marker_pos, 30.0 + 6.0 * k, 0.0, TAU, 32, c, 3.0)
	draw_arc(_marker_pos, 18.0, 0.0, TAU, 24, Color(c, 0.35), 2.0)
	# ...and a small chevron at my feet pointing at it, when it's not right here.
	var me := multiplayer.get_unique_id() if Net.is_active() else 0
	var p: Node2D = main.players.get(me)
	if p == null or not is_instance_valid(p):
		return
	var to := _marker_pos - p.global_position
	if to.length() < 90.0:
		return
	var dir := to.normalized()
	var tip := p.global_position + dir * (52.0 + 4.0 * k)
	var side := dir.orthogonal() * 9.0
	draw_colored_polygon(PackedVector2Array([tip, tip - dir * 14.0 + side, tip - dir * 9.0, tip - dir * 14.0 - side]), c)
