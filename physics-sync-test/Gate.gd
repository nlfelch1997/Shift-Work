extends Node
class_name Gate
## A day-gated barrier between two store sections. REDESIGNED after
## playtest feedback: the original version was a narrow ~120px doorway cut
## into two permanent wall segments (Main.tscn's old "DividerNUpper"/
## "DividerNLower" nodes), and multiple NPCs trying to path through that
## one opening at once jammed up instead of filing through. There is no
## doorway anymore — this component's own CollisionShape2D now spans the
## section boundary's FULL playable height (see Gate.tscn: 500px, matching
## the room interior exactly), so a locked section is sealed edge-to-edge
## (nothing to funnel through even while locked) and an unlocked one opens
## across the WHOLE boundary at once — no chokepoint to ever jam at.
## Main.tscn no longer has separate wall segments at a section boundary at
## all; this node alone is the entire boundary.
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
