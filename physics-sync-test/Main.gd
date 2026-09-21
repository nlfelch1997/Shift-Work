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
## NOTE on each section's Shelf3/Shelf4 (Week 6 greybox layout, reused
## across Meat/Deli, Dairy/Frozen, and Bakery — see Part 1 below): a 180°
## rotation flips Shelf.gd's slots (local y=-70, i.e. "in front of" an
## unrotated shelf toward -y) to the opposite side, so these two face DOWN
## into the room the same way Shelf1/2 face UP into it. Checked against
## Shelf.gd's own collision math, not guessed: body spans local y 42-108
## there, slots land at local y=130, both clear of the top wall (inner
## edge local y=20) and of this file's per-section product spawn band
## (local y 120-360 — see _spawn_pos_in_section below). Result: a shelved
## wall on both sides of each room forms one legible central aisle,
## without interior divider walls inside a section whose collision shapes
## there's no way to verify visually in this environment (no Godot binary
## here to actually run and look at it). KNOWN COSMETIC QUIRK, not a bug:
## each slot's Indicator outline and "C" Prompt label (Shelf.tscn) rotate
## along with the parent, so they render upside-down at 180° (or sideways
## at ±90°, see Dry Goods below) — functionally identical either way
## (Shelf.gd's placement math is orientation-agnostic: every check it does
## — capture radius, color-matching, nearest-slot search — reads
## global_position and the object's own color, never a hardcoded facing —
## so no shelf-specific code anywhere needs to know or care which way a
## shelf is rotated), just backwards/sideways art, left for real slot art
## later rather than a dozen per-node rotation overrides to fix text
## orientation in a greybox.
##
## DRY GOODS IS THE ONE SECTION THAT DOESN'T USE THE ABOVE PATTERN.
## PLAYTEST ROOT-CAUSE FIX ("customers can only approach shelves from
## behind, sway stuck at them"): the up/down-facing pattern above only
## works because Meat/Deli, Dairy/Frozen, and Bakery are all entered
## HORIZONTALLY (their only customer-reachable connection is an east-west
## boundary with the hub or with Dry Goods — see the GRID MAP comment
## below), perpendicular to their shelves' vertical facing, so a customer
## walking through the aisle reaches a shelf's front without ever crossing
## its own collision box. Dry Goods is entered VERTICALLY instead — its
## only customer-reachable connection is its SOUTH edge, to the hub — so
## the same up/down-facing layout would need a customer to walk THROUGH
## Shelf1/2's box to reach their north-facing fronts, since those two sit
## nearest the entrance with their fronts pointed away from it. Dry
## Goods' 4 shelves are instead rotated ±90° (1.57079633 / 4.71238898) to
## flank the EAST and WEST walls, fronts facing sideways into a
## north-south aisle — perpendicular to the south entrance, the same
## structural relationship the other three sections already have to
## their own entrances, just rotated a quarter turn to match Dry Goods'
## own entrance direction. Verified clear of both the product spawn band
## and the room's interior bounds by direct calculation (rotating the
## collision box and slot offsets by hand, not guessed): Shelf1/2 (west,
## y=130/410, rotation 1.57079633) box lands at world x:[1042,1108],
## y:[40,220]/[320,500]; Shelf3/4 (east, same y's, rotation 4.71238898)
## box lands at x:[1772,1838]. Both clear of the spawn band (x:[1140,1740],
## y:[120,360]) and well inside the room's interior (x:[980,1900],
## y:[20,520]).
##
## PART 1 — full store layout (Week 6): originally Main.tscn was 7 uniform
## ROOM_WIDTH x ROOM_HEIGHT rooms in a single left-to-right ROW sharing one
## continuous world (see git history for that layout). THIS SESSION replaced
## that with a HUB-AND-SPOKE layout: the store is now a 3x3 grid of
## ROOM_WIDTH x ROOM_HEIGHT cells (GRID_COLS x GRID_ROWS), addressed by a
## Vector2i(col, row) instead of a single 1D room_index — see the GRID MAP
## comment below for which cell holds what. This is a direct root-cause fix
## for a recurring bug pattern: THREE separate playtest rounds hit customer-
## timeout bugs traced back to the store's shape specifically — a single
## line that only ever gets LONGER as rooms are added, so the worst-case
## walk (and therefore the dynamic lifetime budget it drives — see
## Customer.gd's _extend_lifetime_budget()) kept growing right along with
## it. A compact grid bounds that worst-case walk by the grid's diagonal
## instead of its perimeter: the old 7-room line's worst case (break room to
## Bakery) was 6*ROOM_WIDTH = 5760px; this grid's worst case (Sidewalk to
## Bakery, the two most distant CUSTOMER-relevant cells) is
## sqrt((2*ROOM_WIDTH)^2+(2*ROOM_HEIGHT)^2) ≈ 2202px — well under half — and
## critically, adding another future spoke to the one still-open grid cell
## (see GRID MAP below) doesn't grow that worst case anywhere near as fast
## as appending a room to a line does.
##
## Mechanically, nothing about how a "room" is built changed — reused
## Shelf.tscn/Product.tscn verbatim per the brief's "light re-theming, not
## unique content per zone" — each section's shelves are the identical
## Shelf1-4 layout Dry Goods already used, just modulate-tinted, and every
## room still gets a flat background-color Polygon2D plus a large text label
## (see Main.tscn's SectionLabels) for at-a-glance section identification.
## Only WHERE each room sits changed: every place that used to do
## `room_index * ROOM_WIDTH` now does `grid_pos.x * ROOM_WIDTH, grid_pos.y *
## ROOM_HEIGHT` — see is_unlocked_at_pos()/is_break_room_at_pos() (renamed
## from the old _at_x() forms, since an x-only check can no longer tell two
## stacked cells apart) for the canonical version of that math. The store
## being bigger than one screen in BOTH dimensions now (not just wide) is
## why Player.tscn's Camera2D (see Player.gd) needs both limit_right AND
## limit_bottom updated, not just the one this project's first-ever
## scrolling camera originally needed.
##
## GRID MAP (col, row), 3x3, hub in the center — the ROOM_INDEX MAP this
## replaces went through three playtest-driven reorderings of its own (see
## git history), so this map is deliberately kept in ONE place (here) rather
## than re-derived per file:
##   (0,0) Break Room   (1,0) Dry Goods (Day 1)   (2,0) Bakery (Day 7)
##   (0,1) Dairy/Frozen (1,1) CHECKOUT HUB         (2,1) Meat/Deli (Day 3)
##   (0,2) [reserved]   (1,2) Sidewalk (entrance)  (2,2) Storage (Day 1)
## The hub (Checkout, CentralCheckout in Main.tscn) sits dead center with
## every spoke touching it or one hop off it — Dry Goods, Meat/Deli, Dairy/
## Frozen, and Sidewalk are the four cells directly adjacent to the hub
## (the brief's "north/east/west/south" arrangement); Bakery branches off
## Dry Goods (both day-1-or-later retail, same north arm) and Storage
## branches off Sidewalk (both are "outside access" — customers walk in via
## Sidewalk, and the forklift will eventually bring deliveries in via
## Storage — see that room's own comment below) rather than off the hub
## directly, since the hub only has 4 flat edges to attach to. Break Room
## branches off Dry Goods too — deliberately NOT off Sidewalk or the hub,
## the two cells actually in a customer's path — per the existing
## exclusion-zone approach (is_break_room_at_pos(), unchanged in kind, just
## upgraded from a 1D check to a 2D one) rather than a physical door: a
## customer is simply never given a target inside it, wherever it sits, but
## putting it a hop away from the high-traffic cells is extra insurance the
## old design already valued (see its own comment further down). (0,2) is
## the one grid cell nothing occupies — left that way on purpose as
## breathing room for whatever gets added next, instead of this layout
## being exactly as full as today's store and needing its own reshape the
## next time something new is added, the same trap the old line was in.
## It's still part of the single open floor (no wall seals it off — see
## Main.tscn's Walls), just empty.
##
## Three real interior walls exist BECAUSE of this shape, which the old
## line-of-rooms never needed at all: Break Room/Dairy-Frozen, Bakery/Meat-
## Deli, and Meat-Deli/Storage each sit diagonally-adjacent-by-row across a
## shared edge that ISN'T an intentional spoke connection, so each gets a
## permanent WallSeal segment (same StaticBody2D+CollisionShape2D shape the
## world's own perimeter walls already use, just interior and row-width
## sized) instead of being left open, which would let a customer walk into
## e.g. Bakery from Meat/Deli and bypass GateBakery entirely. Every
## INTENTIONAL spoke connection (hub<->DryGoods, hub<->Sidewalk, DryGoods<->
## BreakRoom, Sidewalk<->Storage) stays a plain open boundary with no wall
## at all, same as the old line's ungated boundaries; hub<->MeatDeli, hub<->
## DairyFrozen, and DryGoods<->Bakery keep the same Gate-seals-the-whole-
## boundary approach the old line already used (see Gate.gd), just
## repositioned — a gate's own collision still spans the FULL playable
## length of whichever edge it sits on, vertical for a column boundary,
## unchanged in kind from before, just no longer always-vertical, now that
## the grid has horizontal boundaries too. (In this grid every actual gate
## still happens to be vertical since row0/row1's three gated boundaries -
## hub/MeatDeli, hub/DairyFrozen, DryGoods/Bakery - are all COLUMN
## boundaries; nothing structurally requires that going forward.)
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
## Break room center — grid (0,0) (see the GRID MAP comment above), so this
## is BREAK_ROOM_GRID_POS * (ROOM_WIDTH, ROOM_HEIGHT) + (half a cell) =
## (0,0)+(480,270) = (480,270) — unchanged from the old line layout's value
## by coincidence (the break room happened to sit at the very start of both
## the old row and this grid's cell (0,0)). Players spawn here, not in Dry
## Goods: you clock in at the break room and walk out through Dry Goods
## (its only connection) to reach the hub and start your shift.
const SPAWN_CENTER := Vector2(480.0, 270.0) # players spread out around this point, not a specific object

const ROOM_WIDTH := 960.0
const ROOM_HEIGHT := 540.0
## 3x3 hub-and-spoke grid — see the GRID MAP comment above this file's
## header for which cell holds what and why this shape (versus the old
## single-row NUM_ROOMS line) is the actual fix for the recurring customer-
## timeout pattern.
const GRID_COLS := 3
const GRID_ROWS := 3
const WORLD_WIDTH := ROOM_WIDTH * GRID_COLS
const WORLD_HEIGHT := ROOM_HEIGHT * GRID_ROWS
## The four non-retail grid cells — see the GRID MAP comment above this
## file's header. None appear in SECTIONS (no gate, no shelves), but all
## four are things other code needs to reason about explicitly:
## SIDEWALK_GRID_POS is where customers spawn (_store_entrance_pos());
## ENTRANCE_GRID_POS is where the central checkout hub lives (CentralCheckout
## in Main.tscn); BREAK_ROOM_GRID_POS is used by is_break_room_at_pos()
## below to keep customer AI (and stray physics objects — see
## _rescue_stranded_products()) out of it; STORAGE_GRID_POS is the new
## delivery/storage room (see its own comment on Main.tscn's Storage node)
## — deliberately NOT in SECTIONS and NOT passed to _configure_gates(), so
## it's reachable from Day 1 with no gate at all, same as Sidewalk/
## Checkout/Break Room, rather than joining Dry Goods on a "Day 1" GATE that
## would still visually/mechanically treat it as a gated section.
const BREAK_ROOM_GRID_POS := Vector2i(0, 0)
const SIDEWALK_GRID_POS := Vector2i(1, 2)
const ENTRANCE_GRID_POS := Vector2i(1, 1)
const STORAGE_GRID_POS := Vector2i(2, 2)
## grid_pos matches each section's cell in the GRID MAP comment above this
## file's header. required_day mirrors the brief's Day 1-2 / 3-4 / 5-6 / 7
## schedule exactly, and is also what _configure_gates() below sets on each
## matching Gate instance by node name (not a .tscn property override — see
## that function's own comment on why), so this table and the actual
## physical doors can't quietly drift apart from each other.
const SECTIONS := [
	{"name": "Dry Goods", "node_name": "DryGoods", "grid_pos": Vector2i(1, 0), "required_day": 1},
	{"name": "Meat/Deli", "node_name": "MeatDeli", "grid_pos": Vector2i(2, 1), "required_day": 3},
	{"name": "Dairy/Frozen", "node_name": "DairyFrozen", "grid_pos": Vector2i(0, 1), "required_day": 5},
	{"name": "Bakery", "node_name": "Bakery", "grid_pos": Vector2i(2, 0), "required_day": 7},
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
## True while the full-screen end-of-day report (ReportLayer, see
## _end_shift()/_advance_to_next_day()) is up, replicated via _day_sync so
## every peer shows/hides it at the same moment. UPGRADED from the old
## "day_transition_message" debug-label text: that string only ever showed
## up buried inside DebugLabel's wall of per-frame peer/shelf/carry state,
## which is very likely WHY the "no end-of-day report" playtest bug was
## filed even though a message was technically already being set — nothing
## about it looked like a report. Replaced with a real full-screen
## CanvasLayer (ReportLayer in Main.tscn) showing Sold Today/Week Total and
## a Continue button. See _process() for the show/hide + label-text logic,
## and _on_continue_pressed() for what ends this stage — no more automatic
## timed transition; the player decides when to move on.
var _day_report_active := false

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
##   confirmed design decision. The customer cap (_customer_baseline() below)
##   no longer scales the same multiplicative way as of this session's
##   cashier-consolidation request — it now reads explicit FLAGGED per-tier
##   numbers off CUSTOMER_CAP_BY_TIER instead (see that constant's own
##   comment for the actual numbers and reasoning), since "increase the
##   customer cap per day" was an explicit ask this round, not an inferred
##   judgment call the way it was in Week 6. Day 1-2 behavior is close to
##   the old numbers either way (1 section unlocked = tier 0). The Week 5B
##   solo playtest (15 sold in 120s) was tuned against the original
##   single-section store, so ANY of this wants re-validating at later days,
##   not assumed to still be right.
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
## FLAGGED SCALING NUMBERS — explicitly asked to be surfaced rather than
## picked silently, per this session's cashier-consolidation request.
## Indexed by (unlocked-section-count - 1), same tier boundary the store
## already uses for everything else section-count-driven (products, the
## old per-section customer baseline, SECTION_TIME_BONUS) — Day 1-2 = 1
## section, Day 3-4 = 2, Day 5-6 = 3, Day 7+ = 4. Both arrays are a
## judgment call, not a tuned value:
## - CUSTOMER_CAP_BY_TIER: replaces the old flat "CUSTOMER_BASELINE * unlocked
##   sections" formula (3/6/9/12) with explicit per-tier numbers, bumped up
##   as requested ("increase the customer cap per day") — same rough shape
##   (roughly +4 per tier) but a higher floor, since a store with a real
##   central checkout can clear a line faster than 4 scattered single-lane
##   cashiers ever could, so a flat customer-per-section ratio tuned against
##   the OLD layout likely reads as too sparse now.
## - CASHIER_COUNT_BY_TIER: how many of the central checkout's stations
##   (CentralCheckout in Main.tscn, up to CASHIER_COUNT_BY_TIER.max() = 5
##   physically placed) are active at each tier — scales throughput
##   alongside the customer cap so a bigger crowd doesn't just pile up at
##   the same number of registers. Started at 2 (not 1) even for Day 1-2,
##   since a single-lane central checkout serving what used to be 4
##   separate sections' worth of foot traffic would be an obvious
##   bottleneck from the very first day.
## Re-tune both freely once played — these are a starting point, not a
## final balance pass.
const CUSTOMER_CAP_BY_TIER := [5, 9, 13, 17]
const CASHIER_COUNT_BY_TIER := [2, 3, 4, 5]
## FLAGGED SCALING NUMBERS, same tier shape as the two arrays above —
## playtest request: keep single-item trips for the early days (Day 1-2,
## tier 0, unchanged at 1 item — this is the existing, already-confirmed
## baseline, not a new behavior), then scale UP how many items a shopper
## buys per visit on later days as more sections come online. A shopper
## doesn't carry multiple items AT ONCE (Carryable.gd's CARRY_OFFSET is a
## single fixed attach point — simultaneous multi-item carry would need
## real rework there); instead it's SEQUENTIAL, buying items one at a time
## and returning to the item-search loop it already runs after every
## purchase (Customer.gd's _shopper_input() already resets _committed_item
## to null once the carried item is gone — that loop already existed, it
## just used to run until MAX_LIFETIME_SHOPPER cut it off, closer to "as
## many as happen to fit" than a deliberate count) until it's completed
## items_target purchases, then leaves satisfied (see Customer.gd's
## record_purchase()/_shopper_input()).
##
## Kept deliberately modest, not matching the CUSTOMER_CAP_BY_TIER ramp:
## every additional item is another full round-trip to the now-centralized
## checkout (see Customer.gd's LIFETIME_DISTANCE_MULTIPLIER for how a
## shopper's timeout budget scales with that walk for a far section), so a
## high target on a late, already-longer
## SECTION_TIME_BONUS-extended shift risks shoppers rarely finishing their
## whole trip before the clock runs out. Starts scaling at Day 3 (tier 1 —
## the same threshold every other tiered system here already uses, not a
## new one invented for this), not Day 1, matching "keep single-item trips
## for the early days" literally.
const ITEMS_TARGET_BY_TIER := [1, 2, 2, 3]
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
## (see its own comment) — and, as of this session's root-cause fix,
## _start_shift() also force-despawns any customer still on the floor from
## the previous day BEFORE this timer starts counting down
## (_despawn_all_customers()), so the grace period actually means "zero
## customers" every day now, not just "no NEW customers" while old ones
## linger. Products are NOT held back the same way — _restock_products()
## still runs immediately, since there'd be nothing to stock during the
## grace period otherwise. Placeholder, not tuned.
const CUSTOMER_GRACE_PERIOD := 9.0
## Playtest request: each ADDITIONAL section that's unlocked (beyond the
## first, Dry Goods) buys the player 10 more seconds of both the pre-shift
## grace period and the shift clock itself, cumulative — a bigger store
## means more ground to cover, so both numbers should grow together, not
## just the shift length. Read via _current_customer_grace_period()/
## _current_shift_duration() below, evaluated fresh in _start_shift() every
## day (using _unlocked_sections(), which is already current_day-driven), so
## Day 1-2 (1 section) is unaffected and later days automatically pick up
## whatever's unlocked that day.
const SECTION_TIME_BONUS := 10.0

## See SECTION_TIME_BONUS above.
func _current_customer_grace_period() -> float:
	return CUSTOMER_GRACE_PERIOD + SECTION_TIME_BONUS * max(0, _unlocked_sections().size() - 1)

## See SECTION_TIME_BONUS above. shift_duration is still the Day-1/single-
## section BASE (and still overridable via --shift-seconds=) — this is what
## actually gets loaded into shift_time_left at the start of every shift.
func _current_shift_duration() -> float:
	return shift_duration + SECTION_TIME_BONUS * max(0, _unlocked_sections().size() - 1)

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
@onready var report_layer: CanvasLayer = $ReportLayer
@onready var report_title_label: Label = $ReportLayer/Panel/TitleLabel
@onready var report_today_label: Label = $ReportLayer/Panel/TodayLabel
@onready var report_week_label: Label = $ReportLayer/Panel/WeekLabel
@onready var save_button: Button = $ReportLayer/Panel/ButtonRow/SaveButton
@onready var continue_button: Button = $ReportLayer/Panel/ButtonRow/ContinueButton

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
	# _day_report_active/_sold_at_day_start: they used to tick down
	# independently on every peer, which was harmless only because
	# shift_active never actually changed value before Week 7's day-end/
	# transition/next-shift cycle existed — an un-replicated client-local
	# copy would otherwise just stay true forever, never showing the
	# transition message a client should see.
	var day_sync := MultiplayerSynchronizer.new()
	var day_config := SceneReplicationConfig.new()
	for prop in [".:current_day", ".:_day_report_active", ".:_sold_at_day_start", ".:shift_active", ".:shift_time_left"]:
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
	continue_button.pressed.connect(_on_continue_pressed)
	save_button.pressed.connect(_on_save_pressed)

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
## shelf to a section by WORLD grid cell (same grid math is_unlocked_at_pos
## uses below), not by node path or name, so it doesn't care what a given
## section's shelves happen to be called.
func _apply_section_accent_colors() -> void:
	for shelf_body in shelves:
		var cell := _grid_cell_of(shelf_body.global_position)
		for section in SECTIONS:
			if section["grid_pos"] == cell:
				var shelf: Node = shelf_body.get_node("Shelf")
				shelf.accent_color = SECTION_COLORS[section["name"]]
				shelf.apply_accent_color()
				break

## Which (col, row) grid cell a world position falls in — the single place
## every other grid-position lookup in this file (is_unlocked_at_pos(),
## is_break_room_at_pos(), _apply_section_accent_colors(),
## _apply_section_lock_visuals()) bottoms out at, so the col/row math itself
## only ever needs to be right in one place.
func _grid_cell_of(world_pos: Vector2) -> Vector2i:
	return Vector2i(int(floor(world_pos.x / ROOM_WIDTH)), int(floor(world_pos.y / ROOM_HEIGHT)))

## Playtest feedback: a locked section previously looked completely
## normal except for the Gate's own thin barrier line at its entrance —
## easy to miss, and gave no sense at a glance that the whole section was
## inactive. Darkens every locked section's shelves, floor tint, and label
## together (cashiers are no longer per-section — see this function's own
## note below). Unlocked sections (including Dry Goods, which is
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
		var cell: Vector2i = section["grid_pos"]
		for shelf_body in shelves:
			if _grid_cell_of(shelf_body.global_position) == cell:
				var base: Color = _original_shelf_modulate[shelf_body]
				shelf_body.modulate = base if unlocked else base * LOCKED_DIM
		# Cashiers are no longer per-section (see CentralCheckout in
		# Main.tscn), so there's nothing to dim/undim here any more — a
		# locked section's own shelves/products are still unreachable via
		# the section-lock check everywhere else, and the central
		# checkout's own active/inactive station count is driven
		# separately by _configure_cashiers().
		var bg := get_node_or_null("RoomBackgrounds/%sBg" % section["node_name"])
		if bg:
			var base_bg: Color = _original_bg_color[section["node_name"]]
			bg.color = base_bg if unlocked else base_bg * LOCKED_DIM
		var label := get_node_or_null("SectionLabels/%s/Label" % section["node_name"])
		if label:
			label.modulate = Color(1, 1, 1, 1) if unlocked else LOCKED_DIM

## Snapshots every shelf/background's color BEFORE any locking dims it, so
## _apply_section_lock_visuals() above always has an undimmed original to
## compute from no matter how many times (or in what order) it later runs.
## Called once from _ready(); order relative to
## _apply_section_accent_colors() doesn't matter, since that touches a
## different property (Shelf.gd's own accent_color/indicator, not the
## ShelfBody root's modulate this reads). No longer caches a cashier
## dictionary — cashiers moved to one shared CentralCheckout, no longer
## dimmed per-section (see _apply_section_lock_visuals()'s own comment).
var _original_shelf_modulate := {} # shelf_body (Node) -> Color
var _original_bg_color := {} # section node_name (String) -> Color

func _cache_original_colors() -> void:
	for shelf_body in shelves:
		_original_shelf_modulate[shelf_body] = shelf_body.modulate
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
## Also the entry point for every day AFTER the first — _advance_to_next_day()
## below calls this exact same function once a player clicks Continue on the
## end-of-day report, rather than a separate "day 2+" code path. Nothing here
## resets or despawns existing PRODUCTS or shelf state between days (only
## _restock_products() topping up to the — likely now-larger, since more
## sections may have just unlocked — cap changes anything); it DOES reset
## player position (_reset_players_to_break_room, playtest bug fix) and, as
## of this session's root-cause fix, force-clears the ENTIRE customer
## population (_despawn_all_customers(), below) before the grace period
## starts counting down — see that function's own comment for why a
## leftover customer surviving the day boundary was the real bug behind
## both "grace period only works on Day 1" and "customers don't spawn from
## the entrance".
func _start_shift() -> void:
	if not multiplayer.is_server() or shift_active:
		return
	shift_active = true
	_sold_at_day_start = _total_sold()
	# PLAYTEST ROOT-CAUSE FIX: a customer left over from the previous day's
	# shift used to just keep existing into the new one (nothing ever
	# force-cleared the population, only paused new spawning) — see
	# _despawn_all_customers()'s own comment for why that alone was enough
	# to make BOTH the grace period and the entrance-spawn fix look broken
	# on Day 2+ even though each was individually working correctly for any
	# customer actually newly spawned.
	_despawn_all_customers()
	_reset_shelves_and_products_for_new_day()
	var grace := _current_customer_grace_period()
	var duration := _current_shift_duration()
	_customer_grace_timer = grace
	_restock_timer = 0.0
	_reset_players_to_break_room()
	print("[Main] Day %d shift starting — %d player(s), %.0fs on the clock, %.0fs customer grace period, no fixed stock target" % [current_day, players.size(), duration, grace])
	_restock_products()
	shift_time_left = duration

## PLAYTEST ROOT-CAUSE FIX (see _start_shift()'s call site): forces every
## currently-existing customer to leave immediately, the same cleanup
## Customer.gd's own lifetime-timeout _leave() already does (drop whatever
## they're carrying, then queue_free), just triggered by "a new day is
## starting" instead of "this one customer's clock ran out". Without this,
## a customer that happened to still be on the floor from the tail end of
## the previous day's shift was indistinguishable, on sight, from a customer
## that "ignored" the grace period or "ignored" the entrance-spawn point —
## it was neither; it just never left. Host-only (same guard as the rest of
## _start_shift()) — freeing a MultiplayerSpawner-spawned node on its
## authority side is what propagates the despawn to every other peer, same
## reasoning as Main.gd's existing disconnect-safety sweep.
func _despawn_all_customers() -> void:
	for customer in get_tree().get_nodes_in_group("customer"):
		customer.force_leave()

## Public read of _day_report_active — Customer.gd/Player.gd/Cashier.gd/
## Shelf.gd all call this (via get_tree().current_scene, same "live scene-
## tree lookup, no cyclic preload" shape those scripts already use for
## is_unlocked_at_pos()/is_break_room_at_pos()) to freeze themselves for the
## duration of the end-of-day report — PLAYTEST BUG FIX: the report used to
## leave the whole simulation running underneath it, which is how a
## customer left an item stranded at checkout when a day ended under it.
func is_day_report_active() -> bool:
	return _day_report_active

## PLAYTEST ROOT-CAUSE FIX ("Day 2 starts fully stocked, nothing to do"):
## nothing previously reset shelf-fill state or the physical product pool
## between days — whatever got stocked by the end of Day 1 just carried
## straight into Day 2 untouched, and since the product cap
## (_product_baseline()) doesn't grow until MORE sections unlock (Day 3+),
## Day 2 specifically had no new demand to create either, on top of that.
## Mirrors _despawn_all_customers()'s shape: force-clear the relevant state
## at the start of EVERY shift (not just conceptually "Day 1"), so each day
## starts from a genuine restocking need instead of inheriting wherever the
## previous day happened to leave off. Shelves are reset FIRST, clearing
## their own _occupant/filled bookkeeping, before the products themselves
## are freed — Shelf.gd's own per-tick check would otherwise try to inspect
## an already-freed object on the very next physics tick.
func _reset_shelves_and_products_for_new_day() -> void:
	for shelf_body in shelves:
		shelf_body.get_node("Shelf").reset()
	for obj in get_tree().get_nodes_in_group("carryable"):
		obj.queue_free()

## Host-only: called the instant the clock hits zero (see _process()'s
## shift-timer check). Raises the full-screen end-of-day report (ReportLayer,
## via replicated _day_report_active — see its own comment) instead of the
## old auto-advancing debug-label message. UPGRADED per this session's
## request: no timed auto-continue any more — the report stays up
## indefinitely until a player clicks Continue (_on_continue_pressed() /
## _advance_to_next_day() below). Gameplay keeps running underneath (players
## can still walk around, a shopper mid-purchase can still complete it —
## Cashier.gd/Shelf.gd don't check shift_active at all); only the economy
## restock is paused, via the same shift_active guard _process() already
## checks before calling _restock_*().
func _end_shift() -> void:
	if not multiplayer.is_server() or not shift_active:
		return
	shift_active = false
	_day_report_active = true
	print("[Main] Day %d complete!  Sold today: %d  |  Week total: %d" % [current_day, _total_sold() - _sold_at_day_start, _total_sold()])

## Any peer's Continue click routes here. Only the host actually drives the
## day advance (current_day/gates/shift are all host-authoritative), so a
## non-host click asks the host over RPC instead of touching anything
## locally — same "any peer may ask, only the authority acts" shape as
## Carryable.gd's request_push / Customer.gd's request_shove.
func _on_continue_pressed() -> void:
	if multiplayer.is_server():
		_advance_to_next_day()
	else:
		rpc_id(1, "_request_advance_day")

@rpc("any_peer", "reliable")
func _request_advance_day() -> void:
	if not multiplayer.is_server():
		return
	_advance_to_next_day()

## VISIBLE PLACEHOLDER ONLY, per this session's request — real save/load is
## a separate, bigger system for a future session. Exists so the button is
## there to design around (layout, a future confirmation toast, etc.)
## without pretending it persists anything yet.
func _on_save_pressed() -> void:
	print("[Main] Save pressed — placeholder only, no save/load system yet.")

## Host-only: ends the end-of-day report and starts the next day. Guarded on
## _day_report_active (not just multiplayer.is_server()) so a duplicate
## Continue click/RPC — e.g. two players clicking in the same frame — can't
## advance current_day twice; the first call flips _day_report_active false
## before a second could ever get here. Reconfigures gates/cashiers/lock
## visuals EXPLICITLY and IMMEDIATELY here (PLAYTEST BUG FIX carried over
## from the previous round of fixes), rather than relying only on
## _process()'s day-change poll to catch it on the next frame — that poll
## still exists too (it's what catches a late-joining/reconnecting client),
## this just makes the connection unmissable at the one moment "a new day
## started" unambiguously means something.
func _advance_to_next_day() -> void:
	if not multiplayer.is_server() or not _day_report_active:
		return
	_day_report_active = false
	current_day += 1
	_configure_gates()
	_configure_cashiers()
	_apply_section_lock_visuals()
	_last_configured_day = current_day
	print("[Main] Starting Day %d..." % current_day)
	_start_shift()

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
## those all still count as "not yet sold" supply. PLAYTEST ROOT-CAUSE FIX:
## EXCEPT anything currently sitting in the break room — before this,
## a stranded item there (see is_break_room_at_pos()'s comment for how it
## gets there) silently counted as "still in play" forever, quietly eating
## into the cap and suppressing real, reachable spawns without ever showing
## up anywhere a player would think to look. _rescue_stranded_products()
## below is the other half of this fix — it actively returns a stranded
## item to play rather than just no longer miscounting it.
func _restock_products() -> void:
	var cap: int = _product_baseline() + PRODUCT_PER_EXTRA_PLAYER * max(0, players.size() - 1)
	var current := 0
	for obj in get_tree().get_nodes_in_group("carryable"):
		if not is_break_room_at_pos(obj.global_position):
			current += 1
	while current < cap:
		_spawn_product(_product_spawn_index)
		_product_spawn_index += 1
		current += 1

## PLAYTEST ROOT-CAUSE FIX, companion to _restock_products()'s cap-count
## exclusion above: actively returns any FREE (uncarried) product currently
## sitting in the break room back into play, rather than leaving it there
## forever. A product ends up there one of two ways — a shopper's
## _leave()/force_leave() dropping it mid-transit (now rare, see
## Customer.gd's dynamic lifetime budget, but not literally impossible), or ordinary
## physics chaos (a push, a throw, a disruptive shove) knocking a free item
## across the ungated break-room boundary — and per this session's explicit
## request, the fix for that spillage is NOT a wall (Week 6 already removed
## doors after they caused NPCs to jam single-file; a break-room door risks
## the same regression), so prevention can't be 100%. This is the mitigation:
## sweep it back onto the floor instead of leaving it dead. Only touches FREE
## items (carrier_id == 0) — one mid-transit through the break room while
## actually being carried is legitimate and left alone. Same cadence as
## _restock_products() (called right alongside it in _process()), host-only.
func _rescue_stranded_products() -> void:
	for obj in get_tree().get_nodes_in_group("carryable"):
		if not is_break_room_at_pos(obj.global_position):
			continue
		var c: Node = obj.get_node("Carryable")
		if c.carrier_id != 0:
			continue
		obj.global_position = _spawn_pos_in_section(_pick_unlocked_section())
		obj.linear_velocity = Vector2.ZERO

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

## True if the given WORLD position falls inside a section that's currently
## unlocked. Used to keep the debug HUD and the restock-baseline scaling
## honest about which shelves are actually reachable this session — a
## shelf behind a locked gate physically exists (so the day advancing past
## it mid-session doesn't need new scene content) but isn't "in play" for
## either purpose until its gate opens.
##
## UPGRADED from an x-only is_unlocked_at_x() to a full Vector2 check when
## the store became a 2D grid instead of a 1D line — an x-only lookup can
## no longer tell two cells in the same column but different rows apart
## (e.g. Meat/Deli at (2,1) vs. Storage at (2,2)).
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
func is_unlocked_at_pos(world_pos: Vector2) -> bool:
	var cell := _grid_cell_of(world_pos)
	for section in SECTIONS:
		if section["grid_pos"] == cell:
			return current_day >= section["required_day"]
	return false # entrance/break room/sidewalk/storage have no shelves, so never matters here

## PLAYTEST ROOT-CAUSE FIX: the central checkout used to live IN the break
## room, and nothing stopped customer AI from wandering into it either —
## harmless-looking, but actually caused two real bugs (see the long
## comment on _spawn_customer's caller and _rescue_stranded_products()
## below): a shopper timing out mid-walk could drop its item there (no
## shelf ever looks for it again), and idle browse/disruptive wandering
## could land a customer there for no reason at all. The checkout is now in
## the hub cell instead (ENTRANCE_GRID_POS), and — carried forward into this
## session's hub-and-spoke reshape — the break room branches off Dry Goods
## rather than sitting on the hub or the Sidewalk (the two cells actually in
## a customer's path), so a customer never has anywhere to be that
## structurally requires passing through it at all (see the GRID MAP
## comment above this file's header for the full story). This function
## is the remaining safety net for the one thing room ordering alone can't
## rule out: the random-offset fallback in Customer.gd's own wander/
## disruptive targeting could still roll a candidate point that happens to
## land in the break room by pure chance if a customer is standing right at
## its boundary. Customer.gd calls this (same "public, live scene-tree
## lookup, no cyclic preload" shape as is_unlocked_at_pos() above) to nudge
## such a candidate back out instead. UPGRADED to a full Vector2 check
## alongside is_unlocked_at_pos() above, same reasoning — the break room's
## grid cell (0,0) shares a column with Dairy/Frozen's (0,1) and a row with
## Dry Goods' (1,0), so x-only or y-only would each misfire against one of
## those.
func is_break_room_at_pos(world_pos: Vector2) -> bool:
	return _grid_cell_of(world_pos) == BREAK_ROOM_GRID_POS

## PLAYTEST BUG FIX ("customers can enter Storage"): same exclusion-zone
## approach as is_break_room_at_pos() above, applied to Storage
## (STORAGE_GRID_POS) — Storage is a real, physically open, ungated cell
## (see STORAGE_GRID_POS's own comment: reachable from Day 1, deliberately
## not day-gated), so nothing about the map itself stops a customer from
## walking there. It needs to stay player-only for now because there's no
## forklift/delivery system yet for a customer to plausibly interact with
## anything inside it — not a physical door (matching Break Room's own
## "exclusion zone, not a wall" precedent), just customer AI never being
## given a target there. Customer.gd calls this the same way it calls
## is_break_room_at_pos() — see that function's own comment for the "public,
## live scene-tree lookup, no cyclic preload" shape both share.
func is_storage_at_pos(world_pos: Vector2) -> bool:
	return _grid_cell_of(world_pos) == STORAGE_GRID_POS

## 12 = one section's slot count (4 shelves x 3 slots) — see the big
## comment block above PRODUCT_PER_EXTRA_PLAYER for why this scales with
## unlocked-section-count instead of staying flat, and why that's flagged
## as a judgment call rather than a confirmed decision.
func _product_baseline() -> int:
	return 12 * _unlocked_sections().size()

## See CUSTOMER_CAP_BY_TIER's own comment for what these numbers are and why.
func _customer_baseline() -> int:
	var tier := clampi(_unlocked_sections().size() - 1, 0, CUSTOMER_CAP_BY_TIER.size() - 1)
	return CUSTOMER_CAP_BY_TIER[tier]

## See ITEMS_TARGET_BY_TIER's own comment. Evaluated fresh per customer at
## spawn time (_spawn_customer() below), not re-evaluated later — a shopper
## keeps whatever target it was given even if the tier changes mid-shift
## (which can't actually happen today anyway, since _despawn_all_customers()
## already clears every customer at the one moment the tier could change,
## a day boundary — but resolving it once at spawn is the honest, no-surprise
## behavior regardless).
func _items_target_for_current_tier() -> int:
	var tier := clampi(_unlocked_sections().size() - 1, 0, ITEMS_TARGET_BY_TIER.size() - 1)
	return ITEMS_TARGET_BY_TIER[tier]

## See CASHIER_COUNT_BY_TIER's own comment. Called from _configure_cashiers()
## below, which is what actually enables/disables that many of the central
## checkout's stations.
func _active_cashier_count() -> int:
	var tier := clampi(_unlocked_sections().size() - 1, 0, CASHIER_COUNT_BY_TIER.size() - 1)
	return CASHIER_COUNT_BY_TIER[tier]

## Enables the first N of the central checkout's Cashier stations (N =
## _active_cashier_count()) and disables the rest — called alongside
## _configure_gates() both from _process()'s day-change poll and explicitly
## from _advance_to_next_day(), same "every peer reacts uniformly, and the
## host also does it immediately at the moment a new day starts" shape
## those two already use. `cashiers` is populated once in _ready() from the
## "cashier" group, which (for CentralCheckout's Cashier1..Cashier5, static
## scene nodes, not dynamically spawned) reflects their declaration order in
## Main.tscn — stations activate in that same fixed order every time, not a
## different subset day to day.
func _configure_cashiers() -> void:
	var count := _active_cashier_count()
	for i in cashiers.size():
		var cashier: Node = cashiers[i].get_node("Cashier")
		cashier.set_active(i < count)

## Picks a random CURRENTLY UNLOCKED section (never the break room: nothing
## to stock or shop for there, and a locked section has no way out anyway).
func _pick_unlocked_section() -> Dictionary:
	var unlocked := _unlocked_sections()
	return unlocked[randi() % unlocked.size()] # always has at least Dry Goods (required_day=1)

## A spawn point inside the given section's safe interior band — same
## shape/margins the original single-room band always used (clear of
## shelves at local y ~42-108/432-498 and the walls), just relocated per
## section by its grid cell (col AND row now, not just a room_index along
## one axis). Spawning a RigidBody2D (a
## product) overlapping a StaticBody2D's collider can make the physics
## engine's penetration-resolution fling it at an absurd speed to separate
## them, the same class of bug Week 1-3 hit with fast-moving objects
## tunneling through thin walls — keeping spawns in open floor avoids ever
## creating that overlap in the first place.
func _spawn_pos_in_section(section: Dictionary) -> Vector2:
	var cell: Vector2i = section["grid_pos"]
	var room_x: float = cell.x * ROOM_WIDTH
	var room_y: float = cell.y * ROOM_HEIGHT
	return Vector2(randf_range(room_x + 180.0, room_x + 780.0), randf_range(room_y + 120.0, room_y + 360.0))

## UPGRADED TWICE this session, replacing the old per-section
## _customer_entrance_pos(): playtest request for a real store entrance —
## a genuinely separate outdoor Sidewalk zone (SIDEWALK_GRID_POS, its own
## room, distinct from the Checkout hub the central registers live in —
## see the GRID MAP comment above this file's header for why they
## used to be one dual-purpose room and aren't any more), that every
## customer spawns at and physically walks in from, rather than popping
## into existence at whichever section they're headed to. All customers
## spawn HERE regardless of role or eventual target, then use their
## existing target-picking AI (Customer.gd's _find_stocked_item/
## _pick_browse_target/_pick_disruptive_target/_find_nearest_cashier — none
## of that changed, this only moves WHERE they start) to walk toward
## wherever they're actually headed — Sidewalk, then Checkout (where the
## central registers sit — see CentralCheckout in Main.tscn — two
## staggered rows with wide spacing so no station's queue markers reach
## into a neighbor's collision box), then whichever section, the same
## "just point them at a target position and let the existing straight-
## line steering handle it" approach already used for every other long
## walk in this project. Small random jitter so several customers spawning
## together don't stack exactly on top of each other.
## PLAYTEST FIX ("Sidewalk is oversized"): the strip is no longer sized/
## positioned off the Sidewalk cell's full ROOM_WIDTH x ROOM_HEIGHT slot
## (that grid cell still reserves the full slot for it, but nothing
## requires the actual walkable zone to fill that whole slot — Sidewalk
## isn't a SECTIONS entry and has no shelves, so nothing else's gating logic
## cares how much of the slot it visually occupies). SIDEWALK_STRIP_CENTER/
## HALF_SIZE below now describe a small rectangle sitting right against the
## Checkout hub's edge instead — both because a small outdoor entry strip
## reads better than a full room-sized square (playtest feedback), and
## because spawning customers this close to the hub meaningfully shortens
## the walk every customer has to survive before the dynamic lifetime
## budget (_extend_lifetime_budget() in Customer.gd) even starts covering
## it. REPOSITIONED this session for the hub-and-spoke grid: Sidewalk is
## now the cell directly SOUTH of the hub (SIDEWALK_GRID_POS = (1,2), hub =
## (1,1)), so the strip hugs the shared horizontal boundary at
## y=ENTRANCE_GRID_POS.y*ROOM_HEIGHT+ROOM_HEIGHT (top of the Sidewalk cell)
## instead of a vertical one. Must stay in sync BY HAND with Main.tscn's
## SidewalkBg position/polygon (no inline .tscn comment to cross-reference
## them with — see this file's header note on why).
const SIDEWALK_STRIP_CENTER := Vector2(1440.0, 1230.0)
const SIDEWALK_STRIP_HALF_SIZE := Vector2(120.0, 150.0)

func _store_entrance_pos() -> Vector2:
	var margin := 20.0
	return SIDEWALK_STRIP_CENTER + Vector2(
		randf_range(-SIDEWALK_STRIP_HALF_SIZE.x + margin, SIDEWALK_STRIP_HALF_SIZE.x - margin),
		randf_range(-SIDEWALK_STRIP_HALF_SIZE.y + margin, SIDEWALK_STRIP_HALF_SIZE.y - margin)
	)

## Products are colored to match the section they spawn in (SECTION_COLORS
## above), the same accent color as that section's shelf slot indicators —
## the color-coordination playtest request. UPGRADED this session:
## Shelf.gd's own settling check (_color_matches()) now ENFORCES this — a
## product only counts as placed if its color approx-matches the shelf's
## accent_color — so a Dry Goods product spawned here genuinely can't be
## placed on a Meat/Deli shelf any more, not just "usually doesn't end up
## there" by proximity. Shelf.gd still doesn't know anything about
## "sections" as a concept, just colors, matching how this project's
## components generally stay ignorant of concerns outside their own job.
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

## Spawns at the shared store ENTRANCE (see _store_entrance_pos), not a
## random interior position — customers are CharacterBody2Ds, not
## RigidBody2Ds, so they wouldn't get flung by a collision-shape overlap
## the way a product could, but starting clear of the shelves/walls still
## avoids an instant, confusing shove on spawn.
func _spawn_customer(role: String) -> void:
	var pos := _store_entrance_pos()
	var carry_id := _next_customer_carry_id
	_next_customer_carry_id -= 1
	customer_spawner.spawn({
		"index": _customer_spawn_index,
		"pos": pos,
		"role": role,
		"carry_id": carry_id,
		"items_target": _items_target_for_current_tier(),
	})
	_customer_spawn_index += 1

func _spawn_customer_node(data: Dictionary) -> Node:
	var c := CustomerScene.instantiate()
	c.name = "Customer%d" % data["index"]
	c.position = data["pos"]
	c.role = data["role"]
	c.carry_id = data["carry_id"]
	c.items_target = data["items_target"]
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
		_configure_cashiers()
		_apply_section_lock_visuals()
		print("[Main] Day is now %d" % current_day)

	# End-of-day report (see _end_shift()/_advance_to_next_day()) — a real
	# full-screen CanvasLayer now, replacing the old debug-label-only
	# message that was easy to miss buried in DebugLabel's wall of text.
	# Driven off the replicated _day_report_active flag so every peer shows/
	# hides it at the same moment; the sold numbers are recomputed from
	# already-replicated state (_total_sold()/_sold_at_day_start), not a
	# separate replicated pair, so there's nothing new to keep in sync here.
	report_layer.visible = _day_report_active
	if _day_report_active:
		var week_sold := _total_sold()
		var today_sold := week_sold - _sold_at_day_start
		report_title_label.text = "Day %d Complete!" % current_day
		report_today_label.text = "Sold Today: %d" % today_sold
		report_week_label.text = "Week Total: %d" % week_sold

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
			_rescue_stranded_products()
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
	var unlocked_shelves := shelves.filter(func(s): return is_unlocked_at_pos(s.global_position))
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
	# the flagged score-continuity comment above _sold_at_day_start. The
	# end-of-day report itself is now the full-screen ReportLayer above, not
	# a line in this debug HUD.
	if shift_active:
		var week_sold := _total_sold()
		var today_sold := week_sold - _sold_at_day_start
		lines.append("Stocked now: %d/%d  |  Today: %d  |  Week total: %d  |  %.0fs left" % [total_filled, total_slots, today_sold, week_sold, shift_time_left])
	debug_label.text = "\n".join(lines)
