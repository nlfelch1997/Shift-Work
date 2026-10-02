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
