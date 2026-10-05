extends "res://tools/hazards_test.gd"
## OCT 2026 SECOND OUTSIDE PLAYTEST — regression tests for the movement bugs
## from the second outside playtest. Reuses tools/hazards_test.gd's helpers and
## drives the real Main.tscn with real key presses (Input actions), so the
## player moves through the same move_and_slide() a person's does. Real
## wall-clock time (no --fixed-fps). Not part of the game.
##
## RIDE ("pushing an object toward the bottom of the screen lets me ride it
## and sends me and the object flying"; "grabbing items slides me to the
## bottom of the screen"): push every kind of pushable (product, delivery box,
## floor display) in all four directions, into a wall, toward the bottom edge,
## while carrying, and grab mid-push. Neither the player nor the object may
## pass the speed caps below:
##   godot --headless --path . --script res://tools/playtest2_test.gd -- --server --day=5 --no-save --test=ride
## INVISIBLE WALLS ("where the cashiers will be on later days"): at every
## section count (1-4 owned), walk through every register station: an empty
## one must not block, an open one must:
##   godot --headless --path . --script res://tools/playtest2_test.gd -- --server --day=1 --no-save --test=cashier-walls
## Co-op (host + 2 clients; each peer moves its OWN player, client-side, so
## each checks its own movement against its own copy of the world):
##   godot ... -- --server --port=8971 --day=5 --players=3 --no-save --test=net-ride &
##   (x2) godot ... -- --client --connect-port=8971 --no-save --test=net-ride

## The caps. A player walks at speed() (220px/s, more with sneakers/coffee);
## per-frame displacement x 60 may overshoot by a frame's jitter, never more.
## A pushed object travels a little ahead of the player that pushes it
## (measured after the fix: <= ~1.3x the walking speed for the lightest item);
## the bug sent player + item off at ~870 / 1200px/s.
const PLAYER_CAP_MULT := 1.15
const OBJECT_CLAMP := 900.0 # Carryable.gd's MAX_SPEED (not preloaded: a SceneTree script can't see its autoloads)
const OBJECT_CAP_MULT := 2.0

var _mode := ""
var worst_player := 0.0
var worst_object := 0.0

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--test="):
			_mode = a.substr(7)
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	main.opening_stock_fraction = 1.0
	main.cleanup_ceiling_override = 0.0
	var client := "--client" in args
	match _mode:
		"ride": _run_ride.call_deferred()
		"cashier-walls": _run_cashier_walls.call_deferred()
		"net-ride": (_run_net_client if client else _run_net_host).call_deferred()
		_:
			print("FAIL  unknown --test=%s" % _mode)
			quit(1)

## --- helpers --------------------------------------------------------------------

func park_world() -> void:
	if main.multiplayer.is_server():
		main.test_hold_customers = true
		main.forklift._pause_timer = 1.0e9
		pin_manager(Vector2(480, 1350), 0.0)
		main._order_timer = 1.0e9
		main.ambience._spill_timer = 1.0e9
		main.ambience._lights_timer = 1.0e9
		for sp in main.ambience.spills.duplicate():
			main.ambience.remove_spill(int(sp["id"]))

## Somewhere loose stock can be pushed from, by kind.
func a_product() -> RigidBody2D:
	for obj in get_nodes_in_group("carryable"):
		if obj.is_in_group("delivery_box") or obj.get_node("Carryable").carrier_id != 0 or obj.is_queued_for_deletion():
			continue
		if not obj.has_meta("p2_used") and not _is_placed(obj) and not obj.get_node("Carryable").shelved:
			obj.set_meta("p2_used", true)
			return obj
	return null

func a_box() -> RigidBody2D:
	var before := get_nodes_in_group("delivery_box").size()
	main.delivery.drop_box(Vector2(1300, 640), "Dry Goods")
	await wait_until(func(): return get_nodes_in_group("delivery_box").size() > before, 2.0)
	var boxes := get_nodes_in_group("delivery_box")
	return boxes[boxes.size() - 1] if boxes.size() > before else null

func a_display() -> RigidBody2D:
	for d in main.displays:
		if not d.get_node("Display").get("toppled"):
			return d
	return main.displays[0] if not main.displays.is_empty() else null

func place(obj: RigidBody2D, pos: Vector2) -> void:
	move_body(obj, pos)
	obj.linear_velocity = Vector2.ZERO
	obj.angular_velocity = 0.0

## Hold `dir` for `seconds` (or until `stop` is true), tracking the player's
## real per-frame movement and `obj`'s speed. Returns [peak player, peak obj].
func hold(dir: Vector2, seconds: float, obj: Node2D = null, stop := Callable()) -> Array:
	steer(dir)
	var prev: Vector2 = player().global_position
	var prev_obj: Vector2 = obj.global_position if obj else Vector2.ZERO
	var peak_p := 0.0
	var peak_o := 0.0
	await physics_frame
	prev = player().global_position
	prev_obj = obj.global_position if obj else Vector2.ZERO
	var t0 := Time.get_ticks_msec()
	var o_start: Vector2 = obj.global_position if obj else Vector2.ZERO
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		var t_frame := Time.get_ticks_msec()
		await physics_frame
		var dt: float = maxf((Time.get_ticks_msec() - t_frame) / 1000.0, 1.0 / 60.0)
		peak_p = maxf(peak_p, (player().global_position - prev).length() / dt)
		prev = player().global_position
		if obj and is_instance_valid(obj):
			# Velocity the physics server has, and how far it actually went
			# (a client's copy is kinematic: its linear_velocity is the host's).
			peak_o = maxf(peak_o, maxf(obj.linear_velocity.length(), (obj.global_position - prev_obj).length() / dt))
			prev_obj = obj.global_position
		if stop.is_valid() and stop.call():
			break
	var secs: float = maxf((Time.get_ticks_msec() - t0) / 1000.0, 1.0 / 60.0)
	steer(Vector2.ZERO)
	await physics_frame
	var travelled: float = obj.global_position.distance_to(o_start) if obj and is_instance_valid(obj) else 0.0
	return [peak_p, peak_o, travelled / secs]

## peaks = hold()'s [peak player, peak object, object's mean speed over the
## push]. A light product is kicked ahead for a frame on first contact (a
## 0.4-mass body taking the push impulse), so the object's PEAK is held to the
## game's own clamp (Carryable.MAX_SPEED) and its SUSTAINED speed to the cap.
func check_caps(label: String, peaks: Array) -> void:
	var cap_p: float = player().speed() * PLAYER_CAP_MULT
	var cap_o: float = player().speed() * OBJECT_CAP_MULT
	worst_player = maxf(worst_player, peaks[0])
	check(peaks[0] <= cap_p, "%s: player never faster than %.0fpx/s (peak %.0f)" % [label, cap_p, peaks[0]])
	if peaks.size() > 2 and peaks[1] >= 0.0:
		worst_object = maxf(worst_object, peaks[2])
		# A client's copy of loose stock is kinematic, chasing the host's
		# position, so its frame-to-frame peak is sync noise: there only the
		# sustained speed is checked.
		var peak_ok: bool = peaks[1] <= OBJECT_CLAMP + 1.0 or not main.multiplayer.is_server()
		check(peaks[2] <= cap_o and peak_ok, "%s: pushed object's speed held: mean %.0fpx/s (cap %.0f), peak %.0f (clamp %.0f%s)" % [label, peaks[2], cap_o, peaks[1], OBJECT_CLAMP, "" if main.multiplayer.is_server() else ", not checked on a client"])

const DIRS := {"down": Vector2.DOWN, "up": Vector2.UP, "left": Vector2.LEFT, "right": Vector2.RIGHT}
## Open hub floor for a ~1s push each way, one lane per peer (host 0, the
## clients 1 and 2), clear of the register rows (y 890+) and of each other:
## vertical lanes at x 1000 / 1720 / 1820, horizontal ones at y 600 / 680 / 760.
func lane_start(dir_name: String, lane := 0) -> Vector2:
	var vx: float = [1000.0, 1700.0, 1820.0][clampi(lane, 0, 2)]
	var hy: float = [600.0, 680.0, 780.0][clampi(lane, 0, 2)]
	match dir_name: # a client's up and down (left and right) lanes are 50px apart: both its items are out at once
		"down": return Vector2(vx, 560)
		"up": return Vector2(vx + (50.0 if lane > 0 else 0.0), 860)
		"left": return Vector2(1500, hy)
	return Vector2(1100, hy + (50.0 if lane > 0 else 0.0))

## Host: a pushed item goes to a grid on the empty south floor afterwards, so
## no lane is ever cluttered by an earlier case's item.
var _parked := 0
func park(obj: RigidBody2D) -> void:
	if obj == null or not is_instance_valid(obj) or not main.multiplayer.is_server() or obj.get_node_or_null("Carryable") == null and obj.get_node_or_null("Display") == null:
		return
	if obj.get_node_or_null("Carryable") and obj.get_node("Carryable").carrier_id != 0:
		return
	place(obj, Vector2(1400 + (_parked % 12) * 40, 1260 + (_parked / 12) * 40))
	_parked += 1

func push_case(label: String, obj: RigidBody2D, dir_name: String, lane := 0, gap := 32.0) -> void:
	if obj == null:
		check(false, "%s: no object to push" % label)
		return
	var dir: Vector2 = DIRS[dir_name]
	var start := lane_start(dir_name, lane)
	player().teleport_to(start)
	await physics_frame
	place(obj, start + dir * gap)
	await wait(0.25)
	var o0 := obj.global_position
	var peaks: Array = await hold(dir, 1.2, obj)
	check(obj.global_position.distance_to(o0) > 60.0, "%s: the object was actually pushed (%.0fpx)" % [label, obj.global_position.distance_to(o0)])
	check_caps(label, peaks)
	park(obj)
	await wait(0.1)

## --- solo -------------------------------------------------------------------------

func _run_ride() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 15.0)
	me = 1
	act = "host_"
	park_world()
	await wait(0.5)
	await _ride_cases("R")
	print("INFO  worst player %.0fpx/s, worst object %.0fpx/s (player speed %.0f)" % [worst_player, worst_object, player().speed()])
	finish()

func _ride_cases(tag: String) -> void:
	# R1 every pushable kind, every direction.
	var lane := 0
	for dir_name in DIRS:
		await push_case("%s1 product pushed %s" % [tag, dir_name], a_product(), dir_name, lane)
		if main.multiplayer.is_server():
			await push_case("%s1 delivery box pushed %s" % [tag, dir_name], await a_box(), dir_name, lane, 40.0)
			await push_case("%s1 floor display pushed %s" % [tag, dir_name], a_display(), dir_name, lane, 50.0)
	# R2 pushed into the bottom edge of the store and held there: the item
	# wedges, the player stops — nothing launches. Then into a side wall.
	var obj := a_product()
	player().teleport_to(Vector2(1040, 1400))
	await physics_frame
	place(obj, Vector2(1040, 1432))
	await wait(0.2)
	var peaks: Array = await hold(Vector2.DOWN, 2.5, obj)
	check_caps("%s2 product pushed down into the bottom wall and held 2.5s" % tag, peaks)
	check(player().global_position.y < Player_WORLD_BOTTOM() and obj.global_position.y < Player_WORLD_BOTTOM(), "%s2 ...both still inside the store (player y %.0f, item y %.0f)" % [tag, player().global_position.y, obj.global_position.y])
	var p_then := player().global_position
	await wait(0.5)
	check(player().global_position.distance_to(p_then) < 2.0, "%s2 ...and the player stays put after letting go (moved %.1fpx)" % [tag, player().global_position.distance_to(p_then)])
	park(obj)
	obj = a_product()
	player().teleport_to(Vector2(1000, 700))
	await physics_frame
	place(obj, Vector2(968, 700))
	await wait(0.2)
	check_caps("%s2 product pushed left across the hub's west edge for 2s" % tag, await hold(Vector2.LEFT, 2.0, obj))
	park(obj)
	# R3 carrying something while walking another item down the screen.
	var held: RigidBody2D = a_product()
	player().teleport_to(Vector2(1000, 560))
	await physics_frame
	place(held, player().global_position + Vector2(30, 0))
	await wait(0.2)
	held.get_node("Carryable").try_pickup(me, player().global_position)
	await wait_until(func(): return held.get_node("Carryable").carrier_id == me, 2.0)
	check(held.get_node("Carryable").carrier_id == me, "%s3 picked an item up to carry" % tag)
	obj = a_product()
	place(obj, player().global_position + Vector2(0, 32))
	await wait(0.25)
	check_caps("%s3 carrying one item, pushing another down" % tag, await hold(Vector2.DOWN, 1.0, obj))
	held.get_node("Carryable").try_drop(me)
	await wait(0.3)
	park(held)
	park(obj)
	# R4 grab mid-push: walking an item down the screen, grab it (E) and keep
	# walking — the player keeps walking speed, before and after the grab.
	obj = a_product()
	player().teleport_to(Vector2(1000, 560))
	await physics_frame
	place(obj, Vector2(1000, 592))
	await wait(0.25)
	var first: Array = await hold(Vector2.DOWN, 0.3, obj)
	print("INFO  R4 at the grab: item %.0fpx ahead" % obj.global_position.distance_to(player().global_position))
	steer(Vector2.DOWN)
	await tap(act + "interact")
	var after: Array = await hold(Vector2.DOWN, 0.6, null)
	check(obj.get_node("Carryable").carrier_id == me, "%s4 grabbed the item being pushed" % tag)
	check_caps("%s4 grab mid-push (pushing)" % tag, first)
	check_caps("%s4 grab mid-push (carrying on down)" % tag, [after[0]])
	obj.get_node("Carryable").try_drop(me)
	await wait(0.3)
	park(obj)

func Player_WORLD_BOTTOM() -> float:
	return player().WORLD_HEIGHT

## --- cashier stations ------------------------------------------------------------

## Walk down through a station's centre: true if the player got from 60px
## above it to 60px below it (nothing there), false if it stopped them.
func walk_through(body: Node2D) -> bool:
	var top: Vector2 = body.global_position + Vector2(0, -70)
	player().teleport_to(top)
	await physics_frame
	await physics_frame
	await hold(Vector2.DOWN, 1.2, null, func(): return player().global_position.y > body.global_position.y + 60.0)
	return player().global_position.y > body.global_position.y + 60.0

func _cashier_states(tag: String, counts: Array) -> void:
	for owned in counts:
		if main.multiplayer.is_server():
			main.sections_owned = owned
			await wait_until(func(): return main._last_config_key == main._config_key(), 2.0)
		else:
			await wait_until(func(): return main.sections_owned == owned and main._last_config_key == main._config_key(), 10.0)
		await physics_frame
		await physics_frame # the stations' collision flips deferred
		var want: int = main._active_cashier_count()
		var active: int = main.cashiers.filter(func(c): return c.get_node("Cashier").active).size()
		check(active == want, "%s %d section(s) owned: %d register(s) open (expected %d)" % [tag, owned, active, want])
		for c in main.cashiers:
			var on: bool = c.get_node("Cashier").active
			var through: bool = await walk_through(c)
			if on:
				check(not through, "%s %d owned: open register %s still blocks (stopped at y %.0f, desk at %.0f)" % [tag, owned, c.name, player().global_position.y, c.global_position.y])
			else:
				check(through, "%s %d owned: walked straight through empty station %s (got to y %.0f, desk at %.0f)" % [tag, owned, c.name, player().global_position.y, c.global_position.y])

func _run_cashier_walls() -> void:
	await wait_until(func(): return main.shift_active and main.players.has(1), 15.0)
	me = 1
	act = "host_"
	park_world()
	await wait(0.5)
	# Back down after the top tier too: a station that closes stops blocking.
	await _cashier_states("W1", [1, 2, 3, 4, 2, 1])
	finish()

## --- co-op --------------------------------------------------------------------------

func _run_net_host() -> void:
	var want := 3
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--players="):
			want = int(a.substr(10))
	await wait_until(func(): return main.shift_active and main.players.size() >= want, 60.0)
	check(main.players.size() >= want, "NET crew connected (%d/%d)" % [main.players.size(), want])
	me = 1
	act = "host_"
	park_world()
	await wait(1.0)
	# Each client pushes in its own lane, then the host does: never two
	# players in one lane at once.
	for id in main.players.keys():
		if id == 1:
			continue
		_net_write("go_%d" % id, {"go": true})
		var served := 0
		var served_objs: Array = []
		var t0 := Time.get_ticks_msec()
		while not FileAccess.file_exists(NET_DIR + "done_%d" % id) and Time.get_ticks_msec() - t0 < 120000:
			# The host owns loose stock, so it lays out each item the client asks
			# for (a client's copy is kinematic and follows the host's).
			var req_file := NET_DIR + "place_%d_%d" % [id, served]
			var moved_file := NET_DIR + "moved_%d_%d" % [id, served - 1]
			if served > 0 and FileAccess.file_exists(moved_file) and not FileAccess.file_exists(NET_DIR + "snapped_%d_%d" % [id, served - 1]):
				# The client stepped up to its lane: put this host's copy of it
				# straight there too (it would otherwise glide across the hub
				# and could shove the item it's about to push).
				var mv = JSON.parse_string(FileAccess.get_file_as_string(moved_file))
				main.players[id].position = Vector2(mv["x"], mv["y"])
				_net_write("snapped_%d_%d" % [id, served - 1], {"ok": true})
			if FileAccess.file_exists(req_file):
				var req = JSON.parse_string(FileAccess.get_file_as_string(req_file))
				for o in served_objs:
					park(o)
				var obj := a_product()
				served_objs.append(obj)
				place(obj, Vector2(req["x"], req["y"]))
				_net_write("placed_%d_%d" % [id, served], {"name": String(obj.name)})
				served += 1
			await wait(0.1)
		check(FileAccess.file_exists(NET_DIR + "done_%d" % id), "NET client %d finished its push checks (%d items laid out for it)" % [id, served])
		for o in served_objs:
			park(o)
	await _ride_cases("NH")
	# Registers, every peer at once: the host flips the section count, each
	# client walks through every station on its own copy and reports back.
	_net_write("walls", {"go": true})
	for id in main.players.keys():
		if id == 1:
			continue
		await _net_read("walls_ready_%d" % id, 60.0)
	var rounds := [1, 2, 3, 4, 1]
	for k in rounds.size():
		main.sections_owned = rounds[k]
		_net_write("walls_round_%d" % k, {"owned": rounds[k]})
		for id in main.players.keys():
			if id != 1:
				var r := await _net_read("walls_round_%d_done_%d" % [k, id], 90.0)
				check(not r.is_empty(), "NET client %d walked the registers at %d owned" % [id, rounds[k]])
	_net_write("bye", {"bye": true})
	for id in main.players.keys():
		if id != 1:
			await _net_read("bye_%d" % id, 30.0) # each client finishes before the host (and the session) goes
	finish()

func _run_net_client() -> void:
	await wait_until(func(): return root.get_node("Net").is_active() and main.multiplayer.get_unique_id() != 1 and main.players.has(main.multiplayer.get_unique_id()) and main.shift_active, 60.0)
	me = main.multiplayer.get_unique_id()
	act = "client_"
	await _net_read("go_%d" % me, 300.0)
	await wait(0.5)
	# Pushes (products: the host lays each one out where this client asks).
	var ids: Array = main.players.keys().filter(func(i): return i != 1)
	ids.sort()
	var lane: int = 1 + ids.find(me)
	var n := 0
	for dir_name in DIRS:
		var dir: Vector2 = DIRS[dir_name]
		var start := lane_start(dir_name, lane)
		# Out of the way while the item is laid out: this client's copy of it
		# glides in a straight line to its new spot, and if that line crossed
		# this player, the brush would push the host's copy off its mark.
		player().teleport_to(Vector2(1300, 1500))
		await wait(0.5)
		var at := start + dir * 32.0
		_net_write("place_%d_%d" % [me, n], {"x": at.x, "y": at.y})
		var r := await _net_read("placed_%d_%d" % [me, n], 30.0)
		var obj: RigidBody2D = main.find_child(r.get("name", "?"), true, false) as RigidBody2D
		check(obj != null, "NC%d host laid out an item to push %s" % [me, dir_name])
		if obj == null:
			n += 1
			continue
		await wait_until(func(): return obj.global_position.distance_to(at) < 2.0, 3.0)
		player().teleport_to(start)
		await physics_frame
		_net_write("moved_%d_%d" % [me, n], {"x": start.x, "y": start.y})
		await _net_read("snapped_%d_%d" % [me, n], 30.0)
		n += 1
		await wait(0.3)
		check(obj.global_position.distance_to(at) < 6.0, "NC%d ...the item is where it was laid out (%.0fpx off)" % [me, obj.global_position.distance_to(at)])
		var o0 := obj.global_position
		var peaks: Array = await hold(dir, 1.2, obj)
		check(obj.global_position.distance_to(o0) > 60.0, "NC%d product pushed %s: the object was actually pushed (%.0fpx)" % [me, dir_name, obj.global_position.distance_to(o0)])
		check_caps("NC%d product pushed %s" % [me, dir_name], peaks)
	_net_write("done_%d" % me, {"worst_player": worst_player, "worst_object": worst_object})
	print("INFO  client %d worst player %.0fpx/s, worst object %.0fpx/s" % [me, worst_player, worst_object])
	await _net_read("walls", 300.0)
	_net_write("walls_ready_%d" % me, {"ok": true})
	for k in 5:
		var r := await _net_read("walls_round_%d" % k, 120.0)
		await _cashier_states("NW%d" % me, [int(r.get("owned", -1))])
		_net_write("walls_round_%d_done_%d" % [k, me], {"ok": true})
	await _net_read("bye", 60.0)
	_net_write("bye_%d" % me, {"ok": true})
	finish()
