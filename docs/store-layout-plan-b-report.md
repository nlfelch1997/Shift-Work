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

(pending: table)

## 3. Systems changed

(pending)

## 4. Camera and readability

(pending)

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
