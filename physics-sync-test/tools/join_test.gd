extends SceneTree
## The main menu's Host IP field (MenuLayer/Menu/IpInput) and the Join flow
## it feeds. Loads the real Main.tscn and drives the real game code. Not part
## of the game.
##
## Menu only (defaults, what _join_address() makes of blank/odd input, the
## immediate-failure path bringing the menu back):
##   godot --headless --path . --script res://tools/join_test.gd -- --no-save --test=join-menu
## A real join typed into the field — a host, then a client that clicks the
## field, types an address key by key, and clicks Join. Pass a NON-loopback
## address of this machine as --type-ip= so 127.0.0.1 can't mask a bug: the
## client checks the server peer it actually reached is at that address.
##   godot --headless --path . --script res://tools/join_test.gd -- --server --port=8951 --no-save --test=net-join &
##   godot --headless --path . --script res://tools/join_test.gd -- --connect-port=8951 --no-save --type-ip=192.168.1.20 --test=net-join
## --connect-ip= (the CLI way to fill the same field), with --client:
##   godot --headless --path . --script res://tools/join_test.gd -- --client --connect-port=8951 --connect-ip=192.168.1.20 --no-save --test=net-join-cli
## Screenshot of the menu (needs a renderer — xvfb-run, no --headless) to user://join_shots/:
##   xvfb-run -a godot --path . --script res://tools/join_test.gd -- --no-save --test=join-shot
## tools/run_join_tests.sh runs all of it.

var main: Node
var fails := 0
var type_ip := ""

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	root.get_node("Sfx").log_plays = false
	var mode := "join-menu"
	for a in args:
		if a.begins_with("--test="):
			mode = a.substr(7)
		elif a.begins_with("--type-ip="):
			type_ip = a.substr("--type-ip=".length())
	match mode:
		"join-menu":
			_run_menu.call_deferred()
		"join-shot":
			_run_shot.call_deferred()
		"net-join":
			if "--server" in args:
				_run_host.call_deferred()
			else:
				_run_typed_client.call_deferred()
		"net-join-cli":
			_run_cli_client.call_deferred()

## --- helpers ---------------------------------------------------------------------

func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1

func finish() -> void:
	print("RESULT: %s (%d failure%s)" % ["OK" if fails == 0 else "FAILED", fails, "" if fails == 1 else "s"])
	quit(1 if fails else 0)

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

## A real left click at the centre of a Control, through the viewport.
func click(c: Control) -> void:
	var at := c.get_global_rect().get_center()
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = at
		ev.global_position = at
		root.push_input(ev)
		await process_frame

## Types text into whatever has focus, one real key event per character.
func type_text(s: String) -> void:
	for ch in s:
		var ev := InputEventKey.new()
		ev.pressed = true
		ev.unicode = ch.unicode_at(0)
		ev.keycode = KEY_PERIOD if ch == "." else (OS.find_keycode_from_string(ch) as Key)
		root.push_input(ev)
		var up := ev.duplicate()
		up.pressed = false
		root.push_input(up)
		await process_frame

func server_peer_address() -> String:
	var peer := main.multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if peer == null:
		return ""
	var pp := peer.get_peer(1)
	return pp.get_remote_address() if pp else ""

## --- menu ------------------------------------------------------------------------

func _run_menu() -> void:
	await frames(3)
	var ip: LineEdit = main.ip_input
	check(main.menu_layer.visible, "J1: main menu up")
	check(ip != null and ip.visible, "J1: IP field present and visible")
	check(ip.text == "", "J1: IP field starts blank ('%s')" % ip.text)
	check(ip.placeholder_text == "127.0.0.1", "J1: placeholder shows 127.0.0.1 ('%s')" % ip.placeholder_text)
	check(main.join_button.text == "Join", "J1: Join button no longer claims a fixed IP ('%s')" % main.join_button.text)
	var kids: Array = main.get_node("MenuLayer/Menu").get_children()
	check(kids.find(ip) == kids.find(main.join_button) - 1, "J1: IP field sits right above Join")
	var cases := {
		"": "127.0.0.1",
		"   ": "127.0.0.1",
		"\t\n": "127.0.0.1",
		"26.14.120.7": "26.14.120.7",
		"  26.14.120.7  ": "26.14.120.7",
		"192.168.1.20\n": "192.168.1.20",
		"::1": "::1",
		"my-pc.local": "my-pc.local",
		"26.14.120.7:8910": "127.0.0.1",
		"26.14 .120.7": "127.0.0.1",
		"http://26.14.120.7": "127.0.0.1",
		"ip?": "127.0.0.1",
	}
	for typed in cases:
		ip.text = typed
		var got: String = main._join_address()
		check(got == cases[typed], "J2: %s -> %s (got %s)" % [JSON.stringify(typed), cases[typed], got])
	# Unresolvable name: create_client fails at once, connection_failed never
	# fires — the menu must come straight back instead of a blank screen.
	ip.text = "no-such-host.invalid"
	main._on_join_pressed()
	await frames(2)
	check(main.menu_layer.visible, "J3: menu back after a join that couldn't start")
	check(ip.text == "no-such-host.invalid", "J3: typed address kept for fixing")
	finish()

func _run_shot() -> void:
	main.ip_input.text = ""
	await frames(10)
	var dir := "user://join_shots/"
	DirAccess.make_dir_recursive_absolute(dir)
	var img := root.get_texture().get_image()
	img.save_png(dir + "menu_blank.png")
	main.ip_input.text = "26.14.120.7"
	await frames(5)
	root.get_texture().get_image().save_png(dir + "menu_typed.png")
	print("SHOT %s" % ProjectSettings.globalize_path(dir))
	finish()

## --- network ---------------------------------------------------------------------

func _run_host() -> void:
	var joined := await wait_until(func() -> bool: return main.multiplayer.get_peers().size() >= 1, 30.0)
	check(joined, "N1: host saw a client join")
	if joined:
		var peer := main.multiplayer.multiplayer_peer as ENetMultiplayerPeer
		var cid: int = main.multiplayer.get_peers()[0]
		print("INFO  client %d connected from %s" % [cid, peer.get_peer(cid).get_remote_address()])
		# Stay up until the client has checked its side and left.
		await wait_until(func() -> bool: return main.multiplayer.get_peers().is_empty(), 20.0)
	finish()

func _run_typed_client() -> void:
	# Headless windows are 64x64, which leaves Join off-screen for a click.
	root.size = Vector2i(960, 540)
	check(type_ip != "" and type_ip != "127.0.0.1", "N2: given a non-loopback address to type (%s)" % type_ip)
	await frames(3)
	var ip: LineEdit = main.ip_input
	await click(ip)
	check(ip.has_focus(), "N2: clicking the field focuses it")
	await type_text(type_ip)
	check(ip.text == type_ip, "N2: typed text landed in the field ('%s')" % ip.text)
	await click(main.join_button)
	check(not main.menu_layer.visible, "N2: clicking Join hid the menu")
	await _check_connected_to(type_ip)

func _run_cli_client() -> void:
	# --client presses Join itself after 1 s; --connect-ip= filled the field.
	var want := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--connect-ip="):
			want = a.substr("--connect-ip=".length())
	await frames(1)
	check(want != "" and main.ip_input.text == want, "N4: --connect-ip= filled the IP field ('%s')" % main.ip_input.text)
	await _check_connected_to(want)

func _check_connected_to(expected: String) -> void:
	# Net.is_active() alone is also true on the default offline peer.
	var ok := await wait_until(func() -> bool:
		return main.multiplayer.multiplayer_peer is ENetMultiplayerPeer and root.get_node("Net").is_active(), 15.0)
	check(ok, "N3: connected to the host")
	var addr := server_peer_address()
	check(addr == expected, "N3: server peer is at the typed address %s (got '%s')" % [expected, addr])
	check(addr != "127.0.0.1", "N3: not silently on 127.0.0.1")
	if ok:
		var spawned := await wait_until(func() -> bool:
			return main.players_root.get_node_or_null(str(main.multiplayer.get_unique_id())) != null, 10.0)
		check(spawned, "N3: host spawned our player")
	finish()
