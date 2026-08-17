extends "res://mods/RTVCoopAlpha/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoopAlpha/Framework/CoopAuthority.gd")

func _log(msg: String) -> void:
	var l = Engine.get_meta("CoopLogger", null)
	if l: l.log_msg("InteractHooks", msg)

func _setup_hooks() -> void:
	CoopHook.register(self, "door-_ready-pre", _on_door_ready_pre)
	CoopHook.register(self, "door-_ready-post", _on_door_ready_post)
	CoopHook.register_replace_or_post(self, "door-interact", _replace_door_interact, _post_door_interact)
	CoopHook.register_replace_or_post(self, "switch-interact", _replace_switch_interact, _post_switch_interact)


func _on_door_ready_pre() -> void:
	var door := CoopHook.caller()
	if door == null or not CoopAuthority.is_active() or players == null:
		return
	var s: int = players.CoopSeedForNode(door)
	if s != 0:
		seed(s)
		door.set_meta("_coop_door_seeded", true)


func _on_door_ready_post() -> void:
	var door := CoopHook.caller()
	if door != null and door.has_meta("_coop_door_seeded"):
		randomize()
		door.remove_meta("_coop_door_seeded")


func _replace_door_interact() -> void:
	var door := CoopHook.caller()
	_log("_replace_door_interact FIRED door=%s interactable=%s active=%s" % [str(door), str(interactable != null), str(CoopAuthority.is_active())])
	if door == null:
		return
	if interactable == null or not CoopAuthority.is_active():
		_log("  → early return (interactable null or not active)")
		return

	if CoopAuthority.is_client():
		if door.key and door.locked:
			door.CheckKey()
			if door.locked:
				CoopHook.skip_super()
				return
			interactable.RequestDoorUnlock.rpc_id(1, door.get_path())
			CoopHook.skip_super()
			return
		interactable.RequestDoorToggle.rpc_id(1, door.get_path())
		CoopHook.skip_super()
		return

	if door.key and door.locked:
		door.CheckKey()
		if not door.locked:
			if door.get("linked") and door.linked:
				door.linked.locked = false
			if door.has_method("PlayUnlock"):
				door.PlayUnlock()
			interactable.BroadcastDoorUnlock.rpc(door.get_path())
		CoopHook.skip_super()
		return

	door.isOccupied = false
	door.occupiedTimer = 0.0
	var new_open: bool = not door.isOpen
	if door.has_method("ApplyDoorState"):
		door.ApplyDoorState(new_open)
	else:
		_apply_door_inline(door, new_open)
	interactable.BroadcastDoorState.rpc(door.get_path(), new_open)
	CoopHook.skip_super()


func _apply_door_inline(door: Node, new_open: bool) -> void:
	door.isOpen = new_open
	door.animationTime = 4.0
	door.handleMoving = true
	if door.openAngle.y > 0.0:
		door.handleTarget = Vector3(0, 0, -45)
	else:
		door.handleTarget = Vector3(0, 0, 45)
	if door.has_method("PlayDoor"):
		door.PlayDoor()
	door.isOccupied = true
	door.occupiedTimer = 0.0


func _post_door_interact() -> void:
	if CoopAuthority.is_active():
		push_warning("[InteractHooks] door-interact replace unavailable; vanilla ran uncoordinated")


func _replace_switch_interact() -> void:
	var sw := CoopHook.caller()
	_log("_replace_switch_interact FIRED sw=%s interactable=%s active=%s" % [str(sw), str(interactable != null), str(CoopAuthority.is_active())])
	if sw == null or interactable == null or not CoopAuthority.is_active():
		_log("  → early return")
		return

	if CoopAuthority.is_client():
		interactable.RequestSwitchToggle.rpc_id(1, sw.get_path())
		CoopHook.skip_super()
		return

	var new_active: bool = not sw.active
	if sw.has_method("ApplySwitchState"):
		sw.ApplySwitchState(new_active)
	interactable.BroadcastSwitchState.rpc(sw.get_path(), new_active)
	CoopHook.skip_super()


func _post_switch_interact() -> void:
	if CoopAuthority.is_active():
		push_warning("[InteractHooks] switch-interact replace unavailable; vanilla ran uncoordinated")
