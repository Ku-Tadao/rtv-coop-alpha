extends "res://mods/RTVCoopAlpha/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoopAlpha/Framework/CoopAuthority.gd")

func _log(msg: String) -> void:
	var l = Engine.get_meta("CoopLogger", null)
	if l: l.log_msg("LoaderHooks", msg)

func _setup_hooks() -> void:
	CoopHook.register(self, "loader-loadscene-pre", _on_loadscene_pre)
	CoopHook.register(self, "loader-loadscene-post", _on_loadscene_post)
	CoopHook.register_replace_or_post(self, "loader-savecharacter", _replace_savecharacter, _post_savecharacter)
	CoopHook.register_replace_or_post(self, "loader-saveworld", _replace_saveworld, _post_saveworld)
	CoopHook.register_replace_or_post(self, "loader-saveshelter", _replace_saveshelter, _post_saveshelter)
	CoopHook.register_replace_or_post(self, "loader-savetrader", _replace_savetrader, _post_savetrader)


var _scene_visit_counter: int = 0

func _on_loadscene_pre(scene_name: String = "") -> void:
	if not CoopAuthority.is_active():
		return
	var session: int = players.coop_session_seed if players and "coop_session_seed" in players else 0
	if session == 0:
		if CoopAuthority.is_host() and players and players.has_method("_ensure_session_seed"):
			session = players._ensure_session_seed()
	if session == 0:
		_log("LoadScene PRE: NO session seed available, skipping RNG seed")
		return
	_scene_visit_counter += 1
	if players:
		players.scene_visit_count = _scene_visit_counter
	var scene_seed: int = session ^ hash(scene_name) ^ (_scene_visit_counter * 7919)
	seed(scene_seed)
	_log("LoadScene PRE: seeded RNG with %d (session=%d scene='%s' visit=%d)" % [scene_seed, session, scene_name, _scene_visit_counter])


func _on_loadscene_post(scene_name: String = "") -> void:
	if CoopAuthority.is_active():
		randomize()
		_log("LoadScene POST: restored random")
	await get_tree().process_frame
	if events == null:
		return
	var map: Node = coop.scene.current_map() if coop and coop.scene else null
	events.scene_ready.emit(map)
	events.map_loaded.emit(scene_name)


func _replace_savecharacter() -> void:
	if CoopAuthority.is_client():
		CoopHook.skip_super()


func _post_savecharacter() -> void:
	if CoopAuthority.is_client():
		push_warning("[LoaderHooks] SaveCharacter ran as client; replace owned elsewhere")


func _replace_saveworld() -> void:
	if CoopAuthority.is_client():
		CoopHook.skip_super()


func _post_saveworld() -> void:
	pass


func _replace_saveshelter(_target = null) -> void:
	if CoopAuthority.is_client():
		CoopHook.skip_super()


func _post_saveshelter(_target = null) -> void:
	pass


func _replace_savetrader(_trader = null) -> void:
	if CoopAuthority.is_client():
		CoopHook.skip_super()


func _post_savetrader(_trader = null) -> void:
	pass
