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


func _exit_tree() -> void:
	if _file:
		_file.store_line("")
		_file.store_line("=== Log closed ===")
		_file.flush()
		_file = null
