extends SceneTree
## OCT 2026 PHASE 3 — renders the hired-helper pieces to PNGs for a look (the
## "clip test": does a staffed aisle read as staff working it?): the staff
## board and its prompt, the open staff panel (nobody hired / hired + trained),
## a helper at work in Produce (carrying, back stock by the pad), all three
## sections staffed with the store open, and the report's wage line. Needs a
## display (not --headless):
##   xvfb-run -a godot --path . --script res://tools/staff_shots.gd -- --server --day=7 --no-save --money=3000
## PNGs land in user://staff_shots/. Not part of the game.

var main: Node
var n := 0

func _initialize() -> void:
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	# OCT 2026 PHASE 4: random events (Events.gd) are off here — tools/events_test.gd
	# tests them; --events=on turns them on (the income runs measure both).
	main.events_on = "--events=on" in OS.get_cmdline_user_args()
	main.cleanup_ceiling_override = 0.0
	_run.call_deferred()

func shot(shot_name: String) -> void:
	await process_frame
	await process_frame
	await process_frame
	DirAccess.make_dir_recursive_absolute("user://staff_shots")
	var path := "user://staff_shots/%02d_%s.png" % [n, shot_name]
	n += 1
	root.get_texture().get_image().save_png(path)
	print("SHOT  " + ProjectSettings.globalize_path(path))

func me() -> Node2D:
	return main.players[1]

func wait(s: float) -> void:
	await create_timer(s).timeout

func _run() -> void:
	main.debug_label.visible = false
	while not main.shift_active:
		await process_frame
	await wait(0.5)
	main.prep_time_left = 9999.0
	me().teleport_to(main.staff.BOARD_SPOT)
	await wait(0.4)
	await shot("board_prompt")
	main.staff.toggle_panel()
	await wait(0.3)
	await shot("panel_nobody_hired")
	main.staff.request("Produce", "hire")
	main.staff.request("Dairy/Frozen", "hire")
	main.staff.request("Bakery", "hire")
	main.staff.request("Produce", "speed")
	main.staff.request("Produce", "carry")
	await wait(0.4)
	await shot("panel_hired")
	main.staff.toggle_panel()
	# Produce, with the helper at work (and a box or two in its back room).
	me().teleport_to(Vector2(2000, 940))
	var h: Node2D = main.staff.helpers["Produce"]
	var t := 0.0
	while h._held().size() < 2 and t < 60.0:
		await wait(0.2)
		t += 0.2
	await shot("produce_helper_carrying")
	await wait(6.0)
	await shot("produce_helper_shelving")
	# The store open: shoppers, the forklift, the helper among them.
	main.open_store(1)
	await wait(25.0)
	await shot("produce_open_store")
	me().teleport_to(Vector2(480, 940))
	await wait(1.0)
	await shot("dairy_open_store")
	me().teleport_to(Vector2(2000, 400))
	await wait(1.0)
	await shot("bakery_open_store")
	main.shift_time_left = 0.05
	while not main.is_day_report_active():
		await process_frame
	await wait(0.4)
	await shot("report_wages")
	quit(0)
