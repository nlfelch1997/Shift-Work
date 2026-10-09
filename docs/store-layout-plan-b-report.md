# Shift Work — Phase 5B Part 2B: Plan B ("Grows Outward") in greybox (report)

Branch `claude/phase-5b-2b-plan-b`, off `main` at `95a2fa3` (Part 2A, PR
#39, confirmed merged with `git log --merges` before starting).

**In one paragraph.** (pending)

---

## 1. What was built

### The store

```
  y 0 ┌──────────────┬────────┬──────────────────────┐
      │ BREAK ROOM   │ STAFF  │ STORAGE (back room)  │  back of house:
      │ (unchanged)  │ HALL   │ dock on the east wall│  no shoppers
  540 ├────────┬─────┴─door───┴──┬─back door─┬───────┤
      │ BAKERY │  DRY GOODS      │  PRODUCE  wing    │
      │ wing 4 │  (the starter   │  (wing 2)         │
 1080 ├─open───┤   corner shop)  │  forklift lane    │
      │ DAIRY/ │                 │  runs north–south │
      │ FROZEN ├─────────────────┤                   │
      │ wing 3 │  CHECKOUT (hub) │                   │
 1680 └────────┴──────door───────┴───────────────────┘
        SIDEWALK + parking (shoppers arrive and leave by the door)
 1860   x 0     780            1620               2400
```

- **World 2400 × 1860** (was 2880 × 1620). The break room is exactly where
  it was; Storage moved as one block to the back-right (`STORAGE_ORIGIN`
  (1440, 0), every back-room number relative to it); a **staff hall**
  joins them and opens into the shop through a 200 px **staff door**.
- **The starter shop** (x 780–1620) is Dry Goods — two gondolas (two
  shelves back to back each) and a two-shelf run on the back wall — and
  the **checkout**, 5 lanes along the front whose **queues run north into
  the store**. The **front door** (200 px) is at its front-right corner.
- **Produce** (wing 2, east, 780 × 1140): a three-shelf run on the outside
  wall, a two-shelf row facing it, the **forklift lane north–south**
  between them, the sample table on the lane and the sale bin; its pad by
  its **own back door into Storage** (a roller shutter until bought).
- **Dairy/Frozen** (wing 3, south-west, 780 × 600): a three-shelf cooler
  run on the outside wall and a two-shelf island.
- **Bakery** (wing 4, north-west corner, 780 × 540): four shelves on the
  back wall and one on the outside wall; open to the shop **and** to the
  Dairy wing (a 240 px opening).
- Same totals as before: **21 shelves (6/5/5/5), 5 registers (2/3/4/5 open
  by tier), 5 trash cans in save order, 4 pads, the dumpster, the
  delivery forklift's lane, the truck, the Staff Board in the Break Room.**

**Where it lives.** `physics-sync-test/StoreLayout.gd` holds all of it:
rooms (with their open/closed rules, links, the manager's stops, spawn and
helper bands), **the walls and the knock-out barriers** (new this part:
Main.gd builds them from the table at start-up — nothing structural is
hand-placed in `Main.tscn` any more, so the table and the walls can't
drift), pads, cans, anchors and the checkout. `Main.tscn` keeps the scene
instances (21 shelves, 5 registers, 2 displays, labels, floor polygons) and
the guard test `areas-snapshot` checks every one against the table.

### Growth stages (screenshots: section 1.1)

| Stage | Owned | What's there |
|---|---|---|
| 1 (a new game) | Dry Goods | The corner shop and the back of house. Three **empty lots** (gravel, a construction fence, a FOR SALE board with the price) behind the shop's outside walls, which carry **FOR SALE banners**. 2 lanes open. |
| 2 | + Produce ($600) | The shop's east wall comes down; the Produce wing and its back door to Storage are open. The Produce forklift starts its north–south laps. 3 lanes. |
| 3 | + Dairy/Frozen ($2,500) | The shop's west wall (front half) comes down. 4 lanes. |
| 4 | + Bakery ($6,000) | The west wall's back half and the Dairy wing's opening into Bakery come down. 5 lanes. |

**The moment.** Buying a section (prep only, at the wall, as before) plays
a 1.8 s greybox knock-out on every connected peer: the wall shakes,
breaks into ~60 px chunks that tumble into the new wing with dust puffs,
and the lot fades to show the wing behind it (`StoreGrowth.gd`, driven by
the registry's `area_opened` hook). A peer that joins later, a reloaded
save or the end of the practice shift just shows the grown store.

**Replication.** Unchanged in kind: the host decides (`buy_section()`,
purchase by RPC with the host checking the buyer stands at the wall), the
replicated `sections_owned` opens the barriers on every peer
(`_configure_gates()`), and the knock-out plays only for a purchase the
host announced. No new network state; **no save change (still v6)**.

(pending: screenshots)

## 2. Deviations from the proposal, and why

The proposal's Plan B (`docs/store-layout-proposal.md` §3, the diagrams
from `layout_model.py`) was followed in shape: corner shop with the
checkout along the front and the door at its front-right corner, Produce to
the right with its own back door, Dairy/Frozen then Bakery to the left,
back of house along the whole back, nothing ever moves. Every change to the
exact shapes, and why:

| # | Proposal | Built | Why |
|---|---|---|---|
| 1 | World 2400 × 1740; sales floor ~1000 px deep | **2400 × 1860; sales floor 1140 deep** (y 540–1680) | Bakery's wing in the model (740 × 380) had no ~300 × 300 patch for its unpack pad clear of its shelves' slots, and three cooler shelves didn't fit Dairy's outside wall. 120 px more depth fixes both. Open floor rises a little above the proposal's 93 % of today's. |
| 2 | Bakery 740 × 380, Dairy 740 × 600 | **Bakery 780 × 540, Dairy 780 × 600** | Same reason. The 240 px Bakery↔Dairy opening is kept. |
| 3 | The Bakery↔Dairy opening left open (the model had no barrier there) | **A Bakery barrier piece across it** | Dairy/Frozen is bought before Bakery, so with Dairy open the opening would have let shoppers into the unbought Bakery lot. Several barrier pieces per section is the "barrier segments" step the proposal planned. |
| 4 | Bakery: 3 shelves on the back wall + 1 on the outer wall + 1 on the wall facing the shop | **4 on the back wall + 1 on the outer wall** | The shop-facing one would have stood with its back to the knock-out wall, i.e. to open floor once Bakery is bought. |
| 5 | Registers at x 840–1440, 150 apart | **x 850–1350, 125 apart; lane 1 (first to open) nearest the door** | At 150 apart the fifth counter stood in the 200 px door. 125 leaves a 64 px walk-through between a counter and the next lane's cashier. |
| 6 | Dry Goods pad between the gondolas (1200, 1060) | **(1200, 1230), south of the gondolas** | Between them its spill ring (80–150 px) lands on the gondolas' slot rows. |
| 7 | Gondola centre y 900 | **y 950** | Leaves a 90 px cross-aisle under the back-wall shelves' standing spots (the model's was ~50 px). |
| 8 | Gondola end caps | **Not built** | The proposal flagged their mouths as stuck-point risks; nothing in the game needs them. Listed for the art pass (B16). |
| 9 | Produce: 2 shelves on its west row at y 760 / 1000; pad at (2160, 1420) | **West row at y 880 / 1060 (level with the east row's), pad at (1790, 700) by the back door** | The forklift's lap visits "stations" along its lane; aligned rows give it the old pattern (stations with a shelf on each side). The pad by the back door makes the crew's carry from Storage short (that's the plan's carry win). |
| 10 | Staff door 1000–1120, "widen to 200 in Part 2" | **200 px (1000–1200)** | As the proposal asked. Break room ↔ hall and hall ↔ Storage doorways are 230 px. |
| 11 | The shop's tool rack (not placed in the proposal) | **Free-standing on the shop's west side, south of the aisles (850, 1300)** | First placed by the staff door; the upkeep tests showed fetching the broom then lost to sweeping by hand (the rack was ~990 px from the checkout's mess, vs ~540 in the old hub). Moved back to ~540. |
| 12 | Manager "lookouts per wing" | **Every room's waypoint and lookouts are in the table**, his checkout stop (and start) inside the door | He walks straight lines with no collision; the old centre-to-centre legs would cross Plan B's shelves. `growth_test` ray-checks every leg. |
| 13 | Spill/stock bands "per area" | **Each wing's band is open floor chosen in the table**; Produce's spans the wing's south half across the lane | A first, narrow Produce band put a Leaky Roof's leaks close together and the janitor alone finished it (the event is meant to need the crew). |

**Nothing in the plan had to be abandoned.** No stuck-AI problem needed a
different room shape: every stage's nav grids have every open slot
reachable, no closed lot reachable and no cut-off pocket of floor
(`growth_test`), and the shopper traffic test has 0 stuck shoppers.

## 3. Systems changed

(pending)

## 4. Camera and readability

**Decision: no camera change.** Each player keeps their own camera,
following them at zoom 1 and limited to the whole world (`Player.gd`, limits
from `StoreLayout.WORLD`). The window stays 960 × 540 with `canvas_items`
stretch, so fullscreen shows the same 960 × 540 world area, larger.

Why, from the clip shots (host + 2 clients, a selling crowd on stocked
shelves, every helper hired, an event running, the host's own camera with
the HUD on, at every growth stage):

- **Stage 1 (the corner shop):** the shop is 840 px wide, so one view
  holds its whole width — the checkout, the aisles' south ends and both
  outside walls with their FOR SALE banners. This is the best early
  readability the store has had: three players and the crowd in one
  frame.
- **Stages 2–4:** a view holds about one wing, the same as one old room
  did. Players, shoppers with carts and list bubbles, helpers (name tags),
  the manager's cone, the forklift and spills all read at 960 × 540, as
  they did. Events are still announced by the HUD banner, whatever a
  player is looking at.
- **Zooming out was rejected** for the reason the proposal rejected Plan C:
  at ~0.5 the art and text are too small at 960 × 540. Nothing in Plan B
  needs it — the biggest store (2400 × 1140 of sales floor) is smaller
  than the old one's (2880 × 1080 of rooms).
- **The camera can see the unbought lots** (limits are the world, not the
  open store): the lots advertise what's next, and the knock-out happens
  on screen for anyone near.

(Screenshots: section 1.1, `docs/store-layout-plan-b/shot_clip_*`.)

## 5. Balance: before / after

(pending)

## 6. Soak and performance

(pending)

## 7. Regression

(pending)

## 8. Art needs

`docs/store-layout-art-needs.md`.

## 9. Deferred

(pending)

## 10. Found along the way

(pending)

## 11. What to look at when playtesting

(pending)
