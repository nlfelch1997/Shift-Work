extends RefCounted
## PHASE 5 — PACING: the demo cap, the store link and the pacing targets, in
## one place. Every number here is a FLAGGED, tunable constant. The economy
## numbers that produce the pacing (section prices, wages, hire fees, the
## complication thresholds, event bonuses, the rating levers) stay next to the
## code that uses them (Main.gd, Staff.gd, Events.gd, Shop.gd); this file
## names the targets they are tuned toward, and the Phase 5 report has the
## measured shifts-to-milestone table against them (tools/staff_test.gd
## --test=progress).
##
## THE DEMO BUILD. Same project, a second export preset: the demo is ON when
## the export preset carries the custom feature tag DEMO_FEATURE_TAG
## (OS.has_feature("demo")), or on any build launched with --demo (testing).
## Off in a normal build. In the demo:
## - the shift-DEMO_SHIFT_CAP report's Continue becomes "Finish Demo"; pressing
##   it ends play on every peer with a "thanks for playing — wishlist the full
##   game" screen (Main.gd's demo_over, replicated);
## - a save already past the cap opens straight onto that screen;
## - the main menu shows a small "Wishlist on Steam" button.
## Shifts count real shifts: the practice shift before Shift 1 isn't one.

## Godot export feature tag that turns the demo on (Project > Export > the
## demo preset > Features > Custom: demo).
const DEMO_FEATURE_TAG := "demo"
## Command-line switch with the same effect, for testing (after "--" or not).
const DEMO_CLI_FLAG := "--demo"
## The demo ends after this many real shifts (~40 minutes at 8-14 min a shift).
const DEMO_SHIFT_CAP := 4
## FLAGGED PLACEHOLDER — no store page yet. Replace with the real Steam URL
## (https://store.steampowered.com/app/<appid>/Shift_Work/) before shipping
## the demo.
const STEAM_WISHLIST_URL := "https://store.steampowered.com/app/0000000/Shift_Work/"

## THE PACING TARGETS (a typical crew, solo and 2-3 players) — documentation
## for the tuning, and what the progression measurement is compared against.
## Demo: by the end of shift DEMO_SHIFT_CAP a second section bought, a first
## helper hired, a random event seen, the rating moved.
const TARGET_DEMO_SHIFTS := 4
## Full game: 25-35 shifts of content (~4-6 hours).
const TARGET_ALL_SECTIONS_BY := 10
const TARGET_TOP_TIER_BY := 16 # Bakery owned + Main.RUSH_EARNED lifetime, helpers hired
const TARGET_EVERYTHING_BY := 24 # the janitor, every helper's training and the whole gear shop
const TARGET_CONTENT_SHIFTS := [25, 35]

## THE OPEN-EARLY HINT (Main.gd's _update_open_early_hint()): opening early
## is the biggest income lever — unused prep becomes selling time — and
## players don't find it. During prep, once the open shelves are this full
## and at least this much prep is left, a banner line says so, once a shift.
const OPEN_EARLY_HINT_FILL := 0.75
const OPEN_EARLY_HINT_MIN_PREP := 45.0
## ...and it stops once this crew has opened early (with at least
## OPEN_EARLY_HINT_MIN_PREP unused) on this many shifts this session.
const OPEN_EARLY_HINT_RETIRE := 3

## Whether this run is the demo.
static func is_demo() -> bool:
	return OS.has_feature(DEMO_FEATURE_TAG) or DEMO_CLI_FLAG in OS.get_cmdline_user_args() or DEMO_CLI_FLAG in OS.get_cmdline_args()
