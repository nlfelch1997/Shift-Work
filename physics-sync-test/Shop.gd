extends Node2D
## OCT 2026 PIVOT, PHASE 4 — THE BREAK ROOM SHOP, folded into ongoing play.
## Built in code by Main.gd's _ready() (explicit name "Shop", same on every
## peer — its synchronizer's path must match), drawn under Players like the
## rest of the break room.
##
## WHERE IT CAME FROM: Week 21's Endless Mode had a Break Room Shop on its hub
## screen, paid in BREAK ROOM BUCKS (a second currency the endless shifts
## paid out). Phase 2 parked that whole mode behind a debug --endless flag;
## Phase 4 retires the mode (the hub, the shift board, the Bucks) and keeps
## the shop: the SAME seven crew upgrades, the SAME effects (every read below
## is Endless.gd's, unchanged), now bought out of the crew's SHARED BANK.
##
## THE CURRENCY DECISION (Phase 4): one currency. The Bucks existed because
## endless shifts had no bank to pay into; the shopkeeper game does, and every
## other purchase (sections, helpers) already spends it. Prices are the old
## Bucks prices x BUCKS_TO_DOLLARS (10): the endless payout was 1 Buck a sale
## where Pay is $10 a sale, so a level costs the same number of SALES it
## always did. The whole shop is $5,600 — twice the whole store ($2,800), so
## it's a long-term sink for a crew that owns everything, and early on it
## competes honestly with saving for the next section. Spending never touches
## lifetime_earned (Main.gd's rule for every spend), so buying gear can never
## switch a complication back off. FLAGGED for Phase 5's balance pass.
##
## WHERE: THE GEAR LOCKERS — the two staff lockers in the break room's
## bottom-left corner (already in the room since Week 23). E at them,
## empty-handed, while a shift runs opens this player's shop panel; its
## buttons ask the host. Purchases happen during PREP only — the same window
## as buying a section or changing staff ("before you open").
##
## NETWORKING: host-authoritative, like the staff board. Any peer asks
## (_request_buy), the host checks the asker is at the lockers, the window,
## the price and the level the button was showing, then writes `upgrades`
## (replicated, ON_CHANGE). Two players buying the same level in the same
## instant buy it ONCE: the second request carries a level that's no longer
## current and is refused — no double charge.

const UPGRADES := [
	# PHASE 5 BALANCE: every price x7 (the whole shop $5,600 -> $39,200). It's
	# the long-term sink after the store is bought and staffed: measured, a
	# trained, full crew banks ~$4,000 a shift net, and the old prices were all
	# bought within a couple of shifts of the last section (x4 still finished by
	# shift ~19 solo; the target is ~24).
	{"key": "shoes", "name": "Comfy Sneakers", "desc": "+8% walking speed per level", "costs": [1400, 3150, 5600]},
	{"key": "brace", "name": "Back Brace", "desc": "+1 product at once: {interact} grabs till full, {interact} again sets all down", "costs": [2800, 7000]},
	{"key": "soles", "name": "Non-Slip Soles", "desc": "spills slow you less, you slide less", "costs": [1400, 3150]},
	{"key": "boots", "name": "Steel-Toe Boots", "desc": "shorter stun when the forklift hits you", "costs": [1050, 2450]},
	{"key": "alibi", "name": "Plausible Deniability", "desc": "manager takes +0.5s longer to write you up", "costs": [1750, 3850]},
	# PHASE 5: shown as "Cleaning Cart" (was "Janitor's Kit", which read like
	# the hireable janitor). The key stays "janitor": it's what every save's
	# "gear" block (and the v2-v4 endless upgrades) store.
	{"key": "janitor", "name": "Cleaning Cart", "desc": "mop & sweep 20% faster, dustpan +4", "costs": [1050, 2450]},
	{"key": "badge", "name": "Employee of the Month", "desc": "cosmetic: a gold star over the crew", "costs": [2100]},
]
## The old Bucks price x this = the $ price above (documentation; see header).
const BUCKS_TO_DOLLARS := 10

## --- the lockers (break room bottom-left; floor x 20..940, y 20..520) ---
const LOCKER_SPOT := Vector2(95.0, 405.0) # where you stand to use them
const LOCKER_RANGE := 70.0

## --- Replicated (ShopSync, ON_CHANGE, host authority). Reassigned, never
## mutated, so a change is plainly a new value to the synchronizer.
var upgrades: Dictionary = {}

## --- Host diagnostics (tests) ---
var purchases_applied := 0
var purchases_refused := 0

var main: Node
var panel: CanvasLayer
var _panel_root: Control
var _panel_sig := ""
var _hint: Label
## For tests: the panel's live buttons, key -> Button.
var buttons := {}

func _ready() -> void:
	main = get_parent()
	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	var path := NodePath(".:upgrades")
	config.add_property(path)
	config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE)
	sync.replication_config = config
	sync.name = "ShopSync" # explicit, identical name on every peer
	sync.set_multiplayer_authority(1)
	add_child(sync)
	_build_sign()
	_build_panel()

## --- Upgrade reads (every peer; the effects are Endless.gd's, unchanged) ------

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

## Save/load (host): only known keys, clamped to their max.
static func clean_upgrades(raw: Dictionary) -> Dictionary:
	var out := {}
	for u in UPGRADES:
		var v = raw.get(u["key"])
		if (v is int or v is float) and is_finite(float(v)):
			var lvl := int(clampf(float(v), 0, u["costs"].size()))
			if lvl > 0:
				out[u["key"]] = lvl
	return out

## --- Rules -----------------------------------------------------------------------

func near_lockers(pos: Vector2) -> bool:
	return pos.distance_to(LOCKER_SPOT) <= LOCKER_RANGE

func _prep_window() -> bool:
	return main.shift_active and not main.store_open and not main.cleanup_active and not main.is_day_report_active()

## Why `key` can't be bought right now ("" = it can).
func blocker(key: String) -> String:
	var cost := next_cost(key)
	if max_level(key) == 0:
		return "no such gear"
	if cost < 0:
		return "maxed out"
	if main.tutorial.active:
		return "practice shift — shop in a real shift"
	if not _prep_window():
		return "buy gear during prep, before you open"
	if main.money < cost:
		return "need %s more" % main._format_money(cost - main.money)
	return ""

## --- Requests (any peer) -> the host ---------------------------------------------

## Carries the level the button was showing (see the header's race note).
func request_buy(key: String) -> void:
	if multiplayer.is_server():
		buy(key, multiplayer.get_unique_id(), upgrade_level(key))
	else:
		_request_buy.rpc_id(1, key, upgrade_level(key))

@rpc("any_peer", "reliable")
func _request_buy(key: String, from_level: int) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	# Where the HOST sees the sender — no shopping from across the store.
	if main.players.has(sender) and near_lockers(main.players[sender].global_position):
		buy(key, sender, from_level)
	else:
		purchases_refused += 1
		print("[Shop] %s's %s request refused: not at the lockers" % [main.player_display_name(sender), key])

## Host-only: the one place gear is bought. Returns whether it happened.
func buy(key: String, by_peer: int, from_level := -1) -> bool:
	if not multiplayer.is_server():
		return false
	var why := blocker(key)
	if why == "" and from_level >= 0 and upgrade_level(key) != from_level:
		why = "someone just bought that"
	if why != "":
		purchases_refused += 1
		print("[Shop] %s can't buy %s: %s" % [main.player_display_name(by_peer), key, why])
		if by_peer == multiplayer.get_unique_id():
			_tell("%s: %s" % [_name_of(key), why])
		elif main.players.has(by_peer):
			_tell.rpc_id(by_peer, "%s: %s" % [_name_of(key), why])
		return false
	var cost := next_cost(key)
	main.money -= cost
	var next := upgrades.duplicate()
	next[key] = upgrade_level(key) + 1
	upgrades = next
	purchases_applied += 1
	print("[Shop] %s bought %s level %d for $%d — bank %s" % [main.player_display_name(by_peer), key, next[key], cost, main._format_money(main.money)])
	_announce.rpc(_name_of(key), next[key], cost, by_peer)
	main.save_progress("bought %s level %d" % [key, next[key]])
	return true

func _name_of(key: String) -> String:
	for u in UPGRADES:
		if u["key"] == key:
			return u["name"]
	return key

@rpc("authority", "call_local", "reliable")
func _announce(gear: String, level: int, cost: int, by_peer: int) -> void:
	var who: String = "You" if Net.is_active() and by_peer == multiplayer.get_unique_id() else main.player_display_name(by_peer)
	main.show_toast("%s bought %s (level %d) for the crew — $%d" % [who, gear, level, cost], Color(0.55, 1, 0.6), 3.5)
	Sfx.play("ui_buy")

@rpc("authority", "reliable")
func _tell(text: String) -> void:
	main.show_toast(text, Color(1, 0.85, 0.3), 2.5)

## --- The lockers' sign and prompt (every peer, visual) ----------------------------

func _build_sign() -> void:
	var sign_label := Label.new()
	sign_label.text = "GEAR"
	sign_label.add_theme_font_size_override("font_size", 10)
	sign_label.add_theme_color_override("font_color", Color(1, 0.95, 0.85))
	sign_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	sign_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sign_label.position = Vector2(59.0, 424.0)
	sign_label.size = Vector2(60, 14)
	add_child(sign_label)
	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.add_theme_color_override("font_color", Color(0.55, 0.9, 1))
	_hint.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_hint.position = LOCKER_SPOT + Vector2(-30, -62)
	_hint.size = Vector2(300, 20)
	_hint.z_index = 5
	_hint.visible = false
	add_child(_hint)

## --- The panel (every peer, local UI) -----------------------------------------------

func _build_panel() -> void:
	panel = CanvasLayer.new()
	panel.name = "ShopPanel"
	panel.layer = main.UI_LAYER_MENU
	panel.visible = false
	add_child(panel)
	_panel_root = Control.new()
	_panel_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(_panel_root)

## E at the lockers (Player.gd): open or close this peer's panel.
func toggle_panel() -> void:
	panel.visible = not panel.visible
	_panel_sig = ""

func _my_player() -> Node2D:
	var me := multiplayer.get_unique_id() if Net.is_active() else 1
	var p = main.players.get(me)
	return p if p != null and is_instance_valid(p) else null

func _process(_delta: float) -> void:
	var p := _my_player()
	var here: bool = p != null and near_lockers(p.global_position) and main.shift_active and not main.is_day_report_active() and not main.tutorial.active
	_hint.visible = here
	if here:
		_hint.text = Settings.key("interact") + ": close the shop" if panel.visible else Settings.key("interact") + ": gear shop — crew upgrades"
	if panel.visible and not here:
		panel.visible = false # walked off, the shift ended...
	if not panel.visible:
		return
	var sig := str([upgrades, main.money, _prep_window()])
	if sig != _panel_sig:
		_panel_sig = sig
		_rebuild_panel()

func _rebuild_panel() -> void:
	for c in _panel_root.get_children():
		c.queue_free()
	buttons.clear()
	var box := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.1, 0.93)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 8
	sb.content_margin_bottom = 10
	box.add_theme_stylebox_override("panel", sb)
	box.position = Vector2(110, 80) # below the PREP line (and the staff panel's height)
	box.custom_minimum_size = Vector2(740, 0)
	_panel_root.add_child(box)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 5)
	box.add_child(col)
	col.add_child(_ui_label("BREAK ROOM SHOP — GEAR FOR THE WHOLE CREW", 20, Color(1, 0.82, 0.25)))
	var why_window := "" if _prep_window() else "   ·   buy during prep, before you open"
	col.add_child(_ui_label("Permanent upgrades, paid out of the bank. Everyone on the crew gets them.  Bank: %s%s" % [main._format_money(main.money), why_window], 12, Color(0.8, 0.85, 0.95)))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 4)
	col.add_child(grid)
	for u in UPGRADES:
		grid.add_child(_row(u))

func _row(u: Dictionary) -> Control:
	var key: String = u["key"]
	var lvl := upgrade_level(key)
	var cost := next_cost(key)
	var row := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.13, 0.17)
	sb.set_corner_radius_all(5)
	sb.content_margin_left = 8
	sb.content_margin_right = 6
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	row.add_theme_stylebox_override("panel", sb)
	row.custom_minimum_size = Vector2(360, 0)
	var h := HBoxContainer.new()
	row.add_child(h)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 0)
	h.add_child(v)
	v.add_child(_ui_label("%s  Lv %d/%d" % [u["name"], lvl, u["costs"].size()], 13, Color(1, 0.82, 0.25) if lvl > 0 else Color(1, 1, 1)))
	var d := _ui_label(u["desc"].replace("{interact}", Settings.key("interact")), 11, Color(0.62, 0.64, 0.7))
	d.custom_minimum_size = Vector2(240, 0)
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(d)
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE # Space/Enter stay the game's keys
	b.custom_minimum_size = Vector2(84, 0)
	b.add_theme_font_size_override("font_size", 13)
	if cost < 0:
		b.text = "MAXED"
		b.disabled = true
	else:
		b.text = "Buy  $%d" % cost
		b.disabled = blocker(key) != ""
		b.pressed.connect(func(): request_buy(key))
	h.add_child(b)
	buttons[key] = b
	return row

func _ui_label(text: String, size: int, c: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", c)
	return l
