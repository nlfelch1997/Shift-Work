extends RefCounted
## WEEK 24 — SAVE / LOAD. One small JSON file in user://, written and read by
## the HOST only (solo is a host with no clients). Main.gd owns the calls; this
## file only knows how to turn the game's state into a save, a save back into
## clean values, and how to get it on and off the disk without ever leaving a
## half-written file behind.
##
## WHAT IS SAVED — progress, never a shift in flight (VERSION 2, the Oct 2026
## shopkeeper economy):
## - the shop: the last FULLY COMPLETED day (a day only counts once its report
##   is up — quitting mid-day replays that day from its start), the crew's
##   bank, lifetime earnings, sections owned, the complication stage, and the
##   lifetime sales count.
## - endless (only reachable through the debug --endless route until Phase 4):
##   the Bucks wallet, every upgrade level, the run's totals, the shift
##   counter, the old week's results and whether it was unlocked.
## NOT saved: anything inside a shift (stock, customers, hazards, the clock),
## the shift board's postings and the coffee machine's per-shift cups.
##
## VERSION 1 SAVES (the 7-day story) are LOAD_LEGACY: story-day progress has no
## honest translation into "owns N sections with $X", so they are NOT migrated.
## The file is copied aside to <file>.v1.bak (never destroyed), and Main.gd
## starts the crew fresh with a one-time message saying why.
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
## is NOT loaded: the game starts fresh (Day 1, empty bank) and the bad file
## is copied aside to <file>.bad so the next save can't destroy the evidence.

const VERSION := 2
const LEGACY_VERSION := 1 # the 7-day story's saves
const DEFAULT_PATH := "user://shiftwork_save.json"
const MAX_DAY := 1000000

const LOAD_NONE := 0 # no file: a fresh start
const LOAD_OK := 1
const LOAD_CORRUPT := 2 # a file was there but unusable: a fresh start
const LOAD_LEGACY := 3 # a pre-shopkeeper save: kept aside, a fresh start

## The save as plain data, from the host's live state.
static func snapshot(main: Node) -> Dictionary:
	var en: Node = main.endless
	return {
		"version": VERSION,
		"saved_at": Time.get_datetime_string_from_system(),
		"shop": {
			"completed_day": main.completed_story_day,
			"money": main.money,
			"lifetime_earned": main.lifetime_earned,
			"sections_owned": main.sections_owned,
			"stage": main.complication_stage,
			# Mid-shift (a purchase checkpoint) only the days already done count:
			# the shift in flight isn't saved, so neither are its sales.
			"lifetime_sold": main._sold_at_day_start if main.shift_active else main._total_sold(),
		},
		"endless": {
			"unlocked": main.story_complete,
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
	if version == LEGACY_VERSION:
		push_warning("[Save] %s is a pre-shopkeeper (version 1) save — not migrated; copied it to %s" % [path, legacy_backup_path(path)])
		DirAccess.copy_absolute(path, legacy_backup_path(path))
		return [LOAD_LEGACY, {}]
	if version < 1 or version > VERSION:
		_quarantine(path, "unknown save version %s" % str(parsed.get("version")))
		return [LOAD_CORRUPT, {}]
	return [LOAD_OK, sanitize(parsed)]

static func legacy_backup_path(path: String) -> String:
	return path + ".v1.bak"

## Every field cast and clamped; anything missing gets its fresh-game value.
static func sanitize(raw: Dictionary) -> Dictionary:
	var shop: Dictionary = _dict(raw.get("shop"))
	var en: Dictionary = _dict(raw.get("endless"))
	var sections := int(clampf(_num(shop.get("sections_owned"), 1), 1, 4))
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
		"shop": {
			"completed_day": int(clampf(_num(shop.get("completed_day"), 0), 0, MAX_DAY)),
			"money": int(clampf(_num(shop.get("money"), 0), -1e9, 1e9)), # can be in the red
			"lifetime_earned": _count(shop.get("lifetime_earned")),
			"sections_owned": sections,
			"stage": int(clampf(_num(shop.get("stage"), 0), 0, 5)),
			"lifetime_sold": _count(shop.get("lifetime_sold")),
		},
		"endless": {
			"unlocked": bool(en.get("unlocked")) if en.get("unlocked") is bool else false,
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
