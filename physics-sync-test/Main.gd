extends Node2D
## Wires everything together:
## - a Host/Join menu for manual two-window testing
## - command-line flags (--server / --client / --bot) for automated,
##   headless testing (no windows, no keyboard needed)
## - player spawning via MultiplayerSpawner
## - a simple on-screen debug readout of the crate's synced state
##
## NOTE on spawning: an earlier version of this file spawned players by hand
## with a custom RPC. That raced against the crate/player state-sync packets:
## those are sent UNRELIABLE (for speed), while a hand-written spawn RPC is
## RELIABLE, and ENet gives no ordering guarantee between packets sent on
## different channels/reliability modes. So a client could receive "player 1
## is at (x,y)" before it had even created player 1's node — "Node not
## found" errors. MultiplayerSpawner is Godot's built-in fix for exactly
## this: it guarantees a node is spawned locally before any sync data for it
## is processed, on every peer, including peers that join late.

const PlayerScene := preload("res://Player.tscn")
const CRATE_START := Vector2(480.0, 270.0)

@onready var menu_layer: CanvasLayer = $MenuLayer
@onready var host_button: Button = $MenuLayer/Menu/HostButton
@onready var join_button: Button = $MenuLayer/Menu/JoinButton
@onready var debug_label: Label = $DebugLayer/DebugLabel
@onready var crate: RigidBody2D = $Crate
@onready var player_spawner: MultiplayerSpawner = $PlayerSpawner
@onready var players_root: Node2D = $Players

var players := {} # peer_id -> Player node (populated on every peer)
var bot_mode := false
var bot_run_seconds := 20.0

func _ready() -> void:
	crate.position = CRATE_START
	player_spawner.spawn_function = _spawn_player_node

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(func():
		print("[Main] Host disconnected, quitting.")
		get_tree().quit()
	)

	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)

	_parse_cli_args()

func _parse_cli_args() -> void:
	var args := OS.get_cmdline_user_args()
	bot_mode = "--bot" in args
	if "--server" in args:
		_on_host_pressed()
	elif "--client" in args:
		# Give the separately launched host process a moment to start listening.
		await get_tree().create_timer(1.0).timeout
		_on_join_pressed()

func _on_host_pressed() -> void:
	menu_layer.hide()
	if not Net.host_game():
		return
	_spawn_player(multiplayer.get_unique_id())
	if bot_mode:
		_start_bot_timer()

func _on_join_pressed() -> void:
	menu_layer.hide()
	Net.join_game("127.0.0.1")

## connected_to_server fires once ENet finishes the handshake, which is when
## our peer id is guaranteed to be valid. The server spawns us (see
## _on_peer_connected); we don't need to ask for it.
func _on_connected_to_server() -> void:
	print("[Main] Connected — my peer id = %d" % multiplayer.get_unique_id())
	if bot_mode:
		_start_bot_timer()

## Fires if there was nothing to connect to (e.g. Join was clicked before
## anyone hosted). Reset and show the menu again instead of leaving the
## window stuck on a blank screen with no way back except relaunching.
func _on_connection_failed() -> void:
	print("[Main] Connection failed — is a host running? Showing menu again.")
	multiplayer.multiplayer_peer = null
	menu_layer.show()

func _start_bot_timer() -> void:
	var t := get_tree().create_timer(bot_run_seconds)
	t.timeout.connect(func():
		print("[Main] Bot test duration elapsed, quitting.")
		get_tree().quit()
	)

func _on_peer_connected(id: int) -> void:
	print("[Main] Peer connected: %d" % id)
	if multiplayer.is_server():
		_spawn_player(id)

func _spawn_player(id: int) -> void:
	var side := -1.0 if players.is_empty() else 1.0
	var spawn_pos := CRATE_START + Vector2(side * 220.0, 0.0)
	player_spawner.spawn({"id": id, "pos": spawn_pos, "side": side})

## Runs on every peer (called locally on the authority by .spawn(), and
## remotely on everyone else once MultiplayerSpawner delivers the spawn
## message) — this is what actually builds the node from the data payload.
func _spawn_player_node(data: Dictionary) -> Node:
	var id: int = data["id"]
	var p := PlayerScene.instantiate()
	p.name = str(id)
	p.position = data["pos"]
	p.set_multiplayer_authority(id)
	p.bot_mode = bot_mode
	p.bot_side = data["side"]
	players[id] = p
	return p

func _process(_delta: float) -> void:
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	var connected := peer != null and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED
	var role := "OFFLINE"
	if connected:
		role = "HOST" if multiplayer.is_server() else "CLIENT"
	debug_label.text = "peer id: %d  (%s)\ncrate pos: (%.1f, %.1f)\ncrate vel: (%.1f, %.1f)\nplayers: %d" % [
		multiplayer.get_unique_id() if connected else 0,
		role,
		crate.position.x, crate.position.y,
		crate.linear_velocity.x, crate.linear_velocity.y,
		players.size(),
	]
