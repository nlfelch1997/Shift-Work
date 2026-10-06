extends "res://Helper.gd"
## OCT 2026 PIVOT, PHASE 4B — THE JANITOR: one hireable staff NPC who keeps the
## WHOLE store clean (Staff.gd owns the hiring, the wage and the board; this is
## the person on the floor). Built in code by Staff.gd on every peer, with an
## explicit name ("Janitor") so its "Sync" matches across peers; hidden until
## someone hires them.
##
## WHY (two reports, one gap): Phase 3D's bot sim found a solo player who
## cleans mid-shift EARNS LESS (stocking is what sells; cleaning time cost
## more than the rating gave back), and Phase 4 found Surprise Inspection and
## Leaky Roof the events a fully staffed crew still has to drop everything
## for. Section helpers don't clean (Phase 3, unchanged): the janitor is the
## hire that does.
##
## WHAT THE JANITOR DOES — three chores, in a fixed order, so it's legible
## (watch them for ten seconds and you can say what they'll do next):
##   1. a BAG in hand goes to the DUMPSTER (Storage, Cleanup.DUMPSTER_POS);
##   2. a FULL CAN anywhere open: walk over, lift its bag out (any trash in
##      hand goes in the bag too), and carry it to the dumpster — a full can
##      is the worst thing on the rating (StoreRating.MESS_FULL_CAN);
##   3. WET MESS — sticky drink puddles and roof leaks (Events.gd): walk to the
##      nearest, mop it (their own mop; the crew's mops stay on the racks). A
##      leak takes LEAK_MOP_TIME — a slow job (see the NUMBERS block);
##   4. LITTER: pick up the nearest piece, then the next nearest, up to
##      HAND_MAX in hand, then into the nearest can with room (each piece pays
##      the crew's usual Cleanup.LITTER_PAY_PER_PIECE as it goes in);
##   5. trash in hand and nothing left on the floor: into the nearest can;
##   6. the stage-4 hazard SPILLS (Ambience.gd), while they count on the
##      rating — LAST: they dry on their own in ~40 s and litter never does.
##      FOUND BY THE INCOME SIMS: with spills ahead of litter, a Day-7
##      janitor spent the whole shift crossing the store to mop spills that
##      were about to dry (5-9 mopped, 0-2 pieces of litter picked up), and
##      the slip hazard — the crew's to dodge — all but went away;
##   7. otherwise wait at home (by the hub's tool rack).
## Displays knocked over and stock knocked off shelves are NOT theirs — the
## crew's mop/hands (cut for simplicity; flagged in the Phase 4B report).
##
## WHERE: STORE-WIDE, unlike a section helper — the hub, every OPEN section,
## and Storage's west end for the dumpster. Paths come from the Phase 3B
## shoppers' grid (CustomerNav.gd), in its own instance with Storage open and
## the delivery forklift's whole working floor (lane, dock, receiving row)
## solid — the dumpster is reached round it, never across it. The Break Room
## and locked sections are never on its grid.
##
## WHY A PLAIN Node2D (NO COLLISION) — the same call as Helper.gd/Manager.gd:
## it walks AROUND shelves, registers, displays, loose stock and the dumpster
## by its path and THROUGH people and carts (customers' carts are drawn, not
## bodies), so there's nothing to wedge on. Customers never target it (not in
## "player"/"customer"), the manager never watches it, a shove can't touch it.
## The two forklifts it simply gives way to: Helper.gd's yield/flee code, fed
## whichever forklift is nearest, with the flee step kept to open floor on the
## grid instead of a room's aisle band.
##
## STUCK DETECTION: on top of a job timeout (JANITOR_JOB_TIMEOUT: a job not
## done in time is dropped), progress along the path is watched — no
## STUCK_PROGRESS px less to walk in STUCK_SECONDS (time spent giving way to a
## moving forklift doesn't count) and the target goes on a cooldown (TARGET_COOLDOWN)
## and another is chosen. A target the grid can't reach (path empty) is
## skipped the same way. `stuck_skips` counts them (the tests read it).
##
## AUTHORITY: the host thinks and moves it; every peer smooths toward the
## replicated target_position and draws what's in their hands from `hand`,
## `bag_n` and `work` (replicated).

## ============================================================================
## NUMBERS — every one a FLAGGED, tunable placeholder (Phase 5 balances). The
## measurements behind them are in Staff.gd's JANITOR block.
## ============================================================================
## Pieces of litter in hand before a trip to a can.
const HAND_MAX := 4
## Seconds of mopping per mess. A player's mop: a puddle 1.2 s, a spill 2.1-
## 2.6 s (Cleanup.gd). The janitor is a little slower at the everyday ones...
const MOP_TIME_PUDDLE := 1.6
const MOP_TIME_SPILL := 3.0
## ...and slow at a roof leak (standing water, not a spilled cup): with three
## leaks across the store, a janitor alone gets to one or two before time's
## up, so a crew member with a mop still decides the event (measured, Staff.gd).
const LEAK_MOP_TIME := 6.0
const PICK_TIME_LITTER := 0.35
const BIN_TIME := 0.5
const BAG_TIME := 1.0
const DUMP_TIME := 0.8
## Reach for each kind of target (from the janitor's centre).
const LITTER_REACH := 22.0
const MOP_REACH := 26.0 # + the mess's radius
const CAN_REACH := 46.0
const DUMPSTER_STAND := Vector2(0.0, -72.0) # north of the dumpster, clear of the receiving row
## Where they wait: the hub, by the tool rack (Cleanup.RACK_POS).
const HOME := Vector2(1760.0, 650.0)
## A job not done in this long is dropped (Helper.gd's JOB_TIMEOUT is one
## room's worth; the hub to the dumpster is ~1500 px at base speed).
const JANITOR_JOB_TIMEOUT := 45.0
## Stuck detection (see the header).
const STUCK_SECONDS := 4.0
const STUCK_PROGRESS := 24.0
const TARGET_COOLDOWN := 15.0
## The forklift that matters is the nearest one within this distance.
const FORKLIFT_WATCH := 320.0
## The janitor's carry_id: no stock is ever theirs (well clear of the helpers'
## -1000000 - index and the customers' -1, -2, ...).
const JANITOR_CARRY_ID := -2000000

## --- Replicated (Sync, host authority) on top of Helper.gd's ---
var hand := 0 # litter pieces in hand
var bag_n := 0 # pieces in the bag they're carrying (0 = no bag)
var work := -1.0 # 0..1 mopping progress (-1 idle)

## --- Host-only ---
var _bag_can := -1 # the can the bag came out of
var _skip := {} # target key -> _clock until which it's passed over
var _best_d := INF # closest we've been to the current goal...
var _best_t := 0.0 # ...and when
var _mop_t := 0.0
## Diagnostics read by the tests (today; reset each shift).
var litter_picked_today := 0
var litter_binned_today := 0
var mopped_today := 0
var leaks_mopped_today := 0
var bags_taken_today := 0
var bags_dumped_today := 0
var stuck_skips := 0
var unreachable_skips := 0

var _hand_node: Node2D
var _bag_node: Node2D
var _mop_node: Node2D

## Staff.gd: like Helper.setup(), with no section.
func setup_janitor(name_text: String, look: String, accent: Color) -> void:
	section = ""
	helper_name = name_text
	carry_id = JANITOR_CARRY_ID
	color = accent
	name = "Janitor"
	_sprite = CharacterSpriteScript.attach(self, look, "facing_angle", accent)
	_tag = _label("", 11, accent.lerp(Color.WHITE, 0.55))
	_tag.position = Vector2(-70, -46)

func _ready() -> void:
	main = get_parent().main
	add_to_group("janitor")
	position = home()
	target_position = position
	visible = false
	set_multiplayer_authority(1)
	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	for prop in [".:target_position", ".:facing_angle", ".:active", ".:status", ".:hand", ".:bag_n", ".:work"]:
		var path := NodePath(prop)
		config.add_property(path)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config
	sync.name = "Sync"
	sync.set_multiplayer_authority(1)
	add_child(sync)
	# What's in their hands (every peer, from the replicated counts):
	# the crew's own placeholder art (Cleanup.gd's builders).
	_mop_node = main.cleanup._build_tool_node("mop")
	_mop_node.position = Vector2(20, -6)
	add_child(_mop_node)
	_bag_node = main.cleanup._build_bag_node()
	_bag_node.position = Vector2(-18, -2)
	add_child(_bag_node)
	_hand_node = Node2D.new()
	_hand_node.position = Vector2(-16, -4)
	add_child(_hand_node)

func home() -> Vector2:
	return HOME

## --- Every peer: visuals ---------------------------------------------------------

func _process(delta: float) -> void:
	super._process(delta)
	if not active:
		return
	_mop_node.visible = bag_n <= 0
	var mopping := work >= 0.0
	_mop_node.get_node("Art").rotation = sin(Time.get_ticks_msec() * 0.02) * 0.35 if mopping else 0.0
	_mop_node.get_node("Bar").visible = mopping and work < 1.0
	_mop_node.get_node("BarBg").visible = _mop_node.get_node("Bar").visible
	if mopping:
		_mop_node.get_node("Bar").scale.x = clampf(work, 0.05, 1.0)
	_bag_node.visible = bag_n > 0
	if bag_n > 0:
		_bag_node.scale = Vector2.ONE * lerpf(0.8, 1.25, clampf(float(bag_n) / main.cleanup.can_capacity(), 0.0, 1.0))
	var shown := mini(hand, HAND_MAX)
	while _hand_node.get_child_count() < shown:
		var k := _hand_node.get_child_count()
		var s: Sprite2D = main.cleanup._sprite(main.cleanup.MARKET_SHEET_4, main.cleanup.LITTER_REGIONS[(k * 5 + 2) % main.cleanup.LITTER_REGIONS.size()], main.cleanup.LITTER_SCALE)
		s.rotation = k * 0.9 - 0.6
		s.position = Vector2(0, -6.0 * k)
		_hand_node.add_child(s)
	while _hand_node.get_child_count() > shown:
		var last := _hand_node.get_child(_hand_node.get_child_count() - 1)
		_hand_node.remove_child(last)
		last.queue_free()

## --- Host: on/off -------------------------------------------------------------------

func set_active(on: bool) -> void:
	if on == active:
		return
	_put_down_all()
	super.set_active(on)

func reset_for_new_shift() -> void:
	_put_down_all()
	super.reset_for_new_shift()
	litter_picked_today = 0
	litter_binned_today = 0
	mopped_today = 0
	leaks_mopped_today = 0
	bags_taken_today = 0
	bags_dumped_today = 0
	stuck_skips = 0
	unreachable_skips = 0

func _reset_brain() -> void:
	super._reset_brain()
	_skip = {}
	work = -1.0
	_best_d = INF
	_best_t = _clock

## No stock is ever in a janitor's hands.
func _held() -> Array:
	return []

## Off the clock (the store closed, let go, the shift ended): trash in hand
## goes into the nearest open can with room (or back on the floor if every
## can's full), a bag goes back into its can — the night crew won't touch it
## either (Cleanup.gd's rule for a player's bag).
func _put_down_all() -> void:
	if main == null or not multiplayer.is_server():
		return
	var cl: Node = main.cleanup
	if hand > 0:
		var c := _nearest_can(position, true)
		if c >= 0:
			var n: int = mini(hand, cl.can_capacity() - int(cl.cans[c]))
			cl._bin(c, n, 0)
			litter_binned_today += n
			hand -= n
		for k in hand:
			cl.drop_litter(position + Vector2(randf_range(-14, 14), randf_range(-14, 14)))
		cl.litter_collected_today = maxi(0, cl.litter_collected_today - hand)
		hand = 0
	if bag_n > 0:
		if _bag_can >= 0 and _bag_can < cl.cans.size():
			cl.set_can(_bag_can, int(cl.cans[_bag_can]) + bag_n)
		bag_n = 0
		_bag_can = -1
	work = -1.0

## --- Host: the brain ------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not Net.is_active() or not is_multiplayer_authority() or not active:
		return
	_clock += delta
	var fk_now := _forklift_live()
	_track_forklift_after(fk_now.rotation if fk_now != null else 0.0)
	if main.is_day_report_active():
		return
	# Off the clock once the store closes for cleanup (that's the crew's job,
	# and the cleanliness bonus is the crew's to earn — Phase 3's rule for
	# helpers): what's in hand is put away, and they wait at home.
	if not main.shift_active or main.cleanup_active:
		if hand > 0 or bag_n > 0:
			_put_down_all()
		_job = {"kind": "home"}
		status = ""
		work = -1.0
		_walk_toward(home(), delta)
		return
	# A Surprise Inspection with a janitor on staff (Events.gd): they walk the
	# inspector round (from the warning on) — off the floor, the cleaning is
	# the crew's until it's over. Whatever's in hand stays in hand.
	if main.events.janitor_escorting():
		_pause = 0.0
		_pause_action = ""
		_job = {"kind": "home", "at": home(), "reach": 2.0}
		work = -1.0
		status = "with the inspector"
		_walk_toward(home(), delta)
		return
	if status == "with the inspector":
		status = ""
	var flee := _forklift_step(delta)
	if flee != Vector2.INF:
		if _pause > 0.0:
			_pause = 0.0
			_pause_action = ""
			_job = {}
			work = -1.0
			status = ""
		_move_to(flee)
		_path_goal = Vector2.INF
		return
	if _pause > 0.0:
		_pause -= delta
		if _pause_action == "mop":
			if not _job_valid():
				_pause = 0.0 # someone else mopped it first
				_pause_action = ""
				_job = {}
				work = -1.0
				status = ""
				return
			work = clampf(1.0 - _pause / maxf(0.01, _mop_t), 0.0, 1.0)
		if _pause <= 0.0:
			_finish_action()
		return
	_job_t += delta
	if not _job.is_empty() and _job_t > JANITOR_JOB_TIMEOUT and _job["kind"] != "home":
		_give_up("timeout")
	if _job.is_empty() or not _job_valid() or (_job["kind"] == "home" and _job_t > 0.5):
		_choose_job()
	if _in_reach():
		_arrive()
		return
	# Stuck: no real progress toward the goal for a while (pinned by a
	# forklift parked in the way, a target the path can't quite get to).
	var goal := _job_goal()
	var d := _left_to_walk(goal)
	if fk_now != null and _forklift_moving(fk_now):
		_best_t = _clock # giving way isn't being stuck
	if d < _best_d - STUCK_PROGRESS:
		_best_d = d
		_best_t = _clock
	elif _clock - _best_t > STUCK_SECONDS and _job["kind"] != "home" and not (fk_now != null and _forklift_moving(fk_now)):
		_give_up("stuck")
		return
	_walk_toward(goal, delta)

## How far is left along the path (not as the crow flies: rounding the end of
## the Bakery/Produce wall walks AWAY from a goal on its far side — FOUND BY
## THE REACH TEST, a straight-line check called that "stuck").
func _left_to_walk(goal: Vector2) -> float:
	if _path.is_empty() or _path_goal != goal:
		return position.distance_to(goal)
	var d := position.distance_to(_path[0])
	for i in range(1, _path.size()):
		d += _path[i - 1].distance_to(_path[i])
	return d

func _give_up(why: String) -> void:
	if _job.has("key"):
		_skip[_job["key"]] = _clock + TARGET_COOLDOWN
	if why == "stuck":
		stuck_skips += 1
	print("[Janitor] gave up on %s (%s) at %s, goal %s, path %s" % [_job.get("key", _job.get("kind", "?")), why, str(position.round()), str(_job_goal().round()), str(_path)])
	# Wait a beat at home, then choose again (_physics_process re-chooses a
	# "home" job after 0.5 s).
	_job = {"kind": "home", "at": home(), "reach": 2.0}
	_job_t = 0.0
	_path_goal = Vector2.INF

func _skipped(k: String) -> bool:
	return _clock < float(_skip.get(k, -1.0))

## --- Jobs ---------------------------------------------------------------------------

func _choose_job() -> void:
	_job_t = 0.0
	_best_d = INF
	_best_t = _clock
	var cl: Node = main.cleanup
	var job := {}
	if bag_n > 0:
		job = {"kind": "dump", "key": "dumpster", "at": cl.DUMPSTER_POS + DUMPSTER_STAND, "reach": 10.0}
	if job.is_empty():
		var c := _nearest_full_can()
		if c >= 0:
			job = {"kind": "bag", "key": "can%d" % c, "can": c, "at": _can_stand(c), "reach": CAN_REACH}
	if job.is_empty():
		var m := _nearest_wet(false)
		if not m.is_empty():
			job = m
	if job.is_empty() and hand < HAND_MAX:
		var best := {}
		var best_d := INF
		for piece in cl.litter:
			var k := "l%d" % piece["id"]
			if _skipped(k) or not _reachable_zone(piece["pos"]):
				continue
			var dd: float = position.distance_to(piece["pos"])
			if dd < best_d:
				best_d = dd
				best = {"kind": "pick", "key": k, "id": piece["id"], "at": piece["pos"], "reach": LITTER_REACH}
		job = best
	if job.is_empty() and hand > 0:
		var c := _nearest_can(position, true)
		if c >= 0:
			job = {"kind": "bin", "key": "bin%d" % c, "can": c, "at": _can_stand(c), "reach": CAN_REACH}
	if job.is_empty():
		var m := _nearest_wet(true)
		if not m.is_empty():
			job = m
	if job.is_empty():
		job = {"kind": "home", "at": home(), "reach": 2.0}
	_job = job
	# A target the grid can't get to at all: skip it now, not after a timeout.
	if _job["kind"] != "home":
		_plan(_job["at"])
		if _path.size() <= 1 and position.distance_to(_job["at"]) > 160.0 and not main.janitor_nav_reachable(position, _job["at"]):
			unreachable_skips += 1
			_give_up("unreachable")

## The nearest puddle/leak (spills = false) or stage-4 hazard spill (true).
func _nearest_wet(spills: bool) -> Dictionary:
	var best := {}
	var best_d := INF
	for pd in ([] if spills else main.cleanup.puddles):
		var k := "u%d" % pd["id"]
		if _skipped(k) or not _reachable_zone(pd["pos"]):
			continue
		var dd: float = position.distance_to(pd["pos"])
		if dd < best_d:
			best_d = dd
			var water: bool = pd.get("water", false)
			best = {"kind": "mop", "key": k, "ref": pd["id"], "what": "leak" if water else "puddle", "at": pd["pos"], "reach": MOP_REACH + float(pd["r"]) * 0.5, "time": LEAK_MOP_TIME if water else MOP_TIME_PUDDLE}
	if spills and main.ambience.spills_enabled():
		for sp in main.ambience.spills:
			var k := "s%d" % sp["id"]
			if _skipped(k) or not _reachable_zone(sp["pos"]):
				continue
			var dd: float = position.distance_to(sp["pos"])
			if dd < best_d:
				best_d = dd
				best = {"kind": "mop", "key": k, "ref": sp["id"], "what": "spill", "at": sp["pos"], "reach": MOP_REACH + float(sp["r"]) * 0.5, "time": MOP_TIME_SPILL}
	return best

func _job_valid() -> bool:
	var cl: Node = main.cleanup
	match _job.get("kind", ""):
		"pick":
			return hand < HAND_MAX and cl.litter.any(func(p): return p["id"] == _job["id"])
		"mop":
			if _job["what"] == "spill":
				return main.ambience.spills.any(func(s): return s["id"] == _job["ref"])
			return cl.puddles.any(func(p): return p["id"] == _job["ref"])
		"bag":
			return bag_n <= 0 and cl.can_open(_job["can"]) and cl.can_full(_job["can"])
		"bin":
			return hand > 0 and cl.can_open(_job["can"]) and not cl.can_full(_job["can"])
		"dump":
			return bag_n > 0
	return true

func _job_goal() -> Vector2:
	return _job.get("at", home())

func _in_reach() -> bool:
	return position.distance_to(_job_goal()) <= float(_job.get("reach", 2.0))

func _arrive() -> void:
	var at: Vector2 = _job_goal()
	if position.distance_to(at) > 0.5:
		facing_angle = (at - position).angle()
	match _job["kind"]:
		"pick":
			_pause_with(PICK_TIME_LITTER, "pick")
		"mop":
			_mop_t = float(_job["time"])
			status = "mopping…"
			work = 0.0
			_pause_with(_mop_t, "mop")
		"bin":
			_pause_with(BIN_TIME, "bin")
		"bag":
			status = "bagging…"
			_pause_with(BAG_TIME, "bag")
		"dump":
			facing_angle = PI * 0.5
			_pause_with(DUMP_TIME, "dump")
		_:
			facing_angle = PI * 0.5

func _finish_action() -> void:
	var cl: Node = main.cleanup
	match _pause_action:
		"pick":
			var id: int = _job["id"]
			if hand < HAND_MAX and cl.litter.any(func(p): return p["id"] == id):
				cl.litter = cl.litter.filter(func(p): return p["id"] != id)
				cl._note_collected(1)
				hand += 1
				litter_picked_today += 1
				if main.cleanup_active:
					cl._update_left()
		"mop":
			if _job_valid():
				if _job["what"] == "spill":
					main.ambience.remove_spill(_job["ref"])
				else:
					cl.remove_puddle(_job["ref"])
				mopped_today += 1
				if _job["what"] == "leak":
					leaks_mopped_today += 1
				print("[Janitor] %s mopped up a %s" % [helper_name, _job["what"]])
		"bin":
			var c: int = _job["can"]
			if hand > 0 and cl.can_open(c) and not cl.can_full(c):
				var n: int = mini(hand, cl.can_capacity() - int(cl.cans[c]))
				cl._bin(c, n, 0)
				hand -= n
				litter_binned_today += n
		"bag":
			var c: int = _job["can"]
			if bag_n <= 0 and cl.can_open(c) and int(cl.cans[c]) > 0:
				# Whatever's in hand goes in on top (no can with room needed).
				bag_n = int(cl.cans[c]) + hand
				if hand > 0:
					cl.trash_binned_today += hand
					cl.litter_pay_week += hand * cl.LITTER_PAY_PER_PIECE
					litter_binned_today += hand
					hand = 0
				_bag_can = c
				cl.set_can(c, 0)
				bags_taken_today += 1
				print("[Janitor] %s bagged can %d (%d pieces)" % [helper_name, c, bag_n])
		"dump":
			if bag_n > 0:
				cl.bags_dumped_today += 1
				cl._announce_dump.rpc(bag_n)
				print("[Janitor] %s tipped a bag (%d pieces) into the dumpster" % [helper_name, bag_n])
				bag_n = 0
				_bag_can = -1
				bags_dumped_today += 1
	status = ""
	work = -1.0
	_pause_action = ""
	_job = {}

## --- What's where (host) --------------------------------------------------------------

## Open floor the crew's customers can be in (the hub and open sections), or
## Storage (the dumpster). Litter only ever lands in the first.
func _reachable_zone(p: Vector2) -> bool:
	var cell: Vector2i = main._grid_cell_of(p)
	return cell == main.ENTRANCE_GRID_POS or cell == main.STORAGE_GRID_POS or main.is_unlocked_at_pos(p)

func _nearest_can(from: Vector2, needs_room: bool) -> int:
	var cl: Node = main.cleanup
	var best := -1
	var best_d := INF
	for i in cl.BINS.size():
		if not cl.can_open(i) or (needs_room and cl.can_full(i)) or _skipped("bin%d" % i):
			continue
		var d: float = from.distance_to(cl.BINS[i]["pos"])
		if d < best_d:
			best_d = d
			best = i
	return best

func _nearest_full_can() -> int:
	var cl: Node = main.cleanup
	var best := -1
	var best_d := INF
	for i in cl.BINS.size():
		if not cl.can_open(i) or not cl.can_full(i) or _skipped("can%d" % i):
			continue
		var d: float = position.distance_to(cl.BINS[i]["pos"])
		if d < best_d:
			best_d = d
			best = i
	return best

## Where to stand at a can: the can's own spot (it has no collision; the
## path ends at the nearest open cell and walks the last bit straight).
func _can_stand(i: int) -> Vector2:
	return main.cleanup.BINS[i]["pos"]

## --- Paths (host): the store-wide grid ------------------------------------------------

func _plan(goal: Vector2) -> void:
	_path_goal = goal
	_path = main.janitor_nav_path(position, goal)

## --- The forklifts (host): Helper.gd's yield/flee, fed the nearest one ----------------

func _forklift_live() -> Node2D:
	var best: Node2D = null
	var best_d := FORKLIFT_WATCH
	for fk in [main.forklift, main.delivery_forklift]:
		if fk == null or not fk.visible or not fk.get("active"):
			continue
		var d: float = position.distance_to(fk.global_position)
		if d < best_d:
			best_d = d
			best = fk
	return best

## Helper.gd's rules (in its body: out the nearer side; in its path ahead:
## sideways out of the lane; too close while it moves: straight away), with
## every step kept on open floor of the grid instead of a room's aisle band.
func _forklift_step(delta: float) -> Vector2:
	var fk := _forklift_live()
	if fk == null:
		return Vector2.INF
	var inside := _in_forklift(position, 6.0)
	if not inside and not _forklift_moving(fk):
		return Vector2.INF
	var rel := position - fk.global_position
	var heading := Vector2.RIGHT.rotated(fk.rotation) * (-1.0 if fk.reversing else 1.0)
	var ahead := rel.dot(heading)
	var side := rel.dot(heading.orthogonal())
	var dirs := []
	var in_path: bool = ahead > -30.0 and ahead < FORKLIFT_PATH_AHEAD and absf(side) < FORKLIFT_HALF.y + FORKLIFT_PATH_SIDE and (fk.velocity.length() > 5.0 or fk.alert)
	if inside or in_path:
		var s := signf(side) if side != 0.0 else 1.0
		dirs = [heading.orthogonal() * s, heading.orthogonal() * -s]
	elif rel.length() < FORKLIFT_FLEE:
		var away := rel.normalized() if rel.length() > 0.01 else Vector2.UP
		dirs = [away, away.rotated(PI * 0.5), away.rotated(-PI * 0.5)]
	if dirs.is_empty():
		return Vector2.INF
	for dir in dirs:
		if main.janitor_nav_open(position + dir * 40.0):
			forklift_yield_s += delta
			return position + dir * maxf(speed, FLEE_SPEED) * delta
	return Vector2.INF # boxed in: no body, so nothing to be hit — wait it out
