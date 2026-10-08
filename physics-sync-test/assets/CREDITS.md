# Art credits — Break Room (Week 23)

Credits for the art added in the Week 23 Break Room pass. The older packs
under `supermarket/` and `warehouse/` are at the end of this file: their
source is UNRESOLVED.

| Files | Used for | Source | Author | License |
|---|---|---|---|---|
| `breakroom-furniture/PixelFurniture.png` | Break Room furniture: fridge, sink counter, coffee-machine cabinet, binder shelf, cubby shelf, staff lockers, table + chairs, armchairs (`BreakRoom.gd`) | Pixel Furniture pack (source URL: **TODO — not recorded**) | Kelano Studio | Free for commercial use, no attribution required — credited as a courtesy |
| `vending-machines/*.png` (only `Vending Machine 2.1.png` is used) | Break Room vending machine (`BreakRoom.gd`) | Pixel Art Vending Machines (source URL: **TODO — not recorded**) | karsiori | CC0 |
| `breakroom-furniture/Employee of the Month.webp` | Break Room "Employee of the Month" photo | Supplied by the project owner (signed "Big Papa Felch") | — | Project-owned |

Notes:
- `breakroom-furniture/preview.webp` is currently a byte-for-byte copy of the
  Employee of the Month photo, not the furniture pack's reference sheet.
  Nothing uses it.
- The furniture sheet holds 20 objects (a 5x4 grid of 32px cells), not 30.
  It has no coffee machine, so the brewer on the counter is placeholder art
  drawn in code (`BreakRoom.gd`'s `_build_coffee_machine()`).

# Character sprites (Week 25)

| Files | Used for | Source | License |
|---|---|---|---|
| `characters/customer_1..6.png` | Customers — six everyday looks, dealt from a shuffled deck per spawn (`Customer.gd`, `Main.gd`) | Universal LPC Spritesheet Character Generator | CC-BY-SA 3.0 (see below) |
| `characters/cashier_1..5.png` | The register cashiers — one fixed look per register, store uniform (`Cashier.gd`) | same | same |
| `characters/player_1..4.png` | Players — the same store uniform, one face per player slot (`Player.gd`) | same | same |
| `characters/manager.png` | The manager — one fixed look, charcoal suit + red tie (`Manager.gd`) | same | same |
| `characters/driver_produce.png`, `driver_delivery.png` | The forklift drivers (Week 26) — one fixed driver per forklift, warehouse crew: yellow hard hat, safety-yellow overalls (`Forklift.gd`, `DeliveryForklift.gd`) | same | same |

Made with the generator's own "ZIP: Split by animation" export (only the walk
sheet is used; for the forklift drivers, only the seated-on-a-chair frame of
the sit sheet) — the exact selection for every look is in
`tools/lpc/looks.json`, the steps in `tools/lpc/`. The staff name tag (3x2 white
pixels on the polo) was added afterwards by `tools/lpc/post.py`.

Every layer's authors, license options and source links, per file, as the
generator exported them: `characters/CREDITS-LPC.csv`. Most layers are offered
under OGA-BY 3.0 (some CC0), but several — the manager's suit coat, formal shirt
and necktie, and a few hairstyles/facial hair — are CC-BY-SA 3.0 / GPL only, so
the finished sheets are distributed as **CC-BY-SA 3.0** (OGA-BY/CC0 parts may be
combined into a CC-BY-SA work).

Credits-screen / Steam-page text:

> Character sprites made with the Universal LPC Spritesheet Character Generator
> (https://github.com/liberatedpixelcup/Universal-LPC-Spritesheet-Character-Generator),
> used under CC-BY-SA 3.0 (https://creativecommons.org/licenses/by-sa/3.0/).
> Art by Stephen Challener (Redshrike), Johannes Sjölund (wulax), Matthew Krohn
> (makrohn), bluecarrot16, Benjamin K. Smith (BenCreating), Eliza Wyatt (ElizaWy),
> JaidynReiman, Evert, TheraHedwig, MuffinElZangano, Durrani, Pierre Vigier
> (pvigier), Lanea Zimmerman (Sharm), Manuel Riecke (MrBeast), Joe White, Nila122,
> Carlo Enrico Victoria (Nemisys), Thane Brimhall (pennomi), Mandi Paugh,
> laetissima, thecilekli, William.Thompsonj and Napsio (Vitruvian Studio). Full per-file credits and source
> links: CREDITS-LPC.csv. Sprite sheets lightly modified for Shift Work (name tag).

# UNRESOLVED — the supermarket and warehouse tile packs (Phase 5 audit)

| Files | Used for | Source | License |
|---|---|---|---|
| `supermarket/Tile_A2-2.png`, `supermarket/Auto-tile-A4-walls-3.png`, `supermarket/1.png`, `2.png`, `4.png`, `11.png` (and unused `3.png`, `5.png`-`10.png`) | Floors, sales-floor walls, shelving bays, every product sprite, litter, trash bins, checkout lanes, carts, the store sign board, the time clock, produce crates (`StoreArt.gd`, `Customer.gd`, `Cleanup.gd`, `Main.gd`, `Delivery.gd`) | **UNKNOWN** — RPG Maker MV-format "supermarket" pack | **UNKNOWN** |
| `warehouse/Auto-tile-A4-walls-2.png`, `warehouse/Auto-tile-A4-walls-3.png` (a copy of the supermarket one), `warehouse/tile-B-03.png`, `tile-B-04.png`, `tile-B-05.png` (and unused `tile-B-01.png`, `tile-B-02.png`) | Storage walls, the tool station, both forklifts, pallets and delivery boxes (`StoreArt.gd`, `Cleanup.gd`, `Forklift.gd`, `Delivery.gd`) | **UNKNOWN** — RPG Maker MV-format "warehouse" pack | **UNKNOWN** |

What the repository shows (Phase 5, Oct 2026): both packs arrived in one
commit by the project owner (`d1b8678`, "Add warehouse and supermarket tileset
assets for art integration pass", 26 Sep 2026) with no license file, readme,
store page or author name, and the PNGs carry no metadata. Nothing else in
the history names a source. **To resolve:** find the purchase receipt or store
page, record the pack names, authors, URLs and license terms here, and confirm
the art is hand-made. `docs/asset-audit.md` (rows A1-A11) explains why
that last point matters.

# Also to confirm

- `breakroom-furniture/Employee of the Month.webp` (the break-room portrait):
  "supplied by the project owner". Who made the image and how, and, if it
  depicts a real person, their permission. See `docs/asset-audit.md` row A14.
- No app/window icon is set (`project.godot` has no `config/icon`), so
  exports use Godot's default icon.
