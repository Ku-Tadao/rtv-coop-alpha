extends "res://mods/RTVCoopAlpha/Game/Sync/BaseSync.gd"




var _container_holders: Dictionary = {}

# Resolving a container id used to scan the CoopLootContainer group and then walk
# every Interactable up its parent chain. The host sends one container RPC per
# container on scene load, so each client paid that scan once per container:
# a few hundred containers against a few thousand interactables is hundreds of
# thousands of node visits while the guest is already sitting on a loading screen.
var _cid_cache: Dictionary = {}
var _cid_cache_frame: int = -1


func _sync_key() -> String:
	return "container"


func _players() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.players if coop else null


func _slot_serializer() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.get_sync("slot_serializer") if coop else null


func _node_id(node: Node) -> int:
	if node.has_meta("coop_container_id"):
		return int(node.get_meta("coop_container_id"))
	return 0


func _find_container_by_id(cid: int) -> Node:
	# _node_id() reports 0 for a node that was never assigned an id; matching on that would
	# hand back an arbitrary unregistered container. Fail closed instead.
	if cid <= 0:
		return null
	var hit = _cid_cache.get(cid)
	if is_instance_valid(hit) and hit.is_inside_tree():
		return hit
	# Ids are stamped from five call sites, so rather than invalidate at each of
	# them, rebuild on a miss -- capped at one scan per frame. The load-time burst
	# of container RPCs arrives within a frame or two, so they share one scan
	# instead of paying for one each. A genuinely unknown id costs nothing extra:
	# the cache was already rebuilt this frame, so we know it is not there.
	var frame: int = Engine.get_process_frames()
	if frame == _cid_cache_frame:
		return null
	_cid_cache_frame = frame
	_rebuild_cid_cache()
	hit = _cid_cache.get(cid)
	return hit if is_instance_valid(hit) else null


func _rebuild_cid_cache() -> void:
	_cid_cache.clear()
	for container in get_tree().get_nodes_in_group("CoopLootContainer"):
		if not is_instance_valid(container):
			continue
		var id: int = _node_id(container)
		if id > 0:
			_cid_cache[id] = container
	for collider in get_tree().get_nodes_in_group("Interactable"):
		if not is_instance_valid(collider):
			continue
		var node: Node = collider
		while node:
			if node is LootContainer:
				var id: int = _node_id(node)
				if id > 0 and not _cid_cache.has(id):
					# Membership is what decides whether a container syncs at all,
					# so adopt it here the way the old scan did.
					if not node.is_in_group("CoopLootContainer"):
						node.add_to_group("CoopLootContainer")
					_cid_cache[id] = node
				break
			node = node.get_parent()


## Called on map change: every cached node belongs to the scene being torn down.
func reset_scene_state() -> void:
	_container_holders.clear()
	_cid_cache.clear()
	_cid_cache_frame = -1


func SyncContainerStorage(container: Node) -> void:
	if not CoopAuthority.is_active() or container == null:
		return
	var ss := _slot_serializer()
	if ss == null:
		return
	var serialized: Array = []
	for slot in container.storage:
		serialized.append(ss.SerializeSlotData(slot))
	var cid: int = _node_id(container)
	if CoopAuthority.is_host():
		BroadcastContainerStorage.rpc(cid, serialized)
	else:
		SubmitContainerStorage.rpc_id(1, cid, serialized)


@rpc("any_peer", "reliable", "call_remote")
func SubmitContainerStorage(cid: int, serialized: Array) -> void:
	if not multiplayer.is_server():
		return
	var container := _find_container_by_id(cid)
	if container == null:
		return
	var ss := _slot_serializer()
	container.storage.clear()
	if ss:
		for dict in serialized:
			container.storage.append(ss.DeserializeSlotData(dict))
	container.storaged = true
	BroadcastContainerStorage.rpc(cid, serialized)


@rpc("authority", "reliable", "call_remote")
func BroadcastContainerStorage(cid: int, serialized: Array) -> void:
	var container := _find_container_by_id(cid)
	if container == null:
		return
	var ss := _slot_serializer()
	container.storage.clear()
	if ss:
		for dict in serialized:
			container.storage.append(ss.DeserializeSlotData(dict))
	container.storaged = true


@rpc("authority", "reliable", "call_remote")
func BroadcastContainerFullState(cid: int, pos: Vector3, loot_arr: Array, storage_arr: Array, storaged_flag: bool) -> void:
	_log("BroadcastContainerFullState RECEIVED cid=%d pos=%s loot=%d storage=%d" % [cid, str(pos), loot_arr.size(), storage_arr.size()])
	# No position-based fallback: guessing the node by proximity assigns an id the host never
	# gave it, which then shadows the node that legitimately owns that id.
	var container := _find_container_by_id(cid)
	if container == null:
		_log("  → container NOT FOUND for cid=%d" % cid)
		return
	var ss := _slot_serializer()
	if ss == null:
		return
	container.loot.clear()
	for dict in loot_arr:
		var slot = ss.DeserializeSlotData(dict)
		if slot:
			container.loot.append(slot)
	container.storage.clear()
	for dict in storage_arr:
		var slot = ss.DeserializeSlotData(dict)
		if slot:
			container.storage.append(slot)
	container.storaged = storaged_flag


func _log(msg: String) -> void:
	var l = Engine.get_meta("CoopLogger", null)
	if l: l.log_msg("ContainerSync", msg)

func TryOpenContainer(container) -> void:
	_log("TryOpenContainer container=%s" % str(container))
	if container == null:
		return
	var cid: int = _node_id(container)
	_log("  cid=%d is_active=%s is_host=%s" % [cid, str(CoopAuthority.is_active()), str(CoopAuthority.is_host())])
	if not CoopAuthority.is_active():
		_coop_open_container_ui(container)
		return
	if CoopAuthority.is_host():
		if _container_holders.has(cid) and _container_holders[cid] != 1:
			_coop_in_use_feedback(int(_container_holders[cid]))
			return
		_container_holders[cid] = 1
		BroadcastContainerHolder.rpc(cid, 1)
		_coop_open_container_ui(container)
		return
	RequestContainerOpen.rpc_id(1, cid)


func ReleaseContainerLock(container) -> void:
	if container == null or not CoopAuthority.is_active():
		return
	var cid: int = _node_id(container)
	if CoopAuthority.is_host():
		if _container_holders.has(cid) and _container_holders[cid] == 1:
			_container_holders.erase(cid)
			BroadcastContainerHolder.rpc(cid, 0)
		return
	ReleaseContainer.rpc_id(1, cid)


func _coop_open_container_ui(container) -> void:
	var coop := RTVCoop.get_instance()
	var ui_root: Node = coop.scene.core_ui() if coop and coop.scene else null
	var players := _players()
	if ui_root and ui_root.has_method("OpenContainer"):
		if players:
			players.container_open_bypassed = true
		ui_root.OpenContainer(container)
		if players:
			players.container_open_bypassed = false
	if container.has_method("ContainerAudio"):
		container.ContainerAudio()


func _coop_play_local_error() -> void:
	var players := _players()
	var iface: Node = players.GetLocalInterface() if players and players.has_method("GetLocalInterface") else null
	if iface and iface.has_method("PlayError"):
		iface.PlayError()


func _coop_in_use_feedback(holder_id: int) -> void:
	_coop_play_local_error()
	var players := _players()
	var holder_name: String = players.GetPlayerName(holder_id) if players else str(holder_id)
	Loader.Message("In use by " + holder_name, Color.ORANGE)


func release_holders_for_peer(peer_id: int) -> void:
	for cid in _container_holders.keys().duplicate():
		if _container_holders[cid] == peer_id:
			_container_holders.erase(cid)
			if CoopAuthority.is_active():
				BroadcastContainerHolder.rpc(cid, 0)


@rpc("any_peer", "reliable", "call_remote")
func RequestContainerOpen(cid: int) -> void:
	_log("RequestContainerOpen RECEIVED cid=%d is_server=%s" % [cid, str(multiplayer.is_server())])
	if not multiplayer.is_server():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	if _container_holders.has(cid) and _container_holders[cid] != sender_id:
		_log("  → DENIED (held by %d)" % _container_holders[cid])
		DenyContainerOpen.rpc_id(sender_id, cid, int(_container_holders[cid]))
		return
	_container_holders[cid] = sender_id
	_log("  → GRANTED to peer %d" % sender_id)
	BroadcastContainerHolder.rpc(cid, sender_id)
	GrantContainerOpen.rpc_id(sender_id, cid)


@rpc("authority", "reliable", "call_remote")
func GrantContainerOpen(cid: int) -> void:
	_log("GrantContainerOpen RECEIVED cid=%d" % cid)
	var container := _find_container_by_id(cid)
	if container == null:
		_log("  → container NOT FOUND, aborting")
		return
	_coop_open_container_ui(container)


@rpc("authority", "reliable", "call_remote")
func DenyContainerOpen(_cid: int, holder_id: int = 0) -> void:
	_coop_in_use_feedback(holder_id)


@rpc("any_peer", "reliable", "call_remote")
func ReleaseContainer(cid: int) -> void:
	if not multiplayer.is_server():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	if _container_holders.has(cid) and _container_holders[cid] == sender_id:
		_container_holders.erase(cid)
		BroadcastContainerHolder.rpc(cid, 0)


@rpc("authority", "reliable", "call_remote")
func BroadcastContainerHolder(cid: int, holder_peer_id: int) -> void:
	if holder_peer_id == 0:
		_container_holders.erase(cid)
	else:
		_container_holders[cid] = holder_peer_id
