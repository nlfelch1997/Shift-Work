# Shift Work — Phase 5 report: polish, balance and pacing

Branch `claude/shift-work-phase-5-polish-q4i9ak`, off `main` after Phase 4C
(PR #36, merged — checked with `git log --merges` before starting).

## 1. What was built

- **Shift N wording everywhere.** The 7-day "Day N"/week framing is gone from
  every player-facing string (list in section 2). Window title is "Shift Work".
- **Main menu restructure** (`MainMenu.gd`): title, Continue (only with a
  save, shows its shift and bank), New Game (asks before replacing a save,
  keeps a `.prev.bak` copy), Play Together (Host Co-op / IP / Join Co-op),
  Practice Shift, Settings, Credits, Quit, and Wishlist on Steam in the demo
  build only.
- **Demo cap** (`Pacing.gd`): the shift-4 report's Continue becomes "Finish
  Demo" and ends play with a thanks / wishlist screen on every peer.
- **Open-early hint**: the prep line explains that unused prep becomes
  selling time, and turns into a nudge (plus one toast a shift) once the
  shelves are stocked; the practice shift's last card teaches it.
- **"Janitor's Kit" gear renamed "Cleaning Cart"** (save key unchanged).
- **One key set for everyone**: a joined player now uses the host's WASD/E/F/C
  keys by default; the arrow set is a per-PC option.
- **Helper/forklift fix**: a helper caught inside the forklift's body now
  leaves by the shortest way and never walks through it (the likely cause of
  Phase 4B's 8 overlap frames), with a deterministic test.
- **Prep line** moved clear of the HUD corners and wraps (it ran under the
  status line and the rating panel).
- **Balance pass** against the pacing target, measured with bot crews
  (section 3).
- **Docs**: `docs/steam-copy.md` (draft store copy), `docs/asset-audit.md`
  (every asset, origin, keep/replace), CREDITS.md gaps marked UNRESOLVED.
- **Tools**: `tools/phase5_test.gd` (menu, demo cap, hint, gear rename,
  forklift escape/watch, screenshots); `staff_test.gd --test=progress` (a
  bot crew plays from a fresh shop and spends by a written policy,
  shifts-to-milestone measured; resumable after a crash); `--open-rule=typical`
  for the bot; `run_regression.sh` can resume (`RESUME=1`); the soak prints
  node counts per subtree.

## 2. Strings and names changed

| Where | Before | After |
|---|---|---|
| HUD status line | `Day N · Bank $X · 1 player` | `Shift N · Bank $X · 1 player` |
| Report title | `Day N Complete!` | `Shift N Complete!` |
| Welcome-back toast | `Welcome back — Day N · Bank $X` | `Welcome back — Shift N · Bank $X` |
| Pause menu info | `Day N is over and saved.` / `Day N — prep (store closed).` / … | `Shift N is over and saved.` / `Shift N — prep (store closed).` / … |
| Mid-shift quit warning | "Today's shift isn't saved … from Day N's shift so far will be lost, and next time you host the crew starts Day N again from the last save." | "This shift isn't saved … from Shift N so far will be lost, and next time you host, the crew replays Shift N from the last save." |
| Quit at report (co-op) | `Day N is saved.` | `Shift N is saved.` |
| Practice prep line | "…Flip the sign at the entrance to start Day 1." | "…to start your first real shift." |
| Practice "Open the store" card | "…flip the STORE SIGN ({interact}) to start Day 1." | adds the open-early lesson; "…now to start your first real shift." |
| Prep line | "PREP — store closed. Opens by itself in m:ss. Flip the sign at the entrance to open early." | "PREP — store closed, opens by itself in m:ss. Open early: unused prep = selling time." / stocked: "PREP — shelves stocked! Flip the sign to open early: m:ss more selling time." |
| New toast | — | "Shelves are stocked — open early! Prep you don't use becomes selling time." |
| Gear | Janitor's Kit | Cleaning Cart |
| Menu buttons | Host Game, Practice Shift, "Host IP (blank = this PC):", Join, Settings, Quit | SHIFT WORK title; Continue · Shift N · Bank $X; New Game; Play Together (Co-op) → Host Co-op / "Join a friend — their IP (blank = this PC):" / Join Co-op / Back; Practice Shift; Settings; Credits; Quit; Wishlist on Steam (demo) |
| Settings > Controls | columns "Hosting / solo" / "Joined a game"; intro about hosting vs joining | "Your keys" / "Second set"; a "Use the second set (arrow keys) on this PC" box |
| Window title | ShiftWork Physics Sync Test (project name) | Shift Work (set at runtime) |
| Scene defaults (`Main.tscn`) | "Day 1 Complete!", "Week Total: 0", "Day 1" | "Shift 1 Complete!", "Bank: $0", "Shift 1" |

Kept on purpose: "Pay Today" / "Sold Today" / "TODAY $X" (one shift is a
working day; nothing in them assumes a week). `project.godot`'s
`config/name` stays "ShiftWork Physics Sync Test": it names the `user://`
folder that every existing save and settings file lives in, and renaming it
would orphan them. Change it only together with a save migration.

**"Survive Your First Week" was not in the repository** (no title text, no
subtitle, nothing in history): the main menu had no title at all. It now has
a plain-text "SHIFT WORK" title (no logo).

Stale code fixed: `tools/art_shots.gd` referenced the removed
`PRIORITY_ORDER_START_DAY` (it would have errored at runtime); `Cashier.gd`'s
comments said the register count followed `current_day` (it follows the open
sections); a reading note at the top of `Main.gd` explains that the dated
"WEEK N / Day N" log entries describe the old story and names the removed
`*_START_DAY` constants.

## 3. Balance pass

### How it was measured

- **Bot crew = "typical crew"** (`--open-rule=typical`): opens the store once
  the open shelves are 75 % stocked (the hint's threshold) or half the prep
  ceiling has passed, whichever comes first; answers events
  (`--event-brain`); doesn't clean mid-shift unless an event asks
  (inspection, leak). That's an assumption about real crews, not a
  measurement of them. The bot's own rule (opens at 90 % full) is reported
  as "competent".
- **Purchase policy** (written in `staff_test.gd`'s PROGRESSION header): next
  section as soon as affordable; with helpers, hire each owned section's
  helper and then the janitor as soon as affordable; once the whole store and
  crew are in, training and gear, cheapest first.
- Per-state income runs (`--test=income`, 2 shifts each, solo and 2 players)
  fed a small purchase-policy model to pick prices; then **full progression
  runs** (`--test=progress`, solo / 2 / 3 players, events on) validated them.
- Bot sims run with `--fixed-fps 60` (as their headers document). Co-op runs
  cap every process at `--max-fps 90` so peers run at the same rate. One run
  per configuration: expect ±1-2 shifts of noise per milestone.

### Before / after — every changed number

| Constant | Before | After | Why |
|---|---|---|---|
| `Main.PREP_CEILING_PER_SECTION` | 180 s | **90 s** | The day's clock is ceiling + selling, so a full store's shift ran ~15 min (30 shifts ≈ 7.5 h against the 4-6 h target), and a crew opening early turned up to 9 min of unused prep into selling time — 3-6x a late opener's income, the main reason crews owned everything by shift 4-6. Now a full store's shift is ~10.5 min and opening early is still the biggest lever. |
| `StoreRating.FALL_PER_SEC` / `RISE_PER_SEC` | 1/60, 1/90 (a star a min down, 1.5 min up) | **1/120, 1/180** | Tuned for a 111 s selling window; early openers sell 4-6 min, and runs saw 3.0 → 1.0 and 1.0 → 4.1 within one shift. After: 1-2 stars per shift at most. |
| Event base bonuses (Rush / Inspection / Leak / Catering / Delivery) | 50 / 40 / 40 / 60 / 60 | **100 / 80 / 80 / 120 / 120** | Measured at 2-5 % of a shift's pay ("a chore, not a payoff"). |
| `Events.SECTION_BONUS_SCALE` (new) | — | **×(1 + 0.5 per section owned past the first)** | Keeps an event worth a real slice of pay as the store grows: now ~10-18 % of the shift (e.g. $150 of $840 with 2 sections, $250-550 of ~$4,400 at the top). |
| `Main.SECTION_PRICES` | 500 / 900 / 1400 | **600 / 2500 / 6000** | A typical crew with helpers banked $1,100-1,300 a shift with 2 sections and $1,600-2,300 with 3; the old prices fell by shift 4-5 (target ~10). Produce stays reachable at shift 3 for the demo. |
| `Main.MANAGER_EARNED` | 800 | **900** | Kept "Produce + one shift" (+$300). |
| `Main.ENVIRONMENT_EARNED` | 1700 | **3700** | Kept "Produce + Dairy/Frozen + ~one shift". |
| `Main.RUSH_EARNED` (top tier) | 3500 | **32,000** | "Whole store + a bit" was reached by shift ~7; lifetime $32,000 lands at the target's shift ~16 solo. |
| `Staff.HIRE_FEE` | 150 / 200 / 250 | **300 / 400 / 500** | Hiring competes with saving for the next section again. |
| `Staff.WAGE` | 60 / 70 / 80 | **120 / 140 / 160** | A staffed top-tier store measured ~4.6x an unstaffed one's pay (the "2.9x" concern, worse with early opening); more of it goes back out as wages. Every hire stays well in the black (Produce's helper adds ~$500 a shift at 2 sections). |
| `Staff.JANITOR_HIRE_FEE` / `JANITOR_WAGE` | 200 / 50 | **400 / 100** | Same reasoning. |
| `Staff.SPEED_COSTS` / `CARRY_COSTS` | [100, 200] / [100, 200] | **[400, 800] / [400, 800]** | Training measured tiny on income (Phase 3); it's a late money sink, priced like one. |
| `Staff.JANITOR_SPEED_COSTS` | [150] | **[600]** | Same. |
| `Shop.UPGRADES` (all costs ×7; shop total) | $5,600 | **$39,200** — Sneakers 1400/3150/5600, Back Brace 2800/7000, Non-Slip Soles 1400/3150, Steel-Toe Boots 1050/2450, Plausible Deniability 1750/3850, Cleaning Cart 1050/2450, Employee of the Month 2100 | The long-term sink after the store is bought and staffed. A trained full crew nets ~$4,000 a shift (solo and co-op alike), and at ×4 solo still finished everything by shift 19 (target ~24). |

Unchanged on purpose: `PAY_PER_SALE` ($10), write-up penalty, the rating's
crowd and price multipliers (1★ ≈ 0.6x the income of 3★, 5★ ≈ 1.27x:
meaningful without needing more), bounce pay, crowd sizes, helper speeds,
event odds.

### Shifts to milestone (typical crew, events on, bot sims)

"At shift N" = true at the start of that shift's prep (after that prep's
purchases). Targets from the brief.

| Milestone | Target | Before: solo | Before: 2p | **After: solo** | **After: 2p** | **After: 3p** | After: solo, no helpers |
|---|---|---|---|---|---|---|---|
| Produce (2nd section) | by 4 (demo) | 3 | 2 | **3** | **2** | **2** | 3 |
| First helper | by 4 (demo) | 3 | 2 | **4** | **3** | **3** | — |
| First random event | by 4 (demo) | 3 | 2 | **3** | **2** | **2** | 3 |
| Rating moved (±0.5★) | by 4 (demo) | 1 | 1 | **2** | **1** | **1** | 3-4 |
| All three sections | ~10 | 5 | 4 | **11** | **8** | **8** | ~16 |
| Top tier (Bakery + lifetime), helpers hired | ~16 | ≥7 (run ended at 6, everything bought) | — | **16** | **13** | **14** | not reached by 15 |
| Janitor + every helper's training + whole gear shop | ~24 | 6 | 6 | **24** | **21** | **21** | — |

- "Before" = the pre-tuning economy with the same typical-crew bot (Phase 5
  UI changes in, no balance changes). The competent bot (opens at 90 %
  full) was faster still: all sections by 5 solo / 4 with 2 players.
- 3-player "before" wasn't completed. Its runs hit the engine crash
  (section 6) and were dropped; 2 players already showed the picture.
- **Without helpers** (solo, 3 runs): the whole store by about shift 16 and
  no top tier within 15 shifts, with the rating pinned near 1★ because this
  bot never cleans mid-shift. Skipping helpers roughly halves progress.
  **Flagged, not forced:** helpers are the core progression; a crew that
  refuses them plays a much slower game. If that should be gentler, lower
  `RUSH_EARNED` or Bakery's price (both also speed up the helper path).
- **Co-op runs 2-3 shifts ahead of solo** at every milestone (per-shift
  pay is ~1.1-1.6x solo's early and about equal late, when the customer cap
  saturates). The targets sit between them. Scaling prices by crew size
  would be a new mechanic, so it wasn't done.
- **Late openers** (the bot that never flips the sign): not re-measured
  after tuning (the runs take hours, and the crash below cost several).
  Before tuning, never-opening cut per-shift pay to roughly a third at 2+
  sections, and the 90 s prep change narrows that gap. The open-early hint
  exists to move crews out of that bracket.

### Time, and the demo

At 90 s/section a shift's clock is ~4:51 (1 section) / 6:21 / 7:51 / 8:51
(4 sections, with the top tier's cut), plus cleanup (1-3 min) and the
report. That's about 6-7 min, 8, 9-10 and 10-12 min per shift: 24 shifts ≈
3.7-4 h and 30 ≈ 4.7-5 h, inside the 4-6 h / 25-35-shift target. The demo:
practice (~5-8 min) plus shifts 1-4 (~6.5, 6.5, 8, 8 min) ≈ 35-40 min, and
by its end every demo milestone above is met for solo and co-op.

### The other concerns from the brief

- **Upgrades / broom.** Helper training and gear stay small on income, as
  Phase 3 measured. They're now priced as late sinks, not as progression.
  The broom's edge wasn't re-measured this phase; no change.
- **Solo vs co-op, events with/without helpers.** Covered above. Events
  complete in all configurations; bonuses are 10-18 % of pay.
- **Rating spread.** 1/3/5 stars ≈ 0.6x / 1x / 1.27x income through crowd ×
  price: kept. Whiplash fixed (drift rates above). Measured: with a janitor
  the rating sits ~3.5-4.5★; without one and without mid-shift cleaning it
  sits at 1-2★.

## 4. The demo cap

- **On** when the export preset carries the custom feature tag `demo`
  (`OS.has_feature("demo")`), or when launched with `--demo` (for testing;
  before or after `--`). **Off** otherwise. All in `Pacing.gd`:
  `DEMO_FEATURE_TAG`, `DEMO_CLI_FLAG`, `DEMO_SHIFT_CAP` (4),
  `STEAM_WISHLIST_URL`.
- The host decides: `demo_mode` and `demo_over` are replicated on DaySync, so
  a client sees "Finish Demo" and the end screen too. The report of shift 4
  (real shifts; the practice shift doesn't count) says **Finish Demo**.
  Pressing it (any peer) raises the thanks screen (Wishlist on Steam / Main
  Menu / Quit) on every peer and nothing advances. A demo save already past
  shift 4 opens straight onto that screen. The main menu shows a small
  Wishlist on Steam button in the demo only.
- **FLAGGED placeholder:** `Pacing.STEAM_WISHLIST_URL` =
  `https://store.steampowered.com/app/0000000/Shift_Work/`. Replace it once
  the store page exists.
- **Making the demo build (Godot 4.7):**
  1. Project → Export…
  2. Select the existing Windows (or Linux) preset and click **Duplicate**.
     Rename the copy, e.g. "Windows Demo".
  3. In the copy, open the **Features** tab. In **Custom**, type `demo`
     (several tags are comma-separated).
  4. Give it its own **Export Path** (e.g. `build/demo/ShiftWorkDemo.exe`) so
     it doesn't overwrite the full game.
  5. Export with that preset. In `export_presets.cfg` this shows up as
     `custom_features="demo"` on that preset.
  To test without exporting: run the game with `--demo`
  (`godot --path . -- --demo`).

## 5. Quality checks

### Controls for joined players
The two key sets came from commit `6eb3145`, "Separate WASD (host) and
arrow-key (client) input for manual dual-window testing": a developer
convenience. There's no local split-screen (each window is its own player,
and only the focused window gets keys), so two people never truly share a
keyboard. **Fix:** every player uses the primary set (WASD / E / F / C /
Space) by default, hosting or joined. The arrow set stays as a choice per
PC: Settings > Controls "Use the second set (arrow keys) on this PC"
(saved in `settings.cfg`), or `--second-keys` on the command line for that
process only. Rebinding works for both sets. The practice card, the mop and
broom prompt, the staff board, lockers and sign prompts all name the keys
this PC reads (`Settings.local_prefix()`). **Trade-off:** a developer
running two windows on one PC now gets WASD in both, which is harmless
because only the focused window reads keys. Pass `--second-keys` to one if
the arrows are wanted.

### Helper / forklift overlap
Cause (found, now fixed): a helper inside the forklift's body stepped out
the nearer long side, but if that side left the room's open band, it turned
round and walked out the other side, *through* the forklift; the band clamp
also dragged a helper standing in a slot row back across it.
`tools/phase5_test.gd --test=fk-escape` drops the helper inside a held
forklift at 225 placements (3 x 3 positions x 5 rotations x 5 offsets):
before the fix 36 exits went through the body; after, 0, and the worst
escape is 10 frames. `--test=fk-helpers` watched 53,102 frames of
top-tier selling with all three helpers: 0 overlap frames.

### Node-count creep
Not reproduced on this build. Economy soak (Day 7, 5 completed shifts):
4,018 → 4,003 → 4,021 → 4,007 → 4,011 nodes, 0 orphans, steady memory. The
soak now prints node counts per subtree and the growth between the first
and last shift, so the cause will be visible if it comes back. The staff
soak comparison is in the soak section below.

### Toast over labels; customer AI overlap
Not changed (pre-existing; no cheap fix). The toast can sit over world-space
name labels (register cashiers, the manager) for its 3 s. The prep line's
overlap with the HUD corners *was* fixed (above).

### Save compatibility
No format change: `SaveGame.VERSION` stays 6. The gear rename is
display-only; the key is still `"janitor"`, so v2-v6 saves load their gear
unchanged (`--test=gear` loads an old-key save, shows "Cleaning Cart Lv
2/2" and writes the same key back). Every save suite passes on the final
code: save-p1..p7, save-net, save-net-story, econ legacy (v1 → v2),
staff (v2 → v3), upkeep (v3 → v4), janitor (v5 → v6).

## 6. Regression and soak

### Full regression (final code; every entry run to completion)
131 entries (`tools/run_regression.sh`, 2 lanes, real time).
First full pass: **111 OK, 20 failed**. All 20 were looked at:
- 13 were tests that wrote in the old numbers (the 180 s prep ceiling, gear
  and training prices, "Day N" status strings, the full-width prep line):
  hz-orders, hz-delivery (D1), hz-finale (F0/F1), coffee, coffee-net, hud,
  hud-past-week, staff-hire, save-p3, save-p4, save-net, save-staff-1,
  save-staff-2. Fixed to read the constants; all pass on rerun.
- 6 were flakes, each passing on rerun: juice-net, pf-trash, pf-pickup and
  up-net NF3 (all on the known list); hz-net-cleanup NC4 (the list names NC3
  of the same test); up-earnings N2 (no troublemaker happened to be thrown out
  that shift; not on the list, passed on rerun).
- **hz-net-ambience-d7** (known flake): failed in the full pass and once
  alone, then passed 2/2 alone. Pristine main passed 2/2 alone too. The
  failure varies run to run (E1: the host's view of a client's spill pass;
  E4: facings); the test doesn't depend on anything Phase 5 changed (it runs
  inside prep).
- The 13 new Phase 5 entries all pass. No Endless tests remain (Phase 4
  retired them); `hz-endless` / `hz-net-endless` aren't in the list.

### Soak — see section 8 (filled in from the final runs).

### Co-op end to end
Host + 2 clients: menu-net-pause (overlay, a client quits to menu, another
to desktop), menu-net-host-quit (host leaves, clients land on their menus,
rejoin), p5-net-demo (the demo cap across peers), every net-* regression
entry, and the 2- and 3-player progression runs (21-22 shifts each, real
co-op peers, events, purchases, helpers).

## 7. Found along the way

- **An intermittent engine crash, pre-existing on main.** Signal 11 on a
  worker thread, right after `ERROR: /root: The caller thread can't call the
  function propagate_notification() on this node`. Seen in long headless
  bot runs under heavy CPU load: 7 crashes over roughly 30 long runs, mostly co-op
  hosts and clients (7 crashes). **Pristine `origin/main` crashed the same way** under
  the same load, with the same backtrace addresses
  (`godot+44f0688 ← 3713d19 ← 498f725 ← 36ff5b7 ← 3fff3b5 ← 4edbda3`,
  Godot 4.7-stable, official build, no symbols). The game's scripts start no
  threads and add no loggers, so it's inside the engine. Not fixed. To chase
  it: reproduce with a Godot 4.7 debug build (symbols), or try the next
  4.7.x patch. Unknown whether it hits players on a normal desktop build;
  worth watching in playtests.
- `tools/art_shots.gd` would have errored on `PRIORITY_ORDER_START_DAY`.
- The co-op income harness can buy a section by accident: a bot pressing E
  at a gate during prep buys it if the bank allows. Noise in the per-state
  income runs only; the progression policy buys anyway.
- `assets/supermarket/` and `warehouse/` show signs consistent with
  AI-generated art and have no recorded source (asset audit, section 7).

## 7b. Credits, placeholders, asset audit

- **Unresolved credits:** the supermarket and warehouse tile packs. One
  commit by the project owner (`d1b8678`, 26 Sep 2026) added them with no
  license, readme, author or URL, and no PNG metadata; nothing else in the
  history names a source. Listed as UNRESOLVED in `assets/CREDITS.md`. Also
  to confirm: the Employee of the Month portrait's maker and, if it depicts
  a real person (the adding commit calls it the "CaseOh photo"), their
  permission. Kelano Studio and karsiori have no source URLs recorded.
- **In-game Credits screen** carries the required lines (Kevin MacLeod
  CC-BY 3.0, LPC CC-BY-SA 3.0 and authors, Kenney, Freesound, Kelano,
  karsiori, Godot). The "Made by" line is a FLAGGED placeholder:
  "[developer / studio name — set before release]".
- **Placeholder art still in (unchanged, as asked):** dumpster, bin bag,
  mop, broom, puddle, tool rack, stars, janitor (an LPC look + ring), leak
  drips and rings, GEAR sign. The "inspector" and the "clipboard and banner
  icons" don't exist as art: they're text today. **Not on the known list:**
  the store OPEN/CLOSED board, the section gates, the box truck and dock,
  the staff board, the coffee machine, the sidewalk floor, the shopping-list
  bubble, the juice particles, the tutorial and door arrows, the badge and
  coffee-cup icons, no app icon (the default Godot icon ships), and
  synthesized audio (prep and menu music, forklift beeps, mop swishes,
  chimes, the fanfare).
- **Asset audit summary** (`docs/asset-audit.md`): 6 rows from licensed
  packs (keep), 13 rows of unknown origin (the supermarket and warehouse
  packs, which cover floors, walls, shelving, every product, checkouts,
  carts, forklifts and crates; plus the portrait and its copy), 26 rows of
  code-drawn art, 2 of code-generated audio, 2 engine-provided, 1 missing
  (the app icon). Top of the replace list: the two packs (unless their
  source is verified as hand-made), the portrait, mop/broom, spills, rating
  stars, the store sign, the prep/menu music and the icon.

## 8. Soak — 8 shifts, all helpers + janitor, events on, full crowd

(staff_test.gd --test=soak, --day=7 top tier, real time; origin/main vs this
branch, run side by side on the same machine.)

SOAK_TABLE_PLACEHOLDER

## 9. Deferred / not done

- A late-opener ("never opens") progression run after tuning (bracket only).
- A 3-player "before" run (crashed; 2-player shows the before picture).
- Toast-over-world-label overlap and customer-AI overlap (pre-existing).
- The engine crash above (needs a debug build).
- `config/name` rename (needs a save-folder migration).
