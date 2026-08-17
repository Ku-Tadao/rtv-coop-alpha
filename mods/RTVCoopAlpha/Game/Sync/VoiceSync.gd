extends "res://mods/RTVCoopAlpha/Game/Sync/BaseSync.gd"




const CONFIG_PATH := "user://coop_voice.cfg"
const DEFAULT_PTT := KEY_V
const SPEAKING_DECAY_MS := 500
const VAD_TAIL_HOLD_MS := 400


var master_volume_linear: float = 1.0
var mic_gain_linear: float = 1.0
var ptt_keycode: int = DEFAULT_PTT
var open_mic_enabled: bool = false
var vad_threshold: float = 0.03
var max_hearing_distance: float = 30.0
var proximity_filter_range: float = 0.0
var peer_volume_by_name: Dictionary = {}


var _recording: bool = false
var _tail_draining: bool = false
var _sample_rate: int = 24000
var _rebinding: bool = false
var _last_vad_above_ms: int = -1
var _settings_dirty: bool = false
var _settings_save_accum: float = 0.0

var _peer_player: Dictionary = {}
var _peer_playback: Dictionary = {}
var _peer_mic_gain: Dictionary = {}
var _speaking_peers: Dictionary = {}
var _last_heard_time: Dictionary = {}


signal peer_speaking(peer_id: int, is_speaking: bool)
signal ptt_rebind_finished(keycode: int)
signal settings_loaded


func _sync_key() -> String:
	return "voice"


func _players() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.players if coop else null


func _lobby() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.lobby if coop else null


func _steam():
	if not ClassDB.class_exists("Steam"):
		return null
	return Engine.get_singleton("Steam")


func _steam_available() -> bool:
	var lobby := _lobby()
	return lobby != null and lobby.available and _steam() != null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var s = _steam()
	if s and s.has_method("getVoiceOptimalSampleRate"):
		var rate: int = int(s.getVoiceOptimalSampleRate())
		if rate >= 11025 and rate <= 48000:
			_sample_rate = rate
	_load_settings()
	var coop := RTVCoop.get_instance()
	if coop and coop.net:
		coop.net.peer_joined.connect(_on_peer_joined)
		coop.net.peer_left.connect(_on_peer_left)
	if coop and coop.events:
		coop.events.puppet_spawned.connect(_on_puppet_spawned)
		coop.events.puppet_despawned.connect(_on_puppet_despawned)
	settings_loaded.emit()
	print("[VoiceSync] Ready (sample_rate=%d, steam_available=%s)" % [_sample_rate, _steam_available()])


func _on_peer_joined(peer_id: int, _display_name: String = "") -> void:
	if not _net_active():
		return
	BroadcastMicGain.rpc_id(peer_id, multiplayer.get_unique_id(), mic_gain_linear)


func _on_peer_left(peer_id: int) -> void:
	_peer_mic_gain.erase(peer_id)
	DetachPuppetAudio(peer_id)


func _on_puppet_spawned(peer_id: int, puppet: Node) -> void:
	AttachPuppetAudio(peer_id, puppet)


func _on_puppet_despawned(peer_id: int) -> void:
	DetachPuppetAudio(peer_id)


func _net_active() -> bool:
	return CoopAuthority.is_active()


func _in_map() -> bool:
	var scene := get_tree().current_scene
	return scene != null and scene.name == "Map"


func _input(event: InputEvent) -> void:
	if _rebinding and event is InputEventKey and event.pressed and not event.echo:
		var kc: int = event.physical_keycode
		if kc == KEY_ESCAPE:
			_rebinding = false
			ptt_rebind_finished.emit(ptt_keycode)
			get_viewport().set_input_as_handled()
			return
		ptt_keycode = kc
		_rebinding = false
		_save_settings()
		ptt_rebind_finished.emit(ptt_keycode)
		get_viewport().set_input_as_handled()
		return

	if open_mic_enabled:
		return
	if not (event is InputEventKey):
		return
	if event.physical_keycode != ptt_keycode:
		return
	if event.echo:
		return
	if not _net_active() or not _in_map():
		return
	if event.pressed:
		_start_recording()
	else:
		_stop_recording()


func _physics_process(delta: float) -> void:
	var should_capture: bool = _net_active() and _in_map() and _steam_available()

	if open_mic_enabled:
		if should_capture and not _recording:
			_start_recording()
		elif not should_capture and _recording:
			_stop_recording()
		if _recording:
			_pump_voice_vad()
	else:
		if _recording or _tail_draining:
			_pump_voice_ptt()

	_decay_speaking_indicators()

	if _settings_dirty:
		_settings_save_accum += delta
		if _settings_save_accum >= 0.5:
			_settings_save_accum = 0.0
			_settings_dirty = false
			_write_settings_to_disk()


func _start_recording() -> void:
	if _recording or not _steam_available():
		return
	var s = _steam()
	s.startVoiceRecording()
	var lobby := _lobby()
	if lobby:
		s.setInGameVoiceSpeaking(lobby.MyId(), true)
	_recording = true
	_tail_draining = false


func _stop_recording() -> void:
	if not _recording:
		return
	var s = _steam()
	if s == null:
		_recording = false
		_tail_draining = false
		return
	s.stopVoiceRecording()
	var lobby := _lobby()
	if lobby:
		s.setInGameVoiceSpeaking(lobby.MyId(), false)
	_recording = false
	_tail_draining = true
	_last_vad_above_ms = -1


func _pump_voice_ptt() -> void:
	var s = _steam()
	if s == null:
		return
	var voice: Dictionary = s.getVoice()
	var result: int = int(voice.get("result", -1))
	if result == 2:
		_tail_draining = false
		return
	if result != 0:
		return
	var written: int = int(voice.get("written", 0))
	if written <= 0:
		return
	var buffer: PackedByteArray = voice.get("buffer", PackedByteArray())
	if buffer.is_empty():
		return
	if buffer.size() > written:
		buffer = buffer.slice(0, written)
	_broadcast_my_voice(buffer)


func _pump_voice_vad() -> void:
	var s = _steam()
	if s == null:
		return
	var voice: Dictionary = s.getVoice()
	if int(voice.get("result", -1)) != 0:
		return
	var written: int = int(voice.get("written", 0))
	if written <= 0:
		return
	var buffer: PackedByteArray = voice.get("buffer", PackedByteArray())
	if buffer.is_empty():
		return
	if buffer.size() > written:
		buffer = buffer.slice(0, written)

	var decomp: Dictionary = s.decompressVoice(buffer, _sample_rate)
	if int(decomp.get("result", -1)) != 0:
		return
	var pcm_size: int = int(decomp.get("size", 0))
	if pcm_size <= 0:
		return
	var pcm: PackedByteArray = decomp.get("uncompressed", PackedByteArray())
	var rms: float = _compute_rms(pcm, pcm_size) * mic_gain_linear

	var now: int = Time.get_ticks_msec()
	if rms >= vad_threshold:
		_last_vad_above_ms = now
	if _last_vad_above_ms >= 0 and (now - _last_vad_above_ms) <= VAD_TAIL_HOLD_MS:
		_broadcast_my_voice(buffer)


func _compute_rms(pcm: PackedByteArray, size: int) -> float:
	var sample_count: int = size / 2
	if sample_count <= 0:
		return 0.0
	var acc: float = 0.0
	for i in sample_count:
		var sample: int = pcm.decode_s16(i * 2)
		var amp: float = sample / 32768.0
		acc += amp * amp
	return sqrt(acc / sample_count)


func _broadcast_my_voice(bytes: PackedByteArray) -> void:
	if not _net_active():
		return
	var pos: Vector3 = _get_my_pos()
	if CoopAuthority.is_host():
		_host_relay(multiplayer.get_unique_id(), pos, bytes)
	else:
		SubmitVoice.rpc_id(1, pos, bytes)


func _get_my_pos() -> Vector3:
	var players := _players()
	var controller: Node = players.GetLocalController() if players else null
	return controller.global_position if controller else Vector3.ZERO


@rpc("any_peer", "unreliable_ordered", "call_remote")
func SubmitVoice(pos: Vector3, bytes: PackedByteArray) -> void:
	if not multiplayer.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	_host_relay(sender, pos, bytes)


func _host_relay(sender_id: int, sender_pos: Vector3, bytes: PackedByteArray) -> void:
	var my_id: int = multiplayer.get_unique_id()
	if sender_id != my_id:
		if _proximity_ok(sender_pos, _get_my_pos()):
			_play_voice(sender_id, bytes)

	for peer_id in multiplayer.get_peers():
		if peer_id == sender_id:
			continue
		var peer_pos: Vector3 = _get_peer_pos(peer_id)
		if not _proximity_ok(sender_pos, peer_pos):
			continue
		ReceiveVoice.rpc_id(peer_id, sender_id, bytes)


func _proximity_ok(sender_pos: Vector3, listener_pos: Vector3) -> bool:
	if proximity_filter_range <= 0.0:
		return true
	if sender_pos == Vector3.ZERO or listener_pos == Vector3.ZERO:
		return true
	return sender_pos.distance_to(listener_pos) <= proximity_filter_range


func _get_peer_pos(peer_id: int) -> Vector3:
	var players := _players()
	if players == null or not players.remote_players.has(peer_id):
		return Vector3.ZERO
	var puppet: Node = players.remote_players[peer_id]
	if not is_instance_valid(puppet):
		return Vector3.ZERO
	return puppet.global_position


@rpc("authority", "unreliable_ordered", "call_remote")
func ReceiveVoice(sender_id: int, bytes: PackedByteArray) -> void:
	_play_voice(sender_id, bytes)


func _play_voice(sender_id: int, bytes: PackedByteArray) -> void:
	if not _peer_playback.has(sender_id):
		return
	var playback: AudioStreamGeneratorPlayback = _peer_playback[sender_id]
	if not is_instance_valid(playback):
		_peer_playback.erase(sender_id)
		return
	var s = _steam()
	if s == null:
		return
	var decompressed: Dictionary = s.decompressVoice(bytes, _sample_rate)
	if int(decompressed.get("result", -1)) != 0:
		return
	var size: int = int(decompressed.get("size", 0))
	if size <= 0:
		return
	var pcm: PackedByteArray = decompressed.get("uncompressed", PackedByteArray())
	if pcm.is_empty():
		return
	var sample_count: int = size / 2
	var available_frames: int = playback.get_frames_available()
	var to_push: int = min(sample_count, available_frames)
	var sender_gain: float = float(_peer_mic_gain.get(sender_id, 1.0))
	for i in to_push:
		var sample: int = pcm.decode_s16(i * 2)
		var amp: float = (sample / 32768.0) * sender_gain
		amp = clampf(amp, -1.0, 1.0)
		playback.push_frame(Vector2(amp, amp))
	if not _last_heard_time.has(sender_id):
		_apply_peer_volume_db(sender_id)
	_last_heard_time[sender_id] = Time.get_ticks_msec()
	if not _speaking_peers.get(sender_id, false):
		_speaking_peers[sender_id] = true
		peer_speaking.emit(sender_id, true)


func _decay_speaking_indicators() -> void:
	if _last_heard_time.is_empty():
		return
	var now: int = Time.get_ticks_msec()
	for peer_id in _last_heard_time.keys().duplicate():
		if now - int(_last_heard_time[peer_id]) > SPEAKING_DECAY_MS:
			_last_heard_time.erase(peer_id)
			if _speaking_peers.get(peer_id, false):
				_speaking_peers[peer_id] = false
				peer_speaking.emit(peer_id, false)


func AttachPuppetAudio(peer_id: int, puppet: Node) -> void:
	DetachPuppetAudio(peer_id)
	if not is_instance_valid(puppet):
		return
	var player := AudioStreamPlayer3D.new()
	player.name = "CoopVoicePlayer"
	player.process_mode = Node.PROCESS_MODE_ALWAYS
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = _sample_rate
	gen.buffer_length = 0.3
	player.stream = gen
	player.max_distance = max_hearing_distance
	player.unit_size = 2.0
	player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	player.volume_db = _compute_peer_volume_db(peer_id)
	puppet.add_child(player)
	player.play()
	_peer_player[peer_id] = player
	_peer_playback[peer_id] = player.get_stream_playback()


func DetachPuppetAudio(peer_id: int) -> void:
	if _peer_player.has(peer_id):
		var player: Node = _peer_player[peer_id]
		if is_instance_valid(player):
			player.queue_free()
		_peer_player.erase(peer_id)
	_peer_playback.erase(peer_id)
	_speaking_peers.erase(peer_id)
	_last_heard_time.erase(peer_id)


func _peer_key(peer_id: int) -> String:
	var players := _players()
	if players == null or not players.peer_names.has(peer_id):
		return ""
	return str(players.peer_names[peer_id])


func _compute_peer_volume_db(peer_id: int) -> float:
	var per_peer: float = GetPeerVolume(peer_id)
	var combined: float = master_volume_linear * per_peer
	return linear_to_db(max(combined, 0.0001))


func GetPeerVolume(peer_id: int) -> float:
	var key: String = _peer_key(peer_id)
	if key == "":
		return 1.0
	return float(peer_volume_by_name.get(key, 1.0))


func SetPeerVolume(peer_id: int, linear: float) -> void:
	var key: String = _peer_key(peer_id)
	if key == "":
		return
	peer_volume_by_name[key] = clampf(linear, 0.0, 2.0)
	_apply_peer_volume_db(peer_id)
	_save_settings()


func _apply_peer_volume_db(peer_id: int) -> void:
	if _peer_player.has(peer_id):
		var player: Node = _peer_player[peer_id]
		if is_instance_valid(player):
			player.volume_db = _compute_peer_volume_db(peer_id)


func SetMasterVolume(linear: float) -> void:
	master_volume_linear = clampf(linear, 0.0, 2.0)
	for peer_id in _peer_player.keys():
		_apply_peer_volume_db(peer_id)
	_save_settings()


func SetMicGain(linear: float) -> void:
	mic_gain_linear = clampf(linear, 0.0, 2.0)
	_broadcast_mic_gain_to_all()
	_save_settings()


func _broadcast_mic_gain_to_all() -> void:
	if not _net_active():
		return
	BroadcastMicGain.rpc(multiplayer.get_unique_id(), mic_gain_linear)


@rpc("any_peer", "reliable", "call_remote")
func BroadcastMicGain(peer_id: int, gain: float) -> void:
	_peer_mic_gain[peer_id] = clampf(gain, 0.0, 2.0)


func SetMaxHearingDistance(meters: float) -> void:
	max_hearing_distance = clampf(meters, 1.0, 200.0)
	for player in _peer_player.values():
		if is_instance_valid(player):
			player.max_distance = max_hearing_distance
	_save_settings()


func SetProximityFilterRange(meters: float) -> void:
	proximity_filter_range = clampf(meters, 0.0, 500.0)
	_save_settings()


func SetOpenMic(enabled: bool) -> void:
	if open_mic_enabled == enabled:
		return
	if open_mic_enabled and not enabled and _recording:
		_stop_recording()
	open_mic_enabled = enabled
	_save_settings()


func SetVadThreshold(val: float) -> void:
	vad_threshold = clampf(val, 0.0, 1.0)
	_save_settings()


func BeginRebindPtt() -> void:
	_rebinding = true


func IsRebinding() -> bool:
	return _rebinding


func GetPttKeyName() -> String:
	return OS.get_keycode_string(ptt_keycode)


func IsRecording() -> bool:
	return _recording


func IsPeerSpeaking(peer_id: int) -> bool:
	return bool(_speaking_peers.get(peer_id, false))


func IsSteamVoiceAvailable() -> bool:
	return _steam_available()


func _save_settings() -> void:
	_settings_dirty = true
	_settings_save_accum = 0.0


func _write_settings_to_disk() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("voice", "master_volume", master_volume_linear)
	cfg.set_value("voice", "mic_gain", mic_gain_linear)
	cfg.set_value("voice", "ptt_keycode", ptt_keycode)
	cfg.set_value("voice", "open_mic", open_mic_enabled)
	cfg.set_value("voice", "vad_threshold", vad_threshold)
	cfg.set_value("voice", "max_hearing_distance", max_hearing_distance)
	cfg.set_value("voice", "proximity_filter_range", proximity_filter_range)
	for key_name in peer_volume_by_name:
		cfg.set_value("peers", key_name, peer_volume_by_name[key_name])
	cfg.save(CONFIG_PATH)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if _settings_dirty:
			_settings_dirty = false
			_write_settings_to_disk()


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return
	master_volume_linear = float(cfg.get_value("voice", "master_volume", 1.0))
	mic_gain_linear = float(cfg.get_value("voice", "mic_gain", 1.0))
	ptt_keycode = int(cfg.get_value("voice", "ptt_keycode", DEFAULT_PTT))
	open_mic_enabled = bool(cfg.get_value("voice", "open_mic", false))
	vad_threshold = float(cfg.get_value("voice", "vad_threshold", 0.03))
	max_hearing_distance = float(cfg.get_value("voice", "max_hearing_distance", 30.0))
	proximity_filter_range = float(cfg.get_value("voice", "proximity_filter_range", 0.0))
	if cfg.has_section("peers"):
		for key_name in cfg.get_section_keys("peers"):
			peer_volume_by_name[key_name] = float(cfg.get_value("peers", key_name, 1.0))
