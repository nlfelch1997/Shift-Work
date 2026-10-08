extends CanvasLayer
## OCT 2026 PHASE 4C — the Settings screen: Audio / Display / Controls tabs
## over Settings.gd (the autoload that owns, applies and saves every value).
## One instance, a child of Main, opened from the main menu or the pause menu
## (PauseMenu.gd routes Esc here first: cancel a key capture, else Back).
## Built in code like every other panel here (the Staff Board's look), and
## PROCESS_MODE_ALWAYS so it works over a paused solo game. Local only.

signal closed

const PANEL_SIZE := Vector2(640, 430)

var main: Node
var _root: Control
var _tabs: TabContainer
var _sliders := {} # kind -> HSlider
var _slider_values := {} # kind -> Label
var _fullscreen: CheckButton
var _vsync: CheckButton
var second_set_check: CheckButton
var _bind_buttons := {} # full action name -> Button
var _status: Label
var back_button: Button
var reset_button: Button
## The full action name waiting for a key ("" = none).
var capturing := ""
var _syncing := false

func _ready() -> void:
	layer = 7
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_build()
	Settings.changed.connect(_refresh)

func is_open() -> bool:
	return visible

func open() -> void:
	capturing = ""
	_status.text = ""
	_refresh()
	visible = true
	_tabs.current_tab = 0
	back_button.grab_focus.call_deferred()

func close() -> void:
	capturing = ""
	visible = false
	closed.emit()

## Esc and key captures (from PauseMenu.gd's router). True = used.
func handle_key(event: InputEventKey) -> bool:
	if not visible:
		return false
	if capturing != "":
		var code: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
		var full := capturing
		capturing = ""
		if code == KEY_ESCAPE:
			_status.text = "Cancelled — %s stays %s" % [_action_text(full), Settings.key_label(full)]
		else:
			var r: Dictionary = Settings.rebind(full, code)
			if not r["ok"]:
				_status.text = "Can't use %s: %s" % [Settings.key_name(code), r["why"]]
			elif r["swapped"] != "":
				_status.text = "%s is now %s  ·  swapped: %s is now %s" % [_action_text(full), Settings.key_label(full), _action_text(r["swapped"]), Settings.key_label(r["swapped"])]
			else:
				_status.text = "%s is now %s" % [_action_text(full), Settings.key_label(full)]
		_refresh()
		if _bind_buttons.has(full):
			_bind_buttons[full].grab_focus()
		return true
	if event.keycode == KEY_ESCAPE:
		close()
		return true
	return false

func _action_text(full: String) -> String:
	var base := full.trim_prefix("host_").trim_prefix("client_")
	return "%s (%s)" % [Settings.ACTION_NAMES[base], "your keys" if full.begins_with("host_") else "second set"]

## Click on a key button: wait for the next key press.
func start_capture(full: String) -> void:
	capturing = full
	_refresh()
	_status.text = "Press a key for %s  ·  Esc cancels" % _action_text(full)

## --- Building ----------------------------------------------------------------------

func _build() -> void:
	var shade := ColorRect.new()
	shade.color = Color(0.05, 0.05, 0.08, 0.6)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	_root = CenterContainer.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", panel_style())
	box.custom_minimum_size = PANEL_SIZE
	_root.add_child(box)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	box.add_child(col)
	col.add_child(ui_label("SETTINGS", 22, Color(1, 0.82, 0.25)))
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_tabs)
	_tabs.add_child(_build_audio())
	_tabs.add_child(_build_display())
	_tabs.add_child(_build_controls())
	_status = ui_label("", 12, Color(1, 0.85, 0.45))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_status)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	col.add_child(row)
	var saved := ui_label("Saved automatically on this PC (not in the game save).", 11, Color(0.62, 0.64, 0.7))
	saved.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(saved)
	back_button = Button.new()
	back_button.name = "BackButton"
	back_button.text = "Back"
	back_button.custom_minimum_size = Vector2(110, 0)
	back_button.pressed.connect(close)
	row.add_child(back_button)

func _tab(title: String) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.name = title
	v.add_theme_constant_override("separation", 10)
	return v

func _build_audio() -> Control:
	var v := _tab("Audio")
	v.add_child(ui_label("", 4, Color.WHITE))
	for spec in [["master", "Master volume"], ["music", "Music"], ["sfx", "Sound effects  (footsteps, forklift, events, clicks)"]]:
		var kind: String = spec[0]
		v.add_child(ui_label(spec[1], 14, Color(1, 1, 1)))
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 10)
		v.add_child(h)
		var s := HSlider.new()
		s.name = "Slider_" + kind
		s.min_value = 0
		s.max_value = 100
		s.step = 5
		s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		s.focus_mode = Control.FOCUS_ALL
		s.value_changed.connect(func(val):
			if not _syncing:
				Settings.set_volume(kind, val / 100.0))
		h.add_child(s)
		var l := ui_label("100%", 14, Color(0.8, 0.85, 0.95))
		l.custom_minimum_size = Vector2(50, 0)
		h.add_child(l)
		_sliders[kind] = s
		_slider_values[kind] = l
	return v

func _build_display() -> Control:
	var v := _tab("Display")
	v.add_child(ui_label("", 4, Color.WHITE))
	_fullscreen = CheckButton.new()
	_fullscreen.name = "Fullscreen"
	_fullscreen.text = "Fullscreen  (F11 anywhere)"
	_fullscreen.toggled.connect(func(on):
		if not _syncing:
			Settings.set_fullscreen(on))
	v.add_child(_fullscreen)
	_vsync = CheckButton.new()
	_vsync.name = "VSync"
	_vsync.text = "VSync  (off can feel snappier, may tear)"
	_vsync.toggled.connect(func(on):
		if not _syncing:
			Settings.set_vsync(on))
	v.add_child(_vsync)
	var note := ui_label("In a window, drag its edges to any size: the game scales to fit.", 12, Color(0.62, 0.64, 0.7))
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(note)
	return v

func _build_controls() -> Control:
	var v := _tab("Controls")
	v.add_theme_constant_override("separation", 6)
	var intro := ui_label("Click a key to change it. A key already in use swaps with it. Everyone plays with the left column, hosting or joined — tick the box to play with the right-hand set (arrow keys) on this PC instead.", 12, Color(0.8, 0.85, 0.95))
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(intro)
	second_set_check = CheckButton.new()
	second_set_check.name = "SecondSet"
	second_set_check.text = "Use the second set (arrow keys) on this PC"
	second_set_check.toggled.connect(func(on: bool):
		if not _syncing:
			Settings.set_second_set(on))
	v.add_child(second_set_check)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 3)
	v.add_child(grid)
	grid.add_child(ui_label("", 12, Color.WHITE))
	grid.add_child(ui_label("Your keys", 12, Color(1, 0.82, 0.25)))
	grid.add_child(ui_label("Second set", 12, Color(1, 0.82, 0.25)))
	for a in Settings.ACTIONS:
		var name_l := ui_label(Settings.ACTION_NAMES[a], 13, Color(1, 1, 1))
		name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(name_l)
		for p in Settings.PREFIXES:
			var full: String = p + a
			var b := Button.new()
			b.name = "Bind_" + full
			b.custom_minimum_size = Vector2(120, 0)
			b.pressed.connect(func(): start_capture(full))
			grid.add_child(b)
			_bind_buttons[full] = b
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 10)
	v.add_child(foot)
	var fixed := ui_label("Fixed: Esc menu  ·  F11 fullscreen  ·  Tab skip practice  ·  F3 debug", 11, Color(0.62, 0.64, 0.7))
	fixed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(fixed)
	reset_button = Button.new()
	reset_button.name = "ResetControls"
	reset_button.text = "Reset to defaults"
	reset_button.pressed.connect(func():
		Settings.reset_controls()
		_status.text = "Controls reset to the defaults")
	foot.add_child(reset_button)
	return v

func _refresh() -> void:
	if _sliders.is_empty():
		return
	_syncing = true
	for kind in _sliders:
		var pct := roundi(Settings.volume(kind) * 100.0)
		_sliders[kind].value = pct
		_slider_values[kind].text = "%d%%" % pct
	_fullscreen.button_pressed = Settings.fullscreen
	_vsync.button_pressed = Settings.vsync
	second_set_check.button_pressed = Settings.second_set
	for full in _bind_buttons:
		_bind_buttons[full].text = "press a key…" if full == capturing else Settings.key_label(full)
	reset_button.disabled = Settings.controls_are_default()
	_syncing = false

## --- Shared look (PauseMenu.gd uses these too) ----------------------------------------

## The Staff Board / gear shop panel look.
static func panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.1, 0.95)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 12
	sb.content_margin_bottom = 14
	return sb

static func ui_label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l
