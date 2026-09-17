extends Node
## Prints machine-readable CSV lines to stdout so we can capture multiple
## running instances (host + N clients) to log files and compare, after the
## fact, whether they agreed on where each object was. This is what turns
## "does it feel janky?" into an actual measurement.
##
## Format: DATA,<object_tag>,<peer_id>,<unix_time_seconds>,<pos_x>,<pos_y>,<vel_x>,<vel_y>
##
## object_tag is whichever object's state this line describes (e.g. "Crate",
## "Can", "Box") — Week 3 added multiple simultaneous carryable objects, so
## log lines need to say which one they're about. peer_id 1 is always the
## host (Godot assigns id 1 to whoever hosts), so the host's line for a
## given object is "ground truth" physics, and every other peer_id's line
## is "what that client's synced copy looked like".

func log_object_state(tag: String, peer_id: int, pos: Vector2, vel: Vector2) -> void:
	var t := Time.get_unix_time_from_system()
	print("DATA,%s,%d,%.6f,%.4f,%.4f,%.4f,%.4f" % [tag, peer_id, t, pos.x, pos.y, vel.x, vel.y])
