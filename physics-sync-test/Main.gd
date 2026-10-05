extends Node2D
## Wires everything together:
## - a Host/Join menu (Join connects to the typed Host IP; blank = 127.0.0.1)
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
##   (0,1) Dairy/Frozen (1,1) CHECKOUT HUB         (2,1) Produce (Day 3; was Meat/Deli)
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
##
## WEEK 8 — THE FORKLIFT HAZARD (Forklift.gd, Main.tscn's Forklift node),
## plus knock-over-able floor displays (Display.gd, Main.tscn's Displays).
## The forklift patrols Meat/Deli's central aisle — the east spoke off the
## hub, the first section that opens after Dry Goods, so it's the first
## thing a Day 3 crew walks into — and periodically rams a shelf, which
## wrecks it (Shelf.gd's wreck(): stock flung as real RigidBody2D impulses,
## shelf refuses stock for a few seconds). Host-authoritative, replicated
## the same way customers are. (Storage deliveries, which the GRID MAP
## comment below anticipates a forklift for, are still future work — this
## one is the brief's Day 3 aisle hazard.) Edge cases found while reading
## the existing code first, each handled where it lives rather than
## special-cased here:
## - DAY GATING is tied to Meat/Deli's own SECTIONS required_day (via
##   is_unlocked_at_pos(forklift.home_position) in _configure_hazards()),
##   not a second hardcoded "3", so the two can't drift apart. Inactive =
##   hidden AND collision disabled, not just parked.
## - Displays are NOT Carryables: anything in the "carryable" group counts
##   against the product cap, is deleted every morning by
##   _reset_shelves_and_products_for_new_day(), and gets picked up/bought.
##   Display.gd reuses only the sync + request_push() half (see its header).
## - Knocked-off stock used to still be the committed target of whichever
##   shopper was walking to it, and got bought off the floor — see
##   Customer.gd's _is_still_stocked(). Without that fix a wreck cost
##   nothing.
## - Forklift contact with a PLAYER can't move the player from the host
##   (movement is client-authoritative) — it RPCs the owner, see Player.gd's
##   forklift_hit().
## - Products respawning in Meat/Deli's spawn band could land on top of the
##   forklift or a display (the band spans the forklift's lane), and a
##   RigidBody2D spawned overlapping another body gets flung by
##   depenetration — _spawn_pos_in_section() now retries for clearance.
## - A hard knock can in principle push a product through a wall/off the
##   map, where it would silently count against the cap forever —
##   _rescue_stranded_products() now also rescues out-of-bounds items (and
##   displays).
##
## WEEK 9 — THE MANAGER (Manager.gd, Main.tscn's Manager node), Day 4+.
## Walks the hub and whichever sections _unlocked_sections() returns today,
## and writes up anyone he watches standing idle or mid-chaos for a
## sustained moment (full rules + the warning tell in Manager.gd's header).
## Host-authoritative, same split as the forklift. What lives HERE:
## - DAY GATING via MANAGER_START_DAY below — the one hazard that ISN'T tied
##   to a section opening (Day 4 opens nothing new), so it gets its own named
##   constant next to SECTIONS rather than a bare "4" inside Manager.gd.
##   Applied through the same _configure_hazards() the forklift uses.
## - PAY. There was no currency before this — only a sold count — so a
##   "pay penalty" needed something to be deducted FROM. Pay Today is
##   derived, not stored: today's sold count * PAY_PER_SALE minus today's
##   write-ups * WRITEUP_PENALTY, the same "compute from replicated counters"
##   shape as Sold Today. Only the write-up counters are new replicated state
##   (DaySync). Pay is crew-wide (sales are crew-wide); the report also
##   breaks write-ups down per player so it's clear whose they were. Not
##   clamped at zero: a write-up always visibly costs something.
## - The on-screen tell for the WATCHED player ("LOOK BUSY" + meter) and the
##   write-up toast every peer sees, built in code in _build_alert_layer().
##
## WEEK 10 — DAY 5, COMPOUNDING HAZARDS. No new systems; Day 5 is the first
## day the forklift and the manager run at the same time, Dairy/Frozen opens
## (it already existed end to end — SECTIONS row, gate, shelves, colors, his
## rounds — so this week only verified it), and the store gets denser:
## - Two forklift x manager interaction bugs, fixed where they live (see
##   Manager.gd's FORKLIFT header note): a forklift hit was being logged as
##   the player's chaos (the fumble "throw", the knockback slide into a
##   display), and his Meat/Deli lookouts sat on the forklift's lane, so it
##   could drive straight through him.
## - Density: STACK_ROWS_BY_TIER (shelves stock two deep, Shelf.gd's
##   set_stack_rows()) and PRODUCT_DENSITY_BY_TIER (more stock on the floor),
##   both from Day 5; Days 1-4 are untouched. _spawn_pos_is_clear() now also
##   keeps spawns off slots, since the outer row reaches into the spawn band.
## - tools/hazards_test.gd holds the repro scenarios and a solo-play sim.
##
## WEEK 11 — DAY 5+ TUNING: a longer stocking head start, and the manager's
## priority stock orders. Both reuse what was already here:
## - STOCKING_GRACE_BONUS: a flat +15s on top of SECTION_TIME_BONUS's
##   per-section scaling (_extra_day_time()), from Day 5, on both the grace
##   period and the shift clock.
## - PRIORITY ORDERS (PRIORITY_ORDER_*): every 45s of shift he calls out a
##   random unlocked section and a quantity; 15s to stock it. Tracking is
##   per ITEM, not per shift: Shelf.gd reports each item the moment it's
##   stocked (note_item_stocked()), and one that counts toward the open order
##   is tagged with that order's id (node meta, host-side). Cashier.gd
##   reports each sale (note_sale()); a tagged item whose order was filled
##   counts in priority_sales_today, which _pay_today() pays at the multiplier
##   — the existing Pay Today math, plus one term. The banner is a third row
##   of the LOOK BUSY alert layer (_build_alert_layer()).
##
## WEEK 11 (DAY 6) — THE ENVIRONMENTAL TWIST (Ambience.gd, built in code in
## _ready()). Not a new NPC: flickering lights (a brownout every 20-40s,
## drawn as a world-space darkness overlay + a vignette on your own camera,
## with every hazard tell kept above the dark) and floor spills (random
## leaks in an open aisle that you slide on). Both Day 6+, host-driven,
## replicated, day-gated through _configure_hazards() like the forklift and
## manager, reset in _start_shift(). Full design + reasoning (why spills are
## passive this week, why not from toppled displays, where they can't form)
## in Ambience.gd's header.
##
## WEEK 12 (DAY 7) — THE FINALE. The last day of the core week adds NO new
## hazard or system (the Overcooked-finale principle: everything you already
## know, all at once, under more pressure). Gated like every hazard before it
## by one constant, FINALE_START_DAY, passed to the forklift, manager and
## ambience through _configure_hazards(); each reads its finale numbers
## through its own getter, so Days 1-6 run the exact same values as before:
## - Forklift: shorter stops (FINALE_LOAD/END_PAUSE) -> passes come around
##   faster. Ram telegraph and speeds unchanged.
## - Manager: shorter fuse (FINALE_CATCH_TIME) and priority orders every
##   FINALE_PRIORITY_ORDER_INTERVAL instead of 45s (same 15s window).
## - Spills: cap +1 (FINALE_SPILL_MAX_BONUS, the per-extra-player +1 still on
##   top) and a faster spawn cadence, without which the cap never binds.
## - Lights: shorter gaps between events; the event itself is unchanged.
## - Clock: the one deliberate exception to "flat shift length" — see
##   FINALE_CLOCK_CUT / FINALE_GRACE_CUT for the numbers and reasoning. (WEEK 16:
##   both became FINALE_SELLING_CUT — see the WEEK 16 note.)
## - "FINAL SHIFT" banner once as Day 7 starts (finale_banner_left, replicated), in its
##   own band of the alert layer, with a placeholder sound hook.
## Day 7 also opens Bakery (the 4th section, top density tier) — that was
## already scheduled in SECTIONS, not part of this escalation.
##
## WEEK 13 — ART PASS, FLOORS + WALLS (StoreArt.gd, built in _ready()).
## Pure visuals from the two RPG Maker-format packs in assets/: tiled floors
## for the four sections, the checkout hub and Storage, and wall art drawn
## over the real wall collision shapes. Follow-up: shelf stocking visuals —
## product sprites for Dry Goods, Bakery and (cold drinks) Dairy/Frozen, empty
## shelf bays under their slots, shelving art on the 0/180-degree shelves;
## Meat/Deli stays placeholder (the packs have no separable meat/deli items).
## Visual only; the stock/order/carry logic never reads any of it.
##
## WEEK 15 — STORAGE DELIVERIES (Delivery.gd, DeliveryForklift.gd, both built
## in _ready()). Stock no longer appears from nothing. A box truck backs up to
## a loading dock in Storage's east wall on a schedule; a second, dedicated
## forklift unloads it pallet by pallet into a RECEIVING row; a player carries
## a box onto the UNPACK PAD; the box becomes BACKSTOCK for its section; and
## _restock_products() sends backstock out to that section's floor — same
## spawn band, same floor cap as before — as sales make room. No box run, no
## refill. Full design in Delivery.gd's header. (WEEK 16 replaced the backstock
## step with manual unpacking and the stocked opening with an empty store —
## see the WEEK 16 note; the list below is how Week 15 left it.) What lives HERE:
## - _restock_products() draws from backstock (and skips delivery boxes when
##   counting stock); _spawn_product_for() replaces the random-section spawn.
## - OPENING: each day still opens with the floor at cap — _opening_backstock()
##   puts exactly that much in backstock at _start_shift() and the same
##   restock lays it out. So the tuned Day 1-7 openings (grace periods were
##   tuned around "stock is on the floor when you clock in") are untouched;
##   everything after the opening arrives by truck. FLAGGED design call.
## - Delivery boxes ride the ProductSpawner (spawn data carries the section —
##   host-rolled, peers copy), so they're replicated and cleared each morning
##   like stock; a stray one is rescued back to receiving, not to a section.
## - WHY A SECOND FORKLIFT, not the Produce one on a separate schedule:
##   Storage is open from Day 1 and Produce (the hazard forklift's home) not
##   until Day 3; the only way between the two cells is through the hub and
##   the Sidewalk (a wall seals Produce/Storage), so a shared forklift would
##   drive through the customers' entrance — the exact thing Storage is placed
##   to avoid; and the Produce forklift's Day 7 finale pacing and ram schedule
##   would have to share time with deliveries. A second instance of the same
##   driver (DeliveryForklift.gd extends Forklift.gd) costs nothing and keeps
##   both jobs independent.
## - Two Carryable.gd changes the co-op delivery test forced (details there):
##   carry_distance, so a 44px box isn't set down overlapping its carrier and
##   thrown clear by the physics engine; and a client-smoothing fix — a
##   client's copy of any loose item the host pushed used to settle short of
##   where the host had it (pre-existing, reproduced on the Week 14 code).
##
## WEEK 16 — FINISHING THE DELIVERY LOOP: PREP PHASE, STORE SIGN, MANUAL
## UNPACKING, MORE SHELVES.
## - Manual unpacking: a box set down on the Storage pad comes apart into
##   loose products of its section round the pad, carried to the shelves by
##   hand (Delivery.gd). Week 15's backstock/auto-feed is gone, and so is the
##   last of the floor top-up (_restock_products()): no box runs, no stock.
##   The store opens empty (OPENING_STOCK_FRACTION = 0).
## - The prep phase (PREP_CEILING_BASE and below) replaces every grace-period
##   knob: the store opens CLOSED — no customers, no priority call-outs, but
##   trucks from 3s in — until someone flips the Store sign at the entrance
##   (open_store(), host-authoritative, replicated; simultaneous flips open it
##   once) or the ceiling runs out. The day's clock is fixed: ceiling + the
##   selling window every day already had.
## - More shelving: Shelf5 (and Shelf6 in Dry Goods) in Main.tscn, in the empty
##   middle of a section wall — Dry Goods +2 (top wall), Produce, Dairy/Frozen
##   and Bakery +1 (bottom wall) — same shelf art as every other (StoreArt.gd
##   dresses them from the "shelf" group), same section tint. The Produce
##   forklift's lap picks its new shelf up as one more stop by itself. FOUND
##   BY THE SPILL TESTS: a second shelf on the opposite wall of Dairy/Frozen or
##   Bakery closes the only stretch of aisle wide enough for a spill once
##   shelves stock two deep (Day 5+: 168px between the outer slot rows, a
##   54px spill needs ~200 clear of slots) — spills there nearly stopped. So
##   those two get one; Dry Goods' open side is the hub, so it keeps two.
##
## WEEK 18 — AN UNPACK PAD IN EVERY SECTION (Delivery.gd's PAD_CENTERS),
## replacing the one central pad in Storage. The truck, dock, delivery
## forklift and RECEIVING are unchanged; a player now carries a box from
## RECEIVING, through the Sidewalk and the hub, to its own section's pad, and
## it only unpacks there (another section's pad refuses it, "wrong pad"). The
## six units it comes apart into are already in the room they're shelved in.
## Why: with one pad in Storage, every unit was its own Storage -> section
## walk, and that walking — not the order window — was what held the solo
## priority-order fill rate at ~36%. Boxes and their carriers cross the hub
## while customers shop (trucks run all shift): intended delivery chaos.
## Produce's sale bin moved out of the alcove its pad sits in, to the
## alcove's east side (2400,690 -> 2520,700).
##
## WEEK 19 — END-OF-SHIFT CLEANUP (Cleanup.gd, built in _ready()). The prep
## phase's shape, inverted. When the day's clock (prep ceiling + selling
## window, unchanged) runs out, the store CLOSES instead of the report coming
## up: customers leave, priority orders and the lights/spill clocks stop, the
## Produce forklift parks and the manager goes home, and no more trucks come.
## The crew mops and sweeps (Cleanup.gd has the mess, tools and scoring),
## then anyone clocks out at the time clock in the break room (clock_out(),
## host-authoritative, replicated; simultaneous presses clock out once) — or
## the CLEANUP CEILING (_cleanup_ceiling(), sized to the mess at close) does
## it for them. Clocking out scores the cleanup, adds its bonus to the day's
## pay, and raises the end-of-day report exactly as the clock used to.
## Cleanliness is a pay BONUS, never a fail state.
##
## WEEK 21 — ENDLESS MODE (Endless.gd: the board, contracts, Bucks, upgrades;
## HubUI.gd: its two screens). Days 1-7 are the story. Day 7's report ->
## _finish_story(): the WEEK COMPLETE screen (the week's totals, +40 Bucks, and
## a plain statement that the story is over) -> enter_hub(): the break room hub,
## the shift board beside the shop -> take_offer(): that posting's shift, the
## same prep/selling/cleanup/clock-out day as ever -> its report (medal, Bucks,
## the run's totals) -> the hub again. current_day parks at 8 for the whole
## run; nothing on screen calls an endless shift a "Day".
## - ONE gate for everything that used to read the day: is_section_open() for
##   sections (gates, lock visuals, _unlocked_sections(), is_unlocked_at_pos(),
##   Cleanup's bins) and hazard_levels() for hazards (forklift, manager,
##   priority orders, spills, lights, the finale's tight clock). The story's day
##   gates produce exactly what they always did; endless reads the posting.
## - "WEEK" TOTALS: honest by construction. The story's report keeps Week Total
##   (Days 1-7 are a week). At WEEK COMPLETE the week's totals are captured for
##   that screen and the running week counters are zeroed; an endless report
##   shows the SHIFT and the RUN (Endless.run_stats) and no line claims to be a
##   week. (WEEK 24: the run — wallet, upgrades, totals — is saved now; see
##   the SAVE / LOAD note below.)
## - Upgrades read through Endless.gd from Player.gd (speed, spill traction,
##   forklift stun, the Back Brace's carry capacity), Carryable.gd (the host's
##   capacity check, the carried stack), Manager.gd (fuse) and Cleanup.gd.
##
## TUNABLE NUMBERS — DAY 3+ BALANCE REFERENCE (documentation only; the
## constants below are the source of truth, and every one is still a FLAGGED
## placeholder, none human-playtest-tuned yet). One place to see every knob
## that shapes a Day 3+ shift, its current value, and where it lives. Edit
## the value where it lives, then update the line here. Tier arrays are
## indexed by (unlocked sections - 1): [Day 1-2, Day 3-4, Day 5-6, Day 7] —
## Phase 2: [1, 2, 3, 4 sections owned].
## Deliberately left out: collision/geometry/pathing internals (arrive
## distances, clearances, smoothing, stall detection), which are
## correctness plumbing, not balance.
##
##   SHIFT CLOCK & PREP (WEEK 16; replaced the grace-period knobs) — Main.gd
##     PREP_CEILING_BASE                 180.0 s  store-closed prep, at most...
##     PREP_CEILING_PER_SECTION          180.0 s  ...+ this per section open beyond Dry Goods
##     SHIFT_DURATION_DEFAULT            111.0 s  the selling window (--shift-seconds= overrides)
##     FINALE_SELLING_CUT                 15.0 s  Day 7 selling window 96s
##     -> day clock = ceiling + selling: Day 1-2 180+111=291s, Day 3-4 360+111=471s,
##        Day 5-6 540+111=651s, Day 7 720+96=816s. Opening early (the Store
##        sign) moves the unused ceiling into selling; the clock never changes.
##     STORE_SIGN_POS / STORE_SIGN_RANGE   (1610,1115) / 70 px
##
##   CLEANUP (WEEK 19) — Main.gd (the rest in Cleanup.gd)
##     CLEANUP_CEILING_BASE / _PER_MESS   50 s + 4 s per mess item at close (WEEK 20: base was 40)
##     CLEANUP_CEILING_MIN / _MAX         60 / 180 s
##     TIME_CLOCK_POS / TIME_CLOCK_RANGE   (880,300) break room / 70 px
##     Cleanup.gd STATION_POS               (700,280) break room, by the time clock (WEEK 20)
##     Cleanup.gd LITTER_RATE_PER_CUSTOMER 1/60 per customer-second in the store
##     Cleanup.gd CLEAN_BONUS_MAX           0.25 (+25% of gross pay, split
##                                          evenly: spills & knockovers / litter)
##     Cleanup.gd PAN_CAPACITY              8 pieces, emptied at a trash bin
##     Cleanup.gd LITTER_PAY_PER_PIECE      $1 a piece picked up (E by hand any time, or swept),
##                                          its own Pay line, outside the bonus (Oct 2026)
##     Carryable.gd PICKUP_RANGE            70 px (+12 host net slack), the store's shared E radius (Oct 2026: was 60)
##     Cleanup.gd MOP_TIME_* / SWEEP_TIME   spill ~2.1-2.6 s, display 1.6, stock 0.8 / 0.45 s
##
##   BREAK ROOM COFFEE (WEEK 23) — BreakRoom.gd (FLAGGED placeholders)
##     COFFEE_POS / COFFEE_RANGE            (180,66) top-wall counter / 70 px
##     COFFEE_SPEED_BONUS                   +0.20, added to the sneakers' multiplier
##     COFFEE_COST_DOLLARS                  $40 per cup off a story day's Pay Today
##     COFFEE_COST_BUCKS                    5 per cup off an endless shift's Bucks, per head
##
##   SHOPKEEPER ECONOMY (OCT 2026 PHASE 2; replaced DAY GATING) — Main.gd
##     STARTING_MONEY                      $0
##     SECTION_PRICES                      Produce $500, Dairy/Frozen $900, Bakery $1400 (in that order)
##     COMPLICATION_STAGES (one step per shift start, never back down):
##       1 forklift      own Produce (2 sections)
##       2 manager       lifetime earned >= MANAGER_EARNED $800
##       3 orders        own Dairy/Frozen (3 sections)
##       4 lights+spills lifetime earned >= ENVIRONMENT_EARNED $1700
##       5 top tier      own Bakery (4) and lifetime earned >= RUSH_EARNED $3500
##     GATE_BUY_RANGE                     70 px  (buy at the gate, E, during prep)
##     STAGE_BANNER_SECONDS                6.5 s  "NEW: ..." banner as a stage starts
##
##   STORE DENSITY (tiered) — Main.gd
##     CUSTOMER_CAP_BY_TIER               [5, 9, 13, 17]
##     CASHIER_COUNT_BY_TIER              [2, 3, 4, 5]
##     ITEMS_TARGET_BY_TIER               [1, 2, 2, 3]  (no longer read — Phase 3B lists below)
##
##   SHOPPING LISTS + CARTS (OCT 2026 PHASE 3B) — Main.gd / Customer.gd (FLAGGED)
##     SHOPPING_LIST_BY_TIER              [[1,2],[2,3],[2,3],[2,4]]  list length, random in [min,max]
##     SHOPPING_LIST_MAX_PER_SECTION      2  (and never more than that section's stocked units)
##     Customer.gd LIST_PATIENCE          10 s  wait for a sold-out item before crossing it off
##     Customer.gd REPLAN_EVERY           3 s   shopper path re-plan (CustomerNav.gd grid, 20 px)
##     Customer.gd SLOT_STAND             29 px  stand-off in front of a slot to take an item
##     Cashier.gd CHECKOUT_WAIT_SECONDS   3 s an item (unchanged — a cart rings up item by item)
##     STACK_ROWS_BY_TIER                 [1, 1, 2, 2]  shelf rows (Shelf.gd set_stack_rows())
##     PRODUCT_DENSITY_BY_TIER            [1.0, 1.0, 1.5, 1.5]  x per-section product cap
##     PRODUCT_PER_EXTRA_PLAYER            3
##     CUSTOMER_PER_EXTRA_PLAYER           2
##     CUSTOMER_DISRUPTIVE_RATIO           0.35  of the LIVE crowd (Oct 2026 fix: was per spawn — see _restock_customers())
##     Customer.gd MAX_LIFETIME_DISRUPTIVE 45 s x 0.6-1.0 (DISRUPTIVE_LIFETIME_JITTER, Oct 2026)
##     RESTOCK_CHECK_INTERVAL              3.0 s  customer top-up + stray-stock rescue cadence
##
##   PAY — Main.gd
##     PAY_PER_SALE                       $10
##     WRITEUP_PENALTY                    $25
##     PRIORITY_ORDER_MULTIPLIER           1.5 x  (order items pay $15)
##
##   DAY 6 ENVIRONMENT — Ambience.gd (slip reaction in Player.gd)
##     LIGHTS_START_DAY / SPILLS_START_DAY 6 / 6
##     LIGHTS_FIRST_DELAY                 14.0 s  into the shift
##     LIGHTS_INTERVAL_MIN / _MAX         18 / 30 s  of normal light between events
##     LIGHTS_FLICKER_IN / DIM / FLICKER_OUT  1.2-2.0 / 5-9 / 0.6-1.0 s
##     LIGHTS_DIM_LEVEL                    0.55   brownout brightness (1 = normal)
##     LIGHTS_BUZZ_LEVEL / FLICKER_LOW     0.42 / 0.3  momentary dips only
##     VIGNETTE_STRENGTH                   0.6    edge darkening at full brownout
##     SPILL_FIRST_DELAY                   8.0 s
##     SPILL_INTERVAL_MIN / _MAX          16 / 26 s  between spawn attempts
##     SPILL_MAX (+ _PER_EXTRA_PLAYER)     3 (+1)  on the floor at once
##     SPILL_RADIUS_MIN / _MAX            38 / 54 px
##     SPILL_FORM / WET / DRY_TIME         1.5 / 34 / 6 s  (forming = harmless telegraph)
##     SPILL_SPEED_FACTOR                  0.7 x  top speed on a spill
##     SPILL_TRACTION                    420 px/s^2  (off a spill: instant)
##     SPILL_SLIDE_OUT                     0.3 s  low traction after stepping off
##     SPILL_EXCUSE_MARGIN                70 px   Manager.gd: pushes near a spill aren't chaos
##
##   TOP TIER (was the DAY 7 FINALE) — complication stage 5; every value is stage 5 only
##     FINALE_SELLING_CUT                 15 s   -> Day 7 sells 96s (Day 6: 111s) after a
##                                         12-min prep ceiling (was: clock -20s, grace -5s)
##     FINALE_PRIORITY_ORDER_INTERVAL     32 s   (vs 45)
##     Forklift FINALE_LOAD / END_PAUSE    0.7 / 0.8 s  (vs 1.2 / 1.6)
##     Manager FINALE_CATCH_TIME           2.0 s  (vs 2.5; still > CHAOS_MEMORY 1.5)
##     Ambience FINALE_SPILL_MAX_BONUS     +1     (cap 4 solo, +1 per extra player)
##     Ambience FINALE_SPILL_INTERVAL      12-20 s (vs 16-26)
##     Ambience FINALE_LIGHTS_INTERVAL     12-22 s (vs 18-30)
##     FINALE_BANNER_SECONDS               4.5 s  (now only the endless postings' start banner)
##
##   ENDLESS MODE (WEEK 21) — Endless.gd; every value a FLAGGED placeholder
##     hazard levels                      0 off / 1 Days 3-6 numbers / 2 Day 7 numbers
##     stars from heat (levels + extra sections, 0-13)  2* at 3, 3* at 6, 4* at 9, 5* at 11
##     OFFER_BANDS                        [1-2*], [3*], [4-5*] — one posting each
##     TIGHT_CLOCK_STARS                  4 (Day 7's 96s selling window); also any
##                                         posting with all four sections open
##                                         (keeps every shift <= Day 7's 816s)
##     Bucks: 1/sale, 4/order filled, +40% of those for a spotless close,
##            -3/write-up (all per head in a crew), medal +5/+12/+25,
##            x(1 + 0.15 per star above 1)
##     WEEK_COMPLETE_BUCKS                40
##     medal targets (gold): $150/300/400/420 by 1-4 sections, -4%/heat (floor
##            45%), +60%/extra player; silver 70%, bronze 40%
##     upgrades: see Endless.gd's UPGRADES (costs and effects)
##
##   STORAGE DELIVERIES — Delivery.gd (forklift driving: DeliveryForklift.gd)
##     (deliveries run every shift — Storage is the crew's from the start)
##     TRUCK_FIRST_DELAY                   3.0 s  into the shift (prep starts at once)
##     TRUCK_INTERVAL_MIN / _MAX          24 / 32 s  arrival to arrival (never two at once)
##     TRUCK_ARRIVE / DEPART / LINGER      2.5 / 2.0 / 1.0 s
##     BOXES_PER_TRUCK_BY_TIER            [2, 3, 4, 5]  (each open section gets one first)
##     BOXES_PER_EXTRA_PLAYER              1
##     UNITS_PER_BOX                       6      loose products per unpacked box
##     PAD_SETTLE_TIME / PAD_REST_SPEED    0.3 s / 150 px/s
##     SPILL_RING_MIN / _MAX              80 / 150 px  where they land round the pad
##     PAD_CENTERS (WEEK 18)              one per section, in the section (layout, not balance)
##     Delivery forklift: Forklift.gd's speeds and LOAD_PAUSE; SET_DOWN_PAUSE 0.6 s
##     OPENING_STOCK_FRACTION (Main.gd)    0.0    of the old floor cap out at opening
##
##   PRIORITY ORDERS — Main.gd
##     PRIORITY_ORDER_INTERVAL            45.0 s  between call-outs
##     PRIORITY_ORDER_WINDOW_BY_PLAYERS   45 / 40 / 35 / 30 s  to fill one, 1/2/3/4 players
##     PRIORITY_ORDER_MIN_GAP_AFTER_WINDOW  5 s  call-out gap >= window + this
##     PRIORITY_ORDER_QTY_MIN / _MAX       3 / 5  (capped by what the section can take)
##     PRIORITY_ORDER_QTY_PER_EXTRA_PLAYER 2
##     PRIORITY_ORDER_RESULT_SECONDS       3.0 s  FILLED/missed line on the banner
##
##   FORKLIFT — Forklift.gd (hit reaction in Player.gd)
##     DRIVE_SPEED / RAM_SPEED / REVERSE_SPEED   120 / 175 / 85 px/s  (player is 220)
##     TURN_RATE                           3.2 rad/s
##     TELEGRAPH_TIME                      0.9 s  beacon warning before a ram
##     RAMS_PER_LAP                        1
##     LOAD_PAUSE / END_PAUSE              1.2 / 1.6 s
##     START_PAUSE                         4.0 s  after each day's reset
##     KNOCK_SPEED_PRODUCT / _DISPLAY      480 / 360 px/s
##     Player.gd FORKLIFT_KNOCKBACK_SPEED  520 px/s
##     Player.gd FORKLIFT_STUN_DURATION    0.6 s
##
##   SHELF WRECKS — Shelf.gd
##     WRECK_DURATION                      7.0 s  shelf refuses stock
##     WRECK_SPILL_RADIUS                130 px   (+ STACK_ROW_DEPTH 56 per extra row)
##     WRECK_SPILL_SPEED                 460 px/s
##     KNOCK_SPEED                       120 px/s  hit that un-shelves a placed item
##     SETTLE_TIME                         0.35 s  rest before an item counts as stocked
##     Display.gd TOPPLE_SPEED           200 px/s  floor display knock-over
##
##   MANAGER — Manager.gd
##     WALK_SPEED                         95 px/s
##     HUB_PAUSE / LOOKOUT_PAUSE           2.5 / 2.2 s
##     START_PAUSE                         8.0 s  after each day's reset
##     DETECT_RANGE                      280 px
##     DETECT_HALF_ANGLE                  65 deg  (130-degree cone)
##     DETECT_NEAR_RANGE                  70 px   seen regardless of facing
##     CATCH_TIME                          2.5 s  of suspicion-in-sight to write up
##     WARN_LEVEL                          0.5    "?" -> "!" / LOOK BUSY turns red
##     DECAY_RATE                          0.6 /s meter drain once busy/out of sight
##     CAUGHT_COOLDOWN                    10.0 s  per player
##     IDLE_DELAY                          1.0 s  still this long = idle
##     WORK_GRACE                          2.0 s  after a pickup/drop/place
##     CHAOS_MEMORY                        1.5 s
##     REGISTER_RANGE                    110 px   at a register = busy
##     FORKLIFT_EXCUSE                     1.5 s  forklift-hit chaos amnesty

## ============================================================================
## OCT 2026 PIVOT, PHASE 2 — THE SHOPKEEPER ECONOMY. The 7-day story is gone.
## The game runs indefinitely: shift after shift (the same prep -> selling ->
## cleanup -> clock-out -> report loop as ever), with progression driven by
## MONEY instead of the calendar.
## - THE BANK (money): one shared pool for the whole crew, host-authoritative,
##   replicated (DaySync), saved. Each shift's Pay Today goes into it at
##   clock-out (_bank_shift_pay(), the one place pay is credited — Phase 3's
##   helper wages will be a debit beside it). Pay can be negative (write-ups),
##   so the bank can too; nothing is gated on a negative balance.
## - LIFETIME EARNED (lifetime_earned): every positive Pay Today ever banked.
##   Spending never lowers it — it's what money-gated complications read, so
##   buying a section can never switch a hazard back off.
## - OCT 2026 PHASE 3 — HIRED HELPERS (Staff.gd, Helper.gd): one per section
##   after Dry Goods, hired at the break room's staff board out of the bank;
##   their wages come out at clock-out beside the pay (_bank_shift_pay()), and
##   like every other spend they never touch lifetime_earned. Their numbers
##   and the measurements behind them are in Staff.gd's NUMBERS block.
## - SECTIONS ARE BOUGHT (sections_owned): the crew starts with Dry Goods and
##   buys the rest IN ORDER (Produce, Dairy/Frozen, Bakery — SECTIONS order),
##   each at its own price (SECTION_PRICES). Bought at the section's own gate:
##   E while standing at it, empty-handed, during PREP (store closed). The
##   section opens on the spot (gate, shelves, deliveries, checkout lanes), and
##   the prep ceiling grows by PREP_CEILING_PER_SECTION so the new aisle gets
##   its stocking time. Shelf stacking depth (shelf_rows) only changes at the
##   next shift start: Shelf.set_stack_rows() unshelves everything, which
##   mid-prep would dump the crew's stocking on the floor.
## - COMPLICATIONS ESCALATE BY STAGE (complication_stage, 0..5), in the order
##   the days used to bring them: forklift, manager, priority orders, the
##   lights + spills, then the finale-style top tier. Each stage needs
##   sections owned and/or lifetime earned (COMPLICATION_STAGES). The stage
##   only ever moves at a SHIFT START, by at most ONE step, so every new thing
##   arrives the way "Day 4: the manager" used to: forecast on the previous
##   shift's report ("NEXT SHIFT: ..."), announced by a banner as the shift
##   starts, and never mid-shift. Never goes back down.
## - THE TOP TIER (stage 5, "rush"): everything at its old Day 7 numbers plus
##   the tight clock, EVERY shift from then on — a sustained state, not an
##   ending. The one-time FINAL SHIFT banner is gone with the day it belonged
##   to; a "NEW THIS SHIFT" banner announces each stage once instead.
## - current_day is now just the shift counter ("Day 12"): nothing gates on it.
##   --day=N (debug/tests) starts at the economy old Day N had — see
##   DEBUG_DAY_PRESETS — so every Day-N test scenario keeps its meaning.
## Every number here is a FLAGGED, tunable placeholder — reasoning and the
## measurements they came from are next to each.
## ============================================================================
## PRICING (FLAGGED placeholders — retune after playing). Measured with the
## solo bot sim (tools/hazards_test.gd --test=solo, Days 1-7, Oct 2026): a
## competent SOLO player banks ~$250 a shift (Day 1-7: $260, $224, $237, $326,
## $175, $332, $186) and, notably, that doesn't grow with sections — one pair
## of hands is the bottleneck, not demand. A 3-player crew with every shelf
## kept full banks ~$860 a shift with the whole store open (economy_test.gd
## --test=soak). So:
## - STARTING_MONEY 0: nothing to spend it on before the first purchase; the
##   first shift's pay landing in an empty bank is the introduction.
## - Produce $500 = two average solo shifts, exactly the old Day 1-2 -> Day 3.
## - Each later section costs more (~1.8x, ~1.55x): Dairy/Frozen $900 (~3.5
##   solo shifts), Bakery $1400 (~5.5). The whole store ($2800) is ~11 solo
##   shifts, or ~5-7 for a 2-3 player crew — about the old week's pace for a
##   crew, and a longer climb solo now that there's no week to fit into.
const STARTING_MONEY := 0
## In SECTIONS order after Dry Goods (owned from the start).
const SECTION_PRICES := {"Produce": 500, "Dairy/Frozen": 900, "Bakery": 1400}
## Lifetime-earned thresholds for the two money-gated stages and the top tier,
## each about ONE solo shift of pay past the purchase it follows — the old
## one-day gap (Day 3 forklift -> Day 4 manager, Day 5 orders -> Day 6 lights):
## - manager: Produce's $500 + ~$300 -> $800.
## - lights + spills: Produce + Dairy/Frozen ($1400) + ~$300 -> $1700.
## - top tier: the whole store ($2800) + ~$700 — "owns everything and has
##   plenty of money" — $3500. Lifetime, not the bank, so spending (and later,
##   Phase 3's wages) never switches it back off.
const MANAGER_EARNED := 800
const ENVIRONMENT_EARNED := 1700
const RUSH_EARNED := 3500
## The complication ladder. Stage i is on once stage i-1 is AND its own needs
## are met (checked at shift start, one step per shift). "sections" = sections
## owned (Dry Goods counts), "earned" = lifetime_earned. title/line: the
## start-of-shift banner and the report forecast.
const COMPLICATION_STAGES := [
	{"key": "start", "sections": 1, "earned": 0, "title": "", "line": "", "ask": ""},
	{"key": "forklift", "sections": 2, "earned": 0, "title": "NEW: THE FORKLIFT",
		"line": "A forklift works the Produce aisle — it rams shelves. Watch for its beacon.", "ask": "buy Produce"},
	{"key": "manager", "sections": 2, "earned": MANAGER_EARNED, "title": "NEW: THE MANAGER",
		"line": "He walks the floor and writes up anyone standing idle (-$25 each).", "ask": ""},
	{"key": "orders", "sections": 3, "earned": 0, "title": "NEW: PRIORITY ORDERS",
		"line": "The manager calls out rush orders — stock them in time for 1.5x pay.", "ask": "buy Dairy/Frozen"},
	{"key": "environment", "sections": 3, "earned": ENVIRONMENT_EARNED, "title": "NEW: BAD WIRING & LEAKS",
		"line": "The lights brown out and the floor springs spills. Mind your footing.", "ask": ""},
	{"key": "rush", "sections": 4, "earned": RUSH_EARNED, "title": "RUSH SEASON",
		"line": "Everything's on, everything's harder — every shift from now on.", "ask": "buy Bakery"},
]
const STAGE_FORKLIFT := 1
const STAGE_MANAGER := 2
const STAGE_ORDERS := 3
const STAGE_ENVIRONMENT := 4
const STAGE_RUSH := 5
## --day=N debug starts: the economy old Day N had (sections owned, stage,
## lifetime earned) — index = day. Day 3: Produce + forklift; 4: + manager;
## 5: Dairy/Frozen + orders; 6: + lights/spills; 7: Bakery + the top tier.
## Days past 7 use Day 7's.
const DEBUG_DAY_PRESETS := [
	[1, 0, 0], [1, 0, 0], [1, 0, 0],
	[2, STAGE_FORKLIFT, 500],
	[2, STAGE_MANAGER, MANAGER_EARNED],
	[3, STAGE_ORDERS, 1400],
	[3, STAGE_ENVIRONMENT, ENVIRONMENT_EARNED],
	[4, STAGE_RUSH, RUSH_EARNED],
]
## Purchase interaction: how close to a for-sale gate's line E buys it — the
## store's shared E radius (Carryable.gd's PICKUP_RANGE, the sign, the clock).
const GATE_BUY_RANGE := 70.0
## The old story's length — only the debug --endless route reads it now (Day
## 7's report finishes that "week" into Endless Mode, so the untouched Endless
## code stays reachable and tested until Phase 4 folds it in).
const LEGACY_WEEK_DAYS := 7
## The selling window. Week 12 cut the finale's clock by 20s and its grace by
## 5s, which landed as a 15s cut to the selling window: 96s vs Day 6's 111s
## (-14%), with the biggest crowd of the week. WEEK 16 keeps exactly that
## selling window and drops the grace side (the prep phase replaced it — see
## PREP_CEILING_BASE), so the finale's cut is now stated as what it always
## amounted to. A cut to the normal math, so --shift-seconds= still scales it.
const FINALE_SELLING_CUT := 15.0
## Priority orders every 32s instead of 45 — about 3 call-outs in the
## selling window instead of 2. The window to fill one (15s) is unchanged,
## and still well under the interval, so one is always closed before the
## next is due.
const FINALE_PRIORITY_ORDER_INTERVAL := 32.0
## The "FINAL SHIFT" banner (finale_banner_left): on screen this long, the
## last second fading. WEEK 22: with a fanfare (Sfx "final_shift",
## res://audio/final_shift.ogg).
const FINALE_BANNER_SECONDS := 4.5
## OCT 2026 PHASE 2: a new complication's banner stays up a little longer —
## it carries a sentence of what it does.
const STAGE_BANNER_SECONDS := 6.5
## FLAGGED PLACEHOLDER ECONOMY — the first money numbers in the project,
## picked so one write-up clearly hurts (2.5 sales' worth) without one bad
## moment erasing a whole shift. Tune freely.
const PAY_PER_SALE := 10
const WRITEUP_PENALTY := 25
## WEEK 11 — manager priority stock orders, Day 5+ (see the WEEK 11 header
## note). Every PRIORITY_ORDER_INTERVAL of shift clock he calls out one
## unlocked section and a quantity; the crew has PRIORITY_ORDER_WINDOW to
## stock that many into it. Items stocked toward an order that gets FILLED
## pay PRIORITY_ORDER_MULTIPLIER x PAY_PER_SALE when they sell (the rest of
## the day's sales are untouched); an order that runs out of time costs
## nothing, it just pays no bonus. Quantity: a random roll in
## [QTY_MIN, QTY_MAX] (+ per extra player), capped at what the section can
## actually take right now (open slots, loose stock of its color) so an
## order is never impossible. FLAGGED placeholders, tuned against the solo
## sim in tools/hazards_test.gd, not a human playtest.
const PRIORITY_ORDER_INTERVAL := 45.0
## WEEK 16: call-outs only run once the store is open. Before, their timer ran
## through the grace period too, so the selling window already had one due
## soon after customers arrived — 3 per selling window on Days 5-7. Starting
## the gap from zero at opening dropped that to 2 (found by the Days 1-7 solo
## sim); the first one 5s after opening restores 3 (Day 5-6: 5/50/95s of a
## 111s window; Day 7: 5/37/69s of 96s).
const PRIORITY_ORDER_FIRST_AFTER_OPEN := 5.0
## WEEK 17 — the window to fill an order, by crew size (index = players - 1,
## 4+ use the last). Was a flat 15s. Since Week 16 the called stock has to
## come out of Storage by hand, so a solo crew filled 1 of 9 orders (it was 5
## of 10 when stock sat on the section floor). The order's SIZE already grows
## with the crew (QTY_PER_EXTRA_PLAYER); the window shrinks the other way, as
## a bigger crew splits the Storage run.
## SOLO 45s: the Days 5-7 solo sim sweep (filled/called, 2-4 runs each) —
## 15s 0/18, 25s 4/14, 35s 7/24, 40s 6/24, 45s 8/20. A solo player hauls about
## one item per 11-12s from the pad, so most misses were near-misses (2/3,
## 2/4); 45s is the best measured without the window eating the call-outs.
## CREW: the average order is 4 items for one player, 6/8/10 for 2/3/4
## (QTY_PER_EXTRA_PLAYER) — 3 / 2.7 / 2.5 per person — but a crew doesn't haul
## at N x the solo pace (one pad, one walk, getting in each other's way): at
## 35s the 2-player co-op sim filled 1 of 6 (most misses 2-5 of 6-7). So
## 40/35/30s — still shorter per crew size, still tighter per item than solo
## at 4. FLAGGED placeholders, bot-sim tuned.
const PRIORITY_ORDER_WINDOW_BY_PLAYERS := [45.0, 40.0, 35.0, 30.0]
## An order is always closed before the next call-out is due (Week 11's rule):
## the gap to the next one is at least the window plus this.
const PRIORITY_ORDER_MIN_GAP_AFTER_WINDOW := 5.0
const PRIORITY_ORDER_MULTIPLIER := 1.5
const PRIORITY_ORDER_QTY_MIN := 3
const PRIORITY_ORDER_QTY_MAX := 5
const PRIORITY_ORDER_QTY_PER_EXTRA_PLAYER := 2
## How long the "ORDER FILLED" / "order missed" line stays on the banner.
const PRIORITY_ORDER_RESULT_SECONDS := 3.0

## Spawn-overlap clearance (see _spawn_pos_is_clear()). Forklift: its
## rotated collision box reaches ~56px from its origin, plus a product's own
## ~20px half-diagonal and margin. Carryable: two 28px boxes overlap inside
## ~40px center-to-center.
const SPAWN_CLEARANCE_FORKLIFT := 95.0
const SPAWN_CLEARANCE_DISPLAY := 50.0
const SPAWN_CLEARANCE_PRODUCT := 40.0
const SPAWN_ATTEMPTS := 10
## Anything closer than this to the outer edge is inside/past the 20px
## perimeter walls — see _is_out_of_bounds().
const WORLD_EDGE_MARGIN := 20.0

const PlayerScene := preload("res://Player.tscn")
const AmbienceScript := preload("res://Ambience.gd")
const DeliveryScript := preload("res://Delivery.gd")
const DeliveryForkliftScript := preload("res://DeliveryForklift.gd")
const CleanupScript := preload("res://Cleanup.gd")
const TutorialScript := preload("res://Tutorial.gd")
const EndlessScript := preload("res://Endless.gd")
const HubUIScript := preload("res://HubUI.gd")
const SoundDirectorScript := preload("res://SoundDirector.gd")
const JuiceScript := preload("res://Juice.gd")
const BreakRoomScript := preload("res://BreakRoom.gd")
const StaffScript := preload("res://Staff.gd")
const SaveGameScript := preload("res://SaveGame.gd")
const ForkliftScene := preload("res://Forklift.tscn")
const StoreArtScript := preload("res://StoreArt.gd")
const ProductScene := preload("res://Product.tscn")
const CustomerScene := preload("res://Customer.tscn")
const CustomerScript := preload("res://Customer.gd")
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
## file's header. (Oct 2026 Phase 2: no required_day any more — sections are
## bought, in this order, at SECTION_PRICES; see is_section_open().) The old
## required_day mirrored the brief's Day 1-2 / 3-4 / 5-6 / 7
## schedule exactly, and is also what _configure_gates() below sets on each
## matching Gate instance by node name (not a .tscn property override — see
## that function's own comment on why), so this table and the actual
## physical doors can't quietly drift apart from each other.
const SECTIONS := [
	{"name": "Dry Goods", "node_name": "DryGoods", "grid_pos": Vector2i(1, 0)},
	# WEEK 13 #4: sold as PRODUCE now (was Meat/Deli — the art packs have no
	# separable meat/deli items, and a full produce range). Only the displayed
	# name changed; node_name and every "MeatDeli" node path stay as they were
	# (internal, never shown), as do its cell, gate, Day 3 unlock and the
	# forklift lane — "Meat/Deli" in older comments means this section.
	{"name": "Produce", "node_name": "MeatDeli", "grid_pos": Vector2i(2, 1)},
	{"name": "Dairy/Frozen", "node_name": "DairyFrozen", "grid_pos": Vector2i(0, 1)},
	{"name": "Bakery", "node_name": "Bakery", "grid_pos": Vector2i(2, 0)},
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
	"Produce": Color(0.85, 0.25, 0.25, 1),
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
## OCT 2026 PHASE 2 — the shopkeeper economy (see the block above
## STARTING_MONEY). Host-written, replicated on DaySync, saved.
var money := STARTING_MONEY
var lifetime_earned := 0
var sections_owned := 1 # Dry Goods; the next ones in SECTIONS order
var complication_stage := 0
## The shelf stacking depth this shift (Shelf.set_stack_rows()), snapshotted
## by the host at shift start from the sections open then — see the economy
## note on why it doesn't follow a mid-prep purchase.
var shelf_rows := 1
## Host: the stage that the NEW THIS SHIFT banner announces this shift (0 =
## none); replicated so a client's banner names the same thing.
var stage_banner := 0
## Debug: --money=N starts the bank there (purchase tests, playtesting).
var debug_money := -1
var _day_given := false
## Debug: --endless. Day 7's report finishes the old story's week into the
## untouched Endless Mode (WEEK COMPLETE -> hub) — the only route to it until
## Phase 4. endless_active is the flag every "is this an endless shift" read
## goes through now (current_day keeps counting, so "> 7" no longer means it).
var legacy_endless_route := false
var endless_active := false
## Host-local, one-off notices on the big banner band (legacy save, a
## section bought): [big, small, seconds left].
var _notice := ["", "", 0.0]
## Diagnostics (tests): purchases made / refused on the host this session.
var purchases_made := 0
var purchases_refused := 0
## WEEK 24 — SAVE / LOAD (SaveGame.gd has the file format and why). Host-only
## state, never replicated: the save is the HOST's — clients see its effects
## through the state it loads (current_day, Endless's wallet/upgrades, ...),
## the same way they see everything else the host runs.
## - completed_story_day: the last story day whose report came up (0-7).
##   story_complete: Day 7's report was continued past (WEEK COMPLETE).
## - Loaded once, as hosting begins (_on_host_pressed -> _load_progress()):
##   a story save resumes at the day after the last completed one; a Day 7
##   save that never reached WEEK COMPLETE reopens that screen; a finished
##   story opens straight into the hub. No file, or a damaged one: Day 1.
## - Written at every checkpoint (save_progress()): each story day's report,
##   WEEK COMPLETE, entering the hub, each endless shift's payout, back to the
##   hub, every Break Room purchase — and the report's Save button.
## - Debug starts never touch the real save: --day=N (and --bot) start where
##   asked and don't write it. --save-file=PATH uses PATH instead (and does
##   load/save even with --day=, which then still picks the start day);
##   --no-save turns it all off; --new-game ignores the save until the first
##   checkpoint overwrites it.
var completed_story_day := 0
var story_complete := false
var save_path := SaveGameScript.DEFAULT_PATH
var save_enabled := true
var _skip_load := false
## The story week's sales from before this launch (the cashiers' replicated
## total_sold counters start at 0 every launch) — part of _total_sold(), so
## Week Total and the WEEK COMPLETE screen still count the earlier days.
## Replicated (DaySync), since every peer's report shows Week Total.
var sold_carryover := 0
## Diagnostics (tests and the report's Save button): what the last load found
## (SaveGame.LOAD_*; -1 = no load attempted) and saves actually written.
var load_status := -1
var saves_written := 0
## (WEEK 21: the old _last_configured_day sentinel is now _last_config_key,
## declared by _config_key() — "" never matches a real key, so the first
## _process() tick on every peer still configures the world once.)
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
## WEEK 9 — write-up counters (see the WEEK 9 header note). Host-written in
## record_writeup(), replicated via DaySync. writeups_by_peer is peer_id ->
## count for today, reassigned (not mutated) on every change so it's plainly
## a new value to the synchronizer.
var writeups_today := 0
var writeups_week := 0
var writeups_by_peer := {}
## WEEK 11 — priority orders (see PRIORITY_ORDER_* above). The open order and
## the day's order tallies are host-written and replicated via DaySync, the
## same as the write-up counters, so every peer's banner and report read
## the same values. order_section == "" means no order is open.
var order_section := ""
var order_needed := 0
var order_stocked := 0
var order_time_left := 0.0
var orders_called_today := 0
var orders_filled_today := 0
## Sales that earned the multiplier. Pay is derived from these the same way
## it is from write-ups (_pay_today()/_pay_week()), not stored as money.
var priority_sales_today := 0
var priority_sales_week := 0
## Host-only bookkeeping. HOW AN ITEM IS TIED TO AN ORDER: the moment an item
## settles into a slot in the ordered section during the window (Shelf.gd ->
## note_item_stocked()), the product node gets a "priority_order" meta set to
## that order's id. The tag is on the item itself, so it doesn't matter
## where the item goes or how long it sits after that; it's read once, at
## checkout (Cashier.gd -> note_sale()). Ids are unique for the whole session
## and never reused, so a tag can't be mistaken for a later order's. A tagged
## item that sells BEFORE its order fills is parked in
## _pending_order_sales and credited only if the order goes on to fill.
var _order_id := 0 # the open order's id, 0 = none
var _next_order_id := 1
var _order_timer := 0.0
var _filled_order_ids := {}
var _pending_order_sales := {} # order id -> tagged items already sold
## Local-only UI for the manager tell/toast (_build_alert_layer()).
var _watch_label: Label
var _toast_label: Label
var _toast_timer := 0.0
var _order_label: Label
var _finale_banner: VBoxContainer
## Host-written, replicated (DaySync): seconds the FINAL SHIFT banner has
## left. State, not a one-shot RPC, so a player whose connection lands a
## moment after the shift starts still sees it (found by the co-op pass).
var finale_banner_left := 0.0
var _order_result_text := ""
var _order_result_timer := 0.0
var _order_result_filled := false
var report_order_label: Label
var report_cleanup_label: Label

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
## OCT 2026 PHASE 3B — SHOPPING LISTS. ITEMS_TARGET_BY_TIER above is no longer
## read: a shopper now walks in with a LIST (Customer.gd's shopping_list),
## drawn by make_shopping_list() below from the sections that are open AND
## have stock on their shelves at that moment. Its length is a random
## [min, max] per tier — FLAGGED, tunable (Phase 5). Centred on the old fixed
## targets (1, 2, 2, 3) so the change measures where customers shop, not a
## jump in how much each one buys.
const SHOPPING_LIST_BY_TIER := [[1, 2], [2, 3], [2, 3], [2, 4]]
## The most times one section can appear on a list (and never more than its
## shelves hold right then) — keeps a list spread across sections.
const SHOPPING_LIST_MAX_PER_SECTION := 2
## WEEK 10 — Day 5+ density, same tier shape as the arrays above (Day 5-6 =
## tier 2, when Dairy/Frozen opens). Both FLAGGED placeholders, tuned against
## the solo sim in tools/hazards_test.gd, not a human playtest:
## - STACK_ROWS_BY_TIER: shelves stock two deep from Day 5 (Shelf.gd's
##   set_stack_rows() — the second row of the existing slot system, the
##   "taller/heavier stacks"). Days 1-4 unchanged at one row.
## - PRODUCT_DENSITY_BY_TIER: multiplies the per-section product cap
##   (_product_baseline()). 1.0 is the old "one product per row-1 slot"
##   ratio; Day 5's 1.5 puts more stock on the floor — more to haul, and
##   more loose clutter in the forklift's aisle — while staying under the
##   now-doubled slot count so a solo crew can't simply run out of shelf.
const STACK_ROWS_BY_TIER := [1, 1, 2, 2]
const PRODUCT_DENSITY_BY_TIER := [1.0, 1.0, 1.5, 1.5]
## WEEK 16 — how much of the old floor cap is already out when the day opens
## (_spawn_opening_stock()). 0: the store opens empty and every unit of stock
## arrives by truck during the prep phase — the point of prep is the delivery
## run. FLAGGED: raise it to hand a team some floor stock to shelve while the
## first truck backs in.
const OPENING_STOCK_FRACTION := 0.0
## Live value (tests from before Week 16 set it to 1.0: they were written
## against a day that opens with a stocked floor).
var opening_stock_fraction := OPENING_STOCK_FRACTION
const CUSTOMER_PER_EXTRA_PLAYER := 2
## Week 6: restored to 0.35 now that the spacebar defend/shove action
## (Player.gd's _try_defend(), Customer.gd's request_shove()) gives players
## an actual counter-play — disruptive customers are no longer pure
## unanswerable chaos. Still a placeholder value, like the rest of this
## block: it's an educated guess for Day 1, not a playtested number.
const CUSTOMER_DISRUPTIVE_RATIO := 0.35
## WEEK 16: the SELLING window (store open) — what Days 1-6 always had after
## the old 9s grace (120 - 9 = 111s; the per-section and Day 5 bonuses went
## on grace and clock alike, so they never changed it). --shift-seconds=
## overrides it. The day's total clock is the prep ceiling plus this.
const SHIFT_DURATION_DEFAULT := 111.0
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
## WEEK 16 — THE PREP PHASE (replaces the Week 7 per-section grace bonus,
## the Week 11 Day 5+ flat bonus and the old 9s grace, all three). Each shift
## opens with the store CLOSED: no customers, but trucks already rolling, so
## the crew unpacks and stocks at its own pace. It ends when anyone flips the
## Store sign at the entrance (open_store(), host-authoritative) or when the
## PREP CEILING runs out (automatic — nobody can get stuck waiting). The
## ceiling is PREP_CEILING_BASE plus PREP_CEILING_PER_SECTION for each section
## open beyond Dry Goods (Day 1-2: 3 min, 3-4: 6, 5-6: 9, 7: 12). FLAGGED
## reading of the spec's "per newly-opened section": counted cumulatively
## (every section opened after Day 1), which is what gives 12 minutes on
## Day 7.
## The day's TOTAL clock is fixed: ceiling + that day's selling window
## (_selling_window(): 111s, 96s on the finale — exactly what each day sold
## for before). Opening early doesn't shorten the day; every second of
## ceiling left over becomes selling time. Using the whole ceiling gets
## exactly the old selling window.
const PREP_CEILING_BASE := 180.0
const PREP_CEILING_PER_SECTION := 180.0

## WEEK 19 — the cleanup ceiling: how long the closed store waits for someone
## to clock out before it clocks everyone out itself. Doesn't scale with the
## day tier the way prep does — it's sized to the mess actually on the floor
## at close (Cleanup.gd's mess_count(): spills/knockovers + litter), so a
## tidy Day 2 isn't a long wait and a wrecked Day 7 has room to be put right.
## At roughly one mess item per 4s of one player's work (walk + scrub), the
## ceiling covers about everything for one player; a crew has slack.
## WEEK 20: 40 -> 50. The tool station moved from the hub's corner to the
## break room (by the time clock), so a trip to it from the sales floor is
## ~3s longer each way (hub center: ~460px -> ~1070px): +10s pays for one
## round trip (a tool swap mid-clean). The bot sim's broom swap ran the old
## ceiling out on the walk to the clock. Flagged placeholder like the rest.
const CLEANUP_CEILING_BASE := 50.0
const CLEANUP_CEILING_PER_MESS := 4.0
const CLEANUP_CEILING_MIN := 60.0
const CLEANUP_CEILING_MAX := 180.0
## --cleanup-seconds=N replaces the formula; 0 clocks out the moment the store
## closes (the tests written before cleanup existed use it).
var cleanup_ceiling_override := -1.0

func _cleanup_ceiling() -> float:
	if cleanup_ceiling_override >= 0.0:
		return cleanup_ceiling_override
	return clampf(CLEANUP_CEILING_BASE + CLEANUP_CEILING_PER_MESS * cleanup.mess_count(), CLEANUP_CEILING_MIN, CLEANUP_CEILING_MAX)

## --prep-seconds=N replaces the formula (a quick playtest of the selling
## window, and the tests written before the prep phase existed, use 0).
var prep_ceiling_override := -1.0

func _prep_ceiling() -> float:
	if prep_ceiling_override >= 0.0:
		return prep_ceiling_override
	return prep_ceiling_for(_unlocked_sections().size())

## WEEK 21: by section count, so the shift board can preview a posting's clock.
func prep_ceiling_for(open_sections: int) -> float:
	if prep_ceiling_override >= 0.0:
		return prep_ceiling_override
	return PREP_CEILING_BASE + PREP_CEILING_PER_SECTION * maxi(0, open_sections - 1)

## WEEK 21: the finale's cut now comes from hazard_levels()'s tight_clock —
## Day 7 in the story, a 4-5 star posting in endless mode.
func _selling_window() -> float:
	return shift_duration - (FINALE_SELLING_CUT if hazard_levels()["tight_clock"] else 0.0)

## The day's whole clock: prep ceiling + selling window. Loaded into
## shift_time_left at the start of every shift; nothing extends it.
func _current_shift_duration() -> float:
	return _prep_ceiling() + _selling_window()

## The display name of the section a point is in ("" outside the sections).
func _section_name_at(world_pos: Vector2) -> String:
	var cell := _grid_cell_of(world_pos)
	for section in SECTIONS:
		if section["grid_pos"] == cell:
			return section["name"]
	return ""

## WEEK 12 — true on the finale day. WEEK 21: the STORY's Day 7 only —
## endless shifts get finale numbers per system, through hazard_levels().
## OCT 2026 PHASE 2: the top complication tier (stage 5), every shift once
## reached — no longer one day.
func is_finale() -> bool:
	return complication_stage >= STAGE_RUSH and not is_endless()

## WEEK 21 — an Endless Mode shift (see Endless.gd's header). Phase 2: a flag
## (only the debug --endless route sets it), since current_day now counts on
## past 7 in the normal game.
func is_endless() -> bool:
	return endless_active

## WEEK 21 — THE one place a system asks "is this hazard on today, and how
## hard?" Levels: 0 off, 1 the normal numbers, 2 the old Day 7 finale numbers
## (each system's own `finale` flag). OCT 2026 PHASE 2: the shopkeeper game
## reads complication_stage (forklift 1 — and only with Produce open, it
## lives there —, manager 2, orders 3, spills + lights 4, everything at 2 +
## the tight clock at 5); endless mode reads the taken posting. Every peer
## (both inputs are replicated).
func hazard_levels() -> Dictionary:
	var produce_open := is_unlocked_at_pos(forklift.home_position)
	if is_endless():
		var d := {"tight_clock": endless.tight_clock()}
		for k in EndlessScript.HAZARDS:
			d[k] = endless.level_of(k)
		if not produce_open:
			d["forklift"] = 0
		return d
	if tutorial.active:
		# The practice shift (Tutorial.gd) is Day 1 plus the manager, so the
		# crew meets his vision cone before it can cost them anything.
		return {"forklift": 0, "manager": 1, "orders": 0, "spills": 0, "lights": 0, "tight_clock": false}
	var st := complication_stage
	var hot := 2 if st >= STAGE_RUSH else 1
	return {
		"forklift": hot if produce_open and st >= STAGE_FORKLIFT else 0,
		"manager": hot if st >= STAGE_MANAGER else 0,
		"orders": hot if st >= STAGE_ORDERS else 0,
		"spills": hot if st >= STAGE_ENVIRONMENT else 0,
		"lights": hot if st >= STAGE_ENVIRONMENT else 0,
		"tight_clock": st >= STAGE_RUSH,
	}

## WEEK 21 — THE one place a section's open/locked state is decided.
## OCT 2026 PHASE 2: owned or not (bought in SECTIONS order, so "owned" is
## just the first sections_owned rows); endless reads the taken posting; the
## practice shift is Dry Goods only, whatever the crew owns.
func is_section_open(section: Dictionary) -> bool:
	if is_endless():
		return endless.section_open(section["name"])
	var i := section_index(section["name"])
	if tutorial.active:
		return i == 0
	return i >= 0 and i < sections_owned

func section_index(sec_name: String) -> int:
	for i in SECTIONS.size():
		if SECTIONS[i]["name"] == sec_name:
			return i
	return -1

## --- OCT 2026 PHASE 2: the shopkeeper economy -------------------------------

## The next section for sale ({} once everything's owned).
func next_section_for_sale() -> Dictionary:
	return SECTIONS[sections_owned] if sections_owned < SECTIONS.size() else {}

func section_price(sec_name: String) -> int:
	return int(SECTION_PRICES.get(sec_name, 0))

## Whether a stage's own needs are met right now (not whether it's on).
func stage_needs_met(stage: int) -> bool:
	if stage <= 0:
		return true
	if stage >= COMPLICATION_STAGES.size():
		return false
	var st: Dictionary = COMPLICATION_STAGES[stage]
	return sections_owned >= int(st["sections"]) and lifetime_earned >= int(st["earned"])

## Host-only, at every shift start (_start_shift()): at most ONE new stage,
## and only if its needs are met. Returns the stage that just began (0 = none).
func _advance_complication_stage() -> int:
	if is_endless() or tutorial.active:
		return 0
	var nxt := complication_stage + 1
	if nxt < COMPLICATION_STAGES.size() and stage_needs_met(nxt):
		complication_stage = nxt
		print("[Economy] Complication stage %d (%s) starts this shift — sections %d, lifetime earned $%d" % [nxt, COMPLICATION_STAGES[nxt]["key"], sections_owned, lifetime_earned])
		return nxt
	return 0

## Host-only, at clock-out: the shift's pay goes into the crew's bank. The one
## place money comes in — and, OCT 2026 PHASE 3, where the hired staff's wages
## (Staff.gd) come out. Wages are spending, like a section's price: they never
## lower lifetime_earned, so paying staff can't switch a hazard back off.
func _bank_shift_pay(pay: int, wages := 0) -> void:
	money += pay - wages
	lifetime_earned += maxi(0, pay)
	print("[Economy] Banked %s%s — bank %s, lifetime earned $%d" % [_format_money(pay), (", paid %s in wages" % _format_money(wages)) if wages != 0 else "", _format_money(money), lifetime_earned])

## What's next on the ladder, for the report and the Break Room: [headline,
## detail, imminent]. imminent = it starts next shift.
func next_complication_forecast() -> Array:
	var nxt := complication_stage + 1
	if is_endless() or nxt >= COMPLICATION_STAGES.size():
		return ["", "", false]
	var st: Dictionary = COMPLICATION_STAGES[nxt]
	var title := str(st["title"]).trim_prefix("NEW: ").to_lower()
	if stage_needs_met(nxt):
		return ["NEXT SHIFT: %s" % str(st["title"]).trim_prefix("NEW: "), str(st["line"]), true]
	var needs := []
	if sections_owned < int(st["sections"]):
		needs.append("when you %s" % st["ask"])
	if lifetime_earned < int(st["earned"]):
		needs.append("at $%d lifetime earnings ($%d to go)" % [int(st["earned"]), int(st["earned"]) - lifetime_earned])
	return ["Coming up: %s — %s" % [title, " and ".join(needs)], "", false]

## --- buying a section at its gate ---

## The gate body sealing a section (null if none).
func gate_of(sec_name: String) -> Node:
	var i := section_index(sec_name)
	if i < 0:
		return null
	return get_node_or_null("Gates/Gate%s" % SECTIONS[i]["node_name"])

## The unowned section whose gate `pos` is standing at ("" if none).
func for_sale_gate_at(pos: Vector2) -> String:
	if is_endless():
		return ""
	for i in range(sections_owned, SECTIONS.size()):
		var g := gate_of(SECTIONS[i]["name"])
		if g == null:
			continue
		var local: Vector2 = g.to_local(pos)
		if absf(local.x) <= GATE_BUY_RANGE and absf(local.y) <= ROOM_HEIGHT / 2.0:
			return SECTIONS[i]["name"]
	return ""

## Why `sec_name` can't be bought right now ("" = it can).
func purchase_blocker(sec_name: String) -> String:
	if is_endless():
		return "not in Endless Mode"
	if tutorial.active:
		return "practice shift — buy it in a real shift"
	var i := section_index(sec_name)
	if i < sections_owned:
		return "already yours"
	if i != sections_owned:
		return "buy %s first" % SECTIONS[sections_owned]["name"]
	if not shift_active or store_open or cleanup_active or _day_report_active:
		return "buy during prep, before you open"
	if money < section_price(sec_name):
		return "need %s more" % _format_money(section_price(sec_name) - money)
	return ""

## Any peer: the local player pressed E at a for-sale gate.
func try_buy_section(sec_name: String) -> void:
	if multiplayer.is_server():
		buy_section(sec_name, multiplayer.get_unique_id())
	else:
		_request_buy_section.rpc_id(1, sec_name)

@rpc("any_peer", "reliable")
func _request_buy_section(sec_name: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	# Where the HOST sees the sender — no buying from across the store.
	if players.has(sender) and for_sale_gate_at(players[sender].global_position) == sec_name:
		buy_section(sec_name, sender)
	else:
		purchases_refused += 1

## Host-only: the purchase. Two players pressing at once buy it once — the
## second request names a section that's already owned and is refused.
func buy_section(sec_name: String, by_peer: int) -> bool:
	if not multiplayer.is_server():
		return false
	var why := purchase_blocker(sec_name)
	if why != "":
		purchases_refused += 1
		print("[Economy] %s can't buy %s: %s" % [player_display_name(by_peer), sec_name, why])
		return false
	var price := section_price(sec_name)
	money -= price
	sections_owned += 1
	purchases_made += 1
	# The new aisle gets its stocking time, the way a day with one more
	# section always had a longer prep ceiling (prep_ceiling_for()).
	if prep_ceiling_override < 0.0:
		prep_time_left += PREP_CEILING_PER_SECTION
		shift_time_left += PREP_CEILING_PER_SECTION
	_reconfigure_world()
	print("[Economy] %s bought %s for $%d — bank %s, %d sections owned" % [player_display_name(by_peer), sec_name, price, _format_money(money), sections_owned])
	_announce_purchase.rpc(sec_name, by_peer, price, _purchase_brings(sec_name))
	save_progress("bought %s" % sec_name)
	return true

## Host: what the section just bought brings, for the purchase notice — the
## stage it unlocks starts NEXT shift only if it's the very next step on the
## ladder (one step per shift); otherwise it's on its way.
func _purchase_brings(sec_name: String) -> String:
	for i in range(complication_stage + 1, COMPLICATION_STAGES.size()):
		if COMPLICATION_STAGES[i]["ask"] == "buy %s" % sec_name:
			var what := str(COMPLICATION_STAGES[i]["title"]).trim_prefix("NEW: ").to_lower()
			if i == complication_stage + 1 and stage_needs_met(i):
				return "  ·  next shift: %s" % what
			return "  ·  it brings %s, in a shift or two" % what
	return ""

## Every peer: the purchase moment.
@rpc("authority", "call_local", "reliable")
func _announce_purchase(sec_name: String, by_peer: int, price: int, extra: String) -> void:
	var who := "You" if Net.is_active() and by_peer == multiplayer.get_unique_id() else player_display_name(by_peer)
	show_notice("%s IS OPEN" % sec_name.to_upper(), "%s bought it for $%d%s" % [who, price, extra], 5.0)
	Sfx.play("store_open")

## Every peer, local: a one-off notice on the big banner band.
func show_notice(big: String, small: String, seconds: float) -> void:
	_notice = [big, small, seconds]

## WEEK 17: stretched when today's window wouldn't close in time (a solo
## window can be longer than the finale's 32s cadence).
func _priority_order_interval() -> float:
	var base: float = FINALE_PRIORITY_ORDER_INTERVAL if hazard_levels()["orders"] >= 2 else PRIORITY_ORDER_INTERVAL
	return maxf(base, _priority_order_window() + PRIORITY_ORDER_MIN_GAP_AFTER_WINDOW)

## Test/sweep hook: >= 0 replaces the table.
var priority_order_window_override := -1.0

## WEEK 17 — see PRIORITY_ORDER_WINDOW_BY_PLAYERS.
func _priority_order_window() -> float:
	if priority_order_window_override >= 0.0:
		return priority_order_window_override
	var i := clampi(players.size() - 1, 0, PRIORITY_ORDER_WINDOW_BY_PLAYERS.size() - 1)
	return PRIORITY_ORDER_WINDOW_BY_PLAYERS[i]

## Screen-space draw order, bottom to top. PLAYTEST BUG FIX (debug HUD
## drawn behind the write-up toast and, from Day 5, the priority order
## banner): every CanvasLayer used to sit on the default layer 1, which
## leaves draw order to tree order, and AlertLayer is built in code in
## _ready(), after the scene's own layers, so it drew over everything. Set
## explicitly in _ready()/_build_alert_layer() instead: the in-game alert
## rows at the bottom, the debug HUD above them, and the modal end-of-day
## report above both (the relative order the scene's own layers already had
## is unchanged).
const UI_LAYER_ALERTS := 1
const UI_LAYER_MENU := 2
const UI_LAYER_DEBUG := 3
const UI_LAYER_REPORT := 4

@onready var menu_layer: CanvasLayer = $MenuLayer
@onready var host_button: Button = $MenuLayer/Menu/HostButton
@onready var join_button: Button = $MenuLayer/Menu/JoinButton
## PLAYTEST PREP: the host address Join connects to (e.g. a Radmin VPN IP).
## Left blank, its placeholder shows — and _join_address() falls back to —
## DEFAULT_JOIN_ADDRESS, so a same-PC join still needs no typing.
@onready var ip_input: LineEdit = $MenuLayer/Menu/IpInput
## The full per-frame dump (peer id, every carryable's position, shelf
## fill, hazard state) — dev-only, hidden by default, F3 toggles it on this
## peer only (see _unhandled_input). status_label is the small
## player-facing line that's always up instead (see _status_text()).
@onready var debug_label: Label = $DebugLayer/DebugLabel
@onready var status_label: Label = $DebugLayer/StatusLabel
## Screenshot/test tools set this false for HUD-free frames (status_label's
## visibility is re-derived every frame, so hiding it once wouldn't stick).
var status_hud := true
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
@onready var forklift: CharacterBody2D = $Forklift
@onready var manager: Node2D = $Manager
@onready var report_writeup_label: Label = $ReportLayer/Panel/WriteupLabel
@onready var report_pay_label: Label = $ReportLayer/Panel/PayLabel
## WEEK 11 — Day 6+ lights and spills (see Ambience.gd), created in _ready().
var ambience: Node2D
## WEEK 15 — Storage deliveries (Delivery.gd) and the delivery forklift
## (DeliveryForklift.gd), both built in _ready().
var delivery: Node2D
var delivery_forklift: CharacterBody2D
## WEEK 19 — end-of-shift cleanup (Cleanup.gd), built in _ready().
var cleanup: Node2D
## WEEK 21 — endless mode: the shift board, the shop, the wallet (Endless.gd),
## and its two screens (HubUI.gd), both built in _ready().
var endless: Node
var hub_ui: CanvasLayer
var sound_director: Node
var juice: Node2D
## Oct 2026 playtest fix — the guided practice shift before Day 1 (Tutorial.gd).
var tutorial: Node2D
## Host: Host Game was clicked in the menu (not a --server test launch) — the
## only way a brand-new crew is offered practice on its own (Tutorial.gd).
var _host_from_menu := false
var _practice_requested := false
## WEEK 23 — the dressed break room and its coffee machine (BreakRoom.gd).
var break_room: Node2D
## OCT 2026 PHASE 3 — the hired staff (Staff.gd).
var staff: Node2D

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
## Week 8 floor displays (Display.gd), found by group the same way.
var displays: Array[Node] = []
var players := {} # peer_id -> Player node (populated on every peer)
var bot_mode := false
var bot_run_seconds := 20.0
## Which port a --client instance actually connects to. Lets us point a
## client at a local latency-simulating proxy (see tools/udp_delay_proxy.py)
## instead of the real host port, without touching Net.gd's own PORT
## constant (which is still what --server always listens on).
var connect_port := Net.PORT
## What Join uses when the IP field is blank or obviously malformed.
const DEFAULT_JOIN_ADDRESS := "127.0.0.1"
## WEEK 21 test plumbing: --port=N moves a --server off Net.PORT, so several
## headless test runs can go at once (clients pass the same N as --connect-port=).
var host_port := Net.PORT
## Per-bot role, index-matched to spawn order, set via --bot-roles=. Empty
## means every bot defaults to "contest" — the original Week 1-3 tug-of-war
## behavior, unchanged. Week 4 adds "stocker" and "interferer".
var bot_roles: Array[String] = []
var shift_duration := SHIFT_DURATION_DEFAULT
var shift_active := false
var shift_time_left := 0.0
var _shelf_log_timer := 0.0
var _restock_timer := 0.0
## WEEK 16 — prep phase (see PREP_CEILING_BASE). Host-written, replicated
## (DaySync). prep_time_left counts the ceiling down while the store is
## closed; store_opened_by is who flipped the sign (0 = the ceiling did).
var store_open := false
var prep_time_left := 0.0
var store_opened_by := -1 # -1 = not opened yet today
var store_opened_at := 0.0 # shift_time_left when it opened
## WEEK 19 — the cleanup phase (see the WEEK 19 note). Host-written,
## replicated (DaySync). clocked_out_by: who clocked out (0 = the ceiling did,
## -1 = not yet today).
var cleanup_active := false
var cleanup_time_left := 0.0
var clocked_out_by := -1
var _product_spawn_index := 0
var _customer_spawn_index := 0
## Unique synthetic carry-id pool for customers — decremented (stays
## negative) so it can never collide with a real ENet peer id, which is
## always positive. See Carryable.gd's _find_carrier() for why customers
## need this instead of reusing multiplayer authority.
var _next_customer_carry_id := -1

## F3: the dev dump. Local only — nothing networked, every peer has its own.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		debug_label.visible = not debug_label.visible
		get_viewport().set_input_as_handled()

## The always-up corner line: which day/shift it is, and the crew size.
## players is populated on every peer (see _spawn_player_node), so a client's
## count matches the host's.
func _status_text() -> String:
	var crew := "%d player%s" % [players.size(), "" if players.size() == 1 else "s"]
	if is_endless():
		# In the hub between shifts shift_number is the LAST shift (#0 before
		# the first), so name the place instead.
		var where := "Break Room" if endless.screen == EndlessScript.SCREEN_HUB else "Shift #%d" % endless.shift_number
		return "Endless  ·  %s  ·  %d Bucks  ·  %s" % [where, endless.wallet, crew]
	if tutorial.active:
		return "Practice shift  ·  %s" % crew
	return "Day %d  ·  Bank %s  ·  %s" % [current_day, _format_money(money), crew]

func _ready() -> void:
	# Children's _ready() runs before their parent's in Godot, so every
	# Carryable component has already added its body to the "carryable"
	# group by the time this line runs.
	carryable_objects = get_tree().get_nodes_in_group("carryable")
	shelves = get_tree().get_nodes_in_group("shelf")
	cashiers = get_tree().get_nodes_in_group("cashier")
	displays = get_tree().get_nodes_in_group("display")
	# WEEK 13 — floor/wall art (StoreArt.gd), purely visual. First, so the
	# color cache below sees the new (white, textured) floors, and right
	# after the floors in draw order, under everything else.
	var store_art := StoreArtScript.new()
	store_art.name = "StoreArt"
	add_child(store_art)
	move_child(store_art, $RoomBackgrounds.get_index() + 1)
	# OCT 2026 PHASE 2 — FOUND WHILE BUILDING THE GATE PURCHASE: Gates sits
	# before RoomBackgrounds in Main.tscn, so since the Week 13 art pass gave
	# the floors opaque textures, every locked gate's red line and its sign
	# ("LOCKED — opens Day N", now "FOR SALE — $600") were drawn UNDER the
	# floor — invisible. The gate is the purchase point now, so it draws just
	# above the floors (draw order only; its collision is untouched).
	move_child($Gates, store_art.get_index() + 1)
	_apply_section_accent_colors()
	_cache_original_colors()
	# WEEK 15 — explicit names, identical on every peer (synchronizer paths).
	# The delivery forklift is Forklift.tscn with DeliveryForklift.gd swapped
	# in before it enters the tree; drawn with the room's other furniture,
	# before Players/Products so they draw over it like the Produce forklift.
	delivery = DeliveryScript.new()
	delivery.name = "Delivery"
	add_child(delivery)
	move_child(delivery, $Players.get_index())
	delivery_forklift = ForkliftScene.instantiate()
	delivery_forklift.set_script(DeliveryForkliftScript)
	delivery_forklift.name = "DeliveryForklift"
	delivery_forklift.position = DeliveryScript.FORKLIFT_HOME
	delivery_forklift.home_rotation = 0.0 # facing the dock
	add_child(delivery_forklift)
	move_child(delivery_forklift, $Players.get_index())
	# Explicit name, identical on every peer: its synchronizer's path has to
	# match across peers (see Player.gd's note on auto-generated names).
	ambience = AmbienceScript.new()
	ambience.name = "Ambience"
	add_child(ambience)
	# After Ambience, so its litter layer sits just above the spills' (both
	# go right after RoomBackgrounds; the later one lands first).
	cleanup = CleanupScript.new()
	cleanup.name = "Cleanup"
	add_child(cleanup)
	move_child(cleanup, $Players.get_index())
	endless = EndlessScript.new()
	endless.name = "Endless"
	add_child(endless)
	# WEEK 23 — break room furniture + the coffee machine. Explicit name (its
	# CoffeeSync's path must match on every peer); under Players in draw order.
	break_room = BreakRoomScript.new()
	break_room.name = "BreakRoomProps"
	add_child(break_room)
	move_child(break_room, $Players.get_index())
	# OCT 2026 PHASE 3 — hired helpers + the staff board (Staff.gd/Helper.gd).
	# Explicit name (StaffSync and each helper's Sync must match on every
	# peer); under Players in draw order, so carried stock draws over them.
	staff = StaffScript.new()
	staff.name = "Staff"
	add_child(staff)
	move_child(staff, $Players.get_index())
	# WEEK 22 — every sound driven by game state (see SoundDirector.gd/Sfx.gd).
	sound_director = SoundDirectorScript.new()
	sound_director.name = "SoundDirector"
	add_child(sound_director)
	# WEEK 27 — juice: local visual feedback on the same replicated events
	# (see Juice.gd). Cosmetic only; nothing reads it.
	juice = JuiceScript.new()
	juice.name = "Juice"
	add_child(juice)
	tutorial = TutorialScript.new()
	tutorial.name = "Tutorial" # explicit: its Sync's path must match on every peer
	add_child(tutorial)
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
	for prop in [".:current_day", ".:_day_report_active", ".:_sold_at_day_start", ".:shift_active", ".:shift_time_left", ".:writeups_today", ".:writeups_week", ".:writeups_by_peer", ".:order_section", ".:order_needed", ".:order_stocked", ".:order_time_left", ".:orders_called_today", ".:orders_filled_today", ".:priority_sales_today", ".:priority_sales_week", ".:finale_banner_left", ".:store_open", ".:prep_time_left", ".:store_opened_by", ".:store_opened_at", ".:cleanup_active", ".:cleanup_time_left", ".:clocked_out_by", ".:sold_carryover", ".:money", ".:lifetime_earned", ".:sections_owned", ".:complication_stage", ".:shelf_rows", ".:stage_banner", ".:endless_active"]:
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

	host_button.pressed.connect(func():
		_host_from_menu = true
		_on_host_pressed())
	join_button.pressed.connect(_on_join_pressed)
	# Practice Shift (Tutorial.gd): host, run practice, then carry on with
	# whatever the save says. Built here, not in Main.tscn (header note).
	var practice_button := Button.new()
	practice_button.name = "PracticeButton"
	practice_button.text = "Practice Shift"
	practice_button.tooltip_text = "A guided, no-pressure shift that walks you through the job. Then your real shift starts."
	practice_button.pressed.connect(func():
		_practice_requested = true
		_on_host_pressed())
	host_button.get_parent().add_child(practice_button)
	host_button.get_parent().move_child(practice_button, host_button.get_index() + 1)
	continue_button.pressed.connect(_on_continue_pressed)
	save_button.pressed.connect(_on_save_pressed)
	save_button.text = "Save"
	menu_layer.layer = UI_LAYER_MENU
	$DebugLayer.layer = UI_LAYER_DEBUG
	report_layer.layer = UI_LAYER_REPORT
	_build_alert_layer()
	_build_store_sign()
	_build_time_clock()
	_build_gate_hint()
	hub_ui = HubUIScript.new()
	hub_ui.name = "HubUI"
	hub_ui.endless = endless
	hub_ui.main = self
	hub_ui.layer = UI_LAYER_REPORT
	add_child(hub_ui)
	_build_report_extras()

	_parse_cli_args()

func _parse_cli_args() -> void:
	var args := OS.get_cmdline_user_args()
	bot_mode = "--bot" in args
	for arg in args:
		if arg.begins_with("--connect-port="):
			connect_port = int(arg.substr("--connect-port=".length()))
		elif arg.begins_with("--connect-ip="):
			# Fills the menu's IP field, so --client goes through the exact
			# same read as a typed-in address (see _join_address()).
			ip_input.text = arg.substr("--connect-ip=".length())
		elif arg.begins_with("--port="):
			host_port = int(arg.substr("--port=".length()))
		elif arg.begins_with("--duration="):
			bot_run_seconds = float(arg.substr("--duration=".length()))
		elif arg.begins_with("--shift-seconds="):
			shift_duration = float(arg.substr("--shift-seconds=".length()))
		elif arg.begins_with("--cleanup-seconds="):
			cleanup_ceiling_override = float(arg.substr("--cleanup-seconds=".length()))
		elif arg.begins_with("--prep-seconds="):
			prep_ceiling_override = float(arg.substr("--prep-seconds=".length()))
		elif arg.begins_with("--bot-roles="):
			bot_roles.assign(arg.substr("--bot-roles=".length()).split(","))
		elif arg.begins_with("--day="):
			debug_day = int(arg.substr("--day=".length()))
		elif arg.begins_with("--money="):
			debug_money = int(arg.substr("--money=".length()))
	# Only ever switches it ON: test harnesses set it before this runs.
	if "--endless" in args:
		legacy_endless_route = true
	# WEEK 24: debug starts leave the player's real save alone (see the
	# SAVE / LOAD note on completed_story_day).
	var custom_save := false
	var day_given := false
	for arg in args:
		if arg.begins_with("--save-file="):
			save_path = arg.substr("--save-file=".length())
			custom_save = true
		elif arg.begins_with("--day="):
			day_given = true
	if not custom_save and (bot_mode or day_given):
		save_enabled = false
	if day_given:
		_skip_load = true
	_day_given = day_given
	if "--no-save" in args:
		save_enabled = false
	if "--new-game" in args:
		_skip_load = true
	_practice_requested = _practice_requested or "--practice" in args
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
	# OCT 2026 PHASE 2: a gate is open once its section is owned (or, endless,
	# opened by the posting); a locked one shows what it costs.
	for gate_body in get_tree().get_nodes_in_group("gate"):
		var gate: Node = gate_body.get_node("Gate")
		var section := {}
		for s in SECTIONS:
			if "Gate" + s["node_name"] == gate_body.name:
				section = s
		if section.is_empty():
			continue
		gate.configure_open(is_section_open(section), _gate_closed_text(section["name"]))

## What a locked gate's sign says.
func _gate_closed_text(sec_name: String) -> String:
	if is_endless():
		return "CLOSED this shift"
	if tutorial.active:
		return "LOCKED"
	if section_index(sec_name) == sections_owned:
		return "FOR SALE — $%d" % section_price(sec_name)
	return "FOR SALE — $%d (after %s)" % [section_price(sec_name), SECTIONS[section_index(sec_name) - 1]["name"]]

## WEEK 8 — turns the forklift on/off for the current day. Called from the
## same two places as _configure_gates() (the day-change poll on every peer,
## and _advance_to_next_day() on the host). Active exactly when the
## section the forklift is parked in is unlocked — see Forklift.gd's DAY
## GATING note for why this reads SECTIONS instead of hardcoding Day 3.
## WEEK 10 — one or two stocked rows per shelf for today (STACK_ROWS_BY_TIER).
## Every peer, same call sites as _configure_gates(); runs before the host's
## _start_shift() reset, so a day never starts with half-built rows.
func _configure_shelf_stacks() -> void:
	# OCT 2026 PHASE 2: the host's shift-start snapshot (see shelf_rows).
	for shelf_body in shelves:
		shelf_body.get_node("Shelf").set_stack_rows(shelf_rows)

## Host: the stacking depth the sections open right now call for.
func _shelf_rows_for_open_sections() -> int:
	var tier := clampi(_unlocked_sections().size() - 1, 0, STACK_ROWS_BY_TIER.size() - 1)
	return STACK_ROWS_BY_TIER[tier]

func _configure_hazards() -> void:
	# WEEK 21: every hazard from hazard_levels() (story days and endless alike).
	var lv := hazard_levels()
	forklift.configure(lv["forklift"] > 0, lv["forklift"] >= 2)
	manager.configure(lv["manager"] > 0, lv["manager"] >= 2)
	ambience.configure_levels(lv["lights"], lv["spills"])
	# Storage is the crew's from the start: deliveries always run.
	delivery.configure(lv["tight_clock"])
	delivery_forklift.configure(true)

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
		var unlocked: bool = is_section_open(section)
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
	if not Net.host_game(host_port):
		return
	# WEEK 7: only the HOST's --day= (or the default of 1) decides the
	# real starting day now — a client's own --day=, if it even passed
	# one, is simply never consulted, since current_day reaches every
	# peer via replication (see _day_sync in _ready()). Applying it
	# (gates, lock visuals) isn't done here — the day-change check at the
	# top of _process() handles that uniformly for every peer, whether
	# it's the very first tick or a later day-advance.
	current_day = debug_day
	# OCT 2026 PHASE 2: a --day=N debug start begins at the economy old Day N
	# had (DEBUG_DAY_PRESETS); otherwise a fresh shop, unless the save says more.
	if _day_given:
		_apply_debug_day_preset(debug_day)
	# WEEK 24: the host's save decides where this crew picks up.
	var resume := _load_progress()
	if debug_money >= 0:
		money = debug_money
	shelf_rows = _shelf_rows_for_open_sections()
	_spawn_player(multiplayer.get_unique_id())
	if bot_mode:
		_start_bot_timer()
	# Oct 2026 playtest fix: a brand-new crew (Host Game from the menu, no
	# save file at all) gets the practice shift first; the menu's Practice
	# Shift button (or --practice) asks for it on any save.
	var fresh_crew: bool = _host_from_menu and save_enabled and not _skip_load and load_status == SaveGameScript.LOAD_NONE and resume == "story" and current_day == 1
	if _practice_requested or fresh_crew:
		tutorial.begin(resume)
	elif resume == "story":
		get_tree().create_timer(PRODUCT_SPAWN_DELAY).timeout.connect(_start_shift)
	else:
		_resume_past_story(resume)

## Host-only: --day=N -> old Day N's sections, stage and lifetime earnings.
func _apply_debug_day_preset(day: int) -> void:
	var p: Array = DEBUG_DAY_PRESETS[clampi(day, 0, DEBUG_DAY_PRESETS.size() - 1)]
	sections_owned = p[0]
	# One below: the first shift's real _advance_complication_stage() takes
	# it the last step, so a debug start announces its newest complication
	# exactly as a crew reaching it would see it (e.g. --day=7: RUSH SEASON).
	complication_stage = maxi(0, int(p[1]) - 1)
	lifetime_earned = p[2]
	money = STARTING_MONEY
	print("[Economy] --day=%d debug start: %d section(s), stage %d (-> %d at the first shift), lifetime earned $%d" % [day, sections_owned, complication_stage, p[1], lifetime_earned])

func _on_join_pressed() -> void:
	var address := _join_address()
	menu_layer.hide()
	if not Net.join_game(address, connect_port):
		# create_client refused outright (e.g. an unresolvable hostname) —
		# connection_failed will never fire, so bring the menu back here.
		print("[Main] Couldn't start joining %s — showing menu again." % address)
		menu_layer.show()

## The IP field's text, trimmed. Blank -> DEFAULT_JOIN_ADDRESS. Anything that
## is neither an IP nor a plain hostname (stray spaces, "ip:port", other
## punctuation) also falls back to it, with a log line saying so — no full
## validation, just enough that a typo can't hand ENet garbage.
func _join_address() -> String:
	var typed := ip_input.text.strip_edges()
	if typed.is_empty():
		return DEFAULT_JOIN_ADDRESS
	if typed.is_valid_ip_address():
		return typed
	for c in typed:
		if not (c == "." or c == "-" or (c >= "0" and c <= "9") \
				or (c.to_lower() >= "a" and c.to_lower() <= "z")):
			print("[Main] Join address '%s' doesn't look like an IP — using %s." % [typed, DEFAULT_JOIN_ADDRESS])
			return DEFAULT_JOIN_ADDRESS
	return typed

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
	if multiplayer.is_server():
		cleanup.drop_tools_of(id)
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
	# WEEK 25 — staff look by player slot (player_1..4), same on every peer.
	player_spawner.spawn({"id": id, "pos": spawn_pos, "angle": angle, "target": target_name, "role": role, "look": index % 4 + 1})

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
	p.look_index = data.get("look", 1)
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
## Customers are NOT restocked here — WEEK 16: the day opens in the prep
## phase (store closed, see PREP_CEILING_BASE); _process()'s periodic check
## starts them once open_store() runs. (Week 16 also removed the product
## top-up: stock only comes from unpacked delivery boxes.)
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
	# OCT 2026 PHASE 2: complications move only here — at most one new stage
	# per shift — and the shelves take the stacking depth for what's open now.
	var new_stage := _advance_complication_stage()
	shelf_rows = _shelf_rows_for_open_sections()
	_reconfigure_world()
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
	# WEEK 8: every shelf's wrecked state was cleared by the reset above;
	# the forklift and displays go back to their starting spots too, so no
	# day inherits yesterday's wreckage (same reasoning as the shelf reset).
	forklift.reset_for_new_day()
	delivery_forklift.reset_for_new_day()
	manager.reset_for_new_day()
	ambience.reset_for_new_day()
	delivery.reset_for_new_day()
	cleanup.reset_for_new_day()
	cleanup_active = false
	cleanup_time_left = 0.0
	clocked_out_by = -1
	writeups_today = 0
	writeups_by_peer = {}
	break_room.reset_for_new_shift() # WEEK 23: a fresh pot, nobody's had a cup
	staff.reset_for_new_shift() # OCT 2026 PHASE 3: who's on the books, empty back rooms
	sold_by_section_today = {}
	_clear_priority_order()
	orders_called_today = 0
	orders_filled_today = 0
	priority_sales_today = 0
	_order_timer = _priority_order_interval()
	for display_body in displays:
		display_body.get_node("Display").reset_to_home()
	var duration := _current_shift_duration()
	# WEEK 16: the store opens CLOSED — prep until the sign is flipped or the
	# ceiling runs out (see PREP_CEILING_BASE).
	store_open = false
	store_opened_by = -1
	store_open_events_today = 0
	clock_out_events_today = 0
	prep_time_left = _prep_ceiling()
	_restock_timer = 0.0
	_reset_players_to_break_room()
	print("[Main] Day %d shift starting — %d player(s), %.0fs on the clock: up to %.0fs of prep (store closed), %.0fs selling at the least" % [current_day, players.size(), duration, prep_time_left, _selling_window()])
	_spawn_opening_stock()
	shift_time_left = duration
	# OCT 2026 PHASE 2: the banner announces a NEW complication stage, once,
	# as its first shift starts (the old one-time FINAL SHIFT banner went with
	# Day 7). WEEK 21: and every endless shift — the same banner, naming the
	# posting.
	stage_banner = new_stage
	if new_stage > 0:
		finale_banner_left = STAGE_BANNER_SECONDS
	elif is_endless():
		finale_banner_left = FINALE_BANNER_SECONDS
	else:
		finale_banner_left = 0.0 # nothing left over from a short last shift

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

## --- WEEK 16: the Store sign ------------------------------------------------
## At the entrance (Sidewalk side of the hub boundary, beside where customers
## walk in). Any player standing within STORE_SIGN_RANGE with empty hands
## presses E at it to flip it to OPEN (Player.gd's _try_interact()). Same
## "any peer may ask, only the host decides" shape as every other shared
## change here: a client's press is a request RPC; the host opens the store
## only if it's still closed, so two players flipping it in the same instant
## open it exactly once (the second request finds it already open and does
## nothing). store_open/store_opened_by reach every peer through DaySync.
const STORE_SIGN_POS := Vector2(1610.0, 1115.0)
const STORE_SIGN_RANGE := 70.0
## Host diagnostic: times open_store() actually opened the store today (must
## only ever be 0 or 1 — the sign race test checks it).
var store_open_events_today := 0
## Test hook (WEEK 17): store open, hazards running, but no new customers —
## what the tests written before the prep phase meant by "hold the grace".
var test_hold_customers := false
## Test hook (OCT 2026 PHASE 2): see _advance_to_next_day().
var test_follow_old_calendar := false

func near_store_sign(pos: Vector2) -> bool:
	return pos.distance_to(STORE_SIGN_POS) <= STORE_SIGN_RANGE

## Any peer: the local player pressed E at the sign.
func try_flip_sign() -> void:
	if multiplayer.is_server():
		open_store(multiplayer.get_unique_id())
	else:
		rpc_id(1, "_request_open_store")

@rpc("any_peer", "reliable")
func _request_open_store() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	# Where the HOST sees the sender's player — a client can't open the store
	# from across the map by sending the RPC.
	if players.has(sender) and near_store_sign(players[sender].global_position):
		open_store(sender)

## Every peer: the one-off "STORE OPEN" line (the state itself is DaySync's).
@rpc("authority", "call_local", "reliable")
func _announce_store_open(by_peer: int) -> void:
	_open_banner_text = "STORE OPEN — %s" % ("customers are coming!" if by_peer == 0 else "%s flipped the sign" % ("you" if Net.is_active() and by_peer == multiplayer.get_unique_id() else player_display_name(by_peer)))
	_open_banner_t = 3.5
	Sfx.play("store_open")

## The sign itself: the supermarket pack's price-sign-on-a-post (1.png), with
## its board painted over by a CLOSED/OPEN panel. Every peer, built in _ready()
## like the rest of the in-code visuals; redrawn from store_open each frame.
const SIGN_SHEET := "res://assets/supermarket/1.png"
const SIGN_REGION := Rect2i(580, 140, 41, 60)
var _sign_board: Polygon2D
var _sign_text: Label
var _sign_hint: Label
var _prep_label: Label
var _open_banner_text := ""
var _open_banner_t := 0.0

func _build_store_sign() -> void:
	var sign := Node2D.new()
	sign.name = "StoreSign"
	sign.position = STORE_SIGN_POS
	add_child(sign)
	move_child(sign, $Players.get_index())
	var post := Sprite2D.new()
	post.texture = load(SIGN_SHEET)
	post.region_enabled = true
	post.region_rect = Rect2(SIGN_REGION)
	post.scale = Vector2(2.0, 2.0)
	sign.add_child(post)
	_sign_board = Polygon2D.new()
	_sign_board.polygon = PackedVector2Array([Vector2(-38, -58), Vector2(38, -58), Vector2(38, -12), Vector2(-38, -12)])
	sign.add_child(_sign_board)
	_sign_text = Label.new()
	_sign_text.position = Vector2(-38, -57)
	_sign_text.size = Vector2(76, 44)
	_sign_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sign_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_sign_text.add_theme_font_size_override("font_size", 17)
	_sign_text.add_theme_color_override("font_color", Color(1, 1, 1))
	sign.add_child(_sign_text)
	_sign_hint = Label.new()
	_sign_hint.text = "E: open the store"
	_sign_hint.position = Vector2(-80, -86)
	_sign_hint.size = Vector2(160, 24)
	_sign_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sign_hint.add_theme_font_size_override("font_size", 15)
	_sign_hint.add_theme_color_override("font_color", Color(1, 0.9, 0.3))
	_sign_hint.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_sign_hint.add_theme_constant_override("shadow_offset_x", 1)
	_sign_hint.add_theme_constant_override("shadow_offset_y", 1)
	sign.add_child(_sign_hint)

## Every peer, every frame: the sign's face, its E hint (only for my own
## player standing at it), the prep countdown banner, the STORE OPEN line.
func _update_store_sign(delta: float) -> void:
	var closed := shift_active and (not store_open or cleanup_active)
	_sign_board.color = Color(0.75, 0.12, 0.1) if closed else Color(0.1, 0.55, 0.2)
	_sign_text.text = "CLOSED" if closed else "OPEN"
	var me := multiplayer.get_unique_id() if Net.is_active() else 0
	_sign_hint.visible = closed and not cleanup_active and players.has(me) and near_store_sign(players[me].global_position)
	_open_banner_t = maxf(0.0, _open_banner_t - delta)
	_update_time_clock(me)
	_update_gate_hint(me)
	if cleanup_active and not _day_report_active:
		_prep_label.visible = true
		_prep_label.add_theme_color_override("font_color", Color(0.55, 0.9, 1))
		_prep_label.text = "CLEANUP — mop & sweep, then clock out in the break room (auto %d:%02d)  ·  Spills %d/%d  ·  Litter %d/%d" % [int(cleanup_time_left) / 60, int(cleanup_time_left) % 60, cleanup.mop_total - cleanup.mop_left, cleanup.mop_total, cleanup.litter_total - cleanup.litter_left, cleanup.litter_total]
	elif closed and not _day_report_active and tutorial.active:
		_prep_label.visible = true
		_prep_label.add_theme_color_override("font_color", Color(1, 0.85, 0.3))
		_prep_label.text = "PRACTICE SHIFT — no clock, no customers, no pay. Flip the sign at the entrance to start Day 1."
	elif closed and not _day_report_active:
		_prep_label.visible = true
		_prep_label.add_theme_color_override("font_color", Color(1, 0.85, 0.3))
		_prep_label.text = "PREP — store closed. Opens by itself in %d:%02d. Flip the sign at the entrance to open early." % [int(prep_time_left) / 60, int(prep_time_left) % 60]
	elif _open_banner_t > 0.0 and not _day_report_active:
		_prep_label.visible = true
		_prep_label.add_theme_color_override("font_color", Color(0.45, 1, 0.45))
		_prep_label.text = _open_banner_text
	else:
		_prep_label.visible = false

## Host-only. by_peer = who flipped the sign; 0 = the prep ceiling ran out.
## Ends prep: customers start arriving on the next restock tick, priority
## orders start counting. The shift clock doesn't change — the rest of it is
## the selling window.
func open_store(by_peer: int) -> void:
	if not multiplayer.is_server() or store_open or not shift_active or _day_report_active:
		return
	# Flipping the sign ends the practice shift and starts the real one.
	if tutorial.active:
		tutorial.finish("sign flipped by %s" % player_display_name(by_peer))
		return
	store_open = true
	store_opened_by = by_peer
	store_opened_at = shift_time_left
	store_open_events_today += 1
	_restock_timer = 0.0 # first customers right away, not up to 3s later
	_announce_store_open.rpc(by_peer)
	_order_timer = PRIORITY_ORDER_FIRST_AFTER_OPEN
	print("[Main] Store OPEN on Day %d — %s, %.0fs of prep left unused, %.0fs to sell" % [current_day, "sign flipped by %s" % player_display_name(by_peer) if by_peer != 0 else "prep ceiling ran out", prep_time_left, shift_time_left])
	prep_time_left = 0.0

## --- WEEK 19: the cleanup phase and the time clock ----------------------------

## Host-only: the day's clock ran out. Closes the store and starts cleanup.
func start_cleanup() -> void:
	if not multiplayer.is_server() or not shift_active or cleanup_active or _day_report_active:
		return
	cleanup_active = true
	_despawn_all_customers()
	# An order still open lapses (no bonus, no penalty), as it did at the
	# old end of shift.
	_clear_priority_order()
	ambience.end_shift() # lights back on; spills stop drying (no more ticks)
	# The Produce forklift parks at home; the manager clocks off.
	forklift.reset_for_new_day()
	manager.watch_peer = 0
	manager.watch_level = 0.0
	cleanup.begin_cleanup()
	cleanup_time_left = _cleanup_ceiling()
	print("[Main] Store CLOSED on Day %d — cleanup: %.0fs ceiling, %d mess on the floor" % [current_day, cleanup_time_left, cleanup.mess_count()])
	if cleanup_time_left <= 0.0:
		clock_out(0)

## Host-only. by_peer = who clocked out; 0 = the cleanup ceiling ran out.
## Scores the cleanup (its bonus goes into Pay Today) and raises the report.
func clock_out(by_peer: int) -> void:
	if not multiplayer.is_server() or not cleanup_active or _day_report_active:
		return
	clocked_out_by = by_peer
	cleanup.finish_cleanup(_gross_pay_today())
	cleanup_active = false
	cleanup_time_left = 0.0
	clock_out_events_today += 1
	print("[Main] Clocked out on Day %d — %s" % [current_day, "by %s" % player_display_name(by_peer) if by_peer != 0 else "cleanup ceiling ran out"])
	_end_shift()

## Host diagnostic, like store_open_events_today: must only ever be 0 or 1.
var clock_out_events_today := 0

## At the break room's time clock — the supermarket pack's card kiosk.
const TIME_CLOCK_POS := Vector2(880.0, 300.0)
const TIME_CLOCK_RANGE := 70.0
const TIME_CLOCK_REGION := Rect2i(240, 685, 44, 80)
var _clock_hint: Label

func near_time_clock(pos: Vector2) -> bool:
	return pos.distance_to(TIME_CLOCK_POS) <= TIME_CLOCK_RANGE

## Any peer: the local player pressed E at the time clock.
func try_clock_out() -> void:
	if multiplayer.is_server():
		clock_out(multiplayer.get_unique_id())
	else:
		rpc_id(1, "_request_clock_out")

@rpc("any_peer", "reliable")
func _request_clock_out() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	# Where the HOST sees the sender — no clocking out from across the store.
	if players.has(sender) and near_time_clock(players[sender].global_position):
		clock_out(sender)

func _build_time_clock() -> void:
	var node := Node2D.new()
	node.name = "TimeClock"
	node.position = TIME_CLOCK_POS
	add_child(node)
	move_child(node, $Players.get_index())
	var kiosk := Sprite2D.new()
	kiosk.texture = load(SIGN_SHEET)
	kiosk.region_enabled = true
	kiosk.region_rect = Rect2(TIME_CLOCK_REGION)
	kiosk.scale = Vector2(0.8, 0.8)
	kiosk.position = Vector2(0, -20)
	node.add_child(kiosk)
	var label := Label.new()
	label.text = "TIME CLOCK"
	label.position = Vector2(-50, 16)
	label.size = Vector2(100, 16)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", Color(0.2, 0.2, 0.2))
	node.add_child(label)
	_clock_hint = Label.new()
	_clock_hint.text = "E: clock out"
	_clock_hint.position = Vector2(-80, -76)
	_clock_hint.size = Vector2(160, 24)
	_clock_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_clock_hint.add_theme_font_size_override("font_size", 15)
	_clock_hint.add_theme_color_override("font_color", Color(0.55, 0.9, 1))
	_clock_hint.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_clock_hint.add_theme_constant_override("shadow_offset_x", 1)
	_clock_hint.add_theme_constant_override("shadow_offset_y", 1)
	_clock_hint.visible = false
	node.add_child(_clock_hint)

## OCT 2026 PHASE 2 — the purchase prompt: one world-space line that sits on
## the for-sale gate my own player is standing at, at their height. Same look
## as the sign's and the time clock's E hints. Every peer, local only.
var _gate_hint: Label

func _build_gate_hint() -> void:
	_gate_hint = Label.new()
	_gate_hint.name = "GateHint"
	_gate_hint.size = Vector2(360, 48)
	_gate_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gate_hint.add_theme_font_size_override("font_size", 15)
	_gate_hint.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_gate_hint.add_theme_constant_override("shadow_offset_x", 1)
	_gate_hint.add_theme_constant_override("shadow_offset_y", 1)
	_gate_hint.z_index = 120 # over the lights' darkness, like the other prompts
	_gate_hint.visible = false
	add_child(_gate_hint)

## [section, text, can_buy] for a player at pos ("" section = no prompt).
func gate_hint_for(pos: Vector2) -> Array:
	var sec := for_sale_gate_at(pos)
	if sec == "" or not shift_active or _day_report_active:
		return ["", "", false]
	var why := purchase_blocker(sec)
	if why == "":
		return [sec, "E: buy %s — $%d\n(bank %s)" % [sec, section_price(sec), _format_money(money)], true]
	return [sec, "%s — $%d\n%s" % [sec, section_price(sec), why], false]

func _update_gate_hint(me: int) -> void:
	var h := ["", "", false]
	# is_instance_valid: a client's player can already be freed (the host
	# left) while it's still in `players` for a frame.
	if players.has(me) and is_instance_valid(players[me]):
		h = gate_hint_for(players[me].global_position)
	_gate_hint.visible = h[0] != ""
	if not _gate_hint.visible:
		return
	var g := gate_of(h[0])
	var p: Vector2 = players[me].global_position
	_gate_hint.position = Vector2(g.global_position.x - _gate_hint.size.x / 2.0, p.y - 80.0)
	_gate_hint.text = h[1]
	_gate_hint.add_theme_color_override("font_color", Color(1, 0.9, 0.3) if h[2] else Color(0.85, 0.85, 0.85))

func _update_time_clock(me: int) -> void:
	_clock_hint.visible = cleanup_active and not _day_report_active and players.has(me) and near_time_clock(players[me].global_position)

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
	# An order still open when the clock runs out simply lapses (no bonus,
	# no penalty) — nothing it tagged can sell from here anyway.
	_clear_priority_order()
	ambience.end_shift()
	if is_endless():
		# WEEK 21: the shift's Pay is its score; Endless.gd turns sales,
		# orders filled and cleanliness into Bucks (and the medal).
		var clean: float = 0.5 * cleanup.mop_fraction() + 0.5 * cleanup.litter_fraction()
		endless.score_shift(_total_sold() - _sold_at_day_start, orders_filled_today, clean, writeups_today, _pay_today(), break_room.coffee_cups_today)
		print("[Main] Shift #%d complete!  Sold: %d  |  Write-ups: %d  |  Pay (score): %s" % [endless.shift_number, _total_sold() - _sold_at_day_start, writeups_today, _format_money(_pay_today())])
		save_progress("shift #%d paid out" % endless.shift_number)
	else:
		print("[Main] Day %d complete!  Sold today: %d  |  Lifetime sold: %d  |  Write-ups today: %d  |  Coffee: %d cup(s) -%s  |  Pay today: %s" % [current_day, _total_sold() - _sold_at_day_start, _total_sold(), writeups_today, break_room.coffee_cups_today, _format_money(break_room.dollars_today()), _format_money(_pay_today())])
		# OCT 2026 PHASE 2: the day's pay goes into the crew's bank.
		# PHASE 3: and the staff's wages come out of it, at the same moment.
		_bank_shift_pay(_pay_today(), staff.close_books())
		completed_story_day = maxi(completed_story_day, current_day)
		save_progress("Day %d complete" % current_day)

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

## WEEK 24: the report's Save button — an explicit save on top of the
## autosaves (every checkpoint already saved; this is the reassurance). The
## save is the host's, so a client's click asks the host, and the host tells
## that client how it went.
func _on_save_pressed() -> void:
	if multiplayer.is_server():
		_show_save_result(save_progress("Save button"), true)
	else:
		_rpc_request_save.rpc_id(1)

@rpc("any_peer", "reliable")
func _rpc_request_save() -> void:
	if not multiplayer.is_server():
		return
	var ok := save_progress("Save button (%s)" % player_display_name(multiplayer.get_remote_sender_id()))
	_rpc_save_result.rpc_id(multiplayer.get_remote_sender_id(), ok)

@rpc("authority", "reliable")
func _rpc_save_result(ok: bool) -> void:
	_show_save_result(ok, false)

var save_result_text := "" # what the button last said, for tests

func _show_save_result(ok: bool, on_host: bool) -> void:
	if ok:
		save_result_text = "Saved ✓" if on_host else "Saved on the host ✓"
	elif not save_enabled or not on_host:
		save_result_text = "Saving is off" if on_host else "Host didn't save"
	else:
		save_result_text = "Save FAILED"
	save_button.text = save_result_text
	get_tree().create_timer(2.5).timeout.connect(func(): save_button.text = "Save")

## Host-only: writes the save. Every checkpoint calls this; returns whether a
## file was actually written.
func save_progress(reason: String) -> bool:
	if not multiplayer.is_server() or not save_enabled:
		return false
	var ok := SaveGameScript.write(save_path, SaveGameScript.snapshot(self))
	if ok:
		saves_written += 1
	print("[Save] %s: %s — completed day %d, bank %s, lifetime earned $%d, %d section(s), stage %d%s" % ["saved" if ok else "SAVE FAILED", reason, completed_story_day, _format_money(money), lifetime_earned, sections_owned, complication_stage, (", endless wallet %d upgrades %s" % [endless.wallet, str(endless.upgrades)]) if story_complete else ""])
	return ok

## Host-only, once, as hosting begins: reads the save and puts its progress
## back. Returns where to pick up: "story" (start current_day's shift as
## usual), or — debug --endless route saves only — "week_complete" / "hub".
func _load_progress() -> String:
	if not save_enabled or _skip_load:
		return "story"
	var r: Array = SaveGameScript.read(save_path)
	load_status = r[0]
	if load_status == SaveGameScript.LOAD_NONE:
		print("[Save] No save at %s — a fresh start, Day 1" % save_path)
		return "story"
	if load_status == SaveGameScript.LOAD_CORRUPT:
		print("[Save] The save at %s couldn't be read — a fresh start, Day 1" % save_path)
		show_toast("Save file was damaged — starting a new game", TOAST_RED, 6.0)
		return "story"
	if load_status == SaveGameScript.LOAD_LEGACY:
		# OCT 2026 PHASE 2: no honest "Day 4 -> N sections and $X" mapping
		# exists, so an old story save isn't migrated: kept aside, a fresh
		# shop, and a message saying why — once: the fresh save written right
		# here replaces it, so the next launch just loads that.
		print("[Save] %s predates the shopkeeper update — starting a new game (old save kept at %s)" % [save_path, SaveGameScript.legacy_backup_path(save_path)])
		show_notice("NEW GAME", "This save predates the shopkeeper update — starting a new game.\n(Your old save is kept as %s)" % SaveGameScript.legacy_backup_path(save_path).get_file(), LEGACY_NOTICE_SECONDS)
		show_toast("Old save from before the shopkeeper update — starting fresh", Color(1, 0.85, 0.3), LEGACY_NOTICE_SECONDS)
		save_progress("fresh start (pre-shopkeeper save set aside)")
		return "story"
	var d: Dictionary = r[1]
	var shop: Dictionary = d["shop"]
	completed_story_day = shop["completed_day"]
	money = shop["money"]
	lifetime_earned = shop["lifetime_earned"]
	sections_owned = shop["sections_owned"]
	complication_stage = shop["stage"]
	sold_carryover = shop["lifetime_sold"]
	staff.staff = d["staff"] # OCT 2026 PHASE 3 (none in a version-2 save)
	var e: Dictionary = d["endless"]
	story_complete = e["unlocked"]
	endless.wallet = e["wallet"]
	endless.upgrades = e["upgrades"]
	endless.shift_number = e["shift_number"]
	endless.run_stats = e["run_stats"]
	endless.week_summary = e["week_summary"]
	var resume := "story"
	if story_complete:
		resume = "hub"
	elif legacy_endless_route and completed_story_day >= LEGACY_WEEK_DAYS:
		resume = "week_complete"
		current_day = LEGACY_WEEK_DAYS
	else:
		current_day = completed_story_day + 1
	print("[Save] Loaded %s — completed day %d, resuming: %s, bank %s, lifetime earned $%d, %d section(s), stage %d%s" % [save_path, completed_story_day, ("Day %d" % current_day) if resume == "story" else resume, _format_money(money), lifetime_earned, sections_owned, complication_stage, (", endless wallet %d" % endless.wallet) if story_complete else ""])
	show_toast(("Welcome back — Endless Mode, %d Bucks" % endless.wallet) if story_complete else ("Welcome back — Day %d  ·  Bank %s" % [current_day, _format_money(money)]), Color(0.55, 1, 0.6), 4.0)
	return resume

const LEGACY_NOTICE_SECONDS := 10.0

## Host-only, from _on_host_pressed(): a save past Day 7's report opens on
## the WEEK COMPLETE screen (not yet continued past — it pays its Bucks now,
## exactly once, as it would have) or the hub, over the same frozen, empty
## store those screens always sit over. Same functions the live game uses.
func _resume_past_story(resume: String) -> void:
	_day_report_active = true
	if resume == "week_complete":
		_finish_story()
	else:
		endless.screen = EndlessScript.SCREEN_WEEK_COMPLETE
		enter_hub()

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
	# WEEK 21: the Week Complete screen and the hub have their own buttons;
	# a stray Continue (a late RPC from the report) does nothing there.
	if endless.screen != EndlessScript.SCREEN_NONE:
		return
	if is_endless():
		# An endless shift's report -> back to the break room, fresh board.
		endless.roll_offers()
		endless.screen = EndlessScript.SCREEN_HUB
		print("[Main] Back to the break room after shift #%d" % endless.shift_number)
		save_progress("back to the break room")
		return
	# Debug --endless only: the old week still ends on Day 7, into Endless Mode.
	if legacy_endless_route and current_day >= LEGACY_WEEK_DAYS:
		_finish_story()
		return
	_day_report_active = false
	current_day += 1
	# Test plumbing: the tests written for the 7-day story roll Day N -> N+1
	# and expect old Day N+1's complications; this hands the crew what old
	# Day N+1 had (sections, lifetime earnings), and the shift start below
	# takes the one stage step every consecutive old day was. Never set in
	# play.
	if test_follow_old_calendar and not is_endless():
		var p: Array = DEBUG_DAY_PRESETS[clampi(current_day, 0, DEBUG_DAY_PRESETS.size() - 1)]
		sections_owned = maxi(sections_owned, p[0])
		lifetime_earned = maxi(lifetime_earned, p[2])
	_reconfigure_world()
	print("[Main] Starting Day %d..." % current_day)
	_start_shift()

## Every system that reads the day (or, WEEK 21, the taken posting), set up
## at once — the host does it the moment the day/shift changes; every peer
## also does it from _process()'s config-key poll.
func _reconfigure_world() -> void:
	if _customer_nav != null:
		_customer_nav.invalidate() # a gate may have opened (Phase 3B shopper paths)
	_configure_gates()
	_configure_cashiers()
	_configure_hazards()
	_configure_shelf_stacks()
	_apply_section_lock_visuals()
	_last_config_key = _config_key()

## WEEK 21 — what _process()'s reconfigure poll watches: the day, and in
## endless mode the taken posting (current_day stays put there). The two
## arrive on different synchronizers (DaySync unreliable, EndlessSync
## reliable), so a client may reconfigure twice around a change — the
## second time with both, which is always the right answer.
var _last_config_key := ""

func _config_key() -> String:
	return "%d:%d:%s:%d:%d:%d:%s" % [current_day, int(endless.contract.get("id", 0)), tutorial.active, sections_owned, complication_stage, shelf_rows, endless_active]

## --- WEEK 21: the end of the story, and endless mode's hub --------------------

## Host-only: Day 7's report -> the WEEK COMPLETE screen. The world stays
## frozen under it (_day_report_active stays true through both screens).
func _finish_story() -> void:
	endless.week_summary = {
		"sold": _total_sold(),
		"pay": _pay_week(),
		"writeups": writeups_week,
		"priority_sales": priority_sales_week,
		"clean_bonus": cleanup.clean_bonus_week,
	}
	endless.wallet += EndlessScript.WEEK_COMPLETE_BUCKS
	# The week is over: its running totals stop meaning anything. Endless
	# reports show the shift and the run (Endless.run_stats) instead.
	writeups_week = 0
	priority_sales_week = 0
	cleanup.clean_bonus_week = 0
	cleanup.litter_pay_week = 0
	break_room.reset_week()
	endless.screen = EndlessScript.SCREEN_WEEK_COMPLETE
	completed_story_day = LEGACY_WEEK_DAYS
	story_complete = true
	print("[Main] WEEK COMPLETE — story over. Week: %s. +%d Bucks." % [str(endless.week_summary), EndlessScript.WEEK_COMPLETE_BUCKS])
	save_progress("WEEK COMPLETE")

## Host-only (any peer asks via Endless.request_enter_hub()): WEEK COMPLETE ->
## the hub. current_day parks at ENDLESS_DAY from here on.
func enter_hub() -> void:
	if not multiplayer.is_server() or endless.screen != EndlessScript.SCREEN_WEEK_COMPLETE:
		return
	current_day = EndlessScript.ENDLESS_DAY
	endless_active = true
	endless.contract = {}
	_reconfigure_world()
	endless.roll_offers()
	endless.screen = EndlessScript.SCREEN_HUB
	print("[Main] Entered the break room hub — endless mode")
	save_progress("entered the hub")

## Host-only (any peer asks via Endless.request_take_offer()): take posting
## `index` off the board and start it. The medal targets are fixed now, for
## the crew that's here. Only from the hub, so two peers taking postings in
## the same instant start one shift (the first; the second finds no hub).
func take_offer(index: int) -> void:
	if not multiplayer.is_server() or endless.screen != EndlessScript.SCREEN_HUB or shift_active:
		return
	if index < 0 or index >= endless.offers.size():
		return
	var c: Dictionary = endless.offers[index].duplicate(true)
	c["targets"] = EndlessScript.targets_for(c, players.size())
	c["crew"] = players.size()
	endless.contract = c
	endless.shift_number += 1
	endless.offers_taken += 1
	endless.screen = EndlessScript.SCREEN_NONE
	_day_report_active = false
	_reconfigure_world()
	print("[Main] Taking posting %d: shift #%d \"%s\" %d* sections %s levels %s targets %s" % [index, endless.shift_number, c["name"], c["stars"], str(c["sections"]), str(c["levels"]), str(c["targets"])])
	_start_shift()

## --- WEEK 21: endless-mode lines on the end-of-shift report -------------------
var report_bucks_label: Label
var report_run_label: Label
var report_shop_label: Label
const MEDAL_COLORS := [Color(0.7, 0.7, 0.7), Color(0.9, 0.6, 0.35), Color(0.85, 0.9, 0.95), Color(1, 0.82, 0.25)]

## Two lines under Pay, built in code like the rest (see the .tscn note).
func _build_report_extras() -> void:
	# Grow both ways from the centre, so a longer endless report stays centred
	# and on screen instead of spilling off the right and bottom edges.
	var panel: Control = report_pay_label.get_parent()
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	report_bucks_label = Label.new()
	report_bucks_label.name = "BucksLabel"
	report_bucks_label.add_theme_font_size_override("font_size", 17)
	report_bucks_label.add_theme_color_override("font_color", Color(1, 0.82, 0.25))
	report_bucks_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	report_bucks_label.visible = false
	report_pay_label.add_sibling(report_bucks_label)
	report_run_label = Label.new()
	report_run_label.name = "RunLabel"
	report_run_label.add_theme_font_size_override("font_size", 15)
	report_run_label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	report_run_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	report_run_label.visible = false
	report_bucks_label.add_sibling(report_run_label)
	# OCT 2026 PHASE 2 — what's next: the complication forecast (the clear
	# signal before something harder shows up) and the next section for sale.
	report_shop_label = Label.new()
	report_shop_label.name = "ShopLabel"
	report_shop_label.add_theme_font_size_override("font_size", 16)
	report_shop_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	report_shop_label.visible = false
	report_run_label.add_sibling(report_shop_label)

## Every peer, while a shopkeeper report is up: the forecast + what's for sale.
func _fill_shop_forecast() -> void:
	var f := next_complication_forecast()
	var lines := []
	if f[0] != "":
		lines.append(f[0] + (("\n" + f[1]) if f[1] != "" else ""))
	var nxt := next_section_for_sale()
	if nxt.is_empty():
		lines.append("You own the whole store.")
	else:
		var price := section_price(nxt["name"])
		if money >= price:
			lines.append("You can afford %s ($%d) — buy it at its gate during prep." % [nxt["name"], price])
		else:
			lines.append("Next section: %s — $%d (%s to go)" % [nxt["name"], price, _format_money(price - money)])
	# OCT 2026 PHASE 3: an owned section nobody's staffing yet, that the bank
	# could hire for — the first one in line.
	for sec in staff.HELPER_SECTIONS:
		if section_index(sec) < sections_owned and not staff.is_hired(sec):
			if money >= int(staff.HIRE_FEE[sec]):
				lines.append("You can hire a %s helper ($%d, then $%d a shift) — the staff board, break room." % [sec, staff.HIRE_FEE[sec], staff.WAGE[sec]])
			break
	report_shop_label.text = "\n".join(lines)
	report_shop_label.add_theme_color_override("font_color", Color(1, 0.6, 0.25) if f[2] else Color(1, 0.85, 0.4))

## Every peer, while an endless shift's report is up: "Shift #N", the medal,
## the Bucks and why, and the RUN's totals where the story's "Week Total"
## was — the week ended with Day 7, so no line here claims to be a week.
func _fill_endless_report(today_sold: int) -> void:
	var c: Dictionary = endless.contract
	report_title_label.text = "Shift #%d Complete" % endless.shift_number
	report_today_label.text = "%s  %s   ·   sold %d" % [EndlessScript.stars_text(int(c.get("stars", 1))), c.get("name", ""), today_sold]
	report_pay_label.text = "Shift Pay: %s" % _format_money(_pay_today())
	var p: Dictionary = endless.last_payout
	if int(p.get("shift", -1)) != endless.shift_number:
		# The payout rides the reliable EndlessSync; the report flag rides
		# DaySync — a frame or two apart on a client.
		report_week_label.text = "Tallying the shift..."
		report_week_label.add_theme_color_override("font_color", Color(0.9, 0.95, 1))
		report_bucks_label.text = ""
	else:
		var medal: int = p["medal"]
		var t: Array = p["targets"]
		report_week_label.text = ("%s MEDAL" % EndlessScript.MEDAL_NAMES[medal] if medal > 0 else "No medal") + "  —  pay %s" % _format_money(int(p["score"]))
		report_week_label.add_theme_color_override("font_color", MEDAL_COLORS[medal])
		var per_head: String = "" if int(p.get("crew", 1)) <= 1 else "\n(sales, orders and write-ups count per head: crew of %d)" % int(p["crew"])
		var coffee: String = "" if int(p.get("coffee_cups", 0)) == 0 else "  − coffee %d (%d cup(s): %s)" % [-int(p["coffee"]), int(p["coffee_cups"]), break_room.drinkers_text()]
		report_bucks_label.text = "Medal targets: bronze $%d · silver $%d · gold $%d\n+%d Break Room Bucks   ·   wallet now %d\n= (sales %d + orders %d + clean %d − write-ups %d + medal %d) × %.2f for %d★%s%s" % [t[0], t[1], t[2], p["total"], endless.wallet, p["sales"], p["orders"], p["clean"], -int(p["writeups"]), p["medal_bucks"], p["mult"], int(c.get("stars", 1)), coffee, per_head]
	var rs: Dictionary = endless.run_stats
	var m: Array = rs.get("medals", [0, 0, 0, 0])
	report_run_label.text = "Endless run so far: %d shift(s) · %d sold · %d gold / %d silver / %d bronze · %d Bucks earned" % [int(rs.get("shifts", 0)), int(rs.get("sold", 0)), m[3], m[2], m[1], int(rs.get("bucks", 0))]
	continue_button.text = "Back to the Break Room"

## --- WEEK 9: manager write-ups and pay ------------------------------------

## Host-only, called by Manager.gd the moment a catch lands.
func record_writeup(peer_id: int, reason: String) -> void:
	if not multiplayer.is_server():
		return
	if tutorial.active:
		_announce_practice_writeup.rpc(peer_id, reason)
		return
	writeups_today += 1
	writeups_week += 1
	var by_peer := writeups_by_peer.duplicate()
	by_peer[peer_id] = by_peer.get(peer_id, 0) + 1
	writeups_by_peer = by_peer
	rpc("_announce_writeup", peer_id, reason)

## Every peer: the toast. The penalty itself is already in the replicated
## counters; this is just the moment-of-impact feedback.
@rpc("authority", "call_local", "reliable")
func _announce_writeup(peer_id: int, reason: String) -> void:
	if Net.is_active() and peer_id == multiplayer.get_unique_id():
		show_toast("WRITTEN UP for %s!  -$%d" % [reason, WRITEUP_PENALTY])
	else:
		show_toast("%s written up for %s  -$%d" % [player_display_name(peer_id), reason, WRITEUP_PENALTY])
	Sfx.play("writeup") # everyone hears it: it docks the whole crew's pay
	juice.writeup(peer_id, WRITEUP_PENALTY)

## Practice shift: what a write-up looks like, without the penalty.
@rpc("authority", "call_local", "reliable")
func _announce_practice_writeup(peer_id: int, reason: String) -> void:
	var who := "You'd be" if Net.is_active() and peer_id == multiplayer.get_unique_id() else "%s would be" % player_display_name(peer_id)
	show_toast("%s WRITTEN UP for %s (-$%d) — practice, so it's free" % [who, reason, WRITEUP_PENALTY])
	Sfx.play("writeup")

## Every peer, local: the bottom-row toast (write-ups red; WEEK 23's coffee
## toasts pass their own colour).
const TOAST_RED := Color(1, 0.35, 0.25)
func show_toast(text: String, color := TOAST_RED, seconds := 3.0) -> void:
	_toast_label.text = text
	_toast_label.add_theme_color_override("font_color", color)
	_toast_timer = seconds

## "Host" / "Player 2" / ... instead of a raw ENet peer id (those are large
## random numbers for clients). Numbered by join order — `players` is filled
## in spawn order on every peer, host first.
func player_display_name(peer_id: int) -> String:
	if peer_id == 1:
		return "Host"
	var index := players.keys().find(peer_id)
	return "Player %d" % (index + 1) if index >= 0 else "Player ?"

## WEEK 11: a priority-order sale is already in the sold count at
## PAY_PER_SALE, so it only adds the multiplier's extra on top.
## WEEK 19: plus the cleanup bonus (0 until clock-out), a share of the gross.
## WEEK 23: minus the coffee tab (BreakRoom.gd) — story days only; on an
## endless shift coffee comes out of the Bucks and Pay stays the medal score.
## PLAYTEST FIX (Oct 2026): + litter picked up, $1 a piece (Cleanup.gd's
## LITTER_PAY_PER_PIECE) — outside the gross, so the cleanliness bonus (a
## share of the gross) is exactly what it was.
func _pay_today() -> int:
	return _gross_pay_today() + cleanup.clean_bonus_today + cleanup.litter_pay_today() - writeups_today * WRITEUP_PENALTY - break_room.dollars_today()

func _pay_week() -> int:
	return _total_sold() * PAY_PER_SALE + _priority_bonus(priority_sales_week) + cleanup.clean_bonus_week + cleanup.litter_pay_week - writeups_week * WRITEUP_PENALTY - break_room.dollars_week()

## Sales plus the priority-order extra — the day's pay before write-ups and
## before the cleanup bonus (which is a share of this).
func _gross_pay_today() -> int:
	return (_total_sold() - _sold_at_day_start) * PAY_PER_SALE + _priority_bonus(priority_sales_today)

func _priority_bonus(sales: int) -> int:
	return int(round(sales * PAY_PER_SALE * (PRIORITY_ORDER_MULTIPLIER - 1.0)))

func _format_money(amount: int) -> String:
	return ("-$%d" % -amount) if amount < 0 else ("$%d" % amount)

## --- WEEK 11: manager priority stock orders --------------------------------

## Host-only, every frame from _process() while the shift runs: counts the
## open order's window down, and the gap to the next call-out. The gap keeps
## running while an order is open, so call-outs land every
## PRIORITY_ORDER_INTERVAL of shift clock (the window is shorter than the
## interval, so one is always closed before the next is due).
func _tick_priority_orders(delta: float) -> void:
	if hazard_levels()["orders"] <= 0:
		return
	if _order_id != 0:
		order_time_left = maxf(0.0, order_time_left - delta)
		if order_time_left <= 0.0:
			_close_priority_order(false)
	# WEEK 16: call-outs are a selling-window mechanic — the gap to the next
	# one only runs once the store is open (open_store() restarts it).
	if not store_open:
		return
	_order_timer -= delta
	if _order_timer <= 0.0:
		_order_timer = _priority_order_interval()
		# Don't call one out that the shift clock would cut short.
		if _order_id == 0 and shift_time_left > _priority_order_window():
			_issue_priority_order()

## Host-only. Picks a random unlocked section that can take at least
## PRIORITY_ORDER_QTY_MIN items right now (falls back to any that can take
## one), rolls a quantity, and opens the window. forced_* are for tests.
func _issue_priority_order(forced_section := "", forced_qty := 0) -> void:
	if not multiplayer.is_server():
		return
	var roomy := []
	var any := []
	var capacity := {}
	for section in _unlocked_sections():
		var sec_name: String = section["name"]
		if forced_section != "" and sec_name != forced_section:
			continue
		capacity[sec_name] = mini(_open_slots_in_section(section), _loose_stock_for_section(section))
		if capacity[sec_name] >= PRIORITY_ORDER_QTY_MIN:
			roomy.append(sec_name)
		if capacity[sec_name] >= 1:
			any.append(sec_name)
	var pool := roomy if not roomy.is_empty() else any
	if pool.is_empty():
		return # nothing anywhere can take stock right now — try again next interval
	var pick: String = pool[randi() % pool.size()]
	var qty := forced_qty
	if qty <= 0:
		qty = randi_range(PRIORITY_ORDER_QTY_MIN, PRIORITY_ORDER_QTY_MAX) + PRIORITY_ORDER_QTY_PER_EXTRA_PLAYER * max(0, players.size() - 1)
		qty = mini(qty, capacity[pick])
	_order_id = _next_order_id
	_next_order_id += 1
	order_section = pick
	order_needed = qty
	order_stocked = 0
	order_time_left = _priority_order_window()
	orders_called_today += 1
	print("[Main] Priority order #%d: stock %d in %s (%.0fs)" % [_order_id, qty, pick, order_time_left])
	_update_alert_layer(0.0) # the host's banner shows it this tick, not next frame

func _open_slots_in_section(section: Dictionary) -> int:
	var n := 0
	for shelf_body in shelves:
		if _grid_cell_of(shelf_body.global_position) != section["grid_pos"]:
			continue
		var shelf: Node = shelf_body.get_node("Shelf")
		if not shelf.wrecked:
			n += shelf.slot_count() - shelf.filled_count()
	return n

## Loose (not shelved, not break-room/out-of-bounds) products of the
## section's color — carried ones count, they're on their way somewhere.
func _loose_stock_for_section(section: Dictionary) -> int:
	var color: Color = SECTION_COLORS[section["name"]]
	var n := 0
	for obj in get_tree().get_nodes_in_group("carryable"):
		if is_break_room_at_pos(obj.global_position) or _is_out_of_bounds(obj.global_position):
			continue
		var visual := obj.get_node_or_null("Polygon2D")
		if visual == null or not visual.color.is_equal_approx(color):
			continue
		if shelves.any(func(s): return s.get_node("Shelf").contains(obj)):
			continue
		n += 1
	return n

## Host-only, called by Shelf.gd the moment an item settles into one of its
## slots. Tags it to the open order if it's the ordered section and the item
## isn't already tagged (re-shelving a knocked-off item doesn't count twice).
func note_item_stocked(obj: Node, shelf_body: Node) -> void:
	if not multiplayer.is_server() or _order_id == 0 or obj.has_meta("priority_order"):
		return
	var cell := _grid_cell_of(shelf_body.global_position)
	var in_section := SECTIONS.any(func(s): return s["name"] == order_section and s["grid_pos"] == cell)
	if not in_section:
		return
	obj.set_meta("priority_order", _order_id)
	order_stocked += 1
	if order_stocked >= order_needed:
		_close_priority_order(true)
	# Oct 2026: same tick as the count (this runs in Shelf.gd's physics step;
	# the banner otherwise waited for the next _process — a frame behind
	# whenever two physics steps landed in one frame under load).
	_update_alert_layer(0.0)

## Host: section name -> units sold this shift (note_sale()).
var sold_by_section_today := {}

## Host-only, called by Cashier.gd as a purchase completes.
func note_sale(item: Node) -> void:
	if not multiplayer.is_server():
		return
	# OCT 2026 PHASE 3: sales by section (host diagnostic — the staff tests
	# read what a staffed section actually sold).
	var visual := item.get_node_or_null("Polygon2D")
	if visual != null:
		var sec := _section_of_color(visual.color)
		sold_by_section_today[sec] = int(sold_by_section_today.get(sec, 0)) + 1
	if not item.has_meta("priority_order"):
		return
	var id: int = item.get_meta("priority_order")
	if _filled_order_ids.has(id):
		priority_sales_today += 1
		priority_sales_week += 1
	elif id == _order_id:
		_pending_order_sales[id] = _pending_order_sales.get(id, 0) + 1
	# else: its order lapsed unfilled — an ordinary sale.

func _close_priority_order(filled: bool) -> void:
	var id := _order_id
	var section := order_section
	var qty := order_needed
	var stocked := order_stocked
	if filled:
		_filled_order_ids[id] = true
		orders_filled_today += 1
		var early: int = _pending_order_sales.get(id, 0)
		priority_sales_today += early
		priority_sales_week += early
	_pending_order_sales.erase(id)
	_clear_priority_order()
	print("[Main] Priority order #%d %s" % [id, "FILLED" if filled else "lapsed (%d/%d stocked)" % [stocked, qty]])
	rpc("_announce_order_result", filled, section, qty)

## Host-only: forgets the open order without announcing anything (day
## start/end). Tags already on items stay, harmlessly — they only pay out
## for ids in _filled_order_ids.
func _clear_priority_order() -> void:
	if _order_id != 0:
		_pending_order_sales.erase(_order_id)
	_order_id = 0
	order_section = ""
	order_needed = 0
	order_stocked = 0
	order_time_left = 0.0

## WEEK 21 — the banner is Day 7's FINAL SHIFT in the story, and names the
## posting at the start of every endless shift, so nobody is surprised by what
## they signed up for (every peer, from replicated state).
func _set_banner_text() -> void:
	var big: Label = _finale_banner.get_child(0)
	var small: Label = _finale_banner.get_child(1)
	var detail: Label = _finale_banner.get_child(2)
	detail.visible = is_endless()
	if not is_endless():
		# OCT 2026 PHASE 2: the new complication this shift brings.
		var st: Dictionary = COMPLICATION_STAGES[clampi(stage_banner, 0, COMPLICATION_STAGES.size() - 1)]
		big.text = str(st["title"])
		small.text = str(st["line"])
		return
	var c: Dictionary = endless.contract
	var on := []
	for k in EndlessScript.HAZARDS:
		if endless.level_of(k) > 0:
			on.append("%s %s" % [EndlessScript.HAZARD_NAMES[k].to_lower(), EndlessScript.pips(endless.level_of(k))])
	big.text = "SHIFT #%d" % endless.shift_number
	small.text = "%s  %s  %s" % [str(c.get("name", "")), EndlessScript.stars_text(int(c.get("stars", 1))), EndlessScript.STAR_WORDS[int(c.get("stars", 1))]]
	detail.text = "open: %s\n%s" % [EndlessScript.sections_text(c), ("on: " + ", ".join(on)) if not on.is_empty() else "no hazards on this shift"]

## WEEK 12 — every peer, the moment its FINAL SHIFT banner comes up (from
## _update_alert_layer()): the fanfare (WEEK 22). Cosmetic only — nothing
## waits on it.
func _play_finale_sting() -> void:
	print("[Main] FINAL SHIFT")
	Sfx.play("final_shift")

## Every peer: the few seconds of "filled"/"missed" feedback on the banner,
## same moment-of-impact role as _announce_writeup()'s toast.
@rpc("authority", "call_local", "reliable")
func _announce_order_result(filled: bool, section: String, qty: int) -> void:
	_order_result_filled = filled
	if filled:
		_order_result_text = "ORDER FILLED — those %d %s items pay %sx!" % [qty, section, str(PRIORITY_ORDER_MULTIPLIER)]
	else:
		_order_result_text = "Priority order missed (%s) — no bonus" % section
	_order_result_timer = PRIORITY_ORDER_RESULT_SECONDS
	Sfx.play("order_filled" if filled else "order_missed")
	juice.order_result(filled)

func _build_alert_layer() -> void:
	var layer := CanvasLayer.new()
	layer.name = "AlertLayer"
	layer.layer = UI_LAYER_ALERTS
	add_child(layer)
	# Rows from the bottom up: 0 LOOK BUSY, 1 write-up toast, 2 (WEEK 11) the
	# priority order banner. Each row has its own fixed band, so all three
	# can be up at once without overlapping — the order banner sits above
	# the other two rather than sharing a row and getting covered by them.
	for i in 3:
		var label := Label.new()
		# Bottom of the screen: found by rendering frames — at the top, the
		# banner sat right over the manager himself whenever he was above
		# you (and over the debug HUD), hiding the "?"/"!" it's warning about.
		label.anchor_left = 0.0
		label.anchor_right = 1.0
		label.anchor_top = 1.0
		label.anchor_bottom = 1.0
		label.offset_top = -60.0 - i * 45.0
		label.offset_bottom = -20.0 - i * 45.0
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 24)
		label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
		label.add_theme_constant_override("shadow_offset_x", 2)
		label.add_theme_constant_override("shadow_offset_y", 2)
		label.visible = false
		layer.add_child(label)
	_watch_label = layer.get_child(0)
	_toast_label = layer.get_child(1)
	_toast_label.add_theme_color_override("font_color", Color(1, 0.35, 0.25))
	_order_label = layer.get_child(2)
	# WEEK 12 — the FINAL SHIFT banner: its own band in the upper third,
	# clear of the three alert rows along the bottom. Only up for a few
	# seconds at shift start, while everyone's still in the break room. Same
	# layer as the other alerts, so the debug HUD still draws over it.
	_finale_banner = VBoxContainer.new()
	_finale_banner.name = "FinaleBanner"
	_finale_banner.anchor_left = 0.0
	_finale_banner.anchor_right = 1.0
	_finale_banner.anchor_top = 0.14
	_finale_banner.anchor_bottom = 0.14
	_finale_banner.offset_bottom = 110.0
	_finale_banner.alignment = BoxContainer.ALIGNMENT_CENTER
	_finale_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_finale_banner.visible = false
	# WEEK 21: a third, smaller line — the endless banner's section/hazard list.
	for spec in [["", 52, Color(1, 0.8, 0.2)], ["", 22, Color(1, 1, 1)], ["", 17, Color(0.85, 0.95, 1)]]:
		var l := Label.new()
		l.text = spec[0]
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override("font_size", spec[1])
		l.add_theme_color_override("font_color", spec[2])
		l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
		l.add_theme_constant_override("shadow_offset_x", 3)
		l.add_theme_constant_override("shadow_offset_y", 3)
		_finale_banner.add_child(l)
	layer.add_child(_finale_banner)
	# WEEK 16 — the prep countdown / STORE OPEN line: top of the screen, in
	# its own band above the finale banner's.
	_prep_label = Label.new()
	_prep_label.name = "PrepLabel"
	_prep_label.anchor_left = 0.0
	_prep_label.anchor_right = 1.0
	_prep_label.anchor_top = 0.07
	_prep_label.anchor_bottom = 0.07
	_prep_label.offset_bottom = 34.0
	_prep_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prep_label.add_theme_font_size_override("font_size", 20)
	_prep_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	_prep_label.add_theme_constant_override("shadow_offset_x", 2)
	_prep_label.add_theme_constant_override("shadow_offset_y", 2)
	_prep_label.visible = false
	layer.add_child(_prep_label)
	# End-of-day report line for the orders, built in code like the rest of
	# this layer (nothing new goes into a .tscn — see the header note on
	# .tscn comments), placed just above the Pay line it feeds.
	report_order_label = Label.new()
	report_order_label.name = "OrderLabel"
	report_order_label.add_theme_font_size_override("font_size", 22)
	report_order_label.add_theme_color_override("font_color", Color(0.45, 0.9, 1, 1))
	report_order_label.visible = false
	report_pay_label.add_sibling(report_order_label)
	report_pay_label.get_parent().move_child(report_order_label, report_pay_label.get_index())
	# WEEK 19 — the cleanup line, right above Pay too.
	report_cleanup_label = Label.new()
	report_cleanup_label.name = "CleanupLabel"
	report_cleanup_label.add_theme_font_size_override("font_size", 18)
	report_cleanup_label.add_theme_color_override("font_color", Color(0.55, 0.9, 1, 1))
	report_cleanup_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	report_pay_label.add_sibling(report_cleanup_label)
	report_pay_label.get_parent().move_child(report_cleanup_label, report_pay_label.get_index())

## Every peer, every frame: the LOOK BUSY warning for whoever the manager is
## watching (only shown on that player's own screen — everyone else sees
## the "?"/"!" over his head instead) and the write-up toast.
func _update_alert_layer(delta: float) -> void:
	var me := multiplayer.get_unique_id() if Net.is_active() else 0
	var watched: bool = manager.active and not _day_report_active and manager.watch_peer == me and me != 0 and manager.watch_level > 0.0
	_watch_label.visible = watched
	if watched:
		var bars := int(round(manager.watch_level * 10.0))
		var hot: bool = manager.watch_level >= manager.WARN_LEVEL
		_watch_label.text = "%s  [%s%s]" % ["MANAGER IS WATCHING — LOOK BUSY!" if hot else "The manager is looking at you...", "|".repeat(bars), ".".repeat(10 - bars)]
		_watch_label.add_theme_color_override("font_color", Color(1, 0.3, 0.2) if hot else Color(1, 0.85, 0.2))
	_toast_timer = maxf(0.0, _toast_timer - delta)
	_toast_label.visible = _toast_timer > 0.0 and not _day_report_active
	# WEEK 11 — the priority order banner: every peer (it's a crew order),
	# same style as the LOOK BUSY row, cyan so the two never read as the
	# same warning. The open order wins over a lingering result line.
	_order_result_timer = maxf(0.0, _order_result_timer - delta)
	if order_section != "":
		_order_label.text = "MANAGER: Stock %d more in %s!  %ds left  (%sx pay)" % [order_needed - order_stocked, order_section, ceili(order_time_left), str(PRIORITY_ORDER_MULTIPLIER)]
		_order_label.add_theme_color_override("font_color", Color(1, 0.85, 0.2) if order_time_left <= 5.0 else Color(0.45, 0.9, 1))
	elif _order_result_timer > 0.0:
		_order_label.text = _order_result_text
		_order_label.add_theme_color_override("font_color", Color(0.5, 1, 0.5) if _order_result_filled else Color(0.75, 0.75, 0.75))
	_order_label.visible = (order_section != "" or _order_result_timer > 0.0) and not _day_report_active
	if multiplayer.is_server():
		finale_banner_left = maxf(0.0, finale_banner_left - delta)
	# A client can hold a banner timer for a stage it hasn't heard of yet
	# (both ride DaySync, but the first packet may predate the stage).
	var show_finale := finale_banner_left > 0.0 and not _day_report_active and (is_endless() or stage_banner > 0)
	if show_finale and not _finale_banner.visible:
		_play_finale_sting()
	# Every frame it's up, not just as it appears: on a client the banner's
	# timer (DaySync) can land before the new posting (EndlessSync) does.
	if show_finale:
		_set_banner_text()
	# OCT 2026 PHASE 2: local one-off notices (a section bought, an old save)
	# use the same band when nothing scheduled is on it.
	# It waits behind a scheduled banner (its clock only runs while it's on
	# screen), and never outlives its shift.
	if _day_report_active:
		_notice[2] = 0.0
	var show_notice_now: bool = not show_finale and float(_notice[2]) > 0.0 and not _day_report_active
	if show_notice_now:
		_notice[2] = maxf(0.0, float(_notice[2]) - delta)
	if show_notice_now:
		(_finale_banner.get_child(0) as Label).text = _notice[0]
		(_finale_banner.get_child(1) as Label).text = _notice[1]
		_finale_banner.get_child(2).visible = false
	_finale_banner.visible = show_finale or show_notice_now
	_finale_banner.modulate.a = clampf(finale_banner_left if show_finale else float(_notice[2]), 0.0, 1.0) # fades over the last second

## Cumulative total across every cashier, for as long as the session has
## run — never reset, unlike _sold_at_day_start (see the score-continuity
## comment above _sold_at_day_start's declaration). Used both directly (as
## the week/session total) and as the basis for "today's sold"
## (_total_sold() - _sold_at_day_start) in _process()'s debug HUD and
## _end_shift()'s report.
func _total_sold() -> int:
	var total := sold_carryover # WEEK 24: the week's sales from before a relaunch
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
##
## WEEK 15 turned that top-up into a backstock feed from the unpack pad; WEEK
## 16 removed it altogether: stock unpacked at the pad comes out as loose
## product in Storage that the crew carries to the shelves by hand, like any
## other carried item (Delivery.gd). There's no mid-shift refill from nothing
## any more — no box runs, no stock.
func _product_cap() -> int:
	return _product_baseline() + PRODUCT_PER_EXTRA_PLAYER * max(0, players.size() - 1)

## WEEK 16 — the day's opening floor: OPENING_STOCK_FRACTION of the old floor
## cap, spread evenly over the open sections (any remainder to random ones),
## straight into each section's spawn band. 0 by default: every unit of stock
## arrives by truck. Host-only.
func _spawn_opening_stock() -> void:
	var names: Array = _unlocked_sections().map(func(s): return s["name"])
	var n := roundi(_product_cap() * opening_stock_fraction)
	var even := n - n % names.size()
	for i in n:
		_spawn_product_for(names[i % names.size()] if i < even else names[randi() % names.size()])

func _section_of_color(color: Color) -> String:
	for sec_name in SECTION_COLORS:
		if color.is_equal_approx(SECTION_COLORS[sec_name]):
			return sec_name
	return ""

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
		if not is_break_room_at_pos(obj.global_position) and not _is_out_of_bounds(obj.global_position):
			continue
		var c: Node = obj.get_node("Carryable")
		if c.carrier_id != 0:
			continue
		# WEEK 15: a stray delivery box goes back to receiving, not a section.
		if obj.is_in_group("delivery_box"):
			var spot = delivery.free_receiving_spot()
			obj.global_position = spot if spot != null else DeliveryScript.RECEIVING_SPOTS[0]
		else:
			obj.global_position = _spawn_pos_in_section(_pick_unlocked_section())
		obj.linear_velocity = Vector2.ZERO
	# WEEK 8: a display knocked clean off the map (see the header's forklift
	# edge-case list) just goes home — it isn't stock, so there's no
	# "respawn somewhere useful" question to answer.
	for display_body in displays:
		if _is_out_of_bounds(display_body.global_position):
			display_body.get_node("Display").reset_to_home()

## WEEK 8 — true if a position is inside or past the world's perimeter
## walls. Nothing should ever be there; if something is (a hard forklift
## knock, or the old MAX_SPEED spike Carryable.gd clamps against), it's
## unreachable, so it's rescued rather than counted.
func _is_out_of_bounds(world_pos: Vector2) -> bool:
	return world_pos.x < WORLD_EDGE_MARGIN or world_pos.y < WORLD_EDGE_MARGIN \
		or world_pos.x > WORLD_WIDTH - WORLD_EDGE_MARGIN or world_pos.y > WORLD_HEIGHT - WORLD_EDGE_MARGIN

## Same shape as _restock_products(), for the combined shopper+disruptive
## population — tops back up to _customer_baseline() + PER_EXTRA_PLAYER
## whenever a customer has despawned (finished shopping, gave up and left,
## or timed out), keeping demand and chaos both roughly constant across
## the whole shift instead of a batch that eventually all finish and go
## idle.
##
## PLAYTEST ROOT-CAUSE FIX (Oct 2026 outside playtest: "red customers show up
## early, then never again"). Each spawn used to roll its role independently
## at CUSTOMER_DISRUPTIVE_RATIO — correct per SPAWN, but spawns only happen
## into slots someone else just left, and the two roles leave at very
## different rates: a disruptive customer always leaves at
## MAX_LIFETIME_DISRUPTIVE (45s), while a shopper's dynamic lifetime budget
## grows every time it commits to an item or a register (Customer.gd's
## _extend_lifetime_budget()) — 90-150s on a stocked floor, longer than the
## whole ~78-111s selling window. So: the opening fills the cap in one tick,
## all of that wave's red customers time out together 45s later, and each
## freed slot comes back red only 35% of the time — the other 65% go to a
## shopper who then holds that slot for the rest of the window. The red
## count only ever ratchets down. Measured on the old code (Day 7 solo,
## stocked floor): 6 red at opening -> 1 red from 45s to close; tools/
## playtest_fixes_test.gd --test=disruptive reproduces it. Now the ratio
## applies to the CROWD ON THE FLOOR: each refill keeps round(cap * ratio)
## of the live customers disruptive, so whenever a red one leaves, a red one
## comes back in (and Customer.gd jitters each one's lifetime, so they stop
## leaving in lockstep waves).
func _restock_customers() -> void:
	var cap: int = _customer_baseline() + CUSTOMER_PER_EXTRA_PLAYER * max(0, players.size() - 1)
	var live := get_tree().get_nodes_in_group("customer").filter(func(c): return not c.is_queued_for_deletion())
	var current := live.size()
	var live_disruptive := live.filter(func(c): return c.role == "disruptive").size()
	var want_disruptive := roundi(cap * CUSTOMER_DISRUPTIVE_RATIO)
	var roles := []
	while current < cap:
		var role := "disruptive" if live_disruptive < want_disruptive else "shopper"
		if role == "disruptive":
			live_disruptive += 1
		roles.append(role)
		current += 1
	roles.shuffle() # an opening wave walks in mixed, not reds first
	for role in roles:
		_spawn_customer(role)

## --- Week 6 Part 1: section helpers --------------------------------------

func _unlocked_sections() -> Array:
	var result := []
	for section in SECTIONS:
		if is_section_open(section):
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
## (Customer.gd's _find_wanted_item/_find_nearest_cashier/
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
			return is_section_open(section)
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

## WEEK 15: still true now that Storage has the loading dock and receiving in
## it — it's the crew's back room, customers stay out. (WEEK 18: the unpack
## pads moved out of Storage into the sections.)
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
	var tier := clampi(_unlocked_sections().size() - 1, 0, PRODUCT_DENSITY_BY_TIER.size() - 1)
	return roundi(12 * _unlocked_sections().size() * PRODUCT_DENSITY_BY_TIER[tier])

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

## OCT 2026 PHASE 3B — host-only. A new shopper's list: section names, one
## entry per item wanted (see SHOPPING_LIST_BY_TIER). Only sections that are
## open and have stock on a shelf right now can appear, each at most
## min(SHOPPING_LIST_MAX_PER_SECTION, its stocked units) times, so the store
## can satisfy the list as it stands. Spread on purpose: every stocked section
## is equally likely, whatever its distance from the door, and distinct
## sections are drawn before any repeats. [] when nothing is stocked (the
## shopper browses and asks again).
func make_shopping_list() -> PackedStringArray:
	var stocked := stocked_units_by_section()
	var sections: Array = stocked.keys()
	sections.shuffle()
	var tier := clampi(_unlocked_sections().size() - 1, 0, SHOPPING_LIST_BY_TIER.size() - 1)
	var want := randi_range(int(SHOPPING_LIST_BY_TIER[tier][0]), int(SHOPPING_LIST_BY_TIER[tier][1]))
	var out := PackedStringArray()
	var taken := {}
	var added := true
	while out.size() < want and added:
		added = false
		for sec in sections:
			if out.size() >= want:
				break
			var n: int = taken.get(sec, 0)
			if n < mini(SHOPPING_LIST_MAX_PER_SECTION, int(stocked[sec])):
				out.append(sec)
				taken[sec] = n + 1
				added = true
	return out

## OCT 2026 PHASE 3B — host: a shopper's walk from `from` to `to` around the
## store's walls, gates, shelves, registers and displays (CustomerNav.gd).
var _customer_nav: RefCounted = null
func customer_path(from: Vector2, to: Vector2) -> PackedVector2Array:
	if _customer_nav == null:
		_customer_nav = preload("res://CustomerNav.gd").new(self)
	return _customer_nav.path(from, to)

## Host: open section name -> units on its shelves now (only sections with
## at least one). A shelf only takes its own section's stock (Shelf.gd's
## _color_matches()), so the shelf's cell says what's on it.
func stocked_units_by_section() -> Dictionary:
	var out := {}
	for shelf_body in shelves:
		if not is_unlocked_at_pos(shelf_body.global_position):
			continue
		var n: int = shelf_body.get_node("Shelf").filled_objects().size()
		if n > 0:
			var sec := _section_name_at(shelf_body.global_position)
			out[sec] = int(out.get(sec, 0)) + n
	return out

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
	return unlocked[randi() % unlocked.size()] # always has at least Dry Goods (owned from the start)

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
	# WEEK 8: the same overlap-fling reasoning now applies to MOVING bodies
	# inside the band too — Meat/Deli's band spans the forklift's lane and
	# a display's home spot, and products spawning on top of each other was
	# already a mild pre-existing version of it. Retry a few times for a
	# clear spot; if the section is genuinely crowded, accept the last roll
	# rather than fail to spawn (the MAX_SPEED clamp still bounds the result).
	var pos := Vector2.ZERO
	for attempt in SPAWN_ATTEMPTS:
		pos = Vector2(randf_range(room_x + 180.0, room_x + 780.0), randf_range(room_y + 120.0, room_y + 360.0))
		if _spawn_pos_is_clear(pos):
			break
	return pos

func _spawn_pos_is_clear(pos: Vector2) -> bool:
	for f in [forklift, delivery_forklift]:
		if f.active and pos.distance_to(f.global_position) < SPAWN_CLEARANCE_FORKLIFT:
			return false
	for display_body in displays:
		if pos.distance_to(display_body.global_position) < SPAWN_CLEARANCE_DISPLAY:
			return false
	for obj in get_tree().get_nodes_in_group("carryable"):
		if pos.distance_to(obj.global_position) < SPAWN_CLEARANCE_PRODUCT:
			return false
	# WEEK 10: Day 5's outer stock row reaches into the spawn band — a product
	# spawned on a slot would settle into it and stock itself.
	for shelf_body in shelves:
		for slot in shelf_body.get_node("Shelf").slots:
			if pos.distance_to(slot.global_position) < SPAWN_CLEARANCE_PRODUCT:
				return false
	return true

## UPGRADED TWICE this session, replacing the old per-section
## _customer_entrance_pos(): playtest request for a real store entrance —
## a genuinely separate outdoor Sidewalk zone (SIDEWALK_GRID_POS, its own
## room, distinct from the Checkout hub the central registers live in —
## see the GRID MAP comment above this file's header for why they
## used to be one dual-purpose room and aren't any more), that every
## customer spawns at and physically walks in from, rather than popping
## into existence at whichever section they're headed to. All customers
## spawn HERE regardless of role or eventual target, then use their
## existing target-picking AI (Customer.gd's _find_wanted_item/
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
## WEEK 15: called per unit of backstock (_restock_products()), for a named
## section, instead of for a random unlocked one.
func _spawn_product_for(section_name: String) -> void:
	for section in SECTIONS:
		if section["name"] == section_name:
			spawn_product_at(section_name, _spawn_pos_in_section(section))
			return

## Host-only. Public for Delivery.gd's unpacking (at the box's section pad).
func spawn_product_at(section_name: String, pos: Vector2) -> void:
	product_spawner.spawn({
		"index": _product_spawn_index,
		"pos": pos,
		"color": SECTION_COLORS[section_name],
	})
	_product_spawn_index += 1

## Every peer. WEEK 15: the same spawner also carries delivery boxes (so
## they're under Products, replicated and cleared at day start like stock);
## Delivery.gd builds those.
func _spawn_product_node(data: Dictionary) -> Node:
	if data.get("kind", "") == "box":
		return delivery.build_box(data)
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
	# OCT 2026 PHASE 3B: a shopper's list rides in the spawn data, so every
	# peer has it from the first frame (later changes go through the
	# customer's own synchronizer).
	var list := make_shopping_list() if role == "shopper" else PackedStringArray()
	customer_spawner.spawn({
		"index": _customer_spawn_index,
		"pos": pos,
		"role": role,
		"carry_id": carry_id,
		"items_target": list.size(),
		"list": list,
		"look": _deal_customer_look(),
	})
	_customer_spawn_index += 1

func _spawn_customer_node(data: Dictionary) -> Node:
	var c := CustomerScene.instantiate()
	c.name = "Customer%d" % data["index"]
	c.position = data["pos"]
	c.role = data["role"]
	c.carry_id = data["carry_id"]
	c.items_target = data["items_target"]
	c.shopping_list = data.get("list", PackedStringArray())
	c.look_index = data.get("look", 1)
	return c

## WEEK 25 — host-only. Deals customer looks from a shuffled deck of all
## Customer.LOOK_COUNT, refilled when empty, so any handful of customers on
## screen shows the whole range of faces instead of whatever a plain
## randi() happens to repeat. Never deals the same look twice in a row
## across a refill either.
var _customer_look_deck: Array = []
var _last_customer_look := 0
func _deal_customer_look() -> int:
	if _customer_look_deck.is_empty():
		for i in range(1, CustomerScript.LOOK_COUNT + 1):
			_customer_look_deck.append(i)
		_customer_look_deck.shuffle()
		if _customer_look_deck.back() == _last_customer_look:
			_customer_look_deck.reverse()
	_last_customer_look = _customer_look_deck.pop_back()
	return _last_customer_look

func _process(delta: float) -> void:
	# WEEK 7 — runs on every peer, purely reactive to current_day (which is
	# host-authoritative, replicated — see _day_sync in _ready()), not
	# something this check itself changes. Catches: the very first tick on
	# any peer (thanks to _last_config_key's "" sentinel), a later day-
	# advance on the host, and a late-joining client the moment
	# current_day's first replicated value arrives — one code path for all
	# three instead of separate "initial setup" and "day changed" cases.
	if _config_key() != _last_config_key:
		_reconfigure_world()
		print("[Main] Day is now %d%s" % [current_day, (" (endless shift #%d)" % endless.shift_number) if is_endless() else ""])

	# End-of-day report (see _end_shift()/_advance_to_next_day()) — a real
	# full-screen CanvasLayer now, replacing the old debug-label-only
	# message that was easy to miss buried in DebugLabel's wall of text.
	# Driven off the replicated _day_report_active flag so every peer shows/
	# hides it at the same moment; the sold numbers are recomputed from
	# already-replicated state (_total_sold()/_sold_at_day_start), not a
	# separate replicated pair, so there's nothing new to keep in sync here.
	# WEEK 21: not while the Week Complete screen or the hub is up (HubUI.gd
	# draws those, over the same frozen world).
	report_layer.visible = _day_report_active and endless.screen == EndlessScript.SCREEN_NONE
	# An endless shift's report only once its payout is in — the report flag
	# (DaySync, unreliable) and the endless state (EndlessSync, reliable) land
	# on a client in either order, and without this the LAST shift's report
	# flashed up for a frame as the next shift was taken.
	if is_endless() and int(endless.last_payout.get("shift", -1)) != endless.shift_number:
		report_layer.visible = false
	if report_layer.visible:
		var week_sold := _total_sold()
		var today_sold := week_sold - _sold_at_day_start
		var lv := hazard_levels()
		report_title_label.text = "Day %d Complete!" % current_day
		report_today_label.text = "Sold Today: %d" % today_sold
		# OCT 2026 PHASE 2: no week any more — the bank is the running number.
		report_week_label.text = "Bank: %s   ·   lifetime earned $%d" % [_format_money(money), lifetime_earned]
		report_week_label.add_theme_color_override("font_color", Color(0.9, 0.95, 1))
		# WEEK 9 — write-ups only exist once the manager is on; before
		# that the line is hidden rather than showing a meaningless 0.
		# WEEK 21: "when the manager was on the floor", story or endless.
		report_writeup_label.visible = lv["manager"] > 0 or writeups_today > 0
		var who := []
		for peer_id in writeups_by_peer:
			who.append("%s x%d" % [player_display_name(peer_id), writeups_by_peer[peer_id]])
		report_writeup_label.text = "Write-ups: %d  (%s docked)%s" % [writeups_today, _format_money(writeups_today * WRITEUP_PENALTY), ("  —  " + ", ".join(who)) if not who.is_empty() else ""]
		report_pay_label.text = "Pay Today: %s  →  into the bank" % _format_money(_pay_today())
		if break_room.coffee_cups_today > 0:
			report_pay_label.text += "\n(coffee: %d cup(s), %s off — %s)" % [break_room.coffee_cups_today, _format_money(break_room.dollars_today()), break_room.drinkers_text()]
		# OCT 2026 PHASE 3: the staff's wages, out of the bank beside the pay.
		if staff.wages_today > 0 and not is_endless():
			report_pay_label.text += "\nStaff wages: -%s (%s)  →  bank %s%s" % [_format_money(staff.wages_today), staff.wages_detail, "+" if _pay_today() - staff.wages_today >= 0 else "", _format_money(_pay_today() - staff.wages_today)]
		report_order_label.visible = lv["orders"] > 0
		report_cleanup_label.text = "Cleanup: spills & knockovers %d/%d (%d%%)  ·  litter %d/%d (%d%%)\n+%s cleanliness bonus  ·  +%s trash picked up (%d)  (%s)" % [cleanup.mop_total - cleanup.mop_left, cleanup.mop_total, roundi(cleanup.mop_fraction() * 100.0), cleanup.litter_total - cleanup.litter_left, cleanup.litter_total, roundi(cleanup.litter_fraction() * 100.0), _format_money(cleanup.clean_bonus_today), _format_money(cleanup.litter_pay_today()), cleanup.litter_collected_today, ("clocked out by %s" % player_display_name(clocked_out_by)) if clocked_out_by > 0 else "auto clock-out"]
		report_order_label.text = "Priority orders: %d/%d filled  —  %d sold at %sx (+%s)" % [orders_filled_today, orders_called_today, priority_sales_today, str(PRIORITY_ORDER_MULTIPLIER), _format_money(_priority_bonus(priority_sales_today))]
		report_bucks_label.visible = is_endless()
		report_run_label.visible = is_endless()
		continue_button.text = "Continue"
		report_pay_label.get_parent().add_theme_constant_override("separation", 6 if is_endless() else 10)
		report_shop_label.visible = not is_endless()
		if not is_endless():
			_fill_shop_forecast()
		if legacy_endless_route and current_day >= LEGACY_WEEK_DAYS and not is_endless():
			continue_button.text = "Finish the Week"
		elif is_endless():
			_fill_endless_report(today_sold)

	var connected := Net.is_active()
	var role := "OFFLINE"
	if connected:
		role = "HOST" if multiplayer.is_server() else "CLIENT"
	var lines := ["peer id: %d  (%s)  players: %d  %s" % [
		multiplayer.get_unique_id() if connected else 0, role, players.size(), ("endless shift #%d  wallet %d Bucks" % [endless.shift_number, endless.wallet]) if is_endless() else "day: %d" % current_day,
	]]
	for obj in carryable_objects:
		var c: Node = obj.get_node("Carryable")
		var carried := "carried by %d" % c.carrier_id if c.carrier_id != 0 else "free"
		lines.append("%s: (%.0f, %.0f)  %s" % [obj.name, obj.position.x, obj.position.y, carried])

	# WEEK 7: host-authoritative now, not ticked locally on every peer —
	# see _ready()'s _day_sync comment for why an un-replicated
	# shift_active/shift_time_left became a real bug once a shift could
	# actually END and transition, not just count down forever.
	# WEEK 19: the clock running out closes the store for cleanup; the report
	# comes at clock-out (clock_out()).
	if multiplayer.is_server() and shift_active and shift_time_left > 0.0:
		shift_time_left = max(0.0, shift_time_left - delta)
		if shift_time_left <= 0.0:
			start_cleanup()
	if multiplayer.is_server() and cleanup_active:
		cleanup_time_left = maxf(0.0, cleanup_time_left - delta)
		cleanup.tick_cleanup(delta)
		if cleanup_time_left <= 0.0:
			clock_out(0)
	# Population maintenance — only the host actually spawns anything (both
	# _restock_* functions no-op their spawning on non-authority peers via
	# the spawners themselves being authority-driven), but the timer is
	# harmless to tick on every peer, so it's not worth an extra guard here.
	if shift_active and multiplayer.is_server():
		tutorial.tick_host() # practice shift: the clock stays pinned
		# WEEK 16: the prep ceiling — the store opens on its own when it runs
		# out, whether or not anyone flipped the sign.
		if not store_open:
			prep_time_left = maxf(0.0, prep_time_left - delta)
			if prep_time_left <= 0.0:
				open_store(0)
		_restock_timer -= delta
		if _restock_timer <= 0.0:
			_restock_timer = RESTOCK_CHECK_INTERVAL
			_rescue_stranded_products()
			# No customers until the store is open (WEEK 16 prep phase).
			if store_open and not cleanup_active and not test_hold_customers:
				_restock_customers()
		if not cleanup_active:
			_tick_priority_orders(delta)
		# WEEK 17: no brownouts or spills during prep — their clocks (first
		# event LIGHTS_FIRST_DELAY / SPILL_FIRST_DELAY in) start at opening.
		# WEEK 19: nor during cleanup — and with no ticks, the spills on the
		# floor at close stop drying, so they're there to be mopped.
		if store_open and not cleanup_active:
			ambience.tick_host(delta)
			cleanup.tick_selling(delta)
		delivery.tick_host(delta)
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
		lines.append("%s: %d/%d%s" % [shelf_body.name, f, s, "  WRECKED" if shelf.wrecked else ""])
	if forklift.active:
		# rams_today isn't replicated (diagnostic only), so only the host's
		# count is meaningful — clients just see that it's live.
		lines.append("FORKLIFT active in %s" % _section_name_at(forklift.home_position) + (" — rams today: %d" % forklift.rams_today if multiplayer.is_server() else ""))
	if manager.active and not cleanup_active:
		lines.append("MANAGER on the floor — %s  |  write-ups today: %d" % [("watching %s (%d%%)" % [player_display_name(manager.watch_peer), int(manager.watch_level * 100.0)]) if manager.watch_peer != 0 else "patrolling", writeups_today])
	if delivery.active:
		lines.append("DELIVERY truck %s (%d on it) | boxes out %d | unpacked today %d" % ["at the dock" if delivery.truck_parked() else ("away" if delivery.truck_offset >= delivery.TRUCK_AWAY_OFFSET else "moving"), delivery.truck_load.size(), delivery.boxes_waiting(), delivery.boxes_unpacked_today])
	if cleanup_active:
		lines.append("CLEANUP — auto clock-out in %.0fs | spills & knockovers left %d/%d | litter left %d/%d" % [cleanup_time_left, cleanup.mop_left, cleanup.mop_total, cleanup.litter_left, cleanup.litter_total])
	elif shift_active:
		lines.append("STORE %s | litter on the floor: %d" % ["OPEN" if store_open else "CLOSED — prep, opens by itself in %.0fs" % prep_time_left, cleanup.litter.size()])
	if ambience.active:
		lines.append("LIGHTS %s  |  SPILLS on the floor: %d" % ["FLICKERING (%.0f%%)" % (ambience.brightness * 100.0) if ambience.brightness < 1.0 or ambience.event_playing() else "ok", ambience.spills.size()])
	if order_section != "":
		lines.append("PRIORITY ORDER: %d/%d in %s, %.0fs left" % [order_stocked, order_needed, order_section, order_time_left])
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
		# WEEK 21: no "week" once the story's week is over.
		if is_endless():
			var t: Array = endless.contract.get("targets", [0, 0, 0])
			lines.append("Stocked now: %d/%d  |  This shift: %d sold  |  Shift pay: %s (bronze $%d / silver $%d / gold $%d)  |  %.0fs left" % [total_filled, total_slots, today_sold, _format_money(_pay_today()), t[0], t[1], t[2], shift_time_left])
		else:
			lines.append("Stocked now: %d/%d  |  Today: %d  |  Lifetime sold: %d  |  Pay today: %s  |  Bank %s  |  stage %d, %d section(s)  |  %.0fs left" % [total_filled, total_slots, today_sold, week_sold, _format_money(_pay_today()), _format_money(money), complication_stage, sections_owned, shift_time_left])
	debug_label.text = "\n".join(lines)
	# Only once you're actually in a game (not over the main menu) and
	# your own player exists — before that "0 players" would be all it said.
	status_label.visible = status_hud and connected and not players.is_empty()
	if status_label.visible:
		status_label.text = _status_text()
	# Last, after this frame's shift/order ticks above: found by the net-orders
	# bot pass — run earlier in _process(), the host's banner showed a new
	# priority order one frame late (clients were fine, they get it by sync).
	_update_alert_layer(delta)
	_update_store_sign(delta)
	# WEEK 19: the manager goes home at close (every peer, from the
	# replicated flag; his rounds stop in Manager.gd).
	manager.visible = manager.active and not cleanup_active
