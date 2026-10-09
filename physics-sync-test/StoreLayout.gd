extends RefCounted
## PHASE 5B PART 2A — THE STORE LAYOUT TABLE (today's store, data only).
##
## Everything the game used to work out from "which 960 x 540 screen cell is
## this position in" is written down here instead, as named areas, and read
## through Areas.gd (main.areas). Nothing in this file runs; it is the one
## place a layout lives. Part 2B (Plan B, "Grows Outward" — see
## docs/store-layout-proposal.md) replaces this table and Main.tscn, not the
## logic that reads them.
##
## This table reproduces TODAY's store exactly: the 3 x 3 grid of 960 x 540
## rooms (Main.gd's old GRID MAP comment):
##   (0,0) Break Room    (1,0) Dry Goods      (2,0) Bakery
##   (0,1) Dairy/Frozen  (1,1) CHECKOUT HUB   (2,1) Produce
##   (0,2) [empty]       (1,2) Sidewalk       (2,2) Storage
## tools/areas_test.gd --test=snapshot compares a dump of it against
## tools/areas_snapshot.txt, and tools/layout_proof.gd showed the game gives
## the same answers, frames and nav grids with it as with the old cell math.
##
## WHAT AN AREA IS. ROOMS tile the world: every point of the world is in at
## most one room, and Areas.area_at(pos) answers which. A room has:
##   id        stable name, used everywhere instead of a grid cell
##   role      "section" (a sales department), "hub" (checkout/sales floor),
##             "storage" (the back room), "break_room", "sidewalk" (outside,
##             where shoppers arrive and are bounced to), "empty" (an unused
##             lot: never open)
##   rect      world Rect2 (a "polygon" key, a PackedVector2Array, is also
##             understood by Areas.gd — Plan B's wings may want one)
##   section   for role "section": Main.SECTIONS' name. The room is open
##             exactly when that section is (owned, or the practice shift's
##             Dry Goods) — Areas.is_open(). Several rooms (and features) may
##             name the same section: Plan B's wing + its back door open
##             together when the section is bought.
##   shoppers  false: customers are kept out (excluded from their nav grid,
##             nudged out if they wander in, never chase a player there)
##   janitor   false: left out of the janitor's nav grid too
##   shop_floor true: where shoppers shop when open — litter lands there, the
##             janitor works there
##   bg        the RoomBackgrounds polygon that floors it (StoreArt.gd)
##   wall_art  which wall material the walls bordering it take: "market",
##             "warehouse", "break_room" (StoreArt.gd; "" = none)
##   links     rooms you can walk straight into from this one (open floor or
##             a gate — not a sealed wall). The manager's rounds route over
##             it (Areas.route()). Listed both ways.
##   spawn_band (sections) room-local Rect2 where spawned stock and spills
##             land (Main._spawn_pos_in_section(), Ambience.pick_spill_spot())
##   helper    (sections with a helper) {"band_y": room-local open band the
##             helper flees the forklift within} — the helper's work area is
##             the room's rect itself (Helper.gd)
## FEATURES are named areas inside a room that some system needs (they do
## not tile; area_at() never returns one): the forklift lane, the storage
## forklift floor the janitor keeps off, the front-door bounce zone, the
## shoppers' arrival strip.
## ANCHORS are named points (pads, cans, the dock, spawn points, the break
## room's furniture...). The systems' old constants are now aliases of these,
## so their values — and every test and save that reads them — are unchanged.
## CHECKOUT is the register block: queue direction and how many registers are
## open at each tier.

## The whole world (camera limits, out-of-bounds rescue, nav grid size).
const WORLD := Rect2(0.0, 0.0, 2880.0, 1620.0)

## Storage's corner: every back-room anchor below is written relative to it,
## so moving the back room as one block (as all three plans do) is one edit.
const STORAGE_ORIGIN := Vector2(1920.0, 1080.0)
## Storage's forklift floor: its lane, the dock and the receiving row (the
## "storage_forklift_floor" feature below; CustomerNav.JANITOR_KEEP_OUT).
const STORAGE_FORKLIFT_FLOOR := Rect2(STORAGE_ORIGIN + Vector2(230.0, 70.0), Vector2(730.0, 360.0))

const ROOMS := [
	{"id": "break_room", "role": "break_room", "rect": Rect2(0.0, 0.0, 960.0, 540.0),
		"shoppers": false, "janitor": false, "bg": "BreakRoomBg", "wall_art": "break_room",
		"links": ["dry_goods"]},
	{"id": "dry_goods", "role": "section", "section": "Dry Goods", "rect": Rect2(960.0, 0.0, 960.0, 540.0),
		"shop_floor": true, "bg": "DryGoodsBg", "wall_art": "market",
		"links": ["hub", "bakery", "break_room"],
		"spawn_band": Rect2(180.0, 120.0, 600.0, 240.0)},
	{"id": "bakery", "role": "section", "section": "Bakery", "rect": Rect2(1920.0, 0.0, 960.0, 540.0),
		"shop_floor": true, "bg": "BakeryBg", "wall_art": "market",
		"links": ["dry_goods"], # its south wall (to Produce) is sealed
		"spawn_band": Rect2(180.0, 120.0, 600.0, 240.0),
		"helper": {"band_y": Vector2(150.0, 395.0)}},
	{"id": "dairy_frozen", "role": "section", "section": "Dairy/Frozen", "rect": Rect2(0.0, 540.0, 960.0, 540.0),
		"shop_floor": true, "bg": "DairyFrozenBg", "wall_art": "market",
		"links": ["hub", "reserved"], # north (break room) sealed
		"spawn_band": Rect2(180.0, 120.0, 600.0, 240.0),
		"helper": {"band_y": Vector2(150.0, 395.0)}},
	{"id": "hub", "role": "hub", "rect": Rect2(960.0, 540.0, 960.0, 540.0),
		"shop_floor": true, "bg": "EntranceBg", "wall_art": "market",
		"links": ["dry_goods", "produce", "dairy_frozen", "sidewalk"]},
	{"id": "produce", "role": "section", "section": "Produce", "rect": Rect2(1920.0, 540.0, 960.0, 540.0),
		"shop_floor": true, "bg": "MeatDeliBg", "wall_art": "market",
		"links": ["hub"], # north (Bakery) and south (Storage) sealed
		"spawn_band": Rect2(180.0, 120.0, 600.0, 240.0),
		"helper": {"band_y": Vector2(150.0, 395.0)}},
	{"id": "reserved", "role": "empty", "rect": Rect2(0.0, 1080.0, 960.0, 540.0),
		"bg": "ReservedBg", "links": ["dairy_frozen", "sidewalk"]},
	{"id": "sidewalk", "role": "sidewalk", "rect": Rect2(960.0, 1080.0, 960.0, 540.0),
		"bg": "SidewalkBg", "links": ["hub", "reserved", "storage"]},
	{"id": "storage", "role": "storage", "rect": Rect2(STORAGE_ORIGIN, Vector2(960.0, 540.0)),
		"shoppers": false, "bg": "StorageBg", "wall_art": "warehouse",
		"links": ["sidewalk"]}, # north (Produce) sealed
]

const FEATURES := [
	# The Produce forklift drives the length of its room along this lane
	# (Forklift.gd: lane ends = the rect's ends; its y is the forklift's home).
	{"id": "produce_forklift_lane", "role": "forklift_lane", "room": "produce",
		"rect": Rect2(1920.0, 788.0, 960.0, 44.0)},
	# Storage's forklift floor — its lane, the dock and the receiving row: the
	# janitor's grid keeps off it (it walks round to the dumpster).
	{"id": "storage_forklift_floor", "role": "forklift_floor", "room": "storage",
		"rect": STORAGE_FORKLIFT_FLOOR, "janitor": false},
	# Out the front door: past the store's south wall (y 1080) by a body —
	# a hauled or thrown troublemaker here is BOUNCED (Main.is_outside_door()).
	{"id": "front_door_outside", "role": "exit", "room": "sidewalk",
		"rect": Rect2(960.0, 1104.0, 960.0, 516.0)},
	# Where shoppers arrive and leave (the grey sidewalk strip).
	{"id": "customer_arrival", "role": "customer_spawn", "room": "sidewalk",
		"rect": Rect2(1320.0, 1080.0, 240.0, 300.0)},
]

const ANCHORS := {
	# --- people ---
	"player_spawn": Vector2(480.0, 270.0), # Main.SPAWN_CENTER: you clock in in the break room
	"janitor_home": Vector2(1760.0, 650.0), # Janitor.HOME: the hub's tool rack corner
	"front_door": Vector2(1440.0, 1100.0), # Cleanup.FRONT_DOOR: the hauling arrow points here
	"bounce_target": Vector2(1440.0, 1130.0), # the practice shift's "walk them out" marker, just past the door
	# --- the sales floor ---
	"store_sign": Vector2(1610.0, 1115.0), # Main.STORE_SIGN_POS
	"tool_rack": Vector2(1822.0, 588.0), # Cleanup.RACK_POS (hub)
	# --- the break room ---
	"time_clock": Vector2(880.0, 300.0),
	"tool_station": Vector2(700.0, 280.0),
	"lockers": Vector2(95.0, 405.0), # Shop.LOCKER_SPOT: where you stand to use them
	"staff_board": Vector2(30.0, 235.0), # Staff.BOARD_POS: on the wall
	"staff_board_spot": Vector2(75.0, 235.0), # Staff.BOARD_SPOT
	"coffee_machine": Vector2(180.0, 66.0),
	"vending_machine": Vector2(610.0, 70.0),
	# --- the back room (relative to STORAGE_ORIGIN) ---
	"dumpster": STORAGE_ORIGIN + Vector2(110.0, 450.0),
	"delivery_forklift_home": STORAGE_ORIGIN + Vector2(350.0, 170.0),
	# --- the practice shift's props (the hub) ---
	"practice_puddle": Vector2(1640.0, 660.0),
}

## Unpack pads, one per section (Delivery.PAD_CENTERS). Each needs ~300 x 300
## of open floor round it (its spill ring is 80-150 px out).
const PADS := {
	"Dry Goods": Vector2(1440.0, 300.0),
	"Produce": Vector2(2400.0, 665.0),
	"Dairy/Frozen": Vector2(480.0, 665.0),
	"Bakery": Vector2(2400.0, 125.0),
}

## The trash cans, IN SAVE ORDER (SaveGame stores each can's fill by index):
## the hub's, then one inside each section's hub-side doorway. Keep five, in
## this order, or v6 saves load fills into the wrong cans.
const CANS := [
	{"pos": Vector2(1110.0, 590.0), "section": ""}, # hub, north-west corner
	{"pos": Vector2(1300.0, 500.0), "section": "Dry Goods"},
	{"pos": Vector2(1975.0, 620.0), "section": "Produce"},
	{"pos": Vector2(905.0, 620.0), "section": "Dairy/Frozen"},
	{"pos": Vector2(1975.0, 300.0), "section": "Bakery"},
]

## The tools in tool order (mops, then brooms): the break-room station's two of
## each, then the hub rack's one of each (Cleanup.TOOL_SPOTS).
const TOOL_SPOTS := [Vector2(660.0, 320.0), Vector2(678.0, 320.0), Vector2(1800.0, 612.0), Vector2(722.0, 320.0), Vector2(740.0, 320.0), Vector2(1844.0, 612.0)]

## The practice shift's litter props (the hub).
const PRACTICE_LITTER := [Vector2(1180.0, 650.0), Vector2(1215.0, 690.0), Vector2(1250.0, 640.0), Vector2(1160.0, 720.0)]

## The loading dock (Delivery.gd): the truck backs west along DOCK_LANE_Y to
## DOCK_X and drives off past the world's east edge.
const DOCK_LANE_Y := STORAGE_ORIGIN.y + 170.0
const DOCK_X := STORAGE_ORIGIN.x + 820.0
## The receiving row, dock end first (the forklift fills the nearest first).
const RECEIVING_SPOTS := [
	STORAGE_ORIGIN + Vector2(760.0, 370.0), STORAGE_ORIGIN + Vector2(685.0, 370.0),
	STORAGE_ORIGIN + Vector2(610.0, 370.0), STORAGE_ORIGIN + Vector2(535.0, 370.0),
	STORAGE_ORIGIN + Vector2(460.0, 370.0), STORAGE_ORIGIN + Vector2(385.0, 370.0),
	STORAGE_ORIGIN + Vector2(310.0, 370.0),
]

## The registers (CentralCheckout in Main.tscn, in scene order). queue_dir is
## the way each register's queue runs from its counter (Cashier.tscn's Queue*
## markers — tools/areas_test.gd checks the scene agrees); Plan B turns it
## north. registers_by_tier: how many are open at 1, 2, 3, 4 sections.
const CHECKOUT := {
	"room": "hub",
	"queue_dir": Vector2(1.0, 0.0),
	"registers_by_tier": [2, 3, 4, 5],
}
