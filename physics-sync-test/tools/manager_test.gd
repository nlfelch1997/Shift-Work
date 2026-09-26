extends SceneTree
## WEEK 9 test harness for the manager (Manager.gd). Loads the real
## Main.tscn, lets Main.gd parse the same CLI flags a normal run does, then
## drives scripted scenarios through the real game code — no mocks — and
## prints PASS/FAIL lines. Not part of the game; nothing loads this unless
## it's launched with --script.
##
## Host, single process (day gating, catch sequence, exemptions, chaos,
## report, day rollover):
##   godot --headless --path . --script res://tools/manager_test.gd -- --server --day=3 --shift-seconds=6 --test=host
## Same, rendering real frames to PNGs under user://manager_shots/ (needs a
## display — e.g. xvfb-run — and no --headless):
##   xvfb-run -a godot --path . --script res://tools/manager_test.gd -- --server --day=3 --shift-seconds=6 --test=host --shots
## Host + client over real ENet (run both; the client gets caught):
##   godot --headless --path . --script res://tools/manager_test.gd -- --server --day=4 --shift-seconds=40 --test=net-host
##   godot --headless --path . --script res://tools/manager_test.gd -- --client --test=net-client

var main: Node
var fails := 0
var shots := false
var shot_index := 0

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	shots = "--shots" in args and DisplayServer.get_name() != "headless"
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	var mode := "host"
	for a in args:
		if a.begins_with("--test="):
			mode = a.substr(7)
	match mode:
		"host":
			_run_host.call_deferred()
		"net-host":
			_run_net_host.call_deferred()
		"net-client":
			_run_net_client.call_deferred()

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

func shot(name: String) -> void:
	if not shots:
		return
	await process_frame
	await process_frame
	DirAccess.make_dir_recursive_absolute("user://manager_shots")
	var path := "user://manager_shots/%02d_%s.png" % [shot_index, name]
	shot_index += 1
	root.get_texture().get_image().save_png(path)
	print("SHOT  " + ProjectSettings.globalize_path(path))

func mgr() -> Node2D:
	return main.manager

## Freeze his patrol for a scenario that needs him still (test-only poke).
func pin_manager(pos: Vector2, heading: float) -> void:
	var m := mgr()
	m.position = pos
	m.target_position = pos
	m.facing = heading
	m._look_heading = heading
	m._pause_timer = 1000.0
	m._legs.clear()

func release_manager() -> void:
	mgr()._pause_timer = 0.0

func player() -> Node2D:
	return main.players[1]

func place_player(pos: Vector2) -> void:
	player().teleport_to(pos)

## A product that's free AND at rest — not the one just thrown (still
## flying), which a direct position write doesn't reliably move.
func free_product() -> Node2D:
	for obj in get_nodes_in_group("carryable"):
		if obj.get_node("Carryable").carrier_id == 0 and obj.linear_velocity.length() < 5.0:
			return obj
	return null

## Returns the product only if the pickup actually went through.
func pickup_near_player() -> Node2D:
	var obj := free_product()
	if obj == null:
		return null
	var pos := player().global_position + Vector2(24, 0)
	PhysicsServer2D.body_set_state(obj.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, Transform2D(0.0, pos))
	PhysicsServer2D.body_set_state(obj.get_rid(), PhysicsServer2D.BODY_STATE_LINEAR_VELOCITY, Vector2.ZERO)
	obj.global_position = pos
	await physics_frame
	await physics_frame
	obj.get_node("Carryable").try_pickup(1, player().global_position)
	await physics_frame
	return obj if obj.get_node("Carryable").carrier_id == 1 else null

## ---------------------------------------------------------------------------

func _run_host() -> void:
	# ---- Day 3: manager must be OFF.
	await wait_until(func(): return main.shift_active, 10.0)
	check(main.current_day == 3, "started on Day 3")
	check(not mgr().active and not mgr().visible, "Day 3: manager inactive and hidden")
	place_player(Vector2(1440, 1000)) # idle, in open hub floor
	await wait_until(func(): return main.is_day_report_active(), 30.0)
	check(main.writeups_today == 0, "Day 3: nobody written up while idle all shift")
	await process_frame
	check(not main.report_writeup_label.visible, "Day 3 report: write-up line hidden")
	check(main.report_pay_label.text.begins_with("Pay Today: "), "Day 3 report: pay line present (%s)" % main.report_pay_label.text)
	await shot("day3_report")

	# ---- Day 4: manager ON. Long day so every scenario fits.
	main.shift_duration = 200.0
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active, 5.0)
	check(main.current_day == 4, "advanced to Day 4")
	check(mgr().active and mgr().visible, "Day 4: manager active and visible")
	var visited := {}
	var track := func():
		visited[main._grid_cell_of(mgr().global_position)] = true
	# T1: idle in plain view -> "?" -> "!" -> caught.
	await physics_frame
	place_player(Vector2(1440, 1000))
	var t0 := Time.get_ticks_msec()
	var got_watch := await wait_until(func(): return mgr().watch_peer == 1 and mgr().watch_level > 0.05, 6.0)
	check(got_watch, "T1: manager starts watching the idle player")
	var t_watch := (Time.get_ticks_msec() - t0) / 1000.0
	check(main._watch_label.visible and main._watch_label.text.begins_with("The manager is looking"), "T1: early warning on the watched player's screen: '%s'" % main._watch_label.text)
	await shot("t1_question")
	var got_hot := await wait_until(func(): return mgr().watch_level >= 0.5, 3.0)
	check(got_hot, "T1: escalates to '!' stage")
	check(main._watch_label.text.begins_with("MANAGER IS WATCHING"), "T1: hot warning text: '%s'" % main._watch_label.text)
	check(mgr().get_node("AlertLabel").text == "!", "T1: '!' over the manager")
	await shot("t1_bang")
	var caught := await wait_until(func(): return main.writeups_today == 1, 4.0)
	var t_caught := (Time.get_ticks_msec() - t0) / 1000.0
	check(caught, "T1: write-up lands (watch began %.1fs after going idle, caught at %.1fs)" % [t_watch, t_caught])
	check(t_caught - t_watch >= 2.0, "T1: warning window before the catch was %.1fs (>= 2s, reactable)" % (t_caught - t_watch))
	await process_frame
	check(main._toast_label.visible and main._toast_label.text.begins_with("WRITTEN UP for standing around"), "T1: toast: '%s'" % main._toast_label.text)
	check(main.writeups_by_peer.get(1, 0) == 1, "T1: write-up attributed to player 1")
	await shot("t1_writeup")

	# T2: cooldown, then react to the warning by getting moving -> no write-up.
	await wait(1.0)
	check(mgr().watch_level == 0.0 or mgr().watch_peer == 0, "T2: meter reset after the catch (cooldown)")
	var rewatch := await wait_until(func(): return mgr().watch_peer == 1 and mgr().watch_level >= 0.6, 16.0)
	check(rewatch, "T2: after the cooldown he's on the same idle player again (level %.2f)" % mgr().watch_level)
	var peak: float = mgr().watch_level
	var base := player().position
	for i in 240: # 4s of walking back and forth
		player().position = base + Vector2(sin(i / 12.0) * 60.0, 0)
		await physics_frame
		track.call()
	check(main.writeups_today == 1, "T2: started moving at %.0f%% — no second write-up" % (peak * 100.0))
	check(mgr().watch_level < 0.05, "T2: meter drained to %.2f once busy" % mgr().watch_level)

	# T3: carrying = busy, even standing still in full view.
	var carried: Node2D = await pickup_near_player()
	check(carried != null and carried.get_node("Carryable").carrier_id == 1, "T3: player is carrying %s" % (carried.name if carried else "nothing"))
	pin_manager(player().global_position + Vector2(0, -160), PI * 0.5)
	await wait(5.0)
	check(main.writeups_today == 1 and mgr().watch_level == 0.0, "T3: carrying + still for 5s in view: not watched (level %.2f)" % mgr().watch_level)
	carried.get_node("Carryable").try_drop(1)
	await physics_frame

	# T4: standing at an active register = busy.
	var reg: Node2D = main.cashiers[0]
	check(reg.get_node("Cashier").active, "T4: %s is active on Day 4" % reg.name)
	place_player(reg.global_position + Vector2(0, -55))
	pin_manager(reg.global_position + Vector2(0, -220), PI * 0.5)
	await wait(5.0)
	check(main.writeups_today == 1 and mgr().watch_level == 0.0, "T4: idle at a register for 5s in view: not watched (level %.2f)" % mgr().watch_level)

	# T5: line of sight — a shelf between them hides you.
	var shelf: Node2D = null
	for s in main.shelves:
		if main._grid_cell_of(s.global_position) == Vector2i(1, 0): # Dry Goods, unlocked
			shelf = s
			break
	var sc: Vector2 = shelf.get_node("CollisionShape2D").global_position
	var hide_side := (sc - Vector2(1440, 270)).normalized() # behind the shelf, away from the aisle
	place_player(sc + Vector2(signf(hide_side.x), 0) * 60.0)
	pin_manager(sc - Vector2(signf(hide_side.x), 0) * 160.0, (Vector2(signf(hide_side.x), 0)).angle())
	await wait(5.0)
	check(main.writeups_today == 1 and mgr().watch_level == 0.0, "T5: idle BEHIND %s for 5s: shelf blocks his view (level %.2f)" % [shelf.name, mgr().watch_level])

	# T6: chaos. One throw while moving -> warning but no write-up; repeated throws -> write-up.
	place_player(Vector2(1440, 1000))
	await physics_frame
	pin_manager(Vector2(1440, 800), PI * 0.5)
	var t_chaos_peak := 0.0
	base = Vector2(1440, 1000)
	var obj: Node2D = await pickup_near_player()
	obj.get_node("Carryable").try_throw(1, Vector2.RIGHT)
	for i in 240:
		player().position = base + Vector2(sin(i / 12.0) * 50.0, 0)
		t_chaos_peak = maxf(t_chaos_peak, mgr().watch_level)
		await physics_frame
	check(t_chaos_peak >= 0.5 and main.writeups_today == 1, "T6a: one throw in view while moving -> peaked at %.0f%% ('!' warning), no write-up" % (t_chaos_peak * 100.0))
	var caught_chaos := false
	var throws := 0
	for n in 8:
		obj = await pickup_near_player()
		if obj:
			obj.get_node("Carryable").try_throw(1, Vector2.RIGHT)
			throws += 1
		for i in 36:
			player().position = base + Vector2(sin((n * 36 + i) / 12.0) * 50.0, 0)
			await physics_frame
		if main.writeups_today == 2:
			caught_chaos = true
			break
	check(caught_chaos, "T6b: repeated throwing in view (while moving) -> written up after %d throws" % throws)
	check(main._toast_label.text.contains("throwing stock"), "T6b: toast names the reason: '%s'" % main._toast_label.text)

	# T7: shoving a display = chaos (host's own push path in Player.gd).
	release_manager()
	var display: Node2D = main.displays[0]
	var disp_state: Dictionary = mgr()._player_state(1)
	var before: float = disp_state["last_chaos"]
	place_player(display.global_position + Vector2(-40, 0))
	for i in 20:
		player().velocity = Vector2(220, 0)
		player().move_and_slide()
		player()._push_rigid_bodies(1.0 / 60.0)
		await physics_frame
	check(disp_state["last_chaos"] > before and disp_state.get("chaos_what", "") == "knocking over a display", "T7: walking into a display registers as chaos ('%s')" % disp_state.get("chaos_what", ""))

	# Patrol coverage: let him walk freely for a while with the player moving.
	var cov_start := Time.get_ticks_msec()
	place_player(Vector2(480, 270)) # break room, out of his way
	while (Time.get_ticks_msec() - cov_start) < 90000 and not (visited.has(Vector2i(1, 0)) and visited.has(Vector2i(2, 1))):
		await physics_frame
		track.call()
	check(visited.has(Vector2i(1, 1)), "patrol: visited the hub")
	check(visited.has(Vector2i(1, 0)) and visited.has(Vector2i(2, 1)), "patrol: visited both Day-4 sections (Dry Goods, Meat/Deli): %s" % str(visited.keys()))
	check(not visited.has(Vector2i(0, 1)) and not visited.has(Vector2i(2, 0)), "patrol: never entered locked Dairy/Frozen or Bakery")

	# Report.
	main.shift_time_left = 0.1
	await wait_until(func(): return main.is_day_report_active(), 3.0)
	# Main._process fills the report labels on the frame AFTER it raises the
	# flag (the clock check sits below the report block), so give it a beat.
	await wait(0.2)
	var sold: int = main._total_sold() - main._sold_at_day_start
	var expect_pay: int = sold * main.PAY_PER_SALE - 2 * main.WRITEUP_PENALTY
	print("REPORT  %s | %s | %s | %s" % [main.report_today_label.text, main.report_week_label.text, main.report_writeup_label.text, main.report_pay_label.text])
	check(main.report_writeup_label.visible, "Day 4 report: write-up line visible")
	check(main.report_writeup_label.text.begins_with("Write-ups: 2  ($50 docked)  —  Host x2"), "Day 4 report: '%s'" % main.report_writeup_label.text)
	check(main.report_pay_label.text.begins_with("Pay Today: %s" % main._format_money(expect_pay)), "Day 4 report: pay = %d sold x $%d - 2 x $%d = %s ('%s')" % [sold, main.PAY_PER_SALE, main.WRITEUP_PENALTY, main._format_money(expect_pay), main.report_pay_label.text])
	check(not main._watch_label.visible and not main._toast_label.visible, "Day 4 report: warning/toast hidden under the report")
	await shot("day4_report")

	# Day 5: counters roll over, week total keeps them, manager still on.
	main._on_continue_pressed()
	await wait_until(func(): return main.shift_active, 5.0)
	check(main.current_day == 5 and mgr().active, "Day 5: manager still active")
	check(main.writeups_today == 0 and main.writeups_week == 2 and main.writeups_by_peer.is_empty(), "Day 5: today's write-ups reset, week keeps 2")
	# Route derivation for a section that isn't off the hub (Bakery, Day 7) —
	# checked by evaluating the path with the day bumped for one call.
	var real_day: int = main.current_day
	main.current_day = 7
	var bakery_path: Array = mgr()._cell_path(main, Vector2i(2, 0))
	var dairy_path: Array = mgr()._cell_path(main, Vector2i(0, 1))
	main.current_day = real_day
	check(bakery_path == [Vector2i(1, 0), Vector2i(2, 0)], "route: Bakery reached through Dry Goods %s" % str(bakery_path))
	check(dairy_path == [Vector2i(0, 1)], "route: Dairy/Frozen straight off the hub %s" % str(dairy_path))
	finish()

## ---------------------------------------------------------------------------

func _run_net_host() -> void:
	await wait_until(func(): return main.players.size() >= 2, 15.0)
	check(main.players.size() >= 2, "net: client connected")
	await wait_until(func(): return main.writeups_today >= 1, 40.0)
	var client_id := 0
	for id in main.writeups_by_peer:
		if id != 1:
			client_id = id
	check(client_id != 0, "net: host wrote up the CLIENT's player (peer %d) — detection works on a client-authoritative player" % client_id)
	check(not main.writeups_by_peer.has(1), "net: host's own player (idle in the break room) wasn't written up")
	await wait(2.0)
	main.shift_time_left = 0.1
	await wait(6.0) # give the client time to read the report
	finish()

func _run_net_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()), 15.0)
	var me: int = main.multiplayer.get_unique_id()
	await wait_until(func(): return main.shift_active and main.current_day == 4, 15.0)
	check(mgr().active and mgr().visible, "net client: manager active on Day 4 (replicated day)")
	await wait(1.0)
	main.players[me].teleport_to(Vector2(1440, 1000))
	var saw_warning := await wait_until(func(): return main._watch_label.visible, 20.0)
	check(saw_warning, "net client: saw the LOOK BUSY warning on my own screen ('%s')" % main._watch_label.text)
	var saw_bang := await wait_until(func(): return mgr().get_node("AlertLabel").visible and mgr().get_node("AlertLabel").text == "!", 5.0)
	check(saw_bang, "net client: saw the replicated '!' over the manager")
	var got := await wait_until(func(): return main.writeups_today == 1, 10.0)
	check(got and main.writeups_by_peer.get(me, 0) == 1, "net client: replicated write-up counted against me (%s)" % str(main.writeups_by_peer))
	check(main._toast_label.visible and main._toast_label.text.begins_with("WRITTEN UP"), "net client: toast '%s'" % main._toast_label.text)
	await wait_until(func(): return main.is_day_report_active(), 15.0)
	await wait(0.5)
	print("CLIENT REPORT  %s | %s" % [main.report_writeup_label.text, main.report_pay_label.text])
	check(main.report_writeup_label.text.begins_with("Write-ups: 1  ($25 docked)  —  %s x1" % main.player_display_name(me)), "net client report: '%s'" % main.report_writeup_label.text)
	finish()
