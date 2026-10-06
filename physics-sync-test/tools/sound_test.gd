extends SceneTree
## WEEK 22 test harness — sound (Sfx.gd, SoundDirector.gd). Loads the real
## Main.tscn and drives the real game code; checks WHICH sounds play WHEN, on
## WHICH peer, and that nothing machine-guns. Headless runs use Godot's dummy
## audio driver: every player is still created, started and counted exactly
## as with a sound card, it just isn't audible. Not part of the game.
##
## Every file in res://audio/ loads, nothing's missing, nothing's orphaned:
##   godot --headless --path . --script res://tools/sound_test.gd -- --test=sound-assets
## Solo, every system on (Day 7): each scenario triggers the real thing and
## checks its sound — footsteps, pickup/drop/throw, impacts, shelf place,
## sales, store open, priority orders, spills, the lights sting, the manager,
## both forklifts (engine starts ONCE, beeper rate), a shelf wreck, displays,
## cleanup tools and chimes, clock-out, the paycheck, the finale fanfare,
## music per phase — then a spam check over the whole run:
##   godot --headless --path . --script res://tools/sound_test.gd -- --server --day=7 --test=sound
## Co-op (2-4 players), same machine: every WORLD sound must play on every
## peer within a beat of the host, your OWN sounds only on your own machine:
##   godot --headless --path . --script res://tools/sound_test.gd -- --server --day=7 --players=3 --test=net-sound &
##   (x2) godot --headless --path . --script res://tools/sound_test.gd -- --client --test=net-sound
## (SW_NET_DIR=user://some_dir/ in the environment moves the peers' shared
## files, like hazards_test.gd.)

var main: Node
var sfx: Node
var fails := 0
var me := 1
var act := "host_"
var _held := {}
## Every sound this peer played: [[unix seconds, name], ...].
var heard: Array = []
var NET_DIR: String = OS.get_environment("SW_NET_DIR") if OS.get_environment("SW_NET_DIR") != "" else "user://net_sound/"

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	# OCT 2026 PHASE 4: random events (Events.gd) are off here — tools/events_test.gd
	# tests them; --events=on turns them on (the income runs measure both).
	main.events_on = "--events=on" in OS.get_cmdline_user_args()
	# OCT 2026 PHASE 2: written for the 7-day story — Day N -> N+1 hands the
	# crew old Day N+1's sections/earnings (Main.gd's test_follow_old_calendar),
	# (OCT 2026 PHASE 4: Week 21's Endless Mode and its debug --endless route
	# are retired — Day 7's report just leads to Day 8 now.)
	main.test_follow_old_calendar = true
	sfx = root.get_node("Sfx")
	sfx.played.connect(func(s, _p): heard.append([Time.get_unix_time_from_system(), s]))
	var mode := "sound"
	for a in args:
		if a.begins_with("--test="):
			mode = a.substr(7)
	main.opening_stock_fraction = 1.0 # loose stock on the floor to throw/shelve
	match mode:
		"sound-assets":
			_run_assets.call_deferred()
		"sound":
			_run_solo.call_deferred()
		"net-sound":
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
	_release_all()
	print("SOUNDS  %s" % str(_sorted_counts()))
	print("RESULT: %s (%d failure%s)" % ["OK" if fails == 0 else "FAILED", fails, "" if fails == 1 else "s"])
	quit(1 if fails else 0)

func _sorted_counts() -> Array:
	var out := []
	var names: Array = sfx.play_counts.keys()
	names.sort()
	for n in names:
		out.append("%s=%d" % [n, sfx.play_counts[n]])
	return out

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

func count(sound: String) -> int:
	return sfx.play_counts.get(sound, 0)

## Waits up to `timeout` for `sound` to have played more than `before` times.
func heard_after(sound: String, before: int, timeout := 1.5) -> bool:
	return await wait_until(func(): return count(sound) > before, timeout)

func press(action: String, strength := 1.0) -> void:
	if strength <= 0.0:
		if _held.has(action):
			Input.action_release(action)
			_held.erase(action)
		return
	Input.action_press(action, strength)
	_held[action] = true

func _release_all() -> void:
	for a in _held.keys():
		Input.action_release(a)
	_held.clear()

func steer(dir: Vector2) -> void:
	press(act + "move_right", maxf(dir.x, 0.0))
	press(act + "move_left", maxf(-dir.x, 0.0))
	press(act + "move_down", maxf(dir.y, 0.0))
	press(act + "move_up", maxf(-dir.y, 0.0))

func player() -> Node2D:
	return main.players[me]

func amb() -> Node2D:
	return main.ambience

func move_body(body: RigidBody2D, pos: Vector2) -> void:
	PhysicsServer2D.body_set_state(body.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, Transform2D(0.0, pos))
	PhysicsServer2D.body_set_state(body.get_rid(), PhysicsServer2D.BODY_STATE_LINEAR_VELOCITY, Vector2.ZERO)
	body.global_position = pos
	body.linear_velocity = Vector2.ZERO

func free_product(color = null) -> RigidBody2D:
	for obj in get_nodes_in_group("carryable"):
		if obj.is_in_group("delivery_box") or obj.get_node("Carryable").carrier_id != 0:
			continue
		if main.shelves.any(func(s): return s.get_node("Shelf").contains(obj)):
			continue
		if color != null and not obj.get_node("Polygon2D").color.is_equal_approx(color):
			continue
		return obj
	return null

func pin_manager(pos: Vector2, heading: float) -> void:
	var m: Node2D = main.manager
	m.position = pos
	m.target_position = pos
	m.facing = heading
	m._look_heading = heading
	m._pause_timer = 1.0e9
	m._legs.clear()

## Host: everything that would make noise on its own, stopped — each scenario
## starts the one thing it tests.
func park_everything() -> void:
	main.test_hold_customers = true
	main.forklift._pause_timer = 1.0e9
	pin_manager(Vector2(480, 1350), 0.0)
	main._order_timer = 1.0e9
	amb()._lights_timer = 1.0e9
	amb()._spill_timer = 1.0e9

## The most plays of one sound inside any `window`-second span of `log`.
static func peak_rate(log: Array, sound: String, window := 1.0) -> int:
	var times: Array = log.filter(func(h): return h[1] == sound).map(func(h): return h[0])
	var best := 0
	var a := 0
	for b in times.size():
		while times[b] - times[a] > window:
			a += 1
		best = maxi(best, b - a + 1)
	return best

## Every sound's worst 1-second burst against its ceiling.
func spam_check(log: Array, who: String) -> void:
	var limits := {"footstep": 5, "register_ding": 8, "impact_light": 12, "impact_heavy": 12, "box_thud": 12, "forklift_beep": 4, "forklift_alert": 4, "place_shelf": 8, "pickup": 6, "drop": 6, "mop": 4, "broom": 5, "clean_chime": 6, "ui_click": 8}
	var names := {}
	for h in log:
		names[h[1]] = true
	var bad := []
	var worst := {}
	for n in names:
		var r := peak_rate(log, n)
		worst[n] = r
		if r > limits.get(n, 3):
			bad.append("%s %d/s" % [n, r])
	print("RATES  %s peak plays per second: %s" % [who, str(worst)])
	check(bad.is_empty(), "%s: no sound over its per-second ceiling (over: %s)" % [who, str(bad)])

## --- sound-assets ------------------------------------------------------------------

func _run_assets() -> void:
	await process_frame
	check(sfx.missing.is_empty(), "every LIBRARY/MUSIC file loads (missing: %s)" % str(sfx.missing))
	var bad := []
	var used := {}
	for sound in sfx.LIBRARY:
		for f in sfx.LIBRARY[sound]["files"]:
			used["res://audio/%s.ogg" % f] = true
		for s in sfx._streams.get(sound, []):
			if s == null or s.get_length() <= 0.01:
				bad.append(sound)
	for track in sfx.MUSIC:
		used["res://audio/%s.ogg" % sfx.MUSIC[track]] = true
		var s: AudioStream = sfx._streams["music:" + track][0]
		check(s.loop and s.get_length() > 20.0, "music '%s' loops (%.1fs)" % [track, s.get_length()])
	check(bad.is_empty(), "every sound has a non-empty stream (bad: %s)" % str(bad))
	check(sfx._streams["forklift_engine"][0].loop, "forklift engine stream loops")
	var on_disk := []
	var total := 0
	for dir in ["res://audio/", "res://audio/sfx/", "res://audio/music/"]:
		for f in DirAccess.get_files_at(dir):
			if f.ends_with(".ogg"):
				on_disk.append(dir + f)
				total += FileAccess.get_file_as_bytes(dir + f).size()
	var orphans := on_disk.filter(func(p): return not used.has(p))
	check(orphans.is_empty(), "no orphaned audio files (%d on disk; orphans: %s)" % [on_disk.size(), str(orphans)])
	check(total < 4 * 1024 * 1024, "all audio together is %.1f MB (< 4 MB)" % (total / 1048576.0))
	check(ResourceLoader.exists("res://audio/final_shift.ogg"), "res://audio/final_shift.ogg exists (was a silent stub)")
	for bus in ["Music", "SFX", "Hazard", "UI"]:
		check(AudioServer.get_bus_index(bus) != -1, "bus %s exists" % bus)
	check(AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Hazard")) > AudioServer.get_bus_volume_db(AudioServer.get_bus_index("SFX")) and AudioServer.get_bus_volume_db(AudioServer.get_bus_index("SFX")) > AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Music")), "bus hierarchy: Hazard > SFX > Music")
	# Every hazard cue sits on the Hazard bus.
	for n in ["forklift_beep", "forklift_alert", "manager_whistle", "manager_tweet", "order_chime", "flicker_sting", "spill_splat", "final_shift"]:
		check(sfx.LIBRARY[n]["bus"] == "Hazard", "%s is a Hazard-bus cue" % n)
	finish()

## --- solo --------------------------------------------------------------------------

func _run_solo() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 15.0)
	me = 1
	await wait(0.5)
	check(main.current_day == 7, "started on Day 7 (every hazard on)")
	check(count("final_shift") == 1, "S0 the fanfare played once as Day 7 started (its RUSH SEASON banner; was FINAL SHIFT) (%d)" % count("final_shift"))
	check(sfx.music_track == "prep" and not main.store_open, "S1 prep phase: calm music ('%s')" % sfx.music_track)
	park_everything()
	await wait(1.6) # past the director's warm-up

	# S2 footsteps: ~6.9 steps for 440px walked, none standing still.
	player().teleport_to(Vector2(1200, 810))
	await wait(0.4)
	var f0 := count("footstep")
	await wait(1.0)
	check(count("footstep") == f0, "S2 standing still: no footsteps")
	steer(Vector2.RIGHT)
	await wait(2.0)
	steer(Vector2.ZERO)
	var steps := count("footstep") - f0
	check(steps >= 5 and steps <= 9, "S2 walking 2s (~440px): %d footsteps (5-9 — one per %.0fpx, not every frame)" % [steps, main.sound_director.STEP_DISTANCE])
	check(peak_rate(heard, "footstep", 0.25) <= 1, "S2 never two footsteps within 0.25s")

	# S3 pickup / drop / throw, and the throw's impact.
	# Oct 2026: from the hub's open north-west corner, so the throw goes
	# straight up into the bare wall. (It was Dry Goods, where the impact came
	# from the stocked shelf — and stocked items no longer collide with thrown
	# stock: Carryable.gd's LAYER_SHELF_STOCK.)
	player().teleport_to(Vector2(1060, 660))
	await wait(0.3)
	var obj := free_product()
	move_body(obj, player().global_position + Vector2(42, 0)) # clear of the player's body, inside PICKUP_RANGE
	await wait(0.2)
	var p0 := count("pickup")
	obj.get_node("Carryable").try_pickup(1, player().global_position)
	check(await heard_after("pickup", p0), "S3 pickup sound on my own pickup")
	var d0 := count("drop")
	obj.get_node("Carryable").try_drop(1)
	check(await heard_after("drop", d0), "S3 drop sound on my own set-down")
	await wait(0.3)
	obj.get_node("Carryable").try_pickup(1, player().global_position)
	await wait(0.2)
	var t0 := count("throw")
	var i0: int = main.sound_director.impacts_detected
	var hits0: int = count("impact_light") + count("impact_heavy")
	obj.get_node("Carryable").try_throw(1, Vector2.UP)
	check(await heard_after("throw", t0), "S3 whoosh on my own throw")
	check(await wait_until(func(): return main.sound_director.impacts_detected > i0, 2.0), "S3 host spotted the thrown item hitting the wall")
	check(count("impact_light") + count("impact_heavy") > hits0, "S3 ...and played an impact")

	# S4 store open: the bell, and the music switches (faster on the finale).
	var o0 := count("store_open")
	main.open_store(1)
	main.forklift._pause_timer = 1.0e9
	check(await heard_after("store_open", o0), "S4 STORE OPEN bell")
	await wait(0.2)
	check(sfx.music_track == "selling" and is_equal_approx(sfx.music_pitch, 1.06), "S4 selling music, a touch faster on Day 7 ('%s' x%.2f)" % [sfx.music_track, sfx.music_pitch])

	# S5 a product settling onto a shelf slot.
	var placed := false
	for shelf_body in main.shelves:
		if not main.is_unlocked_at_pos(shelf_body.global_position):
			continue
		var shelf: Node = shelf_body.get_node("Shelf")
		for i in shelf.slots.size():
			if shelf._is_filled(i):
				continue
			var color: Color = main.SECTION_COLORS[main._section_name_at(shelf_body.global_position)]
			var item := free_product(color)
			if item == null:
				continue
			var s0 := count("place_shelf")
			move_body(item, shelf.slots[i].global_position)
			placed = await heard_after("place_shelf", s0, 2.0)
			break
		if placed:
			break
	check(placed, "S5 clunk as an item settles onto a shelf")

	# S6 a sale at a register.
	var cashier: Node = main.cashiers.filter(func(c): return c.get_node("Cashier").active)[0].get_node("Cashier")
	var r0 := count("register_ding")
	cashier._complete_purchase(free_product(), 0)
	check(await heard_after("register_ding", r0), "S6 register ding on a sale")

	# S7 priority orders: the call-out chime, filled, missed.
	var c0 := count("order_chime")
	main._issue_priority_order()
	check(await heard_after("order_chime", c0) and count("order_chime") == c0 + 1, "S7 PA chime once as a priority order is called out")
	var of0 := count("order_filled")
	main._close_priority_order(true)
	check(await heard_after("order_filled", of0), "S7 'filled' sound")
	await wait(1.2)
	main._issue_priority_order()
	await wait(0.3)
	var om0 := count("order_missed")
	main._close_priority_order(false)
	check(await heard_after("order_missed", om0), "S7 'missed' sound")
	check(count("order_chime") == c0 + 2, "S7 exactly one chime per order called (%d)" % (count("order_chime") - c0))

	# S8 a spill appearing.
	var sp0 := count("spill_splat")
	var sid: int = amb().spawn_spill(Vector2(1300, 450), 40.0)
	check(await heard_after("spill_splat", sp0, 0.5), "S8 splat as a spill appears")
	amb().remove_spill(sid)

	# S9 the lights: one comedic sting per event, on its darkest dip.
	var l0 := count("flicker_sting")
	var lt0 := Time.get_ticks_msec()
	amb().start_lights_event()
	check(await heard_after("flicker_sting", l0, 1.0), "S9 flicker sting as the lights first dip")
	var lag := (Time.get_ticks_msec() - lt0) / 1000.0
	check(lag < 0.4, "S9 ...within %.2fs of the event starting (its first dip is <=0.16s in)" % lag)
	await wait_until(func(): return not amb().event_playing(), 15.0)
	await wait(0.5)
	check(count("flicker_sting") == l0 + 1, "S9 exactly one sting for the whole event (%d), not one per dip" % (count("flicker_sting") - l0))
	amb().start_lights_event()
	check(await heard_after("flicker_sting", l0 + 1, 1.0), "S9 the next event gets its own sting")
	await wait_until(func(): return not amb().event_playing(), 15.0)

	# S10 the manager: whistle as he starts watching me, a tweet at "!", the
	# trombone at the write-up.
	pin_manager(Vector2(480, 1350), 0.0)
	var w0 := count("manager_whistle")
	var tw0 := count("manager_tweet")
	var wu0 := count("writeup")
	player().teleport_to(Vector2(640, 1350))
	check(await heard_after("manager_whistle", w0, 4.0), "S10 whistle as the manager's meter starts on me")
	check(await heard_after("manager_tweet", tw0, 4.0), "S10 tweet as it goes red")
	check(await heard_after("writeup", wu0, 5.0), "S10 sad trombone at the write-up")
	check(count("manager_whistle") == w0 + 1, "S10 one whistle for one stare-down (%d)" % (count("manager_whistle") - w0))
	player().teleport_to(Vector2(1440, 810))
	main.manager._pause_timer = 1.0e9

	# S11 both forklifts: each engine starts once and keeps running, the
	# reverse beeper ticks along with its label.
	var starts0: int = main.sound_director.engine_starts_of(main.forklift)
	main.forklift._pause_timer = 0.0
	var b0 := count("forklift_beep") + count("forklift_alert")
	var beep_log0 := heard.size()
	await wait(24.0)
	var engines: Array = [main.forklift, main.delivery_forklift].map(func(f): return main.sound_director._forklifts[f]["engine"])
	check(engines.all(func(e): return e != null and e.playing), "S11 both forklift engines running")
	check(starts0 == 1 and main.sound_director.engine_starts_of(main.forklift) == starts0, "S11 the Produce forklift's engine started once (at opening) and never restarted over 24s of patrol (%d starts)" % main.sound_director.engine_starts_of(main.forklift))
	var beeps := count("forklift_beep") + count("forklift_alert") - b0
	check(beeps > 0, "S11 reverse beeper / ram alarm heard: %d in 24s" % beeps)
	check(peak_rate(heard.slice(beep_log0), "forklift_beep") <= 4, "S11 beeper never more than 4/s")
	print("FORKLIFT  rams today: %d, beeps %d, alerts %d" % [main.forklift.rams_today, count("forklift_beep"), count("forklift_alert")])
	main.forklift._pause_timer = 1.0e9
	# A wreck (forced, so the test doesn't wait on the patrol's ram leg).
	var shelf_body: Node = main.shelves.filter(func(s): return main.is_unlocked_at_pos(s.global_position) and not s.get_node("Shelf").wrecked)[0]
	var ram0 := count("forklift_ram")
	var col0 := count("stack_collapse")
	shelf_body.get_node("Shelf").wreck(shelf_body.global_position + Vector2(0, 80))
	check(await heard_after("forklift_ram", ram0) and await heard_after("stack_collapse", col0), "S11 crash + stack collapse when a shelf is wrecked")
	var bonk0 := count("forklift_bonk")
	player().forklift_hit(player().global_position + Vector2(40, 0))
	check(await heard_after("forklift_bonk", bonk0), "S11 cartoon bonk when the forklift clips me")

	# S12 a floor display going over.
	# One the forklift hasn't already knocked over during S11.
	# If the forklift toppled BOTH during S11, stand one back up first —
	# indexing an empty filter() threw here, the coroutine died, and the run
	# sat until the suite's 75-minute timeout instead of failing.
	var displays: Array = main.displays.map(func(d): return d.get_node("Display"))
	var upright: Array = displays.filter(func(d): return not d.toppled)
	if upright.is_empty() and not displays.is_empty():
		print("INFO  S12 the forklift toppled every floor display during S11; standing one back up")
		displays[0].reset_to_home()
		await wait(0.3)
		upright = displays.filter(func(d): return not d.toppled)
	check(not upright.is_empty(), "S12 an upright floor display to knock over (%d displays)" % displays.size())
	if not upright.is_empty():
		var g0 := count("glass_break")
		upright[0].toppled = true
		check(await heard_after("glass_break", g0), "S12 crash as a floor display topples")

	# S13 cleanup: calm music, the mop at work, a chime per mess, clock-out.
	var mess := Vector2(1440, 700)
	var msid: int = amb().spawn_spill(mess, 40.0)
	await wait(amb().SPILL_FORM_TIME + 0.2)
	main.shift_time_left = 0.01
	await wait_until(func(): return main.cleanup_active, 3.0)
	await wait(0.3)
	check(sfx.music_track == "prep", "S13 cleanup: calm music again ('%s')" % sfx.music_track)
	var cl: Node = main.cleanup
	var tools: Array = cl.tools.duplicate(true)
	tools[0]["holder"] = 1
	cl.tools = tools
	player().teleport_to(mess - Vector2(70, 0))
	await wait(0.2)
	steer(Vector2.RIGHT)
	await wait(0.12)
	steer(Vector2.ZERO)
	player().teleport_to(mess - Vector2(30, 0))
	await wait(0.2)
	var m0 := count("mop")
	var ch0 := count("clean_chime") + count("all_clean")
	var mop_log0 := heard.size()
	press(act + "place")
	await wait_until(func(): return not amb().spills.any(func(s): return s["id"] == msid), 6.0)
	await wait(0.6)
	press(act + "place", 0.0)
	var mops := count("mop") - m0
	check(mops >= 2, "S13 mop swishes while scrubbing: %d" % mops)
	check(peak_rate(heard.slice(mop_log0), "mop") <= 3, "S13 swishes paced (<=3/s)")
	check(count("clean_chime") + count("all_clean") > ch0, "S13 chime when the spill is mopped up")
	var co0 := count("clock_out")
	var pay0 := count("paycheck")
	main.clock_out(1)
	check(await heard_after("clock_out", co0), "S13 time clock 'ka-chunk' at clock-out")
	check(await heard_after("paycheck", pay0, 2.0), "S13 paycheck cha-ching on the report")
	await wait(0.5)
	check(sfx.music_track == "prep", "S13 report: calm music ('%s')" % sfx.music_track)
	check(sfx.music_starts <= 4, "S13 music (re)started only on phase changes: %d starts" % sfx.music_starts)

	spam_check(heard, "solo run")
	check(sfx.missing.is_empty(), "no missing audio")
	finish()

## --- co-op -------------------------------------------------------------------------

## World sounds every peer must hear, as the host triggers them, in order.
## Each: [label, sound the host expects on every peer].
func _run_net_host() -> void:
	var want := 2
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--players="):
			want = int(a.substr(10))
	DirAccess.make_dir_recursive_absolute(NET_DIR)
	for f in DirAccess.get_files_at(NET_DIR):
		DirAccess.remove_absolute(NET_DIR + f)
	await wait_until(func(): return main.shift_active and main.players.size() >= want, 40.0)
	check(main.players.size() == want, "net: %d players connected" % main.players.size())
	park_everything()
	await wait(2.5) # every client past its warm-up
	var ids: Array = main.players.keys()
	ids.sort()
	var clients: Array = ids.filter(func(id): return id != 1)
	var events := [] # [label, sound, host unix time]

	# Everyone into the hub (one room: every positional sound within earshot).
	for k in ids.size():
		main.players[ids[k]].rpc("teleport_to", Vector2(1300 + 70 * k, 760))
	await wait(0.6)

	# `sound` may be "a|b": whichever of them the host plays.
	var host_event := func(label: String, sound: String, trigger: Callable, timeout := 3.0) -> void:
		var options := sound.split("|")
		var start := heard.size()
		trigger.call()
		var ok := await wait_until(func(): return heard.slice(start).any(func(h): return h[1] in options), timeout)
		var got := ""
		var at := -1.0
		for h in heard.slice(start):
			if h[1] in options and got == "":
				got = h[1]
				at = h[0]
		check(ok, "N %s: host played %s" % [label, got if got != "" else sound])
		events.append([label, got, at])
		await wait(1.2)

	await host_event.call("store open", "store_open", func(): main.open_store(1); main.forklift._pause_timer = 1.0e9)
	await host_event.call("spill", "spill_splat", func(): amb().spawn_spill(Vector2(1440, 640), 40.0))
	await host_event.call("lights", "flicker_sting", func(): amb().start_lights_event())
	await host_event.call("order called", "order_chime", func(): main._issue_priority_order())
	await host_event.call("order filled", "order_filled", func(): main._close_priority_order(true))
	await host_event.call("sale", "register_ding", func():
		var c: Node = main.cashiers.filter(func(x): return x.get_node("Cashier").active)[0]
		c.get_node("Cashier")._complete_purchase(free_product(), 0))
	await host_event.call("shelf wreck", "stack_collapse", func():
		var s: Node = main.shelves.filter(func(x): return main.is_unlocked_at_pos(x.global_position) and not x.get_node("Shelf").wrecked)[0]
		s.get_node("Shelf").wreck(s.global_position + Vector2(0, 80)))
	await host_event.call("impact", "impact_heavy|impact_light", func():
		var o := free_product()
		move_body(o, Vector2(1440, 160))
		o.linear_velocity = Vector2(0, -620)) # a throw's speed, straight into Dry Goods' back wall
	var target: int = clients[0]
	await host_event.call("forklift bump", "forklift_bonk", func(): main.players[target].rpc("forklift_hit", main.players[target].global_position + Vector2(40, 0)))

	# Shelf place: an item settling into a slot on the host's physics.
	var placed := false
	for shelf_body in main.shelves:
		if placed or not main.is_unlocked_at_pos(shelf_body.global_position) or shelf_body.get_node("Shelf").wrecked:
			continue
		var shelf: Node = shelf_body.get_node("Shelf")
		var color: Color = main.SECTION_COLORS[main._section_name_at(shelf_body.global_position)]
		for i in shelf.slots.size():
			var item := free_product(color)
			if shelf._is_filled(i) or item == null:
				continue
			await host_event.call("shelf place", "place_shelf", func(): move_body(item, shelf.slots[i].global_position))
			placed = true
			break

	# The manager stares down one client: that client hears the whistle up
	# close, everyone else (host too) a distant one; all hear the write-up.
	var watched: int = clients[-1]
	pin_manager(Vector2(480, 1350), 0.0)
	main.players[watched].rpc("teleport_to", Vector2(640, 1350))
	var wf0 := count("manager_whistle_far")
	await wait_until(func(): return count("manager_whistle_far") > wf0, 5.0)
	var whistle_at := Time.get_unix_time_from_system()
	await host_event.call("write-up", "writeup", func(): pass, 6.0)
	main.manager._pause_timer = 1.0e9
	main.players[watched].rpc("teleport_to", Vector2(1440, 900))
	await wait(0.5)

	# Local-only sounds: one client walks and picks up/throws; nobody else
	# may hear its footsteps or its pickup.
	var mover: int = clients[0]
	var obj := free_product()
	move_body(obj, main.players[mover].global_position + Vector2(42, 0))
	await wait(0.3)
	var host_steps0 := count("footstep")
	var host_pick0 := count("pickup") + count("throw")
	var local_t0 := Time.get_unix_time_from_system()
	_net_write("mover.json", {"peer": mover, "obj": String(obj.name)})
	var mres := await _net_read("mover_done.json", 20.0)
	var local_t1 := Time.get_unix_time_from_system()
	check(not mres.is_empty(), "N local: the mover reported back")
	check(count("footstep") == host_steps0 and count("pickup") + count("throw") == host_pick0, "N local: the host played none of the mover's footsteps/pickup/throw")

	# Forklift running for a while: every peer's engine on, beeps similar.
	var produce_starts0: int = main.sound_director.engine_starts_of(main.forklift)
	main.forklift._pause_timer = 0.0
	var beep_t0 := Time.get_unix_time_from_system()
	await wait(14.0)
	var beep_t1 := Time.get_unix_time_from_system()
	_net_write("snap.json", {"go": true})
	var host_engine: bool = main.sound_director._forklifts[main.forklift]["engine"].playing
	var produce_starts: int = main.sound_director.engine_starts_of(main.forklift) - produce_starts0
	check(host_engine and produce_starts == 0, "N forklift: host engine running since the store opened, restarted %d time(s) over 14s of patrol" % produce_starts)
	main.forklift._pause_timer = 1.0e9
	await wait(0.5)

	# Cleanup and clock-out (no messes to score: straight through).
	main.shift_time_left = 0.01
	await wait_until(func(): return main.cleanup_active, 3.0)
	await wait(1.0)
	await host_event.call("clock out", "clock_out", func(): main.clock_out(1))
	await wait(1.0)
	_net_write("done.json", {"go": true})

	# Every client's log against the host's events.
	var host_beeps := heard.filter(func(h): return h[1] in ["forklift_beep", "forklift_alert"] and h[0] >= beep_t0 and h[0] <= beep_t1).size()
	for id in clients:
		var r := await _net_read("log_%d.json" % id, 30.0)
		var log: Array = r.get("heard", [])
		check(not log.is_empty(), "N %d: client log received (%d plays)" % [id, log.size()])
		for e in events:
			var near := log.filter(func(h): return h[1] == e[1] and h[0] >= e[2] - 0.4 and h[0] <= e[2] + 1.0)
			var lag: float = (near[0][0] - e[2]) if not near.is_empty() else 99.0
			check(not near.is_empty(), "N %s: client %d heard %s too (%+.2fs vs host)" % [e[0], id, e[1], lag])
		var whistle := "manager_whistle" if id == watched else "manager_whistle_far"
		check(log.any(func(h): return h[1] == whistle and absf(h[0] - whistle_at) < 2.5), "N manager: client %d heard the %s whistle (%s)" % [id, "close" if id == watched else "distant", "the one he watched" if id == watched else "a bystander"])
		check(not log.any(func(h): return h[1] == ("manager_whistle_far" if id == watched else "manager_whistle") and absf(h[0] - whistle_at) < 2.5), "N manager: client %d did NOT get the other variant" % id)
		var steps := log.filter(func(h): return h[1] == "footstep" and h[0] >= local_t0 and h[0] <= local_t1).size()
		var picks := log.filter(func(h): return h[1] in ["pickup", "throw"] and h[0] >= local_t0 and h[0] <= local_t1).size()
		if id == mover:
			check(steps >= 4 and picks >= 2, "N local: the mover (client %d) heard its own %d footsteps and pickup+throw (%d)" % [id, steps, picks])
		else:
			check(steps == 0 and picks == 0, "N local: client %d heard none of the mover's footsteps/pickup (%d/%d)" % [id, steps, picks])
		var beeps := log.filter(func(h): return h[1] in ["forklift_beep", "forklift_alert"] and h[0] >= beep_t0 and h[0] <= beep_t1).size()
		check(host_beeps > 0 and absi(beeps - host_beeps) <= maxi(2, host_beeps / 3), "N forklift: client %d beeps %d vs host %d over the same 14s" % [id, beeps, host_beeps])
		var snap: Dictionary = r.get("snap", {})
		check(snap.get("engine", false) and int(snap.get("starts", 99)) == 1, "N forklift: client %d Produce-forklift engine running, started exactly once all shift (%s)" % [id, str(snap.get("starts"))])
		check(snap.get("music", "") == "selling", "N music: client %d on the selling track while open ('%s')" % [id, snap.get("music", "")])
		check(r.get("music_end", "") == "prep", "N music: client %d back on the calm track for the report ('%s')" % [id, r.get("music_end", "")])
		check(r.get("missing", ["?"]).is_empty(), "N client %d: no missing audio" % id)
		check(r.get("spam_ok", false), "N client %d: no sound over its per-second ceiling %s" % [id, str(r.get("rates", {}))])
		check(r.get("fanfare_ok", false), "N client %d: fanfare iff it saw the FINAL SHIFT banner (%s)" % [id, str(r.get("fanfare", ""))])
	spam_check(heard, "host")
	finish()

func _run_net_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 20.0)
	me = main.multiplayer.get_unique_id()
	act = "client_"
	var banner_seen := false
	var deadline := Time.get_ticks_msec() + 240000
	var snap := {}
	var moved := false
	while Time.get_ticks_msec() < deadline:
		banner_seen = banner_seen or main._finale_banner.visible
		if not moved:
			var mv := _net_peek("mover.json")
			if int(mv.get("peer", 0)) == me:
				moved = true
				await _client_move(String(mv.get("obj", "")))
				_net_write("mover_done.json", {"ok": true})
		if snap.is_empty() and FileAccess.file_exists(NET_DIR + "snap.json"):
			snap = {"engine": main.sound_director._forklifts[main.forklift]["engine"].playing, "starts": main.sound_director.engine_starts_of(main.forklift), "music": sfx.music_track}
		if FileAccess.file_exists(NET_DIR + "done.json"):
			break
		await process_frame
	await wait(0.5)
	var rates := {}
	var spam_ok := true
	var limits := {"footstep": 5, "register_ding": 8, "impact_light": 12, "impact_heavy": 12, "box_thud": 12, "forklift_beep": 4, "forklift_alert": 4, "place_shelf": 8}
	for h in heard:
		if not rates.has(h[1]):
			rates[h[1]] = peak_rate(heard, h[1])
			spam_ok = spam_ok and rates[h[1]] <= limits.get(h[1], 3)
	var fanfare := count("final_shift")
	_net_write("log_%d.json" % me, {"heard": heard, "snap": snap, "music_end": sfx.music_track, "missing": sfx.missing, "rates": rates, "spam_ok": spam_ok, "fanfare": "%d plays, banner %s" % [fanfare, "seen" if banner_seen else "not seen"], "fanfare_ok": fanfare == (1 if banner_seen else 0)})
	print("SOUNDS  client %d: %s" % [me, str(_sorted_counts())])
	_release_all()
	quit(0)

## This client walks 2s and picks up + throws the item the host put by it.
func _client_move(obj_name: String) -> void:
	var obj: Node = null
	for o in get_nodes_in_group("carryable"):
		if String(o.name) == obj_name:
			obj = o
	if obj:
		obj.get_node("Carryable").try_pickup(me, player().global_position)
		await wait(0.5)
	steer(Vector2.RIGHT)
	await wait(2.0)
	steer(Vector2.ZERO)
	if obj and obj.get_node("Carryable").carrier_id == me:
		obj.get_node("Carryable").try_throw(me, Vector2.RIGHT)
	await wait(0.8)

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
