extends Node


const LOG_PATH := "user://coop_debug.log"
const LOG_PREV_PATH := "user://coop_debug.log.1"
# The log appends across every session forever. Roll it once it gets big enough
# to be slow to open, keeping exactly one previous file -- the crash we chase
# needs the session before last at most, not every session ever played.
const LOG_ROLL_BYTES := 8 * 1024 * 1024

## Per-agent equipment dumps are ~6 lines per AI, and every line is flushed, so
## a spawn wave becomes a burst of synchronous writes. The lines the crash work
## actually reads -- heartbeat, weapon swaps, deaths, container ids -- are not
## behind this.
var verbose: bool = false

var _file: FileAccess = null
var _peer_label: String = "UNKNOWN"


func _ready() -> void:
	_roll_if_large()
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


func _roll_if_large() -> void:
	if not FileAccess.file_exists(LOG_PATH):
		return
	var probe := FileAccess.open(LOG_PATH, FileAccess.READ)
	if probe == null:
		return
	var size: int = probe.get_length()
	probe = null
	if size < LOG_ROLL_BYTES:
		return
	var dir := DirAccess.open("user://")
	if dir == null:
		return
	if dir.file_exists(LOG_PREV_PATH.get_file()):
		dir.remove(LOG_PREV_PATH.get_file())
	dir.rename(LOG_PATH.get_file(), LOG_PREV_PATH.get_file())


## Detail that is useful when reproducing a specific problem and noise otherwise.
func log_verbose(tag: String, msg: String) -> void:
	if verbose:
		log_msg(tag, msg)


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
