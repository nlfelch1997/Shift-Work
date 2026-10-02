extends SceneTree
## WEEK 24 — SAVE / LOAD (SaveGame.gd, Main.gd's save_progress()/
## _load_progress()), tested for real: every "relaunch" is a brand-new Godot
## process reading the file the previous one wrote. tools/run_save_tests.sh
## runs the whole sequence; each phase alone:
##
##   Solo — play the story, quit mid-day, relaunch, finish the week, quit on
##   Day 7's report, relaunch into WEEK COMPLETE, earn + spend Bucks, quit,
##   relaunch into the hub (SAVE = --save-file=user://save_test/save.json):
##     godot --headless --path . --script res://tools/save_test.gd -- --server SAVE --test=save --phase=1   (2, 3, 4)
##   Damaged / missing files, and debug starts never touching the real save:
##     godot --headless --path . --script res://tools/save_test.gd -- --server SAVE --test=save --phase=5
##     godot --headless --path . --script res://tools/save_test.gd -- --server --day=3 --test=save --phase=6
##   Co-op — the host has a save (and so does the client, a different one);
##   the client must see the HOST's progress, buy/take a shift/press Save
##   through the host, and its own file must never change:
##     godot --headless --path . --script res://tools/save_test.gd -- --server --save-file=user://save_test/host.json --test=net-save &
##     godot --headless --path . --script res://tools/save_test.gd -- --client --save-file=user://save_test/client.json --test=net-save
##   (--test=net-save-story: the same, with a mid-story save: Day 5, Week Total)
##
## Sales are injected on the host (a cashier's replicated total_sold), and a
## shift is ended by running its clock out — the save/load paths, the report,
## the hub's real buttons and the payouts all run through the game's own code.

## Loaded at run time, not preloaded: SaveGame.gd reaches Endless.gd ->
## BreakRoom.gd, which names the Net autoload — not registered yet while a
## --script SceneTree is being compiled.
var SaveGameScript: GDScript
const DIR := "user://save_test/"
const SOLO := DIR + "save.json"
const EXPECT := DIR + "expect.json"
const HOST_SAVE := DIR + "host.json"
const CLIENT_SAVE := DIR + "client.json"
var NET_DIR: String = OS.get_environment("SW_NET_DIR") if OS.get_environment("SW_NET_DIR") != "" else "user://net_save/"

var main: Node
var fails := 0
var me := 1
var act := "host_"
var mode := "save"
var phase := 1

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--test="):
			mode = a.substr(7)
		elif a.begins_with("--phase="):
			phase = int(a.substr(8))
	SaveGameScript = load("res://SaveGame.gd")
	DirAccess.make_dir_recursive_absolute(DIR)
	# Whatever must be on disk BEFORE the game reads it (it loads as hosting
	# begins, inside _ready()).
	match mode:
		"save":
			if phase == 1:
				for f in [SOLO, SOLO + ".tmp", SOLO + ".bad", EXPECT]:
					DirAccess.remove_absolute(f)
			elif phase == 5:
				_write_text(SOLO, "{ this is not json ]] garbage")
				DirAccess.remove_absolute(SOLO + ".bad")
		"net-save", "net-save-story":
			if "--client" in OS.get_cmdline_user_args():
				_write_text(CLIENT_SAVE, JSON.stringify(CLIENT_FILE, "\t"))
			else:
				if DirAccess.dir_exists_absolute(NET_DIR):
					for f in DirAccess.get_files_at(NET_DIR):
						DirAccess.remove_absolute(NET_DIR + f)
				_write_text(HOST_SAVE, JSON.stringify(HOST_ENDLESS_FILE if mode == "net-save" else HOST_STORY_FILE, "\t"))
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	main.cleanup_ceiling_override = 0.0 # the report the moment the clock runs out
	match mode:
		"save":
			match phase:
				1: _phase1.call_deferred()
				2: _phase2.call_deferred()
				3: _phase3.call_deferred()
				4: _phase4.call_deferred()
				5: _phase5.call_deferred()
				6: _phase6.call_deferred()
		"net-save", "net-save-story":
			if "--client" in OS.get_cmdline_user_args():
				_run_client.call_deferred()
			else:
				_run_host.call_deferred()

## --- Plumbing ---------------------------------------------------------------

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

func en() -> Node:
	return main.endless

func player() -> Node2D:
	return main.players[me]

func _write_text(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()

func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))

## The save on disk, through the game's own reader.
func disk(path := SOLO) -> Dictionary:
	var r: Array = SaveGameScript.read(path)
	return r[1] if r[0] == SaveGameScript.LOAD_OK else {}

func _canon(v) -> String:
	return JSON.stringify(JSON.parse_string(JSON.stringify(v)), "", true)

func add_sales(n: int) -> void:
	main.cashiers[0].get_node("Cashier").total_sold += n

func end_shift_now() -> void:
	main.shift_time_left = 0.05
	await wait_until(func(): return main.is_day_report_active() and not main.shift_active, 10.0)
	await wait(0.3)

func wait_shift() -> bool:
	var ok := await wait_until(func(): return main.shift_active and main.players.has(1), 20.0)
	await wait(0.3)
	return ok

func press(b: Button, what: String) -> void:
	check(b != null and b.visible and not b.disabled, "%s: button is there and enabled" % what)
	if b:
		b.pressed.emit()

## Walk right across open floor for `frames` physics frames; px/s. Owner only.
func measure_speed(frames := 30) -> float:
	var p := player()
	p.teleport_to(Vector2(420.0, 250.0))
	await physics_frame
	await physics_frame
	Input.action_press(act + "move_right")
	for i in 4:
		await physics_frame
	var x0: float = p.global_position.x
	for i in frames:
		await physics_frame
	var dx: float = p.global_position.x - x0
	Input.action_release(act + "move_right")
	await physics_frame
	return dx / (frames / float(Engine.physics_ticks_per_second))

## The progress this peer can see — host and client must agree on all of it.
func view() -> Dictionary:
	return {
		"day": main.current_day, "screen": en().screen, "wallet": en().wallet,
		"upgrades": en().upgrades, "run": en().run_stats, "shift": en().shift_number,
		"week_summary": en().week_summary, "week_sold": main._total_sold(),
		"writeups_week": main.writeups_week, "pay_week": main._pay_week(),
		"speed_mult": en().speed_mult(), "carry": en().carry_capacity(), "badge": en().has_badge(),
	}

## =============================================================================
## SOLO
## =============================================================================

## Fresh install: Day 1 -> Day 2 -> quit partway through Day 3.
func _phase1() -> void:
	check(main.load_status == SaveGameScript.LOAD_NONE and main.save_enabled, "P1: no save file -> a fresh start (status %d), saving on" % main.load_status)
	check(await wait_shift(), "P1: Day 1's shift starts")
	check(main.current_day == 1 and en().wallet == 0 and en().upgrades.is_empty(), "P1: Day 1, empty wallet, no upgrades")
	check(not FileAccess.file_exists(SOLO), "P1: nothing saved before a day is done")
	add_sales(5)
	main.record_writeup(1, "testing")
	await end_shift_now()
	var d := disk()
	check(not d.is_empty() and d["story"]["completed_day"] == 1 and not d["story"]["complete"], "P1: Day 1's report autosaved: completed day 1 (%s)" % str(d.get("story")))
	check(d.get("week", {}).get("sold") == 5 and d["week"]["writeups"] == 1, "P1: the week so far is in it: sold 5, 1 write-up (%s)" % str(d.get("week")))
	main._on_continue_pressed()
	check(await wait_shift() and main.current_day == 2, "P1: Continue -> Day 2")
	add_sales(7)
	await end_shift_now()
	d = disk()
	check(d["story"]["completed_day"] == 2 and d["week"]["sold"] == 12, "P1: Day 2 autosaved: completed 2, week sold 12 (%s)" % str(d.get("week")))
	main._on_continue_pressed()
	check(await wait_shift() and main.current_day == 3, "P1: Continue -> Day 3")
	add_sales(4) # mid-day progress: must NOT survive the quit
	await wait(0.5)
	d = disk()
	check(d["story"]["completed_day"] == 2 and d["week"]["sold"] == 12, "P1: Day 3 in progress isn't saved (file still says completed 2, sold 12)")
	print("P1: quitting partway through Day 3 (4 sold that day)")
	finish()

## Relaunch: back at the start of Day 3 with Days 1-2 counted; play to Day 7's
## report, press Save there, quit without finishing the week.
func _phase2() -> void:
	check(main.load_status == SaveGameScript.LOAD_OK, "P2: the save loaded (status %d)" % main.load_status)
	check(await wait_shift(), "P2: a shift starts")
	check(main.current_day == 3 and main.completed_story_day == 2, "P2: resumes at Day 3 — the day after the last completed one (day %d)" % main.current_day)
	check(main._total_sold() == 12 and main._sold_at_day_start == 12 and main.writeups_week == 1, "P2: week totals restored: sold %d (want 12, Day 3's 4 lost), write-ups %d" % [main._total_sold(), main.writeups_week])
	check(main.multiplayer.is_server() and not en().screen, "P2: story play, no hub")
	add_sales(3)
	await end_shift_now()
	check(main.report_layer.visible and main.report_week_label.text == "Week Total: 15" and main.report_today_label.text == "Sold Today: 3", "P2: Day 3's report: '%s' / '%s'" % [main.report_today_label.text, main.report_week_label.text])
	check(disk()["story"]["completed_day"] == 3, "P2: Day 3 autosaved")
	for day in [4, 5, 6, 7]:
		main._on_continue_pressed()
		check(await wait_shift() and main.current_day == day, "P2: Day %d" % day)
		add_sales(2)
		await end_shift_now()
		check(disk()["story"]["completed_day"] == day and disk()["week"]["sold"] == 15 + 2 * (day - 3), "P2: Day %d autosaved (week sold %d)" % [day, disk()["week"]["sold"]])
	check(main.continue_button.text == "Finish the Week", "P2: Day 7's report says Finish the Week")
	check(main.save_button.text == "Save" and main.save_button.visible, "P2: the Save button is a real 'Save' now ('%s')" % main.save_button.text)
	var before: int = main.saves_written
	DirAccess.remove_absolute(SOLO) # prove the button writes it
	main.save_button.pressed.emit()
	await wait(0.1)
	check(main.saves_written == before + 1 and FileAccess.file_exists(SOLO), "P2: Save button wrote the file (saves %d -> %d)" % [before, main.saves_written])
	check(main.save_button.text == "Saved ✓", "P2: and says so ('%s')" % main.save_button.text)
	var d := disk()
	check(d["story"]["completed_day"] == 7 and not d["story"]["complete"] and d["endless"]["wallet"] == 0, "P2: saved on Day 7's report: completed 7, week not finished, no Bucks yet")
	await wait(2.7)
	check(main.save_button.text == "Save", "P2: the button reads 'Save' again after a moment")
	print("P2: quitting on Day 7's report, before Finish the Week")
	finish()

## Relaunch: straight to WEEK COMPLETE (paid once), the hub, an endless shift,
## a purchase, quit.
func _phase3() -> void:
	check(main.load_status == SaveGameScript.LOAD_OK, "P3: loaded")
	check(await wait_until(func(): return en().screen == en().SCREEN_WEEK_COMPLETE and main.hub_ui.visible, 5.0), "P3: a Day 7 save that never finished the week opens on WEEK COMPLETE")
	check(not main.shift_active and main.current_day == 7, "P3: no shift runs under it, Day 7")
	check(en().wallet == 40 and main.story_complete, "P3: the week's 40 Bucks paid (wallet %d), story complete" % en().wallet)
	check(int(en().week_summary.get("sold", -1)) == 23 and int(en().week_summary.get("writeups", -1)) == 1, "P3: WEEK COMPLETE counts the WHOLE week across both relaunches: sold %s (want 23), write-ups %s" % [str(en().week_summary.get("sold")), str(en().week_summary.get("writeups"))])
	var d := disk()
	check(d["story"]["complete"] and d["endless"]["wallet"] == 40, "P3: autosaved at WEEK COMPLETE (complete, wallet 40)")
	await wait(0.3)
	press(main.hub_ui.enter_button, "P3: WEEK COMPLETE's enter-the-hub")
	check(await wait_until(func(): return en().screen == en().SCREEN_HUB and main.current_day == 8, 3.0), "P3: the hub (Day parks at 8)")
	await wait(0.3)
	press(main.hub_ui.offer_buttons[0], "P3: the first posting")
	check(await wait_shift() and en().shift_number == 1, "P3: endless shift #1 runs")
	add_sales(30)
	await end_shift_now()
	var paid := int(en().last_payout.get("total", -1))
	check(paid > 0 and en().wallet == 40 + paid, "P3: shift paid %d Bucks (wallet %d)" % [paid, en().wallet])
	d = disk()
	check(d["endless"]["wallet"] == en().wallet and d["endless"]["run_stats"]["shifts"] == 1 and d["endless"]["shift_number"] == 1, "P3: autosaved at the payout (wallet %d, 1 shift)" % d["endless"]["wallet"])
	main._on_continue_pressed()
	check(await wait_until(func(): return en().screen == en().SCREEN_HUB, 3.0), "P3: back to the break room")
	await wait(0.3)
	var w0: int = en().wallet
	press(main.hub_ui.buy_buttons["shoes"], "P3: buy Comfy Sneakers")
	await wait(0.2)
	check(en().upgrade_level("shoes") == 1 and en().wallet == w0 - 20, "P3: Sneakers level 1, wallet %d -> %d" % [w0, en().wallet])
	d = disk()
	check(d["endless"]["upgrades"].get("shoes") == 1 and d["endless"]["wallet"] == en().wallet, "P3: the purchase autosaved at once (%s, wallet %d)" % [str(d["endless"]["upgrades"]), d["endless"]["wallet"]])
	await wait(0.3)
	if en().wallet >= 15:
		press(main.hub_ui.buy_buttons["boots"], "P3: buy Steel-Toe Boots")
		await wait(0.2)
	var expect := {"wallet": en().wallet, "upgrades": en().upgrades, "run": en().run_stats, "shift": en().shift_number}
	check(_canon(disk()["endless"]["upgrades"]) == _canon(en().upgrades) and disk()["endless"]["wallet"] == en().wallet, "P3: file == live after every purchase (%s, wallet %d)" % [str(en().upgrades), en().wallet])
	_write_text(EXPECT, JSON.stringify(expect))
	print("P3: quitting in the hub — expecting %s" % str(expect))
	finish()

## Relaunch: straight into the hub, exactly what was there; the upgrade really
## works; Shift #2 continues the count.
func _phase4() -> void:
	var expect: Dictionary = _read_json(EXPECT)
	check(main.load_status == SaveGameScript.LOAD_OK, "P4: loaded")
	check(await wait_until(func(): return en().screen == en().SCREEN_HUB and main.hub_ui.visible, 5.0), "P4: a finished story opens straight into the hub")
	check(main.current_day == 8 and not main.shift_active and en().offers.size() == 3, "P4: endless (day 8), no shift running, a fresh board of 3")
	check(en().wallet == int(expect["wallet"]), "P4: wallet %d == %d" % [en().wallet, int(expect["wallet"])])
	check(_canon(en().upgrades) == _canon(expect["upgrades"]), "P4: upgrades %s == %s" % [str(en().upgrades), str(expect["upgrades"])])
	check(_canon(en().run_stats) == _canon(expect["run"]) and en().shift_number == int(expect["shift"]), "P4: run totals %s, shift counter %d" % [str(en().run_stats), en().shift_number])
	check(int(en().week_summary.get("sold", -1)) == 23, "P4: the week's results kept (sold %s)" % str(en().week_summary.get("sold")))
	await wait(0.3)
	press(main.hub_ui.offer_buttons[2], "P4: the hard posting")
	check(await wait_shift() and en().shift_number == int(expect["shift"]) + 1, "P4: Shift #%d (the count continues)" % en().shift_number)
	var S: float = player().SPEED
	var v := await measure_speed()
	check(absf(v - S * en().speed_mult()) < S * 0.03 and en().speed_mult() > 1.0, "P4: the loaded Sneakers really work: %.0f px/s = %.0f x %.2f" % [v, S, en().speed_mult()])
	add_sales(20)
	await end_shift_now()
	check(main.report_title_label.text == "Shift #%d Complete" % en().shift_number, "P4: report '%s'" % main.report_title_label.text)
	check(disk()["endless"]["wallet"] == en().wallet and disk()["endless"]["run_stats"]["shifts"] == int(expect["run"]["shifts"]) + 1, "P4: autosaved (wallet %d)" % en().wallet)
	finish()

## Damaged files: never a crash, never a soft-lock — a fresh week.
func _phase5() -> void:
	check(main.load_status == SaveGameScript.LOAD_CORRUPT, "P5: a garbage file is reported damaged (status %d)" % main.load_status)
	check(FileAccess.file_exists(SOLO + ".bad") and FileAccess.get_file_as_string(SOLO + ".bad").begins_with("{ this is not json"), "P5: the damaged file was copied aside to .bad")
	check(await wait_shift(), "P5: the game still starts a shift (no soft-lock)")
	check(main.current_day == 1 and en().wallet == 0 and en().upgrades.is_empty() and not main.story_complete, "P5: a fresh start: Day 1, no Bucks, no upgrades")
	add_sales(3)
	await end_shift_now()
	var d := disk()
	check(not d.is_empty() and d["story"]["completed_day"] == 1, "P5: the next checkpoint writes a good save over it")
	# --- SaveGame.read on every kind of bad file.
	var t := DIR + "unit.json"
	var cases := {
		"empty file": "",
		"whitespace": "   \n",
		"truncated": '{"version": 1, "story": {"completed_',
		"a JSON array": "[1, 2, 3]",
		"a JSON string": '"hello"',
		"binary junk": "\u0001\u0002ÿþ",
		"no version": '{"story": {"completed_day": 3}}',
		"a newer version": '{"version": 99, "story": {"completed_day": 3}}',
		"a version string": '{"version": "1", "story": {"completed_day": 3}}',
	}
	for name in cases:
		_write_text(t, cases[name])
		var r: Array = SaveGameScript.read(t)
		check(r[0] == SaveGameScript.LOAD_CORRUPT and r[1].is_empty(), "P5: %s -> damaged, nothing loaded" % name)
	DirAccess.remove_absolute(t)
	check(SaveGameScript.read(t)[0] == SaveGameScript.LOAD_NONE, "P5: a missing file -> 'no save'")
	# Readable but wrong inside: loaded, every value made sane.
	_write_text(t, JSON.stringify({"version": 1,
		"story": {"completed_day": 42, "complete": "yes"},
		"week": {"sold": -5, "writeups": "lots", "coffee_cups": 2.7},
		"endless": {"wallet": 1e30, "upgrades": {"shoes": 99, "brace": -1, "soles": 1.9, "hax": 5}, "shift_number": "x",
			"run_stats": {"shifts": 3, "medals": [1, "a", 2]}, "week_summary": {"sold": 9, "pay": -40, "evil": {}}}}))
	var r: Array = SaveGameScript.read(t)
	var s: Dictionary = r[1]
	check(r[0] == SaveGameScript.LOAD_OK, "P5: a well-formed file with bad values still loads")
	check(s["story"]["completed_day"] == 7 and s["story"]["complete"] == false, "P5: day 42 -> 7, 'yes' isn't true (%s)" % str(s["story"]))
	check(s["week"]["sold"] == 0 and s["week"]["writeups"] == 0 and s["week"]["coffee_cups"] == 2, "P5: negative/strings -> 0, 2.7 -> 2 (%s)" % str(s["week"]))
	check(s["endless"]["wallet"] == 1000000000 and s["endless"]["shift_number"] == 0, "P5: a huge wallet is capped, a string counter is 0")
	check(_canon(s["endless"]["upgrades"]) == _canon({"shoes": 3, "soles": 1}), "P5: upgrades clamped to their max, unknown keys dropped (%s)" % str(s["endless"]["upgrades"]))
	check(_canon(s["endless"]["run_stats"]["medals"]) == _canon([1, 0, 2, 0]) and _canon(s["endless"]["week_summary"]) == _canon({"sold": 9, "pay": -40}), "P5: medals and week summary cleaned (%s, %s)" % [str(s["endless"]["run_stats"]), str(s["endless"]["week_summary"])])
	# A save into a folder that doesn't exist yet.
	var deep := DIR + "deep/er/save.json"
	DirAccess.remove_absolute(deep)
	check(SaveGameScript.write(deep, SaveGameScript.snapshot(main)) and SaveGameScript.read(deep)[0] == SaveGameScript.LOAD_OK, "P5: saving into a folder that doesn't exist yet makes it")
	check(not FileAccess.file_exists(SOLO + ".tmp"), "P5: no .tmp left behind")
	finish()

## Launched with --day=3 and no --save-file: a debug start. It must neither
## load nor write the player's real save.
func _phase6() -> void:
	var real: String = SaveGameScript.DEFAULT_PATH
	var existed := FileAccess.file_exists(real)
	var before := FileAccess.get_file_as_string(real) if existed else ""
	check(not main.save_enabled and main.load_status == -1, "P6: --day=3: saving off, nothing loaded")
	check(await wait_shift() and main.current_day == 3, "P6: starts on Day 3 as asked")
	add_sales(2)
	await end_shift_now()
	main.save_button.pressed.emit()
	await wait(0.1)
	check(main.save_button.text == "Saving is off" and main.saves_written == 0, "P6: Save says '%s', nothing written" % main.save_button.text)
	check(FileAccess.file_exists(real) == existed and (not existed or FileAccess.get_file_as_string(real) == before), "P6: the real save (%s) untouched" % real)
	finish()

## =============================================================================
## CO-OP
## =============================================================================

## The host's save: a finished story, a run in progress.
const HOST_ENDLESS_FILE := {"version": 1,
	"story": {"completed_day": 7, "complete": true},
	"week": {"sold": 0, "writeups": 0, "priority_sales": 0, "clean_bonus": 0, "coffee_cups": 0},
	"endless": {"wallet": 137, "upgrades": {"shoes": 2, "brace": 1, "badge": 1}, "shift_number": 4,
		"run_stats": {"shifts": 4, "sold": 88, "bucks": 210, "medals": [1, 1, 1, 1]},
		"week_summary": {"sold": 140, "pay": 1700, "writeups": 3, "priority_sales": 10, "clean_bonus": 90}}}
## The host's save: mid-story, Days 1-4 done.
const HOST_STORY_FILE := {"version": 1,
	"story": {"completed_day": 4, "complete": false},
	"week": {"sold": 30, "writeups": 2, "priority_sales": 0, "clean_bonus": 12, "coffee_cups": 1},
	"endless": {"wallet": 0, "upgrades": {}, "shift_number": 0, "run_stats": {"shifts": 0, "sold": 0, "bucks": 0, "medals": [0, 0, 0, 0]}, "week_summary": {}}}
## The client's OWN save — different from the host's in every way. It must be
## ignored in the host's session, and never overwritten.
const CLIENT_FILE := {"version": 1,
	"story": {"completed_day": 2, "complete": false},
	"week": {"sold": 9, "writeups": 0, "priority_sales": 0, "clean_bonus": 0, "coffee_cups": 0},
	"endless": {"wallet": 999, "upgrades": {"janitor": 2}, "shift_number": 0, "run_stats": {}, "week_summary": {}}}

var _step_n := 0

func _step(kind: String, data := {}) -> void:
	_step_n += 1
	var d := data.duplicate()
	d["kind"] = kind
	DirAccess.make_dir_recursive_absolute(NET_DIR)
	_write_text(NET_DIR + "st_%d.json.tmp" % _step_n, JSON.stringify(d))
	DirAccess.rename_absolute(NET_DIR + "st_%d.json.tmp" % _step_n, NET_DIR + "st_%d.json" % _step_n)

func _await_file(path: String, timeout: float) -> Dictionary:
	var t := 0.0
	while t < timeout:
		var v = _read_json(path)
		if v is Dictionary:
			return v
		await create_timer(0.25).timeout
		t += 0.25
	return {}

func _answer(n: int, data: Dictionary) -> void:
	_write_text(NET_DIR + "an_%d.json.tmp" % n, JSON.stringify(data))
	DirAccess.rename_absolute(NET_DIR + "an_%d.json.tmp" % n, NET_DIR + "an_%d.json" % n)

func _client_answer() -> Dictionary:
	var a := await _await_file(NET_DIR + "an_%d.json" % _step_n, 60.0)
	check(not a.is_empty(), "host: the client answered step %d" % _step_n)
	if a.has("fails"):
		fails += int(a["fails"])
	return a

func _run_host() -> void:
	var story := mode == "net-save-story"
	check(main.load_status == SaveGameScript.LOAD_OK, "N0 host: my save loaded")
	check(await wait_until(func(): return main.players.size() >= 2, 30.0), "N0 host: the client joined")
	await wait(1.5)
	if story:
		check(await wait_shift() and main.current_day == 5 and main._total_sold() == 30, "N0 host: Day 5 (after the saved Day 4), week sold 30")
	else:
		check(en().screen == en().SCREEN_HUB and en().wallet == 137, "N0 host: in the hub with my 137 Bucks")
	_step("view", {"view": view(), "tag": "N1 right after joining"})
	await _client_answer()
	if story:
		await _host_story()
	else:
		await _host_endless()
	_step("bye")
	await _client_answer()
	finish()

func _host_endless() -> void:
	var w0: int = en().wallet
	var saves0: int = main.saves_written
	_step("buy", {"key": "boots"})
	await _client_answer()
	check(await wait_until(func(): return en().upgrade_level("boots") == 1, 5.0) and en().wallet == w0 - 15, "N2 host: the client's purchase applied once (boots 1, wallet %d -> %d)" % [w0, en().wallet])
	check(main.saves_written > saves0 and disk(HOST_SAVE)["endless"]["upgrades"].get("boots") == 1 and disk(HOST_SAVE)["endless"]["wallet"] == en().wallet, "N2 host: and it autosaved to MY file (wallet %d)" % disk(HOST_SAVE)["endless"]["wallet"])
	_step("view", {"view": view(), "tag": "N2 after the purchase"})
	await _client_answer()
	_step("take", {"index": 1})
	await _client_answer()
	check(await wait_shift() and en().shift_number == 5 and int(en().contract.get("crew", 0)) == 2, "N3 host: the client took a posting -> Shift #5, crew of 2")
	add_sales(40)
	await end_shift_now()
	var paid := int(en().last_payout.get("total", -1))
	check(paid > 0 and disk(HOST_SAVE)["endless"]["wallet"] == en().wallet, "N3 host: paid %d, autosaved (wallet %d)" % [paid, en().wallet])
	var saves1: int = main.saves_written
	_step("save")
	var a := await _client_answer()
	check(main.saves_written == saves1 + 1, "N4 host: the client's Save button saved on the host (%d -> %d)" % [saves1, main.saves_written])
	check(a.get("text") == "Saved on the host ✓", "N4 host: the client's button says '%s'" % str(a.get("text")))
	_step("view", {"view": view(), "tag": "N4 on the shift report"})
	await _client_answer()
	_step("continue")
	await _client_answer()
	check(await wait_until(func(): return en().screen == en().SCREEN_HUB, 5.0), "N5 host: back in the hub")
	var d := disk(HOST_SAVE)
	check(d["endless"]["wallet"] == en().wallet and d["endless"]["run_stats"]["shifts"] == 5 and d["endless"]["shift_number"] == 5, "N5 host: my file has the whole session (wallet %d, 5 shifts)" % d["endless"]["wallet"])

func _host_story() -> void:
	add_sales(6)
	await end_shift_now()
	check(main.report_week_label.text == "Week Total: 36", "N2 host: Day 5's report '%s'" % main.report_week_label.text)
	var d := disk(HOST_SAVE)
	check(d["story"]["completed_day"] == 5 and d["week"]["sold"] == 36 and d["week"]["writeups"] == 2, "N2 host: autosaved: completed 5, sold 36")
	_step("report", {"view": view(), "week": main.report_week_label.text, "pay": main.report_pay_label.text})
	await _client_answer()
	_step("continue")
	await _client_answer()
	check(await wait_shift() and main.current_day == 6, "N3 host: the client's Continue -> Day 6")

func _run_client() -> void:
	var raw_before := FileAccess.get_file_as_string(CLIENT_SAVE)
	check(await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 30.0), "client: connected")
	me = main.multiplayer.get_unique_id()
	act = "client_"
	check(main.load_status == -1, "client: never reads a save of its own (status %d)" % main.load_status)
	var n := 0
	while true:
		n += 1
		var step := await _await_file(NET_DIR + "st_%d.json" % n, 300.0)
		var kind: String = step.get("kind", "")
		var f0 := fails
		var ans := {}
		match kind:
			"view":
				var theirs: Dictionary = step["view"]
				var ok := await wait_until(func(): return _canon(view()) == _canon(theirs), 8.0)
				check(ok, "client: %s — I see the host's progress%s" % [step["tag"], "" if ok else ": mine %s vs host %s" % [_canon(view()), _canon(theirs)]])
				if theirs["screen"] == en().SCREEN_HUB:
					check(main.hub_ui.visible and main.hub_ui.buy_buttons.size() == en().UPGRADES.size(), "client: and the hub is on my screen")
			"buy":
				await wait_until(func(): return main.hub_ui.buy_buttons.has(step["key"]), 5.0)
				press(main.hub_ui.buy_buttons.get(step["key"]), "client: buy %s" % step["key"])
			"take":
				await wait_until(func(): return main.hub_ui.offer_buttons.size() > int(step["index"]), 5.0)
				press(main.hub_ui.offer_buttons[int(step["index"])], "client: take posting %d" % int(step["index"]))
			"save":
				await wait_until(func(): return main.report_layer.visible, 5.0)
				press(main.save_button, "client: the report's Save")
				await wait_until(func(): return main.save_button.text != "Save", 5.0)
				ans["text"] = main.save_button.text
			"report":
				var ok := await wait_until(func(): return main.report_layer.visible and main.report_week_label.text == step["week"] and main.report_pay_label.text == step["pay"], 8.0)
				check(ok, "client: Day 5's report matches the host's: '%s' / '%s'" % [main.report_week_label.text, main.report_pay_label.text])
				check(_canon(view()) == _canon(step["view"]), "client: and so does all the progress")
			"continue":
				await wait_until(func(): return main.report_layer.visible, 5.0)
				press(main.continue_button, "client: Continue")
			"bye":
				check(FileAccess.get_file_as_string(CLIENT_SAVE) == raw_before, "client: my own save file was never touched")
				check(main.saves_written == 0, "client: wrote no saves")
				ans["fails"] = fails - f0
				_answer(n, ans)
				finish() # before the host quits (Main quits a client the host leaves)
				return
		ans["fails"] = fails - f0
		_answer(n, ans)
