extends "res://CustomerNav.gd"
## PHASE 5B PART 2B — THE TEST BOTS' MAP. Not part of the game. The bot
## brain (tools/hazards_test.gd: the solo/co-op sim, the income harness, the
## progression sim, walk_to()) used to walk a hand-written graph of the old
## nine rooms in straight lines, room centre to room centre — which only
## worked because every old room was an empty box with its shelves round the
## edge (Part 2A's report, "found along the way"). Plan B's rooms have
## gondolas in the middle and wings off the shop, so the bots now path over
## the real geometry instead: the shoppers' grid (CustomerNav.gd — same cell,
## same clearance, same walls, closed barriers, shelves, registers, displays
## and solid furniture), but with the player's access: no keep-out rooms
## (a player clocks in in the break room and works in Storage), loose stock
## not an obstacle (a player walks through it, nudging it), plus Storage's
## dock bay. The route is the layout's, not a copy of it, so a future layout
## change needs nothing here.

func _init(main_node: Node) -> void:
	super(main_node)

func _build() -> void:
	_astar.fill_solid_region(_astar.region, false)
	for body in main.get_node("Walls").get_children():
		_solid_body(body)
	for gate in main.get_node("Gates").get_children():
		var cs := gate.get_node_or_null("CollisionShape2D") as CollisionShape2D
		if cs != null and not cs.disabled:
			_solid_body(gate)
	for shelf_body in main.shelves:
		_solid_body(shelf_body)
	for cashier_body in main.cashiers:
		var cs := cashier_body.get_node("CollisionShape2D") as CollisionShape2D
		if not cs.disabled:
			_solid_body(cashier_body)
	for d in main.displays:
		_solid_circle(d.global_position, DISPLAY_RADIUS + CLEARANCE)
	for body in main.get_tree().get_nodes_in_group("nav_obstacle"):
		_solid_body(body)
	var bay := main.get_node_or_null("Delivery/DockBayBody")
	if bay != null:
		_solid_body(bay)
