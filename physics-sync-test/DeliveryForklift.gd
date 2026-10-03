extends "res://Forklift.gd"
## WEEK 15 — the Storage delivery forklift. A SECOND forklift, not the Produce
## one on another schedule (see the WEEK 15 note in Main.gd for why). Reuses
## Forklift.gd's whole driver — turning in place, drive/reverse legs, stall
## skip, the contact rules (knocks loose boxes and stock aside, bumps players
## with the same forklift_hit() knockback and tells the manager, shoves
## customers), the BEEP/beacon, host authority and client smoothing — and
## replaces only what it DOES: instead of patrolling an aisle and ramming
## shelves, it runs pallets from the truck at the dock to the receiving row.
## It never rams (no "ram" legs), so it never wrecks anything on purpose.
##
## One trip, built by _build_lap() whenever its leg list runs out:
##   truck parked with boxes, forks empty -> drive east to the dock, LOAD
##   forks loaded -> reverse west along the lane to a free receiving spot's
##     column, turn south, drive up to the spot, SET DOWN (a real box spawns
##     at the forks — Delivery.gd's drop_box()), reverse back to the lane
##   nothing to do -> go home and wait
## Its only facings are east, west and south, which is what lets it use the
## warehouse pack's side-view and front-view forklift sprites drawn upright
## (the pack has no top-down or rear view).
##
## Built by Main.gd from Forklift.tscn with this script swapped in, so the
## collision box, beacon and BEEP label are the Produce forklift's own.

const DOCK_REACH_GAP := 6.0 # forks stop this short of the truck's back doors
const SET_DOWN_PAUSE := 0.6
const IDLE_PAUSE := 0.5 # re-check for work this often while parked
const LOAD_REACH := 3.0 # how close to its load stop counts as "at the truck"
## Replicated (own synchronizer, see _ready()): the section of the box on the
## forks, "" when empty — drives the load sprite on every peer.
var carrying := ""
## Diagnostic (host): boxes set down today.
var drops_today := 0

var _load_art: Sprite2D
var _load_tag: Polygon2D
var _load_key := ""

func _ready() -> void:
	super._ready()
	# The Produce forklift is the "forklift" (Manager.gd looks it up by group).
	remove_from_group("forklift")
	add_to_group("delivery_forklift")
	var sync := MultiplayerSynchronizer.new()
	var config := SceneReplicationConfig.new()
	var path := NodePath(".:carrying")
	config.add_property(path)
	config.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config
	sync.name = "DeliverySync" # explicit, identical name on every peer
	sync.set_multiplayer_authority(1)
	add_child(sync)
	_load_art = Sprite2D.new()
	_load_art.name = "LoadArt"
	add_child(_load_art)
	_update_art()

## WEEK 17: unlike the Produce forklift, deliveries keep running through the
## prep phase (the store being closed is exactly when the stock arrives).
func _running(main) -> bool:
	return not main.is_day_report_active() and main.shift_active

func reset_for_new_day() -> void:
	super.reset_for_new_day()
	if is_multiplayer_authority():
		carrying = ""
		drops_today = 0

## WEEK 26: its own fixed driver (Forklift.gd's driver_look()).
func driver_look() -> String:
	return "driver_delivery"

func _delivery() -> Node:
	return get_tree().current_scene.delivery

func _fork_tip() -> Vector2:
	return global_position + Vector2.RIGHT.rotated(rotation) * (FRONT_REACH + _delivery().BOX_SIZE * 0.5 + 2.0)

func _build_lap() -> void:
	var d := _delivery()
	var lane_y: float = d.LANE_Y
	if carrying != "":
		var spot = d.free_receiving_spot()
		if spot == null:
			_legs.append({"pos": global_position, "mode": "drive", "pause": IDLE_PAUSE}) # row full: wait
			return
		var stop_y: float = spot.y - (FRONT_REACH + d.BOX_SIZE * 0.5 + 2.0)
		_legs.append({"pos": Vector2(spot.x, lane_y), "mode": "reverse" if global_position.x > spot.x else "drive"})
		_legs.append({"pos": Vector2(spot.x, stop_y), "mode": "drive", "action": "set_down", "pause": SET_DOWN_PAUSE})
		_legs.append({"pos": Vector2(spot.x, lane_y), "mode": "reverse"})
	elif d.truck_parked() and not d.truck_load.is_empty():
		var load_x: float = d.DOCK_X - DOCK_REACH_GAP - FRONT_REACH
		if absf(global_position.y - lane_y) > ARRIVE_DIST:
			_legs.append({"pos": Vector2(global_position.x, lane_y), "mode": "reverse"})
		_legs.append({"pos": Vector2(load_x, lane_y), "mode": "drive", "action": "load", "pause": LOAD_PAUSE})
	elif global_position.distance_to(home_position) > ARRIVE_DIST:
		if absf(global_position.y - lane_y) > ARRIVE_DIST:
			_legs.append({"pos": Vector2(global_position.x, lane_y), "mode": "reverse"})
		_legs.append({"pos": home_position, "mode": "reverse" if global_position.x > home_position.x else "drive", "pause": IDLE_PAUSE})
	else:
		_legs.append({"pos": global_position, "mode": "drive", "pause": IDLE_PAUSE})

func _finish_leg() -> void:
	var leg: Dictionary = _legs[0]
	super._finish_leg()
	match leg.get("action", ""):
		"load":
			# Only if it actually got to the truck (a stalled leg ends early).
			if carrying == "" and global_position.distance_to(leg["pos"]) <= LOAD_REACH + ARRIVE_DIST:
				carrying = _delivery().take_box_from_truck()
		"set_down":
			if carrying != "":
				_delivery().drop_box(_fork_tip(), carrying)
				carrying = ""
				drops_today += 1

## The truck itself is the base's pack sprite (Forklift.gd's _update_art());
## this adds the box on the forks.
func _update_art() -> void:
	super._update_art()
	if _load_art == null:
		return
	var front := Vector2.RIGHT.rotated(rotation).y > 0.7
	_load_art.visible = carrying != ""
	if carrying != "":
		if _load_key != carrying:
			_load_key = carrying
			var d := _delivery()
			var spr: Sprite2D = d.box_sprite("forks", d.BOX_SIZE + 4.0)
			_load_art.texture = spr.texture
			_load_art.region_enabled = true
			_load_art.region_rect = spr.region_rect
			_load_art.scale = spr.scale
			spr.free()
			if _load_tag:
				_load_tag.queue_free()
			_load_tag = d._section_tag(carrying)
			_load_art.add_child(_load_tag)
			_load_tag.scale = Vector2.ONE / _load_art.scale.x
		_load_art.rotation = -rotation
		_load_art.position = (Vector2.RIGHT * (FRONT_REACH + 4.0)) + Vector2(0, -10).rotated(-rotation)
		# In front of the truck when it's coming toward the camera.
		_load_art.z_index = 1 if front else 0
