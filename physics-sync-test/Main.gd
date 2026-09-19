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
## NOTE on .tscn comments: nothing gets commented in any .tscn file in this
## project, full stop — see "Fix shelf invisibility: .tscn inline comment
## silently dropped the polygon" in the git log. A comment placed in a
## .tscn silently corrupted the property after it instead of erroring, so
## every explanation that would otherwise live next to Main.tscn's node
## definitions lives here instead.
##
## NOTE on each section's Shelf3/Shelf4 (Week 6 greybox layout, now reused
## across every section — see Part 1 below): a 180° rotation flips
## Shelf.gd's slots (local y=-70, i.e. "in front of" an unrotated shelf
## toward -y) to the opposite side, so these two face DOWN into the room
## the same way Shelf1/2 face UP into it. Checked against Shelf.gd's own
## collision math, not guessed: body spans local y 42-108 there, slots land
## at local y=130, both clear of the top wall (inner edge local y=20) and
## of this file's per-section product spawn band (local y 120-360 — see
## _spawn_pos_in_section below). Result: a shelved wall on both sides of
## each room forms one legible central aisle, without interior divider
## walls inside a section whose collision shapes there's no way to verify
## visually in this environment (no Godot binary here to actually run and
## look at it). KNOWN COSMETIC QUIRK, not a bug: each slot's Indicator
## outline and "C" Prompt label (Shelf.tscn) rotate along with the 180°
## parent, so they render upside-down on these shelves — functionally
## identical either way (Shelf.gd's placement math is orientation-
## agnostic), just backwards art, left for real slot art later rather than
## a dozen per-node rotation overrides to un-rotate text in a greybox.
##
## PART 1 — full store layout (Week 6): Main.tscn is 5 uniform ROOM_WIDTH x
## ROOM_HEIGHT rooms in a single left-to-right row sharing one continuous
## world — room 0 is the break room (always open, no gate), rooms 1-4 are
## Dry Goods/Meat-Deli/Dairy-Frozen/Bakery, each behind its own Gate (see
## Gate.gd) except the break-room<->Dry-Goods doorway, which has no gate at
## all since Dry Goods is available from Day 1. Reused Shelf.tscn/
## Product.tscn/Cashier.tscn verbatim per the brief's "light re-theming,
## not unique content per zone" — each section's shelves are the identical
## Shelf1-4 layout Dry Goods already used, just modulate-tinted, and every
## room additionally gets a flat background-color Polygon2D plus a large
## text label (see Main.tscn's SectionLabels) for at-a-glance section
## identification. The store being wider than one screen is why
## Player.tscn now carries a Camera2D (see Player.gd) — this project had
## no scrolling/camera concept before Part 1 needed one.
##
## REDESIGNED after playtest feedback: Gate.gd originally sat in a narrow
## ~120px doorway cut into two permanent wall segments per boundary, and
## multiple NPCs pathing through that one opening at once jammed up. Fixed
## by removing the doorway concept entirely — a Gate's own collision now
## spans the section boundary's FULL playable height (500px, see
## Gate.tscn), so a locked boundary is sealed edge-to-edge (nothing to
## funnel through even while locked) and an unlocked one opens across the
## WHOLE boundary at once. Main.tscn no longer has separate wall segments
## at a section boundary at all. SECTION_COLORS below is the other
## playtest-driven addition: each section's products and shelf slot
## indicators now share an accent color (Shelf.gd's apply_accent_color(),
## called from _apply_section_accent_colors() below) so a product visually
## signals which shelf it belongs on, the same way the indicators already
## signal an empty slot.

const PlayerScene := preload("res://Player.tscn")
const ProductScene := preload("res://Product.tscn")
const CustomerScene := preload("res://Customer.tscn")
## Room 0 (the break room) center — unchanged from before Part 1, since
## room 0 happens to occupy the exact same world coordinates the old
## single-room store used to. Players spawn here, not in Dry Goods: you
## clock in at the break room and walk the always-open doorway into Dry
## Goods to start your shift.
const SPAWN_CENTER := Vector2(480.0, 270.0) # players spread out around this point, not a specific object

const ROOM_WIDTH := 960.0
const ROOM_HEIGHT := 540.0
const NUM_ROOMS := 5 # break room + 4 retail sections, single left-to-right row (see Main.tscn)
const WORLD_WIDTH := ROOM_WIDTH * NUM_ROOMS
const WORLD_HEIGHT := ROOM_HEIGHT
## room_index matches each section's position in Main.tscn's row (0 = break
## room, not listed here since it has no gate and no shelves). required_day
## mirrors the brief's Day 1-2 / 3-4 / 5-6 / 7 schedule exactly, and is also
## what _configure_gates() below sets on each matching Gate instance by
## node name (not a .tscn property override — see that function's own
## comment on why), so this table and the actual physical doors can't
## quietly drift apart from each other.
const SECTIONS := [
	{"name": "Dry Goods", "node_name": "DryGoods", "room_index": 1, "required_day": 1},
	{"name": "Meat/Deli", "node_name": "MeatDeli", "room_index": 2, "required_day": 3},
	{"name": "Dairy/Frozen", "node_name": "DairyFrozen", "room_index": 3, "required_day": 5},
	{"name": "Bakery", "node_name": "Bakery", "room_index": 4, "required_day": 7},
]
## Per-section accent color, shared by that section's spawned products
## (_spawn_product_node below) and its shelf slot indicators
## (_apply_section_accent_colors below) — the color-coordination playtest
## request. Dry Goods keeps the ORIGINAL always-yellow indicator color
## exactly (1, 0.9, 0.3) rather than picking something new for it; its
## products change color to match (were plain green before), not the
## other way around, since the indicator color already existed everywhere
## and a product's color was always arbitrary.
const SECTION_COLORS := {
	"Dry Goods": Color(1, 0.9, 0.3, 1),
	"Meat/Deli": Color(0.85, 0.25, 0.25, 1),
	"Dairy/Frozen": Color(0.35, 0.6, 0.9, 1),
	"Bakery": Color(0.85, 0.6, 0.25, 1),
}
## Multiplies onto a locked section's normal shelf/cashier/background/label
## color (_apply_section_lock_visuals below) so it reads as visibly
## inactive rather than identical to an unlocked one — placeholder
## darkening amount, wants a look before calling it final.
const LOCKED_DIM := Color(0.55, 0.55, 0.55, 1)
## WEEK 7: real day progression. debug_day is now ONLY the requested
## STARTING day, read once from --day=N (see _parse_cli_args) and applied
## to current_day the moment hosting begins (_on_host_pressed) — it has no
## further effect after that. current_day is the actual, live, host-
## authoritative day counter: it advances on its own when a shift's clock
## runs out (_end_shift), which is the real thing driving section gates
## now, not a flag anyone has to remember to pass. A client no longer
## needs to pass --day= at all — only the host's copy is ever consulted,
## since current_day reaches every peer via replication (see _day_sync in
## _ready()), the same pattern every other piece of shared state in this
## project already uses.
var debug_day := 1
## The real, live day counter — host-authoritative, replicated via
## _day_sync (see _ready()). Every peer reacts to CHANGES in this value
## (not just reads it) via the check at the top of _process(), which also
## catches a late-joining client up to whatever day is already in
## progress, the same self-healing property Shelf.gd's `filled` array
## already relies on for late joiners.
var current_day := 1
## Sentinel (-1, below any real day) guarantees the first _process() tick
## on EVERY peer — host at start, or a client the moment current_day's
## first replicated value arrives — runs _configure_gates()/
## _apply_section_lock_visuals() at least once, without a separate
## "initial setup" call duplicating that logic.
var _last_configured_day := -1
## FLAGGED DESIGN DECISION — score/sold-count continuity across days,
## explicitly asked to be surfaced rather than picked silently:
##
## My recommendation is to track BOTH a per-day count and a running week
## total, rather than choosing one over the other. They answer different
## questions — a per-day number says "was today better than yesterday,"
## a week total says "how did the whole week go" — and dropping either
## loses a real, distinct piece of feedback a player would want. Keeping
## both costs nothing extra: Cashier.gd's total_sold already never resets
## (it's the natural week/session total), so "today's sold" is just that
## cumulative number minus a snapshot taken at the moment the day's shift
## began (_sold_at_day_start below, set in _start_shift()). See
## _process()'s debug HUD for both numbers shown side by side.
##
## If you'd rather have just one: for "reset each day," drop
## _sold_at_day_start and always display _total_sold() itself, resetting
## each cashier's total_sold to 0 in _start_shift() instead of snapshotting
## it — a bigger change, since total_sold is a REPLICATED cashier
## property, not something Main.gd owns directly. For "accumulate only,"
## just drop the "today" number from the HUD and keep showing
## _total_sold() labeled as the running total — no code change needed
## beyond the display line. I picked "track both" as the default because
## it's the only option that doesn't foreclose either interpretation once
## you've actually played a multi-day session and have an opinion.
var _sold_at_day_start := 0
## Non-empty during either stage of the day transition (see _end_shift()/
## _begin_next_day()) — "Day N complete! Sold today: X | Week total: Y",
## then "Starting Day N+1..." — replicated via _day_sync so every peer
## shows the same message at the same time. Empty = normal shift or the
## pre-shift menu.
var day_transition_message := ""
## Stage 1: how long the end-of-day report stays up before moving to
## stage 2 — playtest request for "a real 'how'd you do' moment," not
## just an immediate "next day" message. Placeholder, not tuned.
const DAY_REPORT_PAUSE := 5.0
## Stage 2: how long "Starting Day N+1..." stays up before the next
## day's shift actually begins — placeholder, not tuned; "doesn't need to
## be polished, just functional" per the original brief, so both stages
## are debug-label messages, not a real pause/blocking screen. Gameplay
## keeps running underneath either one (players can still walk around);
## only the economy (_restock_*) is paused, via the same shift_active
## guard those already checked.
const DAY_TRANSITION_PAUSE := 3.0

## --- Week 4/5B/6 shift-economy placeholders — every number below is a
## guess to make the system testable, not a tuned value. Flagging for
## design input once this is in your hands, not picking silently:
## - Product/customer baselines: as of Week 5B these are a POOL CAP, not a
##   one-time spawn — _restock_products()/_restock_customers() below top
##   the floor back up to their cap every RESTOCK_CHECK_INTERVAL, for as
##   long as the shift runs, since shoppers now permanently remove stock at
##   the cashier and there's no fixed target to stop refilling at. Still
##   scales UP with headcount (PRODUCT/CUSTOMER_PER_EXTRA_PLAYER), same
##   reasoning as Week 4: solo gets a full pool, not a thin trickle.
##   AS OF WEEK 6 PART 1, the baseline itself also scales with how many
##   sections are currently unlocked (_product_baseline()/
##   _customer_baseline() below), not a flat constant — the OLD flat
##   PRODUCT_BASELINE=12 happened to exactly match Dry-Goods-only's total
##   slot count (4 shelves x 3 slots), so leaving it flat while later days
##   open 2-4 more sections would mean most of the newly-opened floor sits
##   empty all shift even at a perfect stocking rate. Scaling it by
##   unlocked-section-count preserves that same "baseline ~= reachable slot
##   count" ratio Week 6 already established — a judgment call, not a
##   confirmed design decision, and CUSTOMER_BASELINE scaling the same way
##   is an extra judgment call on top of that (the brief didn't ask for it,
##   but a customer population that stays flat while the floor quadruples
##   would read as an increasingly empty store). Day 1-2 behavior is
##   unaffected either way (1 section unlocked = the exact old numbers).
##   The Week 5B solo playtest (15 sold in 120s) was tuned against the
##   original single-section store, so ANY of this wants re-validating at
##   later days, not assumed to still be right.
## - CUSTOMER_DISRUPTIVE_RATIO: what fraction of the customer population is
##   disruptive rather than shopper. My best guess for Day 1 is that it
##   should trend UP on later days (a calm first shift should be mostly
##   good pressure — restocking demand — with disruption as a minor
##   complication; escalating days should tilt toward more disruption),
##   mirroring the same "this wants to become per-day" placeholder shape
##   as SHIFT_DURATION_DEFAULT below. Left as a single Day-1 constant since
##   — even with Week 7's real current_day counter now driving section
##   gates — there's still no per-day CURVE system to hang a ratio-by-day
##   formula off of, just a live day number.
## - SHIFT_DURATION_DEFAULT: solo has no second player to create pressure,
##   so a countdown is solo's placeholder source of tension. Override with
##   --shift-seconds= for faster test iteration. Currently calibrated for a
##   calm Day 1 orientation shift specifically — later days are meant to
##   feel more pressured, so this single constant will want to become
##   per-day once a day/level system exists, not a permanent
##   one-size-fits-all value.
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
## Playtest request: no customer (shopper or disruptive) restocking for
## this long after a shift starts, giving the player/team a head start to
## get initial product stocked before anyone shows up to buy or disrupt
## it. Applies to EVERY day, not just Day 1, since _customer_grace_timer
## is reset in _start_shift(), which now runs at the start of every day
## (see its own comment). Products are NOT held back the same way —
## _restock_products() still runs immediately, since there'd be nothing
## to stock during the grace period otherwise. Placeholder, not tuned.
const CUSTOMER_GRACE_PERIOD := 9.0

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
## Counts down from CUSTOMER_GRACE_PERIOD at the start of every shift (see
## _start_shift()); while positive, _process()'s restock check skips
## _restock_customers() entirely (products are unaffected). Host-only
## state — never replicated, since clients don't call _restock_customers()
## themselves anyway (the spawner-authority check inside already no-ops
## their call), so there's nothing for a client to react to here.
var _customer_grace_timer := 0.0
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
	_apply_section_accent_colors()
	_cache_original_colors()
	player_spawner.spawn_function = _spawn_player_node
	product_spawner.spawn_function = _spawn_product_node
	customer_spawner.spawn_function = _spawn_customer_node

	# WEEK 7 — host-authoritative day/shift state, replicated to every peer
	# the same way every other piece of shared state in this project is
	# (see Carryable/Shelf/Cashier's own near-identical setup). Added to
	# Main's own root node rather than a spawned child: Main is present,
	# identically, on every peer from the start (it's the scene root, not
	# something MultiplayerSpawner creates), so a late joiner gets caught
	# up to the CURRENT values automatically via plain ALWAYS-mode sync —
	# no special "catch up a new joiner" RPC needed, the same reasoning
	# Shelf.gd's `filled` array already relies on. shift_active/
	# shift_time_left are included here too, not just current_day/
	# day_transition_message/_sold_at_day_start: they used to tick down
	# independently on every peer, which was harmless only because
	# shift_active never actually changed value before Week 7's day-end/
	# transition/next-shift cycle existed — an un-replicated client-local
	# copy would otherwise just stay true forever, never showing the
	# transition message a client should see.
	var day_sync := MultiplayerSynchronizer.new()
	var day_config := SceneReplicationConfig.new()
	for prop in [".:current_day", ".:day_transition_message", ".:_sold_at_day_start", ".:shift_active", ".:shift_time_left"]:
		var path := NodePath(prop)
		day_config.add_property(path)
		day_config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	day_sync.replication_config = day_config
	day_sync.name = "DaySync" # explicit, identical name on every peer — see Player.gd's note on why an auto-generated name breaks replication
	day_sync.set_multiplayer_authority(1)
	add_child(day_sync)

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
		elif arg.begins_with("--day="):
			debug_day = int(arg.substr("--day=".length()))
	if "--server" in args:
		_on_host_pressed()
	elif "--client" in args:
		# Give the separately launched host process a moment to start listening.
		await get_tree().create_timer(1.0).timeout
		_on_join_pressed()

## Sets every Gate's locked/unlocked state from current_day. Node name ->
## required_day is matched here in code, NOT via a .tscn property override
## on the nested "Gate" child of each Gate.tscn instance — this project
## already lost a shelf polygon once to a .tscn property silently
## corrupted by an inline comment (see the file-header NOTE on .tscn
## comments above), and while a property override isn't a comment, I
## couldn't be fully certain of Godot's exact nested-instance-override
## syntax without a way to load and inspect the scene here — a plain
## name->value lookup in plain GDScript is just as easy and isn't a syntax
## I have to trust blind. Called from _process()'s day-change check now
## (Week 7), not from _parse_cli_args() — every peer reacts uniformly to
## current_day actually changing (initial arrival or a later day-advance),
## rather than each peer computing it once from its own local CLI flag.
func _configure_gates() -> void:
	var required_days := {"GateMeatDeli": 3, "GateDairyFrozen": 5, "GateBakery": 7}
	for gate_body in get_tree().get_nodes_in_group("gate"):
		var gate: Node = gate_body.get_node("Gate")
		if required_days.has(gate_body.name):
			gate.required_day = required_days[gate_body.name]
		gate.configure(current_day)

## Recolors every shelf's slot indicators to match its section's accent
## color (SECTION_COLORS above), called once from _ready(). Matches each
## shelf to a section by WORLD x-position (same room_index math
## is_unlocked_at_x uses below), not by node path or name, so it doesn't
## care what a given section's shelves happen to be called.
func _apply_section_accent_colors() -> void:
	for shelf_body in shelves:
		var idx := int(floor(shelf_body.global_position.x / ROOM_WIDTH))
		for section in SECTIONS:
			if section["room_index"] == idx:
				var shelf: Node = shelf_body.get_node("Shelf")
				shelf.accent_color = SECTION_COLORS[section["name"]]
				shelf.apply_accent_color()
				break

## Playtest feedback: a locked section previously looked completely
## normal except for the Gate's own thin barrier line at its entrance —
## easy to miss, and gave no sense at a glance that the whole section was
## inactive. Darkens every locked section's shelves, cashier, floor tint,
## and label together. Unlocked sections (including Dry Goods, which is
## never locked) are restored to their ORIGINAL color, not just left
## alone — WEEK 7 CHANGE: this now runs every time current_day changes
## (see _process()'s day-change check), not just once at startup, since a
## section can go from locked to unlocked mid-session. Recomputing from
## the cached _original_*_color dictionaries (populated once by
## _cache_original_colors() in _ready()) rather than multiplying
## LOCKED_DIM onto whatever the PREVIOUS call left behind is what keeps a
## still-locked section from getting darker on every single day-advance,
## and correctly brightens a section the moment it unlocks.
func _apply_section_lock_visuals() -> void:
	for section in SECTIONS:
		var unlocked: bool = current_day >= section["required_day"]
		var room_x: float = section["room_index"] * ROOM_WIDTH
		var room_x_end: float = room_x + ROOM_WIDTH
		for shelf_body in shelves:
			if shelf_body.global_position.x >= room_x and shelf_body.global_position.x < room_x_end:
				var base: Color = _original_shelf_modulate[shelf_body]
				shelf_body.modulate = base if unlocked else base * LOCKED_DIM
		for cashier_body in cashiers:
			if cashier_body.global_position.x >= room_x and cashier_body.global_position.x < room_x_end:
				var base: Color = _original_cashier_modulate[cashier_body]
				cashier_body.modulate = base if unlocked else base * LOCKED_DIM
		var bg := get_node_or_null("RoomBackgrounds/%sBg" % section["node_name"])
		if bg:
			var base_bg: Color = _original_bg_color[section["node_name"]]
			bg.color = base_bg if unlocked else base_bg * LOCKED_DIM
		var label := get_node_or_null("SectionLabels/%s/Label" % section["node_name"])
		if label:
			label.modulate = Color(1, 1, 1, 1) if unlocked else LOCKED_DIM

## Snapshots every shelf/cashier/background's color BEFORE any locking
## dims it, so _apply_section_lock_visuals() above always has an
## undimmed original to compute from no matter how many times (or in
## what order) it later runs. Called once from _ready(); order relative
## to _apply_section_accent_colors() doesn't matter, since that touches a
## different property (Shelf.gd's own accent_color/indicator, not the
## ShelfBody root's modulate this reads).
var _original_shelf_modulate := {} # shelf_body (Node) -> Color
var _original_cashier_modulate := {} # cashier_body (Node) -> Color
var _original_bg_color := {} # section node_name (String) -> Color

func _cache_original_colors() -> void:
	for shelf_body in shelves:
		_original_shelf_modulate[shelf_body] = shelf_body.modulate
	for cashier_body in cashiers:
		_original_cashier_modulate[cashier_body] = cashier_body.modulate
	for section in SECTIONS:
		var bg := get_node_or_null("RoomBackgrounds/%sBg" % section["node_name"])
		if bg:
			_original_bg_color[section["node_name"]] = bg.color

func _on_host_pressed() -> void:
	menu_layer.hide()
	if not Net.host_game():
		return
	# WEEK 7: only the HOST's --day= (or the default of 1) decides the
	# real starting day now — a client's own --day=, if it even passed
	# one, is simply never consulted, since current_day reaches every
	# peer via replication (see _day_sync in _ready()). Applying it
	# (gates, lock visuals) isn't done here — the day-change check at the
	# top of _process() handles that uniformly for every peer, whether
	# it's the very first tick or a later day-advance.
	current_day = debug_day
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

## Repositions every connected player to the break room (spread out the
## same way _spawn_player() spreads out initial spawns) — called at the
## start of every day's shift (_start_shift() below), not just the first.
## PLAYTEST BUG FIX: before this existed, nothing ever moved a player
## after their initial spawn — _start_shift() was reused for every day,
## but it never touched player position, so Day 2+ just left everyone
## wherever Day 1's shift happened to end. Player.gd's teleport_to() is an
## RPC, not a direct .position set, because movement here is client-
## authoritative (see Player.gd's own header) — Main.gd runs on the host,
## which generally ISN'T a remote client's own player's authority, so it
## has to ASK that peer's own copy of the node to move itself, the same
## "any peer may ask, only the authority acts" shape used elsewhere in
## this project (e.g. Carryable.gd's request_push).
func _reset_players_to_break_room() -> void:
	var index := 0
	for id in players:
		var angle := index * (TAU / float(Net.MAX_PEERS))
		var pos := SPAWN_CENTER + Vector2.RIGHT.rotated(angle) * 220.0
		players[id].rpc("teleport_to", pos)
		index += 1

## Called once, PRODUCT_SPAWN_DELAY after hosting starts, so CLI-launched
## bot/client processes have had a moment to connect and count toward the
## party size the pool-cap formulas scale against. Guarded so a stray extra
## call (there shouldn't be one) can't double-start the shift. Does an
## initial product top-up immediately, then _process() below calls
## _restock_products()/_restock_customers() periodically for the rest of
## the shift — Week 5B removed the one-time fixed batch entirely: there's
## no finish line except the clock, so supply has to keep replenishing for
## as long as the shift runs, not just spawn once and taper off.
## Customers are NOT restocked here — see CUSTOMER_GRACE_PERIOD below;
## _process()'s periodic restock check is what actually starts spawning
## them, once the grace period elapses.
##
## Also the entry point for every day AFTER the first — _begin_next_day()
## below calls this exact same function once its pause elapses, rather
## than a separate "day 2+" code path. Nothing here resets or despawns
## existing PRODUCTS or shelf state between days (only _restock_products()
## topping up to the — likely now-larger, since more sections may have
## just unlocked — cap changes anything); it DOES reset player position
## (_reset_players_to_break_room, playtest bug fix) and the customer
## population (see CUSTOMER_GRACE_PERIOD's own comment on why existing
## customers aren't force-cleared, just new spawning paused).
func _start_shift() -> void:
	if not multiplayer.is_server() or shift_active:
		return
	shift_active = true
	_sold_at_day_start = _total_sold()
	_customer_grace_timer = CUSTOMER_GRACE_PERIOD
	_restock_timer = 0.0
	_reset_players_to_break_room()
	print("[Main] Day %d shift starting — %d player(s), %.0fs on the clock, %.0fs customer grace period, no fixed stock target" % [current_day, players.size(), shift_duration, CUSTOMER_GRACE_PERIOD])
	_restock_products()
	shift_time_left = shift_duration

## Host-only: called the instant the clock hits zero (see _process()'s
## shift-timer check). This is STAGE 1 of the day transition — the
## end-of-day report the brief asked for ("a real 'how'd you do' moment",
## not just an immediate "next day" message): shows today's and the
## week's sold count for DAY_REPORT_PAUSE seconds (replicated via
## _day_sync, so every peer reads the same numbers at the same time),
## THEN moves to _begin_next_day() (stage 2) below. Gameplay keeps running
## during both stages (players can still walk around, a shopper mid-
## purchase can still complete it — Cashier.gd/Shelf.gd don't check
## shift_active at all); only the economy restock is paused, via the same
## shift_active guard _process() already checks before calling
## _restock_*().
func _end_shift() -> void:
	if not multiplayer.is_server() or not shift_active:
		return
	shift_active = false
	var today_sold := _total_sold() - _sold_at_day_start
	var week_sold := _total_sold()
	day_transition_message = "Day %d complete!  Sold today: %d  |  Week total: %d" % [current_day, today_sold, week_sold]
	print("[Main] %s" % day_transition_message)
	get_tree().create_timer(DAY_REPORT_PAUSE).timeout.connect(_begin_next_day)

## Host-only: STAGE 2 of the day transition, run once the end-of-day
## report (_end_shift() above) has been up for DAY_REPORT_PAUSE seconds.
## Advances current_day and — PLAYTEST BUG FIX — reconfigures gates/lock
## visuals EXPLICITLY and IMMEDIATELY right here, rather than relying only
## on _process()'s day-change poll to catch it on the next frame. That
## poll should already do this correctly (it's still there, and is what
## catches a client up via replication), but a playtest report found
## newly-unlocked sections not actually opening on a day advance, and I
## couldn't rule out some interaction with it I hadn't spotted without a
## way to run the game here — so the host now does it directly and
## unconditionally at the one moment "a new day started" unambiguously
## means something, instead of trusting an async side effect alone.
func _begin_next_day() -> void:
	if not multiplayer.is_server():
		return
	current_day += 1
	_configure_gates()
	_apply_section_lock_visuals()
	_last_configured_day = current_day
	day_transition_message = "Starting Day %d..." % current_day
	print("[Main] %s" % day_transition_message)
	get_tree().create_timer(DAY_TRANSITION_PAUSE).timeout.connect(func():
		day_transition_message = ""
		_start_shift()
	)

## Cumulative total across every cashier, for as long as the session has
## run — never reset, unlike _sold_at_day_start (see the score-continuity
## comment above _sold_at_day_start's declaration). Used both directly (as
## the week/session total) and as the basis for "today's sold"
## (_total_sold() - _sold_at_day_start) in _process()'s debug HUD and
## _end_shift()'s report.
func _total_sold() -> int:
	var total := 0
	for cashier_body in cashiers:
		total += cashier_body.get_node("Cashier").total_sold
	return total

## Tops the floor back up to _product_baseline() + PRODUCT_PER_EXTRA_PLAYER
## whenever it's fallen below that (shoppers permanently remove stock at
## the cashier, so this alone is what keeps the loop from ever running dry
## for the rest of the shift). Counts EVERY carryable object that currently
## exists anywhere — on the floor, placed on a shelf, or mid-carry by
## either a player or a customer — not just free-floating ones, since
## those all still count as "not yet sold" supply.
func _restock_products() -> void:
	var cap: int = _product_baseline() + PRODUCT_PER_EXTRA_PLAYER * max(0, players.size() - 1)
	var current := get_tree().get_nodes_in_group("carryable").size()
	while current < cap:
		_spawn_product(_product_spawn_index)
		_product_spawn_index += 1
		current += 1

## Same shape as _restock_products(), for the combined shopper+disruptive
## population — tops back up to _customer_baseline() + PER_EXTRA_PLAYER
## whenever a customer has despawned (finished shopping, gave up and left,
## or timed out), keeping demand and chaos both roughly constant across
## the whole shift instead of a batch that eventually all finish and go
## idle. Each new spawn's role is picked independently by
## CUSTOMER_DISRUPTIVE_RATIO, not assigned as a fixed up-front split.
func _restock_customers() -> void:
	var cap: int = _customer_baseline() + CUSTOMER_PER_EXTRA_PLAYER * max(0, players.size() - 1)
	var current := get_tree().get_nodes_in_group("customer").size()
	while current < cap:
		var role := "disruptive" if randf() < CUSTOMER_DISRUPTIVE_RATIO else "shopper"
		_spawn_customer(role)
		current += 1

## --- Week 6 Part 1: section helpers --------------------------------------

func _unlocked_sections() -> Array:
	var result := []
	for section in SECTIONS:
		if current_day >= section["required_day"]:
			result.append(section)
	return result

## True if the given WORLD x-coordinate falls inside a section that's
## currently unlocked. Used to keep the debug HUD and the restock-baseline
## scaling honest about which shelves are actually reachable this session
## — a shelf behind a locked gate physically exists (so the day advancing
## past it mid-session doesn't need new scene content) but isn't "in play"
## for either purpose until its gate opens.
##
## Public (no underscore), unlike this file's other section helpers,
## because Customer.gd calls it too (via get_tree().current_scene, not a
## preload — Main.gd already preloads Customer.tscn to spawn customers, so
## preloading Main.gd back from Customer.gd would be a cyclic preload,
## same real GDScript failure mode Player.gd's WORLD_WIDTH/HEIGHT comment
## already flags. A live node reference from the scene tree doesn't have
## that restriction, since it's a runtime lookup, not a parse-time
## import). Playtest feedback found shopper/disruptive target-picking
## (Customer.gd's _find_stocked_item/_find_nearest_cashier/
## _pick_browse_target/_pick_disruptive_target) had no concept of
## section-lock at all — a shopper standing near a boundary could target
## the NEAREST cashier by raw distance regardless of which side of a
## locked gate it was on, then get stuck trying to reach it, which read as
## "the barrier isn't really blocking anything." This is the fix: those
## searches now skip anything in a locked section outright, so a shopper
## has no awareness a locked section's cashier/shelves exist at all, not
## just a physical inability to reach them.
func is_unlocked_at_x(world_x: float) -> bool:
	var idx := int(floor(world_x / ROOM_WIDTH))
	for section in SECTIONS:
		if section["room_index"] == idx:
			return current_day >= section["required_day"]
	return false # room 0 (break room) has no shelves, so never matters here

## 12 = one section's slot count (4 shelves x 3 slots) — see the big
## comment block above CUSTOMER_BASELINE for why these scale with
## unlocked-section-count instead of staying flat, and why that's flagged
## as a judgment call rather than a confirmed decision.
func _product_baseline() -> int:
	return 12 * _unlocked_sections().size()

func _customer_baseline() -> int:
	return CUSTOMER_BASELINE * _unlocked_sections().size()

## Picks a random CURRENTLY UNLOCKED section (never the break room: nothing
## to stock or shop for there, and a locked section has no way out anyway).
func _pick_unlocked_section() -> Dictionary:
	var unlocked := _unlocked_sections()
	return unlocked[randi() % unlocked.size()] # always has at least Dry Goods (required_day=1)

## A spawn point inside the given section's safe interior band — same
## shape/margins the original single-room band always used (clear of
## shelves at local y ~42-108/432-498, the walls, and the cashier), just
## relocated per section by its room_index. Spawning a RigidBody2D (a
## product) overlapping a StaticBody2D's collider can make the physics
## engine's penetration-resolution fling it at an absurd speed to separate
## them, the same class of bug Week 1-3 hit with fast-moving objects
## tunneling through thin walls — keeping spawns in open floor avoids ever
## creating that overlap in the first place.
func _spawn_pos_in_section(section: Dictionary) -> Vector2:
	var room_x: float = section["room_index"] * ROOM_WIDTH
	return Vector2(randf_range(room_x + 180.0, room_x + 780.0), randf_range(120.0, 360.0))

## Playtest request: customers should spawn at a defined ENTRANCE to
## whichever section they're assigned to, then walk inward using their
## existing target-picking AI (Customer.gd's _find_stocked_item/
## _pick_browse_target/_pick_disruptive_target — unchanged, this only
## moves WHERE they start), rather than appearing already scattered
## around the section's interior. Placed just past each section's LEFT
## boundary — the doorway/gate a customer would actually walk in
## through — comfortably clear of that section's own cashier: every
## section's Cashier1 sits at local x=70 with a 60px-wide collision box
## (half-width 30), so x=190 clears it by a wide margin, and the same
## offset works for every section since they're all uniform ROOM_WIDTH
## rooms. Small random jitter so several customers spawning together
## don't stack exactly on top of each other, while still reading as "came
## in the same door."
func _customer_entrance_pos(section: Dictionary) -> Vector2:
	var room_x: float = section["room_index"] * ROOM_WIDTH
	return Vector2(room_x + 190.0 + randf_range(-15.0, 15.0), 270.0 + randf_range(-40.0, 40.0))

## Products are colored to match the section they spawn in (SECTION_COLORS
## above), the same accent color as that section's shelf slot indicators —
## the color-coordination playtest request. A product spawned for Dry
## Goods only ever gets carried onto a Dry Goods shelf in the normal flow
## anyway (shoppers/players walk it to whichever shelf is closest, which
## is overwhelmingly its own section), so tagging it by spawn section
## reads as "this belongs here" without needing an actual placement
## restriction — Shelf.gd still accepts any free item on any shelf,
## unchanged, matching how this project's components generally stay
## ignorant of concerns outside their own job.
func _spawn_product(index: int) -> void:
	var section := _pick_unlocked_section()
	product_spawner.spawn({
		"index": index,
		"pos": _spawn_pos_in_section(section),
		"color": SECTION_COLORS[section["name"]],
	})

func _spawn_product_node(data: Dictionary) -> Node:
	var p := ProductScene.instantiate()
	p.name = "Product%d" % data["index"]
	p.position = data["pos"]
	p.get_node("Polygon2D").color = data["color"]
	return p

## Spawns at the assigned section's ENTRANCE (see _customer_entrance_pos),
## not a random interior position — customers are CharacterBody2Ds, not
## RigidBody2Ds, so they wouldn't get flung by a collision-shape overlap
## the way a product could, but starting clear of the cashier still avoids
## an instant, confusing shove on spawn.
func _spawn_customer(role: String) -> void:
	var pos := _customer_entrance_pos(_pick_unlocked_section())
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
	# WEEK 7 — runs on every peer, purely reactive to current_day (which is
	# host-authoritative, replicated — see _day_sync in _ready()), not
	# something this check itself changes. Catches: the very first tick on
	# any peer (thanks to _last_configured_day's sentinel), a later day-
	# advance on the host, and a late-joining client the moment
	# current_day's first replicated value arrives — one code path for all
	# three instead of separate "initial setup" and "day changed" cases.
	if current_day != _last_configured_day:
		_last_configured_day = current_day
		_configure_gates()
		_apply_section_lock_visuals()
		print("[Main] Day is now %d" % current_day)

	var connected := Net.is_active()
	var role := "OFFLINE"
	if connected:
		role = "HOST" if multiplayer.is_server() else "CLIENT"
	var lines := ["peer id: %d  (%s)  players: %d  day: %d" % [
		multiplayer.get_unique_id() if connected else 0, role, players.size(), current_day,
	]]
	for obj in carryable_objects:
		var c: Node = obj.get_node("Carryable")
		var carried := "carried by %d" % c.carrier_id if c.carrier_id != 0 else "free"
		lines.append("%s: (%.0f, %.0f)  %s" % [obj.name, obj.position.x, obj.position.y, carried])

	# WEEK 7: host-authoritative now, not ticked locally on every peer —
	# see _ready()'s _day_sync comment for why an un-replicated
	# shift_active/shift_time_left became a real bug once a shift could
	# actually END and transition, not just count down forever.
	if multiplayer.is_server() and shift_active and shift_time_left > 0.0:
		shift_time_left = max(0.0, shift_time_left - delta)
		if shift_time_left <= 0.0:
			_end_shift()
	# Population maintenance — only the host actually spawns anything (both
	# _restock_* functions no-op their spawning on non-authority peers via
	# the spawners themselves being authority-driven), but the timer is
	# harmless to tick on every peer, so it's not worth an extra guard here.
	if shift_active and multiplayer.is_server():
		if _customer_grace_timer > 0.0:
			_customer_grace_timer = max(0.0, _customer_grace_timer - delta)
		_restock_timer -= delta
		if _restock_timer <= 0.0:
			_restock_timer = RESTOCK_CHECK_INTERVAL
			_restock_products()
			# Customers wait out CUSTOMER_GRACE_PERIOD (see _start_shift())
			# before this ever fires — products above are never held back
			# the same way, so there's something to stock during the grace
			# window, not just an empty floor.
			if _customer_grace_timer <= 0.0:
				_restock_customers()
	# Only currently-unlocked shelves count below (log, HUD, and the
	# stocked/sold totals) — a locked section's shelves physically exist
	# (so the day advancing past it mid-session doesn't need new scene
	# content) but are never reachable, so counting them would misreport
	# "half the store sits empty" against sections nobody could have
	# stocked yet.
	var unlocked_shelves := shelves.filter(func(s): return is_unlocked_at_x(s.global_position.x))
	# Machine-readable, same purpose as GameLog's DATA lines: lets a test run
	# capture every peer's own view of shelf-fill state to a log file and
	# diff them afterward, to confirm the replicated "filled" array (see
	# Shelf.gd) actually agrees across peers instead of just trusting it
	# does.
	_shelf_log_timer -= delta
	if _shelf_log_timer <= 0.0:
		_shelf_log_timer = 1.0
		var my_id := multiplayer.get_unique_id() if connected else 0
		for shelf_body in unlocked_shelves:
			var s_log: Node = shelf_body.get_node("Shelf")
			print("SHELFDATA,%s,%d,%d,%d" % [shelf_body.name, my_id, s_log.filled_count(), s_log.slot_count()])
		print("SOLDDATA,%d,%d,%d" % [my_id, current_day, _total_sold()])
	var total_filled := 0
	var total_slots := 0
	for shelf_body in unlocked_shelves:
		var shelf: Node = shelf_body.get_node("Shelf")
		var f: int = shelf.filled_count()
		var s: int = shelf.slot_count()
		total_filled += f
		total_slots += s
		lines.append("%s: %d/%d" % [shelf_body.name, f, s])
	# No fixed completion state as of Week 5B — stock demand is continuous
	# for the whole shift, so there's nothing to declare "complete" within
	# a day. WEEK 7: the clock now ends the DAY, not the session — see
	# _end_shift(). Both a per-day and a running week total are shown; see
	# the flagged score-continuity comment above _sold_at_day_start.
	if day_transition_message != "":
		lines.append("=== %s ===" % day_transition_message)
	elif shift_active:
		var week_sold := _total_sold()
		var today_sold := week_sold - _sold_at_day_start
		lines.append("Stocked now: %d/%d  |  Today: %d  |  Week total: %d  |  %.0fs left" % [total_filled, total_slots, today_sold, week_sold, shift_time_left])
	debug_label.text = "\n".join(lines)
