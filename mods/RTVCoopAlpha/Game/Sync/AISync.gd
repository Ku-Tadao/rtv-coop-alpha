extends "res://mods/RTVCoopAlpha/Game/Sync/BaseSync.gd"




const AI_BROADCAST_RATE := 20.0
const AI_LERP_SPEED := 18.0
const AI_SOUND_FIRE := 0
const AI_SOUND_TAIL := 1
const AI_SOUND_IDLE := 2
const AI_SOUND_COMBAT := 3
const AI_SOUND_DAMAGE := 4
const AI_SOUND_DEATH := 5

const SPAWN_RETRY_INTERVAL := 0.5
const SPAWN_RETRY_MAX := 10
const MANIFEST_CHECK_INTERVAL := 20.0
const REAP_INTERVAL := 2.0


var gameData: Resource = preload("res://Resources/GameData.tres")

var _pending_spawns: Array = []
var _ai_accum: float = 0.0
var _manifest_timer: float = 0.0
var _reap_timer: float = 0.0


func _sync_key() -> String:
	return "ai"


func _log(msg: String) -> void:
	var l = Engine.get_meta("CoopLogger", null)
	if l: l.log_msg("AISync", msg)


func _get_ai_loot_container(ai: Node) -> Node:
	if ai.container == null:
		return null
	if ai.container is LootContainer:
		return ai.container
	for child in ai.container.get_children():
		if child is LootContainer:
			return child
	return null


func _players() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.players if coop else null


func _slot_serializer() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.get_sync("slot_serializer") if coop else null


func _live_ai(uuid) -> Node:
	var players := _players()
	if players == null:
		return null
	var key: int = int(uuid)
	if not players.world_ai.has(key):
		return null
	var ai: Node = players.world_ai[key]
	if not is_instance_valid(ai) or not ai.is_inside_tree():
		return null
	return ai


func _prune_pending_uuid(uuid: int) -> void:
	for i in range(_pending_spawns.size() - 1, -1, -1):
		if int(_pending_spawns[i].get("uuid", -1)) == uuid:
			_pending_spawns.remove_at(i)


func _make_spawn_entry(uuid: int, pos: Vector3, rot: Vector3, variant: Dictionary, spawn_type: String, is_sync: bool) -> Dictionary:
	var entry := {
		"uuid": uuid,
		"spawnType": spawn_type,
		"pos": pos,
		"rot": rot,
		"variant": variant,
		"isSync": is_sync,
		"retries": 0,
		"timer": 0.0,
	}
	if is_sync:
		entry["aiTarget"] = {"pos": pos, "rot": rot}
	return entry



func _physics_process(delta: float) -> void:
	if not CoopAuthority.is_active():
		return

	var players := _players()
	if players == null:
		return

	if CoopAuthority.is_host():
		_ai_accum += delta
		if _ai_accum >= 1.0 / AI_BROADCAST_RATE:
			_ai_accum = 0.0
			BroadcastAIPositions()
		_reap_timer += delta
		if _reap_timer >= REAP_INTERVAL:
			_reap_timer = 0.0
			_reap_stale_world_ai()
		_watch_ai_deaths()
	else:
		for uuid in players.ai_targets:
			var ai := _live_ai(uuid)
			if ai == null:
				continue
			var target: Dictionary = players.ai_targets[uuid]
			ai.global_position = ai.global_position.lerp(target["pos"], AI_LERP_SPEED * delta)
			ai.global_rotation.y = lerp_angle(ai.global_rotation.y, target["rot"].y, AI_LERP_SPEED * delta)

		for uuid in players.world_ai:
			var ai: Node = players.world_ai.get(uuid)
			if not is_instance_valid(ai) or not ai.is_inside_tree() or ai.dead:
				continue
			if not ai.visible:
				ai.show()
				ai.pause = false
				ai.process_mode = Node.PROCESS_MODE_INHERIT
				if ai.skeleton:
					ai.skeleton.process_mode = Node.PROCESS_MODE_INHERIT
					ai.skeleton.show_rest_only = false
				if ai.animator:
					ai.animator.active = true
				ai.set_meta("coop_client_anim_ready", false)

	_process_pending_spawns()

	if CoopAuthority.is_client() and players.scene_ready:
		_manifest_timer += delta
		if _manifest_timer >= MANIFEST_CHECK_INTERVAL:
			_manifest_timer = 0.0
			RequestAIManifest.rpc_id(1)


func _process_pending_spawns() -> void:
	var players := _players()
	if _pending_spawns.is_empty() or players == null or not players.scene_ready:
		return
	var still_pending: Array = []
	var dt: float = get_physics_process_delta_time()
	for entry in _pending_spawns:
		if entry["timer"] > 0.0:
			entry["timer"] -= dt
			still_pending.append(entry)
			continue
		if _try_spawn_agent(entry):
			continue
		entry["retries"] += 1
		if entry["retries"] > SPAWN_RETRY_MAX:
			push_warning("[AISync] giving up on spawn uuid=%d" % entry["uuid"])
			continue
		entry["timer"] = SPAWN_RETRY_INTERVAL
		still_pending.append(entry)
	_pending_spawns = still_pending


func _get_ai_spawner() -> Node:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("AI")


func _try_spawn_agent(entry: Dictionary) -> bool:
	var players := _players()
	var uuid: int = entry["uuid"]
	if players.world_ai.has(uuid):
		return true
	if not players.scene_ready:
		return false

	var ai_spawner := _get_ai_spawner()
	if ai_spawner == null:
		return false

	var spawn_type: String = entry.get("spawnType", "")
	var pool: Node = ai_spawner.BPool if spawn_type == "Boss" else ai_spawner.APool
	if pool.get_child_count() == 0 and not _grow_pool(ai_spawner, pool, spawn_type):
		return false

	var new_agent: Node = pool.get_child(0)
	new_agent.reparent(ai_spawner.agents)
	new_agent.global_position = entry["pos"]
	new_agent.global_rotation = entry["rot"]
	new_agent.set_meta("network_uuid", uuid)
	new_agent.set_meta("coop_spawn_variant", entry.get("variant", {}))
	players.world_ai[uuid] = new_agent
	if entry.has("aiTarget"):
		players.ai_targets[uuid] = entry["aiTarget"]
	ai_spawner.activeAgents += 1
	if uuid >= players.next_ai_uuid:
		players.next_ai_uuid = uuid + 1

	_deferred_activate(new_agent, spawn_type, entry.get("isSync", false))
	return true


func _grow_pool(ai_spawner: Node, pool: Node, spawn_type: String) -> bool:
	var scene: PackedScene = ai_spawner.punisher if spawn_type == "Boss" else ai_spawner.agent
	if scene == null:
		return false
	var new_agent = scene.instantiate()
	new_agent.boss = (spawn_type == "Boss")
	new_agent.AISpawner = ai_spawner
	pool.add_child(new_agent, true)
	new_agent.global_position = pool.global_position + Vector3(randf_range(-10, 10), 0, randf_range(-10, 10))
	new_agent.Pause()
	return true


func _watch_ai_deaths() -> void:
	var players := _players()
	if players == null or players.world_ai.is_empty():
		return
	var stale: Array = []
	var ss := _slot_serializer()
	for uuid in players.world_ai:
		var ai: Node = players.world_ai[uuid]
		if not is_instance_valid(ai):
			stale.append(uuid)
			continue
		if not ai.dead:
			continue
		if ai.has_meta("_coop_death_broadcasted"):
			stale.append(uuid)
			continue
		ai.set_meta("_coop_death_broadcasted", true)

		var container_loot: Array = []
		var _lc = _get_ai_loot_container(ai)
		if _lc and ss:
			for slot in _lc.loot:
				container_loot.append(ss.SerializeSlotData(slot))

		var weapon_dict: Dictionary = {}
		if ai.weapon and ai.weapon.slotData and ss:
			weapon_dict = ss.SerializeSlotData(ai.weapon.slotData)

		var backpack_dict: Dictionary = {}
		if ai.backpack and ai.backpack.slotData and ss:
			backpack_dict = ss.SerializeSlotData(ai.backpack.slotData)

		var secondary_dict: Dictionary = {}
		if ai.secondary and ai.secondary.slotData and ss:
			secondary_dict = ss.SerializeSlotData(ai.secondary.slotData)

		var _corpse_cid: int = players.nextContainerId
		players.nextContainerId += 1
		if _lc:
			if not _lc.is_in_group("CoopLootContainer"):
				_lc.add_to_group("CoopLootContainer")
			_lc.set_meta("coop_container_id", _corpse_cid)
		if ai.weapon:
			var w_uuid: int = int(uuid) * 10 + 1
			ai.weapon.set_meta("network_uuid", w_uuid)
			players.worldItems[w_uuid] = ai.weapon
			if w_uuid >= players.nextUuid:
				players.nextUuid = w_uuid + 1
		if ai.backpack:
			var b_uuid: int = int(uuid) * 10 + 2
			ai.backpack.set_meta("network_uuid", b_uuid)
			players.worldItems[b_uuid] = ai.backpack
			if b_uuid >= players.nextUuid:
				players.nextUuid = b_uuid + 1
		if ai.secondary:
			var s_uuid: int = int(uuid) * 10 + 3
			ai.secondary.set_meta("network_uuid", s_uuid)
			players.worldItems[s_uuid] = ai.secondary
			if s_uuid >= players.nextUuid:
				players.nextUuid = s_uuid + 1
		BroadcastAIDeath.rpc(int(uuid), Vector3.ZERO, 20.0, container_loot, weapon_dict, backpack_dict, secondary_dict, _corpse_cid)
		stale.append(uuid)

	for uuid in stale:
		players.world_ai.erase(uuid)
		players.ai_targets.erase(uuid)


func _reap_stale_world_ai() -> void:
	var players := _players()
	if players == null:
		return
	var stale: Array = []
	for uuid in players.world_ai:
		var ai: Node = players.world_ai[uuid]
		if not is_instance_valid(ai) or not ai.is_inside_tree():
			stale.append(uuid)
	if stale.is_empty():
		return
	for uuid in stale:
		players.world_ai.erase(uuid)
		players.ai_targets.erase(uuid)
	BroadcastAIRemove.rpc(PackedInt32Array(stale))


func _deferred_activate(agent: Node, spawn_type: String, is_sync: bool) -> void:
	if not is_instance_valid(agent) or not agent.is_inside_tree():
		return
	_log("_deferred_activate type=%s is_sync=%s is_server=%s" % [spawn_type, str(is_sync), str(multiplayer.is_server())])
	if is_sync or not multiplayer.is_server():
		_full_equipment_from_variant(agent)
		agent.Activate()
		if not multiplayer.is_server():
			_disable_client_sensors(agent)
	else:
		match spawn_type:
			"Wanderer": agent.ActivateWanderer()
			"Guard": agent.ActivateGuard()
			"Hider": agent.ActivateHider()
			"Minion": agent.ActivateMinion()
			"Boss": agent.ActivateBoss()
	_ensure_ai_visible(agent)


func _full_equipment_from_variant(agent: Node) -> void:
	var variant: Dictionary = agent.get_meta("coop_spawn_variant", {})
	var w_count: int = agent.weapons.get_child_count() if agent.weapons else 0
	var has_clothing: bool = agent.get("allowClothing") == true
	var cloth_count: int = agent.clothing.size() if agent.get("clothing") != null else -1
	var has_mesh: bool = agent.mesh != null
	var container_type: String = str(type_string(typeof(agent.container))) if agent.container else "null"
	var container_is_lc: bool = agent.container is LootContainer if agent.container else false
	_log("_full_equipment_from_variant weapons=%d allowClothing=%s clothingArr=%d mesh=%s container=%s isLC=%s" % [w_count, str(has_clothing), cloth_count, str(has_mesh), container_type, str(container_is_lc)])
	_log("  variant=%s" % str(variant))

	if agent.weapons and agent.weapons.get_child_count() > 0:
		var weapon_file: String = variant.get("weaponFile", "")
		var weapon_index: int = -1
		if weapon_file != "":
			for i in agent.weapons.get_child_count():
				var child: Node = agent.weapons.get_child(i)
				if child.slotData and child.slotData.itemData and child.slotData.itemData.file == weapon_file:
					weapon_index = i
					break
		if weapon_index < 0:
			weapon_index = randi_range(0, agent.weapons.get_child_count() - 1)
		_log("  → weapon selected: index=%d/%d file=%s" % [weapon_index, agent.weapons.get_child_count(), weapon_file])
		agent.weapon = agent.weapons.get_child(weapon_index)
		if agent.weapon:
			agent.weaponData = agent.weapon.slotData.itemData
			agent.weapon.show()
			for child in agent.weapons.get_children():
				if child != agent.weapon:
					child.queue_free()
			agent.muzzle = agent.weapon.get_node_or_null("Muzzle")

			var new_slot = SlotData.new()
			new_slot.itemData = agent.weapon.slotData.itemData
			new_slot.condition = variant.get("weaponCondition", randi_range(5, 50))
			var mag_size: int = new_slot.itemData.magazineSize if "magazineSize" in new_slot.itemData else 10
			new_slot.amount = variant.get("weaponAmount", randi_range(1, max(1, mag_size)))
			new_slot.chamber = true
			agent.weapon.slotData = new_slot

			if new_slot.itemData.weaponType == "Pistol":
				agent.animator["parameters/conditions/Pistol"] = true
				agent.animator["parameters/conditions/Rifle"] = false
			else:
				agent.animator["parameters/conditions/Pistol"] = false
				agent.animator["parameters/conditions/Rifle"] = true

			if agent.weaponData.weaponAction != "Manual" and agent.weaponData.compatible.size() > 0:
				if agent.weaponData.compatible[0].subtype == "Magazine":
					var attachments = agent.weapon.get_node_or_null("Attachments")
					if attachments:
						var magazine = attachments.get_node_or_null(agent.weaponData.compatible[0].file)
						if magazine:
							magazine.show()
					agent.weapon.slotData.nested.append(agent.weaponData.compatible[0])

	if agent.get("allowBackpacks") and agent.backpacks and agent.backpacks.get_child_count() > 0:
		var bp_roll: int = variant.get("backpackRoll", randi_range(0, 100))
		if bp_roll < 10:
			var bp_file: String = variant.get("backpackFile", "")
			var bp_index: int = -1
			if bp_file != "":
				for i in agent.backpacks.get_child_count():
					var child = agent.backpacks.get_child(i)
					if child.get("slotData") and child.slotData.itemData and child.slotData.itemData.file == bp_file:
						bp_index = i
						break
					if bp_index < 0 and child.name == bp_file:
						bp_index = i
						break
			if bp_index < 0:
				bp_index = randi_range(0, agent.backpacks.get_child_count() - 1)
			agent.backpack = agent.backpacks.get_child(bp_index)
			for child in agent.backpacks.get_children():
				if child != agent.backpack:
					child.queue_free()
			var bp_mesh = agent.backpack.get_node_or_null("Mesh")
			if bp_mesh:
				agent.backpack.show()
				bp_mesh.visibility_range_end = 400.0
		else:
			for child in agent.backpacks.get_children():
				child.queue_free()

	var allow_clothing: bool = agent.get("allowClothing") if agent.get("allowClothing") != null else false
	_log("  clothing: allowClothing=%s clothing_count=%d mesh=%s" % [str(allow_clothing), agent.clothing.size() if agent.get("clothing") else 0, str(agent.mesh != null)])
	if allow_clothing and agent.clothing and agent.clothing.size() > 0:
		var clothing_path: String = variant.get("clothingPath", "")
		var cloth_index: int = -1
		if clothing_path != "":
			for i in agent.clothing.size():
				if agent.clothing[i] and agent.clothing[i].resource_path == clothing_path:
					cloth_index = i
					break
		if cloth_index < 0:
			cloth_index = randi_range(0, agent.clothing.size() - 1)
		_log("  → applying clothing index=%d/%d path=%s" % [cloth_index, agent.clothing.size(), clothing_path])
		if agent.mesh:
			agent.mesh.set_surface_override_material(0, agent.clothing[cloth_index])


func _disable_client_sensors(agent: Node) -> void:
	if not is_instance_valid(agent):
		return
	if agent.get("detector") and agent.detector is Area3D:
		agent.detector.monitoring = false
	if agent.get("LOS") and agent.LOS is RayCast3D:
		agent.LOS.enabled = false
	if agent.get("fire") and agent.fire is RayCast3D:
		agent.fire.enabled = false
	if agent.get("below") and agent.below is RayCast3D:
		agent.below.enabled = false
	if agent.get("forward") and agent.forward is RayCast3D:
		agent.forward.enabled = false


func _ensure_ai_visible(agent: Node) -> void:
	if not is_instance_valid(agent):
		return
	if agent.has_method("HideGizmos"):
		agent.HideGizmos()
	agent.show()
	agent.pause = false
	agent.process_mode = Node.PROCESS_MODE_INHERIT
	if agent.skeleton:
		agent.skeleton.show_rest_only = false
		agent.skeleton.process_mode = Node.PROCESS_MODE_INHERIT
		agent.skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE
	if agent.animator:
		agent.animator.active = true
		agent.animator.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	agent.set_meta("coop_client_anim_ready", false)


func GenerateAiUuid() -> int:
	var players := _players()
	if players == null:
		return 0
	var u: int = players.next_ai_uuid
	players.next_ai_uuid += 1
	return u


func _nearest_player(from: Vector3, use_camera: bool) -> Vector3:
	var players := _players()
	if players == null:
		return Vector3.ZERO
	var best_pos: Vector3 = Vector3.ZERO
	var best_dist: float = INF
	var found: bool = false

	var local_ctrl: Node = players.GetLocalController() if players.has_method("GetLocalController") else null
	if local_ctrl and local_ctrl.is_inside_tree():
		var d: float = from.distance_squared_to(local_ctrl.global_position)
		if d < best_dist:
			best_dist = d
			best_pos = gameData.cameraPosition if use_camera else local_ctrl.global_position
			found = true

	for id in players.remote_players:
		var puppet: Node = players.remote_players[id]
		if not is_instance_valid(puppet) or not puppet.is_inside_tree():
			continue
		if puppet.get("isDead") or puppet.get("isDowned"):
			continue
		var d: float = from.distance_squared_to(puppet.global_position)
		if d < best_dist:
			best_dist = d
			best_pos = puppet.global_position + (Vector3(0, 1.6, 0) if use_camera else Vector3.ZERO)
			found = true

	return best_pos if found else Vector3.ZERO


func GetNearestPlayerPosition(from: Vector3) -> Vector3:
	return _nearest_player(from, false)


func GetNearestPlayerCamera(from: Vector3) -> Vector3:
	return _nearest_player(from, true)


func GetNearestPlayerState(from: Vector3) -> Dictionary:
	var players := _players()
	if players == null:
		return {}
	var best_dist: float = INF
	var best_peer: int = -1
	var is_local: bool = false

	var local_ctrl: Node = players.GetLocalController() if players.has_method("GetLocalController") else null
	if local_ctrl and local_ctrl.is_inside_tree():
		var d: float = from.distance_squared_to(local_ctrl.global_position)
		if d < best_dist:
			best_dist = d
			best_peer = CoopAuthority.local_peer_id()
			is_local = true

	for id in players.remote_players:
		var puppet: Node = players.remote_players[id]
		if not is_instance_valid(puppet) or not puppet.is_inside_tree():
			continue
		if puppet.get("isDead") or puppet.get("isDowned"):
			continue
		var d: float = from.distance_squared_to(puppet.global_position)
		if d < best_dist:
			best_dist = d
			best_peer = id
			is_local = false

	if best_peer < 0:
		return {}

	if is_local:
		return {
			"pos": local_ctrl.global_position,
			"cam": gameData.cameraPosition,
			"is_running": gameData.isRunning,
			"is_walking": gameData.isWalking,
			"is_firing": gameData.isFiring,
			"player_vector": gameData.playerVector,
		}

	var puppet: Node = players.remote_players.get(best_peer)
	if not is_instance_valid(puppet):
		return {}
	var coop := RTVCoop.get_instance()
	var proxy: Node = coop.get_player_proxy(best_peer) if coop else null
	var p_is_running: bool = false
	var p_is_walking: bool = false
	var p_is_firing: bool = false
	if proxy:
		p_is_firing = proxy.sync_is_firing
		var cond: String = proxy.sync_anim_condition
		var blend: float = proxy.sync_anim_blend
		if cond == "Movement" or cond == "MovementLow":
			if blend >= 4.0:
				p_is_running = true
			elif blend >= 0.5:
				p_is_walking = true

	var fwd := Vector3(sin(puppet.global_rotation.y), 0, cos(puppet.global_rotation.y)).normalized()
	return {
		"pos": puppet.global_position,
		"cam": puppet.global_position + Vector3(0, 1.6, 0),
		"is_running": p_is_running,
		"is_walking": p_is_walking,
		"is_firing": p_is_firing,
		"player_vector": fwd,
	}


func BroadcastAIPositions() -> void:
	var players := _players()
	if players == null or players.world_ai.is_empty():
		return
	var uuids: Array = []
	var positions := PackedVector3Array()
	var rotations := PackedVector3Array()
	var speeds := PackedFloat32Array()
	var ai_states := PackedInt32Array()
	for uuid in players.world_ai:
		var ai := _live_ai(uuid)
		if ai == null:
			continue
		uuids.append(uuid)
		positions.append(ai.global_position)
		rotations.append(ai.global_rotation)
		speeds.append(ai.speed)
		ai_states.append(ai.currentState)
	if uuids.is_empty():
		return
	BroadcastAIStates.rpc(uuids, positions, rotations, speeds, ai_states)


@rpc("authority", "unreliable", "call_remote")
func BroadcastAIStates(uuids: Array, positions: PackedVector3Array, rotations: PackedVector3Array, speeds: PackedFloat32Array, states: PackedInt32Array) -> void:
	var players := _players()
	if players == null:
		return
	for i in uuids.size():
		var ai := _live_ai(uuids[i])
		if ai == null:
			continue
		players.ai_targets[uuids[i]] = {"pos": positions[i], "rot": rotations[i]}
		ai.speed = speeds[i]
		var prev_state: int = ai.currentState
		ai.currentState = states[i]
		if prev_state != states[i]:
			_apply_client_animator_for_state(ai, states[i])


func _apply_client_animator_for_state(ai: Node, state: int) -> void:
	if not is_instance_valid(ai) or ai.animator == null:
		return
	var anim: AnimationMixer = ai.animator
	anim["parameters/Rifle/conditions/Movement"] = false
	anim["parameters/Pistol/conditions/Movement"] = false
	anim["parameters/Rifle/conditions/Combat"] = false
	anim["parameters/Pistol/conditions/Combat"] = false
	anim["parameters/Rifle/conditions/Guard"] = false
	anim["parameters/Pistol/conditions/Guard"] = false
	anim["parameters/Rifle/conditions/Defend"] = false
	anim["parameters/Pistol/conditions/Defend"] = false
	anim["parameters/Rifle/conditions/Hunt"] = false
	anim["parameters/Pistol/conditions/Hunt"] = false
	match state:
		0, 2:
			anim["parameters/Rifle/conditions/Guard"] = true
			anim["parameters/Pistol/conditions/Guard"] = true
		1, 3, 4, 6, 8, 11, 12, 13:
			anim["parameters/Rifle/conditions/Movement"] = true
			anim["parameters/Pistol/conditions/Movement"] = true
		7:
			anim["parameters/Rifle/conditions/Defend"] = true
			anim["parameters/Pistol/conditions/Defend"] = true
		9:
			anim["parameters/Rifle/conditions/Combat"] = true
			anim["parameters/Pistol/conditions/Combat"] = true
		5, 10:
			anim["parameters/Rifle/conditions/Hunt"] = true
			anim["parameters/Pistol/conditions/Hunt"] = true


@rpc("authority", "reliable", "call_remote")
func BroadcastAISpawn(uuid: int, spawn_type: String, spawn_pos: Vector3, spawn_rot: Vector3, variant: Dictionary) -> void:
	_log("BroadcastAISpawn RECEIVED uuid=%d type=%s variant_keys=%s" % [uuid, spawn_type, str(variant.keys())])
	var players := _players()
	if players.world_ai.has(uuid):
		return
	var entry := _make_spawn_entry(uuid, spawn_pos, spawn_rot, variant, spawn_type, false)
	if not _try_spawn_agent(entry):
		_pending_spawns.append(entry)


@rpc("any_peer", "reliable", "call_remote")
func RequestAISync(uuids: PackedInt32Array = PackedInt32Array()) -> void:
	if not multiplayer.is_server():
		return
	var players := _players()
	var sender: int = multiplayer.get_remote_sender_id()
	var targets: Array = Array(uuids) if uuids.size() > 0 else players.world_ai.keys()
	for uuid in targets:
		var ai := _live_ai(uuid)
		if ai == null:
			continue
		var variant: Variant = ai.get_meta("coop_spawn_variant", {})
		if typeof(variant) != TYPE_DICTIONARY:
			variant = {}
		SyncSingleAI.rpc_id(sender, int(uuid), ai.global_position, ai.global_rotation, variant)


@rpc("authority", "reliable", "call_remote")
func SyncSingleAI(uuid: int, pos: Vector3, rot: Vector3, variant: Dictionary) -> void:
	var players := _players()
	if players.world_ai.has(uuid):
		return
	var entry := _make_spawn_entry(uuid, pos, rot, variant, "", true)
	if not _try_spawn_agent(entry):
		_pending_spawns.append(entry)


@rpc("authority", "reliable", "call_remote")
func BroadcastAISound(uuid: int, sound_type: int, full_auto: bool = false) -> void:
	var ai := _live_ai(uuid)
	if ai == null:
		return
	ai.set_meta("_coop_force_local_play", true)
	match sound_type:
		AI_SOUND_FIRE:
			ai.fullAuto = full_auto
			ai.PlayFire()
		AI_SOUND_TAIL: ai.PlayTail()
		AI_SOUND_IDLE: ai.PlayIdle()
		AI_SOUND_COMBAT: ai.PlayCombat()
		AI_SOUND_DAMAGE: ai.PlayDamage()
		AI_SOUND_DEATH: ai.PlayDeath()
	ai.set_meta("_coop_force_local_play", false)


@rpc("authority", "reliable", "call_remote")
func BroadcastAIDeath(uuid: int, direction: Vector3, force: float, container_loot: Array = [], weapon_dict: Dictionary = {}, backpack_dict: Dictionary = {}, secondary_dict: Dictionary = {}, corpse_cid: int = -1) -> void:
	var players := _players()
	_prune_pending_uuid(uuid)
	var ai := _live_ai(uuid)
	if ai == null:
		players.world_ai.erase(uuid)
		players.ai_targets.erase(uuid)
		return
	var ss := _slot_serializer()
	var lc := _get_ai_loot_container(ai)
	if ss:
		if container_loot.size() > 0 and lc:
			lc.loot.clear()
			for dict in container_loot:
				var slot = ss.DeserializeSlotData(dict)
				if slot:
					lc.loot.append(slot)
		if weapon_dict.size() > 0 and ai.weapon and ai.weapon.slotData:
			ss.ApplySlotDictToPickup(ai.weapon, weapon_dict)
		if backpack_dict.size() > 0 and ai.backpack and ai.backpack.slotData:
			ss.ApplySlotDictToPickup(ai.backpack, backpack_dict)
		if secondary_dict.size() > 0 and ai.secondary and ai.secondary.slotData:
			ss.ApplySlotDictToPickup(ai.secondary, secondary_dict)
	_log("BroadcastAIDeath applying: uuid=%d dir=%s force=%.1f loot=%d lc=%s" % [uuid, str(direction), force, container_loot.size(), str(lc)])
	ai.set_meta("_coop_death_from_broadcast", true)
	ai.Death(direction, force)
	if ai.skeleton and "simulationTime" in ai.skeleton:
		ai.skeleton.simulationTime = 999.0
	players.world_ai.erase(uuid)

	if ai.weapon:
		var w_uuid: int = uuid * 10 + 1
		ai.weapon.set_meta("network_uuid", w_uuid)
		players.worldItems[w_uuid] = ai.weapon
		if w_uuid >= players.nextUuid:
			players.nextUuid = w_uuid + 1
	if ai.backpack:
		var b_uuid: int = uuid * 10 + 2
		ai.backpack.set_meta("network_uuid", b_uuid)
		players.worldItems[b_uuid] = ai.backpack
		if b_uuid >= players.nextUuid:
			players.nextUuid = b_uuid + 1
	if ai.secondary:
		var s_uuid: int = uuid * 10 + 3
		ai.secondary.set_meta("network_uuid", s_uuid)
		players.worldItems[s_uuid] = ai.secondary
		if s_uuid >= players.nextUuid:
			players.nextUuid = s_uuid + 1

	if lc:
		if not lc.is_in_group("CoopLootContainer"):
			lc.add_to_group("CoopLootContainer")
		lc.set_meta("coop_container_id", corpse_cid)


@rpc("authority", "reliable", "call_remote")
func BroadcastAIRemove(uuids: PackedInt32Array) -> void:
	var players := _players()
	for uuid in uuids:
		var key: int = int(uuid)
		_prune_pending_uuid(key)
		var ai: Node = players.world_ai.get(key)
		if is_instance_valid(ai) and not ai.dead:
			ai.queue_free()
		players.world_ai.erase(key)
		players.ai_targets.erase(key)


@rpc("any_peer", "reliable", "call_remote")
func RequestAIManifest() -> void:
	if not multiplayer.is_server():
		return
	var players := _players()
	var sender: int = multiplayer.get_remote_sender_id()
	var uuids := PackedInt32Array()
	for uuid in players.world_ai:
		if _live_ai(uuid) != null:
			uuids.append(int(uuid))
	DeliverAIManifest.rpc_id(sender, uuids)


@rpc("authority", "reliable", "call_remote")
func DeliverAIManifest(host_uuids: PackedInt32Array) -> void:
	var players := _players()
	var host_set: Dictionary = {}
	for u in host_uuids:
		host_set[int(u)] = true
	var client_set: Dictionary = {}
	for u in players.world_ai:
		client_set[int(u)] = true

	var missing_on_client: Array = []
	var extra_on_client: Array = []
	for u in host_set:
		if not client_set.has(u):
			missing_on_client.append(u)
	for u in client_set:
		if not host_set.has(u):
			extra_on_client.append(u)

	if missing_on_client.is_empty() and extra_on_client.is_empty():
		return

	for u in extra_on_client:
		var ai: Node = players.world_ai.get(u)
		if is_instance_valid(ai) and not ai.dead:
			ai.queue_free()
		players.world_ai.erase(u)
		players.ai_targets.erase(u)

	if not missing_on_client.is_empty():
		RequestAISync.rpc_id(1, PackedInt32Array(missing_on_client))


@rpc("any_peer", "reliable", "call_remote")
func RequestAIDamage(uuid: int, hitbox: String, damage: float) -> void:
	if not multiplayer.is_server():
		return
	var players := _players()
	var ai := _live_ai(uuid)
	if ai == null:
		players.world_ai.erase(uuid)
		return
	ai.WeaponDamage(hitbox, damage)
