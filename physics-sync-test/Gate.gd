extends Node
class_name Gate
## A day-gated barrier between two store sections (Week 6, Part 1). Attach
## as a child (named exactly "Gate") of a StaticBody2D whose
## CollisionShape2D exactly fills the doorway gap in the divider wall on
## either side of it — see Main.tscn's four divider walls and Main.gd's
## SECTIONS data for which real section each gate corresponds to.
##
## Deliberately NOT authority/network-gated like Carryable/Shelf/Cashier:
## every peer parses the same --day= CLI flag (or the same default)
## independently in Main.gd and calls configure() with the identical
## result, so there's no live, unpredictable state here that needs a
## single broadcast source of truth the way shelf fill state or a carried
## item's position do.
##
## FLAGGED ASSUMPTION: this means every peer in a session must be launched
## with the SAME --day= value — there's no sync check that catches a
## mismatch, so two peers given different values would each compute a
## different locked/unlocked layout and could visibly disagree about
## whether a given doorway is passable. This is the same category of
## assumption --shift-seconds= already relies on (every peer must agree on
## it for the countdown to display consistently) — fine for a debug/testing
## flag, but a real day-progression system would need the host to decide
## the day and replicate it, not have every peer decide independently.
@export var required_day := 1 # this doorway opens once Main.gd's debug_day reaches this

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
	body.get_node("Locked").visible = not unlocked
	body.get_node("Open").visible = unlocked
	print("[%s] required_day=%d current_day=%d -> %s" % [body.name, required_day, current_day, "OPEN" if unlocked else "LOCKED"])
