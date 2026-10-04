extends Node2D
## OCT 2026 PIVOT, PHASE 3 — HIRED HELPERS. The crew hires staff, one per
## section, out of the shared bank; each helper (Helper.gd) works its own
## section on its own. Built in code by Main.gd's _ready() (explicit name
## "Staff", same on every peer — its synchronizer's path must match), drawn
## under Players like the break room furniture.
##
## THE PROBLEM THIS FIXES (Phase 2's report): a solo player's income didn't
## grow by buying sections — one pair of hands can only stock so much, so a
## new section brought hazards and no money. A helper is a second pair of
## hands bolted to one section: its trucks' boxes go to its back stock
## instead of Storage, and the helper unpacks and shelves them (see
## Helper.gd), so the section sells whether or not anyone from the crew ever
## walks into it.
##
## THE RULES (locked design, this phase):
## - PER SECTION. Each hireable section (HELPER_SECTIONS — every section
##   after Dry Goods, which is the crew's own: it's the room everyone walks
##   through, and its side-wall layout isn't the other three's) can have one
##   helper, hired on its own. Owning a section does NOT come with one.
## - TWO GATES. A section's slot opens when the crew OWNS it; hiring into it
##   still needs the money (HIRE_FEE on the spot). Separate checks, separate
##   refusal messages (hire_blocker()).
## - WAGES come out of the shared bank at clock-out, beside the shift's pay
##   (Main.gd's _bank_shift_pay()). They never touch lifetime_earned, so
##   paying staff can never switch an unlocked hazard back off — the same
##   rule as buying a section. A helper on the books at ANY point in a shift
##   is paid for that shift (hired mid-prep or let go mid-prep alike), so
##   hire-for-prep-then-fire isn't a free shelf fill.
## - TWO UPGRADES per helper, bought at the same board: SPEED (walking
##   speed) and CARRY (items per trip). One-off prices; the wage stays the
##   section's wage.
## - LETTING SOMEONE GO is in scope: the board's "Let go" takes the helper
##   off the books now (they still get this shift's wage — see above), and
##   their upgrades go with them; hiring again starts from scratch. Without
##   it a crew whose bank went negative would have no way to stop a wage.
##
## WHERE: THE STAFF BOARD, on the break room's west wall — the room every
## shift starts in, beside the coffee machine's and the time clock's E
## interactions. E at the board (empty-handed, shift running) opens the staff
## panel on that player's screen; its buttons ask the host. Staff changes
## happen during PREP only — the same window as buying a section ("before
## you open"): nothing about who's working changes under a running store.
##
## NETWORKING: host-authoritative, like the purchase gate. Any peer asks
## (_request_staff), the host checks the asker is standing at the board and
## every rule above, then writes `staff` (replicated). Two players pressing
## Hire on the same section in the same instant hire once: the second
## request finds the slot taken and is refused — no double hire, no double
## charge (the money check and the write happen in one host call).

const HelperScript := preload("res://Helper.gd")

## The sections a helper can be hired into, in SECTIONS order.
const HELPER_SECTIONS := ["Produce", "Dairy/Frozen", "Bakery"]
## Flavor: each section's helper (name, look — a staff polo sheet from the
## cashiers' set, and a section-colored ring under the feet).
const HELPER_NAMES := {"Produce": "Sam", "Dairy/Frozen": "Alex", "Bakery": "Jo"}
const HELPER_LOOKS := {"Produce": "cashier_4", "Dairy/Frozen": "cashier_5", "Bakery": "cashier_2"}

## ============================================================================
## NUMBERS — every one a FLAGGED, tunable placeholder (Phase 5 does the real
## balance pass). How they were set: see the PHASE 3 block in Main.gd's
## economy notes and the report — measured with tools/staff_test.gd's
## --test=income (the solo bot, same brain as Phase 2's measurements, with
## and without a helper in each section).
## ============================================================================
## Paid once, at the board, on hiring.
const HIRE_FEE := {"Produce": 150, "Dairy/Frozen": 250, "Bakery": 350}
## Per shift worked, out of the bank at clock-out.
const WAGE := {"Produce": 60, "Dairy/Frozen": 75, "Bakery": 90}
## Level 0 = as hired. Speed in px/s (a customer browses at 90, a player
## walks at 220); carry in items per trip.
const SPEED_BY_LEVEL := [80.0, 110.0, 140.0]
const CARRY_BY_LEVEL := [1, 2, 3]
## Price of the NEXT level (index = current level).
const SPEED_COSTS := [200, 400]
const CARRY_COSTS := [250, 500]
## Back-stock boxes a section can hold; a truck's box for a full back room
## isn't brought (the truck carries one less).
const BACKSTOCK_MAX := 3

## --- the board (break room west wall; floor x 20..940, y 20..520) ---
const BOARD_POS := Vector2(30.0, 235.0) # the board's centre, on the wall
const BOARD_SPOT := Vector2(75.0, 235.0) # where you stand to use it
const BOARD_RANGE := 70.0

## --- Replicated (StaffSync, host authority). Reassigned, never mutated, so
## a change is plainly a new value to the synchronizer.
## section -> {"speed": level, "carry": level}; no key = nobody hired.
var staff: Dictionary = {}
## section -> boxes waiting in its back room.
var backstock: Dictionary = {}
## The last clock-out's wage bill (the report shows it on every peer).
var wages_today := 0
var wages_detail := ""

## --- Host-only ---
var on_books: Dictionary = {} # sections with someone on staff at any point this shift
var actions_done := 0
var actions_refused := 0
var boxes_diverted_today := 0
var boxes_skipped_today := 0 # a staffed section's back room was full

var main: Node
var helpers: Dictionary = {} # section -> Helper (every peer)
var panel: CanvasLayer
var _panel_root: Control
var _panel_sig := ""
var _hint: Label
var _pile_nodes: Dictionary = {} # section -> [Node2D pile, Label]
## For tests: the panel's live buttons, "<section>:<action>" -> Button.
var buttons := {}

func _ready() -> void:
	main = get_parent()
	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	for prop in [".:staff", ".:backstock", ".:wages_today", ".:wages_detail"]:
		var path := NodePath(prop)
		config.add_property(path)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE)
	sync.replication_config = config
	sync.name = "StaffSync" # explicit, identical name on every peer
	sync.set_multiplayer_authority(1)
	add_child(sync)
	_build_board()
	for i in HELPER_SECTIONS.size():
		var sec: String = HELPER_SECTIONS[i]
		_build_pile(sec)
		var h: Node2D = HelperScript.new()
		h.setup(sec, i, HELPER_NAMES[sec], HELPER_LOOKS[sec], main.SECTION_COLORS[sec])
		helpers[sec] = h
		add_child(h)
	_build_panel()

## --- Reads (every peer) -------------------------------------------------------

func is_hired(sec: String) -> bool:
	return staff.has(sec)

func speed_level(sec: String) -> int:
	return int(staff.get(sec, {}).get("speed", 0))

func carry_level(sec: String) -> int:
	return int(staff.get(sec, {}).get("carry", 0))

func backstock_of(sec: String) -> int:
	return int(backstock.get(sec, 0))

## Wages for this shift so far: everyone on the books at any point in it.
func wages_due() -> int:
	var n := 0
	for sec in on_books:
		n += int(WAGE.get(sec, 0))
	return n

## Staffing exists in the shopkeeper game only (not the practice shift, not
## the debug-only Endless route).
func _staffing_live() -> bool:
	return not main.is_endless() and not main.tutorial.active

## The helper is on the floor right now (hired, section open, a real shift).
func working(sec: String) -> bool:
	if not is_hired(sec) or not _staffing_live():
		return false
	var i: int = main.section_index(sec)
	return i >= 0 and main.is_section_open(main.SECTIONS[i])

func near_board(pos: Vector2) -> bool:
	return pos.distance_to(BOARD_SPOT) <= BOARD_RANGE

func _prep_window() -> bool:
	return main.shift_active and not main.store_open and not main.cleanup_active and not main.is_day_report_active()

## Why `action` on `sec` can't happen right now ("" = it can). Actions:
## "hire", "speed", "carry", "fire". The ownership gate and the money gate
## are separate checks with their own answers.
func blocker(sec: String, action: String) -> String:
	if not HELPER_SECTIONS.has(sec):
		return "no helpers for %s" % sec
	if main.is_endless():
		return "not in Endless Mode"
	if main.tutorial.active:
		return "practice shift — hire in a real shift"
	var i: int = main.section_index(sec)
	if action == "hire":
		if i >= main.sections_owned:
			return "buy %s first" % sec
		if is_hired(sec):
			return "%s already works here" % HELPER_NAMES[sec]
	elif not is_hired(sec):
		return "nobody hired"
	if action in ["speed", "carry"] and next_cost(sec, action) < 0:
		return "maxed out"
	if not _prep_window():
		return "staff changes during prep, before you open"
	var cost := price(sec, action)
	if cost > 0 and main.money < cost:
		return "need %s more" % main._format_money(cost - main.money)
	return ""

## What an action costs right now (0 for letting someone go; -1 = maxed).
func price(sec: String, action: String) -> int:
	match action:
		"hire":
			return int(HIRE_FEE.get(sec, 0))
		"speed", "carry":
			return maxi(0, next_cost(sec, action))
	return 0

func next_cost(sec: String, knob: String) -> int:
	var costs: Array = SPEED_COSTS if knob == "speed" else CARRY_COSTS
	var lvl := speed_level(sec) if knob == "speed" else carry_level(sec)
	return costs[lvl] if lvl < costs.size() else -1

## --- Requests (any peer) -> the host ------------------------------------------

## An upgrade request carries the level the button was showing, so two
## players clicking "Faster $200" in the same instant buy ONE level, not a
## second one at a price neither of them saw.
func request(sec: String, action: String) -> void:
	var from_level := _level_of(sec, action)
	if multiplayer.is_server():
		do_action(sec, action, multiplayer.get_unique_id(), from_level)
	else:
		_request_staff.rpc_id(1, sec, action, from_level)

func _level_of(sec: String, action: String) -> int:
	if action == "speed":
		return speed_level(sec)
	if action == "carry":
		return carry_level(sec)
	return -1

@rpc("any_peer", "reliable")
func _request_staff(sec: String, action: String, from_level := -1) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	# Where the HOST sees the sender — no hiring from across the store.
	if main.players.has(sender) and near_board(main.players[sender].global_position):
		do_action(sec, action, sender, from_level)
	else:
		actions_refused += 1
		print("[Staff] %s's %s request for %s refused: not at the board" % [main.player_display_name(sender), action, sec])

## Host-only: the one place staff changes. Returns whether it happened.
func do_action(sec: String, action: String, by_peer: int, from_level := -1) -> bool:
	if not multiplayer.is_server():
		return false
	var why := blocker(sec, action)
	if why == "" and from_level >= 0 and _level_of(sec, action) != from_level:
		why = "someone just did that"
	if why != "":
		actions_refused += 1
		print("[Staff] %s can't %s (%s): %s" % [main.player_display_name(by_peer), action, sec, why])
		if by_peer == multiplayer.get_unique_id():
			_tell("%s: %s" % [sec, why], false)
		elif main.players.has(by_peer):
			_tell.rpc_id(by_peer, "%s: %s" % [sec, why], false)
		return false
	var cost := price(sec, action)
	var next := staff.duplicate(true)
	var text := ""
	match action:
		"hire":
			next[sec] = {"speed": 0, "carry": 0}
			var books := on_books.duplicate()
			books[sec] = true
			on_books = books
			text = "%s hired %s for %s — $%d, then $%d a shift" % ["%s", HELPER_NAMES[sec], sec, cost, WAGE[sec]]
		"speed", "carry":
			var lvl := int(next[sec][action]) + 1
			next[sec][action] = lvl
			text = "%s trained %s: %s" % ["%s", HELPER_NAMES[sec], ("walks faster (%d px/s)" % int(SPEED_BY_LEVEL[lvl])) if action == "speed" else ("carries %d at a time" % CARRY_BY_LEVEL[lvl])]
		"fire":
			next.erase(sec)
			var bs := backstock.duplicate()
			bs.erase(sec)
			backstock = bs
			text = "%s let %s go (this shift's $%d wage is still owed)" % ["%s", HELPER_NAMES[sec], WAGE[sec]]
	main.money -= cost
	staff = next
	actions_done += 1
	sync_helpers()
	print("[Staff] %s — bank %s" % [text % main.player_display_name(by_peer), main._format_money(main.money)])
	_announce.rpc(text, by_peer)
	main.save_progress("staff: %s %s" % [action, sec])
	return true

@rpc("authority", "call_local", "reliable")
func _announce(text: String, by_peer: int) -> void:
	var who: String = "You" if Net.is_active() and by_peer == multiplayer.get_unique_id() else main.player_display_name(by_peer)
	main.show_toast(text % who, Color(0.55, 1, 0.6), 3.5)

@rpc("authority", "reliable")
func _tell(text: String, _ok: bool) -> void:
	main.show_toast(text, Color(1, 0.85, 0.3), 2.5)

## --- Host: the shift ----------------------------------------------------------------

## Host, from Main.gd's _start_shift(): everyone hired is on the books for this
## shift; empty back rooms (the floor was cleared too); helpers to their spots.
func reset_for_new_shift() -> void:
	if not multiplayer.is_server():
		return
	var books := {}
	if _staffing_live():
		for sec in staff:
			books[sec] = true
	on_books = books
	backstock = {}
	boxes_diverted_today = 0
	boxes_skipped_today = 0
	sync_helpers()
	for h in helpers.values():
		h.reset_for_new_shift()

## Host: each helper's on/off and its two knobs from `staff`. Called on every
## change (hire, upgrade, a section bought, the world reconfiguring).
func sync_helpers() -> void:
	if not multiplayer.is_server():
		return
	for sec in helpers:
		var h: Node2D = helpers[sec]
		h.speed = SPEED_BY_LEVEL[speed_level(sec)]
		h.capacity = CARRY_BY_LEVEL[carry_level(sec)]
		h.set_active(working(sec))

## Host, at clock-out (Main.gd's _end_shift()): the shift's wage bill. The
## money itself moves in Main.gd's _bank_shift_pay(), beside the pay.
func close_books() -> int:
	var due := wages_due()
	var parts := []
	for sec in HELPER_SECTIONS:
		if on_books.has(sec):
			parts.append("%s $%d" % [HELPER_NAMES[sec], WAGE[sec]])
	wages_today = due
	wages_detail = ", ".join(parts)
	return due

## Host, from Delivery.gd's start_delivery(): a staffed section's boxes go to
## its back room instead of the truck's load for Storage. Returns the load
## that's left for the crew.
func divert_boxes(cargo: Array) -> Array:
	var rest := []
	var bs := backstock.duplicate()
	for sec in cargo:
		if helpers.has(sec) and working(sec):
			if int(bs.get(sec, 0)) < BACKSTOCK_MAX:
				bs[sec] = int(bs.get(sec, 0)) + 1
				boxes_diverted_today += 1
			else:
				boxes_skipped_today += 1
		else:
			rest.append(sec)
	if bs != backstock:
		backstock = bs
	return rest

## Host, from Helper.gd at the pad: one back-stock box comes apart on the pad
## (Delivery.gd's own unpack spill). Returns whether there was one.
func open_backstock_box(sec: String) -> bool:
	if not multiplayer.is_server() or backstock_of(sec) <= 0:
		return false
	var bs := backstock.duplicate()
	bs[sec] = int(bs[sec]) - 1
	backstock = bs
	main.delivery.unpack_into_section(sec, "%s unpacked a box" % HELPER_NAMES[sec])
	return true

func _process(_delta: float) -> void:
	if Net.is_active() and multiplayer.is_server():
		# The world can open/close a helper's section under it (a purchase,
		# the practice shift ending, a debug start) — keep them in step.
		for sec in helpers:
			if helpers[sec].active != working(sec):
				sync_helpers()
				break
	_update_piles()
	_update_board_ui()

## --- The board (every peer, visual) ---------------------------------------------------

func _build_board() -> void:
	var board := Node2D.new()
	board.name = "StaffBoard"
	board.position = BOARD_POS
	add_child(board)
	# A cork board hung on the west wall (PLACEHOLDER ART, polygons): frame,
	# cork, a header strip and one pinned card per hireable section.
	_poly(board, [Vector2(-12, -78), Vector2(14, -78), Vector2(14, 78), Vector2(-12, 78)], Color(0.35, 0.22, 0.12))
	_poly(board, [Vector2(-9, -74), Vector2(11, -74), Vector2(11, 74), Vector2(-9, 74)], Color(0.72, 0.55, 0.36))
	for i in HELPER_SECTIONS.size():
		var y := -48.0 + i * 46.0
		_poly(board, [Vector2(-6, y - 14), Vector2(9, y - 14), Vector2(9, y + 14), Vector2(-6, y + 14)], Color(0.96, 0.94, 0.88))
		_poly(board, [Vector2(-6, y - 14), Vector2(9, y - 14), Vector2(9, y - 8), Vector2(-6, y - 8)], main.SECTION_COLORS[HELPER_SECTIONS[i]])
		_poly(board, [Vector2(0, y - 12), Vector2(3, y - 12), Vector2(3, y - 9), Vector2(0, y - 9)], Color(0.85, 0.15, 0.15)) # pin
	var title := Label.new()
	title.text = "STAFF"
	title.add_theme_font_size_override("font_size", 10)
	title.add_theme_color_override("font_color", Color(1, 0.95, 0.85))
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	title.position = Vector2(-10, -96)
	title.size = Vector2(60, 14)
	board.add_child(title)
	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.add_theme_color_override("font_color", Color(0.55, 0.9, 1))
	_hint.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_hint.position = BOARD_SPOT + Vector2(-40, 34)
	_hint.size = Vector2(260, 20)
	_hint.z_index = 5
	_hint.visible = false
	add_child(_hint)

func _poly(parent: Node, pts: Array, c: Color) -> Polygon2D:
	var p := Polygon2D.new()
	p.polygon = PackedVector2Array(pts)
	p.color = c
	parent.add_child(p)
	return p

## Back-stock boxes, stacked by the pad's west edge (no collision — scenery
## that counts): what a staffed section's helper has left to unpack.
func _build_pile(sec: String) -> void:
	var pile := Node2D.new()
	pile.name = "BackStock" + sec.replace("/", "")
	pile.position = main.delivery.pad_center(sec) + Vector2(-92.0, -6.0)
	add_child(pile)
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", Color(1, 0.95, 0.8))
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	label.position = Vector2(-30, 24)
	label.size = Vector2(60, 12)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pile.add_child(label)
	_pile_nodes[sec] = [pile, label]

func _update_piles() -> void:
	for sec in _pile_nodes:
		var pile: Node2D = _pile_nodes[sec][0]
		var label: Label = _pile_nodes[sec][1]
		var n := backstock_of(sec)
		pile.visible = is_hired(sec) and helpers[sec].active
		label.text = "back stock %d" % n
		var boxes := pile.get_children().filter(func(c): return c is Sprite2D)
		if boxes.size() != n:
			for b in boxes:
				b.queue_free()
			for k in n:
				var s: Sprite2D = main.delivery.box_sprite("backstock%d" % k, 30.0)
				s.position = Vector2(0, -k * 12.0)
				pile.add_child(s)

## --- The panel (every peer, local UI) ---------------------------------------------

func _build_panel() -> void:
	panel = CanvasLayer.new()
	panel.name = "StaffPanel"
	panel.layer = main.UI_LAYER_MENU
	panel.visible = false
	add_child(panel)
	_panel_root = Control.new()
	_panel_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(_panel_root)

## E at the board (Player.gd): open or close this peer's panel.
func toggle_panel() -> void:
	panel.visible = not panel.visible
	_panel_sig = ""

func _my_player() -> Node2D:
	var me := multiplayer.get_unique_id() if Net.is_active() else 1
	var p = main.players.get(me)
	return p if p != null and is_instance_valid(p) else null

func _update_board_ui() -> void:
	var p := _my_player()
	var here: bool = p != null and near_board(p.global_position) and main.shift_active and not main.is_day_report_active()
	_hint.visible = here and _staffing_live()
	if _hint.visible:
		_hint.text = "E: close the staff board" if panel.visible else "E: staff board — hire help"
	if panel.visible and not (here and _staffing_live()):
		panel.visible = false # walked off, the shift ended, practice...
	if not panel.visible:
		return
	var sig := str([staff, main.money, main.sections_owned, _prep_window(), backstock])
	if sig != _panel_sig:
		_panel_sig = sig
		_rebuild_panel()

func _rebuild_panel() -> void:
	for c in _panel_root.get_children():
		c.queue_free()
	buttons.clear()
	var box := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.1, 0.93)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 8
	sb.content_margin_bottom = 10
	box.add_theme_stylebox_override("panel", sb)
	box.position = Vector2(150, 70)
	box.custom_minimum_size = Vector2(660, 0)
	_panel_root.add_child(box)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	box.add_child(col)
	col.add_child(_ui_label("STAFF BOARD", 20, Color(1, 0.82, 0.25)))
	col.add_child(_ui_label("Hire a helper for a section you own: they unpack its boxes and stock its shelves on their own.\nWages come out of the bank at clock-out. Staff changes happen during prep.  Bank: %s" % main._format_money(main.money), 12, Color(0.8, 0.85, 0.95)))
	for sec in HELPER_SECTIONS:
		col.add_child(_section_row(sec))

func _section_row(sec: String) -> Control:
	var row := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.13, 0.17)
	sb.border_color = main.SECTION_COLORS[sec]
	sb.border_width_left = 4
	sb.set_corner_radius_all(5)
	sb.content_margin_left = 10
	sb.content_margin_right = 8
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	row.add_theme_stylebox_override("panel", sb)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	row.add_child(h)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 0)
	h.add_child(v)
	var owned: bool = main.section_index(sec) < main.sections_owned
	if is_hired(sec):
		var sl := speed_level(sec)
		var cl := carry_level(sec)
		v.add_child(_ui_label("%s — %s  ·  $%d a shift" % [sec, HELPER_NAMES[sec], WAGE[sec]], 15, Color(0.55, 1, 0.6)))
		v.add_child(_ui_label("Speed %d/%d (%d px/s)  ·  Carry %d/%d (%d per trip)  ·  back stock %d" % [sl + 1, SPEED_BY_LEVEL.size(), int(SPEED_BY_LEVEL[sl]), cl + 1, CARRY_BY_LEVEL.size(), CARRY_BY_LEVEL[cl], backstock_of(sec)], 12, Color(0.8, 0.85, 0.95)))
		h.add_child(_button(sec, "speed", ("Faster  $%d" % next_cost(sec, "speed")) if next_cost(sec, "speed") >= 0 else "Speed MAX"))
		h.add_child(_button(sec, "carry", ("Carry more  $%d" % next_cost(sec, "carry")) if next_cost(sec, "carry") >= 0 else "Carry MAX"))
		h.add_child(_button(sec, "fire", "Let go"))
	elif owned:
		v.add_child(_ui_label("%s — no helper" % sec, 15, Color(1, 1, 1)))
		v.add_child(_ui_label("%s: $%d to hire, then $%d a shift" % [HELPER_NAMES[sec], HIRE_FEE[sec], WAGE[sec]], 12, Color(0.8, 0.85, 0.95)))
		h.add_child(_button(sec, "hire", "Hire  $%d" % HIRE_FEE[sec]))
	else:
		v.add_child(_ui_label("%s — not yours yet" % sec, 15, Color(0.5, 0.52, 0.58)))
		v.add_child(_ui_label("Buy the section at its gate first ($%d to hire after that)" % HIRE_FEE[sec], 12, Color(0.5, 0.52, 0.58)))
	var why_l := _ui_label("", 11, Color(1, 0.75, 0.4))
	var whys := []
	for action in (["speed", "carry"] if is_hired(sec) else (["hire"] if owned else [])):
		var why := blocker(sec, action)
		if why != "" and why != "maxed out" and not whys.has(why):
			whys.append(why)
	why_l.text = " / ".join(whys)
	why_l.visible = not whys.is_empty()
	v.add_child(why_l)
	return row

func _button(sec: String, action: String, text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE # Space/Enter stay the game's keys
	b.add_theme_font_size_override("font_size", 13)
	b.disabled = blocker(sec, action) != ""
	b.pressed.connect(func(): request(sec, action))
	buttons["%s:%s" % [sec, action]] = b
	return b

func _ui_label(text: String, size: int, c: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", c)
	return l
