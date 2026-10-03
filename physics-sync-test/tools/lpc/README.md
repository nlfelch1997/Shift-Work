# Character sprites — how they were made (Week 25)

Every sheet in `assets/characters/` came out of the real
[Universal LPC Spritesheet Character Generator](https://liberatedpixelcup.github.io/Universal-LPC-Spritesheet-Character-Generator/),
driven by script so the looks can be regenerated or tweaked:

1. `mklooks.py` writes `looks.json` — one generator selection (the same string
   the generator keeps in its URL hash) per look. Paste any of them after
   `#` on the generator's page to see/edit that character by hand.
2. `gen.mjs` (Node + Playwright) opens the generator for each look, presses its
   own **ZIP: Split by animation** and **Credits (CSV)** buttons and keeps the
   downloads. It expects the generator running locally (clone its repo,
   `npm ci`, `npx vite --port 5199`), since that's scriptable; the public page
   works the same by hand.
3. `post.py` keeps the 9 used columns of each `walk.png` (standing frame + the
   8-frame walk; rows = up, left, down, right) and stamps the white name tag on
   the staff polo (cashiers + players).

Credits: the generator's per-look CSVs merged into
`assets/characters/CREDITS-LPC.csv`; summary and Credits-screen text in
`assets/CREDITS.md`.

   Forklift drivers (`driver_*`, Week 26) never stand up, so `post.py` keeps only
   the seated-on-a-chair column of their `sit.png` instead (64x256: one frame per
   facing). Regenerate just those: `node gen.mjs looks.json driver_produce`, then
   `python3 post.py ../../assets/characters driver_produce driver_delivery`.

Uniform rule (legible at a glance): staff (cashiers + players) = bright green
polo, charcoal pants, name tag; manager = charcoal suit coat, white shirt, red
tie; customers = everyday clothes, never green tops; warehouse crew (forklift
drivers) = yellow hard hat, safety-yellow overalls over charcoal long sleeves,
work boots.
