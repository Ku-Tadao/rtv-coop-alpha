extends "res://mods/RTVCoopAlpha/Game/Sync/BaseSync.gd"




const BROADCAST_RATE := 20.0
const MAX_SHOTS_PER_UPDATE := 8


var gameData: Resource = preload("res://Resources/GameData.tres")
var _broadcast_accum: float = 0.0
var _local_shot_count: int = 0
var _was_firing_local: bool = false
var _prev_shot_accum: Dictionary = {}

# Resolved once per scene rather than five string-path lookups per broadcast.
# They only change when the map does, and this runs at 20Hz forever.
var _cached_scene: Node = null
var _rig_manager: Node = null
var _interface: Node = null
var _camera: Node = null


func _ready() -> void:
	var coop := RTVCoop.get_instance()
	if coop and coop.events:
		coop.events.puppet_spawned.connect(_on_puppet_spawned)
		coop.events.puppet_despawned.connect(_on_puppet_despawned)


func _on_puppet_spawned(peer_id: int, _puppet: Node) -> void:
	var coop := RTVCoop.get_instance()
	var proxy: Node = coop.get_player_proxy(peer_id) if coop else null
	# ponytail: pre-spawn shots have no remote model to play from, so baseline them here.
	_prev_shot_accum[peer_id] = proxy.shot_accumulator if proxy else 0


func _on_puppet_despawned(peer_id: int) -> void:
	_prev_shot_accum.erase(peer_id)


func _sync_key() -> String:
	return "local_state"


func _players() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.players if coop else null


func _physics_process(delta: float) -> void:
	if not CoopAuthority.is_active():
		return
	if gameData.isFiring and not _was_firing_local:
		_local_shot_count += 1
	_was_firing_local = gameData.isFiring

	_broadcast_accum += delta
	if _broadcast_accum < 1.0 / BROADCAST_RATE:
		return
	_broadcast_accum = 0.0
	_write_to_proxy()
	_read_remote_proxies()


func _write_to_proxy() -> void:
	var players := _players()
	if players == null:
		return
	var controller: Node = players.GetLocalController()
	if controller == null:
		return
	var coop := RTVCoop.get_instance()
	if coop == null:
		return
	var proxy: Node = coop.get_player_proxy(CoopAuthority.local_peer_id())
	if proxy == null:
		return
	var state: Dictionary = GatherLocalAnimState(controller)
	proxy.write_state(state)


func _read_remote_proxies() -> void:
	var players := _players()
	if players == null:
		return
	var coop := RTVCoop.get_instance()
	if coop == null:
		return
	var my_id: int = CoopAuthority.local_peer_id()
	for peer_id in players.remote_players:
		if peer_id == my_id:
			continue
		var puppet: Node = players.remote_players[peer_id]
		if not is_instance_valid(puppet) or not puppet.is_inside_tree():
			continue
		var proxy: Node = coop.get_player_proxy(peer_id)
		if proxy == null:
			continue
		var state: Dictionary = proxy.read_state()
		var current_shots: int = proxy.shot_accumulator
		var previous_shots: int = _prev_shot_accum.get(peer_id, current_shots)
		var shot_delta: int = current_shots - previous_shots
		_prev_shot_accum[peer_id] = current_shots
		if shot_delta > 0:
			# ponytail: cap catch-up playback; use timestamped shot events if 8 shots/50ms becomes real.
			state["shots"] = mini(shot_delta, MAX_SHOTS_PER_UPDATE)
		if puppet.has_method("SetTarget"):
			puppet.SetTarget(state.get("pos", puppet.global_position), state.get("rot", puppet.global_rotation))
		if puppet.has_method("ApplyAnimState"):
			puppet.ApplyAnimState(state)


func GatherLocalAnimState(controller: Node3D) -> Dictionary:
	var state: Dictionary = {
		"pos": controller.global_position,
		"rot": controller.global_rotation,
		"animCondition": "Guard",
		"animBlend": 0.0,
		"weapon": "rifle",
		"hasWeapon": false,
		"weaponFile": "",
	}

	if gameData.isCrouching:
		state["animCondition"] = "Hunt"
		state["animBlend"] = 1.0 if gameData.isMoving else 0.0
	elif gameData.isAiming and gameData.isMoving:
		state["animCondition"] = "Combat"
		state["animBlend"] = 1.0
	elif gameData.isAiming:
		state["animCondition"] = "Defend"
		state["animBlend"] = 0.0
	elif gameData.isMoving and gameData.isRunning:
		state["animCondition"] = "Movement"
		state["animBlend"] = 5.0
	elif gameData.isMoving and gameData.weaponPosition == 1:
		state["animCondition"] = "MovementLow"
		state["animBlend"] = 1.0
	elif gameData.isMoving:
		state["animCondition"] = "Movement"
		state["animBlend"] = 1.0
	elif gameData.weaponPosition == 2:
		state["animCondition"] = "Defend"
		state["animBlend"] = 0.0
	else:
		state["animCondition"] = "Group"
		state["animBlend"] = 1.0

	_refresh_scene_nodes()
	var rig_manager: Node = _rig_manager
	var weapon_slot = null

	if rig_manager:
		if gameData.primary and rig_manager.primarySlot and rig_manager.primarySlot.get_child_count() > 0:
			weapon_slot = rig_manager.primarySlot.get_child(0)
		elif gameData.secondary and rig_manager.secondarySlot and rig_manager.secondarySlot.get_child_count() > 0:
			weapon_slot = rig_manager.secondarySlot.get_child(0)

		if weapon_slot and weapon_slot.slotData and weapon_slot.slotData.itemData:
			state["weaponFile"] = weapon_slot.slotData.itemData.file
			state["hasWeapon"] = true
			state["weapon"] = "pistol" if weapon_slot.slotData.itemData.weaponType == "Pistol" else "rifle"
		elif gameData.knife and rig_manager.knifeSlot and rig_manager.knifeSlot.get_child_count() > 0:
			var knife_item = rig_manager.knifeSlot.get_child(0)
			if knife_item.slotData and knife_item.slotData.itemData:
				state["weaponFile"] = knife_item.slotData.itemData.file

	# The puppet cannot tell a lowered weapon from a raised one without this, so
	# every pose defaulted to the aiming variant.
	state["weaponPosition"] = gameData.weaponPosition
	state["isFiring"] = gameData.isFiring
	state["shots"] = _local_shot_count
	_local_shot_count = 0
	state["fireMode"] = 1
	if weapon_slot and weapon_slot.slotData:
		state["fireMode"] = weapon_slot.slotData.mode
	state["flashlight"] = gameData.flashlight
	state["nvg"] = gameData.NVG

	var iface: Node = _interface
	if iface:
		var bp_slot: Node = iface.get_node_or_null("Equipment/Backpack")
		var bp_cc: int = bp_slot.get_child_count() if bp_slot else -1
		if bp_slot and bp_cc > 0:
			var bp_item = bp_slot.get_child(0)
			if "slotData" in bp_item and bp_item.slotData and bp_item.slotData.itemData:
				state["backpackFile"] = bp_item.slotData.itemData.file
		if not state.has("backpackFile"):
			var rig_slot: Node = iface.get_node_or_null("Equipment/Rig")
			if rig_slot and rig_slot.get_child_count() > 0:
				var rig_item = rig_slot.get_child(0)
				if "slotData" in rig_item and rig_item.slotData and rig_item.slotData.itemData:
					state["backpackFile"] = rig_item.slotData.itemData.file

	var attachment_files: Array = []
	if weapon_slot and weapon_slot.slotData:
		for nested in weapon_slot.slotData.nested:
			if nested and nested.file:
				attachment_files.append(nested.file)
	state["attachments"] = attachment_files

	var is_suppressed: bool = false
	if rig_manager and rig_manager.get_child_count() > 0:
		var rig: Node = rig_manager.get_child(rig_manager.get_child_count() - 1)
		if rig.get("activeMuzzle") != null and rig.activeMuzzle != null:
			is_suppressed = true
	state["suppressed"] = is_suppressed

	state["pitch"] = _camera.rotation.x if is_instance_valid(_camera) else 0.0

	return state


## Re-resolve only when the scene changes or a cached node has gone away.
func _refresh_scene_nodes() -> void:
	var scene: Node = get_tree().current_scene
	var cached_ok: bool = is_instance_valid(_rig_manager) and is_instance_valid(_interface) \
			and is_instance_valid(_camera)
	if scene == _cached_scene and cached_ok:
		return
	_cached_scene = scene
	_rig_manager = scene.get_node_or_null("Core/Camera/Manager") if scene else null
	_interface = scene.get_node_or_null("Core/UI/Interface") if scene else null
	_camera = scene.get_node_or_null("Core/Camera") if scene else null
