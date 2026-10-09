extends SceneTree
## OCT 2026 PHASE 4B — renders the janitor to PNGs for a look (the clip test:
## does it read as staff cleaning?): the staff panel's janitor row, Pat
## carrying a full can's bag to the dumpster, mopping a puddle, litter in
## hand, and walking the inspector round. Needs a display (not --headless):
##   xvfb-run -a godot --path . --script res://tools/janitor_shots.gd -- --server --day=5 --no-save --events=on
## PNGs land in user://janitor_shots/. Not part of the game.

var main: Node

## PHASE 5B PART 2A: a spot in a named room of the layout table — its centre,
## plus an offset — so a test says WHICH room it means instead of repeating
## raw world coordinates (main.areas; StoreLayout.gd).
func area_spot(id: String, offset := Vector2.ZERO) -> Vector2:
	return main.areas.center_of(id) + offset
var n := 0

func _initialize() -> void:
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	main.events_on = "--events=on" in OS.get_cmdline_user_args()
	main.cleanup_ceiling_override = 0.0
	_run.call_deferred()

func shot(shot_name: String) -> void:
	await process_frame
	await process_frame
	await process_frame
	DirAccess.make_dir_recursive_absolute("user://janitor_shots")
	var path := "user://janitor_shots/%02d_%s.png" % [n, shot_name]
	n += 1
	root.get_texture().get_image().save_png(path)
	print("SHOT  " + ProjectSettings.globalize_path(path))

func me() -> Node2D:
	return main.players[1]

func jan() -> Node2D:
	return main.staff.janitor

func wait(s: float) -> void:
	await create_timer(s).timeout

func until(cond: Callable, t: float) -> void:
	var left := t
	while left > 0.0 and not cond.call():
		await process_frame
		left -= 1.0 / 60.0

func _run() -> void:
	main.debug_label.visible = false
	while not main.shift_active:
		await process_frame
	await wait(0.5)
	main.prep_time_left = 9999.0
	main.money = 3000
	me().teleport_to(main.staff.BOARD_SPOT)
	await wait(0.4)
	main.staff.toggle_panel()
	await wait(0.3)
	await shot("panel_janitor_not_hired")
	main.staff.request("Janitor", "hire")
	await wait(0.4)
	await shot("panel_janitor_hired")
	main.staff.toggle_panel()
	main.test_hold_customers = true
	# A full can: the bag out to the dumpster.
	main.cleanup.set_can(2, main.cleanup.can_capacity())
	await until(func(): return jan().bag_n > 0, 40.0)
	await wait(2.0)
	me().teleport_to(jan().position + Vector2(-90, 40))
	await wait(0.3)
	await shot("carrying_a_bag")
	await until(func(): return jan().bag_n == 0, 60.0)
	me().teleport_to(jan().position + Vector2(-90, 0))
	await wait(0.3)
	await shot("at_the_dumpster")
	# A puddle and some litter in the hub.
	main.cleanup.drop_puddle(area_spot("hub", Vector2(60, -10)))
	for i in 3:
		main.cleanup.drop_litter(Vector2(1350 + i * 40, 720))
	main.open_store(1)
	await until(func(): return jan().work > 0.3, 60.0)
	me().teleport_to(jan().position + Vector2(-100, 30))
	await wait(0.1)
	await shot("mopping")
	await until(func(): return jan().hand >= 2, 40.0)
	me().teleport_to(jan().position + Vector2(-100, 30))
	await wait(0.1)
	await shot("litter_in_hand")
	# A Surprise Inspection: Pat walks the inspector round.
	main.events.reschedule = false
	main.events.force_next("inspection", 0.5)
	await until(func(): return main.events.active(), 30.0)
	await wait(1.0)
	me().teleport_to(jan().position + Vector2(-100, 30))
	await wait(0.3)
	await shot("with_the_inspector")
	quit()
