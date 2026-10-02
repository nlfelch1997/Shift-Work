# Art credits — Break Room (Week 23)

Credits for the art added in the Week 23 Break Room pass. (The older art
packs under `supermarket/` and `warehouse/` aren't listed here yet.)

| Files | Used for | Source | Author | License |
|---|---|---|---|---|
| `breakroom-furniture/PixelFurniture.png` | Break Room furniture: fridge, sink counter, coffee-machine cabinet, binder shelf, cubby shelf, staff lockers, table + chairs, armchairs (`BreakRoom.gd`) | Pixel Furniture pack | Kelano Studio | Free for commercial use, no attribution required — credited as a courtesy |
| `vending-machines/*.png` (only `Vending Machine 2.1.png` is used) | Break Room vending machine (`BreakRoom.gd`) | Pixel Art Vending Machines | karsiori | CC0 |
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

Made with the generator's own "ZIP: Split by animation" export (only the walk
sheet is used) — the exact selection for every look is in
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
> laetissima, thecilekli and William.Thompsonj. Full per-file credits and source
> links: CREDITS-LPC.csv. Sprite sheets lightly modified for Shift Work (name tag).
