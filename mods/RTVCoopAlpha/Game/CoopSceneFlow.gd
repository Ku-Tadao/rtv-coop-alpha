class_name CoopSceneFlow extends Node



const CoopAuthority = preload("res://mods/RTVCoopAlpha/Framework/CoopAuthority.gd")
const RTVCoop = preload("res://mods/RTVCoopAlpha/Game/Coop.gd")

const SCENE_CHANGE_TIMEOUT := 90.0
const HOST_READY_BROADCAST_DELAY := 3.0
const LOOT_MANIFEST_DELAY := 2.0


var _players: Node

var lastKnownMap: Node = null
var pendingSceneChange: String = ""
var pendingSceneTimer: float = 0.0
var pendingSpawnPosition: Vector3 = Vector3.ZERO
var pendingHostReady: float = -1.0
var pendingHostSceneName: String = ""
var pendingLootBroadcast: float = -1.0
var pendingSceneScan: float = -1.0
var pendingSecondScan: float = -1.0
var pendingSecondLootSync: float = -1.0


func _enter_tree() -> void:
	_players = get_parent()


var _physics_logged_once: bool = false
var _pending_layouts: Array = []
var _pending_runtime_spawns: Array = []

func _physics_process(delta: float) -> void:
	if not CoopAuthority.is_active() or _players == null:
		return
	if not _physics_logged_once:
		_physics_logged_once = true
		_log("_physics_process FIRST RUN (active=%s server=%s pendingSecondScan=%.1f)" % [str(CoopAuthority.is_active()), str(multiplayer.is_server()), pendingSecondScan])

	if pendingSceneChange != "" and not multiplayer.is_server():
		pendingSceneTimer += delta
		if pendingSceneTimer >= SCENE_CHANGE_TIMEOUT:
			var cur_map: Node = GetMap()
			var cur_name: String = str(cur_map.get("mapName")) if cur_map and cur_map.get("mapName") else ""
			if cur_name != pendingSceneChange:
				_players.SaveClientCharacterBuffer()
				Loader.LoadScene(pendingSceneChange)
			pendingSceneChange = ""
			pendingSceneTimer = 0.0

	ScanIfNeeded(delta)

	if pendingHostReady > 0.0:
		pendingHostReady -= delta
		if pendingHostReady <= 0.0:
			var controller: Node = _players.GetLocalController()
			var host_pos: Vector3 = controller.global_position if controller else Vector3.ZERO
			_players._ensure_session_seed()
			HostSceneReady.rpc(pendingHostSceneName, host_pos, _players.coop_session_seed)
			pendingHostSceneName = ""
			_players.gameData.isTransitioning = false

	if pendingSceneScan > 0.0:
		pendingSceneScan -= delta
		if pendingSceneScan <= 0.0:
			if multiplayer.is_server():
				RegisterSceneItems()
				RegisterSceneContainers()
				pendingLootBroadcast = LOOT_MANIFEST_DELAY
				print("[SceneFlow] Host: registered %d items, broadcast in %.1fs" % [_players.worldItems.size(), LOOT_MANIFEST_DELAY])

	if pendingSecondScan > 0.0:
		pendingSecondScan -= delta
		if pendingSecondScan <= 0.0:
			_log("Second scan fired (is_server=%s)" % str(multiplayer.is_server()))
			if multiplayer.is_server():
				RegisterSceneItems()
				RegisterSceneContainers()
				_broadcast_shelter_furniture()
				_broadcast_runtime_spawns()
				_broadcast_layouts()
				pendingLootBroadcast = 0.5

	if pendingLootBroadcast > 0.0:
		pendingLootBroadcast -= delta
		if pendingLootBroadcast <= 0.0:
			_broadcast_scene_loot_manifest()


func Reset() -> void:
	lastKnownMap = null
	pendingSceneChange = ""
	pendingSceneTimer = 0.0
	pendingSpawnPosition = Vector3.ZERO
	pendingHostReady = -1.0
	pendingHostSceneName = ""
	pendingLootBroadcast = -1.0
	pendingSceneScan = -1.0
	pendingSecondScan = -1.0
	pendingSecondLootSync = -1.0
	_pending_layouts.clear()
	_pending_runtime_spawns.clear()


func GetMap() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.scene.get_map() if coop and coop.scene else null


func ScanIfNeeded(_delta: float) -> void:
	if _players == null:
		return
	var current_map: Node = GetMap()
	if current_map == lastKnownMap:
		return
	print("[SceneFlow] Map change detected: %s (was %s)" % [str(current_map), str(lastKnownMap)])
	_players.worldItems.clear()
	_players.worldFurniture.clear()
	_players.world_ai.clear()
	_players.ai_targets.clear()
	_players.nextUuid = 0
	_players.nextFurnitureId = 0
	_players.nextContainerId = 1
	pendingSecondLootSync = -1.0
	_players.scene_ready = false

	var coop := RTVCoop.get_instance()
	var ai_sync: Node = coop.get_sync("ai") if coop else null
	if ai_sync and "_pending_spawns" in ai_sync:
		ai_sync._pending_spawns.clear()
	var event_sync: Node = coop.get_sync("event") if coop else null
	if event_sync and "_pending_events" in event_sync:
		event_sync._pending_events.clear()
	if event_sync and "_sleep_ready" in event_sync:
		event_sync._sleep_ready.clear()
	if event_sync and "_sleep_in_progress" in event_sync:
		event_sync._sleep_in_progress = false
	var container_sync: Node = coop.get_sync("container") if coop else null
	if container_sync and "_container_holders" in container_sync:
		container_sync._container_holders.clear()

	lastKnownMap = current_map
	if current_map == null:
		return
	_players.scene_ready = true
	pendingSceneScan = 1.0
	pendingSecondScan = 10.0

	if not _pending_layouts.is_empty():
		_log("Applying %d pending layouts" % _pending_layouts.size())
		_apply_layouts_now(_pending_layouts)
		_pending_layouts.clear()
	if not _pending_runtime_spawns.is_empty():
		_log("Applying %d pending runtime spawns" % _pending_runtime_spawns.size())
		ApplyRuntimeSpawns(_pending_runtime_spawns)
		_pending_runtime_spawns.clear()
	_log("Map change: pendingSecondScan set to 10.0 (map=%s, is_server=%s)" % [str(current_map), str(multiplayer.is_server())])

	if coop and coop.events:
		coop.events.scene_ready.emit(current_map)

	if CoopAuthority.is_active() and multiplayer.multiplayer_peer and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		if multiplayer.is_server():
			pendingHostSceneName = str(current_map.get("mapName")) if current_map.get("mapName") else ""
			pendingHostReady = HOST_READY_BROADCAST_DELAY
			_players.gameData.isTransitioning = true
			print("[SceneFlow] Host: scheduling broadcast for '%s'" % pendingHostSceneName)
		else:
			if pendingSpawnPosition != Vector3.ZERO:
				ApplyClientSpawn(pendingSpawnPosition)
				pendingSpawnPosition = Vector3.ZERO
			if ai_sync and ai_sync.has_method("RequestAISync"):
				ai_sync.RequestAISync.rpc_id(1)
				if "_manifest_timer" in ai_sync and "MANIFEST_CHECK_INTERVAL" in ai_sync:
					ai_sync._manifest_timer = max(0.0, ai_sync.MANIFEST_CHECK_INTERVAL - 5.0)
			print("[SceneFlow] Client: requesting loot sync from host")
			RequestSceneLootSync.rpc_id(1)
			if event_sync and event_sync.has_method("RequestFireSync"):
				event_sync.RequestFireSync.rpc_id(1)
	else:
		print("[SceneFlow] Map detected but coop not active (active=%s, peer=%s)" % [CoopAuthority.is_active(), multiplayer.multiplayer_peer != null])


func RegisterSceneItems() -> void:
	if _players == null:
		return
	var items: Array = get_tree().get_nodes_in_group("Item")
	items.sort_custom(func(a, b): return str(a.get_path()) < str(b.get_path()))
	for item in items:
		if not (item is Pickup):
			continue
		if item.has_meta("network_uuid"):
			continue
		if _players._is_trader_display_item(item):
			continue
		item.set_meta("network_uuid", _players.nextUuid)
		_players.worldItems[_players.nextUuid] = item
		_players.nextUuid += 1


func RegisterSceneContainers() -> void:
	var seen: Dictionary = {}
	for collider in get_tree().get_nodes_in_group("Interactable"):
		if not is_instance_valid(collider):
			continue
		var node: Node = collider
		var root: Node = null
		while node:
			if node is LootContainer:
				root = node
				break
			node = node.get_parent()
		if root == null or seen.has(root):
			continue
		seen[root] = true
		if not root.is_in_group("CoopLootContainer"):
			root.add_to_group("CoopLootContainer")
		if CoopAuthority.is_host() and not root.has_meta("coop_container_id"):
			root.set_meta("coop_container_id", _players.nextContainerId)
			_players.nextContainerId += 1


func ApplyClientSpawn(pos: Vector3) -> void:
	if _players == null:
		return
	var controller: Node = _players.GetLocalController()
	if controller:
		controller.global_position = pos
		if "velocity" in controller:
			controller.velocity = Vector3.ZERO


func TriggerRescan(delay: float = 1.5) -> void:
	if not CoopAuthority.is_active() or not multiplayer.is_server():
		return
	await get_tree().create_timer(delay, false).timeout
	RegisterSceneItems()
	RegisterSceneContainers()
	pendingLootBroadcast = 0.2


@rpc("authority", "reliable", "call_remote")
func ApplySceneChange(scene_name: String) -> void:
	pendingSceneChange = scene_name
	pendingSceneTimer = 0.0


@rpc("authority", "reliable", "call_remote")
func HostSceneReady(scene_name: String = "", host_pos: Vector3 = Vector3.ZERO, scene_seed: int = 0) -> void:
	if _players == null:
		return
	if scene_seed != 0:
		_players.coop_session_seed = scene_seed
	var target: String = pendingSceneChange if pendingSceneChange != "" else scene_name
	if target == "":
		return
	var current_map: Node = GetMap()
	var current_name: String = str(current_map.get("mapName")) if current_map and current_map.get("mapName") else ""
	if current_name == target:
		pendingSceneChange = ""
		pendingSceneTimer = 0.0
		if host_pos != Vector3.ZERO:
			ApplyClientSpawn(host_pos)
		return
	if host_pos != Vector3.ZERO:
		pendingSpawnPosition = host_pos
	_players.SaveClientCharacterBuffer()
	_players.gameData.isTransitioning = true
	Loader.LoadScene(target)
	pendingSceneChange = ""
	pendingSceneTimer = 0.0


func _build_loot_manifest() -> Array:
	var manifest: Array = []
	if _players == null:
		return manifest
	var ss: Node = RTVCoop.get_instance().get_sync("slot_serializer") if RTVCoop.get_instance() else null
	for uuid in _players.worldItems:
		var item: Node = _players.worldItems[uuid]
		if not is_instance_valid(item) or not (item is Pickup):
			continue
		if item.slotData == null or item.slotData.itemData == null:
			continue
		var entry: Dictionary = {
			"uuid": uuid,
			"file": item.slotData.itemData.file,
			"pos": item.global_position,
			"rot": item.global_rotation,
		}
		if ss:
			entry["slotDict"] = ss.SerializeSlotData(item.slotData)
		manifest.append(entry)
	return manifest


func PushLootStateTo(peer_id: int) -> void:
	if not multiplayer.is_server() or _players == null:
		return
	if _players.worldItems.is_empty():
		RegisterSceneItems()
		RegisterSceneContainers()
	var manifest: Array = _build_loot_manifest()
	if not manifest.is_empty():
		ApplyLootManifest.rpc_id(peer_id, manifest)
	_broadcast_container_storage_to(peer_id)


func _log(msg: String) -> void:
	var l = Engine.get_meta("CoopLogger", null)
	if l: l.log_msg("SceneFlow", msg)

func _broadcast_shelter_furniture() -> void:
	if not multiplayer.is_server() or _players == null:
		_log("_broadcast_shelter_furniture: skipped (server=%s players=%s)" % [str(multiplayer.is_server()), str(_players != null)])
		return
	var coop := RTVCoop.get_instance()
	var fs: Node = coop.get_sync("furniture") if coop else null
	if fs == null:
		_log("_broadcast_shelter_furniture: no furniture sync module")
		return
	var furnitures: Array = get_tree().get_nodes_in_group("Furniture")
	_log("_broadcast_shelter_furniture: found %d furniture nodes" % furnitures.size())
	if furnitures.is_empty():
		return
	fs.BroadcastClearShelterFurniture.rpc()
	var seen_roots: Dictionary = {}
	for furn_node in furnitures:
		if not is_instance_valid(furn_node) or furn_node.owner == null:
			continue
		var root: Node = furn_node.owner
		if seen_roots.has(root):
			continue
		seen_roots[root] = true
		var furn_component: Node = null
		for child in root.get_children():
			if child is Furniture:
				furn_component = child
				break
		if furn_component == null or furn_component.itemData == null or furn_component.itemData.file == "":
			_log("  skip: %s — no Furniture component or no itemData" % str(root))
			continue
		var item_data = furn_component.itemData
		var fid: int = _players.GenerateFurnitureId() if _players.has_method("GenerateFurnitureId") else 0
		if fid == 0:
			continue
		root.set_meta("coop_furniture_id", fid)
		_players.worldFurniture[fid] = root
		if root is LootContainer:
			root.set_meta("coop_container_id", fid)
			if not root.is_in_group("CoopLootContainer"):
				root.add_to_group("CoopLootContainer")
		_log("  → spawning fid=%d file=%s pos=%s" % [fid, item_data.file, str(root.global_position)])
		fs.BroadcastFurnitureSpawn.rpc(fid, item_data.file, root.global_position, root.global_rotation, root.scale)


func _broadcast_runtime_spawns() -> void:
	if not multiplayer.is_server() or _players == null:
		return
	var spawns: Array = []
	var scene := get_tree().current_scene
	if scene == null:
		return
	var spawners: Array = []
	_find_spawners(scene, spawners)
	for spawner in spawners:
		var sceneData = spawner.data as SpawnerSceneData if "data" in spawner else null
		if sceneData == null or not sceneData.runtime:
			continue
		for child in spawner.get_children():
			if child.scene_file_path == "":
				continue
			spawns.append({
				"file": child.scene_file_path,
				"pos": child.global_position,
				"rot": child.global_rotation,
				"scale": child.scale,
			})
	if spawns.is_empty():
		_log("_broadcast_runtime_spawns: no spawns found")
		return
	var sample: String = spawns[0].get("file", "?") if spawns.size() > 0 else "?"
	_log("Broadcasting %d runtime spawns (first file: %s)" % [spawns.size(), sample])
	ApplyRuntimeSpawns.rpc(spawns)


func _find_spawners(node: Node, result: Array) -> void:
	if "data" in node and node.data is SpawnerSceneData:
		result.append(node)
	for child in node.get_children():
		_find_spawners(child, result)


@rpc("authority", "reliable", "call_remote")
func ApplyRuntimeSpawns(spawns: Array) -> void:
	_log("Received %d runtime spawns" % spawns.size())
	var map := GetMap()
	if map == null:
		_log("  → NO MAP, queuing")
		_pending_runtime_spawns = spawns.duplicate()
		return
	_clear_client_runtime_spawns(map)
	var placed: int = 0
	var failed: int = 0
	for entry in spawns:
		var file: String = entry.get("file", "")
		if file == "":
			continue
		var scene = load(file)
		if scene == null:
			failed += 1
			continue
		var instance = scene.instantiate()
		map.add_child(instance)
		instance.global_position = entry.get("pos", Vector3.ZERO)
		instance.global_rotation = entry.get("rot", Vector3.ZERO)
		instance.scale = entry.get("scale", Vector3.ONE)
		placed += 1
	_log("  → placed=%d failed=%d" % [placed, failed])


func _clear_client_runtime_spawns(map: Node) -> void:
	var cleared: int = 0
	var scene := get_tree().current_scene
	if scene == null:
		return
	var spawners: Array = []
	_find_spawners(scene, spawners)
	for spawner in spawners:
		var sd = spawner.data as SpawnerSceneData if "data" in spawner else null
		if sd == null or not sd.runtime:
			continue
		for child in spawner.get_children().duplicate():
			if child.scene_file_path != "":
				child.queue_free()
				cleared += 1
	_log("  → cleared %d existing runtime spawns" % cleared)


func _broadcast_layouts() -> void:
	if not multiplayer.is_server():
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	var layouts: Array = []
	_find_nodes_by_script(scene, "Layouts", layouts)
	if layouts.is_empty():
		return
	var data: Array = []
	for layout_node in layouts:
		if layout_node.get_child_count() == 0:
			continue
		var chosen_name: String = layout_node.get_child(0).name
		data.append({"path": str(layout_node.get_path()), "chosen": chosen_name})
	if data.is_empty():
		return
	_log("Broadcasting %d layouts" % data.size())
	ApplyLayouts.rpc(data)


func _find_nodes_by_script(node: Node, script_name: String, result: Array) -> void:
	var s = node.get_script()
	if s and str(s.resource_path).find(script_name) != -1:
		result.append(node)
	for child in node.get_children():
		_find_nodes_by_script(child, script_name, result)


@rpc("authority", "reliable", "call_remote")
func ApplyLayouts(data: Array) -> void:
	_log("Received %d layouts" % data.size())
	if get_tree().current_scene == null:
		_log("  → scene not ready, queuing")
		_pending_layouts = data.duplicate()
		return
	_apply_layouts_now(data)


func _apply_layouts_now(data: Array) -> void:
	var applied: int = 0
	for entry in data:
		var path: String = entry.get("path", "")
		var chosen: String = entry.get("chosen", "")
		if path == "" or chosen == "":
			continue
		var lookup_path: String = path.substr(6) if path.begins_with("/root/") else path
		var layout_node: Node = get_tree().root.get_node_or_null(lookup_path)
		if layout_node == null:
			var scene_name: String = get_tree().current_scene.name if get_tree().current_scene else "null"
			_log("  → layout NOT FOUND: '%s' (lookup='%s' scene='%s')" % [path, lookup_path, scene_name])
			continue
		if layout_node.get_child_count() <= 1:
			_log("  → layout %s has <=1 child, skip (extend not loaded)" % path)
			continue
		var target: Node = null
		for child in layout_node.get_children():
			if child.name == chosen:
				target = child
				break
		if target == null:
			_log("  → layout %s: child '%s' not found" % [path, chosen])
			continue
		target.show()
		applied += 1
		for child in layout_node.get_children().duplicate():
			if child != target:
				child.queue_free()
	_log("  → applied %d/%d layouts" % [applied, data.size()])


func _broadcast_scene_loot_manifest() -> void:
	if not multiplayer.is_server() or _players == null:
		return
	var manifest: Array = _build_loot_manifest()
	print("[SceneFlow] Host: broadcasting loot manifest (%d items)" % manifest.size())
	if manifest.is_empty():
		print("[SceneFlow] Host: manifest empty, skipping broadcast")
		return
	ApplyLootManifest.rpc(manifest)
	_broadcast_container_storage_to(0)


func _broadcast_container_storage_to(peer_id: int) -> void:
	var coop := RTVCoop.get_instance()
	if coop == null:
		return
	var cs: Node = coop.get_sync("container")
	var ss: Node = coop.get_sync("slot_serializer")
	if cs == null or ss == null:
		print("[SceneFlow] Host: container sync missing (cs=%s, ss=%s)" % [cs != null, ss != null])
		return
	var containers := get_tree().get_nodes_in_group("CoopLootContainer")
	print("[SceneFlow] Host: broadcasting %d containers to peer %d" % [containers.size(), peer_id])
	for root in containers:
		if not is_instance_valid(root) or not (root is LootContainer):
			continue
		if root.locked:
			continue
		var loot_arr: Array = []
		for slot in root.loot:
			loot_arr.append(ss.SerializeSlotData(slot))
		var storage_arr: Array = []
		for slot in root.storage:
			storage_arr.append(ss.SerializeSlotData(slot))
		var cid: int = cs._node_id(root)
		if peer_id == 0:
			cs.BroadcastContainerFullState.rpc(cid, root.global_position, loot_arr, storage_arr, root.storaged)
		else:
			cs.BroadcastContainerFullState.rpc_id(peer_id, cid, root.global_position, loot_arr, storage_arr, root.storaged)


@rpc("authority", "reliable", "call_remote")
func ApplyLootManifest(manifest: Array) -> void:
	if _players == null:
		return
	print("[SceneFlow] Client: received loot manifest (%d items)" % manifest.size())
	var ss: Node = RTVCoop.get_instance().get_sync("slot_serializer") if RTVCoop.get_instance() else null
	var map: Node = GetMap()
	var max_uuid: int = _players.nextUuid - 1
	var matched: int = 0
	var spawned: int = 0
	for entry in manifest:
		var uuid: int = int(entry.get("uuid", -1))
		if uuid < 0:
			continue
		if uuid > max_uuid:
			max_uuid = uuid
		if _players.worldItems.has(uuid) and is_instance_valid(_players.worldItems[uuid]):
			var existing: Node = _players.worldItems[uuid]
			existing.global_position = entry.get("pos", existing.global_position)
			existing.global_rotation = entry.get("rot", existing.global_rotation)
			if ss and entry.has("slotDict"):
				ss.ApplySlotDictToPickup(existing, entry["slotDict"])
			matched += 1
			continue
		var file: String = entry.get("file", "")
		if file == "" or map == null:
			continue
		var scene = Database.get(file)
		if scene == null:
			push_warning("[SceneFlow] Manifest item not in Database: %s" % file)
			continue
		var pickup: Node = scene.instantiate()
		map.add_child(pickup)
		pickup.global_position = entry.get("pos", Vector3.ZERO)
		pickup.global_rotation = entry.get("rot", Vector3.ZERO)
		if ss and entry.has("slotDict"):
			ss.ApplySlotDictToPickup(pickup, entry["slotDict"])
		pickup.freeze = true
		pickup.set_meta("network_uuid", uuid)
		_players.worldItems[uuid] = pickup
		spawned += 1
	_players.nextUuid = max_uuid + 1
	print("[SceneFlow] Client: manifest result — matched=%d, spawned=%d" % [matched, spawned])


@rpc("any_peer", "reliable", "call_remote")
func RequestSceneLootSync() -> void:
	if not multiplayer.is_server() or _players == null:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	print("[SceneFlow] Host: received loot sync request from peer %d" % sender)
	if _players.worldItems.is_empty():
		RegisterSceneItems()
		RegisterSceneContainers()
	var manifest: Array = _build_loot_manifest()
	print("[SceneFlow] Host: sending manifest (%d items) + containers to peer %d" % [manifest.size(), sender])
	ApplyLootManifest.rpc_id(sender, manifest)
	_broadcast_container_storage_to(sender)
