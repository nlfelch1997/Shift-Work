extends RefCounted
## THE STORE LAYOUT TABLE (data only). PHASE 5B PART 2B: Plan B, "Grows
## Outward" (docs/store-layout-proposal.md, section 3; built in greybox,
## docs/store-layout-plan-b-report.md).
##
## Everything the game needs to know about WHERE things are is written down
## here, as named areas, structure and points, and read through Areas.gd
## (main.areas). Nothing in this file runs; it is the one place a layout
## lives. Part 2A (docs/store-layout-refactor-report.md) moved the old 3 x 3
## grid of 960 x 540 rooms into this table and proved the game identical;
## Part 2B replaced the table's contents with Plan B. The logic reading it
## did not change shape.
##
## THE STORE (world 2400 x 1860; x right, y down; north = up):
##
##   y 0 ┌──────────────┬────────┬──────────────────────┐
##       │ BREAK ROOM   │ STAFF  │ STORAGE (back room)  │  back of house,
##       │ (as before)  │ HALL   │ dock on the east wall│  never for shoppers
##   540 ├────────┬─────┴─door───┴──┬─back door─┬───────┤
##       │ BAKERY │  DRY GOODS      │  PRODUCE  wing    │
##       │ wing 4 │  (the starter   │  (wing 2)         │
##  1080 ├──open──┤   corner shop)  │  forklift lane    │
##       │ DAIRY/ │                 │  runs north-south │
##       │ FROZEN ├─────────────────┤                   │
##       │ wing 3 │  CHECKOUT (hub) │                   │
##  1680 └────────┴──────door───────┴───────────────────┘
##         SIDEWALK + parking (shoppers arrive and leave by the door)
##  1860   x 0     780            1620               2400
##
## The store starts as the corner shop (Dry Goods + the checkout), with the
## whole back of house behind it. Buying a section knocks out one outside
## wall of the shop and that wing is there: Produce to the right (beside the
## door; its own back door into Storage opens with it), then Dairy/Frozen to
## the left (cooler wall on the outside wall), then Bakery in the back-left
## corner (open to the shop AND to the Dairy wing). Nothing that exists ever
## moves. Before it's bought, a wing is an empty lot behind the shop's outside
## wall (BARRIERS below, drawn by StoreArt.gd as wall + FOR SALE banner; the
## lot itself as fenced gravel).
##
## WHAT AN AREA IS. ROOMS tile the world: every point of the world is in at
## most one room, and Areas.area_at(pos) answers which. A room has:
##   id        stable name, used everywhere instead of a grid cell
##   role      "section" (a sales department), "hub" (checkout/sales floor),
##             "storage" (the back room), "break_room", "corridor" (the staff
##             hall), "sidewalk" (outside, where shoppers arrive and are
##             bounced to), "empty" (an unused lot: never open)
##   rect      world Rect2 (a "polygon" key, a PackedVector2Array, is also
##             understood by Areas.gd)
##   section   for role "section": Main.SECTIONS' name. The room is open
##             exactly when that section is (owned, or the practice shift's
##             Dry Goods) — Areas.is_open(). Several rooms, features and
##             barriers may name the same section (Produce's wing and its
##             back door open together when it's bought).
##   shoppers  false: customers are kept out (excluded from their nav grid,
##             nudged out if they wander in, never chase a player there)
##   janitor   false: left out of the janitor's nav grid too
##   shop_floor true: where shoppers shop when open — litter lands there, the
##             janitor works there
##   bg        the RoomBackgrounds polygon that floors it (StoreArt.gd)
##   wall_art  which wall material the walls bordering it take: "market",
##             "warehouse", "break_room" (StoreArt.gd; "" = none)
##   links     rooms you can walk straight into from this one (open floor or
##             a barrier that opens — not a wall). The manager's rounds route
##             over it (Areas.route()). Listed both ways.
##   waypoint  (optional) the open spot that stands for the room on a walk
##             through it (the manager's rounds); the rect's centre if absent.
##             He walks straight between stops and has no collision, so each
##             waypoint/lookout is placed so the straight legs between them
##             clear the shelves (tools/growth_test.gd checks it).
##   lookouts  (sections) the open spots the manager stops at on his rounds
##   spawn_band (sections) room-local Rect2 of open floor where spawned
##             stock and spills land (Main._spawn_pos_in_section(),
##             Ambience.pick_spill_spot())
##   helper    (sections with a helper) {"band": room-local Rect2}: the open
##             floor a helper keeps to while getting out of the forklift's
##             way (Helper.gd); the helper's work area is the room's rect.
## FEATURES are named areas inside a room that some system needs (they do
## not tile; area_at() never returns one): the forklift lane, the storage
## forklift floor the janitor keeps off, the front-door bounce zone, the
## shoppers' arrival strip.
## WALLS and BARRIERS are the store's structure (Main.gd builds them from
## here at start-up; nothing in Main.tscn): walls are permanent; a barrier
## is solid until its section is bought (Gate.gd), then gone.
## ANCHORS are named points (pads, cans, the dock, spawn points, the break
## room's furniture...). The systems' old constants are aliases of these.
## CHECKOUT is the register block: queue direction and how many registers are
## open at each tier.
##
## Positions sit on a 60 px grid where they can (it suits both the 20 px nav
## cells and the 30 px floor tiles); every size is in world px at the art
## scale the tilesets are drawn at (StoreArt.ART_SCALE: a floor tile is 30 px,
## a character ~28 px), so a tileset swap changes art, not this table.

## The whole world (camera limits, out-of-bounds rescue, nav grid size).
const WORLD := Rect2(0.0, 0.0, 2400.0, 1860.0)

## Storage's corner: every back-room anchor below is written relative to it,
## so the back room moved here from the old store as one block (Part 2A's
## promise): only this line changed for it.
const STORAGE_ORIGIN := Vector2(1440.0, 0.0)
## Storage's forklift floor: its lane, the dock and the receiving row (the
## "storage_forklift_floor" feature below; CustomerNav.JANITOR_KEEP_OUT).
const STORAGE_FORKLIFT_FLOOR := Rect2(STORAGE_ORIGIN + Vector2(230.0, 70.0), Vector2(730.0, 360.0))

## Wall thickness (every wall and barrier is a strip this thick, centred on
## its line).
const WALL_THICKNESS := 20.0

const ROOMS := [
	# --- back of house (y 0-540) ---
	{"id": "break_room", "role": "break_room", "rect": Rect2(0.0, 0.0, 960.0, 540.0),
		"shoppers": false, "janitor": false, "bg": "BreakRoomBg", "wall_art": "break_room",
		"links": ["staff_hall"]},
	{"id": "staff_hall", "role": "corridor", "rect": Rect2(960.0, 0.0, 480.0, 540.0),
		"shoppers": false, "bg": "StaffHallBg", "wall_art": "break_room",
		"links": ["break_room", "storage", "dry_goods"]},
	{"id": "storage", "role": "storage", "rect": Rect2(STORAGE_ORIGIN, Vector2(960.0, 540.0)),
		"shoppers": false, "bg": "StorageBg", "wall_art": "warehouse",
		"links": ["staff_hall", "produce"]}, # (Produce's back door)
	# --- the sales floor (y 540-1680) ---
	{"id": "bakery", "role": "section", "section": "Bakery", "rect": Rect2(0.0, 540.0, 780.0, 540.0),
		"shop_floor": true, "bg": "BakeryBg", "wall_art": "market",
		"links": ["dry_goods", "dairy_frozen"],
		"waypoint": Vector2(600.0, 820.0),
		"lookouts": [Vector2(600.0, 820.0), Vector2(320.0, 1000.0)],
		"spawn_band": Rect2(230.0, 230.0, 530.0, 280.0),
		"helper": {"band": Rect2(60.0, 60.0, 660.0, 420.0)}},
	{"id": "dairy_frozen", "role": "section", "section": "Dairy/Frozen", "rect": Rect2(0.0, 1080.0, 780.0, 600.0),
		"shop_floor": true, "bg": "DairyFrozenBg", "wall_art": "market",
		"links": ["bakery", "dry_goods", "hub"],
		"waypoint": Vector2(690.0, 1250.0),
		"lookouts": [Vector2(690.0, 1250.0), Vector2(300.0, 1250.0)],
		"spawn_band": Rect2(240.0, 20.0, 520.0, 210.0),
		"helper": {"band": Rect2(60.0, 60.0, 660.0, 480.0)}},
	{"id": "dry_goods", "role": "section", "section": "Dry Goods", "rect": Rect2(780.0, 540.0, 840.0, 840.0),
		"shop_floor": true, "bg": "DryGoodsBg", "wall_art": "market",
		"links": ["staff_hall", "hub", "bakery", "dairy_frozen", "produce"],
		"waypoint": Vector2(1200.0, 790.0),
		"lookouts": [Vector2(1200.0, 790.0), Vector2(1200.0, 1090.0)],
		"spawn_band": Rect2(120.0, 520.0, 540.0, 240.0)}, # (between the tool rack and the checkout's door corridor)
	{"id": "hub", "role": "hub", "rect": Rect2(780.0, 1380.0, 840.0, 300.0),
		"shop_floor": true, "bg": "EntranceBg", "wall_art": "market",
		"links": ["dry_goods", "dairy_frozen", "produce", "sidewalk"],
		"waypoint": Vector2(1510.0, 1430.0)}, # inside the door, overlooking the queues
	{"id": "produce", "role": "section", "section": "Produce", "rect": Rect2(1620.0, 540.0, 780.0, 1140.0),
		"shop_floor": true, "bg": "MeatDeliBg", "wall_art": "market",
		"links": ["dry_goods", "hub", "storage"],
		"waypoint": Vector2(1780.0, 1080.0),
		"lookouts": [Vector2(1780.0, 1080.0), Vector2(2050.0, 1450.0)],
		"spawn_band": Rect2(40.0, 640.0, 680.0, 420.0), # the wing's open south half, across the lane (as the old room's band crossed its lane)
		"helper": {"band": Rect2(414.0, 60.0, 216.0, 1020.0)}},
	# --- outside ---
	{"id": "sidewalk", "role": "sidewalk", "rect": Rect2(0.0, 1680.0, 2400.0, 180.0),
		"bg": "SidewalkBg", "links": ["hub"]},
]

const FEATURES := [
	# The Produce forklift drives the length of its wing along this lane,
	# north-south (Forklift.gd: the lane's long axis is its axis, the ends are
	# the rect's ends, its home is the south end).
	{"id": "produce_forklift_lane", "role": "forklift_lane", "room": "produce",
		"rect": Rect2(2120.0, 550.0, 44.0, 1120.0)},
	# Storage's forklift floor — its lane, the dock and the receiving row: the
	# janitor's grid keeps off it (it walks round to the dumpster).
	{"id": "storage_forklift_floor", "role": "forklift_floor", "room": "storage",
		"rect": STORAGE_FORKLIFT_FLOOR, "janitor": false},
	# Out the front door: past the front wall (y 1680, 10 px thick each side)
	# by a body — a hauled or thrown troublemaker here is BOUNCED
	# (Main.is_outside_door()).
	{"id": "front_door_outside", "role": "exit", "room": "sidewalk",
		"rect": Rect2(0.0, 1704.0, 2400.0, 156.0)},
	# Where shoppers arrive and leave (the pavement outside the door).
	{"id": "customer_arrival", "role": "customer_spawn", "room": "sidewalk",
		"rect": Rect2(1390.0, 1700.0, 240.0, 140.0)},
]

## The permanent walls: [from, to] centre lines (WALL_THICKNESS thick).
## Openings are simply gaps: the staff door (x 1000-1200) from the hall into
## the shop, the break room's and Storage's doorways into the hall, and the
## shop's front door (x 1410-1610).
const WALLS := [
	[Vector2(0.0, 10.0), Vector2(2400.0, 10.0)], # back of the building
	[Vector2(10.0, 0.0), Vector2(10.0, 1860.0)], # west edge
	[Vector2(2390.0, 0.0), Vector2(2390.0, 1860.0)], # east edge
	[Vector2(0.0, 1850.0), Vector2(2400.0, 1850.0)], # the kerb (world edge)
	[Vector2(0.0, 540.0), Vector2(1000.0, 540.0)], # back-of-house wall: break room + hall
	[Vector2(1200.0, 540.0), Vector2(1640.0, 540.0)], # ...staff door 1000-1200, then Storage's wall
	[Vector2(1840.0, 540.0), Vector2(2400.0, 540.0)], # ...Produce's back door 1640-1840 (a barrier)
	[Vector2(960.0, 0.0), Vector2(960.0, 300.0)], # break room | staff hall (doorway 300-530)
	[Vector2(1440.0, 0.0), Vector2(1440.0, 300.0)], # staff hall | Storage (doorway 300-530)
	[Vector2(0.0, 1080.0), Vector2(540.0, 1080.0)], # Bakery | Dairy (opening 540-780 is a barrier)
	[Vector2(0.0, 1680.0), Vector2(1410.0, 1680.0)], # the front: west of the door
	[Vector2(1610.0, 1680.0), Vector2(2400.0, 1680.0)], # ...east of the door
]

## The knock-out walls: solid (an outside wall of the shop with a FOR SALE
## banner) until the section is bought, then gone. Several per section; the
## first of each section's is the one Main.gate_of() returns.
const BARRIERS := [
	{"section": "Produce", "from": Vector2(1620.0, 540.0), "to": Vector2(1620.0, 1680.0)}, # the shop's east wall
	{"section": "Produce", "from": Vector2(1640.0, 540.0), "to": Vector2(1840.0, 540.0), "back_door": true}, # into Storage
	{"section": "Dairy/Frozen", "from": Vector2(780.0, 1080.0), "to": Vector2(780.0, 1680.0)}, # the shop's west wall (front half)
	{"section": "Bakery", "from": Vector2(780.0, 540.0), "to": Vector2(780.0, 1080.0)}, # the shop's west wall (back half)
	{"section": "Bakery", "from": Vector2(540.0, 1080.0), "to": Vector2(780.0, 1080.0)}, # the Dairy wing's opening into it
]

const ANCHORS := {
	# --- people ---
	"player_spawn": Vector2(480.0, 270.0), # Main.SPAWN_CENTER: you clock in in the break room
	"janitor_home": Vector2(900.0, 1360.0), # Janitor.HOME: by the shop's tool rack
	"front_door": Vector2(1510.0, 1680.0), # Cleanup.FRONT_DOOR: the hauling arrow points here
	"bounce_target": Vector2(1510.0, 1730.0), # the practice shift's "walk them out" marker, just past the door
	# --- the sales floor ---
	"store_sign": Vector2(1665.0, 1720.0), # Main.STORE_SIGN_POS: on the pavement, east of the door
	# Cleanup.RACK_POS: a free-standing rack on the shop's west side, south of
	# the aisles — ~540 px from the checkout's mess, as the old hub rack was
	# (by the staff door it was ~990 px away, and fetching the broom lost to
	# sweeping by hand: tools/upkeep_test.gd B2/B3).
	"tool_rack": Vector2(850.0, 1300.0),
	# --- the break room (unchanged) ---
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
	# --- the practice shift's props (the shop floor, south of the aisles) ---
	"practice_puddle": Vector2(1460.0, 1290.0),
	# --- tests and tools: somewhere nobody works (the far west pavement) ---
	"out_of_the_way": Vector2(300.0, 1770.0),
}

## Unpack pads, one per section (Delivery.PAD_CENTERS). Each needs ~300 x 300
## of open floor round it (its spill ring is 80-150 px out).
const PADS := {
	# Dry Goods (crew-stocked: no helper): in the shop's north end, inside the
	# staff door and clear of the gondolas. First at the aisle mouths (1200,
	# 1100): the checkout's queues run north and a busy lane's line reached
	# it, so shoppers stood on the pad and its spilled stock (Dry Goods ran
	# dry while selling at 3+ sections; report section 5).
	"Dry Goods": Vector2(1110.0, 750.0),
	# A helper's pad sits in the floor its slots face: Produce's at the dead-end
	# north end of the strip between its two rows (every slot faces it), far
	# enough west that its spill ring (<= 150 px) stays off the forklift lane
	# (x 2120: the forklift plows anything on it); Dairy/Frozen's at the head
	# of the aisle between the wall run and the island. The first placements
	# (by the back door; east of the island) made the helpers walk round a
	# shelf row for most units: ~50 % more walking than the old rooms'
	# helpers, and their wings ran a third emptier at 3 sections (progression
	# sim; docs/store-layout-plan-b-report.md section 5).
	"Produce": Vector2(1950.0, 670.0),
	"Dairy/Frozen": Vector2(330.0, 1210.0),
	"Bakery": Vector2(450.0, 900.0),
}

## The trash cans, IN SAVE ORDER (SaveGame stores each can's fill by index):
## the checkout's, then one per section. Keep five, in this order, or v6
## saves load fills into the wrong cans.
const CANS := [
	{"pos": Vector2(1592.0, 1400.0), "section": ""}, # checkout, inside the door
	{"pos": Vector2(960.0, 580.0), "section": "Dry Goods"}, # the shop's back wall, by the staff door
	{"pos": Vector2(1660.0, 1150.0), "section": "Produce"}, # inside the wing's opening
	{"pos": Vector2(735.0, 1630.0), "section": "Dairy/Frozen"}, # inside the wing's opening, by the front
	{"pos": Vector2(735.0, 1020.0), "section": "Bakery"}, # inside the wing, by both its openings
]

## The tools in tool order (mops, then brooms): the break-room station's two of
## each, then the shop rack's one of each (Cleanup.TOOL_SPOTS).
const TOOL_SPOTS := [Vector2(660.0, 320.0), Vector2(678.0, 320.0), Vector2(828.0, 1324.0), Vector2(722.0, 320.0), Vector2(740.0, 320.0), Vector2(872.0, 1324.0)]

## The practice shift's litter props (the shop floor, south-west).
const PRACTICE_LITTER := [Vector2(900.0, 1150.0), Vector2(935.0, 1190.0), Vector2(970.0, 1140.0), Vector2(880.0, 1220.0)]

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

## The registers (CentralCheckout in Main.tscn, in scene order: Cashier1 is
## the lane nearest the door, the first to open). queue_dir is the way each
## register's queue runs from its counter (the counters are turned so their
## Queue* markers run this way — tools/areas_test.gd checks the scene
## agrees): north, into the store. registers_by_tier: how many are open at 1,
## 2, 3, 4 sections.
const CHECKOUT := {
	"room": "hub",
	"queue_dir": Vector2(0.0, -1.0),
	"registers_by_tier": [2, 3, 4, 5],
}
