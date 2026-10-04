extends SceneTree
## The corner HUD (DebugLayer): the small always-up StatusLabel and the dev
## DebugLabel dump that's hidden until F3. Loads the real Main.tscn and drives
## the real game code. Not part of the game.
##
## Story, solo (Day N on the line, F3, the day rolling over):
##   godot --headless --path . --script res://tools/hud_test.gd -- --server --day=1 --no-save --test=hud
## Endless (Shift #N and the wallet on the line, no "Day"/"Week"):
##   godot --headless --path . --script res://tools/hud_test.gd -- --server --day=7 --no-save --test=hud-endless
## Main menu (no --server: nothing in the corner over the menu):
##   godot --headless --path . --script res://tools/hud_test.gd -- --no-save --test=hud-menu
## Co-op (3 peers): every peer's player count right, F3 local to its peer,
## the count dropping when someone leaves:
##   godot --headless --path . --script res://tools/hud_test.gd -- --server --day=3 --no-save --players=3 --test=net-hud &
##   (x2) godot --headless --path . --script res://tools/hud_test.gd -- --client --no-save --test=net-hud
## Screenshots (needs a renderer — xvfb-run, no --headless) to user://hud_shots/:
##   xvfb-run -a godot --path . --script res://tools/hud_test.gd -- --server --day=7 --no-save --test=hud-shots

var main: Node
var fails := 0
var NET_DIR: String = OS.get_environment("SW_NET_DIR") if OS.get_environment("SW_NET_DIR") != "" else "user://net_hud/"

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	# OCT 2026 PHASE 2: written for the 7-day story — Day N -> N+1 hands the
	# crew old Day N+1's sections/earnings (Main.gd's test_follow_old_calendar),
	# and Day 7's report still finishes the week into Endless Mode (the debug
	# --endless route) for the endless checks.
	main.test_follow_old_calendar = true
	main.legacy_endless_route = true
	root.get_node("Sfx").log_plays = false
	var mode := "hud"
	for a in args:
		if a.begins_with("--test="):
			mode = a.substr(7)
	match mode:
		"hud":
			_run_story.call_deferred()
		"hud-endless":
			_run_endless.call_deferred()
		"hud-menu":
			_run_menu.call_deferred()
		"hud-shots":
			_run_shots.call_deferred()
		"net-hud":
			if "--client" in args:
				_run_net_client.call_deferred()
			else:
				_run_net_host.call_deferred()

## --- helpers ---------------------------------------------------------------------

func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1

func finish() -> void:
	print("RESULT: %s (%d failure%s)" % ["OK" if fails == 0 else "FAILED", fails, "" if fails == 1 else "s"])
	quit(1 if fails else 0)

func wait(seconds: float) -> void:
	await create_timer(seconds).timeout

func wait_until(cond: Callable, timeout: float) -> bool:
	var t := 0.0
	while t < timeout:
		if cond.call():
			return true
		await physics_frame
		t += 1.0 / 60.0
	return cond.call()

func frames(n: int) -> void:
	for i in n:
		await process_frame

## A real F3 key event through the viewport, the same path a keyboard takes.
func key(code: Key, pressed := true, echo := false) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = pressed
	ev.echo = echo
	root.push_input(ev)
	await frames(2)

func tap_f3() -> void:
	await key(KEY_F3, true)
	await key(KEY_F3, false)

func status() -> Label:
	return main.status_label

func dbg() -> Label:
	return main.debug_label

func _common_checks(tag: String) -> void:
	check(status().visible, "%s: status line up" % tag)
	check(not dbg().visible, "%s: debug dump hidden by default" % tag)
	check(status().get_parent() is CanvasLayer and dbg().get_parent() == status().get_parent(), "%s: both on DebugLayer (screen-space)" % tag)
	var r := status().get_global_rect()
	var vp := Vector2(ProjectSettings.get_setting("display/window/size/viewport_width"), ProjectSettings.get_setting("display/window/size/viewport_height"))
	check(r.position.x >= 0.0 and r.position.y >= 0.0 and r.end.x < vp.x * 0.5 and r.size.y < 40.0, "%s: status line a small corner box %s (viewport %s)" % [tag, str(r), str(vp)])
	for other in [main._prep_label, main._finale_banner]:
		if other.visible:
			check(not r.intersects(_text_rect(other)), "%s: status line clear of %s's text (%s vs %s)" % [tag, other.name, str(r), str(_text_rect(other))])
	check(not status().text.contains("peer") and not status().text.contains("HOST") and not status().text.contains("("), "%s: no dev text on the status line ('%s')" % [tag, status().text])

## Where a full-width centered label's text actually is (its rect is the
## whole screen width, so the rect alone always "overlaps" the corner).
func _text_rect(c: Control) -> Rect2:
	var l: Label = c if c is Label else c.get_child(0)
	var w: float = l.get_theme_font("font").get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, l.get_theme_font_size("font_size")).x
	var g := l.get_global_rect()
	return Rect2(g.get_center().x - w * 0.5, g.position.y, w, g.size.y)

func _f3_checks(tag: String) -> void:
	var dump_before: String = dbg().text
	await tap_f3()
	check(dbg().visible, "%s: F3 shows the debug dump" % tag)
	check(dbg().text.begins_with("peer id: ") and (dbg().text.contains("(HOST)") or dbg().text.contains("(CLIENT)")), "%s: dump is the full one ('%s')" % [tag, dbg().text.get_slice("\n", 0)])
	check(status().visible, "%s: status line stays up with the dump open" % tag)
	check(not status().get_global_rect().intersects(dbg().get_global_rect()), "%s: dump sits below the status line, no overlap (%s vs %s)" % [tag, str(status().get_global_rect()), str(dbg().get_global_rect())])
	await key(KEY_F3, true, true)
	check(dbg().visible, "%s: a key-repeat (echo) F3 doesn't flip it back" % tag)
	await key(KEY_F3, false)
	check(dbg().visible, "%s: releasing F3 doesn't flip it" % tag)
	await tap_f3()
	check(not dbg().visible, "%s: F3 again hides it" % tag)
	await key(KEY_F2)
	await key(KEY_F4)
	check(not dbg().visible, "%s: other F-keys do nothing" % tag)
	check(dump_before != "", "%s: dump text still built while hidden" % tag)

func _end_day() -> void:
	main.shift_time_left = 0.01
	await wait_until(func(): return main.cleanup_active, 3.0)
	main.clock_out(1)
	await wait_until(func(): return main.is_day_report_active(), 5.0)
	await wait(0.3)

## --- story -----------------------------------------------------------------------

func _run_story() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 15.0)
	root.size = Vector2i(960, 540)
	await frames(3)
	_common_checks("S1")
	check(status().text == "Day %d  ·  Bank %s  ·  1 player" % [main.current_day, main._format_money(main.money)], "S1: story line reads '%s'" % status().text)
	await _f3_checks("S2")
	var day0: int = main.current_day
	await _end_day()
	check(status().text == "Day %d  ·  Bank %s  ·  1 player" % [day0, main._format_money(main.money)], "S3: still Day %d on the report ('%s')" % [day0, status().text])
	main._on_continue_pressed()
	await wait_until(func(): return main.current_day == day0 + 1 and main.shift_active, 8.0)
	await frames(2)
	check(status().text == "Day %d  ·  Bank %s  ·  1 player" % [day0 + 1, main._format_money(main.money)], "S3: rolls over live to '%s'" % status().text)
	check(status().visible and not dbg().visible, "S3: next day — status up, dump still hidden")
	main.status_hud = false
	await frames(2)
	check(not status().visible, "S4: status_hud = false (screenshot tools) keeps it off across frames")
	main.status_hud = true
	await frames(2)
	check(status().visible, "S4: and back on")
	finish()

## --- endless ---------------------------------------------------------------------

func _run_endless() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 15.0)
	root.size = Vector2i(960, 540)
	await frames(3)
	check(status().text == "Day 7  ·  Bank %s  ·  1 player" % main._format_money(main.money), "E0: Day 7 before the week ends ('%s')" % status().text)
	await _end_day()
	main._on_continue_pressed()
	await wait_until(func(): return main.endless.screen == main.endless.SCREEN_WEEK_COMPLETE, 5.0)
	main.enter_hub()
	await wait(0.5)
	check(main.is_endless(), "E1: in endless mode")
	var want := "Endless  ·  Break Room  ·  %d Bucks  ·  1 player" % main.endless.wallet
	check(status().text == want, "E1: hub reads '%s'" % status().text)
	main.take_offer(0)
	await wait_until(func(): return main.shift_active, 5.0)
	await frames(3)
	_common_checks("E2")
	check(status().text.begins_with("Endless  ·  Shift #%d  ·  " % main.endless.shift_number) and main.endless.shift_number == 1, "E2: shift #1 on the line ('%s')" % status().text)
	check(not status().text.contains("Week") and not status().text.contains("Day"), "E2: no 'Day'/'Week' in endless ('%s')" % status().text)
	main.endless.wallet += 37
	await frames(2)
	check(status().text.contains("%d Bucks" % main.endless.wallet), "E3: wallet updates live ('%s')" % status().text)
	await _f3_checks("E4")
	check(dbg().text.contains("endless shift #1"), "E4: dump has the endless line too")
	await _end_day()
	main._on_continue_pressed()
	await wait_until(func(): return main.endless.screen == main.endless.SCREEN_HUB, 5.0)
	await frames(2)
	check(status().text == "Endless  ·  Break Room  ·  %d Bucks  ·  1 player" % main.endless.wallet, "E5: back in the hub after shift #1, payout in the wallet ('%s')" % status().text)
	finish()

## --- menu ------------------------------------------------------------------------

func _run_menu() -> void:
	await wait(1.5)
	check(main.menu_layer.visible, "M1: main menu up")
	check(not status().visible, "M1: nothing in the corner over the menu ('%s')" % status().text)
	check(not dbg().visible, "M1: debug dump hidden over the menu")
	finish()

## --- co-op -----------------------------------------------------------------------

func _run_net_host() -> void:
	var want := 3
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--players="):
			want = int(a.substr(10))
	DirAccess.make_dir_recursive_absolute(NET_DIR)
	for f in DirAccess.get_files_at(NET_DIR):
		DirAccess.remove_absolute(NET_DIR + f)
	await wait_until(func(): return main.shift_active and main.players.size() >= want, 40.0)
	await wait(1.5)
	var line := "Day %d  ·  Bank %s  ·  %d players" % [main.current_day, main._format_money(main.money), want]
	check(status().text == line, "N1 host: '%s'" % status().text)
	check(not dbg().visible, "N1 host: dump hidden")
	_net_write("phase1.json", {"line": line})
	var ids: Array = main.players.keys().filter(func(id): return id != 1)
	ids.sort()
	for id in ids:
		var r := await _net_read("c%d_p1.json" % id, 20.0)
		check(r.get("text", "") == line, "N1 client %d: '%s'" % [id, r.get("text", "(no report)")])
		check(r.get("visible", false) and not r.get("dbg", true), "N1 client %d: status up, dump hidden" % id)
	# F3 on the host only.
	await tap_f3()
	check(dbg().visible and dbg().text.contains("(HOST)"), "N2 host: F3 opened the host's own dump")
	_net_write("phase2.json", {"host_dbg": true})
	for id in ids:
		var r := await _net_read("c%d_p2.json" % id, 20.0)
		check(not r.get("dbg", true), "N2 client %d: host's F3 didn't open its dump" % id)
	# F3 on the first client only.
	_net_write("phase3.json", {"who": ids[0]})
	var r3 := await _net_read("c%d_p3.json" % ids[0], 20.0)
	check(r3.get("dbg", false) and r3.get("dump", "").contains("(CLIENT)"), "N3 client %d: its own F3 opened its own dump ('%s')" % [ids[0], r3.get("dump", "")])
	await wait(0.5)
	check(dbg().visible, "N3 host: dump unchanged by the client's F3")
	for id in ids.slice(1):
		var r := await _net_read("c%d_p3.json" % id, 20.0)
		check(not r.get("dbg", true), "N3 client %d: unaffected by client %d's F3" % [id, ids[0]])
	# The last client leaves; everyone left should drop to want-1.
	var leaver: int = ids[-1]
	_net_write("phase4.json", {"leave": leaver})
	await wait_until(func(): return main.players.size() == want - 1, 15.0)
	await frames(3)
	var line2 := "Day %d  ·  Bank %s  ·  %d player%s" % [main.current_day, main._format_money(main.money), want - 1, "" if want - 1 == 1 else "s"]
	check(status().text == line2, "N4 host: after %d left, '%s'" % [leaver, status().text])
	_net_write("phase5.json", {"line": line2})
	for id in ids:
		if id == leaver:
			continue
		var r := await _net_read("c%d_p5.json" % id, 20.0)
		check(r.get("text", "") == line2, "N4 client %d: after %d left, '%s'" % [id, leaver, r.get("text", "(no report)")])
	_net_write("done.json", {"go": true})
	await wait(1.0)
	finish()

func _run_net_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 20.0)
	var me: int = main.multiplayer.get_unique_id()
	var p1 := await _net_read("phase1.json", 60.0)
	await wait_until(func(): return status().text == p1.get("line", ""), 5.0)
	_net_write("c%d_p1.json" % me, {"text": status().text, "visible": status().visible, "dbg": dbg().visible})
	await _net_read("phase2.json", 30.0)
	await wait(0.5)
	_net_write("c%d_p2.json" % me, {"dbg": dbg().visible})
	var p3 := await _net_read("phase3.json", 30.0)
	if int(p3.get("who", 0)) == me:
		await tap_f3()
	else:
		await wait(1.0)
	_net_write("c%d_p3.json" % me, {"dbg": dbg().visible, "dump": dbg().text.get_slice("\n", 0)})
	var p4 := await _net_read("phase4.json", 30.0)
	if int(p4.get("leave", 0)) == me:
		print("INFO  client %d leaving" % me)
		quit(0)
		return
	var p5 := await _net_read("phase5.json", 30.0)
	await wait_until(func(): return status().text == p5.get("line", ""), 5.0)
	_net_write("c%d_p5.json" % me, {"text": status().text})
	await _net_read("done.json", 30.0)
	print("INFO  client %d: '%s'" % [me, status().text])
	quit(0)

func _net_peek(file: String) -> Dictionary:
	if not FileAccess.file_exists(NET_DIR + file):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(NET_DIR + file))
	return parsed if parsed is Dictionary else {}

func _net_write(file: String, data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(NET_DIR)
	var f := FileAccess.open(NET_DIR + file + ".tmp", FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()
	DirAccess.rename_absolute(NET_DIR + file + ".tmp", NET_DIR + file)

func _net_read(file: String, timeout: float) -> Dictionary:
	var t := 0.0
	while t < timeout:
		var d := _net_peek(file)
		if not d.is_empty():
			return d
		await create_timer(0.25).timeout
		t += 0.25
	return {}

## --- screenshots -----------------------------------------------------------------

func _shot(name: String) -> void:
	await frames(4)
	DirAccess.make_dir_recursive_absolute("user://hud_shots")
	var path := "user://hud_shots/%s.png" % name
	root.get_texture().get_image().save_png(path)
	print("SHOT  " + ProjectSettings.globalize_path(path))

func _run_shots() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 15.0)
	root.size = Vector2i(960, 540)
	await wait(0.4)
	await _shot("1_shift_start_banner")
	await wait(3.5)
	await _shot("2_prep_quiet")
	await tap_f3()
	await _shot("3_f3_dump")
	await tap_f3()
	# A crowded moment: store open, a priority order, a write-up toast, the
	# manager watching, lights flickering.
	main.open_store(1)
	await wait(6.0)
	main._issue_priority_order()
	main.show_toast("WRITTEN UP — Host (throwing stock)", main.TOAST_RED, 6.0)
	if main.ambience.has_method("start_lights_event"):
		main.ambience.start_lights_event()
	await wait(0.8)
	await _shot("4_busy")
	await tap_f3()
	await _shot("5_busy_f3")
	finish()
