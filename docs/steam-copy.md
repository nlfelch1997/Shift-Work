# Shift Work — Steam page copy (DRAFT)

Draft only: nothing here has been published. Every claim below is something
the current build actually does. Before using it, check the bracketed notes.

## One-line pitch

A chaotic co-op supermarket sim: stock the shelves, dodge the forklift, look
busy for the manager, and grow a one-aisle shop into a whole store, one shift
at a time.

## Short description (Steam "short description", max 300 characters)

Run a supermarket with up to four friends. Haul deliveries, stock shelves,
keep the floor clean and dodge a forklift with no brakes, all while the
manager watches for anyone standing still. Every shift's pay goes in the
bank: buy new sections, hire helpers and grow the shop.

(276 characters.)

## Long description ("About This Game")

**Clock in. The store opens when you say so.**

Every shift starts with the doors locked. Trucks back up to the loading dock,
the forklift unloads the pallets, and it's on you to haul the crates to the
unpack pads, rip them open and get every shelf stocked. Flip the sign when
you're ready. The sooner you open, the longer you sell.

**Then the customers arrive.**

Shoppers walk in with shopping lists, fill their carts and queue at the
registers. Some of them knock your stock straight off the shelves, so grab
the troublemakers and walk them out the front door. Meanwhile the forklift
does laps of the Produce aisle and rams anything in its way, shelves
included. And the manager walks the floor, writing up anyone he catches
standing still.

**Close up, clean up, get paid.**

When the store closes, mop the spills, sweep the litter, haul the full trash
bags out to the dumpster and clock out. The shift's pay goes into the crew's
shared bank. Keep the store clean and the rating climbs. A higher rating
brings in more customers who pay more.

**Grow the shop.**

Start with one aisle of Dry Goods and buy your way up to Produce,
Dairy/Frozen and the Bakery. Hire a helper for each section and a janitor for
the whole store, then train them up. Kit the crew out at the gear lockers:
comfy sneakers, a back brace, non-slip soles and steel-toe boots. As the shop
grows, so does the chaos: priority orders, bad wiring and leaks, lunch rushes,
surprise inspections and surprise deliveries.

**Better with friends.**

Play solo, or with up to four people in online co-op. One player hosts the
shop and friends join over the internet or LAN. Everyone shares one bank and
one store, and everyone takes the blame.

## Feature bullets

- **1-4 player online co-op**, or play solo. One shared shop, one shared bank.
- **Physical, hands-on stocking.** Carry crates, unpack them and put every
  item on the shelf yourself. Throw things if you're in a hurry.
- **A store that grows.** Three more sections to buy, helpers and a janitor to hire
  and train, and a gear shop for the crew.
- **Hazards that grow with it:** a forklift that rams shelves, a manager who
  writes you up for standing around, rush orders, flickering lights and
  spills.
- **Random events:** Lunch Rush, Surprise Inspection, Leaky Roof, Catering
  Order and Surprise Delivery, each with a bonus if you pull it off.
- **A store rating to protect.** Trash, spills and overflowing cans drag it
  down; a clean store earns more.
- **A guided practice shift** teaches the job before your first real shift.
- **Keys you can rebind**, volume controls, fullscreen and a pause menu.

## Notes for the developer (not page copy)

- [Player count] 1-4 matches `Net.MAX_PEERS` (4). Change the copy if that
  changes.
- [Online] Joining is by IP address today: a VPN/LAN or a forwarded port. If
  Steam networking or a lobby browser isn't added before launch, keep the
  wording "over the internet or LAN" (true now) and don't promise
  "matchmaking" or "Steam invites".
- [Price] Planned $9.99 (maybe $7.99) with a launch discount around $5.99.
  Nothing here mentions price.
- [Length] The balance targets aim at roughly 25-35 shifts (about 4-6
  hours) before everything is bought, then open-ended play. Don't promise an
  hour count until playtests confirm it.
- [AI disclosure] See `docs/asset-audit.md`. The page's content survey asks
  whether the game contains AI-generated content. Answer it only once the
  audit's open items are settled.
- [Demo] The demo build ends after 4 shifts with a wishlist screen
  (`Pacing.gd`). A line like "Play the first four shifts free in the demo"
  fits the demo page.
