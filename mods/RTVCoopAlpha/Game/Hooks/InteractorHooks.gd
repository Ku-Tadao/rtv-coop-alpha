extends "res://mods/RTVCoopAlpha/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoopAlpha/Framework/CoopAuthority.gd")

const REVIVE_DURATION := 5.0
const REVIVE_MAX_RANGE := 4.0

var _reviving: bool = false
var _diag_cooldown: float = 0.0

func _log(msg: String) -> void:
	var l = Engine.get_meta("CoopLogger", null)
	if l: l.log_msg("InteractorHooks", msg)

func _setup_hooks() -> void:
	_log("_setup_hooks called")
	var id1 = CoopHook.register(self, "interactor-_physics_process-post", _on_interactor_physics_post)
	_log("  interactor-_physics_process-post → id=%d" % id1)
	var id2 = CoopHook.register_replace_or_post(self, "interactor-interact", _replace_interactor_interact, _post_interactor_interact)
	_log("  interactor-interact → id=%d" % id2)


func _on_interactor_physics_post(delta: float) -> void:
	var interactor := CoopHook.caller()
	if interactor == null or not CoopAuthority.is_active():
		return
	var gd: Resource = load("res://Resources/GameData.tres")
	if gd == null:
		return

	_diag_cooldown -= delta
	if downed and downed.is_any_peer_downed() and _diag_cooldown <= 0.0:
		_diag_cooldown = 2.0
		var tgt_info: String = "null"
		if interactor.target:
			var groups: String = str(interactor.target.get_groups())
			var owner_str: String = str(interactor.target.owner) if interactor.target.owner else "null"
			var layer: int = interactor.target.collision_layer if "collision_layer" in interactor.target else -1
			tgt_info = "groups=%s owner=%s layer=%d" % [groups, owner_str, layer]
		_log("DIAG target=%s interaction=%s freeze=%s decor=%s" % [tgt_info, str(gd.interaction), str(gd.freeze), str(gd.decor)])

	if interactor.target and interactor.target.is_in_group("Interactable") and not gd.decor:
		if interactor.target.owner and interactor.target.owner.get("isDowned") == true:
			if Input.is_action_just_pressed("interact") and not _reviving:
				_log("revive: interact pressed on downed puppet (post hook)")
				_start_revive(interactor.target.owner)
			return

	if not interactor.target:
		return
	if interactor.target.is_in_group("Transition") and not gd.decor:
		if downed and downed.is_any_peer_downed():
			gd.tooltip = "Cannot leave while a player is downed"
			gd.interaction = false
			gd.transition = false
			return
		if CoopAuthority.is_client():
			gd.interaction = false
			gd.transition = false
		return
	if interactor.target.is_in_group("Interactable") and not gd.decor:
		if interactor.target.owner and interactor.target.owner.get("canSleep") != null:
			_coop_bed_tooltip(interactor.target.owner, gd)
		elif interactor.target.owner and interactor.target.owner is LootContainer:
			_coop_container_tooltip(interactor.target.owner, gd)


func _replace_interactor_interact() -> void:
	var interactor := CoopHook.caller()
	if interactor == null or not CoopAuthority.is_active():
		_log("_replace_interactor_interact: early return (caller=%s active=%s)" % [str(interactor != null), str(CoopAuthority.is_active())])
		return
	if _reviving:
		CoopHook.skip_super()
		return
	if not Input.is_action_just_pressed("interact"):
		return
	var gd: Resource = load("res://Resources/GameData.tres")
	if gd == null or interactor.target == null:
		_log("_replace_interactor_interact: no gameData or no target")
		return

	var target_groups: String = str(interactor.target.get_groups())
	var owner_class: String = str(interactor.target.owner) if interactor.target.owner else "null"
	_log("INTERACT target_groups=%s owner=%s decor=%s" % [target_groups, owner_class, str(gd.decor)])

	if not gd.decor and interactor.target.is_in_group("Interactable"):
		if interactor.target.owner and interactor.target.owner.get("isDowned") == true:
			_start_revive(interactor.target.owner)
			CoopHook.skip_super()
			return
		if interactor.target.owner and interactor.target.owner.get("canSleep") != null:
			_log("  → bed interact")
			_coop_bed_interact(interactor.target.owner)
			CoopHook.skip_super()
			return
		_log("  → general Interactable, calling owner.Interact() (has_method=%s)" % str(interactor.target.owner.has_method("Interact") if interactor.target.owner else false))
		if interactor.target.owner and interactor.target.owner.has_method("Interact"):
			interactor.target.owner.Interact()
		CoopHook.skip_super()
		return

	if not gd.decor and interactor.target.is_in_group("Transition"):
		if downed and downed.is_any_peer_downed():
			Loader.Message("Cannot leave while a player is downed", Color.ORANGE)
			CoopHook.skip_super()
			return
		if CoopAuthority.is_client():
			CoopHook.skip_super()
			return

	if not gd.decor and interactor.target.is_in_group("Item"):
		if players and players._is_trader_display_item(interactor.target):
			CoopHook.skip_super()
			return
		gd.interaction = true
		if interactor.target.has_meta("network_uuid"):
			var uuid: int = int(interactor.target.get_meta("network_uuid"))
			if players and players.has_method("RequestPickup"):
				players.RequestPickup(uuid)
			CoopHook.skip_super()
			return

	if gd.decor and interactor.target.is_in_group("Furniture"):
		var coop_fid: int = -1
		var root: Node = interactor.target.owner
		if root and root.has_meta("coop_furniture_id"):
			coop_fid = int(root.get_meta("coop_furniture_id"))
			if furniture and furniture.IsFurnitureLocked(coop_fid):
				var locker_id: int = furniture.GetFurnitureLockOwner(coop_fid)
				var locker_name: String = players.GetPlayerName(locker_id) if players else str(locker_id)
				Loader.Message("In use by " + locker_name, Color.ORANGE)
				CoopHook.skip_super()
				return
		for child in interactor.target.owner.get_children():
			if child is Furniture:
				child.Catalog()
		if coop_fid >= 0 and furniture:
			if CoopAuthority.is_host():
				furniture.BroadcastFurnitureRemove.rpc(coop_fid)
			else:
				furniture.SubmitFurnitureRemove.rpc_id(1, coop_fid)
		CoopHook.skip_super()


func _post_interactor_interact() -> void:
	pass


func _coop_bed_interact(bed: Node) -> void:
	if not bed.canSleep or event == null:
		return
	if CoopAuthority.is_host():
		event.HostToggleSleepReady(multiplayer.get_unique_id(), bed.randomSleep)
	else:
		event.RequestSleepReady.rpc_id(1, bed.randomSleep)


func _coop_container_tooltip(lc: Node, gd: Resource) -> void:
	if container == null:
		return
	var cid: int = container._node_id(lc)
	if not container._container_holders.has(cid):
		return
	var holder_id: int = int(container._container_holders[cid])
	if holder_id == multiplayer.get_unique_id():
		return
	var holder_name: String = players.GetPlayerName(holder_id) if players else str(holder_id)
	gd.tooltip = lc.containerName + " [In use by " + holder_name + "]"


func _coop_bed_tooltip(bed: Node, gd: Resource) -> void:
	if not bed.canSleep:
		gd.tooltip = ""
		return
	var my_id: int = multiplayer.get_unique_id()
	if event and event._sleep_ready.has(my_id):
		gd.tooltip = "Sleep [Cancel]"
	else:
		gd.tooltip = "Sleep (Random: 6-12h) [Ready]"


func _start_revive(puppet: Node) -> void:
	if _reviving or downed == null:
		return
	_reviving = true
	var puppet_peer_id: int = puppet.peer_id
	var player_name: String = players.GetPlayerName(puppet_peer_id) if players else str(puppet_peer_id)
	_log("revive: STARTED for peer=%d name=%s" % [puppet_peer_id, player_name])

	var elapsed: float = 0.0
	while elapsed < REVIVE_DURATION:
		if not is_instance_valid(puppet) or not puppet.isDowned:
			Loader.Message("Revive cancelled", Color.RED)
			_log("revive: cancelled (puppet invalid or no longer downed)")
			_reviving = false
			return
		var controller = players.GetLocalController() if players else null
		if controller and controller.global_position.distance_to(puppet.global_position) > REVIVE_MAX_RANGE:
			Loader.Message("Too far — revive cancelled", Color.RED)
			_log("revive: cancelled (too far)")
			_reviving = false
			return
		var pct: int = int((elapsed / REVIVE_DURATION) * 100.0)
		Loader.Message("Reviving %s... %d%%" % [player_name, pct], Color.YELLOW)
		await get_tree().create_timer(0.5).timeout
		elapsed += 0.5

	if not is_instance_valid(puppet) or not puppet.isDowned:
		Loader.Message("Revive cancelled", Color.RED)
		_reviving = false
		return

	downed.request_revive(puppet_peer_id)
	Loader.Message("Revived %s!" % player_name, Color.GREEN)
	_log("revive: COMPLETED for peer=%d" % puppet_peer_id)
	_reviving = false
