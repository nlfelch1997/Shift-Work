extends SceneTree
## WEEK 24 — SAVE / LOAD (SaveGame.gd, Main.gd's save_progress()/
## _load_progress()), tested for real: every "relaunch" is a brand-new Godot
## process reading the file the previous one wrote. tools/run_save_tests.sh
## runs the whole sequence; each phase alone:
##
##   OCT 2026 PHASE 2 (save VERSION 2, the shopkeeper economy): solo — earn,
##   buy Produce mid-prep, quit mid-day, relaunch (bank, sections, stage and
##   lifetime sales back; the day replays), play to Day 7, relaunch into Day 8
##   (the game goes on past the old week), then — OCT 2026 PHASE 4, save
##   VERSION 5 — buy gear at the Break Room Shop with the bank, quit
##   mid-shift, relaunch with the gear (and its effect) intact
##   (SAVE = --save-file=user://save_test/save.json). Run in this order:
##     godot --headless --path . --script res://tools/save_test.gd -- --server SAVE --test=save --phase=1   (2, 7, 3, 4)
##   Damaged / missing files, and debug starts never touching the real save:
##     godot --headless --path . --script res://tools/save_test.gd -- --server SAVE --test=save --phase=5
##     godot --headless --path . --script res://tools/save_test.gd -- --server --day=3 --test=save --phase=6
##   Co-op — the host has a save (and so does the client, a different one);
##   the client must see the HOST's progress, buy gear/press Save through the
##   host, and its own file must never change (PHASE 4: the host's file is an
##   old version-2 save with Endless upgrades — they load as the crew's gear):
##     godot --headless --path . --script res://tools/save_test.gd -- --server --save-file=user://save_test/host.json --test=net-save &
##     godot --headless --path . --script res://tools/save_test.gd -- --client --save-file=user://save_test/client.json --test=net-save
##   (--test=net-save-story: the same, with a mid-game save: Day 5, the bank)
##
## Sales are injected on the host (a cashier's replicated total_sold), and a
## shift is ended by running its clock out — the save/load paths, the report,
## the shop's real buttons and the payouts all run through the game's own code.

## Loaded at run time, not preloaded: SaveGame.gd reaches Shop.gd/Events.gd,
## which name the Net/Sfx autoloads — not registered yet while a --script
## SceneTree is being compiled.
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
				_write_text(HOST_SAVE, JSON.stringify(HOST_V2_GEAR_FILE if mode == "net-save" else HOST_STORY_FILE, "\t"))
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	# OCT 2026 PHASE 4: random events (Events.gd) are off here — tools/events_test.gd
	# tests them; --events=on turns them on (the income runs measure both).
	main.events_on = "--events=on" in OS.get_cmdline_user_args()
	main.cleanup_ceiling_override = 0.0 # the report the moment the clock runs out
	match mode:
		"save":
			match phase:
				1: _phase1.call_deferred()
				2: _phase2.call_deferred()
				7: _phase7.call_deferred()
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

func shop() -> Node:
	return main.shop

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
		"day": main.current_day, "gear": shop().upgrades, "lifetime_sold": main._total_sold(),
		"money": main.money, "earned": main.lifetime_earned, "owned": main.sections_owned, "stage": main.complication_stage,
		"speed_mult": shop().speed_mult(), "carry": shop().carry_capacity(), "badge": shop().has_badge(),
	}

## =============================================================================
## SOLO
## =============================================================================

## Fresh install: Day 1 -> Day 2 -> buy Produce in Day 3's prep -> quit
## partway through Day 3.
func _phase1() -> void:
	check(main.load_status == SaveGameScript.LOAD_NONE and main.save_enabled, "P1: no save file -> a fresh start (status %d), saving on" % main.load_status)
	check(await wait_shift(), "P1: Day 1's shift starts")
	check(main.current_day == 1 and main.money == 0 and main.sections_owned == 1 and shop().upgrades.is_empty(), "P1: Day 1, empty bank, Dry Goods only, no gear")
	check(not FileAccess.file_exists(SOLO), "P1: nothing saved before a day is done")
	add_sales(50)
	main.record_writeup(1, "testing")
	await end_shift_now()
	var pay1: int = main._pay_today()
	var d := disk()
	check(not d.is_empty() and d["shop"]["completed_day"] == 1 and d["shop"]["money"] == pay1 and d["shop"]["lifetime_earned"] == pay1, "P1: Day 1's report autosaved: completed day 1, bank %s (%s)" % [main._format_money(pay1), str(d.get("shop"))])
	check(d["shop"]["lifetime_sold"] == 50 and d["shop"]["sections_owned"] == 1, "P1: lifetime sold 50, 1 section")
	main._on_continue_pressed()
	check(await wait_shift() and main.current_day == 2, "P1: Continue -> Day 2")
	add_sales(40)
	await end_shift_now()
	d = disk()
	check(d["shop"]["completed_day"] == 2 and d["shop"]["lifetime_sold"] == 90 and d["shop"]["money"] == main.money, "P1: Day 2 autosaved: completed 2, sold 90, bank %s" % main._format_money(main.money))
	main._on_continue_pressed()
	check(await wait_shift() and main.current_day == 3, "P1: Continue -> Day 3")
	var bank0: int = main.money
	check(main.buy_section("Produce", 1), "P1: Day 3 prep — Produce bought (bank %s)" % main._format_money(main.money))
	d = disk()
	check(d["shop"]["sections_owned"] == 2 and d["shop"]["money"] == bank0 - main.section_price("Produce") and d["shop"]["completed_day"] == 2, "P1: the purchase autosaved at once (2 sections, bank %s) — the day itself still isn't" % main._format_money(d["shop"]["money"]))
	add_sales(4) # mid-day progress: must NOT survive the quit
	await wait(0.5)
	main.save_progress("mid-day test checkpoint")
	d = disk()
	check(d["shop"]["completed_day"] == 2 and d["shop"]["lifetime_sold"] == 90, "P1: a mid-day save counts no in-flight sales (file still says completed 2, sold 90)")
	_write_text(EXPECT, JSON.stringify({"money": main.money, "earned": main.lifetime_earned}))
	print("P1: quitting partway through Day 3 (4 sold that day)")
	finish()

## Relaunch: back at the start of Day 3 with Days 1-2 counted and Produce
## still owned; play to Day 7's report, press Save there, quit.
func _phase2() -> void:
	var expect: Dictionary = _read_json(EXPECT)
	check(main.load_status == SaveGameScript.LOAD_OK, "P2: the save loaded (status %d)" % main.load_status)
	check(await wait_shift(), "P2: a shift starts")
	check(main.current_day == 3 and main.completed_story_day == 2, "P2: resumes at Day 3 — the day after the last completed one (day %d)" % main.current_day)
	check(main._total_sold() == 90 and main._sold_at_day_start == 90, "P2: lifetime sales restored: %d (want 90, Day 3's 4 lost)" % main._total_sold())
	check(main.money == int(expect["money"]) and main.lifetime_earned == int(expect["earned"]) and main.sections_owned == 2, "P2: bank %s, lifetime $%d, 2 sections — as saved" % [main._format_money(main.money), main.lifetime_earned])
	check(main.get_node("Gates/GateMeatDeli/CollisionShape2D").disabled, "P2: Produce's gate is open after the relaunch")
	check(main.complication_stage == main.STAGE_FORKLIFT, "P2: and the forklift stage arrived with this (replayed) shift's start (stage %d)" % main.complication_stage)
	add_sales(3)
	await end_shift_now()
	check(main.report_layer.visible and main.report_week_label.text.begins_with("Bank: %s" % main._format_money(main.money)) and main.report_today_label.text == "Sold Today: 3", "P2: Day 3's report: '%s' / '%s'" % [main.report_today_label.text, main.report_week_label.text])
	check(disk()["shop"]["completed_day"] == 3, "P2: Day 3 autosaved")
	for day in [4, 5, 6, 7]:
		main._on_continue_pressed()
		check(await wait_shift() and main.current_day == day, "P2: Day %d" % day)
		add_sales(2)
		await end_shift_now()
		check(disk()["shop"]["completed_day"] == day and disk()["shop"]["lifetime_sold"] == 93 + 2 * (day - 3) and disk()["shop"]["money"] == main.money, "P2: Day %d autosaved (sold %d, bank %s)" % [day, disk()["shop"]["lifetime_sold"], main._format_money(main.money)])
	check(main.continue_button.text == "Continue", "P2: Day 7's report just says Continue — no end of the week ('%s')" % main.continue_button.text)
	check(main.save_button.text == "Save" and main.save_button.visible, "P2: the Save button is a real 'Save' now ('%s')" % main.save_button.text)
	var before: int = main.saves_written
	DirAccess.remove_absolute(SOLO) # prove the button writes it
	main.save_button.pressed.emit()
	await wait(0.1)
	check(main.saves_written == before + 1 and FileAccess.file_exists(SOLO), "P2: Save button wrote the file (saves %d -> %d)" % [before, main.saves_written])
	check(main.save_button.text == "Saved ✓", "P2: and says so ('%s')" % main.save_button.text)
	var d := disk()
	check(d["shop"]["completed_day"] == 7 and d["gear"].is_empty() and d["events"]["seen"].is_empty(), "P2: saved on Day 7's report: completed 7, no gear, no events")
	var rawj: Dictionary = _read_json(SOLO)
	check(int(rawj.get("version", 0)) == SaveGameScript.VERSION and SaveGameScript.VERSION >= 5 and rawj.has("gear") and rawj.has("events") and not rawj.has("endless"), "P2: the file is the current version (5 added these): 'gear' and 'events', no 'endless' block (%s)" % str(rawj.keys()))
	await wait(2.7)
	check(main.save_button.text == "Save", "P2: the button reads 'Save' again after a moment")
	_write_text(EXPECT, JSON.stringify({"money": main.money, "earned": main.lifetime_earned, "owned": main.sections_owned, "stage": main.complication_stage}))
	print("P2: quitting on Day 7's report")
	finish()

## Relaunch: the game goes on — Day 8, everything as saved. Leaves the file
## alone (no checkpoint reached) for the gear phases.
func _phase7() -> void:
	var expect: Dictionary = _read_json(EXPECT)
	var raw := FileAccess.get_file_as_string(SOLO)
	check(main.load_status == SaveGameScript.LOAD_OK, "P7: loaded")
	check(await wait_shift() and main.current_day == 8 and main.get_node_or_null("HubUI") == null, "P7: a Day 7 save resumes on Day 8 — past the old week, no WEEK COMPLETE")
	check(main.money == int(expect["money"]) and main.lifetime_earned == int(expect["earned"]) and main.sections_owned == int(expect["owned"]), "P7: bank %s, lifetime $%d, %d sections — as saved" % [main._format_money(main.money), main.lifetime_earned, main.sections_owned])
	check(main.complication_stage >= int(expect["stage"]), "P7: stage %d (saved %d; at most one step on at this shift's start)" % [main.complication_stage, int(expect["stage"])])
	check(main.status_label.text.begins_with("Shift 8  ·  Bank %s" % main._format_money(main.money)), "P7: status line '%s'" % main.status_label.text)
	check(FileAccess.get_file_as_string(SOLO) == raw, "P7: nothing written (no checkpoint yet)")
	finish()

## OCT 2026 PHASE 4 — relaunch onto Day 8 again (the file still says Day 7
## was the last done), buy gear at the Break Room Shop with the bank during
## prep (the real E at the lockers, the real button), quit mid-shift.
func _phase3() -> void:
	check(main.load_status == SaveGameScript.LOAD_OK, "P3: loaded")
	check(await wait_shift() and main.current_day == 8 and not main.store_open, "P3: Day 8, in prep")
	main.money = 1000 + shop().next_cost("shoes") + shop().next_cost("boots") # enough for two pieces of gear (test plumbing; PHASE 5: priced from Shop.gd)
	var bank_p3: int = main.money
	player().teleport_to(shop().LOCKER_SPOT)
	await wait(0.3)
	Input.action_press(act + "interact")
	await physics_frame
	Input.action_release(act + "interact")
	check(await wait_until(func(): return shop().panel.visible and shop().buttons.has("shoes"), 3.0), "P3: E at the gear lockers opens the shop")
	press(shop().buttons["shoes"], "P3: buy Comfy Sneakers")
	await wait(0.2)
	check(shop().upgrade_level("shoes") == 1 and main.money == bank_p3 - shop().UPGRADES[0]["costs"][0], "P3: Sneakers level 1, bank %s -> %s" % [main._format_money(bank_p3), main._format_money(main.money)])
	var d := disk()
	check(d["gear"].get("shoes") == 1 and d["shop"]["money"] == main.money and d["shop"]["completed_day"] == 7, "P3: the purchase autosaved at once (%s, bank %s) — the day itself still isn't" % [str(d["gear"]), main._format_money(d["shop"]["money"])])
	await wait(0.2)
	press(shop().buttons["boots"], "P3: buy Steel-Toe Boots")
	await wait(0.2)
	var expect := {"gear": shop().upgrades, "money": main.money}
	check(_canon(disk()["gear"]) == _canon(shop().upgrades) and disk()["shop"]["money"] == main.money, "P3: file == live after every purchase (%s, bank %s)" % [str(shop().upgrades), main._format_money(main.money)])
	_write_text(EXPECT, JSON.stringify(expect))
	print("P3: quitting mid-prep on Day 8 — expecting %s" % str(expect))
	finish()

## Relaunch: the gear is exactly what was bought, it really works, and the
## next checkpoint keeps it.
func _phase4() -> void:
	var expect: Dictionary = _read_json(EXPECT)
	check(main.load_status == SaveGameScript.LOAD_OK, "P4: loaded")
	check(await wait_shift() and main.current_day == 8, "P4: Day 8 (replayed — it never finished)")
	check(_canon(shop().upgrades) == _canon(expect["gear"]) and main.money == int(expect["money"]), "P4: gear %s == %s, bank %s" % [str(shop().upgrades), str(expect["gear"]), main._format_money(main.money)])
	var S: float = player().SPEED
	var v := await measure_speed()
	check(absf(v - S * shop().speed_mult()) < S * 0.03 and shop().speed_mult() > 1.0, "P4: the loaded Sneakers really work: %.0f px/s = %.0f x %.2f" % [v, S, shop().speed_mult()])
	check(is_equal_approx(shop().forklift_stun_mult(), 1.0 - 0.35), "P4: and the Boots (stun x%.2f)" % shop().forklift_stun_mult())
	add_sales(20)
	await end_shift_now()
	var d := disk()
	check(d["shop"]["completed_day"] == 8 and _canon(d["gear"]) == _canon(shop().upgrades), "P4: Day 8 autosaved with the gear (%s)" % str(d["gear"]))
	finish()

## Damaged files: never a crash, never a soft-lock — a fresh week.
func _phase5() -> void:
	check(main.load_status == SaveGameScript.LOAD_CORRUPT, "P5: a garbage file is reported damaged (status %d)" % main.load_status)
	check(FileAccess.file_exists(SOLO + ".bad") and FileAccess.get_file_as_string(SOLO + ".bad").begins_with("{ this is not json"), "P5: the damaged file was copied aside to .bad")
	check(await wait_shift(), "P5: the game still starts a shift (no soft-lock)")
	check(main.current_day == 1 and main.money == 0 and main.sections_owned == 1 and shop().upgrades.is_empty() and main.events.seen.is_empty(), "P5: a fresh start: Day 1, empty bank, no gear, no events seen")
	add_sales(3)
	await end_shift_now()
	var d := disk()
	check(not d.is_empty() and d["shop"]["completed_day"] == 1, "P5: the next checkpoint writes a good save over it")
	# --- SaveGame.read on every kind of bad file.
	var t := DIR + "unit.json"
	var cases := {
		"empty file": "",
		"whitespace": "   \n",
		"truncated": '{"version": 2, "shop": {"completed_',
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
	# OCT 2026 PHASE 2: a version-1 (story) save is LEGACY — kept aside, not loaded.
	var v1 := '{"version": 1, "story": {"completed_day": 4, "complete": false}, "week": {"sold": 30}}'
	_write_text(t, v1)
	DirAccess.remove_absolute(t + ".v1.bak")
	var r1: Array = SaveGameScript.read(t)
	check(r1[0] == SaveGameScript.LOAD_LEGACY and r1[1].is_empty(), "P5: a version-1 save -> LEGACY, nothing loaded (status %d)" % r1[0])
	check(FileAccess.file_exists(t + ".v1.bak") and FileAccess.get_file_as_string(t + ".v1.bak") == v1, "P5: ...and copied aside to .v1.bak, byte for byte")
	DirAccess.remove_absolute(t + ".v1.bak")
	_write_text(t, JSON.stringify({"version": 2,
		"shop": {"completed_day": -3, "money": "lots", "lifetime_earned": -5, "sections_owned": 9, "stage": "x", "lifetime_sold": 2.7},
		"endless": {"unlocked": "yes", "wallet": 1e30, "upgrades": {"shoes": 99, "brace": -1, "soles": 1.9, "hax": 5}, "shift_number": "x",
			"run_stats": {"shifts": 3, "medals": [1, "a", 2]}, "week_summary": {"sold": 9, "pay": -40, "evil": {}}}}))
	var r: Array = SaveGameScript.read(t)
	var s: Dictionary = r[1]
	check(r[0] == SaveGameScript.LOAD_OK, "P5: a well-formed file with bad values still loads")
	check(s["shop"]["completed_day"] == 0 and s["shop"]["money"] == 0 and s["shop"]["lifetime_earned"] == 0, "P5: day -3 -> 0, a string bank -> 0, negative lifetime -> 0 (%s)" % str(s["shop"]))
	check(s["shop"]["sections_owned"] == 4 and s["shop"]["stage"] == 0 and s["shop"]["lifetime_sold"] == 2 and not s.has("endless"), "P5: 9 sections -> 4, a string stage -> 0, 2.7 -> 2, no 'endless' block survives (%s)" % str(s["shop"]))
	_write_text(t, JSON.stringify({"version": 2, "shop": {"money": -250}}))
	check(SaveGameScript.read(t)[1]["shop"]["money"] == -250 and SaveGameScript.read(t)[1]["shop"]["sections_owned"] == 1, "P5: a bank in the red loads as it was; missing sections -> 1")
	check(_canon(s["gear"]) == _canon({"shoes": 3, "soles": 1}), "P5: a v2 save's Endless upgrades carry over as gear, clamped to their max, unknown keys dropped (%s)" % str(s["gear"]))
	check(s["events"]["seen"].is_empty() and s["events"]["completed"] == 0, "P5: a v2 save has met no events yet (%s)" % str(s["events"]))
	# OCT 2026 PHASE 4 — version 5: damaged gear and event fields, cleaned.
	_write_text(t, JSON.stringify({"version": 5, "shop": {"completed_day": 9, "sections_owned": 3},
		"gear": {"shoes": "x", "badge": 7, "brace": 1.0, "hax": 2},
		"endless": {"upgrades": {"janitor": 2}}, # a stray old block: "gear" wins
		"events": {"seen": ["rush", "bogus", 5, "leak"], "completed": -3}}))
	var r5: Array = SaveGameScript.read(t)
	var s5: Dictionary = r5[1]
	check(r5[0] == SaveGameScript.LOAD_OK and _canon(s5["gear"]) == _canon({"badge": 1, "brace": 1}), "P5: v5 gear cleaned: a string level dropped, 7 -> 1 (max), unknown keys dropped, 'gear' beats a stray 'endless' (%s)" % str(s5["gear"]))
	check(_canon(s5["events"]["seen"]) == _canon({"rush": true, "leak": true}) and s5["events"]["completed"] == 0, "P5: events seen: only real event keys; completed -3 -> 0 (%s)" % str(s5["events"]))
	# Every older version loads: v3 (staff) and v4 (upkeep) without any of it.
	for ver in [2, 3, 4]:
		_write_text(t, JSON.stringify({"version": ver, "shop": {"completed_day": 5, "money": 50, "sections_owned": 3}, "endless": {"unlocked": true, "wallet": 80, "upgrades": {"janitor": 1}}}))
		var rv: Array = SaveGameScript.read(t)
		check(rv[0] == SaveGameScript.LOAD_OK and rv[1]["shop"]["completed_day"] == 5 and _canon(rv[1]["gear"]) == _canon({"janitor": 1}) and rv[1]["events"]["seen"].is_empty(), "P5: a version-%d save loads: day 5, its upgrades as gear, the Bucks wallet dropped (%s)" % [ver, str(rv[1].get("gear"))])
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

## The host's save: an OLD version-2 file from a crew that had played the
## debug Endless route — its upgrades must come through as the crew's gear
## (PHASE 4), its Bucks don't.
const HOST_V2_GEAR_FILE := {"version": 2,
	"shop": {"completed_day": 7, "money": 300, "lifetime_earned": 7000, "sections_owned": 4, "stage": 5, "lifetime_sold": 140},
	"endless": {"unlocked": true, "wallet": 137, "upgrades": {"shoes": 2, "brace": 1, "badge": 1}, "shift_number": 4,
		"run_stats": {"shifts": 4, "sold": 88, "bucks": 210, "medals": [1, 1, 1, 1]},
		"week_summary": {"sold": 140, "pay": 1700, "writeups": 3, "priority_sales": 10, "clean_bonus": 90}}}
## The host's save: mid-game, Days 1-4 done, Produce owned.
const HOST_STORY_FILE := {"version": 2,
	"shop": {"completed_day": 4, "money": 1234, "lifetime_earned": 1500, "sections_owned": 2, "stage": 2, "lifetime_sold": 30},
	"endless": {"unlocked": false, "wallet": 0, "upgrades": {}, "shift_number": 0, "run_stats": {"shifts": 0, "sold": 0, "bucks": 0, "medals": [0, 0, 0, 0]}, "week_summary": {}}}
## The client's OWN save — different from the host's in every way. It must be
## ignored in the host's session, and never overwritten.
const CLIENT_FILE := {"version": 2,
	"shop": {"completed_day": 2, "money": 77, "lifetime_earned": 90, "sections_owned": 1, "stage": 0, "lifetime_sold": 9},
	"endless": {"unlocked": false, "wallet": 999, "upgrades": {"janitor": 2}, "shift_number": 0, "run_stats": {}, "week_summary": {}}}

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
		check(await wait_shift() and main.current_day == 5 and main._total_sold() == 30 and main.money == 1234 and main.sections_owned == 2, "N0 host: Day 5 (after the saved Day 4), sold 30, bank $1234, 2 sections")
	else:
		check(await wait_shift() and main.current_day == 8 and main.money == 300 and _canon(shop().upgrades) == _canon({"shoes": 2, "brace": 1, "badge": 1}), "N0 host: my v2 save -> Day 8, bank $300, its Endless upgrades as gear (%s)" % str(shop().upgrades))
	_step("view", {"view": view(), "tag": "N1 right after joining"})
	await _client_answer()
	if story:
		await _host_story()
	else:
		await _host_gear()
	_step("bye")
	await _client_answer()
	finish()

func _host_gear() -> void:
	# PHASE 5: enough for the boots at whatever Shop.gd charges.
	var boots_cost: int = shop().next_cost("boots")
	main.money = maxi(main.money, boots_cost + 300)
	var m0: int = main.money
	var saves0: int = main.saves_written
	_step("buy", {"key": "boots"})
	await _client_answer()
	check(await wait_until(func(): return shop().upgrade_level("boots") == 1, 5.0) and main.money == m0 - boots_cost, "N2 host: the client's purchase applied once (boots 1, bank %s -> %s)" % [main._format_money(m0), main._format_money(main.money)])
	check(main.saves_written > saves0 and disk(HOST_SAVE)["gear"].get("boots") == 1 and disk(HOST_SAVE)["shop"]["money"] == main.money, "N2 host: and it autosaved to MY file (bank %s)" % main._format_money(disk(HOST_SAVE)["shop"]["money"]))
	_step("view", {"view": view(), "tag": "N2 after the purchase"})
	await _client_answer()
	add_sales(40)
	await end_shift_now()
	check(disk(HOST_SAVE)["shop"]["completed_day"] == 8 and disk(HOST_SAVE)["shop"]["money"] == main.money, "N3 host: Day 8 paid and autosaved (bank %s)" % main._format_money(main.money))
	var saves1: int = main.saves_written
	_step("save")
	var a := await _client_answer()
	check(main.saves_written == saves1 + 1, "N4 host: the client's Save button saved on the host (%d -> %d)" % [saves1, main.saves_written])
	check(a.get("text") == "Saved on the host ✓", "N4 host: the client's button says '%s'" % str(a.get("text")))
	_step("view", {"view": view(), "tag": "N4 on the shift report"})
	await _client_answer()
	_step("continue")
	await _client_answer()
	check(await wait_shift() and main.current_day == 9, "N5 host: the client's Continue -> Day 9")
	var d := disk(HOST_SAVE)
	check(d["shop"]["completed_day"] == 8 and _canon(d["gear"]) == _canon(shop().upgrades), "N5 host: my file has the whole session (gear %s)" % str(d["gear"]))

func _host_story() -> void:
	add_sales(6)
	await end_shift_now()
	check(main.report_week_label.text.begins_with("Bank: %s" % main._format_money(main.money)) and main.money == 1234 + main._pay_today(), "N2 host: Day 5's report '%s'" % main.report_week_label.text)
	var d := disk(HOST_SAVE)
	check(d["shop"]["completed_day"] == 5 and d["shop"]["lifetime_sold"] == 36 and d["shop"]["money"] == main.money, "N2 host: autosaved: completed 5, sold 36, bank %s" % main._format_money(main.money))
	_step("report", {"view": view(), "week": main.report_week_label.text, "pay": main.report_pay_label.text})
	await _client_answer()
	_step("continue")
	await _client_answer()
	check(await wait_shift() and main.current_day == 6, "N3 host: the client's Continue -> Day 6")

func _run_client() -> void:
	var raw_before := FileAccess.get_file_as_string(CLIENT_SAVE)
	check(await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 30.0), "client: connected")
	me = main.multiplayer.get_unique_id()
	act = root.get_node("Settings").local_prefix()
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
			"buy":
				# The real thing: walk to the gear lockers, E, click the button.
				player().teleport_to(shop().LOCKER_SPOT)
				await wait(0.4)
				Input.action_press(act + "interact")
				await physics_frame
				Input.action_release(act + "interact")
				await wait_until(func(): return shop().panel.visible and shop().buttons.has(step["key"]), 5.0)
				check(shop().panel.visible and shop().buttons.size() == shop().UPGRADES.size(), "client: E at the lockers opened the shop on my screen")
				press(shop().buttons.get(step["key"]), "client: buy %s" % step["key"])
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
