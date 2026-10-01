extends CanvasLayer
## WEEK 21 — the WEEK COMPLETE screen and the endless-mode hub (the shift board
## beside the Break Room shop), one full-screen layer drawn over the frozen
## store. Built in code by Main.gd (nothing new goes into a .tscn — see Main's
## header note). Every peer draws it from Endless.gd's replicated state; every
## button is a request to the host (Endless.gd's request_*()). Rebuilt only
## when that state changes (_signature()), not every frame.

const BG := Color(0.05, 0.05, 0.08, 0.95)
const GOLD := Color(1, 0.82, 0.25)
const CYAN := Color(0.45, 0.9, 1)
const DIM := Color(0.62, 0.64, 0.7)
const OFF := Color(0.42, 0.44, 0.5)
const CARD_BG := [Color(0.1, 0.2, 0.13), Color(0.2, 0.18, 0.08), Color(0.24, 0.09, 0.08)]

var endless: Node
var main: Node
var _root: Control
var _sig := ""
## For tests: the live buttons.
var enter_button: Button
var offer_buttons: Array[Button] = []
var buy_buttons := {}

func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	visible = false

func _process(_delta: float) -> void:
	var s: int = endless.screen if main.is_day_report_active() else endless.SCREEN_NONE
	visible = s != endless.SCREEN_NONE
	if not visible:
		_sig = ""
		return
	var sig := _signature(s)
	if sig != _sig:
		_sig = sig
		_rebuild(s)

func _signature(s: int) -> String:
	return str([s, endless.offers.map(func(o): return o["id"]), endless.wallet, endless.upgrades, endless.run_stats, endless.week_summary, main.players.size()])

func _rebuild(s: int) -> void:
	for c in _root.get_children():
		c.queue_free()
	offer_buttons.clear()
	buy_buttons.clear()
	enter_button = null
	if s == endless.SCREEN_WEEK_COMPLETE:
		_build_week_complete()
	elif s == endless.SCREEN_HUB:
		_build_hub()

## --- helpers ------------------------------------------------------------------

## trim: never wider than its container (an ellipsis instead) — the hub has a
## fixed 960x540 to fit, and a long line must not push a card off screen.
func _label(text: String, size: int, color := Color(1, 1, 1), align := HORIZONTAL_ALIGNMENT_LEFT, trim := false) -> Label:
	var l := Label.new()
	l.text = text
	if trim:
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.horizontal_alignment = align
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

func _panel(color: Color) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	p.add_theme_stylebox_override("panel", sb)
	return p

## --- WEEK COMPLETE: the story's closing beat ------------------------------------

func _build_week_complete() -> void:
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 8)
	_root.add_child(box)
	var w: Dictionary = endless.week_summary
	box.add_child(_label("WEEK ONE COMPLETE", 50, GOLD, HORIZONTAL_ALIGNMENT_CENTER))
	box.add_child(_label("That's the story — seven days, one store, and everything at once. You survived it.", 18, Color(1, 1, 1), HORIZONTAL_ALIGNMENT_CENTER))
	box.add_child(_label("The week:  sold %d   ·   pay %s   ·   write-ups %d   ·   priority-order sales %d   ·   cleanliness bonuses %s" % [int(w.get("sold", 0)), main._format_money(int(w.get("pay", 0))), int(w.get("writeups", 0)), int(w.get("priority_sales", 0)), main._format_money(int(w.get("clean_bonus", 0)))], 18, Color(0.9, 0.95, 1), HORIZONTAL_ALIGNMENT_CENTER))
	box.add_child(_label("+%d Break Room Bucks — for making it through the week" % endless.WEEK_COMPLETE_BUCKS, 20, GOLD, HORIZONTAL_ALIGNMENT_CENTER))
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 14)
	box.add_child(gap)
	box.add_child(_label("WHAT'S NEXT:  ENDLESS SHIFTS", 26, CYAN, HORIZONTAL_ALIGNMENT_CENTER))
	box.add_child(_label("No more numbered days. From the break room you pick your next shift off the board —\nevery posting shows its open sections, its hazards and how hard it is before you take it.\nHit its medal targets to earn Bucks; spend them in the Break Room shop on permanent upgrades.", 16, Color(0.85, 0.88, 0.95), HORIZONTAL_ALIGNMENT_CENTER))
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)
	enter_button = Button.new()
	enter_button.text = "Clock in to Endless Shifts  →"
	enter_button.add_theme_font_size_override("font_size", 20)
	enter_button.pressed.connect(func(): endless.request_enter_hub())
	row.add_child(enter_button)

## --- THE HUB: shift board + Break Room shop -------------------------------------

func _build_hub() -> void:
	var outer := MarginContainer.new()
	outer.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		outer.add_theme_constant_override("margin_" + side, 12)
	_root.add_child(outer)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	outer.add_child(col)
	# Header.
	var head := HBoxContainer.new()
	col.add_child(head)
	var title := _label("BREAK ROOM  —  ENDLESS SHIFTS", 22, CYAN)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	head.add_child(_label("Wallet: %d Bucks" % endless.wallet, 22, GOLD, HORIZONTAL_ALIGNMENT_RIGHT))
	var rs: Dictionary = endless.run_stats
	var m: Array = rs.get("medals", [0, 0, 0, 0])
	col.add_child(_label("Story: Days 1-7 complete   ·   Endless shifts worked: %d   ·   Medals: %d gold, %d silver, %d bronze   ·   Bucks earned: %d   ·   Crew: %d" % [int(rs.get("shifts", 0)), m[3], m[2], m[1], int(rs.get("bucks", 0)), main.players.size()], 12, DIM, HORIZONTAL_ALIGNMENT_LEFT, true))
	# The board.
	col.add_child(_label("SHIFT BOARD — pick your next shift (the whole crew plays the one that's taken)", 14, Color(1, 1, 1), HORIZONTAL_ALIGNMENT_LEFT, true))
	var board := HBoxContainer.new()
	board.add_theme_constant_override("separation", 8)
	col.add_child(board)
	for i in endless.offers.size():
		board.add_child(_offer_card(i, endless.offers[i]))
	# The shop.
	col.add_child(_label("BREAK ROOM SHOP — permanent upgrades for the whole crew", 14, Color(1, 1, 1), HORIZONTAL_ALIGNMENT_LEFT, true))
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 4)
	col.add_child(grid)
	for u in endless.UPGRADES:
		grid.add_child(_shop_row(u))

func _offer_card(i: int, o: Dictionary) -> Control:
	var stars: int = o["stars"]
	var card := _panel(CARD_BG[clampi((stars - 1) / 2, 0, 2)])
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_stretch_ratio = 1.0
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	card.add_child(v)
	v.add_child(_label("%s" % o["name"], 16, Color(1, 1, 1), HORIZONTAL_ALIGNMENT_LEFT, true))
	v.add_child(_label("%s  %s   ·  Bucks ×%.2f" % [endless.stars_text(stars), endless.STAR_WORDS[stars], o["bucks_mult"]], 14, GOLD, HORIZONTAL_ALIGNMENT_LEFT, true))
	v.add_child(_label("Open: %s" % endless.sections_text(o), 12, Color(0.9, 0.95, 1), HORIZONTAL_ALIGNMENT_LEFT, true))
	for line in endless.hazard_lines(o):
		v.add_child(_label(line[2], 12, Color(1, 0.75, 0.55) if line[1] == 2 else (Color(1, 1, 1) if line[1] == 1 else OFF), HORIZONTAL_ALIGNMENT_LEFT, true))
	var prep: float = main.prep_ceiling_for(1 + o["sections"].size())
	var sell: float = maxf(0.0, main.shift_duration - (main.FINALE_SELLING_CUT if o["tight_clock"] else 0.0))
	v.add_child(_label("Clock: prep up to %d:%02d, then %ds selling%s" % [int(prep) / 60, int(prep) % 60, int(sell), " (TIGHT)" if o["tight_clock"] else ""], 12, Color(0.9, 0.95, 1), HORIZONTAL_ALIGNMENT_LEFT, true))
	var t: Array = endless.targets_for(o, main.players.size())
	v.add_child(_label("Medals: bronze $%d · silver $%d · gold $%d" % t, 12, Color(0.9, 0.95, 1), HORIZONTAL_ALIGNMENT_LEFT, true))
	var b := Button.new()
	b.text = "Take this shift"
	b.add_theme_font_size_override("font_size", 14)
	b.pressed.connect(func(): endless.request_take_offer(i))
	v.add_child(b)
	offer_buttons.append(b)
	return card

func _shop_row(u: Dictionary) -> Control:
	var key: String = u["key"]
	var lvl: int = endless.upgrade_level(key)
	var mx: int = endless.max_level(key)
	var cost: int = endless.next_cost(key)
	var row := _panel(Color(0.12, 0.13, 0.17))
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var h := HBoxContainer.new()
	row.add_child(h)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(v)
	v.add_child(_label("%s  Lv %d/%d" % [u["name"], lvl, mx], 13, GOLD if lvl > 0 else Color(1, 1, 1), HORIZONTAL_ALIGNMENT_LEFT, true))
	var d := _label(u["desc"], 11, DIM)
	d.custom_minimum_size = Vector2(190, 0)
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(d)
	var b := Button.new()
	b.custom_minimum_size = Vector2(70, 0)
	b.add_theme_font_size_override("font_size", 13)
	if cost < 0:
		b.text = "MAXED"
		b.disabled = true
	else:
		b.text = "Buy  %d" % cost
		b.disabled = cost > endless.wallet
		b.pressed.connect(func(): endless.request_buy(key))
	h.add_child(b)
	buy_buttons[key] = b
	return row
