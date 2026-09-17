extends Node
## Thin wrapper around Godot's high-level multiplayer API (ENet transport).
## This node only sets up the network connection. It knows nothing about
## players or the crate — that game logic lives in Main.gd. Keeping the two
## separate makes it obvious which part is "plumbing" (this file) and which
## part is "our game's rules" (Main.gd, Player.gd, Crate.gd).

const PORT := 8910
const MAX_PEERS := 4

func host_game(port := PORT) -> bool:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PEERS)
	if err != OK:
		push_error("[Net] host_game failed: %s" % error_string(err))
		return false
	multiplayer.multiplayer_peer = peer
	# The host is always assigned peer id 1 by Godot's MultiplayerAPI.
	print("[Net] Hosting on port %d — my peer id = %d" % [port, multiplayer.get_unique_id()])
	return true

func join_game(address: String, port := PORT) -> bool:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		push_error("[Net] join_game failed: %s" % error_string(err))
		return false
	multiplayer.multiplayer_peer = peer
	print("[Net] Connecting to %s:%d ..." % [address, port])
	return true

## Calling multiplayer.get_unique_id()/is_multiplayer_authority() on a peer
## that has just disconnected throws "multiplayer instance isn't active" —
## it briefly stays non-null but reports itself as inactive. Anything
## polling the network state every frame (like Crate/Player's _process)
## should check this first.
func is_active() -> bool:
	var peer := multiplayer.multiplayer_peer
	return peer != null and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED
