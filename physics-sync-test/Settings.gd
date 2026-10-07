extends Node
## OCT 2026 PHASE 4C — the player's settings: volume, display and key
## bindings. Autoloaded as "Settings" (project.godot, after Sfx so its buses
## exist), so they're loaded and applied before the first menu is drawn.
##
## STORED ON THEIR OWN, in user://settings.cfg (a ConfigFile), never in the
## shift save: they belong to this PC, not to the crew, so a new game, an old
## save set aside, or a different host never touches them, and SaveGame.gd's
## format didn't change for them. A missing file is the defaults; a file
## that won't parse, or a value of the wrong type or out of range, falls
## back to the default for that value (and the next change rewrites a clean
## file). --settings-file=<path> points tests somewhere else.
##
## Every change applies at once and is saved at once.
##
## KEYS. The game has two key sets (project.godot): host_* (WASD/E/F/C/
## Space), read when this PC hosts or plays solo, and client_* (arrows/
## Enter/./Slash/Space), read when it joined someone else's game (Player.gd).
## Both can be rebound; each binding is one physical key, stored by
## physical keycode. Binding a key already used by another action in the same
## set SWAPS the two, so no action is ever left without a key. Esc (menu),
## F11 (fullscreen), F3 (debug) and Tab (skip practice) are fixed.
## key()/move_keys() give every on-screen prompt the key actually bound.

signal changed

const DEFAULT_PATH := "user://settings.cfg"
const BUS_MASTER := "Master"

## Rebindable actions, in the order the Controls tab lists them.
const ACTIONS := ["move_up", "move_down", "move_left", "move_right", "interact", "throw", "place", "defend"]
const ACTION_NAMES := {
	"move_up": "Move up",
	"move_down": "Move down",
	"move_left": "Move left",
	"move_right": "Move right",
	"interact": "Interact · grab · drop",
	"throw": "Throw",
	"place": "Place on shelf · use mop/broom (hold)",
	"defend": "Shove",
}
const PREFIXES := ["host_", "client_"]
## Never rebindable: they do something on their own (see header).
const RESERVED := [KEY_ESCAPE, KEY_F11, KEY_F3, KEY_TAB]
const RESERVED_WHY := {KEY_ESCAPE: "the menu", KEY_F11: "fullscreen", KEY_F3: "the debug readout", KEY_TAB: "skipping practice"}

var path := DEFAULT_PATH
## 0..1, linear (the sliders' 0-100%).
var master := 1.0
var music := 1.0
var sfx := 1.0
var fullscreen := false
var vsync := true
## What load_settings() found: "ok", "missing" or "corrupt" (tests read it).
var load_status := "missing"
## full action name -> physical keycode, as project.godot ships them.
var _defaults := {}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--settings-file="):
			path = arg.substr("--settings-file=".length())
	for p in PREFIXES:
		for a in ACTIONS:
			_defaults[p + a] = key_of(p + a)
	load_settings()
	apply_all()

## F11 anywhere — menus, a shift, paused.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F11:
		set_fullscreen(not fullscreen)
		get_viewport().set_input_as_handled()

## --- File ---------------------------------------------------------------------

## Reads `path` into the fields above (defaults for anything missing or bad).
## Bindings are applied to the InputMap here; audio/display by apply_all().
func load_settings() -> String:
	master = 1.0
	music = 1.0
	sfx = 1.0
	fullscreen = false
	vsync = true
	_restore_default_keys()
	if not FileAccess.file_exists(path):
		load_status = "missing"
		print("[Settings] No settings file at %s — defaults" % path)
		return load_status
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		load_status = "corrupt"
		print("[Settings] %s couldn't be read — defaults" % path)
		return load_status
	load_status = "ok"
	master = _volume(cfg.get_value("audio", "master", 1.0))
	music = _volume(cfg.get_value("audio", "music", 1.0))
	sfx = _volume(cfg.get_value("audio", "sfx", 1.0))
	var fs = cfg.get_value("display", "fullscreen", false)
	fullscreen = fs if fs is bool else false
	var vs = cfg.get_value("display", "vsync", true)
	vsync = vs if vs is bool else true
	if cfg.has_section("controls"):
		for p in PREFIXES:
			var used := {}
			var want := {}
			for a in ACTIONS:
				var k = cfg.get_value("controls", p + a, _defaults[p + a])
				if not (k is int) or k <= 0 or k in RESERVED or used.has(k):
					k = _defaults[p + a] # bad or duplicate: this one keeps its default
				used[k] = true
				want[p + a] = k
			# Only if the whole set is still one key per action (a default
			# brought back above could collide with a saved one).
			if used.size() == ACTIONS.size():
				for full in want:
					_set_key(full, want[full])
	print("[Settings] Loaded %s — master %d%%, music %d%%, sfx %d%%, %s, vsync %s" % [path, roundi(master * 100), roundi(music * 100), roundi(sfx * 100), "fullscreen" if fullscreen else "windowed", "on" if vsync else "off"])
	return load_status

func _volume(v) -> float:
	if not (v is float or v is int):
		return 1.0
	return clampf(float(v), 0.0, 1.0)

func save_settings() -> bool:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "master", master)
	cfg.set_value("audio", "music", music)
	cfg.set_value("audio", "sfx", sfx)
	cfg.set_value("display", "fullscreen", fullscreen)
	cfg.set_value("display", "vsync", vsync)
	for p in PREFIXES:
		for a in ACTIONS:
			cfg.set_value("controls", p + a, key_of(p + a))
	var dir := path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var err := cfg.save(path)
	if err != OK:
		push_warning("[Settings] couldn't write %s: %s" % [path, error_string(err)])
	return err == OK

## --- Applying -----------------------------------------------------------------

func apply_all() -> void:
	_apply_audio()
	_apply_display()
	changed.emit()

func _apply_audio() -> void:
	var m := AudioServer.get_bus_index(BUS_MASTER)
	AudioServer.set_bus_volume_db(m, linear_to_db(maxf(master, 0.0001)))
	AudioServer.set_bus_mute(m, master <= 0.0)
	var s := get_node_or_null("/root/Sfx")
	if s:
		s.set_user_volume("music", music)
		s.set_user_volume("sfx", sfx)

func _apply_display() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var mode := DisplayServer.window_get_mode()
	var is_fs := mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	if fullscreen and not is_fs:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	elif not fullscreen and is_fs:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)

## kind: "master", "music" or "sfx"; v: 0..1.
func set_volume(kind: String, v: float) -> void:
	v = clampf(v, 0.0, 1.0)
	match kind:
		"master": master = v
		"music": music = v
		"sfx": sfx = v
		_: return
	_apply_audio()
	save_settings()
	changed.emit()

func volume(kind: String) -> float:
	return {"master": master, "music": music, "sfx": sfx}.get(kind, 1.0)

func set_fullscreen(on: bool) -> void:
	fullscreen = on
	_apply_display()
	save_settings()
	changed.emit()
	print("[Settings] %s" % ("fullscreen" if on else "windowed"))

func set_vsync(on: bool) -> void:
	vsync = on
	_apply_display()
	save_settings()
	changed.emit()

## --- Keys -----------------------------------------------------------------------

## The physical keycode bound to a full action name ("host_interact"), 0 if none.
func key_of(full: String) -> int:
	if not InputMap.has_action(full):
		return 0
	for e in InputMap.action_get_events(full):
		if e is InputEventKey:
			return e.physical_keycode if e.physical_keycode != 0 else e.keycode
	return 0

func _set_key(full: String, physical: int) -> void:
	for e in InputMap.action_get_events(full):
		if e is InputEventKey:
			InputMap.action_erase_event(full, e)
	var ev := InputEventKey.new()
	ev.physical_keycode = physical as Key
	InputMap.action_add_event(full, ev)

func _restore_default_keys() -> void:
	for full in _defaults:
		_set_key(full, _defaults[full])

func default_key(full: String) -> int:
	return _defaults.get(full, 0)

## Binds `physical` to `full`. Returns {ok, why, swapped: "" or the other
## action's full name (which now has `full`'s old key)}.
func rebind(full: String, physical: int) -> Dictionary:
	if not _defaults.has(full):
		return {"ok": false, "why": "unknown action", "swapped": ""}
	if physical in RESERVED:
		return {"ok": false, "why": "%s is for %s" % [key_name(physical), RESERVED_WHY[physical]], "swapped": ""}
	if physical <= 0:
		return {"ok": false, "why": "not a key", "swapped": ""}
	var old := key_of(full)
	var prefix: String = "host_" if full.begins_with("host_") else "client_"
	var swapped := ""
	if physical != old:
		for a in ACTIONS:
			var other: String = prefix + a
			if other != full and key_of(other) == physical:
				_set_key(other, old)
				swapped = other
		_set_key(full, physical)
	save_settings()
	changed.emit()
	print("[Settings] %s -> %s%s" % [full, key_name(physical), ("  (swapped: %s -> %s)" % [swapped, key_name(old)]) if swapped != "" else ""])
	return {"ok": true, "why": "", "swapped": swapped}

func reset_controls() -> void:
	_restore_default_keys()
	save_settings()
	changed.emit()
	print("[Settings] controls reset to defaults")

func controls_are_default() -> bool:
	for full in _defaults:
		if key_of(full) != _defaults[full]:
			return false
	return true

const _NICE := {KEY_PERIOD: ".", KEY_SLASH: "/", KEY_COMMA: ",", KEY_SEMICOLON: ";", KEY_APOSTROPHE: "'", KEY_BRACKETLEFT: "[", KEY_BRACKETRIGHT: "]", KEY_MINUS: "-", KEY_EQUAL: "=", KEY_BACKSLASH: "\\", KEY_QUOTELEFT: "`"}

## A key's on-screen name ("E", "Space", "Enter", "/"), from its physical
## code — for a non-QWERTY layout, the letter printed where that key is.
func key_name(physical: int) -> String:
	if physical <= 0:
		return "—"
	var code := physical
	if DisplayServer.get_name() != "headless":
		var mapped := DisplayServer.keyboard_get_keycode_from_physical(physical as Key)
		if mapped != KEY_NONE:
			code = mapped
	if _NICE.has(code):
		return _NICE[code]
	return OS.get_keycode_string(code)

func key_label(full: String) -> String:
	return key_name(key_of(full))

## Which key set this PC is reading right now (Player.gd's rule): host_ when
## hosting, playing solo or not connected; client_ when joined to a host.
func local_prefix() -> String:
	var mp := get_tree().get_multiplayer()
	var peer := mp.multiplayer_peer
	var connected := peer != null and not (peer is OfflineMultiplayerPeer) and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED
	return "client_" if connected and not mp.is_server() else "host_"

## The key this PC presses for `action` ("interact", "place", ...).
func key(action: String, prefix := "") -> String:
	return key_label((prefix if prefix != "" else local_prefix()) + action)

## The four movement keys as a prompt says them: "WASD", "arrow keys", or
## the four in up/left/down/right order ("IJKL").
func move_keys(prefix := "") -> String:
	var p := prefix if prefix != "" else local_prefix()
	var k := [key_of(p + "move_up"), key_of(p + "move_left"), key_of(p + "move_down"), key_of(p + "move_right")]
	if k == [KEY_UP, KEY_LEFT, KEY_DOWN, KEY_RIGHT]:
		return "arrow keys"
	var names := k.map(func(c): return key_name(c))
	if names.all(func(n): return n.length() == 1):
		return "".join(names)
	return "/".join(names)
