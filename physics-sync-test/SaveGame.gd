extends RefCounted
## WEEK 24 — SAVE / LOAD. One small JSON file in user://, written and read by
## the HOST only (solo is a host with no clients). Main.gd owns the calls; this
## file only knows how to turn the game's state into a save, a save back into
## clean values, and how to get it on and off the disk without ever leaving a
## half-written file behind.
##
## WHAT IS SAVED — progress, never a shift in flight:
## - the story: the last FULLY COMPLETED day (0-7) and whether the week is
##   over (Endless Mode unlocked). A day only counts once its report is up
##   (Main._end_shift()); quitting mid-day replays that day from its start.
## - the story week's running totals (sold, write-ups, priority sales, the
##   cleanliness bonus, coffee cups) — so Day 5's "Week Total" and the WEEK
##   COMPLETE screen still count Days 1-4 after a relaunch. Only meaningful
##   until the week is over.
## - endless: the Bucks wallet, every upgrade level, the run's totals
##   (shifts, sold, Bucks earned, medals), the shift counter ("Shift #N") and
##   the week's results shown on WEEK COMPLETE.
## NOT saved: anything inside a shift (stock, customers, hazards, the clock),
## the shift board's postings (a fresh board is rolled on load) and the coffee
## machine's per-shift cups (they reset every shift anyway).
##
## WHY JSON (not ConfigFile/var_to_str): it can only ever describe plain data.
## A ConfigFile is parsed with Godot's Variant parser, which also understands
## Object(...) — a save someone hands you shouldn't be able to build objects.
## JSON turns every number into a float, so EVERY field is re-read through
## sanitize() (cast, clamped, unknown keys dropped) — which is also exactly
## what makes a hand-edited or damaged file safe to load.
##
## ROBUSTNESS: writes go to <file>.tmp, then replace the real file in one
## rename — a crash or power cut mid-write leaves the previous save intact.
## A file that won't parse, isn't an object, or is from a newer save version
## is NOT loaded: the game starts fresh (Day 1, empty wallet) and the bad file
## is copied aside to <file>.bad so the next save can't destroy the evidence.

const VERSION := 1
const DEFAULT_PATH := "user://shiftwork_save.json"
const STORY_DAYS := 7

const LOAD_NONE := 0 # no file: a fresh start
const LOAD_OK := 1
const LOAD_CORRUPT := 2 # a file was there but unusable: a fresh start

## The save as plain data, from the host's live state.
static func snapshot(main: Node) -> Dictionary:
	var en: Node = main.endless
	return {
		"version": VERSION,
		"saved_at": Time.get_datetime_string_from_system(),
		"story": {
			"completed_day": main.completed_story_day,
			"complete": main.story_complete,
		},
		"week": {
			"sold": main._total_sold(),
			"writeups": main.writeups_week,
			"priority_sales": main.priority_sales_week,
			"clean_bonus": main.cleanup.clean_bonus_week,
			"coffee_cups": main.break_room.coffee_cups_week,
		},
		"endless": {
			"wallet": en.wallet,
			"upgrades": en.upgrades.duplicate(),
			"shift_number": en.shift_number,
			"run_stats": en.run_stats.duplicate(true),
			"week_summary": en.week_summary.duplicate(true),
		},
	}

static func write(path: String, data: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("[Save] couldn't write %s: %s" % [tmp, error_string(FileAccess.get_open_error())])
		return false
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		push_warning("[Save] couldn't move %s into place: %s" % [tmp, error_string(err)])
		return false
	return true

## [status, clean data]. The data is {} unless the status is LOAD_OK.
static func read(path: String) -> Array:
	if not FileAccess.file_exists(path):
		return [LOAD_NONE, {}]
	var text := FileAccess.get_file_as_string(path)
	# An instance parse, not JSON.parse_string(): a damaged file is an
	# expected case here, not an engine error to print.
	var json := JSON.new()
	var parsed = json.data if text.strip_edges() != "" and json.parse(text) == OK else null
	if not parsed is Dictionary:
		_quarantine(path, "not a JSON object")
		return [LOAD_CORRUPT, {}]
	var version := int(clampf(_num(parsed.get("version"), -1), -1, 1e6))
	if version < 1 or version > VERSION:
		_quarantine(path, "unknown save version %s" % str(parsed.get("version")))
		return [LOAD_CORRUPT, {}]
	return [LOAD_OK, sanitize(parsed)]

## Every field cast and clamped; anything missing gets its fresh-game value.
static func sanitize(raw: Dictionary) -> Dictionary:
	var story: Dictionary = _dict(raw.get("story"))
	var week: Dictionary = _dict(raw.get("week"))
	var en: Dictionary = _dict(raw.get("endless"))
	var complete := bool(story.get("complete", false)) if story.get("complete") is bool else false
	var day := int(clampf(_num(story.get("completed_day"), 0), 0, STORY_DAYS))
	if complete:
		day = STORY_DAYS
	var upgrades := {}
	var raw_up: Dictionary = _dict(en.get("upgrades"))
	for u in preload("res://Endless.gd").UPGRADES:
		var lvl := int(clampf(_num(raw_up.get(u["key"]), 0), 0, u["costs"].size()))
		if lvl > 0:
			upgrades[u["key"]] = lvl
	var rs: Dictionary = _dict(en.get("run_stats"))
	var medals := [0, 0, 0, 0]
	var raw_medals = rs.get("medals")
	if raw_medals is Array:
		for i in mini(4, raw_medals.size()):
			medals[i] = _count(raw_medals[i])
	var ws: Dictionary = _dict(en.get("week_summary"))
	var week_summary := {}
	for k in ["sold", "pay", "writeups", "priority_sales", "clean_bonus"]:
		if ws.has(k):
			week_summary[k] = int(clampf(_num(ws[k], 0), -1e9, 1e9)) # pay can be negative
	return {
		"story": {"completed_day": day, "complete": complete},
		"week": {
			"sold": _count(week.get("sold")),
			"writeups": _count(week.get("writeups")),
			"priority_sales": _count(week.get("priority_sales")),
			"clean_bonus": _count(week.get("clean_bonus")),
			"coffee_cups": _count(week.get("coffee_cups")),
		},
		"endless": {
			"wallet": _count(en.get("wallet")),
			"upgrades": upgrades,
			"shift_number": _count(en.get("shift_number")),
			"run_stats": {
				"shifts": _count(rs.get("shifts")),
				"sold": _count(rs.get("sold")),
				"bucks": _count(rs.get("bucks")),
				"medals": medals,
			},
			"week_summary": week_summary,
		},
	}

static func _dict(v) -> Dictionary:
	return v if v is Dictionary else {}

static func _num(v, fallback: float) -> float:
	if (v is float or v is int) and is_finite(float(v)):
		return float(v)
	return fallback

## A non-negative whole number, capped well clear of int overflow.
static func _count(v) -> int:
	return int(clampf(_num(v, 0), 0, 1e9))

static func _quarantine(path: String, why: String) -> void:
	push_warning("[Save] %s is unusable (%s) — starting fresh; copied it to %s.bad" % [path, why, path])
	DirAccess.copy_absolute(path, path + ".bad")
