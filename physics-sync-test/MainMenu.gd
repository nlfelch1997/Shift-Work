extends Node
## PHASE 5 — THE MAIN MENU, restructured. Before this phase the menu (one
## VBox in Main.tscn's MenuLayer, plus the buttons Main.gd added in code) was,
## top to bottom: Host Game (host on this PC: the save loaded if there was one,
## a brand-new crew got the practice shift first), Practice Shift, a "Host IP
## (blank = this PC):" label, the IP field, Join, Settings (Phase 4C), Quit
## (Phase 4C) — no title, no Continue/New Game split (Host Game silently
## continued the save), no credits, and solo play reached only through "Host".
##
## Now (same VBox, same default theme and button style, nothing restyled):
##   SHIFT WORK                 a plain text title (no logo — that's the art pass)
##   Continue  Shift N · $X     only when a save exists (read without side effects)
##   New Game                   confirms first when it would replace a save
##   Play Together (Co-op)      -> Host Co-op / the IP field / Join Co-op / Back
##   Practice Shift
##   Settings · Credits · Quit
##   Wishlist on Steam          demo build only (Pacing.gd)
## Hosting is still how solo works (a host nobody joins), so Continue, New Game
## and Host Co-op all host; friends can join any of them. Keyboard: every
## button takes focus, the first one grabs it whenever a page shows, Esc backs
## out of a sub-page (Settings has its own Esc, PauseMenu.gd routes it).
##
## Built in code over the scene's nodes: host_button / ip_input / join_button
## keep their paths' owners (Main.gd's @onready vars), just reparented.

const PacingScript := preload("res://Pacing.gd")
const SaveGameScript := preload("res://SaveGame.gd")

const MENU_WIDTH := 300.0
const PRIMARY_FONT := 20
const PRIMARY_HEIGHT := 40.0
const BUTTON_HEIGHT := 32.0
## The pause menu's look (PauseMenu.gd): its panel, its gold title, light text.
const SettingsMenuScript := preload("res://SettingsMenu.gd")
const TITLE_GOLD := Color(1, 0.82, 0.25)
const TEXT_LIGHT := Color(0.9, 0.92, 1)
const NOTE_COLOR := Color(1, 0.6, 0.45)

## What the Credits screen shows — the in-game copy of assets/CREDITS.md and
## audio/CREDITS.md (the .md files themselves aren't exported with the game).
## tools/menu_test.gd checks the required attributions are here and in the
## .md files alike, so the two can't quietly drift apart.
const CREDITS_TEXT := """SHIFT WORK

Made by: [developer / studio name — set before release]

MUSIC
"Monkeys Spinning Monkeys" Kevin MacLeod (incompetech.com)
Licensed under Creative Commons: By Attribution 3.0 License
http://creativecommons.org/licenses/by/3.0/

SOUND EFFECTS (CC0)
Kenney (kenney.nl) — Interface Sounds, UI Audio and the Starter Kits
Freesound: FFeller, dorian.mastin, MatthewWong, chewiesmissus, OwlStorm,
kirbydx, themusicalnomad (via the Godot demo projects)

CHARACTER SPRITES
Made with the Universal LPC Spritesheet Character Generator
(https://github.com/liberatedpixelcup/Universal-LPC-Spritesheet-Character-Generator),
used under CC-BY-SA 3.0 (https://creativecommons.org/licenses/by-sa/3.0/).
Art by Stephen Challener (Redshrike), Johannes Sjölund (wulax), Matthew Krohn
(makrohn), bluecarrot16, Benjamin K. Smith (BenCreating), Eliza Wyatt (ElizaWy),
JaidynReiman, Evert, TheraHedwig, MuffinElZangano, Durrani, Pierre Vigier
(pvigier), Lanea Zimmerman (Sharm), Manuel Riecke (MrBeast), Joe White, Nila122,
Carlo Enrico Victoria (Nemisys), Thane Brimhall (pennomi), Mandi Paugh,
laetissima, thecilekli, William.Thompsonj and Napsio (Vitruvian Studio).
Sprite sheets lightly modified for Shift Work (name tag).

BREAK ROOM
Pixel Furniture — Kelano Studio
Pixel Art Vending Machines — karsiori (CC0)

STORE AND WAREHOUSE TILES
Source to be confirmed (see CREDITS.md)

Made with the Godot Engine (godotengine.org/license)"""

var main: Node
var menu: VBoxContainer
var title: Label
var main_page: VBoxContainer
var coop_page: VBoxContainer
var confirm_page: VBoxContainer
var continue_button: Button
var new_game_button: Button
var play_together_button: Button
var practice_button: Button
var credits_button: Button
var wishlist_button: Button
var back_button: Button
var host_note: Label
var confirm_label: Label
var confirm_button: Button
var cancel_button: Button
var credits_layer: Control
var credits_back: Button
## What Continue last read from the save (SaveGame.peek()).
var save_info := {}
## The URL the Wishlist button last opened (tests; OS.shell_open isn't called
## when test_no_shell is set).
var last_opened_url := ""
var test_no_shell := false

func setup(m: Node) -> void:
	main = m
	menu = main.get_node("MenuLayer/Menu")
	# On the pause menu's panel, centred both ways whatever the page's height
	# (the scene's box was a fixed 200x160 from the screen centre, straight
	# over the break room — the photo showed through the buttons).
	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	main.menu_layer.add_child(center)
	main.menu_layer.move_child(center, menu.get_index())
	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.add_theme_stylebox_override("panel", SettingsMenuScript.panel_style())
	center.add_child(panel)
	menu.get_parent().remove_child(menu)
	panel.add_child(menu)
	menu.set_anchors_preset(Control.PRESET_TOP_LEFT)
	menu.custom_minimum_size = Vector2(MENU_WIDTH, 0)
	menu.add_theme_constant_override("separation", 8)
	var host_button: Button = main.host_button
	var join_button: Button = main.join_button
	var ip_input: LineEdit = main.ip_input
	var ip_label: Label = menu.get_node("IpLabel")
	practice_button = menu.get_node("PracticeButton")
	var settings_button: Button = main._menu_settings_button
	var quit_button: Button = main._menu_quit_button

	title = _label("SHIFT WORK", 40, TITLE_GOLD)
	title.name = "Title"
	menu.add_child(title)
	menu.move_child(title, 0)
	# The note after leaving a game ("The host ended the session"), under the
	# title instead of floating over the buttons.
	var notice: Label = main._menu_notice
	notice.get_parent().remove_child(notice)
	menu.add_child(notice)
	menu.move_child(notice, 1)
	notice.set_anchors_preset(Control.PRESET_TOP_LEFT)
	notice.custom_minimum_size = Vector2(MENU_WIDTH, 0)
	notice.add_theme_font_size_override("font_size", 13)
	notice.add_theme_color_override("font_color", NOTE_COLOR)
	notice.add_theme_constant_override("outline_size", 0)

	main_page = _page("MainPage")
	continue_button = _button("ContinueButton", "Continue", true)
	continue_button.pressed.connect(_on_continue)
	new_game_button = _button("NewGameButton", "New Game", true)
	new_game_button.pressed.connect(_on_new_game)
	play_together_button = _button("PlayTogetherButton", "Play Together (Co-op)")
	play_together_button.pressed.connect(func(): show_page(coop_page))
	credits_button = _button("CreditsButton", "Credits")
	credits_button.pressed.connect(open_credits)
	wishlist_button = _button("WishlistButton", "Wishlist on Steam")
	wishlist_button.pressed.connect(_on_wishlist)
	for b in [continue_button, new_game_button, play_together_button]:
		main_page.add_child(b)
	_adopt(main_page, practice_button)
	_adopt(main_page, settings_button)
	main_page.add_child(credits_button)
	_adopt(main_page, quit_button)
	main_page.add_child(wishlist_button)

	coop_page = _page("CoopPage")
	coop_page.add_child(_label("PLAY TOGETHER", 20, TITLE_GOLD))
	host_button.text = "Host Co-op"
	_adopt(coop_page, host_button)
	host_note = _label("", 13)
	host_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	coop_page.add_child(host_note)
	ip_label.text = "Join a friend — their IP (blank = this PC):"
	ip_label.add_theme_font_size_override("font_size", 13)
	ip_label.add_theme_color_override("font_color", TEXT_LIGHT)
	ip_label.add_theme_constant_override("outline_size", 0)
	_adopt(coop_page, ip_label)
	_adopt(coop_page, ip_input)
	join_button.text = "Join Co-op"
	_adopt(coop_page, join_button)
	back_button = _button("BackButton", "Back")
	back_button.pressed.connect(func(): show_page(main_page))
	coop_page.add_child(back_button)

	confirm_page = _page("ConfirmPage")
	confirm_label = _label("", 15)
	confirm_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	confirm_page.add_child(confirm_label)
	confirm_button = _button("ConfirmNewGameButton", "Start New Game", true)
	confirm_button.pressed.connect(start_new_game)
	confirm_page.add_child(confirm_button)
	cancel_button = _button("CancelButton", "Cancel")
	cancel_button.pressed.connect(func(): show_page(main_page))
	confirm_page.add_child(cancel_button)

	for p in [main_page, coop_page, confirm_page]:
		menu.add_child(p)
	_build_credits()
	main.menu_layer.visibility_changed.connect(_on_menu_shown)
	# Deferred: Main reads --save-file / --no-save after building this.
	show_page.call_deferred(main_page)

## --- pages --------------------------------------------------------------------

func show_page(page: Control) -> void:
	refresh()
	for p in [main_page, coop_page, confirm_page]:
		p.visible = p == page
	_focus_first(page)

func current_page() -> Control:
	for p in [main_page, coop_page, confirm_page]:
		if p.visible:
			return p
	return null

## Re-reads the save and the demo flag (the menu comes back after a game).
func refresh() -> void:
	save_info = SaveGameScript.peek(main.save_path) if main.save_enabled else {"exists": false, "ok": false, "shift": 1, "money": 0}
	continue_button.visible = save_info["ok"]
	if save_info["ok"]:
		continue_button.text = "Continue  ·  Shift %d  ·  Bank %s" % [save_info["shift"], main._format_money(save_info["money"])]
	wishlist_button.visible = PacingScript.is_demo()
	if save_info["ok"]:
		host_note.text = "Hosts your saved shop (Shift %d). Friends join with this PC's IP address." % save_info["shift"]
	else:
		host_note.text = "Hosts a new shop on this PC. Friends join with this PC's IP address."

func _on_menu_shown() -> void:
	if main.menu_layer.visible:
		show_page(main_page)

func _focus_first(page: Control) -> void:
	for c in page.get_children():
		if c is Button and c.visible and not c.disabled:
			c.grab_focus.call_deferred()
			return

func _input(event: InputEvent) -> void:
	if not main.menu_layer.visible or main.settings_menu.is_open():
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		if credits_layer.visible:
			close_credits()
		elif current_page() != main_page:
			show_page(main_page)
		else:
			return
		get_viewport().set_input_as_handled()

## --- actions ------------------------------------------------------------------

func _on_continue() -> void:
	main._host_from_menu = true
	main._on_host_pressed()

func _on_new_game() -> void:
	refresh()
	if not save_info["exists"]:
		_on_continue() # nothing to replace: a brand-new crew (practice first)
		return
	if save_info["ok"]:
		confirm_label.text = "Start a new game?\nThis replaces your saved shop (Shift %d, Bank %s). A copy of the old save is kept beside it." % [save_info["shift"], main._format_money(save_info["money"])]
	else:
		confirm_label.text = "Start a new game?\nThe save file there can't be continued (damaged, or from an older version). A copy of it is kept beside it."
	show_page(confirm_page)

## A fresh shop over an existing save: the old file is copied aside
## (<save>.prev.bak), and the fresh shop is written at once, so Continue never
## offers the old one again.
func start_new_game() -> void:
	if FileAccess.file_exists(main.save_path):
		DirAccess.copy_absolute(main.save_path, main.save_path + ".prev.bak")
	main.start_new_game()

func _on_wishlist() -> void:
	last_opened_url = PacingScript.STEAM_WISHLIST_URL
	if not test_no_shell:
		OS.shell_open(PacingScript.STEAM_WISHLIST_URL)

## --- credits ------------------------------------------------------------------

func _build_credits() -> void:
	credits_layer = Control.new()
	credits_layer.name = "Credits"
	credits_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	credits_layer.visible = false
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.05, 0.08, 0.92) # the report screen's backdrop
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	credits_layer.add_child(bg)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 40.0
	box.offset_right = -40.0
	box.offset_top = 20.0
	box.offset_bottom = -20.0
	box.add_theme_constant_override("separation", 10)
	credits_layer.add_child(box)
	var head := Label.new()
	head.text = "Credits"
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_theme_font_size_override("font_size", 30)
	box.add_child(head)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	var body := Label.new()
	body.name = "Body"
	body.text = CREDITS_TEXT
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_theme_font_size_override("font_size", 14)
	body.add_theme_color_override("font_color", Color(0.9, 0.95, 1))
	scroll.add_child(body)
	credits_back = _button("CreditsBackButton", "Back")
	credits_back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	credits_back.custom_minimum_size.x = 200.0
	credits_back.pressed.connect(close_credits)
	box.add_child(credits_back)
	main.menu_layer.add_child(credits_layer)

func open_credits() -> void:
	credits_layer.visible = true
	menu.visible = false
	credits_back.grab_focus.call_deferred()

func close_credits() -> void:
	credits_layer.visible = false
	menu.visible = true
	credits_button.grab_focus.call_deferred()

## --- building blocks (the scene's IpLabel look; default button theme) ---------

func _page(n: String) -> VBoxContainer:
	var p := VBoxContainer.new()
	p.name = n
	p.add_theme_constant_override("separation", 8)
	return p

func _button(n: String, text: String, primary := false) -> Button:
	var b := Button.new()
	b.name = n
	b.text = text
	b.custom_minimum_size.y = PRIMARY_HEIGHT if primary else BUTTON_HEIGHT
	if primary:
		b.add_theme_font_size_override("font_size", PRIMARY_FONT)
	return b

func _adopt(page: Control, c: Control) -> void:
	c.get_parent().remove_child(c)
	page.add_child(c)
	if c is Button:
		c.custom_minimum_size.y = BUTTON_HEIGHT

func _label(text: String, size: int, color := TEXT_LIGHT) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.custom_minimum_size = Vector2(MENU_WIDTH, 0)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l
