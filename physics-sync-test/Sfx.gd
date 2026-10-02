extends Node
## WEEK 22 — sound. The one place every sound in the game is played from.
## Autoloaded as "Sfx" (project.godot), so it exists at /root/Sfx on every
## peer before Main does — that fixed path is also what lets the host
## broadcast a one-shot to everyone over RPC (_net_play() below).
##
## WHAT LIVES WHERE:
## - Sfx.gd (this): the bus layout, the sound library (LIBRARY), a voice pool,
##   anti-spam limits, the host->everyone broadcast, the music crossfade, and
##   counters/logging the tests read. Knows nothing about the game.
## - SoundDirector.gd (a child of Main): watches the game's REPLICATED state
##   on every peer and plays the right sound when it changes (a new spill, a
##   lights event, the forklift's BEEP, the manager's "?", a sale...). Same
##   reasoning this project already uses for visuals: replicated state, not
##   one-shot RPCs, so every peer — including one that joined late — hears the
##   same thing from the same data.
## - A handful of one-line hooks in existing reliable call_local RPCs (store
##   open, write-up, order result, a forklift bump, pickup/drop/throw), where
##   the RPC already IS the moment on every peer.
##
## BUSES (built in code, _setup_buses()): Master <- Music / SFX / Hazard / UI.
## Hazard cues (forklift beeper, manager whistle, priority-order chime, the
## lights sting, spills, the finale fanfare) sit loudest; music sits well
## under everything and ducks a further DUCK_DB for a moment whenever a
## hazard cue plays, so the gameplay-critical cues always read over it.
##
## ANTI-SPAM (every sound, see LIBRARY): `cooldown` = minimum seconds between
## two plays of that sound (per position bucket for positional ones),
## `voices` = how many may overlap; past that the oldest is cut. Footsteps,
## impacts and sales can't machine-gun however often they're asked for.
##
## SOURCES & LICENSES: audio/CREDITS.md. Everything is CC0 except the selling
## music (Kevin MacLeod, CC-BY — credit line in CREDITS.md).

const BUS_MUSIC := "Music"
const BUS_SFX := "SFX"
const BUS_HAZARD := "Hazard"
const BUS_UI := "UI"
## dB per bus, relative to Master. The hierarchy is the point: hazard > sfx >
## ui > music. Placeholders like every other tuning number here.
const BUS_DB := {BUS_MUSIC: -13.0, BUS_SFX: -4.0, BUS_HAZARD: 0.0, BUS_UI: -6.0}
const DUCK_DB := -7.0
const DUCK_SECONDS := 1.2
const MUSIC_FADE := 1.5 # s crossfade between music tracks
## Positional sounds: beyond this (px) they're silent. One room is 960 wide.
const MAX_DISTANCE := 1100.0

## name -> {files, bus, db, pitch (random +- range), cooldown (s), voices, pos (positional)}
const LIBRARY := {
	# Movement / interaction — your own, played locally.
	"footstep": {"files": ["sfx/footstep_1", "sfx/footstep_2", "sfx/footstep_3", "sfx/footstep_4", "sfx/footstep_5", "sfx/footstep_6"], "bus": BUS_SFX, "db": -15.0, "pitch": 0.08, "cooldown": 0.18, "voices": 2},
	"pickup": {"files": ["sfx/pickup"], "bus": BUS_SFX, "db": -9.0, "pitch": 0.06, "cooldown": 0.06, "voices": 3},
	"drop": {"files": ["sfx/drop"], "bus": BUS_SFX, "db": -9.0, "pitch": 0.06, "cooldown": 0.06, "voices": 3},
	"throw": {"files": ["sfx/throw_whoosh"], "bus": BUS_SFX, "db": -6.0, "pitch": 0.1, "cooldown": 0.08, "voices": 3},
	# Physical chaos — shared world, positional.
	"place_shelf": {"files": ["sfx/place_shelf"], "bus": BUS_SFX, "db": -10.0, "pitch": 0.08, "cooldown": 0.05, "voices": 4, "pos": true},
	"impact_light": {"files": ["sfx/impact_light"], "bus": BUS_SFX, "db": -12.0, "pitch": 0.12, "cooldown": 0.07, "voices": 4, "pos": true},
	"impact_heavy": {"files": ["sfx/impact_heavy"], "bus": BUS_SFX, "db": -8.0, "pitch": 0.1, "cooldown": 0.1, "voices": 3, "pos": true},
	"box_thud": {"files": ["sfx/box_thud"], "bus": BUS_SFX, "db": -5.0, "pitch": 0.1, "cooldown": 0.08, "voices": 3, "pos": true},
	"stack_collapse": {"files": ["sfx/stack_collapse"], "bus": BUS_SFX, "db": -3.0, "pitch": 0.06, "cooldown": 0.4, "voices": 2, "pos": true},
	"glass_break": {"files": ["sfx/glass_break"], "bus": BUS_SFX, "db": -5.0, "pitch": 0.06, "cooldown": 0.5, "voices": 2, "pos": true},
	# Forklift.
	"forklift_engine": {"files": ["sfx/forklift_engine_loop"], "bus": BUS_SFX, "db": -12.0, "loop": true},
	"forklift_beep": {"files": ["sfx/forklift_beep"], "bus": BUS_HAZARD, "db": -7.0, "cooldown": 0.25, "voices": 2, "pos": true},
	"forklift_alert": {"files": ["sfx/forklift_alert"], "bus": BUS_HAZARD, "db": -5.0, "cooldown": 0.33, "voices": 2, "pos": true, "duck": true},
	"forklift_ram": {"files": ["sfx/forklift_ram"], "bus": BUS_HAZARD, "db": -2.0, "pitch": 0.04, "cooldown": 0.5, "voices": 2, "pos": true, "duck": true},
	"forklift_bonk": {"files": ["sfx/forklift_bonk"], "bus": BUS_SFX, "db": -4.0, "pitch": 0.08, "cooldown": 0.3, "voices": 2, "pos": true},
	# Manager.
	"manager_whistle": {"files": ["sfx/manager_whistle"], "bus": BUS_HAZARD, "db": -3.0, "cooldown": 2.5, "voices": 1, "duck": true},
	"manager_whistle_far": {"files": ["sfx/manager_whistle"], "bus": BUS_HAZARD, "db": -12.0, "cooldown": 2.5, "voices": 1, "pos": true},
	"manager_tweet": {"files": ["sfx/manager_tweet"], "bus": BUS_HAZARD, "db": -3.0, "pitch": 0.0, "cooldown": 1.5, "voices": 1, "duck": true},
	"writeup": {"files": ["sfx/writeup_trombone"], "bus": BUS_HAZARD, "db": -5.0, "cooldown": 1.0, "voices": 1, "duck": true},
	# Priority orders.
	"order_chime": {"files": ["sfx/order_chime"], "bus": BUS_HAZARD, "db": -2.0, "cooldown": 1.0, "voices": 1, "duck": true},
	"order_filled": {"files": ["sfx/order_filled"], "bus": BUS_SFX, "db": -4.0, "cooldown": 1.0, "voices": 1},
	"order_missed": {"files": ["sfx/order_missed"], "bus": BUS_SFX, "db": -9.0, "cooldown": 1.0, "voices": 1},
	# Spills, lights, finale.
	"spill_splat": {"files": ["sfx/spill_splat"], "bus": BUS_HAZARD, "db": -6.0, "pitch": 0.1, "cooldown": 0.3, "voices": 2, "pos": true},
	"flicker_sting": {"files": ["sfx/flicker_sting"], "bus": BUS_HAZARD, "db": -4.0, "cooldown": 3.0, "voices": 1, "duck": true},
	"final_shift": {"files": ["final_shift"], "bus": BUS_HAZARD, "db": -2.0, "cooldown": 3.0, "voices": 1, "duck": true},
	# Store, register, report.
	"store_open": {"files": ["sfx/store_open_bell"], "bus": BUS_SFX, "db": -4.0, "cooldown": 2.0, "voices": 1},
	"register_ding": {"files": ["sfx/register_ding"], "bus": BUS_SFX, "db": -13.0, "pitch": 0.03, "cooldown": 0.12, "voices": 3, "pos": true},
	"paycheck": {"files": ["sfx/paycheck_chaching"], "bus": BUS_UI, "db": 0.0, "cooldown": 1.0, "voices": 1},
	"clock_out": {"files": ["sfx/clock_out"], "bus": BUS_SFX, "db": -2.0, "cooldown": 1.0, "voices": 1},
	# Cleanup.
	"mop": {"files": ["sfx/mop_swish_1", "sfx/mop_swish_2"], "bus": BUS_SFX, "db": -10.0, "pitch": 0.08, "cooldown": 0.25, "voices": 2, "pos": true},
	"broom": {"files": ["sfx/broom_sweep_1", "sfx/broom_sweep_2"], "bus": BUS_SFX, "db": -12.0, "pitch": 0.1, "cooldown": 0.15, "voices": 2, "pos": true},
	"clean_chime": {"files": ["sfx/clean_chime"], "bus": BUS_SFX, "db": -9.0, "pitch": 0.0, "cooldown": 0.08, "voices": 2},
	"all_clean": {"files": ["sfx/all_clean"], "bus": BUS_SFX, "db": -3.0, "cooldown": 2.0, "voices": 1},
	"pan_dump": {"files": ["sfx/pan_dump"], "bus": BUS_SFX, "db": -7.0, "pitch": 0.06, "cooldown": 0.3, "voices": 1, "pos": true},
	# UI.
	"ui_click": {"files": ["sfx/ui_click"], "bus": BUS_UI, "db": -4.0, "pitch": 0.04, "cooldown": 0.04, "voices": 2},
	"ui_buy": {"files": ["sfx/ui_buy"], "bus": BUS_UI, "db": -2.0, "cooldown": 0.2, "voices": 1},
}
## Every play that got through the limits (tests listen to this).
signal played(sound: String, pos: Variant)

const MUSIC := {
	"prep": "music/prep_loop",
	"selling": "music/selling_loop",
}

## name -> Array[AudioStream] (every variant). Filled in _ready().
var _streams := {}
## Every LIBRARY/MUSIC file that failed to load. Must stay empty (tests check).
var missing: Array[String] = []
## Diagnostics the tests read: plays per sound, and the last N plays with times.
var play_counts := {}
var history: Array = [] # [[msec, name], ...], newest last, capped
const HISTORY_CAP := 4000
var _last_play := {} # name (+ position bucket) -> msec
var _voices := {} # name -> Array of live players, oldest first
var _duck_left := 0.0
var _music_players: Array[AudioStreamPlayer] = []
var _music_active := 0 # index into _music_players of the one fading in / playing
var music_track := "" # what's playing ("" = silence)
var music_pitch := 1.0
## Times the music actually (re)started a track — tests check it isn't
## restarting every frame.
var music_starts := 0
## Off in tests that want silence-free logs; on by default.
var log_plays := true
## --sfx-log-all: log the quiet ones too (footsteps, impacts...) — playtest
## diagnostics.
var _log_all := "--sfx-log-all" in OS.get_cmdline_user_args()
const QUIET_LOG := ["footstep", "register_ding", "place_shelf", "impact_light", "impact_heavy", "box_thud", "mop", "broom", "clean_chime", "pickup", "drop", "throw", "ui_click", "forklift_beep", "forklift_alert"]

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_buses()
	for sound in LIBRARY:
		var list: Array[AudioStream] = []
		for f in LIBRARY[sound]["files"]:
			var s := _load("res://audio/%s.ogg" % f)
			if s:
				if LIBRARY[sound].get("loop", false):
					s.loop = true
				list.append(s)
		_streams[sound] = list
	for track in MUSIC:
		var s := _load("res://audio/%s.ogg" % MUSIC[track])
		if s:
			s.loop = true
			_streams["music:" + track] = [s]
	for i in 2:
		var p := AudioStreamPlayer.new()
		p.name = "Music%d" % i
		p.bus = BUS_MUSIC
		p.volume_db = -80.0
		add_child(p)
		_music_players.append(p)
	# Every button anywhere (menus, report, hub) clicks — one hook instead of
	# a line per button.
	get_tree().node_added.connect(_on_node_added)
	print("[Sfx] %d sounds, %d music tracks loaded%s" % [LIBRARY.size(), MUSIC.size(), ("  MISSING: " + ", ".join(missing)) if not missing.is_empty() else ""])

func _load(path: String) -> AudioStream:
	if not ResourceLoader.exists(path):
		missing.append(path)
		push_error("[Sfx] missing audio file: %s" % path)
		return null
	var s = load(path)
	if s == null:
		missing.append(path)
		push_error("[Sfx] failed to load audio file: %s" % path)
	return s

func _setup_buses() -> void:
	for bus_name in [BUS_MUSIC, BUS_SFX, BUS_HAZARD, BUS_UI]:
		if AudioServer.get_bus_index(bus_name) == -1:
			AudioServer.add_bus()
			var i := AudioServer.bus_count - 1
			AudioServer.set_bus_name(i, bus_name)
			AudioServer.set_bus_send(i, "Master")
		AudioServer.set_bus_volume_db(AudioServer.get_bus_index(bus_name), BUS_DB[bus_name])

func _on_node_added(node: Node) -> void:
	if node is BaseButton:
		node.pressed.connect(func(): play("ui_click"))

func has_sound(sound: String) -> bool:
	return _streams.has(sound) and not _streams[sound].is_empty()

## Plays `sound` on this peer only. Non-positional (heard the same anywhere).
## Returns the player, or null if it was rate-limited / unknown.
func play(sound: String, db_offset := 0.0, pitch := 1.0) -> Node:
	return _play(sound, null, db_offset, pitch)

## Plays `sound` on this peer only, at a world position (louder near this
## peer's camera, silent past MAX_DISTANCE).
func play_at(sound: String, pos: Vector2, db_offset := 0.0, pitch := 1.0) -> Node:
	return _play(sound, pos, db_offset, pitch)

## Host-only: plays `sound` at `pos` on EVERY peer (itself included). For
## host-only events with no replicated state to watch — physics impacts.
## Unreliable on purpose: a lost thud is fine, a late one isn't.
func broadcast_at(sound: String, pos: Vector2, db_offset := 0.0) -> void:
	if Net.is_active() and multiplayer.is_server():
		_net_play.rpc(sound, pos, db_offset)
	elif not Net.is_active():
		play_at(sound, pos, db_offset)

@rpc("authority", "call_local", "unreliable")
func _net_play(sound: String, pos: Vector2, db_offset: float) -> void:
	play_at(sound, pos, db_offset)

func _play(sound: String, pos: Variant, db_offset: float, pitch: float) -> Node:
	if not has_sound(sound):
		if not LIBRARY.has(sound):
			push_error("[Sfx] unknown sound: %s" % sound)
		return null
	var def: Dictionary = LIBRARY[sound]
	var now := Time.get_ticks_msec()
	# Positional sounds rate-limit per ~200px bucket, so two registers dinging
	# at once both play but one register can't machine-gun.
	var key := sound if pos == null else "%s@%d,%d" % [sound, int(pos.x / 200.0), int(pos.y / 200.0)]
	var cooldown_ms := int(def.get("cooldown", 0.0) * 1000.0)
	if _last_play.has(key) and now - _last_play[key] < cooldown_ms:
		return null
	_last_play[key] = now
	var stream_list: Array = _streams[sound]
	var p: Node
	if pos == null or not def.get("pos", false):
		p = AudioStreamPlayer.new()
	else:
		var p2 := AudioStreamPlayer2D.new()
		p2.max_distance = MAX_DISTANCE
		p2.attenuation = 1.2
		p = p2
	p.stream = stream_list[randi() % stream_list.size()]
	p.bus = def["bus"]
	p.volume_db = def.get("db", 0.0) + db_offset
	var spread: float = def.get("pitch", 0.0)
	p.pitch_scale = pitch * (1.0 + randf_range(-spread, spread))
	_add_voice(sound, p, int(def.get("voices", 4)))
	if p is AudioStreamPlayer2D:
		p.global_position = pos # once it's in the tree
	p.finished.connect(p.queue_free)
	p.play()
	if def.get("duck", false):
		_duck_left = DUCK_SECONDS
	play_counts[sound] = play_counts.get(sound, 0) + 1
	played.emit(sound, pos)
	history.append([now, sound])
	if history.size() > HISTORY_CAP:
		history = history.slice(history.size() - HISTORY_CAP / 2)
	if log_plays and (not QUIET_LOG.has(sound) or _log_all):
		print("[Sfx] %s%s (peer %d)" % [sound, "" if pos == null else " at (%.0f, %.0f)" % [pos.x, pos.y], multiplayer.get_unique_id() if Net.is_active() else 0])
	return p

## The scene the positional players live in: Main when it's up (so the
## camera there is their listener), this node otherwise.
func _voice_parent() -> Node:
	var scene := get_tree().current_scene
	return scene if scene != null else self

func _add_voice(sound: String, p: Node, max_voices: int) -> void:
	var live: Array = _voices.get(sound, []).filter(func(v): return is_instance_valid(v) and v.playing)
	while live.size() >= max_voices:
		var oldest: Node = live.pop_front()
		oldest.stop()
		oldest.queue_free()
	live.append(p)
	_voices[sound] = live
	_voice_parent().add_child(p)

## A looping player owned by the caller (the forklift engine): created once,
## the caller adjusts volume/pitch and stops it; Sfx never restarts it.
func make_loop(sound: String, parent: Node) -> AudioStreamPlayer2D:
	if not has_sound(sound):
		return null
	var p := AudioStreamPlayer2D.new()
	p.name = "Loop_" + sound
	p.stream = _streams[sound][0]
	p.bus = LIBRARY[sound]["bus"]
	p.volume_db = -80.0
	p.max_distance = MAX_DISTANCE * 0.8
	p.attenuation = 1.4
	parent.add_child(p)
	return p

## Which music should be playing; a no-op while it already is.
func set_music(track: String, pitch := 1.0) -> void:
	if track == music_track:
		if not is_equal_approx(pitch, music_pitch):
			music_pitch = pitch
			_music_players[_music_active].pitch_scale = pitch
		return
	music_track = track
	music_pitch = pitch
	_music_active = 1 - _music_active
	var p := _music_players[_music_active]
	if track == "" or not _streams.has("music:" + track):
		p.stop()
		return
	p.stream = _streams["music:" + track][0]
	p.pitch_scale = pitch
	p.volume_db = -40.0
	p.play()
	music_starts += 1
	print("[Sfx] music -> %s%s" % [track, "" if is_equal_approx(pitch, 1.0) else " x%.2f" % pitch])

func _process(delta: float) -> void:
	# Crossfade: the active track up to 0 dB (the bus sets the real level),
	# the other one down and stopped.
	for i in _music_players.size():
		var p := _music_players[i]
		if not p.playing:
			continue
		var target := 0.0 if i == _music_active and music_track != "" else -60.0
		p.volume_db = move_toward(p.volume_db, target, 60.0 / MUSIC_FADE * delta)
		if i != _music_active and p.volume_db <= -59.0:
			p.stop()
	_duck_left = maxf(0.0, _duck_left - delta)
	var music_bus := AudioServer.get_bus_index(BUS_MUSIC)
	var want: float = BUS_DB[BUS_MUSIC] + (DUCK_DB if _duck_left > 0.0 else 0.0)
	AudioServer.set_bus_volume_db(music_bus, move_toward(AudioServer.get_bus_volume_db(music_bus), want, 40.0 * delta))

## Tests: how many times `sound` played in the last `seconds`.
func plays_within(sound: String, seconds: float) -> int:
	var since := Time.get_ticks_msec() - int(seconds * 1000.0)
	var n := 0
	for h in history:
		if h[0] >= since and h[1] == sound:
			n += 1
	return n

## The busiest 1-second burst of each sound so far: {name: plays}.
func peak_rates(window_ms := 1000) -> Dictionary:
	var by_name := {}
	for h in history:
		if not by_name.has(h[1]):
			by_name[h[1]] = []
		by_name[h[1]].append(h[0])
	var out := {}
	for n in by_name:
		var times: Array = by_name[n]
		var best := 0
		var a := 0
		for b in times.size():
			while times[b] - times[a] > window_ms:
				a += 1
			best = maxi(best, b - a + 1)
		out[n] = best
	return out

## --sfx-report on the command line: a summary line at exit (playtest soaks).
func _exit_tree() -> void:
	if "--sfx-report" in OS.get_cmdline_user_args():
		var names: Array = play_counts.keys()
		names.sort()
		print("[Sfx] SUMMARY plays: %s" % ", ".join(names.map(func(n): return "%s=%d" % [n, play_counts[n]])))
		print("[Sfx] SUMMARY peak per second: %s  |  music starts %d  |  missing %s" % [str(peak_rates()), music_starts, str(missing)])
