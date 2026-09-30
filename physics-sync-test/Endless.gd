extends Node
## WEEK 21 — ENDLESS MODE: the hub, the shift board, the Break Room shop.
## Built in code by Main.gd's _ready() (explicit name "Endless", same on every
## peer — its synchronizer's path has to match, see Player.gd's note).
##
## THE SHAPE (locked design, borrowed from R.E.P.O.'s run -> Service Station
## loop, in this game's top-down Overcooked tone):
## - Days 1-7 are THE STORY. Day 7's report is followed by a WEEK COMPLETE
##   screen (SCREEN_WEEK_COMPLETE) that says so in so many words, then the hub.
## - The hub (SCREEN_HUB, drawn by HubUI.gd) is one screen: the SHIFT BOARD
##   (OFFER_COUNT randomized shift postings, each fully previewed — which
##   sections are open, which hazards run and how hard, the clock, the medal
##   targets, the Bucks multiplier) beside the BREAK ROOM SHOP (permanent crew
##   upgrades). Pick a posting -> play that shift (prep, selling, cleanup,
##   clock out, exactly the story days' loop) -> its report shows the medal
##   and the Bucks it paid -> back to the hub with a fresh board.
## - Endless shifts are NOT more numbered days. Main.gd's current_day parks at
##   ENDLESS_DAY (8) for the whole run and never moves again; shift_number
##   counts shifts, and every screen says "Shift #N", never "Day N".
##
## WHAT A SHIFT RANDOMIZES — the same per-system knobs the story days use,
## nothing new invented. Each hazard gets a LEVEL: 0 off, 1 its normal (Days
## 3-6) numbers, 2 its Day 7 finale numbers. Main.gd's hazard_levels() hands
## these to the systems in place of the story's "day >= N" / is_finale() gates,
## so a level-2 manager IS the Day 7 manager, not a new tuning. Plus which
## sections are open (Dry Goods always; any of Produce, Dairy/Frozen, Bakery),
## which drives every density tier, the prep ceiling and the delivery load
## through the existing _unlocked_sections(). The Produce forklift lives in
## Produce's aisle, so it can only run when Produce is open. A shift is never
## longer than the story's longest day: prep ceiling by open sections (max
## 12 min = Day 7) + the 111s selling window, cut to Day 7's 96s ("tight
## clock") on 4-5 star shifts and whenever all four sections are open.
##
## DIFFICULTY READ (the preview's stars): heat = sum of hazard levels (0-10)
## + extra sections open (0-3), 0-13, bucketed by STAR_HEAT_MIN into 1-5
## stars. For scale: story Day 5 would read 2 stars, Day 6 3, Day 7 5. The
## three postings are always one per band in OFFER_BANDS (easy / middle /
## hard), so the board is a real risk-vs-reward choice every time.
##
## MONEY — two currencies, deliberately:
## - PAY ($) is the story's existing number (sales + priority bonus +
##   cleanliness bonus - write-ups), unchanged. On an endless shift it is the
##   SHIFT SCORE the medal targets are set against.
## - BREAK ROOM BUCKS are the new spendable currency (the shop's). A shift
##   pays Bucks from the same three things the report already tracks — sales,
##   priority orders filled, cleanliness — minus write-ups, plus a medal bonus,
##   times the shift's star multiplier (compute_payout()); per head in a crew.
##   A bad shift pays a little, a strong one a lot, a strong hard one the most.
##
## MULTIPLAYER: host-authoritative like everything else. The host rolls the
## board, takes the posting, scores the shift and applies purchases; any peer's
## click is a request RPC (the same "any peer may ask, only the host acts"
## shape as the Store sign and the time clock). Every piece of state below is
## on EndlessSync in ON_CHANGE mode (reliable deltas — no MTU cap; the Week 20
## litter bug was an ALWAYS-mode node state over the 1350-byte MTU, and a
## three-posting board plus the payout breakdown is exactly that kind of
## blob). Every Dictionary/Array is reassigned, never mutated, so a change is
## plainly a new value to the synchronizer.
##
## PERSISTENCE: wallet, upgrades and run stats live in this node, for the
## lifetime of the running game (the HOST's process — clients mirror it). Quit
## and relaunch and they're gone: surviving that needs the real save/load
## system, explicitly deferred to its own session. Everything a save would
## need is the replicated state listed in _ready() plus Main's current_day.

const SCREEN_NONE := 0
const SCREEN_WEEK_COMPLETE := 1
const SCREEN_HUB := 2

## Where current_day parks once the story is over (see the header).
const ENDLESS_DAY := 8

const HAZARDS := ["forklift", "manager", "orders", "spills", "lights"]
const HAZARD_NAMES := {
	"forklift": "Produce forklift",
	"manager": "Manager",
	"orders": "Priority orders",
	"spills": "Floor spills",
	"lights": "Flickering lights",
}
## One short line per hazard per level, for the preview (index = level).
const HAZARD_LEVEL_TEXT := {
	"forklift": ["off", "patrols, rams shelves", "Day 7: shorter stops"],
	"manager": ["off", "writes up idlers", "Day 7: shorter fuse"],
	"orders": ["off", "every 45s", "Day 7: every 32s"],
	"spills": ["off", "now and then", "Day 7: more, faster"],
	"lights": ["off", "brownouts", "Day 7: more often"],
}
const OPTIONAL_SECTIONS := ["Produce", "Dairy/Frozen", "Bakery"]
const OFFER_COUNT := 3
## [min stars, max stars] for each posting on the board, in board order.
const OFFER_BANDS := [[1, 2], [3, 3], [4, 5]]
## heat -> stars: the lowest heat that earns 2, 3, 4, 5 stars.
const STAR_HEAT_MIN := [3, 6, 9, 11]
const STAR_WORDS := ["", "EASY", "STEADY", "BUSY", "HECTIC", "NIGHTMARE"]
## 4-5 star shifts sell for Day 7's 96s instead of 111s (Main.gd's
## FINALE_SELLING_CUT) — the one clock lever, and it only ever SHORTENS. So do
## postings with every section open, whatever their stars: all four sections
## is Day 7's 12-minute prep ceiling, and with a 111s window that day would run
## 15s past Day 7's own 816s — no shift may be longer than the story's longest.
const TIGHT_CLOCK_STARS := 4
## Flavor only — names never imply a hazard the posting doesn't have.
const SHIFT_NAMES := [
	[],
	["Quiet Tuesday", "Soft Open", "Slow Morning", "Rainy Weekday"],
	["Weekday Restock", "Lunch Rush", "Coupon Day", "Payday Friday"],
	["Weekend Crowd", "Inventory Night", "Double Coupon Day", "Game Day"],
	["Holiday Eve", "Grand Reopening", "Doorbuster Night", "Snowstorm Stock-Up"],
	["Black Friday", "The Big One", "Everything Sale", "Last Shift Before Christmas"],
]

## --- Bucks (FLAGGED placeholders, bot-sim calibrated — see compute_payout()).
const BUCKS_PER_SALE := 1
const BUCKS_PER_ORDER := 4
## Cleanliness is a SHARE of what the shift earned (sales + orders), the same
## shape as the story's $ cleanliness bonus (Cleanup.gd's CLEAN_BONUS_MAX of
## gross pay): a spotless close adds 40%; an empty store that sold nothing
## earns nothing for being tidy.
const BUCKS_CLEAN_SHARE := 0.4
const BUCKS_PER_WRITEUP := 3
const MEDAL_NAMES := ["none", "BRONZE", "SILVER", "GOLD"]
const MEDAL_BUCKS := [0, 5, 12, 25]
## x Bucks per star above 1 (a 5-star shift pays 1.6x).
const BUCKS_MULT_PER_STAR := 0.15
## Paid once, on the WEEK COMPLETE screen, so the first hub visit has
## something to spend.
const WEEK_COMPLETE_BUCKS := 40

## --- Medal targets: the shift score (Pay, $) to reach. GOLD is about what the
## solo bot sim (tools/hazards_test.gd, a "competent human" brain) earns on a
## shift of that shape; silver and bronze are shares of it. Calibrated from
## the story days on unmodified main (solo, one run each — runs vary by
## several sales): 1 section $151, 2 sections $263 / $311, 3 sections $338 /
## $369, 4 sections at full Day 7 heat $150. Pay doesn't grow linearly with
## sections (more walking), and heat bites harder the higher it goes — hence a
## base per section count and a heat discount with a floor. Scaled up for a
## crew (more customers and stock per extra player). The reward for a HARD
## shift is the Bucks multiplier, not an easier target. FLAGGED placeholders.
const TARGET_BASE_BY_SECTIONS := [150, 300, 400, 420] # $, gold-level, 1-4 open sections
const TARGET_SHARES := [0.4, 0.7, 1.0] # bronze, silver, gold
const TARGET_HEAT_DISCOUNT := 0.04 # -4% per point of heat...
const TARGET_HEAT_FLOOR := 0.45 # ...down to this
## +60% per extra crew member. From the 3-player co-op run (4 full shifts):
## crew score / the solo-calibrated gold was 0.4x, 5.6x, 1.6x, 3.1x — a crew
## stocks faster, so it often opens early and sells far longer (Week 16's
## unused-prep-becomes-selling rule). One bot run; wants human co-op numbers.
const TARGET_PER_EXTRA_PLAYER := 0.6

## --- The Break Room shop. Crew-wide (every player gets it — pay is crew-wide
## too), permanent for the run. costs[i] = price of level i+1.
const UPGRADES := [
	{"key": "shoes", "name": "Comfy Sneakers", "desc": "+8% walking speed per level", "costs": [20, 45, 80]},
	{"key": "brace", "name": "Back Brace", "desc": "+1 product at once: E grabs till full, E again sets all down", "costs": [40, 100]},
	{"key": "soles", "name": "Non-Slip Soles", "desc": "spills slow you less, you slide less", "costs": [20, 45]},
	{"key": "boots", "name": "Steel-Toe Boots", "desc": "shorter stun when the forklift hits you", "costs": [15, 35]},
	{"key": "alibi", "name": "Plausible Deniability", "desc": "manager takes +0.5s longer to write you up", "costs": [25, 55]},
	{"key": "janitor", "name": "Janitor's Kit", "desc": "mop & sweep 20% faster, dustpan +4", "costs": [15, 35]},
	{"key": "badge", "name": "Employee of the Month", "desc": "cosmetic: a gold star over the crew", "costs": [30]},
]

## --- Replicated state (EndlessSync, ON_CHANGE, host authority) ------------
var screen := SCREEN_NONE
## The three postings on the board (contract dictionaries, see _make_offer()).
var offers: Array = []
## The shift being played; {} outside endless mode. Carries the medal targets
## fixed for the crew size at the moment it was taken.
var contract: Dictionary = {}
## Endless shifts started this run ("Shift #N").
var shift_number := 0
var wallet := 0
var upgrades: Dictionary = {}
## The last scored shift's breakdown (compute_payout()), for its report.
var last_payout: Dictionary = {}
## Run totals: shifts, bucks, medals [none, bronze, silver, gold].
var run_stats: Dictionary = {"shifts": 0, "sold": 0, "bucks": 0, "medals": [0, 0, 0, 0]}
## The story week's results, captured as Day 7 closes (WEEK COMPLETE screen).
var week_summary: Dictionary = {}

## Host diagnostics (tests): purchases / postings taken that actually applied.
var purchases_applied := 0
var offers_taken := 0
var _next_offer_id := 1

var main: Node

func _ready() -> void:
	main = get_parent()
	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	for prop in [".:screen", ".:offers", ".:contract", ".:shift_number", ".:wallet", ".:upgrades", ".:last_payout", ".:run_stats", ".:week_summary"]:
		var path := NodePath(prop)
		config.add_property(path)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE)
	sync.replication_config = config
	sync.name = "EndlessSync"
	sync.set_multiplayer_authority(1)
	add_child(sync)

## --- Section / hazard reads (every peer, from the replicated contract) ------

func section_open(section_name: String) -> bool:
	if section_name == "Dry Goods":
		return true
	return contract.get("sections", []).has(section_name)

func level_of(hazard: String) -> int:
	return int(contract.get("levels", {}).get(hazard, 0))

func tight_clock() -> bool:
	return bool(contract.get("tight_clock", false))

## --- Upgrade reads (every peer) ---------------------------------------------

func upgrade_level(key: String) -> int:
	return int(upgrades.get(key, 0))

func max_level(key: String) -> int:
	for u in UPGRADES:
		if u["key"] == key:
			return u["costs"].size()
	return 0

## Price of the next level, or -1 when maxed / unknown.
func next_cost(key: String) -> int:
	for u in UPGRADES:
		if u["key"] == key:
			var lvl := upgrade_level(key)
			return u["costs"][lvl] if lvl < u["costs"].size() else -1
	return -1

func speed_mult() -> float:
	return 1.0 + 0.08 * upgrade_level("shoes")

func carry_capacity() -> int:
	return 1 + upgrade_level("brace")

## Top speed on a wet spill (Ambience's 0.7 at level 0) and traction multiplier.
func spill_speed_factor(base: float) -> float:
	return minf(0.95, base + 0.1 * upgrade_level("soles"))

func spill_traction_mult() -> float:
	return 1.0 + 0.5 * upgrade_level("soles")

func forklift_stun_mult() -> float:
	return 1.0 - 0.35 * upgrade_level("boots")

func manager_fuse_bonus() -> float:
	return 0.5 * upgrade_level("alibi")

func cleanup_time_mult() -> float:
	return 1.0 - 0.2 * upgrade_level("janitor")

func pan_bonus() -> int:
	return 4 * upgrade_level("janitor")

func has_badge() -> bool:
	return upgrade_level("badge") > 0

## --- The board ---------------------------------------------------------------

static func heat_of(levels: Dictionary, sections: Array) -> int:
	var h := 0
	for k in HAZARDS:
		h += int(levels.get(k, 0))
	return h + sections.size()

static func stars_for_heat(heat: int) -> int:
	var stars := 1
	for threshold in STAR_HEAT_MIN:
		if heat >= threshold:
			stars += 1
	return stars

## Host-only. A fresh board: one posting per OFFER_BANDS band, no two alike.
func roll_offers() -> void:
	if not multiplayer.is_server():
		return
	var board := []
	var seen := {}
	for band in OFFER_BANDS:
		var offer := {}
		for attempt in 12:
			offer = _make_offer(band[0], band[1])
			if not seen.has(offer["sig"]):
				break
		seen[offer["sig"]] = true
		board.append(offer)
	offers = board
	print("[Endless] Shift board: %s" % " | ".join(board.map(func(o): return "%s %d* %s %s" % [o["name"], o["stars"], str(o["sections"]), str(o["levels"])])))

## Host-only. A random shift, then nudged one knob at a time (a random one that
## can move) until its stars hit a goal picked evenly within [lo, hi] — so a
## band's range is really used, not just its edge. Always terminates: every
## knob at max is 5 stars, every knob at 0 is 1.
func _make_offer(lo: int, hi: int) -> Dictionary:
	var goal := randi_range(lo, hi)
	var sections := []
	for s in OPTIONAL_SECTIONS:
		if randf() < 0.5:
			sections.append(s)
	var levels := {}
	for k in HAZARDS:
		levels[k] = randi_range(0, 2)
	_fix_forklift(levels, sections)
	for step in 64:
		var stars := stars_for_heat(heat_of(levels, sections))
		if stars == goal:
			break
		var up := stars < goal
		var knobs := []
		for k in HAZARDS:
			if up and levels[k] < 2 and (k != "forklift" or sections.has("Produce")):
				knobs.append(k)
			elif not up and levels[k] > 0:
				knobs.append(k)
		for s in OPTIONAL_SECTIONS:
			if up != sections.has(s):
				knobs.append(s)
		if knobs.is_empty():
			break
		var pick: String = knobs[randi() % knobs.size()]
		if pick in HAZARDS:
			levels[pick] += 1 if up else -1
		elif up:
			sections.append(pick)
		else:
			sections.erase(pick)
		_fix_forklift(levels, sections)
	# Board order, not roll order, so the preview always lists sections alike.
	var ordered := OPTIONAL_SECTIONS.filter(func(s): return sections.has(s))
	var heat := heat_of(levels, ordered)
	var stars := stars_for_heat(heat)
	var names: Array = SHIFT_NAMES[stars]
	var offer := {
		"id": _next_offer_id,
		"name": names[randi() % names.size()],
		"sections": ordered,
		"levels": levels,
		"heat": heat,
		"stars": stars,
		"tight_clock": stars >= TIGHT_CLOCK_STARS or ordered.size() == OPTIONAL_SECTIONS.size(),
		"bucks_mult": snappedf(1.0 + BUCKS_MULT_PER_STAR * (stars - 1), 0.01),
		"sig": "%s|%s" % [str(ordered), str(HAZARDS.map(func(k): return levels[k]))],
	}
	_next_offer_id += 1
	return offer

## The Produce forklift patrols Produce's aisle — no Produce, no forklift.
static func _fix_forklift(levels: Dictionary, sections: Array) -> void:
	if not sections.has("Produce"):
		levels["forklift"] = 0

## [bronze, silver, gold] shift-score targets ($) for a posting and crew size.
static func targets_for(offer: Dictionary, crew: int) -> Array:
	var n: int = clampi(1 + offer["sections"].size(), 1, TARGET_BASE_BY_SECTIONS.size())
	var gold: float = TARGET_BASE_BY_SECTIONS[n - 1] * maxf(TARGET_HEAT_FLOOR, 1.0 - TARGET_HEAT_DISCOUNT * int(offer["heat"])) * (1.0 + TARGET_PER_EXTRA_PLAYER * maxi(0, crew - 1))
	var out := []
	for share in TARGET_SHARES:
		out.append(maxi(5, int(round(gold * share / 5.0)) * 5))
	return out

## --- Requests: any peer asks, the host acts -----------------------------------

## WEEK COMPLETE -> hub.
func request_enter_hub() -> void:
	if multiplayer.is_server():
		main.enter_hub()
	else:
		_rpc_enter_hub.rpc_id(1)

@rpc("any_peer", "reliable")
func _rpc_enter_hub() -> void:
	if multiplayer.is_server():
		main.enter_hub()

func request_take_offer(index: int) -> void:
	if multiplayer.is_server():
		main.take_offer(index)
	else:
		_rpc_take_offer.rpc_id(1, index)

@rpc("any_peer", "reliable")
func _rpc_take_offer(index: int) -> void:
	if multiplayer.is_server():
		main.take_offer(index)

func request_buy(key: String) -> void:
	if multiplayer.is_server():
		buy(key)
	else:
		_rpc_buy.rpc_id(1, key)

@rpc("any_peer", "reliable")
func _rpc_buy(key: String) -> void:
	if multiplayer.is_server():
		buy(key)

## Host-only. Only from the hub, only if affordable and not maxed — two peers
## buying the last level in the same instant buy it once.
func buy(key: String) -> bool:
	if not multiplayer.is_server() or screen != SCREEN_HUB:
		return false
	var cost := next_cost(key)
	if cost < 0 or cost > wallet:
		return false
	wallet -= cost
	var next := upgrades.duplicate()
	next[key] = upgrade_level(key) + 1
	upgrades = next
	purchases_applied += 1
	print("[Endless] Bought %s level %d for %d Bucks (wallet %d)" % [key, next[key], cost, wallet])
	return true

## --- Scoring -------------------------------------------------------------------

## Pure: the Bucks a finished shift pays, and why. score = the shift's Pay ($).
## PER HEAD in a crew: sales, orders and write-ups are the crew's totals
## divided by its size (the cleanliness share follows); the medal bonus is
## the crew's, whole. Found by the 3-player co-op run: a crew that opened the
## store early (Week 16's unused-prep-becomes-selling rule) sold 107 in one
## shift and would have paid 226 Bucks — a solo shift paid 25-78, and the whole
## shop costs 560. Per head, that shift pays ~110: still the best of the run.
static func compute_payout(c: Dictionary, sold: int, orders_filled: int, clean_frac: float, writeups: int, score: int) -> Dictionary:
	var targets: Array = c.get("targets", [0, 0, 0])
	var crew := maxi(1, int(c.get("crew", 1)))
	var medal := 0
	for i in 3:
		if score >= int(targets[i]):
			medal = i + 1
	var sales_b := int(round(float(sold * BUCKS_PER_SALE) / crew))
	var orders_b := int(round(float(orders_filled * BUCKS_PER_ORDER) / crew))
	var writeup_b := -int(round(float(writeups * BUCKS_PER_WRITEUP) / crew))
	var clean_b := int(round(clampf(clean_frac, 0.0, 1.0) * BUCKS_CLEAN_SHARE * (sales_b + orders_b)))
	var medal_b: int = MEDAL_BUCKS[medal]
	var subtotal := maxi(0, sales_b + orders_b + clean_b + writeup_b + medal_b)
	var mult := float(c.get("bucks_mult", 1.0))
	return {
		"medal": medal, "score": score, "targets": targets, "crew": crew,
		"sales": sales_b, "orders": orders_b, "clean": clean_b, "writeups": writeup_b, "medal_bucks": medal_b,
		"subtotal": subtotal, "mult": mult, "total": int(round(subtotal * mult)),
	}

## Host-only, from Main.gd's _end_shift() on an endless shift: pays it out.
func score_shift(sold: int, orders_filled: int, clean_frac: float, writeups: int, score: int) -> void:
	if not multiplayer.is_server():
		return
	var p := compute_payout(contract, sold, orders_filled, clean_frac, writeups, score)
	p["shift"] = shift_number # the report shows it only once this matches
	wallet += int(p["total"])
	last_payout = p
	var medals: Array = run_stats.get("medals", [0, 0, 0, 0]).duplicate()
	medals[p["medal"]] += 1
	run_stats = {"shifts": int(run_stats.get("shifts", 0)) + 1, "sold": int(run_stats.get("sold", 0)) + sold, "bucks": int(run_stats.get("bucks", 0)) + int(p["total"]), "medals": medals}
	print("[Endless] Shift #%d scored — score $%d vs %s -> %s, +%d Bucks (x%.2f; sales %d, orders %d, clean %d, write-ups %d, medal %d) wallet %d" % [shift_number, score, str(p["targets"]), MEDAL_NAMES[p["medal"]], p["total"], p["mult"], p["sales"], p["orders"], p["clean"], p["writeups"], p["medal_bucks"], wallet])

## --- Preview text (every peer; HubUI.gd and Main's banners read these) ------

static func stars_text(stars: int) -> String:
	return "★".repeat(stars) + "☆".repeat(5 - stars)

static func pips(level: int) -> String:
	return "●".repeat(level) + "○".repeat(2 - level)

static func sections_text(offer: Dictionary) -> String:
	return ", ".join(["Dry Goods"] + offer.get("sections", []))

## One line per hazard, on or off, for the posting card.
static func hazard_lines(offer: Dictionary) -> Array:
	var out := []
	for k in HAZARDS:
		var lvl := int(offer.get("levels", {}).get(k, 0))
		out.append([k, lvl, "%s %s — %s" % [pips(lvl), HAZARD_NAMES[k], HAZARD_LEVEL_TEXT[k][lvl]]])
	return out

static func medal_text(medal: int) -> String:
	return MEDAL_NAMES[medal] if medal > 0 else "no medal"
