extends Node
## WEEK 22 — turns game state into sound, on EVERY peer (see Sfx.gd's header
## for how the pieces fit). Built by Main.gd in _ready(), like Ambience/Cleanup.
##
## THE RULE: a sound about the shared world comes from REPLICATED state this
## peer already has — the same values that already drive the visuals — so it
## plays at the same moment the matching visual does, on every peer, with no
## extra network traffic and nothing for a late joiner to miss. Each watcher
## below keeps the last value it saw and plays on the edge (a new spill id,
## lights_event_id changing, the BEEP label blinking on, total_sold going up).
##
## THREE EXCEPTIONS:
## - Your own footsteps and tool work: the LOCAL player's movement, played
##   here, locally (nobody else hears your footsteps — keeps four players'
##   worth of feet from drowning the hazard cues).
## - Your own pickup/drop/throw: Carryable.gd's reliable call_local RPCs call
##   Sfx directly when the carrier is this peer.
## - Physics impacts: only the host simulates loose stock, so the host spots
##   them here (_detect_impacts_host()) and broadcasts each one, unreliably,
##   through Sfx.broadcast_at().
##
## WARM-UP: for WARMUP seconds after this peer connects (and right after a
## shift starts) the watchers only record what they see — a late joiner's
## first sync would otherwise "discover" every existing spill, sale and shelf
## at once and play them all together.

const WARMUP := 1.5
## Your footsteps: one every STEP_DISTANCE px walked.
const STEP_DISTANCE := 64.0
## Tool work: a swish this often while the tool's held down on a mess.
const MOP_EVERY := 0.42
const BROOM_EVERY := 0.26
## Host impact detection: a loose body moving faster than IMPACT_MIN_SPEED
## whose velocity changes by more than IMPACT_MIN_DV in one physics tick hit
## something. Past IMPACT_HEAVY_DV it's the heavy thud.
const IMPACT_MIN_SPEED := 220.0
const IMPACT_MIN_DV := 150.0
const IMPACT_HEAVY_DV := 430.0
const IMPACT_BODY_COOLDOWN := 0.35 # per body: one item rattling along a shelf is one thud, not five
const IMPACT_MAX_PER_SECOND := 8 # across the whole store (a forklift plowing a full aisle is still only so loud)
## A shelf losing this many items within COLLAPSE_WINDOW is a stack collapse.
const COLLAPSE_ITEMS := 3
const COLLAPSE_WINDOW := 0.35
## Forklift engine (Kenney's racing-kit engine loop, played slow: a forklift
## putters). Pitch/volume follow its replicated speed; the loop itself starts
## once and never restarts while it runs.
const ENGINE_IDLE_PITCH := 0.55
const ENGINE_MOVE_PITCH := 0.72
const ENGINE_IDLE_DB := -18.0
const ENGINE_MOVE_DB := -11.0

var main: Node
var _warmup := WARMUP
var _was_active := false

## Watcher state (last value seen).
var _shift_active := false
var _store_open := false
var _report_shown := false
var _screen := 0
var _wallet := 0
var _orders_called := 0
var _spill_ids := {}
var _lights_id := 0
var _lights_stung := 0
var _sold := {} # cashier -> total_sold
var _shelf_filled := {} # shelf -> filled count
var _shelf_losses := {} # shelf -> [msec, ...]
var _shelf_wrecked := {} # shelf -> bool
var _display_toppled := {} # display -> bool
var _mop_left := 0
var _can_fills: Array = []
var _binned_seen := 0
var _litter_left := 0
var _pans := {} # tool index -> pan count
var _tool_timers := {} # tool index -> s to the next swish
var _watch_on := false
var _watch_hot := false
var _forklifts := {} # forklift -> {"engine": player, "beep_on": bool, "last_pos": Vector2, "speed": float}
var _step_accum := 0.0
var _last_step_pos = null
## Host: impact detection.
var _prev_vel := {} # instance id -> Vector2
var _impact_cooldown := {} # instance id -> s
var _impacts_this_second := 0
var _impact_window := 0.0
## Diagnostics the tests read.
var impacts_detected := 0
var engine_starts := 0 # both forklifts; per forklift in _forklifts[f]["starts"]

## Tests: how many times this forklift's engine loop has been (re)started.
func engine_starts_of(f: Node) -> int:
	return _forklifts.get(f, {}).get("starts", 0)

func _ready() -> void:
	main = get_parent()

func _process(delta: float) -> void:
	var active := Net.is_active()
	if active and not _was_active:
		_warmup = WARMUP
	_was_active = active
	_update_music()
	if not active:
		return
	var quiet := _warmup > 0.0
	_warmup = maxf(0.0, _warmup - delta)
	_watch_shift(quiet)
	_watch_orders(quiet)
	_watch_manager(quiet)
	_watch_ambience(quiet)
	_watch_shelves(quiet)
	_watch_registers(quiet)
	_watch_cleanup(quiet, delta)
	_watch_report(quiet)
	_update_forklifts(delta)
	_local_footsteps()

func _physics_process(delta: float) -> void:
	if Net.is_active() and multiplayer.is_server():
		_detect_impacts_host(delta)

## --- Music ----------------------------------------------------------------------

## Calm loop for the menu, prep, cleanup and the report/hub; the upbeat one
## while the store's open (a touch faster on the finale day / the hardest
## endless postings).
func _update_music() -> void:
	if not Net.is_active():
		Sfx.set_music("prep")
		return
	var selling: bool = main.shift_active and main.store_open and not main.cleanup_active and not main.is_day_report_active()
	if selling:
		Sfx.set_music("selling", 1.06 if main.is_finale() else 1.0)
	else:
		Sfx.set_music("prep")

## --- Phase changes --------------------------------------------------------------

func _watch_shift(quiet: bool) -> void:
	var shift: bool = main.shift_active
	if shift and not _shift_active:
		_warmup = maxf(_warmup, 0.6) # the day reset empties every shelf at once
	_shift_active = shift
	# The STORE OPEN bell is Main._announce_store_open()'s (a reliable RPC).
	_store_open = main.store_open

func _watch_report(quiet: bool) -> void:
	var shown: bool = main.report_layer.visible
	if shown and not _report_shown and not quiet:
		Sfx.play("clock_out")
		get_tree().create_timer(0.55).timeout.connect(func(): Sfx.play("paycheck"))
	_report_shown = shown
	var screen: int = main.endless.screen
	if screen != _screen and screen == main.endless.SCREEN_WEEK_COMPLETE and not quiet:
		Sfx.play("final_shift")
		get_tree().create_timer(0.9).timeout.connect(func(): Sfx.play("paycheck"))
	_screen = screen
	var wallet: int = main.endless.wallet
	if wallet < _wallet and screen == main.endless.SCREEN_HUB and not quiet:
		Sfx.play("ui_buy")
	_wallet = wallet

## --- Priority orders ------------------------------------------------------------

## The call-out chime as a NEW order appears. orders_called_today and
## order_section arrive in the same DaySync packet, so "the count went up and
## an order is open" is exactly "a fresh order", never a stale one.
func _watch_orders(quiet: bool) -> void:
	var called: int = main.orders_called_today
	if called > _orders_called and main.order_section != "" and not quiet:
		Sfx.play("order_chime")
	_orders_called = called

## --- Manager --------------------------------------------------------------------

## The "look busy" cue as his meter starts climbing on someone ("?"), and a
## sharper tweet when it crosses into the red ("!"). Loud and up-front for
## the player he's staring at; a distant whistle from where he stands for
## everyone else. The write-up sting itself is Main._announce_writeup()'s.
func _watch_manager(quiet: bool) -> void:
	var m: Node2D = main.manager
	var on: bool = m.active and not main.cleanup_active and not main.is_day_report_active() and m.watch_peer != 0 and m.watch_level > 0.0 and not m.writing_up
	var hot: bool = on and m.watch_level >= m.WARN_LEVEL
	var me := multiplayer.get_unique_id()
	if not quiet:
		if on and not _watch_on:
			if m.watch_peer == me:
				Sfx.play("manager_whistle")
			else:
				Sfx.play_at("manager_whistle_far", m.global_position)
		if hot and not _watch_hot and m.watch_peer == me:
			Sfx.play("manager_tweet")
	_watch_on = on
	_watch_hot = hot

## --- Spills and lights ----------------------------------------------------------

func _watch_ambience(quiet: bool) -> void:
	var amb: Node2D = main.ambience
	var ids := {}
	for s in (amb.spills if amb.spills_enabled() else []):
		ids[s["id"]] = true
		if not _spill_ids.has(s["id"]) and not quiet:
			Sfx.play_at("spill_splat", s["pos"])
	_spill_ids = ids
	# The flicker sting: once per lights event, on its darkest dip (the
	# moment Ambience's own playback first hits the event's lowest level).
	var id: int = amb.lights_event_id
	if id != _lights_id:
		_lights_id = id
		if quiet:
			_lights_stung = id # joined mid-event: let this one go
	if id != 0 and id != _lights_stung and amb.event_playing() and amb.brightness <= amb.LIGHTS_FLICKER_LOW + 0.001:
		_lights_stung = id
		Sfx.play("flicker_sting")

## --- Shelves, displays, registers -----------------------------------------------

## Every peer, from Shelf.gd's replicated filled/wrecked: a soft clunk as
## something settles into a slot, the crash + collapse when the forklift
## wrecks a shelf, and the collapse alone when a shelf loses COLLAPSE_ITEMS
## at once any other way (a thrown armful plowing into it).
func _watch_shelves(quiet: bool) -> void:
	var now := Time.get_ticks_msec()
	for shelf_body in main.shelves:
		var shelf: Node = shelf_body.get_node("Shelf")
		var count: int = shelf.filled_count()
		var prev: int = _shelf_filled.get(shelf_body, count)
		var wrecked: bool = shelf.wrecked
		var was_wrecked: bool = _shelf_wrecked.get(shelf_body, wrecked)
		var pos: Vector2 = shelf_body.global_position
		if not quiet:
			if wrecked and not was_wrecked:
				Sfx.play_at("forklift_ram", pos)
				Sfx.play_at("stack_collapse", pos, 0.0, 0.9)
			elif count > prev:
				Sfx.play_at("place_shelf", pos)
			elif count < prev and not wrecked:
				var losses: Array = _shelf_losses.get(shelf_body, []).filter(func(t): return now - t < int(COLLAPSE_WINDOW * 1000.0))
				for i in prev - count:
					losses.append(now)
				if losses.size() >= COLLAPSE_ITEMS:
					Sfx.play_at("stack_collapse", pos)
					losses.clear()
				_shelf_losses[shelf_body] = losses
		_shelf_filled[shelf_body] = count
		_shelf_wrecked[shelf_body] = wrecked
	for display_body in main.displays:
		var toppled: bool = display_body.get_node("Display").toppled
		if toppled and not _display_toppled.get(display_body, toppled) and not quiet:
			Sfx.play_at("glass_break", display_body.global_position)
		_display_toppled[display_body] = toppled

## The register ding on every sale (Cashier.total_sold, replicated).
func _watch_registers(quiet: bool) -> void:
	for cashier_body in main.cashiers:
		var c: Node = cashier_body.get_node("Cashier")
		var sold: int = c.total_sold
		if sold > _sold.get(cashier_body, sold) and not quiet:
			Sfx.play_at("register_ding", cashier_body.global_position)
		_sold[cashier_body] = sold

## --- Cleanup --------------------------------------------------------------------

## Tools at work (every peer hears whoever's mopping/sweeping, near them),
## a chime per mess cleared, a bigger one when the floor's spotless, and the
## dustpan going into the bin.
func _watch_cleanup(quiet: bool, delta: float) -> void:
	var cl: Node2D = main.cleanup
	var tools: Array = cl.tools
	for i in tools.size():
		var t: Dictionary = tools[i]
		var holder: int = t["holder"]
		var p = main.players.get(holder) if holder != 0 else null
		# OCT 2026 PHASE 3D: the tools work all shift, not just at close.
		var working: bool = p != null and is_instance_valid(p) and p.using_tool and main.shift_active and not main.is_day_report_active()
		var left: float = _tool_timers.get(i, 0.0) - delta
		if working:
			if left <= 0.0:
				# Scrubbing a mess for real: full swish. Waving it at clean
				# floor: a quieter one, so you can tell.
				var on_mess: bool = float(t["work"]) >= 0.0
				Sfx.play_at(t["kind"], p.global_position, 0.0 if on_mess else -7.0)
				left = MOP_EVERY if t["kind"] == "mop" else BROOM_EVERY
		else:
			left = 0.0
		_tool_timers[i] = left
		_pans[i] = int(t["pan"])
	# PHASE 3D: trash going into a can (by hand or out of a dustpan) — the
	# rattle, at the can.
	var fills: Array = cl.cans
	var binned: int = cl.trash_binned_today
	if _can_fills.size() == fills.size() and not quiet and binned > _binned_seen:
		for c in fills.size():
			if int(fills[c]) > int(_can_fills[c]):
				Sfx.play_at("pan_dump", cl.BINS[c]["pos"], -2.0 if int(fills[c]) - int(_can_fills[c]) > 1 else -6.0)
	_can_fills = fills.duplicate()
	_binned_seen = binned
	var mop_left: int = cl.mop_left
	var litter_left: int = cl.litter_left
	if main.cleanup_active and not quiet:
		var cleared := (_mop_left - mop_left if mop_left < _mop_left else 0) + (_litter_left - litter_left if litter_left < _litter_left else 0)
		if cleared > 0:
			if mop_left == 0 and litter_left == 0 and cl.mop_total + cl.litter_total > 0:
				Sfx.play("all_clean")
			else:
				Sfx.play("clean_chime", 0.0, 1.0 + 0.04 * minf(8.0, float(cl.mop_total + cl.litter_total - mop_left - litter_left)))
	_mop_left = mop_left
	_litter_left = litter_left

## --- Forklifts ------------------------------------------------------------------

## Both forklifts (Produce + delivery), every peer: the engine loop while it
## runs, the reverse beeper in time with its blinking BEEP label, and the
## faster alarm chirp on its "!!" ram telegraph.
func _update_forklifts(delta: float) -> void:
	for f in [main.forklift, main.delivery_forklift]:
		if f == null:
			continue
		var st: Dictionary = _forklifts.get(f, {})
		if st.is_empty():
			st = {"engine": Sfx.make_loop("forklift_engine", f), "beep_on": false, "last_pos": f.global_position, "speed": 0.0, "starts": 0}
			_forklifts[f] = st
		var running: bool = f.active and f._running(main)
		var moved: float = f.global_position.distance_to(st["last_pos"]) / maxf(delta, 0.001)
		st["last_pos"] = f.global_position
		st["speed"] = lerpf(st["speed"], minf(moved, 200.0), clampf(6.0 * delta, 0.0, 1.0))
		var engine: AudioStreamPlayer2D = st["engine"]
		if engine:
			if running and not engine.playing:
				engine.play(randf() * 6.0) # random spot in the loop: two forklifts never phase
				engine_starts += 1
				st["starts"] += 1
			var k: float = clampf(st["speed"] / f.DRIVE_SPEED, 0.0, 1.2)
			var want_db: float = lerpf(ENGINE_IDLE_DB, ENGINE_MOVE_DB, minf(k, 1.0)) if running else -60.0
			engine.volume_db = move_toward(engine.volume_db, want_db, 40.0 * delta)
			engine.pitch_scale = lerpf(ENGINE_IDLE_PITCH, ENGINE_MOVE_PITCH, k)
			if not running and engine.playing and engine.volume_db <= -59.0:
				engine.stop()
		var label: Label = f.get_node("BeepAnchor/BeepLabel")
		var beep_on: bool = f.active and label.visible
		if beep_on and not st["beep_on"]:
			Sfx.play_at("forklift_alert" if f.alert else "forklift_beep", f.global_position)
		st["beep_on"] = beep_on

## --- Your own feet --------------------------------------------------------------

func _local_footsteps() -> void:
	var me := multiplayer.get_unique_id()
	var p = main.players.get(me)
	if p == null or not is_instance_valid(p) or main.is_day_report_active():
		_last_step_pos = null
		return
	var pos: Vector2 = p.global_position
	if _last_step_pos == null or pos.distance_to(_last_step_pos) > 200.0: # spawn / teleport
		_last_step_pos = pos
		return
	_step_accum += pos.distance_to(_last_step_pos)
	_last_step_pos = pos
	if _step_accum >= STEP_DISTANCE:
		_step_accum = 0.0
		Sfx.play("footstep")

## --- Host: physics impacts ------------------------------------------------------

func _detect_impacts_host(delta: float) -> void:
	_impact_window -= delta
	if _impact_window <= 0.0:
		_impact_window = 1.0
		_impacts_this_second = 0
	var bodies: Array = get_tree().get_nodes_in_group("carryable") + get_tree().get_nodes_in_group("display")
	var seen := {}
	for b in bodies:
		if not (b is RigidBody2D) or not is_instance_valid(b):
			continue
		var id: int = b.get_instance_id()
		seen[id] = true
		var v: Vector2 = b.linear_velocity
		var prev: Vector2 = _prev_vel.get(id, v)
		_prev_vel[id] = v
		var cd: float = _impact_cooldown.get(id, 0.0)
		if cd > 0.0:
			_impact_cooldown[id] = cd - delta
			continue
		var comp: Node = b.get_node_or_null("Carryable")
		if comp != null and comp.carrier_id != 0:
			continue # caught / picked up mid-flight: not a hit
		var dv := (prev - v).length()
		if prev.length() < IMPACT_MIN_SPEED or dv < IMPACT_MIN_DV:
			continue
		_impact_cooldown[id] = IMPACT_BODY_COOLDOWN
		if _impacts_this_second >= IMPACT_MAX_PER_SECOND:
			continue
		_impacts_this_second += 1
		impacts_detected += 1
		var sound := "box_thud" if b.is_in_group("delivery_box") else ("impact_heavy" if dv >= IMPACT_HEAVY_DV else "impact_light")
		Sfx.broadcast_at(sound, b.global_position, clampf((dv - IMPACT_HEAVY_DV) / 100.0, -6.0, 3.0))
	for id in _prev_vel.keys():
		if not seen.has(id):
			_prev_vel.erase(id)
			_impact_cooldown.erase(id)
