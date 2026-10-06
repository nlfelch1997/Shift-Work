extends Node
## OCT 2026 PHASE 3D — THE STORE RATING, and the live "Today" earnings counter.
##
## ONE SENTENCE (the HUD and the practice shift say it): "Trash, spills and
## overflowing cans drag the store rating down — a better rating brings more
## customers and better prices."
##
## WHAT IT READS (mess_points(), host — every input is already replicated
## state, so a client could compute it too): loose litter on the floor
## (MESS_LITTER each), every spill and sticky puddle (MESS_SPILL each), and
## every overflowing (full) trash can or bin bag left lying on the floor
## (MESS_FULL_CAN each). Only open parts of the store count (litter only ever
## lands there; a locked section's can is hidden). Disruptive customers don't
## count — throwing them out has its own payoff (Main.gd's BOUNCE_PAY).
##
## HOW IT MOVES: the TARGET is 5 stars minus a star per `mess_per_star()`
## points (more floor = more slack: MESS_PER_STAR_BASE plus
## MESS_PER_STAR_PER_SECTION per section open past the first), clamped to 1-5.
## The live rating walks toward the target at a capped rate — FALL_PER_SEC
## down, RISE_PER_SEC up (slower: a reputation is quicker lost than won) — so
## one bad moment never whiplashes it, while a mess left for a minute shows.
## It only moves while the store is OPEN (customers are the ones judging it),
## not in prep, cleanup or the practice shift.
##
## IT PERSISTS: across shifts and in the save (SaveGame.gd v4); a new shop
## and every older save start at Main.RATING_START (3 stars), where the
## economy levers are exactly 1.0 — the pre-3D game.
##
## WHAT IT DOES (Main.gd, beside the other economy constants): the customer
## cap (RATING_CROWD_MULT) and each sale's pay (RATING_PRICE_MULT).
##
## THE HUD (every peer, top-right, under the debug HUD): "TODAY $85", the
## stars with an arrow for where it's heading, and what's dragging it down
## right now. A whole star gained or lost pops a toast.
##
## Every number here is a FLAGGED placeholder (Phase 5 is the balance pass).

const MESS_LITTER := 1.0
const MESS_SPILL := 3.0
const MESS_FULL_CAN := 4.0
const MESS_PER_STAR_BASE := 6.0
const MESS_PER_STAR_PER_SECTION := 3.0
const FALL_PER_SEC := 1.0 / 60.0 # a star a minute, at most
const RISE_PER_SEC := 1.0 / 90.0
const MIN_RATING := 1.0
const MAX_RATING := 5.0
## The trend arrow only shows when the target is this far off.
const TREND_DEADBAND := 0.05

## Host-written, replicated (own Sync, every tick: two floats).
var rating := 3.0
var target := 3.0
## [litter, spills, full cans + loose bags] — what the HUD says drags it down.
var mess_parts := [0, 0, 0]

var main: Node
var _layer: CanvasLayer
var _panel: PanelContainer
var _today: Label
var _stars: Label
var _why: Label
var _shown_stars := -1
var _shown_pay := 0
var _pay_pop := 0.0
var hud_visible := false # tests read it
var star_changes := 0 # tests read it

func _ready() -> void:
	main = get_parent()
	rating = main.RATING_START
	target = rating
	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	for prop in [".:rating", ".:target", ".:mess_parts"]:
		var path := NodePath(prop)
		config.add_property(path)
		config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config
	sync.name = "Sync" # explicit, identical name on every peer — see Player.gd's note
	sync.set_multiplayer_authority(1)
	add_child(sync)
	_build_hud()

## --- the rating (host) ------------------------------------------------------

## Points of mess on the floor right now, and the parts (see the header).
func mess_points() -> float:
	var parts := _mess_parts_now()
	return parts[0] * MESS_LITTER + parts[1] * MESS_SPILL + parts[2] * MESS_FULL_CAN

func _mess_parts_now() -> Array:
	var cl: Node = main.cleanup
	var spills: int = cl.puddles.size() + (main.ambience.spills.size() if main.ambience.spills_enabled() else 0)
	return [cl.litter.size(), spills, cl.full_cans() + cl.loose_bags()]

func mess_per_star() -> float:
	return MESS_PER_STAR_BASE + MESS_PER_STAR_PER_SECTION * maxi(0, main._unlocked_sections().size() - 1)

func target_for(mess: float) -> float:
	return clampf(MAX_RATING - mess / mess_per_star(), MIN_RATING, MAX_RATING)

## Host-only, every frame the store is open (Main.gd's _process()).
func tick_host(delta: float) -> void:
	if not multiplayer.is_server() or main.tutorial.active:
		return
	var parts := _mess_parts_now()
	if parts != mess_parts:
		mess_parts = parts
	target = target_for(mess_points())
	if rating > target:
		rating = maxf(target, rating - FALL_PER_SEC * delta)
	elif rating < target:
		rating = minf(target, rating + RISE_PER_SEC * delta)

## Save/load (host).
func set_rating(r: float) -> void:
	rating = clampf(r, MIN_RATING, MAX_RATING)
	target = rating

## --- the economy levers (every peer; Main.gd's constants) --------------------

static func lerp3(r: float, at: Array) -> float:
	if r <= 3.0:
		return lerpf(float(at[0]), float(at[1]), clampf((r - 1.0) / 2.0, 0.0, 1.0))
	return lerpf(float(at[1]), float(at[2]), clampf((r - 3.0) / 2.0, 0.0, 1.0))

func crowd_mult() -> float:
	return lerp3(rating, main.RATING_CROWD_MULT)

func price_mult() -> float:
	return lerp3(rating, main.RATING_PRICE_MULT)

## -1 falling, 0 steady, 1 rising.
func trend() -> int:
	if target < rating - TREND_DEADBAND:
		return -1
	if target > rating + TREND_DEADBAND:
		return 1
	return 0

## "★★★★☆" — rounded to whole stars (the number beside it has the decimal).
static func star_text(r: float) -> String:
	var n := clampi(roundi(r), 1, 5)
	return "★".repeat(n) + "☆".repeat(5 - n)

## --- the HUD (every peer) ------------------------------------------------------

func _build_hud() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "RatingLayer"
	_layer.layer = main.UI_LAYER_ALERTS
	add_child(_layer)
	_panel = PanelContainer.new()
	_panel.name = "RatingPanel"
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.offset_left = -232.0
	_panel.offset_right = -10.0
	_panel.offset_top = 10.0
	_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN # widens leftward, never off-screen
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.06, 0.08, 0.72)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 5
	style.content_margin_bottom = 6
	_panel.add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(box)
	_today = _label(22, Color(0.55, 1, 0.6))
	_stars = _label(18, Color(1, 0.85, 0.3))
	_why = _label(11, Color(0.85, 0.85, 0.85))
	for l in [_today, _stars, _why]:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		box.add_child(l)
	_panel.visible = false
	_layer.add_child(_panel)

func _label(size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

## What the counter shows: exactly Pay Today (Main.gd's _pay_today()) — and
## during cleanup, before the bonus is scored, the cleanliness bonus the floor
## would earn right now (Cleanup.gd's bonus_for(), the same formula
## clock-out uses), so the number never jumps at clock-out: what it says as
## the report comes up is what goes in the bank.
func today_pay() -> int:
	var pay: int = main._pay_today()
	if main.cleanup_active and main.cleanup.clean_bonus_today == 0:
		pay += main.cleanup.bonus_for(main._gross_pay_today())
	return pay

var today_text := "" # tests read what the counter says

func _process(delta: float) -> void:
	var show: bool = main.status_hud and Net.is_active() and not main.players.is_empty() and main.shift_active and not main.is_day_report_active() and not main.is_endless()
	hud_visible = show
	_panel.visible = show
	if not show:
		_shown_stars = -1
		return
	var pay := today_pay()
	today_text = "TODAY  %s" % main._format_money(pay)
	_today.text = today_text
	if pay != _shown_pay:
		_pay_pop = 0.25 if pay > _shown_pay else 0.0
		_shown_pay = pay
	_pay_pop = maxf(0.0, _pay_pop - delta)
	_today.scale = Vector2.ONE * (1.0 + _pay_pop * 0.6)
	_today.pivot_offset = _today.size * Vector2(1.0, 0.5)
	_today.add_theme_color_override("font_color", Color(0.55, 1, 0.6) if pay >= 0 else Color(1, 0.4, 0.3))
	if main.tutorial.active:
		_stars.text = "Store rating  %s  %.1f" % [star_text(rating), rating]
		_why.text = "Practice — no pay, the rating doesn't move"
		return
	var arrow: String = ["  ▼", "", "  ▲"][trend() + 1]
	_stars.text = "%s  %.1f%s" % [star_text(rating), rating, arrow]
	var falling := trend() < 0
	_stars.add_theme_color_override("font_color", Color(1, 0.4, 0.3) if falling and fmod(Time.get_ticks_msec() / 1000.0, 0.8) < 0.5 else Color(1, 0.85, 0.3))
	var bits := []
	if int(mess_parts[0]) > 0:
		bits.append("trash %d" % mess_parts[0])
	if int(mess_parts[1]) > 0:
		bits.append("spills %d" % mess_parts[1])
	if int(mess_parts[2]) > 0:
		bits.append("full cans %d" % mess_parts[2])
	_why.text = ("Dragging it down: " + " · ".join(bits)) if not bits.is_empty() else "Clean store: more customers, better prices"
	# A whole star crossed: say so (every peer, on its own screen).
	var whole := clampi(roundi(rating), 1, 5)
	# (Under the panel, not on the toast row — that's the write-ups'.)
	if _shown_stars > 0 and whole != _shown_stars and main.store_open and main.juice:
		var vp := get_viewport().get_visible_rect().size
		var at := Vector2(vp.x - 120.0, _panel.get_global_rect().end.y + 26.0)
		if whole < _shown_stars:
			main.juice.ui_popup(at, "▼ %d★ — clean up!" % whole, Color(1, 0.4, 0.3), false, 2.6)
		else:
			main.juice.ui_popup(at, "▲ %d★!" % whole, Color(0.55, 1, 0.6), false, 2.2)
		star_changes += 1
	_shown_stars = whole
