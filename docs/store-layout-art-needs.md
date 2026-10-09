# Shift Work — Plan B art needs list (Phase 5B, Part 2B)

Every visual the Plan B ("Grows Outward") layout needs, for the art session
that follows the greybox build. Written against the layout in
`physics-sync-test/StoreLayout.gd` and the greybox in `StoreArt.gd` /
`StoreGrowth.gd` (report: `docs/store-layout-plan-b-report.md`).

## The scale contract (unchanged from the proposal, section 8)

- **One floor tile = 30 px** on screen. Today's packs are 48 px RPG Maker MV
  tiles drawn at `StoreArt.ART_SCALE` 0.625. A replacement set drawn at
  16, 32 or 48 px works if it's scaled so a floor tile is 30 px.
- **Characters are ~28 px** (LPC, kept).
- **Walls are 20 px thick strips seen from above** (every wall and barrier
  in the table: `StoreLayout.WALL_THICKNESS`). Wall art is a *face* texture
  that tiles along the strip.
- Every size below is world px at that scale. Every position lives in the
  layout table, so art that fits these footprints drops in with **no layout
  change**.

## What can reuse the current "Cute SCKR" tilesets today

The developer is keeping the current packs for now (the supermarket page's
AI Disclosure row reads "AI Assisted – Graphics") and will decide on
replacing them before the Steam page. The greybox build already uses them
wherever a matching piece exists:

| Already covered by the current sets | Where it comes from |
|---|---|
| Shop, checkout, Produce, Dairy/Frozen, Bakery, Storage and break-room floors | `Tile_A2-2.png` blocks (`StoreArt.FLOORS`) |
| Sales-floor walls (blue tile), Storage walls (corrugated metal), break-room walls | `Auto-tile-A4-walls-*.png` faces (`StoreArt`) |
| Shelving bays and products; registers, belts, carts; produce crates; forklift; boxes; dumpster; trash cans | as before (`docs/asset-audit.md` A1–A10) |
| The knock-out walls' closed look | the same blue sales-floor wall face (`StoreArt.market_wall_face()`) |

## What Plan B needs that doesn't exist yet

"Placeholder" = drawn in code today (Polygon2D/Line2D/Label in greybox). All
code-drawn pieces are **placeholders** and are listed here to be replaced;
none is meant to ship.

### Priority 1 — on screen every shift, or the growth moment itself

| # | Piece | Size (px) | Today (greybox) | Notes |
|---|---|---|---|---|
| B1 | **Empty-lot ground** (an unbought wing) | tiling texture; lots are 780 × 1140 (Produce), 780 × 600 (Dairy/Frozen), 780 × 540 (Bakery) | **Placeholder:** dark gravel colour, scattered stones, two tyre ruts (`StoreGrowth.gd`) | Gravel, old asphalt or packed dirt; should read as "outside / not yours" next to the shop's bright floor. Hook: `StoreGrowth.ART["lot_ground"]`. |
| B2 | **Construction fence / hoarding** round a lot | tiling strip, 12 px tall (posts every ~60 px) | **Placeholder:** 3 px grey line with square posts | Chain-link or painted plywood hoarding, top-down. Hook: `ART["fence"]`. |
| B3 | **FOR SALE board** in each lot | 280 × 120 sign + 2 posts (8 × 46) | **Placeholder:** white rect, red "FOR SALE", wing name, price (text drawn by code) | Text stays code-drawn (price changes); art is the blank board. Hook: `ART["for_sale_board"]`. |
| B4 | **FOR SALE banner** on the knock-out wall | 168 × 18, hung along a 20 px wall (turned for vertical walls) | **Placeholder:** red rect with white text | Blank banner; text drawn over. Hook: `ART["banner"]`. |
| B5 | **Knock-out wall breaking** (the growth moment) | the wall in ~60 px chunks; 1.8 s | **Placeholder:** the wall face cut into chunks that tumble and fade + grey dust puffs (code) | Optional: a rubble/dust sprite sheet (4–8 frames, ~60 px) and a "crunch" sound (none added — no new audio this phase). |
| B6 | **Storefront** (the shop's front wall) | 20 px strip along y 1680; the door gap is 200 px (x 1410–1610) | the blue sales-floor wall face | Glass shopfront face for the strip + an **automatic sliding door** frame (200 × 20 top-down, open/closed). |
| B7 | **Checkout counters for north-facing lanes** | counter 40 × 60 (the 60 × 40 counter turned); belt runs north–south | **Placeholder:** the side-view lane sprite from `1.png` turned 90° (reads as a lane, but the register and bags are on their side) | A top-down vertical lane: counter + belt + register, red and blue variants, plus a belt segment that tiles vertically. |
| B8 | **Sidewalk + parking** | the pavement strip 2400 × 180 (y 1680–1860) | flat grey (`SidewalkBg`) | Pavement tile, kerb, a few parking bays' white lines (30 px grid). |

### Priority 2 — seen often, small

| # | Piece | Size (px) | Today | Notes |
|---|---|---|---|---|
| B9 | **Roller shutter** (Produce's back door into Storage, closed until Produce is bought) | 200 × 20 strip, tiling | **Placeholder:** grey strip with a slat line | Hook: `ART["shutter"]`. Open = gone (a doorway). |
| B10 | **Staff door frame** ("Employees Only") between the staff hall and the shop | 200 px opening in a 20 px wall (x 1000–1200, y 540) | a gap in the wall | Swing doors or a frame + sign. |
| B11 | **Staff hall floor** | 480 × 540 | the back room's concrete A2 block (`StoreArt.FLOORS["StaffHallBg"]`) | Covered by the current set; listed so a new set includes a back-of-house floor. |
| B12 | **Overhead department signs** (DRY GOODS, PRODUCE, DAIRY / FROZEN, BAKERY, CHECKOUT) | ~200 × 40 hanging signs | text labels (`SectionLabels` in `Main.tscn`) | Hanging boards behind the existing text, or text baked in. |
| B13 | **Lane numbers and "lane closed" signs** | ~24 × 24 number plates; ~40 × 30 sign | none (a closed lane's counter is hidden, as before) | Shows that lanes 3–5 exist but are dark in the small shop. |
| B14 | **Forklift lane marking** (Produce, north–south) | 44 × 1120 strip (yellow/black edge lines) | none | Floor paint; tells players where the forklift runs. |
| B15 | **Forklift seen from behind** | ~71 × 92 (like the front view) | the side view is shown when it drives north | The Produce forklift now drives north–south; front view exists (driving south), back view doesn't. |

### Priority 3 — nice to have

| # | Piece | Size (px) | Notes |
|---|---|---|---|
| B16 | Gondola **end caps** (a short display at each end of the shop's two gondolas) | ~80 × 28 | Not built (would add nav obstacles at the aisle mouths; the proposal named them as stuck-point risks). |
| B17 | Cooler-case look for Dairy/Frozen's wall run, bakery cases for Bakery | shelf footprint 180 × 66 | Today all shelves use the same metal bays, tinted per section. |
| B18 | Exterior wall face for the building's outside (east, west, back) where it borders the world edge | 20 px strip | Today these use the room's interior wall face. |
| B19 | Car-park dressing on the pavement (trolley bay, bollards) | ~30–60 px pieces | Decoration only. |

## Designing for the swap (what's already a data change)

- **Floors and walls:** `StoreArt.FLOORS` (room floor → A2 block) and the
  wall-face constants pick every texture. A new set = new paths/blocks there.
- **Growth placeholders:** `StoreGrowth.ART` — put a `res://` path in an
  entry and that placeholder is replaced; empty = the code-drawn greybox.
  Nothing else changes.
- **Positions and footprints:** all in `StoreLayout.gd` (rooms, walls,
  barriers, pads, cans, anchors, the checkout). If a new set's shelf or
  counter footprint differs, it's an edit to the table and the scene's
  shelf/register instances, and the guard tests (`areas-snapshot`,
  `growth`, `checkout`) say whether it still fits.
- **Gameplay footprints the art must keep** (unchanged): shelf 180 × 66 with
  slots 70/126 px out; register counter 60 × 40; forklift 92 × 44; display
  44 × 44; unpack pad 112 × 112; dumpster 110 × 56; box 44; walls 20 px.
