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
##
## NOTE on Main.tscn's Shelf3/Shelf4 (Week 6 greybox layout): explained
## here, not in the .tscn, on purpose — this project already hit a real bug
## (see "Fix shelf invisibility: .tscn inline comment silently dropped the
## polygon") where a comment placed in a .tscn file silently corrupted the
## property after it instead of erroring, so nothing gets commented there
## anymore, full stop. Shelf3/Shelf4 mirror Shelf1/Shelf2 along the top wall
## instead of inventing new wall/divider geometry: a 180° rotation flips
## Shelf.gd's slots (local y=-70, i.e. "in front of" an unrotated shelf
## toward -y) to the opposite side, so these two face DOWN into the room
## the same way Shelf1/2 face UP into it. Checked against Shelf.gd's own
## collision math, not guessed: body spans y 42-108 there, slots land at
## y=130, both clear of the top wall (inner edge y=20) and of this file's
## PRODUCT_SPAWN_DELAY-triggered spawn band (y 120-360 in _spawn_product/
## _spawn_customer below). Result: a shelved wall on both sides of the room
## forms one legible central aisle, without interior divider walls whose
## collision shapes there's no way to verify visually in this environment
## (no Godot binary here to actually run and look at it). KNOWN COSMETIC
## QUIRK, not a bug: each slot's Indicator outline and "C" Prompt label
## (Shelf.tscn) rotate along with the 180° parent, so they render
## upside-down on these two shelves — functionally identical either way
## (Shelf.gd's placement math is orientation-agnostic), just backwards art,
## left for real slot art later rather than a dozen per-node rotation
## overrides to un-rotate text in a greybox.

const PlayerScene := preload("res://Player.tscn")
const ProductScene := preload("res://Product.tscn")
const CustomerScene := preload("res://Customer.tscn")
const SPAWN_CENTER := Vector2(480.0, 270.0) # players spread out around this point, not a specific object

## --- Week 4/5B shift-economy placeholders — every number below is a guess
## to make the system testable, not a tuned value. Flagging for design
## input once this is in your hands, not picking silently:
## - PRODUCT_BASELINE / PRODUCT_PER_EXTRA_PLAYER: as of Week 5B these are a
##   POOL CAP, not a one-time spawn — _restock_products() below tops the
##   floor back up to this count every RESTOCK_CHECK_INTERVAL, for as long
##   as the shift runs, since shoppers now permanently remove stock at the
##   cashier and there's no fixed target to stop refilling at. Still scales
##   UP with headcount, same reasoning as Week 4: solo gets a full pool,
##   not a thin trickle, and more players means proportionally more.
##   BASELINE bumped 6->12 for Week 6's larger store (4 shelves x 3 slots
##   instead of 2x3): the old value happened to exactly match the old total
##   slot count, so leaving it at 6 against 12 slots would mean half the
##   store stays visibly empty all shift even at a perfect stocking rate.
##   Doubling it to match is a judgment call to preserve that same ratio,
##   not a confirmed design decision — the Week 5B solo playtest (15 sold in
##   120s) was tuned against the smaller store, so this wants re-validating
##   against the fuller one, not assumed to still be right.
## - CUSTOMER_BASELINE / CUSTOMER_PER_EXTRA_PLAYER: same pool-cap shape,
##   for the combined shopper+disruptive population.
## - CUSTOMER_DISRUPTIVE_RATIO: what fraction of that population is
##   disruptive rather than shopper. My best guess for Day 1 is that it
##   should trend UP on later days (a calm first shift should be mostly
##   good pressure — restocking demand — with disruption as a minor
##   complication; escalating days should tilt toward more disruption),
##   mirroring the same "this wants to become per-day" placeholder shape
##   as SHIFT_DURATION_DEFAULT below. Left as a single Day-1 constant since
##   no day/level system exists yet to hang a per-day curve off of.
## - SHIFT_DURATION_DEFAULT: solo has no second player to create pressure,
##   so a countdown is solo's placeholder source of tension. Override with
##   --shift-seconds= for faster test iteration. Currently calibrated for a
##   calm Day 1 orientation shift specifically — later days are meant to
##   feel more pressured, so this single constant will want to become
##   per-day once a day/level system exists, not a permanent
##   one-size-fits-all value.
const PRODUCT_BASELINE := 12
const PRODUCT_PER_EXTRA_PLAYER := 3
const CUSTOMER_BASELINE := 3
const CUSTOMER_PER_EXTRA_PLAYER := 2
## Week 6: restored to 0.35 now that the spacebar defend/shove action
## (Player.gd's _try_defend(), Customer.gd's request_shove()) gives players
## an actual counter-play — disruptive customers are no longer pure
## unanswerable chaos. Still a placeholder value, like the rest of this
## block: it's an educated guess for Day 1, not a playtested number.
const CUSTOMER_DISRUPTIVE_RATIO := 0.35
const SHIFT_DURATION_DEFAULT := 120.0
## How long after hosting starts before the shift begins — gives CLI-
## launched bot/client processes a moment to connect first, so the product/
## customer counts reflect the actual party size instead of just the host
## alone. Placeholder: a real lobby would spawn on an explicit "ready up"
## instead of a fixed delay. Shortened 5.0->2.0 by request ("have them
## automatically start walking around once the game starts") — a solo
## human clicking Host Game doesn't need 5 whole seconds of an empty store
## before anything (products, customers) exists to see move; a CLI client
## launched separately still only needs ~1s (see its own await in
## _parse_cli_args) plus a moment for the ENet handshake, well under 2s.
const PRODUCT_SPAWN_DELAY := 2.0
## How often the population-maintenance check tops up products/customers
## back up to their pool caps. Shared by both since they're the same shape
## of system; no reason for them to run on different cadences right now.
const RESTOCK_CHECK_INTERVAL := 3.0

@onready var menu_layer: CanvasLayer = $MenuLayer
@onready var host_button: Button = $MenuLayer/Menu/HostButton
@onready var join_button: Button = $MenuLayer/Menu/JoinButton
@onready var debug_label: Label = $DebugLayer/DebugLabel
@onready var player_spawner: MultiplayerSpawner = $PlayerSpawner
@onready var players_root: Node2D = $Players
@onready var product_spawner: MultiplayerSpawner = $ProductSpawner
@onready var products_root: Node2D = $Products
@onready var customer_spawner: MultiplayerSpawner = $CustomerSpawner
@onready var customers_root: Node2D = $Customers

## Every RigidBody2D carrying a Carryable child, found generically instead
## of hardcoding "the crate" — Week 3 added Can/Box alongside it, and this
## list is what proves the pickup/carry system doesn't secretly still only
## work for one specific object. Week 4 removed those static test props
## from the default scene (their job — proving Carryable.gd generalizes —
## is already proven and committed); this now starts empty and stays that
## way unless static carryable props are added back to Main.tscn. Anything
## that must see EVERY carryable object including dynamically-spawned
## Products (e.g. the disconnect-safety sweep below) queries the "carryable"
## group live instead of reading this cached list.
var carryable_objects: Array[Node] = []
## Every ShelfBody found generically, same reasoning as carryable_objects.
var shelves: Array[Node] = []
## Every CashierBody found generically, same reasoning.
var cashiers: Array[Node] = []
var players := {} # peer_id -> Player node (populated on every peer)
var bot_mode := false
var bot_run_seconds := 20.0
## Which port a --client instance actually connects to. Lets us point a
## client at a local latency-simulating proxy (see tools/udp_delay_proxy.py)
## instead of the real host port, without touching Net.gd's own PORT
## constant (which is still what --server always listens on).
var connect_port := Net.PORT
## Per-bot role, index-matched to spawn order, set via --bot-roles=. Empty
## means every bot defaults to "contest" — the original Week 1-3 tug-of-war
## behavior, unchanged. Week 4 adds "stocker" and "interferer".
var bot_roles: Array[String] = []
var shift_duration := SHIFT_DURATION_DEFAULT
var shift_active := false
var shift_time_left := 0.0
var _shelf_log_timer := 0.0
var _restock_timer := 0.0
var _product_spawn_index := 0
var _customer_spawn_index := 0
## Unique synthetic carry-id pool for customers — decremented (stays
## negative) so it can never collide with a real ENet peer id, which is
## always positive. See Carryable.gd's _find_carrier() for why customers
## need this instead of reusing multiplayer authority.
var _next_customer_carry_id := -1

func _ready() -> void:
	# Children's _ready() runs before their parent's in Godot, so every
	# Carryable component has already added its body to the "carryable"
	# group by the time this line runs.
	carryable_objects = get_tree().get_nodes_in_group("carryable")
	shelves = get_tree().get_nodes_in_group("shelf")
	cashiers = get_tree().get_nodes_in_group("cashier")
	player_spawner.spawn_function = _spawn_player_node
	product_spawner.spawn_function = _spawn_product_node
	customer_spawner.spawn_function = _spawn_customer_node

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
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
	for arg in args:
		if arg.begins_with("--connect-port="):
			connect_port = int(arg.substr("--connect-port=".length()))
		elif arg.begins_with("--duration="):
			bot_run_seconds = float(arg.substr("--duration=".length()))
		elif arg.begins_with("--shift-seconds="):
			shift_duration = float(arg.substr("--shift-seconds=".length()))
		elif arg.begins_with("--bot-roles="):
			bot_roles.assign(arg.substr("--bot-roles=".length()).split(","))
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
	get_tree().create_timer(PRODUCT_SPAWN_DELAY).timeout.connect(_start_shift)

func _on_join_pressed() -> void:
	menu_layer.hide()
	Net.join_game("127.0.0.1", connect_port)

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

## Without this, a disconnected peer's Player node lingers forever (never
## despawned), a newly-joining peer gets told about it as if it were still
## connected (MultiplayerSpawner replicates spawn history to late joiners),
## and if that peer was carrying the crate when they dropped, the crate
## stays permanently frozen and un-droppable — confirmed by testing before
## this fix existed. Only the server actually frees the node (freeing a
## MultiplayerSpawner-spawned node on its authority side is what propagates
## the despawn to every other peer); every peer cleans up its own local
## bookkeeping dict regardless of role.
func _on_peer_disconnected(id: int) -> void:
	print("[Main] Peer disconnected: %d" % id)
	if multiplayer.is_server() and players.has(id):
		players[id].queue_free()
	players.erase(id)
	# Queried live, not via the cached carryable_objects list above — Week 4
	# products spawn dynamically after _ready() already ran once, so a
	# cached snapshot would silently miss them and leave one stuck un-
	# droppable if its carrier disconnected mid-carry, same bug class this
	# fix originally closed for the crate.
	for obj in get_tree().get_nodes_in_group("carryable"):
		obj.get_node("Carryable").force_drop_if_carrier(id)

## Spawns players spread evenly around SPAWN_CENTER (up to Net.MAX_PEERS) so
## 3-4 players can each approach from a different direction, and assigns
## each one a "primary" object to contest — round-robin across whatever
## carryable objects exist — so with N objects and M players, contention
## spreads across all of them instead of everyone piling onto one.
func _spawn_player(id: int) -> void:
	var index := players.size()
	var angle := index * (TAU / float(Net.MAX_PEERS))
	var spawn_pos := SPAWN_CENTER + Vector2.RIGHT.rotated(angle) * 220.0
	var target_name := ""
	if not carryable_objects.is_empty():
		target_name = carryable_objects[index % carryable_objects.size()].name
	# Empty (no --bot-roles=) means every bot keeps the original Week 1-3
	# "contest" behavior — this is purely additive, not a breaking change.
	var role := bot_roles[index % bot_roles.size()] if not bot_roles.is_empty() else "contest"
	player_spawner.spawn({"id": id, "pos": spawn_pos, "angle": angle, "target": target_name, "role": role})

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
	p.bot_angle = data["angle"]
	p.bot_target_name = data["target"]
	p.bot_role = data["role"]
	players[id] = p
	return p

## Called once, PRODUCT_SPAWN_DELAY after hosting starts, so CLI-launched
## bot/client processes have had a moment to connect and count toward the
## party size the pool-cap formulas scale against. Guarded so a stray extra
## call (there shouldn't be one) can't double-start the shift. Does an
## initial top-up immediately, then _process() below calls _restock_*()
## periodically for the rest of the shift — Week 5B removed the one-time
## fixed batch entirely: there's no finish line except the clock, so supply
## (product) and demand (customers) both have to keep replenishing for as
## long as the shift runs, not just spawn once and taper off.
func _start_shift() -> void:
	if not multiplayer.is_server() or shift_active:
		return
	shift_active = true
	print("[Main] Shift starting — %d player(s), %.0fs on the clock, no fixed stock target" % [players.size(), shift_duration])
	_restock_products()
	_restock_customers()
	shift_time_left = shift_duration

## Tops the floor back up to PRODUCT_BASELINE + PRODUCT_PER_EXTRA_PLAYER
## whenever it's fallen below that (shoppers permanently remove stock at
## the cashier, so this alone is what keeps the loop from ever running dry
## for the rest of the shift). Counts EVERY carryable object that currently
## exists anywhere — on the floor, placed on a shelf, or mid-carry by
## either a player or a customer — not just free-floating ones, since
## those all still count as "not yet sold" supply.
func _restock_products() -> void:
	var cap: int = PRODUCT_BASELINE + PRODUCT_PER_EXTRA_PLAYER * max(0, players.size() - 1)
	var current := get_tree().get_nodes_in_group("carryable").size()
	while current < cap:
		_spawn_product(_product_spawn_index)
		_product_spawn_index += 1
		current += 1

## Same shape as _restock_products(), for the combined shopper+disruptive
## population — tops back up to CUSTOMER_BASELINE + PER_EXTRA_PLAYER
## whenever a customer has despawned (finished shopping, gave up and left,
## or timed out), keeping demand and chaos both roughly constant across
## the whole shift instead of a batch that eventually all finish and go
## idle. Each new spawn's role is picked independently by
## CUSTOMER_DISRUPTIVE_RATIO, not assigned as a fixed up-front split.
func _restock_customers() -> void:
	var cap: int = CUSTOMER_BASELINE + CUSTOMER_PER_EXTRA_PLAYER * max(0, players.size() - 1)
	var current := get_tree().get_nodes_in_group("customer").size()
	while current < cap:
		var role := "disruptive" if randf() < CUSTOMER_DISRUPTIVE_RATIO else "shopper"
		_spawn_customer(role)
		current += 1

## Random within a band well clear of the shelves (y ~462-498), the walls,
## and the cashier (tucked against the left wall at x~40-100, well left of
## this band's x>=180 floor) — spawning a RigidBody2D overlapping a
## StaticBody2D's collider can make the physics engine's penetration-
## resolution fling it at an absurd speed to separate them, the same class
## of bug Week 1-3 hit with fast-moving objects tunneling through thin
## walls. Keeping spawns in open floor avoids ever creating that overlap in
## the first place.
func _spawn_product(index: int) -> void:
	var pos := Vector2(randf_range(180.0, 780.0), randf_range(120.0, 360.0))
	product_spawner.spawn({"index": index, "pos": pos})

func _spawn_product_node(data: Dictionary) -> Node:
	var p := ProductScene.instantiate()
	p.name = "Product%d" % data["index"]
	p.position = data["pos"]
	return p

## Same safe spawn band as products — customers are CharacterBody2Ds, not
## RigidBody2Ds, so they wouldn't get flung by a collision-shape overlap
## the way a product could, but starting them clear of the shelves/cashier
## still avoids an instant, confusing shove on spawn.
func _spawn_customer(role: String) -> void:
	var pos := Vector2(randf_range(180.0, 780.0), randf_range(120.0, 360.0))
	var carry_id := _next_customer_carry_id
	_next_customer_carry_id -= 1
	customer_spawner.spawn({"index": _customer_spawn_index, "pos": pos, "role": role, "carry_id": carry_id})
	_customer_spawn_index += 1

func _spawn_customer_node(data: Dictionary) -> Node:
	var c := CustomerScene.instantiate()
	c.name = "Customer%d" % data["index"]
	c.position = data["pos"]
	c.role = data["role"]
	c.carry_id = data["carry_id"]
	return c

func _process(delta: float) -> void:
	var connected := Net.is_active()
	var role := "OFFLINE"
	if connected:
		role = "HOST" if multiplayer.is_server() else "CLIENT"
	var lines := ["peer id: %d  (%s)  players: %d" % [
		multiplayer.get_unique_id() if connected else 0, role, players.size(),
	]]
	for obj in carryable_objects:
		var c: Node = obj.get_node("Carryable")
		var carried := "carried by %d" % c.carrier_id if c.carrier_id != 0 else "free"
		lines.append("%s: (%.0f, %.0f)  %s" % [obj.name, obj.position.x, obj.position.y, carried])

	if shift_active and shift_time_left > 0.0:
		shift_time_left = max(0.0, shift_time_left - delta)
	# Population maintenance — only the host actually spawns anything (both
	# _restock_* functions no-op their spawning on non-authority peers via
	# the spawners themselves being authority-driven), but the timer is
	# harmless to tick on every peer, so it's not worth an extra guard here.
	if shift_active and multiplayer.is_server():
		_restock_timer -= delta
		if _restock_timer <= 0.0:
			_restock_timer = RESTOCK_CHECK_INTERVAL
			_restock_products()
			_restock_customers()
	# Machine-readable, same purpose as GameLog's DATA lines: lets a test run
	# capture every peer's own view of shelf-fill state to a log file and
	# diff them afterward, to confirm the replicated "filled" array (see
	# Shelf.gd) actually agrees across peers instead of just trusting it
	# does.
	_shelf_log_timer -= delta
	if _shelf_log_timer <= 0.0:
		_shelf_log_timer = 1.0
		var my_id := multiplayer.get_unique_id() if connected else 0
		for shelf_body in shelves:
			var s_log: Node = shelf_body.get_node("Shelf")
			print("SHELFDATA,%s,%d,%d,%d" % [shelf_body.name, my_id, s_log.filled_count(), s_log.slot_count()])
		var total_sold_log := 0
		for cashier_body in cashiers:
			total_sold_log += cashier_body.get_node("Cashier").total_sold
		print("SOLDDATA,%d,%d" % [my_id, total_sold_log])
	var total_filled := 0
	var total_slots := 0
	for shelf_body in shelves:
		var shelf: Node = shelf_body.get_node("Shelf")
		var f: int = shelf.filled_count()
		var s: int = shelf.slot_count()
		total_filled += f
		total_slots += s
		lines.append("%s: %d/%d" % [shelf_body.name, f, s])
	var total_sold := 0
	for cashier_body in cashiers:
		total_sold += cashier_body.get_node("Cashier").total_sold
	# No fixed completion state as of Week 5B — stock demand is continuous
	# for the whole shift, so there's nothing to declare "complete." The
	# only thing that ends the shift is the clock; the ongoing scoreboard
	# (see the session's flagged scoring decision) is total items sold.
	if shift_active:
		lines.append("Stocked now: %d/%d  |  Sold: %d  |  %.0fs left" % [total_filled, total_slots, total_sold, shift_time_left])
		if shift_time_left <= 0.0:
			lines.append("SHIFT OVER — Sold: %d" % total_sold)
	debug_label.text = "\n".join(lines)
