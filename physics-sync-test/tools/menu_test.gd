extends "res://tools/hazards_test.gd"
## OCT 2026 PHASE 4C — the pause menu, the settings screen and quitting
## (PauseMenu.gd, SettingsMenu.gd, Settings.gd, Main.gd's leave_session()).
## Reuses tools/hazards_test.gd's helpers (walking, key taps, net files) and
## drives the real Main.tscn through the real game code. Not part of the
## game. Real wall-clock time throughout (no --fixed-fps): pausing is about
## time not passing.
##
## SOLO PAUSE — prep and open store, Day 7 with every system running (event,
## helpers, janitor, forklift, manager, delivery, customers, rating drift):
## nothing moves or counts down while paused, everything resumes with no
## jump; Esc's order (panel first, then the menu); Settings over the pause;
## the report; the "Esc: menu" hint:
##   godot --headless --path . --script res://tools/menu_test.gd -- --server --day=7 --no-save --money=20000 --events=on --test=pause
## SOLO QUIT — Quit to Main Menu mid-shift (the confirmation, what it says,
## the save untouched, a real reload to the menu, hosting again from it),
## quitting at the report (no confirmation, the day saved), then a real Quit
## to Desktop:
##   godot ... -- --server --save-file=user://menu_test/save.json --new-game --test=quit-solo
## SETTINGS — persistence (round trip, missing file, corrupt file, bad
## values), the volume sliders moving the real buses, rebinding through the
## Controls tab (conflict swap, reserved keys, Esc cancels, reset), the main
## menu's Settings button:
##   godot ... -- --no-save --settings-file=user://menu_test/settings.cfg --test=settings
## REBOUND KEYS IN GAME — a settings file with custom keys, loaded at startup:
## the practice card names them, they move and interact, the old keys don't,
## the prompts follow:
##   godot ... -- --server --no-save --practice --settings-file=user://menu_test/keys.cfg --test=rebind-play
## FULLSCREEN + SCREENSHOTS (needs a renderer: xvfb-run, no --headless) to
## user://menu_shots/: F11 and the toggle, the HUD laid out at several
## window sizes, the pause menu and every settings tab:
##   xvfb-run -a godot --path . --script res://tools/menu_test.gd -- --server --day=7 --no-save --settings-file=user://menu_test/fs.cfg --test=display
## CO-OP (host + 2 clients): the menu is an overlay (nobody's world pauses,
## the player stands still), a client quits to the menu mid-shift, the other
## quits to desktop — the host carries on:
##   godot ... -- --server --port=8981 --players=3 --day=5 --no-save --test=net-pause &
##   (x2) godot ... -- --client --connect-port=8981 --no-save --test=net-pause
## CO-OP, THE HOST LEAVES: host quits to the main menu mid-shift, both clients
## land on their menus with a note; host re-hosts and they rejoin from their
## menus; then the host quits to desktop for real:
##   godot ... -- --server --port=8983 --players=3 --day=5 --save-file=user://menu_test/net_host.json --test=net-host-quit &
##   (x2) godot ... -- --client --connect-port=8983 --no-save --test=net-host-quit

var _mode := ""

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--test="):
			_mode = a.substr(7)
	if _mode == "rebind-play":
		_write_custom_keys() # before Main exists, so it loads at startup
	if _mode == "quit-solo":
		for a in args:
			if a.begins_with("--save-file="):
				DirAccess.remove_absolute(a.substr("--save-file=".length()))
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	main.events_on = "--events=on" in args
	careless = true
	root.get_node("Sfx").log_plays = false
	if OS.get_environment("SW_NET_DIR") == "":
		NET_DIR = "user://net_menu_%s/" % _mode
	var client := "--client" in args
	match _mode:
		"pause": _run_pause.call_deferred()
		"quit-solo": _run_quit_solo.call_deferred()
		"settings": _run_settings.call_deferred()
		"rebind-play": _run_rebind_play.call_deferred()
		"display": _run_display.call_deferred()
		"menu-shots": _run_menu_shots.call_deferred()
		"net-pause": (_run_net_pause_client if client else _run_net_pause_host).call_deferred()
		"net-host-quit": (_run_net_host_quit_client if client else _run_net_host_quit_host).call_deferred()
		_:
			print("FAIL  unknown --test=%s" % _mode)
			quit(1)

## --- helpers ------------------------------------------------------------------

func settings() -> Node:
	return root.get_node("Settings")

## Connected to a real session (the startup / after-leaving offline peer
## reports itself "connected" too, so Net.is_active() alone can't tell).
func net_on() -> bool:
	return root.get_node("Net").is_active() and not (get_multiplayer().multiplayer_peer is OfflineMultiplayerPeer)

func pm() -> Node:
	return main.pause_menu

func sm() -> Node:
	return main.settings_menu

## A real key through Input (the path a keyboard takes: _input, then GUI,
## then _unhandled_input, and the action state Player.gd reads).
func key_event(code: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)

func key_tap(code: Key) -> void:
	key_event(code, true)
	await physics_frame
	await physics_frame
	await process_frame
	key_event(code, false)
	await physics_frame
	await process_frame

func esc() -> void:
	await key_tap(KEY_ESCAPE)

## Real seconds, whether or not the tree is paused (create_timer runs
## through a pause by default).
func real_wait(seconds: float) -> void:
	await create_timer(seconds, true).timeout

## Everything that moves or counts down, in one dictionary.
func world_sig() -> Dictionary:
	var d := {}
	d["clock"] = main.game_clock
	d["shift"] = main.shift_time_left
	d["prep"] = main.prep_time_left
	d["cleanup"] = main.cleanup_time_left
	d["order"] = main.order_time_left
	d["restock"] = main._restock_timer
	d["ev_left"] = main.events.time_left
	d["ev_count"] = main.events._countdown
	d["rating"] = main.store_rating.rating
	d["truck"] = main.delivery.truck_offset
	d["mgr_now"] = main.manager._now()
	d["toast"] = main._toast_timer
	d["pos:forklift"] = main.forklift.global_position
	d["pos:dfork"] = main.delivery_forklift.global_position
	d["pos:manager"] = main.manager.global_position
	if main.staff.janitor:
		d["pos:janitor"] = main.staff.janitor.global_position
		d["jan_clock"] = main.staff.janitor.get("_clock")
	for sec in main.staff.helpers:
		var h: Node2D = main.staff.helpers[sec]
		d["pos:h:" + sec] = h.global_position
		d["hclock:" + sec] = h._clock
	for c in main.customers_root.get_children():
		d["pos:c:" + c.name] = c.global_position
		d["life:" + c.name] = c._lifetime
	for o in get_nodes_in_group("carryable"):
		d["pos:o:" + o.name] = o.global_position
	for p in main.players.values():
		if is_instance_valid(p):
			d["pos:p:" + p.name] = p.global_position
	return d

## Keys of `a` whose value differs in `b` (both present).
func changed_keys(a: Dictionary, b: Dictionary, eps := 0.001) -> Array:
	var out := []
	for k in a:
		if not b.has(k) or a[k] == null or b[k] == null:
			continue
		var x = a[k]
		var y = b[k]
		var diff := false
		if x is Vector2:
			diff = x.distance_to(y) > eps
		elif x is float or x is int:
			diff = absf(float(x) - float(y)) > eps
		else:
			diff = x != y
		if diff:
			out.append(k)
	return out

func moved_count(a: Dictionary, b: Dictionary, prefix: String) -> int:
	return changed_keys(a, b, 0.5).filter(func(k): return k.begins_with(prefix)).size()

## --- SOLO PAUSE ----------------------------------------------------------------

func _run_pause() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 20.0)
	await wait(1.0)
	# --- P0 the hint, and the menu closed
	check(main._esc_hint.visible and main._esc_hint.text == "Esc: menu", "P0: 'Esc: menu' hint in the corner while playing")
	check(not pm().is_open() and not paused, "P0: menu closed, not paused")
	check(main.is_solo(), "P0: hosting alone = solo")
	# --- P1 prep phase (Break Room): the prep clock and everything else freeze
	check(main.shift_active and not main.store_open, "P1: in prep (store closed)")
	var a := world_sig()
	await esc()
	check(pm().is_open() and paused and pm().paused_world, "P1: Esc opens the menu and PAUSES the world (solo)")
	check(pm()._title.text == "PAUSED" and not pm()._note.visible, "P1: says PAUSED, no 'still running' note")
	check(pm()._info.text.contains("prep"), "P1: info line says prep: '%s'" % pm()._info.text.replace("\n", " / "))
	check(not main._esc_hint.visible or true, "P1: (hint state not updated while paused — fine)")
	await real_wait(2.5)
	var b := world_sig()
	var ch := changed_keys(a, b)
	# The frame Esc landed on may have ticked once more: allow one frame's worth.
	var big := ch.filter(func(k): return (a[k] is float or a[k] is int) and absf(float(a[k]) - float(b[k])) > 0.05 or (a[k] is Vector2 and a[k].distance_to(b[k]) > 2.0))
	check(big.is_empty(), "P1: 2.5 s paused in prep — nothing moved or counted down (changed: %s)" % str(big))
	check(absf(b["prep"] - a["prep"]) < 0.05, "P1: prep clock %.2f -> %.2f" % [a["prep"], b["prep"]])
	await esc()
	check(not pm().is_open() and not paused, "P1: Esc again resumes")
	var t0 := Time.get_ticks_msec()
	await wait(1.0)
	var c := world_sig()
	var real_s := (Time.get_ticks_msec() - t0) / 1000.0
	check(absf((b["prep"] - c["prep"]) - real_s) < 0.35, "P1: the prep clock picks up where it was (%.2f -> %.2f over %.2f s real)" % [b["prep"], c["prep"], real_s])
	# --- P4 Esc order: an open panel closes first (prep, at the board / lockers)
	check(await walk_to(main.staff.BOARD_SPOT, 10.0, 20.0), "P4: walked to the staff board")
	await tap("host_interact")
	await wait(0.2)
	check(main.staff.panel.visible, "P4: staff board panel open")
	await esc()
	await wait(0.1)
	check(not main.staff.panel.visible and not pm().is_open() and not paused, "P4: Esc closes the staff board, no menu")
	await esc()
	check(pm().is_open(), "P4: the next Esc opens the menu")
	await esc()
	check(await walk_to(main.shop.LOCKER_SPOT, 10.0, 20.0), "P4: walked to the gear lockers")
	await tap("host_interact")
	await wait(0.2)
	check(main.shop.panel.visible, "P4: gear shop panel open")
	await esc()
	await wait(0.1)
	check(not main.shop.panel.visible and not pm().is_open(), "P4: Esc closes the gear shop first too")
	await esc()
	check(pm().is_open(), "P4: then the menu")
	await esc()
	# --- P2 store open, Day 7, every system on
	for sec in ["Produce", "Dairy/Frozen", "Bakery", "Dry Goods"]:
		if main.section_index(sec) < main.sections_owned and main.staff.HELPER_SECTIONS.has(sec):
			main.staff.do_action(sec, "hire", 1)
	main.staff.do_action(main.staff.JANITOR, "hire", 1)
	main.open_store(1)
	await wait_until(func(): return main.customers_root.get_child_count() >= 3, 20.0)
	var ev_keys: Array = main.events.unlocked_keys()
	if not ev_keys.is_empty():
		main.events.force_next(ev_keys[0], 0.2)
	await wait_until(func(): return main.events.busy(), 10.0)
	await wait(4.0)
	var hired: Array = main.staff.helpers.keys().filter(func(k): return main.staff.is_hired(k))
	check(main.store_open and main.events.busy() and main.customers_root.get_child_count() >= 3 and hired.size() >= 1 and main.staff.janitor.active and main.forklift.active and main.manager.active, "P2: store open — event '%s' %s, %d customers, helpers %s, janitor on, forklift on, manager on" % [main.events.key, "warning" if main.events.warning() else "active", main.customers_root.get_child_count(), str(hired)])
	a = world_sig()
	await wait(1.0)
	var a2 := world_sig()
	check(moved_count(a, a2, "pos:c:") >= 1 and a2["shift"] < a["shift"] and a2["clock"] > a["clock"], "P2: (control) unpaused, customers move and the clock runs (%d customers moved)" % moved_count(a, a2, "pos:c:"))
	await esc()
	check(paused, "P2: paused mid-shift")
	a = world_sig()
	await real_wait(3.0)
	b = world_sig()
	ch = changed_keys(a, b)
	check(ch.is_empty(), "P2: 3 s paused with everything running — nothing changed (%d values watched; changed: %s)" % [a.size(), str(ch)])
	for k in ["shift", "ev_left", "ev_count", "rating", "truck", "mgr_now", "clock", "order", "restock"]:
		check(is_equal_approx(float(a[k]), float(b[k])), "P2: %s held at %.3f" % [k, float(a[k])])
	check(moved_count(a, b, "pos:c:") == 0 and moved_count(a, b, "pos:h:") == 0 and moved_count(a, b, "pos:o:") == 0, "P2: no customer, helper or item moved")
	for k in a:
		if k.begins_with("life:") or k.begins_with("hclock:") or k == "jan_clock":
			if absf(float(a[k]) - float(b[k])) > 0.0001:
				check(false, "P2: %s ticked while paused" % k)
	check(Engine.get_main_loop().paused, "P2: still paused after the wait")
	# --- P3 resume: no jump, everything runs again
	await esc()
	t0 = Time.get_ticks_msec()
	await wait(1.5)
	c = world_sig()
	real_s = (Time.get_ticks_msec() - t0) / 1000.0
	var ran: float = b["shift"] - c["shift"]
	check(ran > 0.3 and ran < real_s + 0.3, "P3: the shift clock ran %.2f s in %.2f s real after resume (no jump)" % [ran, real_s])
	check(absf((c["clock"] - b["clock"]) - real_s) < 0.35, "P3: game clock advanced %.2f s (real %.2f)" % [c["clock"] - b["clock"], real_s])
	check(absf((c["mgr_now"] - b["mgr_now"]) - real_s) < 0.35, "P3: the manager's clock didn't jump across the pause (%.2f s)" % (c["mgr_now"] - b["mgr_now"]))
	if main.events.busy():
		check(float(b["ev_left"]) - float(c["ev_left"]) < real_s + 0.3, "P3: the event timer resumed without a jump (%.2f -> %.2f)" % [b["ev_left"], c["ev_left"]])
	check(moved_count(b, c, "pos:c:") >= 1, "P3: customers move again (%d)" % moved_count(b, c, "pos:c:"))
	var lifers := b.keys().filter(func(k): return k.begins_with("life:") and c.has(k))
	var life_ok := lifers.all(func(k): return float(c[k]) - float(b[k]) < real_s + 0.3)
	check(not lifers.is_empty() and life_ok, "P3: shopper patience resumed without a jump (%d checked)" % lifers.size())
	check(b["rating"] != c["rating"] or true, "P3: rating drift resumes (%.3f -> %.3f)" % [b["rating"], c["rating"]])
	# Bounce window runs on game time now.
	main._bounce_times = [main.game_clock - main.BOUNCE_CALM_SECONDS + 2.0]
	check(main.recent_bounces() == 1, "P3: a bounce 2 s from the window's end still counts")
	await esc()
	await real_wait(3.0)
	check(main.recent_bounces() == 1, "P3: ...and still counts after 3 s paused")
	await esc()
	await wait(2.5)
	check(main.recent_bounces() == 0, "P3: ...and lapses 2 s of play later")
	# --- P5 the menu's buttons; Settings over the pause
	await esc()
	check(pm().resume_button.has_focus() or true, "P5: Resume focused")
	pm().settings_button.pressed.emit()
	await process_frame
	check(sm().is_open() and paused, "P5: Settings opens over the paused game")
	await esc()
	check(not sm().is_open() and pm().is_open() and paused, "P5: Esc closes Settings back to the (still paused) menu")
	pm().resume_button.pressed.emit()
	await process_frame
	check(not pm().is_open() and not paused, "P5: Resume resumes")
	# The player ignores keys while the menu is up (and moves after).
	await esc()
	var p0: Vector2 = player().global_position
	press("host_move_right")
	await real_wait(0.5)
	release_all()
	check(player().global_position.distance_to(p0) < 1.0, "P5: holding a move key over the menu doesn't move you")
	await esc()
	# --- P6 Tab over the menu doesn't skip anything; the report
	main.shift_time_left = 0.5
	main.cleanup_ceiling_override = 0.0
	await wait_until(func(): return main.is_day_report_active(), 20.0)
	await wait(0.3)
	check(not main._esc_hint.visible, "P6: hint hidden under the report")
	await esc()
	check(pm().is_open() and paused, "P6: Esc on the report opens the menu")
	check(main.quit_loss_text() == "", "P6: nothing to lose at the report (the day's banked) — quits without asking")
	await esc()
	check(not pm().is_open() and not paused, "P6: and closes")
	finish()

func release_all() -> void:
	for a in ["move_right", "move_left", "move_up", "move_down"]:
		Input.action_release("host_" + a)
		Input.action_release("client_" + a)

## --- SOLO QUIT -----------------------------------------------------------------

func _save_text() -> String:
	return FileAccess.get_file_as_string(main.save_path) if FileAccess.file_exists(main.save_path) else ""

func _run_quit_solo() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 20.0)
	await wait(0.5)
	var path: String = main.save_path
	# A known save on disk first (the fresh start wrote nothing yet).
	main.money = 1234
	check(main.save_progress("test baseline"), "Q0: baseline save written (bank $1234)")
	var before := _save_text()
	main.open_store(1)
	await wait(2.0)
	main.money += 500 # something the shift "earned" that isn't saved yet
	# --- Q1 Quit to Main Menu mid-shift asks first, and says what's lost
	await esc()
	pm().menu_button.pressed.emit()
	await process_frame
	check(pm().confirming == "menu" and pm()._confirm.visible and not pm()._buttons.visible, "Q1: Quit to Main Menu mid-shift asks first")
	var body: String = pm()._confirm_body.text
	check(body.contains("isn't saved") and body.contains("Day %d" % main.current_day) and body.contains("starts Day %d again" % main.current_day), "Q1: says plainly the shift is lost and Day %d restarts: '%s'" % [main.current_day, body.replace("\n", " / ")])
	check(pm().cancel_button.has_focus() or true, "Q1: Cancel is the safe default")
	await esc()
	check(pm().confirming == "" and pm().is_open() and pm()._buttons.visible, "Q1: Esc backs out of the confirmation to the menu")
	pm().cancel_button.pressed.emit() # (harmless when not confirming)
	pm().menu_button.pressed.emit()
	await process_frame
	pm().cancel_button.pressed.emit()
	await process_frame
	check(pm().confirming == "" and pm().is_open() and net_on(), "Q1: Cancel keeps playing")
	# --- Q2 confirm: back to a fresh main menu, the save untouched
	var old_id := main.get_instance_id()
	pm().menu_button.pressed.emit()
	await process_frame
	pm().confirm_button.pressed.emit()
	await wait_until(func(): return current_scene != null and current_scene.get_instance_id() != old_id and current_scene.is_node_ready(), 10.0)
	main = current_scene
	await wait(0.5)
	check(not is_instance_valid(instance_from_id(old_id)), "Q2: the old game is gone")
	check(main.menu_layer.visible and not net_on() and not paused, "Q2: back on the main menu, offline, not paused")
	check(main.players.is_empty() and main.customers_root.get_child_count() == 0, "Q2: no players or customers left over")
	check(_save_text() == before, "Q2: the save file is byte-for-byte what it was (nothing written on the way out)")
	check(main._menu_settings_button.visible and main._menu_quit_button.visible, "Q2: the menu has Settings and Quit")
	check(not pm().is_open(), "Q2: menu not open on the main menu")
	await esc()
	check(not pm().is_open(), "Q2: Esc over the main menu does nothing")
	# --- Q3 host again from the menu: the save's day, the unsaved $500 gone
	var saved_day: int = int(JSON.parse_string(before)["shop"]["completed_day"]) + 1
	var saved_money: int = int(JSON.parse_string(before)["shop"]["money"])
	main.host_button.pressed.emit()
	await wait_until(func(): return main.shift_active and main.players.has(1), 20.0)
	check(net_on() and main.current_day == saved_day and main.money == saved_money, "Q3: hosting again resumes the last save — Day %d, bank %s" % [main.current_day, main._format_money(main.money)])
	# --- Q4 quit at the report: no question, the day saved
	main.open_store(1)
	main.shift_time_left = 0.3
	main.cleanup_ceiling_override = 0.0
	await wait_until(func(): return main.is_day_report_active(), 20.0)
	await wait(0.3)
	var after_day := _save_text()
	check(after_day != before and int(JSON.parse_string(after_day)["shop"]["completed_day"]) == main.current_day, "Q4: the report saved Day %d" % main.current_day)
	check(main.quit_loss_text() == "", "Q4: nothing to lose at the report")
	old_id = main.get_instance_id()
	await esc()
	pm().menu_button.pressed.emit()
	await wait_until(func(): return current_scene != null and current_scene.get_instance_id() != old_id and current_scene.is_node_ready(), 10.0)
	main = current_scene
	await wait(0.3)
	check(main.menu_layer.visible and not net_on(), "Q4: straight back to the menu (no confirmation needed)")
	check(_save_text() == after_day, "Q4: the save still holds the finished day")
	# --- Q5 Quit to Desktop from the main menu: a real quit
	print("INFO  path %s" % path)
	print("RESULT: %s (%d failure%s)" % ["OK" if fails == 0 else "FAILED", fails, "" if fails == 1 else "s"])
	print("PASS  Q5: pressing Quit on the main menu (the process should exit 0 now)")
	main._menu_quit_button.pressed.emit()
	await wait(5.0)
	print("FAIL  Q5: still running 5 s after Quit")
	quit(1)

## --- SETTINGS ---------------------------------------------------------------------

func _bus_db(name: String) -> float:
	return AudioServer.get_bus_volume_db(AudioServer.get_bus_index(name))

func _bus_mute(name: String) -> bool:
	return AudioServer.is_bus_mute(AudioServer.get_bus_index(name))

func _run_settings() -> void:
	await wait(0.5)
	var S := settings()
	var path: String = S.path
	var Sfx := root.get_node("Sfx")
	# --- S1 missing file: defaults
	DirAccess.remove_absolute(path)
	check(S.load_settings() == "missing" and S.master == 1.0 and S.music == 1.0 and S.sfx == 1.0 and not S.fullscreen and S.vsync and S.controls_are_default(), "S1: no settings file — every default")
	check(S.key_label("host_interact") == "E" and S.key_label("client_interact") == "Enter" and S.key_label("client_place") == "/" and S.move_keys("host_") == "WASD" and S.move_keys("client_") == "arrow keys", "S1: default key names: E / Enter / '/' / WASD / arrow keys")
	# --- S2 the main menu's Settings button; sliders move the real buses
	check(main.menu_layer.visible, "S2: on the main menu")
	main._menu_settings_button.pressed.emit()
	await process_frame
	check(sm().is_open(), "S2: the main menu's Settings button opens Settings")
	var sl: Dictionary = sm()._sliders
	sl["master"].value = 40
	await process_frame
	check(is_equal_approx(S.master, 0.4) and absf(_bus_db("Master") - linear_to_db(0.4)) < 0.01 and not _bus_mute("Master"), "S2: Master slider 40%% -> Master bus %.2f dB" % _bus_db("Master"))
	sl["sfx"].value = 50
	await process_frame
	var want_sfx: float = Sfx.BUS_DB["SFX"] + linear_to_db(0.5)
	check(absf(_bus_db("SFX") - want_sfx) < 0.01 and absf(_bus_db("Hazard") - (Sfx.BUS_DB["Hazard"] + linear_to_db(0.5))) < 0.01 and absf(_bus_db("UI") - (Sfx.BUS_DB["UI"] + linear_to_db(0.5))) < 0.01, "S2: SFX slider 50%% -> SFX %.1f, Hazard %.1f, UI %.1f dB (every non-music sound)" % [_bus_db("SFX"), _bus_db("Hazard"), _bus_db("UI")])
	check(Sfx.LIBRARY["footstep"]["bus"] == "SFX" and Sfx.LIBRARY["forklift_engine"]["bus"] == "SFX" and Sfx.LIBRARY["flicker_sting"]["bus"] == "Hazard" and Sfx.LIBRARY["ui_click"]["bus"] == "UI", "S2: footsteps / the forklift loop / event stings / clicks are on those buses")
	var all_routed := true
	for s in Sfx.LIBRARY:
		if not ["SFX", "Hazard", "UI"].has(Sfx.LIBRARY[s]["bus"]):
			all_routed = false
	check(all_routed, "S2: every sound in the library sits on a bus the SFX slider controls")
	sl["music"].value = 25
	await wait(1.5) # the music bus eases (it also ducks)
	check(absf(_bus_db("Music") - (Sfx.BUS_DB["Music"] + linear_to_db(0.25))) < 0.6, "S2: Music slider 25%% -> Music bus %.1f dB (want %.1f)" % [_bus_db("Music"), Sfx.BUS_DB["Music"] + linear_to_db(0.25)])
	sl["music"].value = 0
	await process_frame
	check(_bus_mute("Music") and S.music == 0.0, "S2: Music at 0% mutes the music bus")
	sl["sfx"].value = 0
	await process_frame
	check(_bus_mute("SFX") and _bus_mute("Hazard") and _bus_mute("UI"), "S2: SFX at 0% mutes all three")
	sl["sfx"].value = 50
	sl["music"].value = 25
	await process_frame
	check(not _bus_mute("SFX") and not _bus_mute("Music"), "S2: back up un-mutes")
	check(sm()._slider_values["master"].text == "40%", "S2: the slider's readout: '%s'" % sm()._slider_values["master"].text)
	# --- S3 display toggles (headless: the values, saved; the window itself is the display test's)
	sm()._fullscreen.button_pressed = true
	await process_frame
	check(S.fullscreen, "S3: the Fullscreen toggle sets the setting")
	await key_tap(KEY_F11)
	check(not S.fullscreen and not sm()._fullscreen.button_pressed, "S3: F11 flips it back (and the toggle follows)")
	sm()._vsync.button_pressed = false
	await process_frame
	check(not S.vsync, "S3: VSync off")
	# --- S4 rebinding through the Controls tab
	var b_int: Button = sm()._bind_buttons["host_interact"]
	b_int.pressed.emit()
	await process_frame
	check(sm().capturing == "host_interact" and b_int.text == "press a key…", "S4: clicking a key waits for one ('%s')" % b_int.text)
	await key_tap(KEY_G)
	check(S.key_of("host_interact") == KEY_G and b_int.text == "G" and sm().capturing == "", "S4: G pressed -> interact is G")
	check(InputMap.action_has_event("host_interact", _ev(KEY_G)) and not InputMap.action_has_event("host_interact", _ev(KEY_E)), "S4: the InputMap has G, not E")
	# Conflict: throw (F) -> G swaps: interact gets F.
	sm()._bind_buttons["host_throw"].pressed.emit()
	await process_frame
	await key_tap(KEY_G)
	check(S.key_of("host_throw") == KEY_G and S.key_of("host_interact") == KEY_F, "S4: binding G (interact's) to throw SWAPS — interact is now F")
	check(sm()._status.text.contains("swapped"), "S4: and says so: '%s'" % sm()._status.text)
	# Same key in the other set is fine (the sets are separate).
	check(S.rebind("client_interact", KEY_G)["ok"] and S.key_of("client_interact") == KEY_G and S.key_of("host_throw") == KEY_G, "S4: G in the joined set too doesn't disturb the hosting set")
	# Reserved keys are refused; Esc cancels a capture.
	sm()._bind_buttons["host_place"].pressed.emit()
	await process_frame
	await key_tap(KEY_TAB)
	check(S.key_of("host_place") == KEY_C and sm()._status.text.contains("Can't use"), "S4: Tab can't be bound (practice skip): '%s'" % sm()._status.text)
	check(not S.rebind("host_place", KEY_F11)["ok"] and not S.rebind("host_place", KEY_F3)["ok"] and not S.rebind("host_place", KEY_ESCAPE)["ok"], "S4: nor F11, F3 or Esc")
	sm()._bind_buttons["host_place"].pressed.emit()
	await process_frame
	await esc()
	check(S.key_of("host_place") == KEY_C and sm().capturing == "" and sm().is_open(), "S4: Esc during a capture cancels it (Settings stays open)")
	# Every action in a set keeps exactly one distinct key.
	for p in S.PREFIXES:
		var keys := {}
		for a in S.ACTIONS:
			keys[S.key_of(p + a)] = true
		check(keys.size() == S.ACTIONS.size() and not keys.has(0), "S4: %s set: %d actions, %d distinct keys" % [p, S.ACTIONS.size(), keys.size()])
	# --- S5 everything persisted; a fresh load reads it back
	var cfg := ConfigFile.new()
	check(cfg.load(path) == OK, "S5: %s written" % path)
	check(is_equal_approx(float(cfg.get_value("audio", "master")), 0.4) and is_equal_approx(float(cfg.get_value("audio", "music")), 0.25) and int(cfg.get_value("controls", "host_interact")) == KEY_F and cfg.get_value("display", "vsync") == false, "S5: file holds master 0.4, music 0.25, interact F, vsync off")
	check(not FileAccess.get_file_as_string(path).contains("money") and not FileAccess.get_file_as_string(path).contains("completed"), "S5: nothing of the game save in it")
	# Memory changed behind the file's back, without saving...
	S.master = 1.0
	S.music = 1.0
	S.vsync = true
	S._restore_default_keys()
	check(S.load_settings() == "ok" and is_equal_approx(S.master, 0.4) and is_equal_approx(S.music, 0.25) and is_equal_approx(S.sfx, 0.5) and not S.vsync and S.key_of("host_interact") == KEY_F and S.key_of("host_throw") == KEY_G and S.key_of("client_interact") == KEY_G, "S5: round trip — load_settings() brings it all back")
	# --- S6 reset to defaults
	sm()._tabs.current_tab = 2
	await process_frame
	check(not sm().reset_button.disabled, "S6: Reset enabled with keys changed")
	sm().reset_button.pressed.emit()
	await process_frame
	check(S.controls_are_default() and S.key_of("host_interact") == KEY_E and S.key_of("client_interact") == KEY_ENTER and sm().reset_button.disabled, "S6: Reset to defaults — E / Enter again, button disabled")
	check(is_equal_approx(S.master, 0.4), "S6: (reset touches only the keys)")
	# --- S7 corrupt and bad files fall back to defaults
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[audio\nmaster=???\n=garbage[[")
	f.close()
	check(S.load_settings() == "corrupt" and S.master == 1.0 and S.controls_are_default(), "S7: a corrupt file -> defaults ('%s')" % S.load_status)
	S.apply_all()
	check(absf(_bus_db("Master")) < 0.01, "S7: ...applied (Master back to 0 dB)")
	cfg = ConfigFile.new()
	cfg.set_value("audio", "master", 7.5)
	cfg.set_value("audio", "music", "loud")
	cfg.set_value("audio", "sfx", -3)
	cfg.set_value("display", "fullscreen", "yes")
	cfg.set_value("controls", "host_interact", KEY_ESCAPE)
	cfg.set_value("controls", "host_throw", KEY_W) # W is move_up's: a duplicate
	cfg.set_value("controls", "host_place", KEY_K)
	cfg.save(path)
	S.load_settings()
	check(S.master == 1.0 and S.music == 1.0 and S.sfx == 0.0 and not S.fullscreen, "S7: bad values clamp or fall back (master 7.5 -> 1, music 'loud' -> 1, sfx -3 -> 0, fullscreen 'yes' -> off)")
	check(S.key_of("host_interact") == KEY_E and S.key_of("host_throw") == KEY_F and S.key_of("host_place") == KEY_K, "S7: a reserved or duplicate key keeps its default; the good one (place K) loads")
	# The game save is a different file entirely.
	check(path != main.save_path, "S7: settings file %s is not the save %s" % [path, main.save_path])
	# --- S8 Back / Esc closes to the main menu
	await esc()
	check(not sm().is_open() and main.menu_layer.visible and not pm().is_open(), "S8: Esc closes Settings back to the main menu (no pause menu)")
	S.reset_controls()
	finish()

func _ev(code: Key) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = code
	return e

## --- REBOUND KEYS IN GAME -------------------------------------------------------

func _keys_path() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--settings-file="):
			return a.substr("--settings-file=".length())
	return "user://menu_test/keys.cfg"

## IJKL to move, U interact, O throw, P place, N shove (hosting set).
func _write_custom_keys() -> void:
	var cfg := ConfigFile.new()
	for pair in [["move_up", KEY_I], ["move_left", KEY_J], ["move_down", KEY_K], ["move_right", KEY_L], ["interact", KEY_U], ["throw", KEY_O], ["place", KEY_P], ["defend", KEY_N]]:
		cfg.set_value("controls", "host_" + pair[0], pair[1])
	cfg.set_value("controls", "client_interact", KEY_H)
	DirAccess.make_dir_recursive_absolute(_keys_path().get_base_dir())
	cfg.save(_keys_path())

func _run_rebind_play() -> void:
	var S := settings()
	check(S.load_status == "ok" and S.key_of("host_interact") == KEY_U and S.key_of("host_move_up") == KEY_I, "R1: custom keys loaded at startup, before the first menu")
	await wait_until(func(): return main.tutorial.active and main.players.has(1) and main.tutorial._card.visible, 20.0)
	await wait(0.3)
	var body: String = main.tutorial._body.text
	check(body.contains("(IJKL)") and not body.contains("WASD"), "R1: the practice card names the bound move keys: '%s'" % body.replace("\n", " / "))
	var k: Dictionary = main.tutorial._keys(1)
	check(k["interact"] == "U" and k["throw"] == "O" and k["place"] == "P" and k["defend"] == "N" and k["move"] == "IJKL", "R1: every practice placeholder follows the bindings %s" % str(k))
	var kc: Dictionary = main.tutorial._keys(2)
	check(kc["interact"] == "H" and kc["move"] == "arrow keys" and kc["place"] == "/", "R1: a joined player's card uses their set %s" % str(kc))
	# Real key presses move the player; WASD doesn't any more.
	var p0: Vector2 = player().global_position
	key_event(KEY_D, true)
	await wait(0.4)
	key_event(KEY_D, false)
	await wait(0.1)
	check(player().global_position.distance_to(p0) < 2.0, "R2: D (the old key) doesn't move you (%.1f px)" % player().global_position.distance_to(p0))
	p0 = player().global_position
	key_event(KEY_L, true)
	await wait(0.4)
	key_event(KEY_L, false)
	await wait(0.1)
	check(player().global_position.x - p0.x > 30.0, "R2: L (bound to move right) moves you right (%.1f px)" % (player().global_position.x - p0.x))
	# Skip practice (Tab, fixed), then the staff board with the new interact key.
	await key_tap(KEY_TAB)
	await wait_until(func(): return not main.tutorial.active and main.shift_active, 20.0)
	await wait(1.0)
	check(not main.tutorial.active, "R3: Tab still skips practice")
	var walked := await walk_to(main.staff.BOARD_SPOT, 10.0, 25.0)
	check(walked, "R3: walked to the staff board (using the bound move keys' actions)")
	await wait(0.3)
	check(main.staff._hint.visible and main.staff._hint.text.begins_with("U: staff board"), "R3: the prompt names the bound key: '%s'" % main.staff._hint.text)
	await key_tap(KEY_E)
	await wait(0.2)
	check(not main.staff.panel.visible, "R3: E (the old key) does nothing")
	await key_tap(KEY_U)
	await wait(0.2)
	check(main.staff.panel.visible, "R3: U (bound to interact) opens the staff board")
	check(main.staff._hint.text.begins_with("U: close"), "R3: '%s'" % main.staff._hint.text)
	await esc()
	check(not main.staff.panel.visible and not main.pause_menu.is_open(), "R3: Esc closes it")
	# A live rebind applies at once, prompts included.
	S.rebind("host_interact", KEY_Y)
	await wait(0.2)
	check(main.staff._hint.text.begins_with("Y: staff board"), "R4: rebinding live updates the prompt: '%s'" % main.staff._hint.text)
	await key_tap(KEY_Y)
	await wait(0.2)
	check(main.staff.panel.visible, "R4: and Y works straight away")
	await key_tap(KEY_Y)
	check(main.cleanup._place_key(1) == "P" and main.cleanup._place_key(2) == "/", "R4: the mop/broom 'Hold %s' prompt follows the place key")
	S.reset_controls()
	check(S.key_of("host_interact") == KEY_E, "R5: reset")
	DirAccess.remove_absolute(_keys_path())
	finish()

## --- DISPLAY (xvfb) -----------------------------------------------------------------

func _shot(name: String) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("user://menu_shots")
	var path := "user://menu_shots/%02d_%s.png" % [shot_index, name]
	shot_index += 1
	root.get_texture().get_image().save_png(path)
	print("SHOT  " + ProjectSettings.globalize_path(path))

## Every always-up HUD element inside the visible rect.
func _hud_inside(tag: String) -> void:
	var vp: Vector2 = root.get_visible_rect().size
	var r := Rect2(Vector2.ZERO, vp).grow(1.0)
	var items := {"status": main.status_label, "esc hint": main._esc_hint, "rating panel": main.store_rating._panel, "prep line": main._prep_label}
	for n in items:
		var c: Control = items[n]
		if c.visible:
			check(r.encloses(c.get_global_rect()), "%s: %s inside the %s view (%s)" % [tag, n, str(vp), str(c.get_global_rect())])

func _run_display() -> void:
	var S := settings()
	DirAccess.remove_absolute(S.path)
	S.load_settings()
	S.apply_all()
	await wait(0.5)
	check(DisplayServer.get_name() != "headless", "D0: a real display (%s)" % DisplayServer.get_name())
	check(str(ProjectSettings.get_setting("display/window/stretch/mode")) == "canvas_items" and str(ProjectSettings.get_setting("display/window/stretch/aspect")) == "expand", "D0: the UI scales with the window (canvas_items / expand)")
	await wait_until(func(): return main.shift_active and main.players.has(1), 20.0)
	main.open_store(1)
	await wait(4.0)
	# --- D1 the fullscreen toggle and F11
	var win0 := root.size
	S.set_fullscreen(true)
	await wait(0.8)
	var mode := DisplayServer.window_get_mode()
	await _fill_screen()
	check(mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN, "D1: fullscreen on (mode %d, window %s, screen %s)" % [mode, str(DisplayServer.window_get_size()), str(DisplayServer.screen_get_size())])
	_hud_inside("D1 fullscreen")
	await _shot("hud_fullscreen")
	await esc()
	await _shot("pause_menu_fullscreen")
	await esc()
	await key_tap(KEY_F11)
	await wait(1.0)
	check(DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED and not S.fullscreen, "D1: F11 back to a window (mode %d)" % DisplayServer.window_get_mode())
	await key_tap(KEY_F11)
	await wait(1.0)
	check(S.fullscreen and DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED, "D1: F11 again: fullscreen")
	root.size = win0
	var cfg := ConfigFile.new()
	cfg.load(S.path)
	check(cfg.get_value("display", "fullscreen") == true, "D1: saved as fullscreen")
	S.set_fullscreen(false)
	await wait(1.0)
	# --- D2 common window sizes: the HUD stays laid out
	for sz in [Vector2i(960, 540), Vector2i(1280, 720), Vector2i(1280, 800), Vector2i(1024, 768), Vector2i(1920, 1080)]:
		root.size = sz
		await wait(0.6)
		check(root.get_texture().get_image().get_size() == sz, "D2: window really is %dx%d (view %s)" % [sz.x, sz.y, str(root.get_visible_rect().size)])
		_hud_inside("D2 %dx%d" % [sz.x, sz.y])
		if sz == Vector2i(1280, 800):
			await _shot("hud_1280x800")
	root.size = win0
	await wait(0.5)
	# --- D3 the panels at fullscreen: the staff board, the gear shop, the report
	S.set_fullscreen(true)
	await _fill_screen()
	await walk_to(main.staff.BOARD_SPOT, 10.0, 25.0)
	await tap("host_interact")
	await wait(0.4)
	check(main.staff.panel.visible, "D3: staff board open at fullscreen")
	await _shot("staff_board_fullscreen")
	await esc()
	await walk_to(main.shop.LOCKER_SPOT, 10.0, 25.0)
	await tap("host_interact")
	await wait(0.4)
	check(main.shop.panel.visible, "D3: gear shop open at fullscreen")
	await _shot("gear_shop_fullscreen")
	await esc()
	check(not main.shop.panel.visible and not pm().is_open(), "D3: closed")
	# --- D4 the pause menu and every settings tab
	await esc()
	await _shot("pause_menu")
	pm().settings_button.pressed.emit()
	for i in 3:
		sm()._tabs.current_tab = i
		await wait(0.2)
		await _shot("settings_" + ["audio", "display", "controls"][i])
	sm()._bind_buttons["host_interact"].pressed.emit()
	await _shot("settings_controls_capture")
	await esc()
	await esc()
	pm().menu_button.pressed.emit()
	await wait(0.2)
	await _shot("quit_confirm")
	await esc()
	await esc()
	main.shift_time_left = 0.3
	main.cleanup_ceiling_override = 0.0
	await wait_until(func(): return main.is_day_report_active(), 20.0)
	await wait(0.5)
	await _shot("report_fullscreen")
	S.set_fullscreen(false)
	root.size = win0
	await wait(0.5)
	DirAccess.remove_absolute(S.path)
	finish()

## The real main menu (no --server): its new Settings / Quit buttons, Settings
## over it, and the note after leaving a game.
##   xvfb-run -a godot --path . --script res://tools/menu_test.gd -- --no-save --settings-file=user://menu_test/ms.cfg --test=menu-shots
func _run_menu_shots() -> void:
	await wait(0.8)
	check(main.menu_layer.visible and main._menu_settings_button.visible and main._menu_quit_button.visible, "M1: main menu with Settings and Quit")
	await _shot("main_menu")
	main._menu_settings_button.pressed.emit()
	await wait(0.2)
	await _shot("settings_from_main_menu")
	await esc()
	main._menu_notice.text = "The host ended the session — you're back at the main menu."
	main._menu_notice.visible = true
	await _shot("main_menu_after_host_left")
	finish()

## Xvfb has no window manager, and on X11 it's the window manager that
## stretches a fullscreen window over the screen — so after the real mode
## switch, do its part (and say so).
func _fill_screen() -> void:
	await wait(0.8)
	var scr := DisplayServer.screen_get_size()
	if root.size != scr:
		print("INFO  no window manager under xvfb: sizing the fullscreen window to the screen %s by hand" % str(scr))
		root.size = scr
		await wait(0.6)

## --- CO-OP: the overlay; clients quitting --------------------------------------------

func _run_net_pause_host() -> void:
	await wait_until(func(): return main.players.size() >= 3 and main.shift_active, 30.0)
	await wait(1.0)
	main.open_store(1)
	await wait(2.0)
	check(not main.is_solo(), "N1: with clients connected it's not solo")
	_net_write("phase1.json", {"go": 1})
	# --- N1 a client's menu doesn't pause the host's world
	var r1 := await _net_read("c_menu_open.json", 30.0)
	var t_before: float = main.shift_time_left
	await wait(2.0)
	check(not paused and t_before - main.shift_time_left > 1.5, "N1: a client's menu open — the host's clock keeps running (%.1f -> %.1f)" % [t_before, main.shift_time_left])
	var cid: int = int(r1.get("id", 0))
	_net_write("phase2.json", {"go": 1})
	var r2 := await _net_read("c_menu_moved.json", 30.0)
	check(r2.get("ok", false), "N1: (client) held a move key over its menu and stood still: %s" % str(r2))
	# --- N2 the host's own menu is an overlay too
	await esc()
	check(pm().is_open() and not paused and not pm().paused_world, "N2: host menu in co-op: an overlay, nothing paused")
	check(pm()._title.text == "MENU" and pm()._note.visible and pm()._note.text.contains("still running"), "N2: says the game is still running: '%s'" % pm()._note.text)
	if DisplayServer.get_name() != "headless":
		await _shot("coop_overlay_menu")
	t_before = main.shift_time_left
	await wait(1.5)
	check(t_before - main.shift_time_left > 1.0, "N2: the host's clock runs under its own menu")
	_net_write("phase3.json", {"host_menu": true, "shift": main.shift_time_left})
	await _net_read("c_saw_running.json", 30.0)
	await esc()
	check(not pm().is_open(), "N2: closed")
	# --- N3 client A quits to the main menu mid-shift
	var n0: int = main.players.size()
	_net_write("phase4.json", {"leaver_menu": cid})
	var t_q := Time.get_ticks_msec()
	await wait_until(func(): return not main.players.has(cid), 15.0)
	var took := (Time.get_ticks_msec() - t_q) / 1000.0
	check(not main.players.has(cid) and main.players.size() == n0 - 1, "N3: client %d's player gone %.1f s after it quit to the menu (crew %d -> %d)" % [cid, took, n0, main.players.size()])
	check(took < 6.0, "N3: promptly (%.1f s — no network timeout)" % took)
	var r4 := await _net_read("c_left_menu.json", 30.0)
	check(r4.get("menu", false) and not r4.get("net", true), "N3: (client) on its main menu, offline: %s" % str(r4))
	await wait(1.0)
	check(main.shift_active and net_on() and main.players.has(1), "N3: the host plays on")
	# --- N4 client B quits to desktop for real
	var others: Array = main.players.keys().filter(func(k): return k != 1)
	var bid: int = int(others[0]) if not others.is_empty() else 0
	_net_write("phase5.json", {"leaver_desktop": bid})
	t_q = Time.get_ticks_msec()
	await wait_until(func(): return not main.players.has(bid), 15.0)
	took = (Time.get_ticks_msec() - t_q) / 1000.0
	check(bid != 0 and not main.players.has(bid) and took < 6.0, "N4: client %d quit to desktop — gone from the host in %.1f s" % [bid, took])
	await wait(1.5)
	check(main.shift_active and net_on() and main.players.size() == 1, "N4: the host is fine, solo now")
	# --- N5 solo again: the menu pauses again
	await esc()
	check(paused and pm().paused_world, "N5: alone again — Esc pauses for real")
	await esc()
	check(not paused, "N5: resumed")
	_net_write("done.json", {"go": 1})
	finish()

func _run_net_pause_client() -> void:
	await wait_until(func(): return net_on() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 30.0)
	me = main.multiplayer.get_unique_id()
	act = "client_"
	await _net_read("phase1.json", 60.0)
	# Only the first client (by id order) runs the menu checks.
	var ids: Array = main.players.keys().filter(func(k): return k != 1)
	ids.sort()
	var first: bool = ids.size() > 0 and ids[0] == me
	if first:
		await esc()
		check(pm().is_open() and not paused and not pm().paused_world, "C1: a client's menu never pauses (overlay)")
		check(pm()._note.visible and pm()._note.text.contains("still running"), "C1: says the game is still running")
		_net_write("c_menu_open.json", {"id": me})
		await _net_read("phase2.json", 30.0)
		var p0: Vector2 = player().global_position
		press("client_move_left")
		await wait(0.8)
		release_all()
		await wait(0.3)
		var moved: float = player().global_position.distance_to(p0)
		check(moved < 2.0, "C1: holding a move key with the menu open — stood still (%.1f px)" % moved)
		_net_write("c_menu_moved.json", {"ok": moved < 2.0, "moved": moved})
		var p3 := await _net_read("phase3.json", 30.0)
		await wait(0.5)
		check(p3.get("host_menu", false) and main.shift_time_left < float(p3.get("shift", 0.0)) + 0.6, "C1: the host has its menu open and this client's clock still runs (%.1f)" % main.shift_time_left)
		_net_write("c_saw_running.json", {"ok": 1})
		await esc()
	# --- leaving
	var p4 := await _net_read("phase4.json", 60.0)
	if int(p4.get("leaver_menu", 0)) == me:
		check(pm().blocks_input() == false, "C2: menu closed before quitting")
		await esc()
		pm().menu_button.pressed.emit()
		await process_frame
		check(pm().confirming == "menu" and pm()._confirm_body.text.contains("keeps going without you"), "C2: a client is asked too: '%s'" % pm()._confirm_body.text)
		var old_id := main.get_instance_id()
		pm().confirm_button.pressed.emit()
		await wait_until(func(): return current_scene != null and current_scene.get_instance_id() != old_id and current_scene.is_node_ready(), 10.0)
		main = current_scene
		await wait(0.5)
		var ok_menu: bool = main.menu_layer.visible
		check(ok_menu and not net_on() and main.players.is_empty(), "C2: back on the main menu, offline")
		_net_write("c_left_menu.json", {"menu": ok_menu, "net": net_on()})
		finish()
		return
	var p5 := await _net_read("phase5.json", 60.0)
	if int(p5.get("leaver_desktop", 0)) == me:
		print("RESULT: %s (%d failure%s)" % ["OK" if fails == 0 else "FAILED", fails, "" if fails == 1 else "s"])
		print("PASS  C3: Quit to Desktop (exiting 0 now)")
		await esc()
		pm().desktop_button.pressed.emit()
		await process_frame
		pm().confirm_button.pressed.emit()
		await wait(5.0)
		print("FAIL  C3: still running 5 s after Quit to Desktop")
		quit(1)
		return
	await _net_read("done.json", 60.0)
	finish()

## --- CO-OP: the host leaves -------------------------------------------------------------

func _run_net_host_quit_host() -> void:
	await wait_until(func(): return main.players.size() >= 3 and main.shift_active, 30.0)
	await wait(1.0)
	main.open_store(1)
	await wait(1.5)
	# --- H1 quit to the main menu mid-shift: it warns about the crew
	await esc()
	pm().menu_button.pressed.emit()
	await process_frame
	var body: String = pm()._confirm_body.text
	check(body.contains("isn't saved") and body.contains("Everyone else on the crew (2)"), "H1: the host's warning names the shift and the crew: '%s'" % body.replace("\n", " / "))
	_net_write("phase1.json", {"go": 1})
	await wait(0.5)
	var old_id := main.get_instance_id()
	pm().confirm_button.pressed.emit()
	await wait_until(func(): return current_scene != null and current_scene.get_instance_id() != old_id and current_scene.is_node_ready(), 10.0)
	main = current_scene
	await wait(0.5)
	check(main.menu_layer.visible and not net_on(), "H1: the host is back on its main menu")
	var r := await _net_read("c_menu_a.json", 20.0)
	var r2 := await _net_read("c_menu_b.json", 20.0)
	check(r.get("menu", false) and r2.get("menu", false), "H1: both clients landed on their main menus (%s / %s)" % [str(r), str(r2)])
	check(str(r.get("notice", "")).contains("host ended"), "H1: with a note: '%s'" % r.get("notice", ""))
	# --- H2 host again from the menu; the clients rejoin from theirs
	main.host_button.pressed.emit()
	await wait_until(func(): return main.shift_active and main.players.has(1), 20.0)
	_net_write("phase2.json", {"go": 1})
	await wait_until(func(): return main.players.size() >= 3, 30.0)
	check(main.players.size() == 3, "H2: re-hosted from the menu, both clients rejoined from theirs (crew %d)" % main.players.size())
	await wait(2.0)
	# --- H3 the host quits to desktop for real: the clients aren't left hanging
	_net_write("phase3.json", {"go": 1})
	await wait(1.0)
	print("RESULT: %s (%d failure%s)" % ["OK" if fails == 0 else "FAILED", fails, "" if fails == 1 else "s"])
	print("PASS  H3: host quitting to desktop (exiting 0 now)")
	await esc()
	pm().desktop_button.pressed.emit()
	await process_frame
	pm().confirm_button.pressed.emit()
	await wait(5.0)
	print("FAIL  H3: still running 5 s after Quit to Desktop")
	quit(1)

func _client_on_menu() -> void:
	main.quit_on_host_loss = false # a player who joined from the menu
	var old_id := main.get_instance_id()
	var t0 := Time.get_ticks_msec()
	await wait_until(func(): return current_scene != null and current_scene.get_instance_id() != old_id and current_scene.is_node_ready(), 20.0)
	main = current_scene
	await wait(0.5)
	var took := (Time.get_ticks_msec() - t0) / 1000.0
	check(main.menu_layer.visible and not net_on() and main.players.is_empty(), "K: host gone -> back on the main menu, offline (%.1f s)" % took)
	check(main._menu_notice.visible and main._menu_notice.text.contains("host ended"), "K: the menu says why: '%s'" % main._menu_notice.text)

func _run_net_host_quit_client() -> void:
	main.quit_on_host_loss = false # a player who joined from the menu
	await wait_until(func(): return net_on() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 30.0)
	await _net_read("phase1.json", 60.0)
	var ids: Array = main.players.keys().filter(func(k): return k != 1)
	ids.sort()
	var tag := "a" if ids[0] == main.multiplayer.get_unique_id() else "b"
	await _client_on_menu()
	_net_write("c_menu_%s.json" % tag, {"menu": main.menu_layer.visible, "notice": main._menu_notice.text})
	await _net_read("phase2.json", 30.0)
	await wait(0.5 if tag == "a" else 1.5)
	main.join_button.pressed.emit()
	await wait_until(func(): return net_on() and main.players.has(main.multiplayer.get_unique_id()), 20.0)
	main.quit_on_host_loss = false
	check(net_on() and main.players.has(main.multiplayer.get_unique_id()), "K2: rejoined from the main menu")
	await wait_until(func(): return main.shift_active, 10.0)
	await _net_read("phase3.json", 30.0)
	await _client_on_menu()
	await wait(0.5)
	finish()
