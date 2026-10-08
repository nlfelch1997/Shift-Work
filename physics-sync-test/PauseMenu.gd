extends CanvasLayer
## OCT 2026 PHASE 4C — the pause menu (Esc), from outside playtest feedback:
## the player found no pause (tried Esc and Tab), no way to quit but closing
## the window, and no settings. One instance, a child of Main, local to each
## peer, PROCESS_MODE_ALWAYS.
##
## ESC, IN ORDER (this node's _input is the one place Esc is read):
##   1. the Settings screen, if open: cancel a key capture, else Back;
##   2. a quit confirmation, if up: back to the menu;
##   3. this menu, if open: Resume;
##   4. an open Staff Board / gear shop panel: close it (Main.close_open_panel());
##   5. in a game (shift, prep, Break Room, cleanup, the report, even still
##      connecting): open this menu. Over the main menu Esc does nothing.
##
## SOLO vs CO-OP (decided — see the Phase 4C notes in Main.gd):
## - Solo (this PC hosts and nobody else is connected): opening the menu
##   PAUSES THE WORLD — get_tree().paused — so the clocks, customers, forklift,
##   manager, helpers, janitor, events, rating drift, physics and every
##   delta-driven timer stop, and pick up exactly where they were. (The two
##   wall-clock timers that used to exist — the manager's work/forklift
##   grace and the recent-bounce window — run on Main.game_clock now.)
##   If a friend joins while it's paused, the world un-pauses (a joiner can't
##   load into a frozen host) and the menu stays up as the co-op overlay.
## - Co-op: an OVERLAY. The world keeps running — the host is authoritative and
##   freezing one peer would desync everyone — and the menu says so. While it's
##   open this player's own input is ignored, so they stand still (they can
##   still be bumped, like anyone standing still). Nobody can pause anybody else.

const LAYER := 6
const SettingsMenuScript := preload("res://SettingsMenu.gd")

var main: Node
var settings_menu: Node
var _shade: ColorRect
var _panel: PanelContainer
var _title: Label
var _note: Label
var _info: Label
var _buttons: VBoxContainer
var _confirm: VBoxContainer
var _confirm_title: Label
var _confirm_body: Label
var resume_button: Button
var settings_button: Button
var menu_button: Button
var desktop_button: Button
var confirm_button: Button
var cancel_button: Button
## Whether opening the menu paused the tree (solo) — only then does closing
## it un-pause.
var paused_world := false
## "menu" / "desktop" while a quit confirmation is up, else "".
var confirming := ""
## How many times this menu has been opened (tests).
var opens := 0

func _ready() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_build()

func is_open() -> bool:
	return visible

## The local player ignores input while this (or Settings over it) is up.
func blocks_input() -> bool:
	return visible or (settings_menu != null and settings_menu.is_open())

## --- Esc -------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if settings_menu.is_open():
		# Settings owns every key while it waits for one; otherwise only Esc.
		if settings_menu.capturing != "" or event.keycode == KEY_ESCAPE:
			settings_menu.handle_key(event)
			get_viewport().set_input_as_handled()
		return
	if event.keycode != KEY_ESCAPE:
		return
	get_viewport().set_input_as_handled()
	if confirming != "":
		_show_buttons()
	elif visible:
		close()
	elif main.close_open_panel():
		pass
	elif main.in_game():
		open()

## --- Open / close ----------------------------------------------------------------

func open() -> void:
	if visible:
		return
	opens += 1
	paused_world = main.is_solo()
	if paused_world:
		get_tree().paused = true
	_refresh_text()
	_show_buttons()
	visible = true
	print("[Pause] menu opened — %s" % ("world PAUSED (solo)" if paused_world else "overlay, the game keeps running (co-op)"))

func close() -> void:
	if not visible:
		return
	visible = false
	confirming = ""
	if settings_menu.is_open():
		settings_menu.close()
	if paused_world:
		get_tree().paused = false
		paused_world = false
	print("[Pause] menu closed — resumed")

## Main: someone joined a paused solo game. Un-pause; keep the menu up as
## the co-op overlay.
func crew_joined() -> void:
	if paused_world:
		paused_world = false
		get_tree().paused = false
		print("[Pause] a crewmate joined — world un-paused")
	if visible:
		_refresh_text()

## --- Building --------------------------------------------------------------------

func _build() -> void:
	_shade = ColorRect.new()
	_shade.color = Color(0.05, 0.05, 0.08, 0.7)
	_shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_shade)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", SettingsMenuScript.panel_style())
	_panel.custom_minimum_size = Vector2(380, 0)
	center.add_child(_panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	_panel.add_child(col)
	_title = _label("PAUSED", 30, Color(1, 0.82, 0.25))
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_title)
	_note = _label("", 13, Color(1, 0.6, 0.45))
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.custom_minimum_size = Vector2(340, 0)
	col.add_child(_note)
	_info = _label("", 12, Color(0.8, 0.85, 0.95))
	_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info.custom_minimum_size = Vector2(340, 0)
	col.add_child(_info)
	_buttons = VBoxContainer.new()
	_buttons.add_theme_constant_override("separation", 8)
	col.add_child(_buttons)
	resume_button = _button("Resume", close)
	settings_button = _button("Settings", _open_settings)
	menu_button = _button("Quit to Main Menu", func(): _ask_quit("menu"))
	desktop_button = _button("Quit to Desktop", func(): _ask_quit("desktop"))
	for b in [resume_button, settings_button, menu_button, desktop_button]:
		_buttons.add_child(b)
	_confirm = VBoxContainer.new()
	_confirm.add_theme_constant_override("separation", 10)
	_confirm.visible = false
	col.add_child(_confirm)
	_confirm_title = _label("", 18, Color(1, 1, 1))
	_confirm_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_confirm.add_child(_confirm_title)
	_confirm_body = _label("", 13, Color(0.9, 0.92, 1))
	_confirm_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_confirm_body.custom_minimum_size = Vector2(340, 0)
	_confirm.add_child(_confirm_body)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	_confirm.add_child(row)
	confirm_button = _button("Quit", _confirmed)
	cancel_button = _button("Cancel", _show_buttons)
	confirm_button.custom_minimum_size = Vector2(130, 0)
	cancel_button.custom_minimum_size = Vector2(130, 0)
	row.add_child(confirm_button)
	row.add_child(cancel_button)
	var foot := _label("Esc: resume  ·  F11: fullscreen", 11, Color(0.62, 0.64, 0.7))
	foot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(foot)

func _label(text: String, size: int, color: Color) -> Label:
	return SettingsMenuScript.ui_label(text, size, color)

func _button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.name = text.replace(" ", "")
	b.text = text
	b.custom_minimum_size = Vector2(0, 32)
	b.pressed.connect(on_press)
	return b

func _refresh_text() -> void:
	var solo: bool = paused_world
	_title.text = "PAUSED" if solo else "MENU"
	_note.visible = not solo
	_note.text = "The game is still running — your crew and the clock keep going. You stand still while this is open." if not solo else ""
	_info.text = main.pause_info_text()

func _show_buttons() -> void:
	confirming = ""
	_confirm.visible = false
	_buttons.visible = true
	_title.visible = true
	resume_button.grab_focus.call_deferred()

func _open_settings() -> void:
	settings_menu.open()

## A quit: straight out when nothing would be lost (the day's saved, or no
## game yet), otherwise say plainly what happens and ask first.
func _ask_quit(to: String) -> void:
	var lose: String = main.quit_loss_text()
	if lose == "":
		main.leave_session(to == "desktop")
		return
	confirming = to
	_buttons.visible = false
	_confirm.visible = true
	_confirm_title.text = "Quit to the main menu?" if to == "menu" else "Quit to desktop?"
	_confirm_body.text = lose
	confirm_button.text = "Quit" if to == "desktop" else "Quit to menu"
	cancel_button.grab_focus.call_deferred()

func _confirmed() -> void:
	var to := confirming
	confirming = ""
	main.leave_session(to == "desktop")
