extends "res://tools/hazards_test.gd"
## PHASE 5 — polish: the main menu (MainMenu.gd), the demo cap (Pacing.gd,
## Main.gd's demo_over), the open-early hint, the gear rename (Cleaning Cart)
## and old saves, the helper/forklift overlap. Reuses tools/hazards_test.gd's
## helpers and drives the real Main.tscn. Not part of the game. Real
## wall-clock time throughout (no --fixed-fps).
##
## MAIN MENU — no save: Continue hidden, the buttons, keyboard focus; a save
## appears: Continue with its shift and bank; Credits opens/closes (button,
## Esc) and carries the required attributions; Play Together -> the host/join
## page and back; New Game over a save asks first (Cancel keeps it), then
## starts a fresh shop, keeps a copy, and is hosting; no Wishlist button:
##   godot --headless --path . --script res://tools/phase5_test.gd -- --save-file=user://p5_menu/save.json --test=menu
## CONTINUE — a v6 save on disk: Continue says its shift and bank, and loads it:
##   godot ... -- --save-file=user://p5_cont/save.json --test=menu-continue
## HOST CO-OP from the Play Together page: hosting, the lobby's first shift:
##   godot ... -- --no-save --test=menu-host
## DEMO MENU — --demo: the Wishlist button shows and opens the store URL:
##   godot ... -- --no-save --demo --test=menu-demo
## DEMO CAP — the demo's last shift: its report says Finish Demo, Continue
## ends play (thanks screen, nothing advances); off in a normal build:
##   godot ... -- --server --demo --day=4 --no-save --shift-seconds=4 --prep-seconds=0 --cleanup-seconds=0 --test=demo-cap
##   godot ... -- --server --day=4 --no-save --shift-seconds=4 --prep-seconds=0 --cleanup-seconds=0 --test=demo-off
## A demo save already past the cap opens on the thanks screen:
##   godot ... -- --server --demo --save-file=user://p5_demo/save.json --test=demo-save
## CO-OP DEMO CAP (host + 1 client): the client sees Finish Demo and the end:
##   godot ... -- --server --demo --day=4 --players=2 --no-save --shift-seconds=6 --prep-seconds=0 --cleanup-seconds=0 --test=net-demo &
##   godot ... -- --client --connect-port=P --no-save --test=net-demo
## OPEN-EARLY HINT — prep with shelves stocked: the prep line turns into the
## nudge and one toast; not before they're stocked, not after opening, once a
## shift, retired after the crew has opened early enough times:
##   godot ... -- --server --day=1 --no-save --test=open-early
## GEAR RENAME — "Cleaning Cart" in the shop; a save holding the old key
## ("janitor") loads into it, writes it back unchanged:
##   godot ... -- --server --save-file=user://p5_gear/save.json --test=gear
## MENU SHOTS (xvfb, no --headless): the menu at common window sizes and in
## fullscreen, inside the screen; the demo end screen; the hint:
##   xvfb-run -a godot --path . --script res://tools/phase5_test.gd -- --save-file=user://p5_shots/save.json --test=shots

## Loaded at run time, not preloaded: SaveGame.gd preloads game scripts that
## name the autoloads, which don't exist yet when this script compiles.
var SaveGameScript: GDScript
var PacingScript: GDScript

var _mode := ""
var _left := ""

func _initialize() -> void:
	SaveGameScript = load("res://SaveGame.gd")
	PacingScript = load("res://Pacing.gd")
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--test="):
			_mode = a.substr(7)
	var save_path := ""
	for a in args:
		if a.begins_with("--save-file="):
			save_path = a.substr("--save-file=".length())
	if save_path != "":
		for suffix in ["", ".prev.bak", ".tmp", ".bad"]:
			DirAccess.remove_absolute(save_path + suffix)
		match _mode:
			"menu-continue":
				_write_save(save_path, 6, 830, {})
			"demo-save":
				_write_save(save_path, PacingScript.DEMO_SHIFT_CAP, 1200, {})
			"gear":
				_write_save(save_path, 2, 900, {"janitor": 2, "shoes": 1})
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	main.events_on = false
	careless = true
	root.get_node("Sfx").log_plays = false
	main.test_leave_hook = func(to_desktop: bool): _left = "desktop" if to_desktop else "menu"
	if OS.get_environment("SW_NET_DIR") == "":
		NET_DIR = "user://net_p5_%s/" % _mode
	var client := "--client" in args
	match _mode:
		"menu": _run_menu.call_deferred()
		"menu-continue": _run_menu_continue.call_deferred()
		"menu-host": _run_menu_host.call_deferred()
		"menu-demo": _run_menu_demo.call_deferred()
		"demo-cap": _run_demo_cap.call_deferred()
		"demo-off": _run_demo_off.call_deferred()
		"demo-save": _run_demo_save.call_deferred()
		"net-demo": (_run_net_demo_client if client else _run_net_demo_host).call_deferred()
		"open-early": _run_open_early.call_deferred()
		"gear": _run_gear.call_deferred()
		"shots": _run_shots.call_deferred()
		"fk-helpers": _run_fk_helpers.call_deferred()
		"fk-escape": _run_fk_escape.call_deferred()
		_:
			print("FAIL  unknown --test=%s" % _mode)
			quit(1)

## A version-6 save: `completed` shifts done, `money` in the bank, two
## sections, the given gear.
func _write_save(path: String, completed: int, money: int, gear: Dictionary) -> void:
	var data := {
		"version": 6,
		"saved_at": "2026-10-08T00:00:00",
		"shop": {"completed_day": completed, "money": money, "lifetime_earned": 2000, "sections_owned": 2, "stage": 2, "lifetime_sold": 150},
		"staff": {},
		"upkeep": {"rating": 3.4, "cans": [0, 0, 0, 0]},
		"gear": gear,
		"events": {"seen": [], "completed": 0},
	}
	check(SaveGameScript.write(path, data), "setup: wrote a v6 save (%d shifts done, $%d)" % [completed, money])

func mm() -> Node:
	return main.main_menu

func visible_buttons(page: Control) -> Array:
	return page.get_children().filter(func(c): return c is Button and c.visible).map(func(c): return String(c.name))

## Hosting or joined (the menu's offline peer reports itself active too).
func net_on() -> bool:
	return root.get_node("Net").is_active() and not (get_multiplayer().multiplayer_peer is OfflineMultiplayerPeer)

func key_event(code: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)

func key_tap(code: Key) -> void:
	key_event(code, true)
	await process_frame
	await process_frame
	key_event(code, false)
	await process_frame

func focused() -> Control:
	return root.gui_get_focus_owner()

## --- MAIN MENU ------------------------------------------------------------------

func _run_menu() -> void:
	await wait(0.6)
	# --- M1 no save
	check(main.menu_layer.visible and not net_on(), "M1: on the main menu, not hosting")
	check(mm().title.text == "SHIFT WORK", "M1: the title says SHIFT WORK ('%s')" % mm().title.text)
	var btns := visible_buttons(mm().main_page)
	check(btns == ["NewGameButton", "PlayTogetherButton", "PracticeButton", "SettingsButton", "CreditsButton", "QuitButton"], "M1: no save -> no Continue, no Wishlist: %s" % str(btns))
	check(not PacingScript.is_demo() and not mm().wishlist_button.visible, "M1: a normal build: no Wishlist button")
	check(focused() == mm().new_game_button, "M1: keyboard focus starts on New Game (%s)" % (focused().name if focused() else "none"))
	await key_tap(KEY_DOWN)
	check(focused() == mm().play_together_button, "M1: Down moves focus to Play Together (%s)" % (focused().name if focused() else "none"))
	await key_tap(KEY_UP)
	check(focused() == mm().new_game_button, "M1: Up moves it back")
	# --- M2 a save appears (the menu re-reads it whenever it shows a page)
	var path: String = main.save_path
	_write_save(path, 11, 2345, {})
	mm().show_page(mm().main_page)
	await wait(0.1)
	btns = visible_buttons(mm().main_page)
	check(btns[0] == "ContinueButton", "M2: Continue at the top once a save exists: %s" % str(btns))
	check(mm().continue_button.text == "Continue  ·  Shift 12  ·  Bank $2345", "M2: Continue shows the shift and bank: '%s'" % mm().continue_button.text)
	check(focused() == mm().continue_button, "M2: focus starts on Continue")
	# --- M3 credits
	mm().credits_button.pressed.emit()
	await wait(0.1)
	check(mm().credits_layer.visible and not mm().menu.visible, "M3: Credits opens over the menu")
	check(focused() == mm().credits_back, "M3: focus on its Back button")
	var body: String = mm().credits_layer.find_child("Body", true, false).text
	for must in ["\"Monkeys Spinning Monkeys\" Kevin MacLeod (incompetech.com)", "Licensed under Creative Commons: By Attribution 3.0 License", "Universal LPC Spritesheet Character Generator", "CC-BY-SA 3.0", "Kelano Studio", "karsiori", "Kenney"]:
		check(body.contains(must), "M3: credits carry '%s'" % must)
	var md := FileAccess.get_file_as_string("res://assets/CREDITS.md") + FileAccess.get_file_as_string("res://audio/CREDITS.md")
	for must in ["\"Monkeys Spinning Monkeys\" Kevin MacLeod (incompetech.com)", "Universal LPC Spritesheet Character Generator", "Kelano Studio", "karsiori"]:
		check(md.contains(must), "M3: ...and so do the CREDITS.md files ('%s')" % must)
	await key_tap(KEY_ESCAPE)
	check(not mm().credits_layer.visible and mm().menu.visible, "M3: Esc closes Credits")
	mm().credits_button.pressed.emit()
	await wait(0.1)
	mm().credits_back.pressed.emit()
	await wait(0.1)
	check(not mm().credits_layer.visible and mm().main_page.visible and focused() == mm().credits_button, "M3: Back closes it, focus back on Credits")
	# --- M4 Play Together -> host / join
	mm().play_together_button.pressed.emit()
	await wait(0.1)
	check(mm().coop_page.visible and not mm().main_page.visible, "M4: Play Together opens the co-op page")
	btns = visible_buttons(mm().coop_page)
	check(btns == ["HostButton", "JoinButton", "BackButton"] and main.host_button.text == "Host Co-op" and main.join_button.text == "Join Co-op", "M4: Host Co-op / Join Co-op / Back: %s" % str(btns))
	var kids: Array = mm().coop_page.get_children()
	check(kids.find(main.ip_input) == kids.find(main.join_button) - 1 and main.ip_input.visible, "M4: the IP field sits right above Join Co-op")
	check(mm().host_note.text.contains("Shift 12"), "M4: Host Co-op says it hosts the saved shop: '%s'" % mm().host_note.text)
	check(focused() == main.host_button, "M4: focus on Host Co-op")
	await key_tap(KEY_ESCAPE)
	check(mm().main_page.visible and not mm().coop_page.visible, "M4: Esc goes back to the main page")
	# --- M5 New Game over a save: asks first
	var before := FileAccess.get_file_as_string(path)
	mm().new_game_button.pressed.emit()
	await wait(0.2)
	check(mm().confirm_page.visible and not net_on(), "M5: New Game with a save asks first (not hosting yet)")
	check(mm().confirm_label.text.contains("Shift 12") and mm().confirm_label.text.contains("$2345"), "M5: the question names the save it replaces: '%s'" % mm().confirm_label.text.replace("\n", " / "))
	check(focused() == mm().confirm_button, "M5: focus on Start New Game")
	mm().cancel_button.pressed.emit()
	await wait(0.2)
	check(mm().main_page.visible and FileAccess.get_file_as_string(path) == before and not net_on(), "M5: Cancel -> back, the save untouched")
	mm().new_game_button.pressed.emit()
	await wait(0.2)
	mm().confirm_button.pressed.emit()
	await wait_until(func(): return main.shift_active, 15.0)
	check(root.get_node("Net").is_active() and main.multiplayer.is_server() and not main.menu_layer.visible, "M5: Start New Game -> hosting")
	check(main.current_day == 1 and main.money == 0 and main.sections_owned == 1 and not main.tutorial.active, "M5: a fresh shop: Shift 1, $0, Dry Goods (shift %d, %s)" % [main.current_day, main._format_money(main.money)])
	var peek: Dictionary = SaveGameScript.peek(path)
	check(peek["ok"] and peek["shift"] == 1 and peek["money"] == 0, "M5: the save now holds the fresh shop at once: %s" % str(peek))
	check(FileAccess.get_file_as_string(path + ".prev.bak") == before, "M5: the old save is kept as save.json.prev.bak")
	finish()

func _run_menu_continue() -> void:
	await wait(0.6)
	check(mm().continue_button.visible and mm().continue_button.text == "Continue  ·  Shift 7  ·  Bank $830", "C1: Continue: '%s'" % mm().continue_button.text)
	mm().continue_button.pressed.emit()
	await wait_until(func(): return main.shift_active, 15.0)
	check(main.current_day == 7 and main.money == 830 and main.sections_owned == 2, "C1: Continue loaded the save: Shift %d, %s, %d sections" % [main.current_day, main._format_money(main.money), main.sections_owned])
	check(main.status_label.text.begins_with("Shift 7  ·  Bank $830"), "C1: the HUD says '%s'" % main.status_label.text)
	finish()

func _run_menu_host() -> void:
	await wait(0.6)
	check(not mm().continue_button.visible, "H1: --no-save: no Continue")
	mm().play_together_button.pressed.emit()
	await wait(0.1)
	main.host_button.pressed.emit()
	await wait_until(func(): return main.shift_active and main.players.size() == 1, 15.0)
	check(root.get_node("Net").is_active() and main.multiplayer.is_server() and main.shift_active and not main.menu_layer.visible, "H1: Host Co-op -> hosting, the first shift's prep running, waiting for friends")
	finish()

func _run_menu_demo() -> void:
	await wait(0.6)
	check(PacingScript.is_demo(), "D1: --demo turns the demo on")
	check(mm().wishlist_button.visible and visible_buttons(mm().main_page).back() == "WishlistButton", "D1: the demo menu ends with Wishlist on Steam: %s" % str(visible_buttons(mm().main_page)))
	mm().test_no_shell = true
	mm().wishlist_button.pressed.emit()
	check(mm().last_opened_url == PacingScript.STEAM_WISHLIST_URL and mm().last_opened_url.begins_with("https://store.steampowered.com/"), "D1: it opens the store page (placeholder URL '%s')" % mm().last_opened_url)
	finish()

## --- DEMO CAP --------------------------------------------------------------------

func _to_report() -> void:
	await wait_until(func(): return main.shift_active, 20.0)
	main.open_store(1)
	await wait_until(func(): return main.is_day_report_active(), 60.0)
	await wait(0.3)

func _run_demo_cap() -> void:
	check(PacingScript.is_demo() and PacingScript.DEMO_SHIFT_CAP == 4, "DC1: the demo, capped at %d shifts" % PacingScript.DEMO_SHIFT_CAP)
	# Shift 3 first: the cap isn't there yet.
	main.current_day = 3
	await _to_report()
	check(main.demo_mode and not main.demo_cap_reached() and main.continue_button.text == "Continue", "DC1: Shift 3's report: plain Continue ('%s')" % main.continue_button.text)
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 10.0)
	check(main.current_day == 4 and not main.demo_over, "DC1: on to Shift 4")
	await _to_report()
	check(main.demo_cap_reached() and main.continue_button.text == "Finish Demo", "DC2: Shift 4's report: 'Finish Demo' ('%s')" % main.continue_button.text)
	check(not main._demo_end.visible, "DC2: no end screen yet — the report first")
	main.continue_button.pressed.emit()
	await wait(0.3)
	check(main.demo_over and main._demo_end.visible, "DC3: Finish Demo -> the thanks screen")
	check(main.current_day == 4 and not main.shift_active and main.is_day_report_active(), "DC3: nothing advanced (Shift %d, no new shift)" % main.current_day)
	check(main._demo_end_body.text.contains("4 shifts") and main._demo_end_body.text.contains("Wishlist"), "DC3: it thanks and asks for a wishlist: '%s'" % main._demo_end_body.text.replace("\n", " "))
	main._on_continue_pressed()
	await wait(1.0)
	check(main.current_day == 4 and not main.shift_active, "DC3: a second Continue still doesn't start Shift 5")
	main.main_menu.test_no_shell = true
	main.demo_end_wishlist.pressed.emit()
	check(main.main_menu.last_opened_url == PacingScript.STEAM_WISHLIST_URL, "DC4: its Wishlist button opens the store page")
	main.demo_end_menu.pressed.emit()
	await wait(0.2)
	check(_left == "menu", "DC4: Main Menu leaves the session for the menu")
	finish()

func _run_demo_off() -> void:
	check(not PacingScript.is_demo(), "DO1: a normal build: no demo")
	await _to_report()
	check(not main.demo_mode and main.continue_button.text == "Continue", "DO1: Shift 4's report: plain Continue")
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 10.0)
	check(main.current_day == 5 and not main.demo_over and not main._demo_end.visible, "DO1: Shift 5 starts — no cap")
	finish()

func _run_demo_save() -> void:
	await wait(3.0)
	check(main.demo_mode and main.demo_over and main._demo_end.visible, "DS1: a demo save past the cap opens on the thanks screen")
	check(not main.shift_active and main.current_day == PacingScript.DEMO_SHIFT_CAP + 1, "DS1: no shift starts (Shift %d)" % main.current_day)
	finish()

func _run_net_demo_host() -> void:
	await wait_until(func(): return main.players.size() >= 2 and main.shift_active, 30.0)
	await wait(0.5)
	main.open_store(1)
	await wait_until(func(): return main.is_day_report_active(), 60.0)
	await wait(0.5)
	check(main.continue_button.text == "Finish Demo", "ND1: host: Finish Demo")
	var r := await _net_read("c_report.json", 30.0)
	check(r.get("text", "") == "Finish Demo", "ND1: the client's report says it too: %s" % str(r))
	_net_write("go.json", {})
	await wait_until(func(): return main.demo_over, 15.0)
	check(main.demo_over and main._demo_end.visible and main.current_day == 4 and not main.shift_active, "ND2: the client's Finish Demo ended the demo for the crew (host screen up, nothing advanced)")
	var r2 := await _net_read("c_end.json", 30.0)
	check(r2.get("end", false), "ND2: the client shows the thanks screen: %s" % str(r2))
	_net_write("done.json", {})
	await wait(1.0)
	finish()

func _run_net_demo_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1, 30.0)
	await wait_until(func(): return main.is_day_report_active(), 90.0)
	await wait(0.5)
	_net_write("c_report.json", {"text": main.continue_button.text})
	await _net_read("go.json", 30.0)
	main.continue_button.pressed.emit()
	await wait_until(func(): return main._demo_end.visible, 15.0)
	_net_write("c_end.json", {"end": main._demo_end.visible and main.demo_over})
	await _net_read("done.json", 30.0)
	finish()

## --- OPEN-EARLY HINT -------------------------------------------------------------

func _stock_open_shelves(fraction: float) -> void:
	var slots := []
	for sb in main.shelves:
		if main.is_unlocked_at_pos(sb.global_position):
			var sec: String = main._section_name_at(sb.global_position)
			for sl in sb.get_node("Shelf").slots:
				slots.append([sec, sl.global_position])
	var want := int(ceil(slots.size() * fraction))
	for i in want:
		main.spawn_product_at(slots[i][0], slots[i][1])
	await wait_until(func(): return main.open_shelf_fill() >= float(want) / slots.size() - 0.001, 8.0)

func _run_open_early() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 20.0)
	main.test_hold_customers = true
	await wait(0.5)
	# --- OE1 prep, empty shelves: the plain prep line, no nudge
	check(not main.store_open and main.prep_time_left > 100.0, "OE1: prep, %.0fs left" % main.prep_time_left)
	check(not main.open_early_nudge and main.open_early_toasts == 0, "OE1: empty shelves — no nudge yet")
	check(main._prep_label.text.contains("Open early: unused prep = selling time"), "OE1: the prep line says what opening early does: '%s'" % main._prep_label.text)
	# --- OE2 shelves half stocked: still nothing
	await _stock_open_shelves(0.5)
	await wait(0.3)
	check(main.open_shelf_fill() >= 0.5 and not main.open_early_nudge, "OE2: %.0f%% stocked — under the hint's %.0f%%: no nudge" % [main.open_shelf_fill() * 100.0, PacingScript.OPEN_EARLY_HINT_FILL * 100.0])
	# --- OE3 stocked: the nudge and ONE toast
	await _stock_open_shelves(1.0)
	await wait(0.3)
	check(main.open_shelf_fill() >= PacingScript.OPEN_EARLY_HINT_FILL and main.open_early_nudge, "OE3: %.0f%% stocked -> the nudge" % (main.open_shelf_fill() * 100.0))
	check(main._prep_label.text.begins_with("PREP — shelves stocked! Flip the sign to open early") and main._prep_label.text.contains("more selling time"), "OE3: the prep line: '%s'" % main._prep_label.text)
	check(main.open_early_toasts == 1 and main._toast_label.text.contains("open early") and main._toast_timer > 0.0, "OE3: one toast: '%s'" % main._toast_label.text)
	await wait(1.0)
	check(main.open_early_toasts == 1, "OE3: still one toast a second later")
	# --- OE4 not with too little prep left
	var keep: float = main.prep_time_left
	main.prep_time_left = PacingScript.OPEN_EARLY_HINT_MIN_PREP - 5.0
	await wait(0.2)
	check(not main.open_early_nudge, "OE4: under %.0fs of prep left — no nudge" % PacingScript.OPEN_EARLY_HINT_MIN_PREP)
	main.prep_time_left = keep
	await wait(0.2)
	# --- OE5 opening early: the nudge goes, the open counts
	main.open_store(1)
	await wait(0.3)
	check(not main.open_early_nudge and main.opened_early_shifts == 1, "OE5: opened with prep to spare -> no nudge, counted (%d)" % main.opened_early_shifts)
	# --- OE6 next shifts: once a shift, then retired
	var toasts_by_shift := [main.open_early_toasts]
	for n in PacingScript.OPEN_EARLY_HINT_RETIRE:
		main.start_cleanup()
		main.clock_out(1)
		await wait_until(func(): return main.is_day_report_active(), 20.0)
		main._on_continue_pressed()
		await wait_until(func(): return main.shift_active and not main.is_day_report_active(), 10.0)
		await wait(0.3)
		await _stock_open_shelves(1.0)
		await wait(0.3)
		toasts_by_shift.append(main.open_early_toasts)
		print("INFO  shift %d: fill %.2f, prep left %.0f, nudge %s, toasts %d, opened early %d" % [main.current_day, main.open_shelf_fill(), main.prep_time_left, str(main.open_early_nudge), main.open_early_toasts, main.opened_early_shifts])
		main.open_store(1)
		await wait(0.3)
	check(main.opened_early_shifts == PacingScript.OPEN_EARLY_HINT_RETIRE + 1, "OE6: opened early %d times" % main.opened_early_shifts)
	var expect := []
	for i in toasts_by_shift.size():
		expect.append(mini(i + 1, PacingScript.OPEN_EARLY_HINT_RETIRE))
	check(toasts_by_shift == expect, "OE6: one toast a shift until the crew has opened early %d times, then none: %s (want %s)" % [PacingScript.OPEN_EARLY_HINT_RETIRE, str(toasts_by_shift), str(expect)])
	finish()

## --- GEAR RENAME -----------------------------------------------------------------

func _run_gear() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 20.0)
	await wait(0.5)
	var shop: Node = main.shop
	check(shop._name_of("janitor") == "Cleaning Cart", "G1: the gear is called Cleaning Cart ('%s')" % shop._name_of("janitor"))
	for u in shop.UPGRADES:
		check(not str(u["name"]).contains("Janitor"), "G1: no gear named like the hireable janitor ('%s')" % u["name"])
	check(shop.upgrades.get("janitor", 0) == 2 and shop.upgrades.get("shoes", 0) == 1, "G2: the save's old key loaded: %s" % str(shop.upgrades))
	check(is_equal_approx(shop.cleanup_time_mult(), 0.6) and shop.pan_bonus() == 8, "G2: ...and its effect is on (cleaning x%.1f, dustpan +%d)" % [shop.cleanup_time_mult(), shop.pan_bonus()])
	check(await walk_to(shop.LOCKER_SPOT, 10.0, 25.0), "G3: walked to the gear lockers")
	await tap(act + "interact")
	await wait(0.4)
	var texts := []
	for l in shop.panel.find_children("*", "Label", true, false):
		texts.append(l.text)
	var joined := " | ".join(texts)
	check(joined.contains("Cleaning Cart  Lv 2/2") and not joined.contains("Janitor's Kit"), "G3: the shop panel lists 'Cleaning Cart  Lv 2/2'")
	check(main.save_progress("gear test"), "G4: saved")
	var raw = JSON.parse_string(FileAccess.get_file_as_string(main.save_path))
	check(raw is Dictionary and raw["gear"].get("janitor", 0) == 2 and not raw["gear"].has("cleaning_cart") and int(raw["version"]) == SaveGameScript.VERSION, "G4: written back under the same key, same save version: %s" % str(raw.get("gear") if raw is Dictionary else raw))
	finish()

## --- SHOTS (xvfb) ----------------------------------------------------------------



func _shot(name: String) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("user://phase5_shots")
	var path := "user://phase5_shots/%02d_%s.png" % [shot_index, name]
	shot_index += 1
	root.get_texture().get_image().save_png(path)
	print("SHOT  " + ProjectSettings.globalize_path(path))

func _menu_inside(tag: String) -> void:
	var vp: Vector2 = root.get_visible_rect().size
	var panel: Control = main.menu_layer.get_node("Center/Panel")
	var r := Rect2(Vector2.ZERO, vp).grow(1.0)
	check(r.encloses(panel.get_global_rect()), "W: %s: the menu panel %s is inside the %s view" % [tag, str(panel.get_global_rect()), str(vp)])

func _run_shots() -> void:
	await wait(0.8)
	_write_save(main.save_path, 11, 2345, {})
	mm().show_page(mm().main_page)
	await wait(0.2)
	var win0: Vector2i = root.size
	for sz in [Vector2i(960, 540), Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1920, 1080), Vector2i(800, 600)]:
		root.size = sz
		await wait(0.4)
		_menu_inside("window %dx%d" % [sz.x, sz.y])
		await _shot("title_%dx%d" % [sz.x, sz.y])
	root.size = win0
	await wait(0.3)
	var S: Node = root.get_node("Settings")
	S.set_fullscreen(true)
	await wait(0.8)
	var scr := DisplayServer.screen_get_size()
	if root.size != scr:
		root.size = scr # no window manager under xvfb (see menu_test.gd)
		await wait(0.6)
	_menu_inside("fullscreen %s" % str(scr))
	await _shot("title_fullscreen")
	S.set_fullscreen(false)
	root.size = win0
	await wait(0.5)
	await key_tap(KEY_DOWN)
	await _shot("title_keyboard_focus_new_game")
	mm().play_together_button.pressed.emit()
	await wait(0.2)
	await _shot("play_together")
	mm().show_page(mm().main_page)
	mm().new_game_button.pressed.emit()
	await wait(0.2)
	await _shot("new_game_confirm")
	mm().show_page(mm().main_page)
	mm().credits_button.pressed.emit()
	await wait(0.2)
	await _shot("credits")
	mm().close_credits()
	mm().wishlist_button.visible = true # as the demo build shows it
	await _shot("title_demo_wishlist")
	mm().wishlist_button.visible = false
	# Into a game: the HUD and the open-early hint.
	main.prep_ceiling_override = 600.0
	mm().continue_button.pressed.emit()
	await wait_until(func(): return main.shift_active, 15.0)
	main.test_hold_customers = true
	await wait(1.0)
	await _shot("hud_prep")
	await _stock_open_shelves(1.0)
	await wait(0.5)
	var p := player()
	p.teleport_to(area_spot("hub", Vector2(0, -50)))
	await wait(0.6)
	check(main.open_early_nudge, "SH: the hint is up for its shot")
	await _shot("open_early_hint")
	main.open_store(1)
	main.test_hold_customers = false
	await wait(6.0)
	await _shot("hud_selling")
	main.start_cleanup()
	main.clock_out(1)
	await wait_until(func(): return main.is_day_report_active(), 10.0)
	await wait(0.5)
	await _shot("report")
	# The demo's end, as the demo build shows it (shift 12 is past the cap).
	main.demo_mode = true
	await wait(0.2)
	main.continue_button.pressed.emit()
	await wait(0.5)
	check(main._demo_end.visible, "SH: the demo end screen is up")
	await _shot("demo_end")
	finish()

## --- HELPERS AND THE FORKLIFT ------------------------------------------------------
## Phase 4B's soak saw a section helper inside the Produce forklift's body for
## 8 frames once. Every helper hired, the top tier (the forklift's hottest
## lap), a long selling window, nobody playing: every physics frame, after
## the helpers and the forklift have both moved, no helper is inside the
## forklift's body (Helper.gd's _in_forklift(), +2px); each overlap frame is
## printed with the state that led to it.
##   godot --headless --path . --script res://tools/phase5_test.gd -- --server --day=7 --no-save --prep-seconds=0 --shift-seconds=300 --test=fk-helpers
func _run_fk_helpers() -> void:
	await wait_until(func(): return main.players.has(1), 20.0)
	main.staff.staff = {"Produce": {"speed": 0, "carry": 0}, "Dairy/Frozen": {"speed": 0, "carry": 0}, "Bakery": {"speed": 0, "carry": 0}}
	await wait_until(func(): return main.shift_active, 20.0)
	player().teleport_to(area_spot("break_room")) # out of everyone's way, in the break room
	main.open_store(1)
	var h: Node2D = main.staff.helpers["Produce"]
	var fk: Node2D = main.forklift
	var frames := 0
	var overlap := 0
	var close := 0
	var near_ram := 0
	var rams0: int = fk.rams_today
	var episodes := 0
	var in_ep := false
	while main.shift_active and not main.cleanup_active:
		# After every node's _physics_process this frame (process_frame comes
		# after the physics step), so this sees where both actually ended up.
		await process_frame
		if main.is_day_report_active():
			break
		frames += 1
		if not h.active or h._forklift_live() == null:
			in_ep = false
			continue
		if h._in_forklift(h.position, 2.0):
			overlap += 1
			if not in_ep:
				episodes += 1
			in_ep = true
			if overlap <= 40:
				var rel: Vector2 = (h.position - fk.global_position).rotated(-fk.rotation)
				print("INFO  OVERLAP f=%d helper %s (local %s) job=%s pause=%.2f | forklift %s rot %.3f v %.0f alert %s reversing %s state %s" % [frames, str(h.position.round()), str(rel.round()), h._job.get("kind", "-"), h._pause, str(fk.global_position.round()), fk.rotation, fk.velocity.length(), str(fk.alert), str(fk.reversing), str(fk.get("state"))])
		else:
			in_ep = false
			if h._in_forklift(h.position, 20.0):
				close += 1
	print("INFO  FK-HELPERS frames %d, overlap frames %d in %d episode(s), within 20px %d, rams %d, Produce helper placed %d" % [frames, overlap, episodes, close, fk.rams_today - rams0, h.placed_today])
	check(frames > 1200, "FK1: watched %d frames of selling" % frames)
	check(h.placed_today > 0, "FK1: the Produce helper worked the aisle (%d placed)" % h.placed_today)
	check(overlap == 0, "FK1: the Produce helper was never inside the forklift's body (%d frames, %d episodes; within 20px %d frames)" % [overlap, episodes, close])
	finish()

## THE ESCAPE (deterministic): the forklift held still at a pose (as if it
## had just stopped with its forks over someone, or rammed a shelf with a
## helper at it), the Produce helper put inside its body at several spots,
## then left to its own brain. FOUND IN PHASE 5: inside, the helper stepped
## out sideways, but if that side left the room's open band it turned round
## and walked out the other side, THROUGH the forklift, or stayed clamped
## against the band's edge still under it. Every placement must be clear of
## the body within ESCAPE_FRAMES (a quarter second at its flee speed is ~40 px).
##   godot --headless --path . --script res://tools/phase5_test.gd -- --server --day=3 --no-save --prep-seconds=900 --test=fk-escape
const ESCAPE_FRAMES := 12

func _run_fk_escape() -> void:
	await wait_until(func(): return main.players.has(1) and main.shift_active, 20.0)
	main.staff.staff = {"Produce": {"speed": 0, "carry": 0}}
	await wait(0.5)
	var h: Node2D = main.staff.helpers["Produce"]
	var fk: CharacterBody2D = main.forklift
	check(h.active, "FE0: the Produce helper is on the floor")
	player().teleport_to(area_spot("break_room"))
	fk.set_physics_process(false) # held exactly where it's put
	var room: Rect2 = h._room
	var band_top: float = room.position.y + h.band_y.x
	var band_bot: float = room.position.y + h.band_y.y
	var poses := []
	for x in [2150.0, 2400.0, 2650.0]:
		for y in [band_top + 4.0, room.position.y + 270.0, band_bot - 4.0]:
			for rot in [0.0, PI / 2.0, PI, -PI / 2.0, 0.6]:
				poses.append([Vector2(x, y), rot])
	var worst := 0
	var stuck := 0
	var through := 0
	var n := 0
	for pose in poses:
		for off in [Vector2(6, 0), Vector2(30, 10), Vector2(-30, -10), Vector2(6, 18), Vector2(6, -18)]:
			fk.global_position = pose[0]
			fk.rotation = pose[1]
			fk.velocity = Vector2.ZERO
			await physics_frame
			await physics_frame # the helper's turn-tracking settles on the new pose
			var start: Vector2 = pose[0] + off.rotated(pose[1])
			h.position = start
			h.target_position = start
			h._path = PackedVector2Array()
			h._path_goal = Vector2.INF
			var frames := 0
			while h._in_forklift(h.position, 2.0) and frames < 120:
				await physics_frame
				frames += 1
			n += 1
			worst = maxi(worst, frames)
			# Out the far side of the body = walked through it.
			var rel_start: Vector2 = (start - fk.global_position).rotated(-fk.rotation)
			var rel_end: Vector2 = (h.position - fk.global_position).rotated(-fk.rotation)
			if signf(rel_start.y) != 0.0 and signf(rel_end.y) == -signf(rel_start.y) and absf(rel_end.y) > 20.0 and absf(rel_start.y) > 4.0:
				through += 1
				if through <= 10:
					print("INFO  THROUGH forklift %s rot %.2f, helper from %s (local %s, band %.0f-%.0f) to %s (local %s) in %d frames" % [str(pose[0]), pose[1], str(start.round()), str(rel_start.round()), band_top, band_bot, str(h.position.round()), str(rel_end.round()), frames])
			if frames > ESCAPE_FRAMES:
				stuck += 1
				if stuck <= 8:
					print("INFO  SLOW ESCAPE %d frames: forklift %s rot %.2f, helper from %s (local %s) to %s (local %s)" % [frames, str(pose[0]), pose[1], str(start.round()), str(rel_start.round()), str(h.position.round()), str(rel_end.round())])
	fk.set_physics_process(true)
	print("INFO  FK-ESCAPE %d placements, worst %d frames, over %d frames: %d, walked through the body: %d" % [n, worst, ESCAPE_FRAMES, stuck, through])
	check(stuck == 0, "FE1: out of the forklift's body within %d frames from every one of %d placements (worst %d; %d slow)" % [ESCAPE_FRAMES, n, worst, stuck])
	check(through == 0, "FE2: never out through the far side of the body (%d)" % through)
	finish()
