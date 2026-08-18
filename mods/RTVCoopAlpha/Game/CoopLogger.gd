extends Node


const LOG_PATH := "user://coop_debug.log"
var _file: FileAccess = null
var _peer_label: String = "UNKNOWN"


func _ready() -> void:
	if FileAccess.file_exists(LOG_PATH):
		_file = FileAccess.open(LOG_PATH, FileAccess.READ_WRITE)
		if _file:
			_file.seek_end()
	else:
		_file = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if _file:
		_file.store_line("")
		_file.store_line("========================================")
		_file.store_line("=== RTVCoop Instance Start ===")
		_file.store_line("Time: %s" % Time.get_datetime_string_from_system())
		_file.store_line("PID: %d" % OS.get_process_id())
		_file.store_line("Log path: %s" % ProjectSettings.globalize_path(LOG_PATH))
		_file.store_line("========================================")
		_file.store_line("")
		_file.flush()
		print("[CoopLogger] Appending to: %s" % ProjectSettings.globalize_path(LOG_PATH))
	else:
		push_error("[CoopLogger] Failed to open log file at %s" % LOG_PATH)


func set_peer_label(label: String) -> void:
	_peer_label = label
	log_msg("CoopLogger", "Peer label set to: %s" % label)


func log_msg(tag: String, msg: String) -> void:
	var line := "[%s] [%s] [%s] %s" % [
		Time.get_time_string_from_system(),
		_peer_label,
		tag,
		msg
	]
	print(line)
	if _file:
		_file.store_line(line)
		_file.flush()


# --- Crash forensics -------------------------------------------------------
#
# The crash we are chasing kills the process outright: no Godot error, no
# GDScript stack, and godot.log loses its final buffered write. log_msg() flushes
# every line, so THIS file is the one that survives -- put anything you need to
# read after a crash through it.
#
# The heartbeat exists to test one specific hypothesis: that something leaks
# nodes until the process dies. If so, these counters climb steadily and the last
# line before the crash says how far they got. If they are flat right up to the
# end, it is not exhaustion and the answer is in the dump instead.

const HEARTBEAT_INTERVAL := 15.0

var _heartbeat_t: float = 0.0
var _peak_nodes: int = 0


func _process(delta: float) -> void:
	if _file == null:
		return
	_heartbeat_t -= delta
	if _heartbeat_t > 0.0:
		return
	_heartbeat_t = HEARTBEAT_INTERVAL

	var nodes: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	_peak_nodes = maxi(_peak_nodes, nodes)
	log_msg("Heartbeat", "nodes=%d peak=%d objects=%d orphans=%d mem=%.1fMB fps=%d peers=%d" % [
		nodes,
		_peak_nodes,
		int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		int(Performance.get_monitor(Performance.TIME_FPS)),
		multiplayer.get_peers().size() if multiplayer.multiplayer_peer else 0,
	])


func _exit_tree() -> void:
	if _file:
		_file.store_line("")
		_file.store_line("=== Log closed ===")
		_file.flush()
		_file = null
