#!/usr/bin/env python3
"""Store layout model for docs/store-layout-proposal.md (Phase 5B, Part 1).

Design aid only: it is NOT game code and nothing in the game reads it.
It describes the current store and the three proposed floor plans as plain
rectangles in world pixels, then:
  1. draws each one as a top-down greybox diagram (PNG), and
  2. measures walking distances on a 20 px grid with the same 16 px
     clearance the game's shopper pathfinding uses (CustomerNav.gd), so the
     plans can be compared with today's store on equal terms.

Run:  python3 docs/store-layout/layout_model.py      (needs Pillow)
Writes plan_*.png / current_model.png next to this file and prints the
distance tables used in the proposal.

Conventions match the game: y grows downward, a shelf body is 180 x 66,
its three slots sit 70 px in front of its centre (60 px apart), the outer
stock row (top tier) 56 px further out, and a shopper stands 29 px beyond
the slot it takes from. Customers walk 90 px/s, players 220 px/s.
"""
import heapq
import math
import os
import random

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
GRID = 20
CLEARANCE = 16
CUSTOMER_SPEED = 90.0
PLAYER_SPEED = 220.0

FACING = {"N": (0, -1), "S": (0, 1), "E": (1, 0), "W": (-1, 0)}

SECTION_COLORS = {
    "Dry Goods": (235, 205, 60),
    "Produce": (215, 70, 70),
    "Dairy/Frozen": (80, 140, 225),
    "Bakery": (215, 150, 60),
}
ZONE_FILL = {
    "Dry Goods": (250, 244, 214),
    "Produce": (250, 225, 225),
    "Dairy/Frozen": (222, 234, 250),
    "Bakery": (243, 228, 205),
    "checkout": (240, 236, 222),
    "floor": (236, 236, 232),
    "storage": (196, 198, 196),
    "break": (232, 218, 196),
    "outside": (140, 140, 140),
    "corridor": (214, 210, 204),
    "lot": (90, 96, 90),
}


class Shelf:
    def __init__(self, section, x, y, facing, dressing=False):
        self.section, self.x, self.y, self.facing = section, x, y, facing
        self.dressing = dressing  # art-only shelf: collision, no slots

    def rect(self):
        if self.facing in ("N", "S"):
            return (self.x - 90, self.y - 33, self.x + 90, self.y + 33)
        return (self.x - 33, self.y - 90, self.x + 33, self.y + 90)

    def slots(self, rows=1):
        fx, fy = FACING[self.facing]
        px, py = -fy, fx  # along the shelf
        out = []
        for depth in ([70] if rows == 1 else [70, 126]):
            for off in (-60, 0, 60):
                out.append((self.x + fx * depth + px * off, self.y + fy * depth + py * off))
        return out

    def stand_points(self, rows=2):
        fx, fy = FACING[self.facing]
        return [(sx + fx * 29, sy + fy * 29) for sx, sy in self.slots(rows)]


class Layout:
    def __init__(self, name, w, h):
        self.name, self.w, self.h = name, w, h
        self.zones = []  # (rect, kind, label)
        self.walls = []  # rects
        self.gates = []  # (rect, section) solid until the section is bought
        self.shelves = []
        self.registers = []  # (x, y, queue_dir)  queue_dir: unit vector the line runs along
        self.solids = []  # other collision rects (displays, dumpster, ...)
        self.marks = []  # (x, y, label, color) points of interest
        self.lanes = []  # (rect, label) forklift lanes / truck
        self.no_customer = []  # rects customers never enter (break room, storage)
        self.spawn = (0, 0)  # where shoppers appear
        self.exit = (0, 0)  # where they leave
        self.receiving = (0, 0)  # middle of the receiving row
        self.pads = {}  # section -> (x, y)
        self.camera = None  # (w, h) of one player's view in world px
        self.camera_at = None  # where the view outline is drawn (centre); default: the door
        self.locked_overlay = []  # (rect, section, label) drawn as hatched until bought
        self.overlay_alpha = 235  # 235: hidden (an empty lot); lower: seen through a shutter
        self.notes = []  # (x, y, text, size)
        self.solids_draw_only = []  # receiving spots etc. (not obstacles)

    def wall(self, x0, y0, x1, y1, t=20):
        """A wall segment along an axis-aligned line, t px thick."""
        if y0 == y1:
            self.walls.append((min(x0, x1), y0 - t / 2, max(x0, x1), y0 + t / 2))
        else:
            self.walls.append((x0 - t / 2, min(y0, y1), x0 + t / 2, max(y0, y1)))

    def gate(self, section, x0, y0, x1, y1, t=20):
        if y0 == y1:
            self.gates.append(((min(x0, x1), y0 - t / 2, max(x0, x1), y0 + t / 2), section))
        else:
            self.gates.append(((x0 - t / 2, min(y0, y1), x0 + t / 2, max(y0, y1)), section))

    def shelf(self, section, x, y, facing, dressing=False):
        self.shelves.append(Shelf(section, x, y, facing, dressing))

    def register_rects(self):
        out = []
        for x, y, q in self.registers:
            # Cashier.tscn: a 60 x 40 counter; its queue runs along q.
            out.append((x - 30, y - 20, x + 30, y + 20))
        return out

    def counts(self):
        c = {}
        for s in self.shelves:
            if not s.dressing:
                c[s.section] = c.get(s.section, 0) + 1
        return c


# ---------------------------------------------------------------------------
# Navigation (a stand-in for CustomerNav.gd: same grid, same clearance)
# ---------------------------------------------------------------------------
class Nav:
    def __init__(self, layout, owned, for_customers=True):
        self.L = layout
        self.cols = int(math.ceil(layout.w / GRID))
        self.rows = int(math.ceil(layout.h / GRID))
        self.solid = bytearray(self.cols * self.rows)
        rects = list(layout.walls) + [r for r, s in layout.gates if s not in owned]
        rects += [s.rect() for s in layout.shelves] + layout.register_rects() + layout.solids
        for r in rects:
            self._mark(r, CLEARANCE)
        if for_customers:
            for r in layout.no_customer:
                self._mark(r, 0)

    def _mark(self, r, pad):
        x0, y0, x1, y1 = r[0] - pad, r[1] - pad, r[2] + pad, r[3] + pad
        for cx in range(max(0, int(x0 // GRID)), min(self.cols, int(x1 // GRID) + 1)):
            for cy in range(max(0, int(y0 // GRID)), min(self.rows, int(y1 // GRID) + 1)):
                mx, my = (cx + 0.5) * GRID, (cy + 0.5) * GRID
                if x0 <= mx <= x1 and y0 <= my <= y1:
                    self.solid[cy * self.cols + cx] = 1

    def _open_near(self, p):
        cx = min(self.cols - 1, max(0, int(p[0] // GRID)))
        cy = min(self.rows - 1, max(0, int(p[1] // GRID)))
        if not self.solid[cy * self.cols + cx]:
            return (cx, cy)
        for r in range(1, 8):
            best, bd = None, 1e9
            for dx in range(-r, r + 1):
                for dy in range(-r, r + 1):
                    nx, ny = cx + dx, cy + dy
                    if 0 <= nx < self.cols and 0 <= ny < self.rows and not self.solid[ny * self.cols + nx]:
                        d = dx * dx + dy * dy
                        if d < bd:
                            best, bd = (nx, ny), d
            if best:
                return best
        return None

    def dist(self, a, b):
        """Grid path length in px (8-way, octile; corner cutting not allowed)."""
        s, t = self._open_near(a), self._open_near(b)
        if s is None or t is None:
            return None
        if s == t:
            return 0.0
        cols = self.cols
        INF = 1e18
        g = {s: 0.0}
        h = lambda c: GRID * (max(abs(c[0] - t[0]), abs(c[1] - t[1])) + (math.sqrt(2) - 1) * min(abs(c[0] - t[0]), abs(c[1] - t[1])))
        pq = [(h(s), 0.0, s)]
        while pq:
            f, gc, c = heapq.heappop(pq)
            if c == t:
                return gc
            if gc > g.get(c, INF):
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)):
                nx, ny = c[0] + dx, c[1] + dy
                if not (0 <= nx < cols and 0 <= ny < self.rows) or self.solid[ny * cols + nx]:
                    continue
                if dx and dy and (self.solid[c[1] * cols + nx] or self.solid[ny * cols + c[0]]):
                    continue
                ng = gc + (GRID * 1.41421356 if dx and dy else GRID)
                if ng < g.get((nx, ny), INF):
                    g[(nx, ny)] = ng
                    heapq.heappush(pq, (ng + h((nx, ny)), ng, (nx, ny)))
        return None

    def open_cells(self):
        return self.cols * self.rows - sum(self.solid)



def storage_block(L, ox, oy, label="BACK ROOM / STORAGE"):
    """Today's Storage room (Delivery.gd / Cleanup.gd numbers) moved as one block:
    (ox, oy) is where its top-left corner (today 1920,1080) lands. Every
    Delivery.gd constant then shifts by the same offset."""
    dx, dy = ox - 1920, oy - 1080
    L.zones.append(((ox, oy, ox + 960, oy + 540), "storage", label))
    L.lanes.append(((2150 + dx, 1225 + dy, 2740 + dx, 1275 + dy), "delivery forklift lane"))
    for x in (2680, 2605, 2530, 2455, 2380, 2305, 2230):
        L.solids_draw_only.append((x + dx - 22, 1450 + dy - 22, x + dx + 22, 1450 + dy + 22))
    L.solids.append((1975 + dx, 1502 + dy, 2085 + dx, 1558 + dy))
    L.marks += [(2740 + dx, 1250 + dy, "DOCK", (40, 40, 40)), (2030 + dx, 1530 + dy, "DUMPSTER", (30, 120, 50))]
    L.marks.append((2455 + dx, 1490 + dy, "receiving row", (150, 110, 0)))
    L.receiving = (2455 + dx, 1450 + dy)

# ---------------------------------------------------------------------------
# The layouts
# ---------------------------------------------------------------------------
def current():
    """Today's store, from Main.tscn / Delivery.gd / Cleanup.gd coordinates."""
    L = Layout("Current: 3x3 grid of rooms", 2880, 1620)
    L.camera = (960, 540)
    cells = {
        (0, 0): ("break", "BREAK ROOM"), (1, 0): ("Dry Goods", "DRY GOODS"), (2, 0): ("Bakery", "BAKERY"),
        (0, 1): ("Dairy/Frozen", "DAIRY / FROZEN"), (1, 1): ("checkout", "CHECKOUT HUB"), (2, 1): ("Produce", "PRODUCE"),
        (0, 2): ("lot", "(reserved, empty)"), (1, 2): ("outside", "SIDEWALK"), (2, 2): ("storage", "STORAGE"),
    }
    for (cx, cy), (kind, label) in cells.items():
        L.zones.append(((cx * 960, cy * 540, cx * 960 + 960, cy * 540 + 540), kind, label))
    L.wall(0, 10, 2880, 10)
    L.wall(0, 1610, 2880, 1610)
    L.wall(10, 0, 10, 1620)
    L.wall(2870, 0, 2870, 1620)
    L.wall(0, 540, 960, 540)  # break room / dairy seal
    L.wall(1920, 540, 2880, 540)  # bakery / produce seal
    L.wall(1920, 1080, 2880, 1080)  # produce / storage seal
    L.gate("Produce", 1920, 540, 1920, 1080)
    L.gate("Dairy/Frozen", 960, 540, 960, 1080)
    L.gate("Bakery", 1920, 0, 1920, 540)
    for x, y in ((1060, 130), (1060, 410)):
        L.shelf("Dry Goods", x, y, "E")
    for x, y in ((1820, 130), (1820, 410)):
        L.shelf("Dry Goods", x, y, "W")
    for x in (1320, 1560):
        L.shelf("Dry Goods", x, 60, "S")
    for sec, ox, oy in (("Produce", 1920, 540), ("Dairy/Frozen", 0, 540), ("Bakery", 1920, 0)):
        for dx in (220, 740, 480):
            L.shelf(sec, ox + dx, oy + 480, "N")
        for dx in (220, 740):
            L.shelf(sec, ox + dx, oy + 60, "S")
    for x, y in ((1110, 910), (1360, 910), (1610, 910), (1235, 1020), (1485, 1020)):
        L.registers.append((x, y, (1, 0)))
    L.solids += [(2378, 788, 2422, 832), (2498, 678, 2542, 722)]  # Produce displays
    L.lanes.append(((2040, 785, 2760, 835), "Produce forklift lane"))
    L.zones.remove(((1920, 1080, 2880, 1620), "storage", "STORAGE"))
    storage_block(L, 1920, 1080, "STORAGE")
    L.no_customer += [(0, 0, 960, 540), (1920, 1080, 2880, 1620)]
    L.spawn = (1440, 1230)
    L.exit = (1440, 1300)
    L.pads = {"Dry Goods": (1440, 300), "Produce": (2400, 665), "Dairy/Frozen": (480, 665), "Bakery": (2400, 125)}
    L.marks += [(1610, 1115, "SIGN", (200, 40, 40))]
    return L


def plan_a():
    """PLAN A - THE RACETRACK. One big hall, every department's floor there from
    day one behind a roll-down shutter; a loop aisle round a centre block of
    grocery gondolas; fresh departments on the walls; back of house behind
    the back wall."""
    L = Layout("Plan A: The Racetrack", 2400, 1860)
    L.camera = (960, 540)
    L.zones.append(((0, 0, 960, 540), "break", "BREAK ROOM (unchanged)"))
    L.zones.append(((960, 0, 1440, 540), "corridor", "STAFF HALL"))
    storage_block(L, 1440, 0)
    L.zones.append(((0, 540, 2400, 1700), "floor", ""))
    L.zones.append(((0, 1700, 2400, 1860), "outside", "SIDEWALK + PARKING"))
    L.zones.append(((20, 560, 620, 1100), "Bakery", "BAKERY (corner)"))
    L.zones.append(((640, 560, 1540, 1000), "Dairy/Frozen", "DAIRY / FROZEN (cooler wall)"))
    L.zones.append(((1540, 560, 1800, 1000), "corridor", "UNPACK BAY"))
    L.zones.append(((1820, 560, 2380, 1340), "Produce", "PRODUCE (by the door)"))
    L.zones.append(((560, 1140, 1640, 1380), "Dry Goods", "GROCERY AISLES"))
    L.zones.append(((560, 1400, 1840, 1680), "checkout", "CHECKOUT"))
    L.overlay_alpha = 110
    L.locked_overlay += [((20, 560, 620, 1100), "Bakery", "shutter down - for sale"),
                         ((640, 560, 1540, 1000), "Dairy/Frozen", "shutter down - for sale"),
                         ((1820, 560, 2380, 1340), "Produce", "shutter down - for sale")]
    L.wall(0, 10, 2400, 10)
    L.wall(10, 0, 10, 1700)
    L.wall(2390, 0, 2390, 1700)
    L.wall(0, 550, 1560, 550)  # back wall; staff door 1560-1760 opens into the unpack bay
    L.wall(1760, 550, 2400, 550)
    L.wall(960, 0, 960, 380)  # break room | staff hall (door 380-540)
    L.wall(1440, 0, 1440, 380)  # staff hall | back room (door 380-540)
    L.wall(0, 1690, 1980, 1690)  # front wall; the door is 1980-2180, by Produce
    L.wall(2180, 1690, 2400, 1690)
    L.gate("Bakery", 620, 560, 620, 1100)
    L.gate("Bakery", 20, 1100, 620, 1100)
    L.gate("Dairy/Frozen", 640, 1000, 1540, 1000)
    L.gate("Produce", 1820, 560, 1820, 1340)
    L.gate("Produce", 1820, 1340, 2380, 1340)
    for x in (130, 310, 490):
        L.shelf("Bakery", x, 600, "S")
    for y in (780, 960):
        L.shelf("Bakery", 60, y, "E")
    for x in (730, 910, 1090, 1270, 1450):
        L.shelf("Dairy/Frozen", x, 600, "S")
    for y in (690, 870, 1050):
        L.shelf("Produce", 2340, y, "W")
    L.shelf("Produce", 1990, 760, "E")
    L.shelf("Produce", 1990, 1000, "E")
    L.solids.append((1900, 1100, 1944, 1144))  # sale bin
    L.solids.append((2260, 1200, 2304, 1244))  # sample table
    L.lanes.append(((2120, 640, 2170, 1180), "Produce forklift lane (N-S)"))
    for gx in (700, 1100, 1500):
        L.shelf("Dry Goods", gx - 33, 1260, "W")
        L.shelf("Dry Goods", gx + 33, 1260, "E")
        L.solids.append((gx - 40, 1352, gx + 40, 1380))  # end caps (art + collision)
        L.solids.append((gx - 40, 1140, gx + 40, 1168))
    for x in (1640, 1420, 1200, 980, 760):  # in the order they open (nearest the door first)
        L.registers.append((x, 1640, (0, -1)))
    L.marks += [(2080, 1720, "SIGN", (200, 40, 40)), (1200, 470, "tool rack", (90, 90, 90))]
    L.no_customer += [(0, 0, 2400, 545), (1540, 545, 1800, 1000)]
    L.spawn = (2080, 1780)
    L.exit = (2080, 1780)
    L.pads = {"Dry Goods": (1670, 820), "Produce": (2030, 1220), "Dairy/Frozen": (1090, 880), "Bakery": (380, 920)}
    L.notes.append((700, 1400, "queue zone: each line runs up from its register", 18))
    L.notes.append((700, 1060, "loop aisle (racetrack) round the grocery block", 18))
    L.notes.append((1900, 1420, "door + open entry floor", 16))
    return L


def plan_b():
    """PLAN B - GROWS OUTWARD. Starts as a small corner shop (grocery aisles +
    checkout). Each purchase knocks out an exterior wall and a new wing is
    there; nothing that already exists moves. Back of house runs along the
    whole back from day one."""
    L = Layout("Plan B: Grows Outward", 2400, 1740)
    L.camera = (960, 540)
    L.zones.append(((0, 0, 960, 540), "break", "BREAK ROOM (unchanged)"))
    L.zones.append(((960, 0, 1440, 540), "corridor", "STAFF HALL"))
    storage_block(L, 1440, 0)
    L.zones.append(((0, 540, 2400, 1580), "floor", ""))
    L.zones.append(((0, 1580, 2400, 1740), "outside", "SIDEWALK + PARKING"))
    L.zones.append(((780, 560, 1620, 1560), "Dry Goods", "STARTER SHOP: grocery + checkout"))
    L.zones.append(((1640, 560, 2380, 1560), "Produce", "WING 2: PRODUCE"))
    L.zones.append(((20, 960, 760, 1560), "Dairy/Frozen", "WING 3: DAIRY / FROZEN"))
    L.zones.append(((20, 560, 760, 940), "Bakery", "WING 4: BAKERY"))
    L.locked_overlay += [((1640, 560, 2380, 1560), "Produce", "empty lot until bought"),
                         ((20, 960, 760, 1560), "Dairy/Frozen", "empty lot until bought"),
                         ((20, 560, 760, 940), "Bakery", "empty lot until bought")]
    L.wall(0, 10, 2400, 10)
    L.wall(10, 0, 10, 1580)
    L.wall(2390, 0, 2390, 1580)
    L.wall(0, 550, 1000, 550)
    L.wall(1120, 550, 1800, 550)  # staff door 1000-1120 into the starter shop
    L.gate("Produce", 1800, 550, 1940, 550)  # Produce wing's own back door (opens with it)
    L.wall(1940, 550, 2400, 550)
    L.wall(960, 0, 960, 380)
    L.wall(1440, 0, 1440, 380)
    L.wall(0, 1570, 1420, 1570)  # front wall; door 1420-1600, starter shop's front corner
    L.wall(1600, 1570, 2400, 1570)
    L.gate("Produce", 1630, 560, 1630, 1560)  # knock-out walls
    L.gate("Dairy/Frozen", 770, 960, 770, 1560)
    L.gate("Bakery", 770, 560, 770, 950)
    L.wall(20, 950, 520, 950)  # Bakery | Dairy: a wall with a wide opening 520-760
    for gx in (1000, 1400):  # two gondolas (aisle between them 268 px)
        L.shelf("Dry Goods", gx - 33, 900, "W")
        L.shelf("Dry Goods", gx + 33, 900, "E")
        L.solids.append((gx - 40, 782, gx + 40, 810))
        L.solids.append((gx - 40, 990, gx + 40, 1018))
    for x in (1290, 1470):  # a back-wall run
        L.shelf("Dry Goods", x, 600, "S")
    for x in (840, 990, 1140, 1290, 1440):
        L.registers.append((x, 1500, (0, -1)))
    for y in (700, 880, 1060):
        L.shelf("Produce", 2340, y, "W")
    L.shelf("Produce", 1960, 760, "E")
    L.shelf("Produce", 1960, 1000, "E")
    L.solids += [(1880, 1250, 1924, 1294), (2120, 1300, 2164, 1344)]
    L.lanes.append(((2110, 640, 2160, 1220), "Produce forklift lane"))
    for y in (1060, 1240, 1420):
        L.shelf("Dairy/Frozen", 60, y, "E")
    L.shelf("Dairy/Frozen", 380, 1180, "W")
    L.shelf("Dairy/Frozen", 446, 1180, "E")
    for x in (130, 310, 490):
        L.shelf("Bakery", x, 600, "S")
    L.shelf("Bakery", 60, 800, "E")
    L.shelf("Bakery", 680, 760, "W")
    L.marks += [(1660, 1600, "SIGN", (200, 40, 40))]
    L.no_customer += [(0, 0, 2400, 545)]
    L.spawn = (1510, 1660)
    L.exit = (1510, 1660)
    L.pads = {"Dry Goods": (1200, 1060), "Produce": (2160, 1420), "Dairy/Frozen": (620, 1420), "Bakery": (400, 830)}
    L.notes.append((860, 1290, "queue zone", 18))
    return L


def plan_c():
    """PLAN C - THE ONE-SCREEN MARKET. A compact store whose whole sales floor
    fits one zoomed-out view (camera zoom 0.53 shows 1811 x 1019 world px at
    960x540), so the camera holds still on the floor and every player sees
    everything. In-door and out-door at opposite ends of the front with the
    registers between; back of house behind the back wall is its own screen."""
    L = Layout("Plan C: The One-Screen Market", 1920, 1680)
    L.camera = (1811, 1019)
    L.camera_at = (905, 1030)
    L.zones.append(((0, 0, 960, 540), "break", "BREAK ROOM (unchanged)"))
    storage_block(L, 960, 0)
    L.zones.append(((0, 540, 1800, 1520), "floor", ""))
    L.zones.append(((1800, 540, 1920, 1680), "lot", ""))
    L.zones.append(((0, 1520, 1800, 1680), "outside", "SIDEWALK"))
    L.zones.append(((20, 560, 420, 1080), "Bakery", "BAKERY"))
    L.zones.append(((440, 560, 1340, 880), "Dairy/Frozen", "DAIRY / FROZEN"))
    L.zones.append(((1440, 700, 1780, 1240), "Produce", "PRODUCE"))
    L.zones.append(((480, 990, 1380, 1230), "Dry Goods", "AISLES"))
    L.zones.append(((140, 1380, 1460, 1500), "checkout", ""))
    L.wall(0, 10, 1920, 10)
    L.wall(10, 0, 10, 1520)
    L.wall(1910, 0, 1910, 540)
    L.wall(1790, 540, 1790, 1520)
    L.wall(0, 550, 1340, 550)  # back wall; wide staff door 1340-1520
    L.wall(1520, 550, 1920, 550)
    L.wall(960, 0, 960, 380)  # break room | back room (door 380-540)
    L.wall(180, 1510, 1580, 1510)  # front: OUT door 20-180, IN door 1580-1780
    L.gate("Bakery", 420, 560, 420, 1080)
    L.gate("Bakery", 20, 1080, 420, 1080)
    L.gate("Dairy/Frozen", 440, 880, 1340, 880)
    L.gate("Produce", 1440, 700, 1440, 1240)
    L.gate("Produce", 1440, 700, 1780, 700)
    L.gate("Produce", 1440, 1240, 1780, 1240)
    for x in (110, 290):
        L.shelf("Bakery", x, 600, "S")
    for y in (780, 960):
        L.shelf("Bakery", 60, y, "E")
    L.shelf("Bakery", 300, 1030, "N")
    for x in (530, 710, 890, 1070, 1250):
        L.shelf("Dairy/Frozen", x, 600, "S")
    for y in (790, 970, 1150):
        L.shelf("Produce", 1740, y, "W")
    L.shelf("Produce", 1480, 850, "E")
    L.shelf("Produce", 1480, 1090, "E")
    L.lanes.append(((1590, 760, 1640, 1200), "Produce forklift lane"))
    for gx in (600, 930, 1260):
        L.shelf("Dry Goods", gx - 33, 1110, "W")
        L.shelf("Dry Goods", gx + 33, 1110, "E")
        L.solids.append((gx - 40, 992, gx + 40, 1020))
        L.solids.append((gx - 40, 1200, gx + 40, 1228))
    for x in (220, 470, 720, 970, 1220):  # queues run east along the front, as today
        L.registers.append((x, 1440, (1, 0)))
    L.marks += [(1680, 1540, "IN", (0, 130, 0)), (100, 1540, "OUT", (200, 40, 40))]
    L.no_customer += [(0, 0, 1920, 545)]
    L.spawn = (1680, 1600)
    L.exit = (100, 1600)
    L.pads = {"Dry Goods": (1270, 1310), "Produce": (1610, 1340), "Dairy/Frozen": (890, 815), "Bakery": (280, 830)}
    L.notes.append((500, 1255, "front aisle", 18))
    L.notes.append((1350, 600, "wide staff door", 15))
    return L


# ---------------------------------------------------------------------------
# Measurements
# ---------------------------------------------------------------------------
ORDER = ["Dry Goods", "Produce", "Dairy/Frozen", "Bakery"]
LIST_BY_TIER = [(1, 2), (2, 3), (2, 3), (2, 4)]


def trips(L, owned_n, n=160, seed=7):
    owned = ORDER[:owned_n]
    nav = Nav(L, owned)
    rng = random.Random(seed)
    stands = {}
    for s in L.shelves:
        if not s.dressing and s.section in owned:
            stands.setdefault(s.section, []).extend(s.stand_points(2 if owned_n >= 3 else 1))
    regs = L.registers[: [2, 3, 4, 5][owned_n - 1]]
    shopper, fails = [], 0
    lo, hi = LIST_BY_TIER[owned_n - 1]
    for _ in range(n):
        k = rng.randint(lo, hi)
        secs = [rng.choice(owned) for _ in range(k)]
        pos, total = L.spawn, 0.0
        ok = True
        for sec in secs:
            tgt = rng.choice(stands[sec])
            d = nav.dist(pos, tgt)
            if d is None:
                ok = False
                break
            total += d
            pos = tgt
        if not ok:
            fails += 1
            continue
        best = None
        for (x, y, q) in regs:
            spot = (x + q[0] * 50, y + q[1] * 50) if q[1] == 0 else (x + 50, y - 40)
            d = nav.dist(pos, spot)
            if d is not None and (best is None or d < best[0]):
                best = (d, spot)
        if best is None:
            fails += 1
            continue
        total += best[0]
        d = nav.dist(best[1], L.exit)
        total += d if d is not None else 0
        shopper.append(total)
    # crew: receiving row -> each owned section's pad (player walk, staff doors open)
    crew_nav = Nav(L, owned, for_customers=False)
    crew = {sec: crew_nav.dist(L.receiving, L.pads[sec]) for sec in owned}
    return shopper, fails, crew, nav.open_cells()


def stats(xs):
    xs = sorted(xs)
    return sum(xs) / len(xs), xs[int(len(xs) * 0.9)]


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------
def font(size):
    for p in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf"):
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def draw(L, path, owned=ORDER, scale=0.5):
    W, H = int(L.w * scale), int(L.h * scale)
    im = Image.new("RGB", (W, H + 40), (255, 255, 255))
    d = ImageDraw.Draw(im, "RGBA")
    S = lambda r: [r[0] * scale, r[1] * scale, r[2] * scale, r[3] * scale]
    for r, kind, label in L.zones:
        d.rectangle(S(r), fill=ZONE_FILL.get(kind, (230, 230, 230)))
    for r, label in L.lanes:
        d.rectangle(S(r), fill=(255, 170, 0, 90), outline=(200, 120, 0))
    for r in L.walls:
        d.rectangle(S(r), fill=(40, 60, 110))
    for r, sec in L.gates:
        if sec in owned:
            d.rectangle(S(r), outline=SECTION_COLORS[sec], width=1)
        else:
            d.rectangle(S(r), fill=(150, 30, 30))
    for s in L.shelves:
        col = (160, 160, 160) if s.dressing else SECTION_COLORS[s.section]
        d.rectangle(S(s.rect()), fill=col, outline=(60, 60, 60))
        if not s.dressing:
            for sx, sy in s.slots(1):
                d.ellipse([sx * scale - 3, sy * scale - 3, sx * scale + 3, sy * scale + 3], fill=(60, 60, 60))
    for r in L.solids:
        d.rectangle(S(r), fill=(120, 120, 120), outline=(60, 60, 60))
    for r in L.solids_draw_only:
        d.rectangle(S(r), outline=(190, 150, 0), width=2)
    for (x, y, q) in L.registers:
        r = (x - 30, y - 20, x + 30, y + 20)
        d.rectangle(S(r), fill=(70, 70, 80))
        for k in (50, 90, 130, 170):
            qx = x + q[0] * k + (50 if q[1] != 0 else 0) * 0
            qy = y + q[1] * k
            if q[1] != 0:
                qx = x + 50 if k == 50 else x + 50
                qy = y - 40 - (k - 50)
            d.ellipse([qx * scale - 3, qy * scale - 3, qx * scale + 3, qy * scale + 3], outline=(80, 80, 200), width=2)
    for sec, (x, y) in L.pads.items():
        d.rectangle([(x - 56) * scale, (y - 56) * scale, (x + 56) * scale, (y + 56) * scale], outline=(110, 110, 110), width=2)
    for r, sec, label in L.locked_overlay:
        if sec not in owned:
            w, h = int((r[2] - r[0]) * scale), int((r[3] - r[1]) * scale)
            tile = Image.new("RGBA", (w, h), (60, 60, 60, L.overlay_alpha))
            td = ImageDraw.Draw(tile)
            for i in range(-h, w, 14):
                td.line([i, h, i + h, 0], fill=(255, 210, 0, 110), width=2)
            im.paste(tile, (int(r[0] * scale), int(r[1] * scale)), tile)
    for x, y, label, col in L.marks:
        d.ellipse([x * scale - 5, y * scale - 5, x * scale + 5, y * scale + 5], fill=col)
        d.text((x * scale + 7, y * scale - 7), label, fill=col, font=font(11))
    for r, kind, label in L.zones:
        if label:
            f = font(14)
            d.text(((r[0] + 12) * scale, (r[1] + 8) * scale), label, fill=(30, 30, 30), font=f)
    for r, sec, label in L.locked_overlay:
        if sec not in owned:
            d.text(((r[0] + 12) * scale, (r[1] + 46) * scale), label.upper(), fill=(255, 220, 0), font=font(13))
    for x, y, text, size in L.notes:
        d.text((x * scale, y * scale), text, fill=(90, 90, 90), font=font(int(size * 0.7)))
    d.ellipse([L.spawn[0] * scale - 6, L.spawn[1] * scale - 6, L.spawn[0] * scale + 6, L.spawn[1] * scale + 6], fill=(0, 150, 0))
    # one player's view at the true size
    cw, ch = L.camera
    cx, cy = L.camera_at or (L.spawn[0], L.spawn[1] - ch / 2)
    x0 = min(max(cx - cw / 2, 0), L.w - cw) * scale
    y0 = min(max(cy - ch / 2, 0), L.h - ch) * scale
    for i in range(0, int(cw * scale), 16):
        d.line([x0 + i, y0, x0 + min(i + 8, cw * scale), y0], fill=(255, 0, 200), width=3)
        d.line([x0 + i, y0 + ch * scale, x0 + min(i + 8, cw * scale), y0 + ch * scale], fill=(255, 0, 200), width=3)
    for i in range(0, int(ch * scale), 16):
        d.line([x0, y0 + i, x0, y0 + min(i + 8, ch * scale)], fill=(255, 0, 200), width=3)
        d.line([x0 + cw * scale, y0 + i, x0 + cw * scale, y0 + min(i + 8, ch * scale)], fill=(255, 0, 200), width=3)
    d.text((x0 + 6, y0 + ch * scale - 18), "one player's view (%d x %d)" % (cw, ch), fill=(200, 0, 160), font=font(12))
    d.text((10, H + 10), "%s  —  %d x %d px world; owned: %s" % (L.name, L.w, L.h, ", ".join(owned)), fill=(0, 0, 0), font=font(14))
    im.save(path)


def main():
    layouts = [current(), plan_a(), plan_b(), plan_c()]
    for L in layouts:
        assert L.counts() == current().counts(), (L.name, L.counts())
    files = {"Current: 3x3 grid of rooms": "current_model", "Plan A: The Racetrack": "plan_a",
             "Plan B: Grows Outward": "plan_b", "Plan C: The One-Screen Market": "plan_c"}
    for L in layouts:
        base = files[L.name]
        draw(L, os.path.join(HERE, base + ".png"))
        if L.name.startswith("Plan B"):
            draw(L, os.path.join(HERE, base + "_shift1.png"), owned=ORDER[:1])
            draw(L, os.path.join(HERE, base + "_two_sections.png"), owned=ORDER[:2])
        if L.name.startswith(("Plan A", "Plan C")):
            draw(L, os.path.join(HERE, base + "_shift1.png"), owned=ORDER[:1])
    # What one player sees at 960x540: A and B at zoom 1 (a 960x540 crop at
    # true scale), C at its zoomed-out framing (1811x1019 squeezed to 960x540).
    for L, base in ((layouts[1], "plan_a"), (layouts[2], "plan_b"), (layouts[3], "plan_c")):
        tmp = os.path.join(HERE, "_tmp.png")
        draw(L, tmp, scale=1.0)
        big = Image.open(tmp)
        cw, ch = L.camera
        cx, cy = L.camera_at or (L.spawn[0], L.spawn[1] - ch / 2)
        x0 = int(min(max(cx - cw / 2, 0), L.w - cw))
        y0 = int(min(max(cy - ch / 2, 0), L.h - ch))
        big.crop((x0, y0, x0 + cw, y0 + ch)).resize((960, 540)).save(os.path.join(HERE, base + "_view_960x540.png"))
        os.remove(tmp)
    print("Shelf counts (must match today's):", current().counts())
    print()
    print("| Layout | sections owned | shopper walk avg (px) | avg s @90px/s | 90th pct s | no-route | crew: receiving -> pads (px) |")
    print("|---|---|---|---|---|---|---|")
    for L in layouts:
        for n in (1, 2, 4):
            sh, fails, crew, cells = trips(L, n)
            avg, p90 = stats(sh)
            crew_s = ", ".join("%s %d" % (k.split("/")[0], v) for k, v in crew.items() if v is not None)
            print("| %s | %d | %d | %.0f | %.0f | %d | %s |" % (L.name.split(":")[0], n, avg, avg / CUSTOMER_SPEED, p90 / CUSTOMER_SPEED, fails, crew_s))
    print()
    for L in layouts:
        nav = Nav(L, ORDER)
        print("%s: open nav cells (customers, all owned) = %d of %d; world %dx%d = %.1f screens" % (
            L.name, nav.open_cells(), nav.cols * nav.rows, L.w, L.h, (L.w * L.h) / (960 * 540)))


if __name__ == "__main__":
    main()
