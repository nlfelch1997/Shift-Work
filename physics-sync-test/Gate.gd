extends Node
class_name Gate
## A barrier between two store sections (sealed until the section is bought). REDESIGNED after
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
## Deliberately NOT authority/network-gated like Carryable/Shelf/Cashier:
## every peer calls configure_open() from the same replicated state (Main.gd's
## sections_owned on DaySync), so there's nothing here to sync.

## OCT 2026 PHASE 2: sections are BOUGHT now, not opened by a day — Main.gd
## decides open/locked (is_section_open()) and what the locked side says
## ("FOR SALE — $600"), and calls configure_open() on every peer from the
## replicated sections_owned. (The old required_day/configure(current_day)
## pair is gone with the day gates.)

var body: StaticBody2D
var collision: CollisionShape2D

func _ready() -> void:
	body = get_parent()
	body.add_to_group("gate")
	collision = body.get_node("CollisionShape2D")

## Open (invisible, passable) or closed (sealed, with closed_text on its sign).
## WEEK 21 — endless shifts: by the taken posting. Phase 2: by ownership.
func configure_open(open: bool, closed_text: String) -> void:
	# Unlocked = fully invisible, not just passable — the brief asked for
	# one continuous open floor with no visible seam once a section is open.
	collision.disabled = open
	body.get_node("Locked").visible = not open
	var label: Label = body.get_node("Locked/Label")
	label.text = closed_text
	# A longer sign ("FOR SALE — $2600 (after Dairy/Frozen)") widens both ways,
	# so it stays centred on the gate line instead of running off to one side.
	label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	print("[%s] -> %s" % [body.name, "OPEN" if open else "CLOSED (%s)" % closed_text])
