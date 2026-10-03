extends Node2D
## WEEK 27 — juice: the small, fast visual feedback that makes actions the
## player already takes feel like they landed. Purely cosmetic and purely
## local: nothing here is replicated, nothing here changes a number, nothing
## mechanical reads anything here. Built by Main.gd in _ready(), like
## SoundDirector.
##
## SAME RULE AS SoundDirector.gd (WEEK 22): an effect about the shared world
## comes from REPLICATED state this peer already has, or from a reliable
## call_local RPC that already IS the moment on every peer — so it fires at
## the same moment on every peer, once, with no new network traffic and
## nothing for a late joiner to "discover" all at once (same WARMUP).
##   Watched here (replicated state, edge-triggered): sales (Cashier
##   total_sold + Main.priority_sales_today), a shelf slot filling / a shelf
##   wrecked (Shelf.filled / wrecked), a display toppling, a spill appearing,
##   messes cleared + SPOTLESS (Cleanup), the report / medal / Week Complete,
##   a new priority order, Bucks spent in the hub.
##   Hooked (reliable call_local RPCs, one line each): write-up, order
##   filled/missed, a forklift clipping a player, coffee, pickup/drop/throw.
##   Physics thuds: Sfx.played (the host's impact broadcast already reaches
##   every peer through it, rate-limited by Sfx's own anti-spam).
##
## WHAT IT DRAWS, AND WHERE:
## - World effects (score popups, cartoon impact stars, dust, sparkles,
##   confetti) are drawn by this one node at Z_JUICE — ABOVE the floor,
##   shelves, people and stock, but BELOW Ambience's darkness (Z_DARKNESS)
##   and every hazard marker drawn above it (Z_EMISSIVE: the forklift's
##   beacon/BEEP, the manager's "?"/"!" and cone, wet-floor signs, shelf
##   prompts). So a hazard cue ALWAYS draws over a score popup, by
##   construction, and the alert banners are CanvasLayers above the world
##   entirely. One _draw for everything: no node per particle.
## - The report / Week Complete payoff draws on its own CanvasLayer just
##   above the report (modal screens: nothing to compete with there).
## - Squash/flash tweens on the existing sprites (players, stock) and a
##   scale punch on existing UI labels (order banner, report medal line).
## - Screen shake: the LOCAL camera's offset only, a small trauma model
##   (offset = SHAKE_MAX_PX * trauma^2), scaled by distance from what you're
##   looking at, so only impacts you can actually see shake your view.
##   --no-shake turns it off.
##
## UNDER LOAD (Day 6-7, a 17-customer endless shift): hard caps on live
## popups/particles/bursts (oldest dropped first), sales at one register
## within COALESCE_SECONDS merge into ONE popup whose number grows ("+$30"),
## and trauma is capped at 1 so stacked impacts never compound into a
## violent shake.

const Z_JUICE := 90 # under Ambience.Z_DARKNESS (100) and Z_EMISSIVE (110)
const WARMUP := 1.5
## --- popups ---
const POPUP_LIFE := 1.05
const POPUP_RISE := 30.0
const POPUP_FONT := 16
const POPUP_BIG_FONT := 26
const COALESCE_SECONDS := 0.6
const MAX_POPUPS := 10
## --- particles / bursts ---
const MAX_PARTICLES := 240
const MAX_BURSTS := 10
## --- shake ---
const SHAKE_MAX_PX := 8.0
const SHAKE_DECAY := 2.2 # trauma per second
const SHAKE_RANGE := 620.0 # px from the view centre at which an impact stops shaking you
## --- colours (cartoon palette) ---
const C_MONEY := Color(1.0, 0.86, 0.3)
const C_RUSH := Color(1.0, 0.62, 0.2)
const C_LOSS := Color(1.0, 0.36, 0.28)
const C_COFFEE := Color(1.0, 0.8, 0.45)
const C_GOOD := Color(0.55, 1.0, 0.55)
const C_WATER := Color(0.45, 0.75, 1.0)
const C_DUST := Color(0.58, 0.52, 0.45) # reads on the light store floors
const C_POW := Color(1.0, 0.93, 0.55) # impact-star fill; a dark outline does the contrast
const C_WHITE := Color(1, 1, 1)
const CONFETTI := [Color(1.0, 0.85, 0.25), Color(0.4, 0.85, 1.0), Color(1.0, 0.45, 0.55), Color(0.55, 1.0, 0.5), Color(0.85, 0.6, 1.0)]

## Every effect fired (tests listen): kind, world/screen position.
signal fired(kind: String, pos: Variant)

var main: Node
var shake_enabled := not ("--no-shake" in OS.get_cmdline_user_args())
var _warmup := WARMUP
var _was_active := false

## Live effects. Popups: {pos, text, color, t, life, amount, key, fmt, size, pop}
var popups: Array = []
var particles: Array = [] # {p, v, t, life, c, s, g, kind, rot, spin}
var bursts: Array = [] # {p, t, life, r, c, spikes}
var ui_particles: Array = []
var ui_popups: Array = []
var trauma := 0.0
var _shake_t := 0.0
var _camera: Camera2D = null

## Diagnostics the tests read.
var counts := {} # kind -> times fired
var peak_popups := 0
var peak_particles := 0
var peak_bursts := 0
var dropped := 0 # effects culled by the caps
var peak_trauma := 0.0
var shake_offset := Vector2.ZERO

## Watcher state (last value seen).
var _sold := {} # cashier body -> total_sold
var _last_sale_cashier: Node = null
var _priority_sales := 0
var _slot_filled := {} # shelf body -> Array[bool]
var _wrecked := {} # shelf body -> bool
var _toppled := {} # display body -> bool
var _spill_pos := {} # id -> Vector2
var _litter_pos := {} # id -> Vector2
var _mess_left := -1
var _knocked := {} # product name -> its node
var _report_shown := false
var _report_payout_shift := -1
var _screen := 0
var _wallet := 0
var _orders_called := 0
var _shift_active := false

var _ui_layer: CanvasLayer
var _ui_fx: Node2D
var _font: Font

func _ready() -> void:
	main = get_parent()
	z_index = Z_JUICE
	z_as_relative = false
	_font = ThemeDB.fallback_font
	_ui_layer = CanvasLayer.new()
	_ui_layer.name = "JuiceUILayer"
	_ui_layer.layer = main.UI_LAYER_REPORT + 1
	add_child(_ui_layer)
	_ui_fx = Node2D.new()
	_ui_fx.name = "JuiceUI"
	_ui_fx.draw.connect(_draw_ui)
	_ui_layer.add_child(_ui_fx)
	Sfx.played.connect(_on_sound)

## --- frame -------------------------------------------------------------------

func _process(delta: float) -> void:
	var active := Net.is_active()
	if active and not _was_active:
		_warmup = WARMUP
	_was_active = active
	_tick_effects(delta)
	_update_shake(delta)
	if not active:
		return
	var quiet := _warmup > 0.0
	_warmup = maxf(0.0, _warmup - delta)
	if main.shift_active and not _shift_active:
		_warmup = maxf(_warmup, 0.6) # the day reset empties every shelf at once
	_shift_active = main.shift_active
	_watch_sales(quiet)
	_watch_shelves(quiet)
	_watch_spills(quiet)
	_watch_cleanup(quiet)
	_watch_orders(quiet)
	_watch_report(quiet)

func _tick_effects(delta: float) -> void:
	for list in [popups, ui_popups]:
		for i in range(list.size() - 1, -1, -1):
			var p: Dictionary = list[i]
			p["t"] += delta
			p["pop"] = maxf(0.0, p["pop"] - delta)
			if p["t"] >= p["life"]:
				list.remove_at(i)
	for list in [particles, ui_particles]:
		for i in range(list.size() - 1, -1, -1):
			var q: Dictionary = list[i]
			q["t"] += delta
			if q["t"] >= q["life"]:
				list.remove_at(i)
				continue
			q["v"] += Vector2(0, q["g"]) * delta
			q["v"] *= 1.0 - minf(1.0, q.get("drag", 2.0) * delta)
			q["p"] += q["v"] * delta
			q["rot"] += q["spin"] * delta
	for i in range(bursts.size() - 1, -1, -1):
		bursts[i]["t"] += delta
		if bursts[i]["t"] >= bursts[i]["life"]:
			bursts.remove_at(i)
	peak_popups = maxi(peak_popups, popups.size())
	peak_particles = maxi(peak_particles, particles.size() + ui_particles.size())
	peak_bursts = maxi(peak_bursts, bursts.size())
	if not (popups.is_empty() and particles.is_empty() and bursts.is_empty()) or _drew_world:
		queue_redraw()
	if not (ui_popups.is_empty() and ui_particles.is_empty()) or _drew_ui:
		_ui_fx.queue_redraw()

## --- the public effects ----------------------------------------------------------

func _note(kind: String, pos: Variant) -> void:
	counts[kind] = counts.get(kind, 0) + 1
	fired.emit(kind, pos)

## A floating "+$X" (or any short text) at a world position, rising and
## fading. `key` coalesces: a second popup with the same key while the first
## is young adds to its amount and re-pops it instead of stacking a new one.
func popup(pos: Vector2, amount: int, fmt: String, color: Color, key: Variant = null, big := false, life := POPUP_LIFE) -> void:
	if key != null:
		for p in popups:
			if typeof(p["key"]) == typeof(key) and p["key"] == key and p["t"] < COALESCE_SECONDS:
				p["amount"] += amount
				p["text"] = fmt % p["amount"] if fmt.contains("%") else fmt
				p["t"] = minf(p["t"], 0.12)
				p["pop"] = 0.16
				return
	if popups.size() >= MAX_POPUPS:
		popups.pop_front()
		dropped += 1
	popups.append({"pos": pos, "text": fmt % amount if fmt.contains("%") else fmt, "color": color, "t": 0.0, "life": life, "amount": amount, "key": key, "fmt": fmt, "size": POPUP_BIG_FONT if big else POPUP_FONT, "pop": 0.16})

func ui_popup(pos: Vector2, text: String, color: Color, big := true, life := 1.6) -> void:
	if ui_popups.size() >= MAX_POPUPS:
		ui_popups.pop_front()
	ui_popups.append({"pos": pos, "text": text, "color": color, "t": 0.0, "life": life, "amount": 0, "key": null, "fmt": "", "size": 34 if big else 20, "pop": 0.22})

## A cartoon "POW" star at a world position: a spiky flash that pops out and
## fades in a quarter second.
func burst(pos: Vector2, radius: float, color := C_POW, life := 0.26) -> void:
	if bursts.size() >= MAX_BURSTS:
		bursts.pop_front()
		dropped += 1
	bursts.append({"p": pos, "t": 0.0, "life": life, "r": radius, "c": color, "spikes": 8, "a0": randf() * TAU})

## `n` particles from `pos`. kind: 0 dot, 1 confetti (spinning rect), 2 spark (streak).
func spray(list: Array, pos: Vector2, n: int, color_or_palette: Variant, speed: Vector2, life: Vector2, gravity := 0.0, kind := 0, size := 3.0, up_bias := 0.0) -> void:
	for i in n:
		if list.size() >= MAX_PARTICLES:
			list.pop_front()
			dropped += 1
		var a := randf() * TAU
		var v := Vector2.RIGHT.rotated(a) * randf_range(speed.x, speed.y) + Vector2(0, -up_bias)
		var c: Color = color_or_palette[randi() % color_or_palette.size()] if color_or_palette is Array else color_or_palette
		list.append({"p": pos, "v": v, "t": 0.0, "life": randf_range(life.x, life.y), "c": c, "s": size * randf_range(0.7, 1.3), "g": gravity, "kind": kind, "rot": randf() * TAU, "spin": randf_range(-9.0, 9.0), "drag": 1.2 if kind == 1 else 3.0})

## Adds camera trauma for an impact at a world position (falls off with
## distance from what this peer is looking at; nothing off-screen shakes you).
func shake_at(pos: Vector2, amount: float) -> void:
	var cam := _local_camera()
	if cam == null:
		return
	var d := cam.get_screen_center_position().distance_to(pos)
	shake(amount * clampf(1.0 - d / SHAKE_RANGE, 0.0, 1.0))

func shake(amount: float) -> void:
	if not shake_enabled or amount <= 0.0:
		return
	trauma = minf(1.0, trauma + amount)
	peak_trauma = maxf(peak_trauma, trauma)

## Squash-and-stretch + optional flash on a character (Player / NPC) sprite.
## CharacterSprite is top-left anchored with its feet at FEET_AT, so the
## position is re-derived each step to keep the feet planted.
func squash_character(owner_node: Node, squash: Vector2, flash := Color(1, 1, 1, 0), seconds := 0.32) -> void:
	var s = owner_node.get_node_or_null("CharacterSprite")
	if s == null or not (s is Sprite2D):
		return
	var base: float = s.ART_SCALE
	var prev = s.get_meta("juice_tween") if s.has_meta("juice_tween") else null
	if prev is Tween and prev.is_valid():
		prev.kill()
	var tw := s.create_tween()
	s.set_meta("juice_tween", tw)
	var apply := func(k: Vector2) -> void:
		s.scale = base * k
		s.position = s.FEET_AT - s.FEET_PX * s.scale
	tw.tween_method(apply, squash, Vector2.ONE, seconds).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	if flash.a > 0.0:
		s.self_modulate = flash
		tw.parallel().tween_property(s, "self_modulate", C_WHITE, seconds * 0.6)

## Scale pop on a physics body's VISUALS (never the body: that's physics).
func pop_body(body: Node, from: Vector2, seconds := 0.22) -> void:
	if body == null or not is_instance_valid(body):
		return
	var prev = body.get_meta("juice_tween") if body.has_meta("juice_tween") else null
	if prev is Tween and prev.is_valid():
		prev.kill()
	var visuals: Array = []
	for c in body.get_children():
		if c is Node2D and not (c is CollisionShape2D or c is CollisionPolygon2D):
			visuals.append(c)
	if visuals.is_empty():
		return
	var tw := body.create_tween()
	body.set_meta("juice_tween", tw)
	var apply := func(k: Vector2) -> void:
		for v in visuals:
			if is_instance_valid(v):
				v.scale = k
	tw.tween_method(apply, from, Vector2.ONE, seconds).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

## A scale punch on a UI Control, from its centre.
func punch_control(c: Control, from := 1.25, seconds := 0.35) -> void:
	if c == null:
		return
	var prev = c.get_meta("juice_tween") if c.has_meta("juice_tween") else null
	if prev is Tween and prev.is_valid():
		prev.kill()
	c.pivot_offset = c.size / 2.0
	c.scale = Vector2(from, from)
	var tw := c.create_tween()
	c.set_meta("juice_tween", tw)
	tw.tween_property(c, "scale", Vector2.ONE, seconds).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

## A punch for a Label that lives in a Container (the report's lines): a
## Container resets its children's scale on every re-layout, so these punch
## their font size instead, then put back exactly what was there.
func punch_font(l: Label, from := 1.4, seconds := 0.45) -> void:
	if l == null:
		return
	if not l.has_meta("juice_font_base"):
		l.set_meta("juice_font_base", [l.has_theme_font_size_override("font_size"), l.get_theme_font_size("font_size")])
	var base: Array = l.get_meta("juice_font_base")
	var prev = l.get_meta("juice_tween") if l.has_meta("juice_tween") else null
	if prev is Tween and prev.is_valid():
		prev.kill()
	var tw := l.create_tween()
	l.set_meta("juice_tween", tw)
	tw.tween_method(func(k: float) -> void: l.add_theme_font_size_override("font_size", roundi(base[1] * k)), from, 1.0, seconds).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_callback(func() -> void:
		if base[0]:
			l.add_theme_font_size_override("font_size", base[1])
		else:
			l.remove_theme_font_size_override("font_size"))

## --- hooks (called from existing reliable call_local RPCs, every peer) ----------

## Main._announce_writeup(): "-$25" over whoever got it, a red flash and a
## wince, and a small jolt only for the one written up.
func writeup(peer_id: int, penalty: int) -> void:
	var p = main.players.get(peer_id)
	if p == null or not is_instance_valid(p):
		return
	var at: Vector2 = p.global_position + Vector2(0, -44)
	popup(at, penalty, "-$%d", C_LOSS, null, false, 1.3)
	squash_character(p, Vector2(1.25, 0.75), Color(1.9, 0.6, 0.5))
	if Net.is_active() and peer_id == multiplayer.get_unique_id():
		shake(0.32)
	_note("writeup", at)

## Main._announce_order_result(): the banner punches; a filled order throws
## a burst of confetti up from the bottom of your view (world space, under
## the hazard cues).
func order_result(filled: bool) -> void:
	punch_control(main._order_label, 1.3 if filled else 1.1)
	if filled:
		var cam := _local_camera()
		if cam:
			var c := cam.get_screen_center_position() + Vector2(0, 150)
			for k in 3:
				spray(particles, c + Vector2((k - 1) * 160.0, 0), 12, CONFETTI, Vector2(140, 300), Vector2(0.9, 1.3), 420.0, 1, 4.0, 260.0)
		_note("order_filled", null)
	else:
		_note("order_missed", null)

## Player.forklift_hit(): cartoon BONK on whoever got clipped — star burst,
## white flash, squash; a proper jolt if it's you.
func forklift_hit(p: Node2D) -> void:
	var at := p.global_position + Vector2(0, -12)
	burst(at, 34.0, C_POW)
	spray(particles, at, 6, C_DUST, Vector2(60, 140), Vector2(0.3, 0.5), 0.0, 0, 3.5)
	squash_character(p, Vector2(1.35, 0.65), Color(2.4, 2.4, 2.4), 0.4)
	if Net.is_active() and p.get_multiplayer_authority() == multiplayer.get_unique_id():
		shake(0.6)
	else:
		shake_at(at, 0.22)
	_note("forklift_hit", at)

## BreakRoom._announce_coffee(): a perk-up over the drinker.
func coffee(peer_id: int) -> void:
	var p = main.players.get(peer_id)
	if p == null or not is_instance_valid(p):
		return
	var at: Vector2 = p.global_position + Vector2(0, -46)
	popup(at, 0, "+%d%% SPEED" % roundi(main.break_room.COFFEE_SPEED_BONUS * 100.0), C_COFFEE, null, false, 1.3)
	spray(particles, at + Vector2(0, 20), 8, C_COFFEE, Vector2(30, 80), Vector2(0.4, 0.7), -60.0, 0, 3.0)
	squash_character(p, Vector2(0.8, 1.25))
	_note("coffee", at)

## Carryable's carrier RPCs: the item pops as it's grabbed, squashes as it's
## set down, stretches as it's thrown. Every peer (everyone can see it).
func carry(body: Node, kind: String) -> void:
	match kind:
		"pickup":
			pop_body(body, Vector2(1.3, 1.3))
		"drop":
			pop_body(body, Vector2(1.3, 0.75))
		"throw":
			pop_body(body, Vector2(0.75, 1.3), 0.3)
	_note("carry_" + kind, null)

## --- watchers (replicated state, every peer) ------------------------------------

## A popup per sale at that register: "+$10", coalescing while the line
## moves fast. A priority-order sale's extra lands on the same popup.
func _watch_sales(quiet: bool) -> void:
	for cashier_body in main.cashiers:
		var c: Node = cashier_body.get_node("Cashier")
		var sold: int = c.total_sold
		var prev: int = _sold.get(cashier_body, sold)
		if sold > prev and not quiet:
			var at: Vector2 = cashier_body.global_position + Vector2(0, -40)
			popup(at, (sold - prev) * main.PAY_PER_SALE, "+$%d", C_MONEY, cashier_body)
			spray(particles, at + Vector2(0, 14), 3, C_MONEY, Vector2(50, 90), Vector2(0.35, 0.55), 220.0, 0, 3.0, 80.0)
			_last_sale_cashier = cashier_body
			_note("sale", at)
		_sold[cashier_body] = sold
	var pri: int = main.priority_sales_today
	if pri > _priority_sales and not quiet:
		var bonus: int = main._priority_bonus(pri) - main._priority_bonus(_priority_sales)
		var anchor: Node = _last_sale_cashier if _last_sale_cashier != null and is_instance_valid(_last_sale_cashier) else null
		var cam := _local_camera()
		var at: Vector2 = anchor.global_position + Vector2(0, -62) if anchor else (cam.get_screen_center_position() if cam else Vector2.ZERO)
		popup(at, bonus, "+$%d RUSH", C_RUSH, "rush")
		_note("rush_bonus", at)
	_priority_sales = pri

## A slot filling: a little sparkle ring at the slot and the item pops into
## place. A shelf wrecked: POW, dust, and a jolt if you can see it. A display
## toppling: a smaller POW and some glass.
func _watch_shelves(quiet: bool) -> void:
	for shelf_body in main.shelves:
		var shelf: Node = shelf_body.get_node("Shelf")
		var now: Array = shelf.filled.duplicate()
		var prev: Array = _slot_filled.get(shelf_body, now)
		var wrecked: bool = shelf.wrecked
		var was: bool = _wrecked.get(shelf_body, wrecked)
		if not quiet:
			if wrecked and not was:
				var at: Vector2 = shelf_body.global_position
				burst(at, 64.0, C_POW, 0.3)
				spray(particles, at, 14, C_DUST, Vector2(80, 220), Vector2(0.4, 0.75), 0.0, 0, 4.5)
				shake_at(at, 0.55)
				_note("shelf_wreck", at)
			elif not wrecked and now.size() == prev.size():
				for i in now.size():
					if now[i] and not prev[i] and i < shelf.slots.size():
						var at: Vector2 = shelf.slots[i].global_position
						spray(particles, at, 6, C_WHITE, Vector2(70, 110), Vector2(0.18, 0.3), 0.0, 2, 2.0)
						pop_body(_item_near(at), Vector2(1.35, 1.35), 0.26)
						_note("shelf_place", at)
		_slot_filled[shelf_body] = now
		_wrecked[shelf_body] = wrecked
	for display_body in main.displays:
		var toppled: bool = display_body.get_node("Display").toppled
		if not toppled and _toppled.get(display_body, toppled) and main.cleanup_active and not quiet:
			_sparkle(display_body.global_position) # stood back up during cleanup
		if toppled and not _toppled.get(display_body, toppled) and not quiet:
			var at: Vector2 = display_body.global_position
			burst(at, 44.0, C_POW)
			spray(particles, at, 10, Color(0.75, 0.9, 1.0), Vector2(90, 200), Vector2(0.3, 0.6), 0.0, 2, 2.5)
			shake_at(at, 0.3)
			_note("display_topple", at)
		_toppled[display_body] = toppled

func _item_near(at: Vector2) -> Node:
	var best: Node = null
	var best_d := 26.0
	for obj in get_tree().get_nodes_in_group("carryable"):
		var d: float = obj.global_position.distance_to(at)
		if d < best_d:
			best_d = d
			best = obj
	return best

## A splash as a new spill appears (the wet-floor sign itself is Ambience's,
## drawn above all of this). A spill disappearing during cleanup = mopped:
## a sparkle where it was.
func _watch_spills(quiet: bool) -> void:
	var amb: Node = main.ambience
	var now := {}
	for s in (amb.spills if amb.spills_enabled() else []):
		now[s["id"]] = s["pos"]
		if not _spill_pos.has(s["id"]) and not quiet:
			spray(particles, s["pos"], 9, C_WATER, Vector2(60, 140), Vector2(0.25, 0.45), 0.0, 0, 3.0)
			_note("spill", s["pos"])
	if main.cleanup_active and not quiet:
		for id in _spill_pos:
			if not now.has(id):
				_sparkle(_spill_pos[id])
	_spill_pos = now

func _sparkle(at: Vector2) -> void:
	spray(particles, at, 10, [C_WHITE, Color(0.7, 0.95, 1.0), C_MONEY], Vector2(50, 120), Vector2(0.35, 0.6), 0.0, 2, 2.5)
	_note("mess_cleared", at)

## Litter swept up: a sparkle. The floor spotless: a big "SPOTLESS!" over you
## and a confetti burst.
func _watch_cleanup(quiet: bool) -> void:
	var cl: Node = main.cleanup
	var now := {}
	for l in cl.litter:
		now[l["id"]] = l["pos"]
	if main.cleanup_active and not quiet:
		for id in _litter_pos:
			if not now.has(id):
				_sparkle(_litter_pos[id])
	_litter_pos = now
	# Knocked stock picked up / re-shelved during cleanup (Cleanup's
	# replicated knocked_names): a sparkle where it is as it stops counting.
	var knocked := {}
	for n in cl.knocked_names:
		knocked[n] = _knocked[n] if _knocked.has(n) else main.find_child(n, true, false)
	if main.cleanup_active and not quiet:
		for n in _knocked:
			var obj = _knocked[n]
			if not knocked.has(n) and obj != null and is_instance_valid(obj):
				_sparkle(obj.global_position)
	_knocked = knocked
	var left: int = cl.mop_left + cl.litter_left
	if main.cleanup_active and not quiet and _mess_left > 0 and left == 0 and cl.mop_total + cl.litter_total > 0:
		var me = main.players.get(multiplayer.get_unique_id())
		var cam := _local_camera()
		var at: Vector2 = me.global_position + Vector2(0, -60) if me != null and is_instance_valid(me) else (cam.get_screen_center_position() if cam else Vector2.ZERO)
		popup(at, 0, "SPOTLESS!", C_GOOD, null, true, 1.6)
		spray(particles, at + Vector2(0, 30), 30, CONFETTI, Vector2(120, 280), Vector2(0.9, 1.3), 420.0, 1, 4.0, 220.0)
		_note("spotless", at)
	_mess_left = left if main.cleanup_active else -1

## A fresh priority order: the banner punches in (it's a call to action —
## this makes it read, it doesn't compete with it).
func _watch_orders(quiet: bool) -> void:
	var called: int = main.orders_called_today
	if called > _orders_called and main.order_section != "" and not quiet:
		punch_control(main._order_label, 1.2)
		_note("order_called", null)
	_orders_called = called

## The report / Week Complete payoff, on the modal screens. Story: the pay
## line punches in with a modest burst. Endless: the medal line STAMPS in —
## confetti scaled to the medal (gold gets the big one) — and "+N Bucks"
## floats up. Week Complete: the fanfare gets its confetti.
func _watch_report(quiet: bool) -> void:
	var shown: bool = main.report_layer.visible
	var vp := get_viewport().get_visible_rect().size
	if shown and not _report_shown and not quiet:
		if main.is_endless():
			_report_payout_shift = -1 # wait for the payout (see below)
		else:
			punch_font(main.report_pay_label, 1.35, 0.45)
			_confetti_ui(vp, 24)
			_note("report", null)
	if shown and main.is_endless() and not quiet:
		var p: Dictionary = main.endless.last_payout
		var shift: int = int(p.get("shift", -2))
		if shift == main.endless.shift_number and shift != _report_payout_shift:
			_report_payout_shift = shift
			var medal: int = int(p.get("medal", 0))
			punch_font(main.report_week_label, [1.2, 1.5, 1.7, 2.0][medal], 0.55)
			_confetti_ui(vp, [0, 16, 32, 70][medal])
			if int(p.get("total", 0)) != 0:
				ui_popup(Vector2(vp.x / 2.0, vp.y * 0.72), "%+d Bucks" % int(p["total"]), C_MONEY, false, 1.8)
			if medal == 3:
				ui_popup(Vector2(vp.x / 2.0, vp.y * 0.22), "GOLD!", Color(1, 0.82, 0.25), true, 1.6)
			_note("medal_%d" % medal, null)
	_report_shown = shown
	var screen: int = main.endless.screen
	if screen != _screen and screen == main.endless.SCREEN_WEEK_COMPLETE and not quiet:
		_confetti_ui(vp, 80)
		_note("week_complete", null)
	_screen = screen
	var wallet: int = main.endless.wallet
	if wallet < _wallet and screen == main.endless.SCREEN_HUB and not quiet:
		ui_popup(Vector2(vp.x * 0.5, vp.y * 0.16), "-%d Bucks" % (_wallet - wallet), C_LOSS, false, 1.2)
		_note("spend", null)
	_wallet = wallet

func _confetti_ui(vp: Vector2, n: int) -> void:
	if n <= 0:
		return
	for k in 2: # two cannons from the bottom corners
		var from := Vector2(vp.x * (0.08 if k == 0 else 0.92), vp.y + 10.0)
		for i in n / 2:
			if ui_particles.size() >= MAX_PARTICLES:
				ui_particles.pop_front()
				dropped += 1
			var dir := Vector2(0.45 if k == 0 else -0.45, -1.0).normalized().rotated(randf_range(-0.35, 0.35))
			ui_particles.append({"p": from, "v": dir * randf_range(420.0, 720.0), "t": 0.0, "life": randf_range(1.4, 2.0), "c": CONFETTI[randi() % CONFETTI.size()], "s": randf_range(3.5, 6.0), "g": 520.0, "kind": 1, "rot": randf() * TAU, "spin": randf_range(-10.0, 10.0), "drag": 0.9})

## Physics thuds (the host's broadcast, already rate-limited by Sfx): a puff
## of dust where it hit. Every peer gets these through Sfx.played.
func _on_sound(sound: String, pos: Variant) -> void:
	if not (pos is Vector2) or _warmup > 0.0:
		return
	match sound:
		"impact_heavy", "box_thud":
			spray(particles, pos, 4, C_DUST, Vector2(40, 90), Vector2(0.25, 0.4), 0.0, 0, 3.5)
			_note("thud", pos)
		"stack_collapse":
			spray(particles, pos, 8, C_DUST, Vector2(60, 150), Vector2(0.35, 0.6), 0.0, 0, 4.0)
			_note("collapse", pos)

## --- shake -----------------------------------------------------------------------

func _local_camera() -> Camera2D:
	if _camera != null and is_instance_valid(_camera) and _camera.enabled:
		return _camera
	_camera = null
	if not Net.is_active():
		return null
	var me = main.players.get(multiplayer.get_unique_id())
	if me != null and is_instance_valid(me):
		_camera = me.get_node_or_null("Camera") as Camera2D
	return _camera

func _update_shake(delta: float) -> void:
	var cam := _local_camera()
	trauma = maxf(0.0, trauma - SHAKE_DECAY * delta)
	if cam == null:
		return
	if trauma <= 0.0:
		if cam.offset != Vector2.ZERO:
			cam.offset = Vector2.ZERO
		shake_offset = Vector2.ZERO
		return
	_shake_t += delta
	var k := trauma * trauma * SHAKE_MAX_PX
	# Two incommensurate sines per axis: smooth wobble, not per-frame noise.
	shake_offset = Vector2(sin(_shake_t * 47.0) + 0.5 * sin(_shake_t * 83.0), sin(_shake_t * 53.0 + 1.3) + 0.5 * sin(_shake_t * 71.0)) / 1.5 * k
	cam.offset = shake_offset

## --- drawing ---------------------------------------------------------------------

var _drew_world := false
var _drew_ui := false

func _draw() -> void:
	_drew_world = not (popups.is_empty() and particles.is_empty() and bursts.is_empty())
	for b in bursts:
		var k: float = b["t"] / b["life"]
		var r: float = b["r"] * (0.45 + 0.55 * ease(k, 0.4))
		var c: Color = b["c"]
		c.a = 1.0 - k
		var pts := PackedVector2Array()
		var n: int = b["spikes"] * 2
		for i in n:
			var a: float = b["a0"] + TAU * i / n
			pts.append(b["p"] + Vector2.RIGHT.rotated(a) * (r if i % 2 == 0 else r * 0.45))
		draw_colored_polygon(pts, c)
		pts.append(pts[0])
		draw_polyline(pts, Color(0.18, 0.1, 0.04, c.a), 2.5)
	_draw_particles(self, particles)
	_draw_popups(self, popups)

func _draw_ui() -> void:
	_drew_ui = not (ui_popups.is_empty() and ui_particles.is_empty())
	_draw_particles(_ui_fx, ui_particles)
	_draw_popups(_ui_fx, ui_popups)

func _draw_particles(ci: CanvasItem, list: Array) -> void:
	for q in list:
		var k: float = q["t"] / q["life"]
		var c: Color = q["c"]
		c.a = 1.0 - k * k
		match int(q["kind"]):
			0:
				ci.draw_circle(q["p"], q["s"] * (1.0 - 0.5 * k), c)
			1:
				ci.draw_set_transform(q["p"], q["rot"], Vector2(1.0, absf(sin(q["rot"] * 1.7)) + 0.25))
				ci.draw_rect(Rect2(-q["s"], -q["s"] * 0.6, q["s"] * 2.0, q["s"] * 1.2), c)
				ci.draw_set_transform(Vector2.ZERO)
			2:
				ci.draw_line(q["p"], q["p"] - q["v"] * 0.05, c, q["s"])
	ci.draw_set_transform(Vector2.ZERO)

func _draw_popups(ci: CanvasItem, list: Array) -> void:
	for p in list:
		var k: float = p["t"] / p["life"]
		var rise: float = POPUP_RISE * ease(k, 0.4)
		var pop: float = 1.0 + 0.45 * (p["pop"] / 0.16)
		var a: float = 1.0 if k < 0.6 else 1.0 - (k - 0.6) / 0.4
		var size: int = p["size"]
		var w := _font.get_string_size(p["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		ci.draw_set_transform(p["pos"] - Vector2(0, rise), 0.0, Vector2(pop, pop))
		var at := Vector2(-w / 2.0, size * 0.35)
		ci.draw_string_outline(_font, at, p["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, size, 5, Color(0.1, 0.06, 0.02, 0.9 * a))
		var c: Color = p["color"]
		c.a = a
		ci.draw_string(_font, at, p["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, size, c)
	ci.draw_set_transform(Vector2.ZERO)
