extends SceneTree
## OCT 2026 PHASE 2 — renders the shopkeeper economy's on-screen pieces to PNGs
## for a look: a for-sale gate and its prompt (can't afford / can buy), the
## purchase notice, the report's bank + forecast lines, a NEW: banner, the
## top-tier banner, the old-save notice. Needs a display (not --headless):
##   xvfb-run -a godot --path . --script res://tools/economy_shots.gd -- --server --no-save
## PNGs land in user://economy_shots/. Not part of the game.

var main: Node
var n := 0

func _initialize() -> void:
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	main.cleanup_ceiling_override = 0.0
	_run.call_deferred()

func shot(name: String) -> void:
	await process_frame
	await process_frame
	await process_frame
	DirAccess.make_dir_recursive_absolute("user://economy_shots")
	var path := "user://economy_shots/%02d_%s.png" % [n, name]
	n += 1
	root.get_texture().get_image().save_png(path)
	print("SHOT  " + ProjectSettings.globalize_path(path))

func me() -> Node2D:
	return main.players[1]

func end_day() -> void:
	main.shift_time_left = 0.05
	while not main.is_day_report_active():
		await process_frame
	await create_timer(0.3).timeout

func next_day() -> void:
	main._on_continue_pressed()
	while not main.shift_active:
		await process_frame
	await create_timer(0.4).timeout

func _run() -> void:
	main.debug_label.visible = false
	while not main.shift_active:
		await process_frame
	await create_timer(0.5).timeout
	me().teleport_to(Vector2(1880, 760))
	await create_timer(0.3).timeout
	await shot("gate_for_sale_broke")
	me().teleport_to(Vector2(1860, 830))
	await create_timer(0.3).timeout
	await shot("gate_sign_produce")
	me().teleport_to(Vector2(1860, 300))
	await create_timer(0.3).timeout
	await shot("gate_sign_bakery")
	main.cashiers[0].get_node("Cashier").total_sold += 60
	await end_day()
	await shot("report_forecast_affordable")
	await next_day()
	me().teleport_to(Vector2(1880, 760))
	await create_timer(0.3).timeout
	await shot("gate_prompt_can_buy")
	main.buy_section("Produce", 1)
	await create_timer(0.4).timeout
	await shot("purchase_notice")
	await end_day()
	await shot("report_next_shift_forklift")
	await next_day()
	await shot("banner_new_forklift")
	main.lifetime_earned = main.MANAGER_EARNED
	await end_day()
	await next_day()
	await shot("banner_new_manager")
	main.money = 99999
	main.lifetime_earned = main.RUSH_EARNED
	main.buy_section("Dairy/Frozen", 1)
	main.buy_section("Bakery", 1)
	for i in 3:
		await end_day()
		await next_day()
	await shot("banner_rush_season")
	await end_day()
	await shot("report_whole_store")
	await next_day()
	main.show_notice("NEW GAME", "This save predates the shopkeeper update — starting a new game.\n(Your old save is kept as shiftwork_save.json.v1.bak)", 10.0)
	await create_timer(0.3).timeout
	await shot("legacy_notice")
	quit(0)
