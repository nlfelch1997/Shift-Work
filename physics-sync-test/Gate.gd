extends Node
class_name Gate
## A day-gated barrier between two store sections. REDESIGNED after
## playtest feedback: the original version was a narrow ~120px doorway cut
## into two permanent wall segments (Main.tscn's old "DividerNUpper"/
## "DividerNLower" nodes), and multiple NPCs trying to path through that
## one opening at once jammed up instead of filing through. There is no
## doorway anymore — this component's own CollisionShape2D now spans the
## section boundary's FULL length edge-to-edge (see Gate.tscn), so a locked
## section is sealed completely (nothing to funnel through even while
## locked) and an unlocked one opens across the WHOLE boundary at once — no
## chokepoint to ever jam at. Main.tscn no longer has separate wall
## segments at a section boundary at all; this node alone is the entire
## boundary.
##
## SIZED TO THE FULL ROOM DIMENSION (540px), NOT the original 500px
## "playable interior" — upgraded this session when the store's layout went
## from a single 1D line of rooms to a 2D hub-and-spoke grid (see Main.gd's
## GRID MAP comment). In the old line, every boundary sat between the
## world's permanent top/bottom outer walls, which always plugged the old
## 500px gate's 20px top/bottom margins for free — a gate never needed to
## cover more than the "interior," since something else always covered the
## rest. In the grid, several gated boundaries (e.g. hub<->MeatDeli, hub<->
## DairyFrozen) are fully INTERIOR — no outer wall anywhere near them — so
## a gate that only covered the old 500px interior would leave an
## unguarded 20px gap at each end, letting a customer walk diagonally
## around a "locked" gate through it. Sizing the gate to the full room span
## removes the assumption entirely: it seals its own boundary unassisted,
## whether or not a wall happens to help at either end.
##
## Deliberately NOT authority/network-gated like Carryable/Shelf/Cashier —
## same reasoning as before this redesign: every peer parses the same
## --day= CLI flag (or the same default) independently in Main.gd and
## calls configure() with the identical result, so there's no live,
## unpredictable state here that needs a single broadcast source of truth.
##
## FLAGGED ASSUMPTION, unchanged: every peer in a session must be launched
## with the SAME --day= value — there's no sync check that catches a
## mismatch. Same category of assumption --shift-seconds= already relies
## on; fine for a debug/testing flag, not for a real day-progression
## system later.

@export var required_day := 1 # this boundary opens once Main.gd's debug_day reaches this

var body: StaticBody2D
var collision: CollisionShape2D

func _ready() -> void:
	body = get_parent()
	body.add_to_group("gate")
	collision = body.get_node("CollisionShape2D")

## Called once by Main.gd right after it determines debug_day (from the
## --day= CLI flag or its default), independently on every peer.
func configure(current_day: int) -> void:
	var unlocked := current_day >= required_day
	collision.disabled = unlocked
	# Unlocked = fully invisible, not just passable — the brief asked for
	# one continuous open floor with no visible seam once a section is
	# open, not a floor that still shows where a door used to be. Locked
	# shows a thin marker line + the day it opens, so it reads as "not
	# open yet" instead of an unexplained invisible wall.
	body.get_node("Locked").visible = not unlocked
	body.get_node("Locked/Label").text = "LOCKED — opens Day %d" % required_day
	print("[%s] required_day=%d current_day=%d -> %s" % [body.name, required_day, current_day, "OPEN" if unlocked else "LOCKED"])
