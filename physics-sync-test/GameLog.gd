extends Node
## Prints machine-readable CSV lines to stdout so we can capture two running
## instances (host + client) to log files and compare, after the fact,
## whether they agreed on where the crate was. This is what turns "does it
## feel janky?" into an actual measurement.
##
## Format: DATA,<peer_id>,<unix_time_seconds>,<pos_x>,<pos_y>,<vel_x>,<vel_y>
##
## peer_id 1 is always the host (Godot assigns id 1 to whoever hosts), so
## the host's line at a given moment is "ground truth" physics, and every
## other peer_id's line is "what that client's synced copy looked like".

func log_crate_state(peer_id: int, pos: Vector2, vel: Vector2) -> void:
	var t := Time.get_unix_time_from_system()
	print("DATA,%d,%.6f,%.4f,%.4f,%.4f,%.4f" % [peer_id, t, pos.x, pos.y, vel.x, vel.y])
