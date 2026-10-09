# Shift Work — Phase 5B Part 2B: Plan B ("Grows Outward") in greybox (report)

DRAFT — sections marked (pending) are filled at the end of Stage 4.

## 1. What was built

### The store (all four sections bought)

![Plan B, every wing open](store-layout-plan-b/shot_d7_store.png)

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

World 2400 × 1860 (was 2880 × 1620). Everything is in
`physics-sync-test/StoreLayout.gd`: the rooms, **the walls and knock-out
barriers (new: the structure is built from the table at start-up, nothing
hand-placed in `Main.tscn`)**, pads, cans, anchors, the checkout, the
manager's stops. `Main.tscn` keeps the 21 shelves, 5 registers, 2 displays,
labels and floor polygons (scene instances), and `tools/areas_test.gd`
checks them against the table on every regression run.

(pending: per-stage screenshots and the rest of the report)
