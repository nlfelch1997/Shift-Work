extends SceneTree
## WEEK 21 — renders the new endless-mode screens to PNGs for a look: Day 7's
## report, WEEK COMPLETE, the hub (board + shop), a shift's start banner and
## its report. Needs a display (not --headless):
##   xvfb-run -a godot --path . --script res://tools/hub_shots.gd -- --server --day=7 --prep-seconds=0 --shift-seconds=4 --cleanup-seconds=0
## PNGs land in user://hub_shots/.

var main: Node
var n := 0

func _initialize() -> void:
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	_run.call_deferred()

func shot(name: String) -> void:
	await process_frame
	await process_frame
	await process_frame
	DirAccess.make_dir_recursive_absolute("user://hub_shots")
	var path := "user://hub_shots/%02d_%s.png" % [n, name]
	n += 1
	root.get_texture().get_image().save_png(path)
	print("SHOT  " + ProjectSettings.globalize_path(path))

func _run() -> void:
	main.debug_label.visible = false
	main.status_hud = false
	while not main.shift_active:
		await process_frame
	main.shift_time_left = 0.05
	while not main.is_day_report_active():
		await process_frame
	await shot("day7_report")
	main._on_continue_pressed()
	await shot("week_complete")
	main.hub_ui.enter_button.pressed.emit()
	await shot("hub")
	main.endless.request_buy("shoes")
	await shot("hub_after_buy")
	main.endless.request_take_offer(2)
	await create_timer(0.6).timeout
	await shot("shift_banner")
	main.shift_time_left = 0.05
	while not main.is_day_report_active():
		await process_frame
	await create_timer(0.3).timeout
	await shot("shift_report")
	main._on_continue_pressed()
	await shot("hub_again")
	quit(0)
