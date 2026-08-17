extends "res://mods/RTVCoopAlpha/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoopAlpha/Framework/CoopAuthority.gd")

var _drain_prev: Dictionary = {}
var _downed_char_node: Node = null


func _setup_hooks() -> void:
	CoopHook.register(self, "character-_physics_process-pre", _on_character_physics_pre)
	CoopHook.register(self, "character-_physics_process-post", _on_character_physics_post)
	CoopHook.register_replace_or_post(self, "character-death", _replace_character_death, _post_character_death)
	if downed:
		downed.local_revived.connect(_on_local_revived)
		downed.local_bled_out.connect(_on_local_bled_out)
		downed.local_downed.connect(_on_local_downed)


func _on_character_physics_pre(_delta: float = 0.0) -> void:
	if not CoopAuthority.is_active() or settings == null:
		return
	var mult: float = settings.Get("stats_drain_multiplier", 1.0)
	if mult == 1.0:
		return
	var gd: Resource = _game_data()
	if gd == null:
		return
	_drain_prev = {
		"energy": gd.energy,
		"hydration": gd.hydration,
		"mental": gd.mental,
	}


func _on_character_physics_post(_delta: float = 0.0) -> void:
	if _drain_prev.is_empty() or not CoopAuthority.is_active() or settings == null:
		_drain_prev.clear()
		return
	var mult: float = settings.Get("stats_drain_multiplier", 1.0)
	var gd: Resource = _game_data()
	if gd == null:
		_drain_prev.clear()
		return
	for key in ["energy", "hydration", "mental"]:
		var before: float = _drain_prev[key]
		var after: float = gd.get(key)
		var drain: float = before - after
		if drain > 0:
			gd.set(key, before - drain * mult)
	_drain_prev.clear()


func _game_data() -> Resource:
	var caller := CoopHook.caller()
	if caller and "gameData" in caller:
		return caller.gameData
	return load("res://Resources/GameData.tres")


func _replace_character_death() -> void:
	if not CoopAuthority.is_active():
		return
	var char_node := CoopHook.caller()
	if char_node == null:
		return
	CoopHook.skip_super()
	_coop_enter_downed(char_node)


func _post_character_death() -> void:
	pass


func _coop_enter_downed(char_node: Node) -> void:
	if players == null:
		return
	var gd: Resource = _game_data()
	if gd == null:
		return

	_downed_char_node = char_node

	if char_node.has_method("PlayDeathAudio"):
		char_node.PlayDeathAudio()
	if char_node.get("audio"):
		if char_node.audio.get("breathing"):
			char_node.audio.breathing.stop()
		if char_node.audio.get("heartbeat"):
			char_node.audio.heartbeat.stop()

	gd.health = 0
	gd.isDead = true
	gd.freeze = true

	if downed:
		downed.enter_downed(multiplayer.get_unique_id())


func _on_local_downed() -> void:
	var gd: Resource = _game_data()
	if gd == null:
		return
	if gd.permadeath:
		Loader.Message("YOU ARE DOWNED — Wait for a teammate!", Color.RED)
	else:
		_show_bleedout_countdown()


func _on_local_revived() -> void:
	var gd: Resource = _game_data()
	if gd == null:
		return

	gd.health = 25.0
	gd.isDead = false
	gd.freeze = false
	gd.damage = false
	gd.impact = false
	gd.bleeding = false
	gd.fracture = false
	gd.burn = false
	gd.rupture = false
	gd.headshot = false
	gd.poisoning = false

	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	Loader.FadeOut()
	Loader.Message("You have been revived!", Color.GREEN)
	players.NotifyPlayerRespawn(multiplayer.get_unique_id())
	_downed_char_node = null


func _on_local_bled_out() -> void:
	if _downed_char_node and is_instance_valid(_downed_char_node):
		_coop_respawn(_downed_char_node)
	_downed_char_node = null


func _show_bleedout_countdown() -> void:
	var remaining: float = downed.BLEEDOUT_TIMER if downed else 30.0
	while remaining > 0 and _downed_char_node != null:
		Loader.Message("DOWNED — Bleeding out in %.0fs" % remaining, Color.RED)
		await get_tree().create_timer(1.0).timeout
		remaining -= 1.0


func _coop_respawn(char_node: Node) -> void:
	if players == null:
		return
	var gd: Resource = _game_data()
	if gd == null:
		return

	players.NotifyPlayerDeath(multiplayer.get_unique_id())

	var death_pos: Vector3 = char_node.get_parent().global_position
	if not gd.isDead and char_node.has_method("PlayDeathAudio"):
		char_node.PlayDeathAudio()
	if not gd.isDead and char_node.get("audio"):
		if char_node.audio.get("breathing"):
			char_node.audio.breathing.stop()
		if char_node.audio.get("heartbeat"):
			char_node.audio.heartbeat.stop()
	gd.health = 0
	gd.isDead = true
	gd.freeze = true

	var iface: Node = players.GetLocalInterface()
	var death_items: Array = []
	if iface and slot:
		for item in iface.inventoryGrid.get_children():
			death_items.append(slot.SerializeSlotData(item.slotData))
		for item in iface.inventoryGrid.get_children():
			iface.inventoryGrid.Pick(item)
			item.queue_free()
		for equipment_slot in iface.equipment.get_children():
			if equipment_slot is Slot and equipment_slot.get_child_count() != 0:
				var slot_item = equipment_slot.get_child(0)
				death_items.append(slot.SerializeSlotData(slot_item.slotData))
				slot_item.queue_free()
				equipment_slot.hint.show()
		for item in iface.catalogGrid.get_children():
			death_items.append(slot.SerializeSlotData(item.slotData))
		for item in iface.catalogGrid.get_children():
			iface.catalogGrid.Pick(item)
			item.queue_free()
		iface.UpdateStats(false)
		if iface.activeProgress and is_instance_valid(iface.activeProgress):
			iface.activeProgress.queue_free()
		iface.activeProgress = null
		iface.isCrafting = false

	if char_node.get("rigManager") and char_node.rigManager.has_method("ClearRig"):
		char_node.rigManager.ClearRig()

	if death_items.size() > 0 and pickup:
		if CoopAuthority.is_host():
			var stash_cid: int = players.nextContainerId if players else 0
			if players:
				players.nextContainerId += 1
			pickup.SpawnDeathContainer.rpc(death_pos, death_items, stash_cid)
		else:
			pickup.SubmitDeathContainer.rpc_id(1, death_pos, death_items)

	Loader.FadeIn()
	await get_tree().create_timer(5.0).timeout

	var controller: Node = char_node.get_parent()
	var respawn_pos: Vector3 = controller.global_position + Vector3(0, 1, 0)

	var best_transition: Node = null
	var best_dist: float = INF
	for transition in get_tree().get_nodes_in_group("Transition"):
		if transition.owner == null or not transition.owner.get("spawn"):
			continue
		var d: float = controller.global_position.distance_squared_to(transition.owner.global_position)
		if d < best_dist:
			best_dist = d
			best_transition = transition.owner
	if best_transition and best_transition.spawn:
		respawn_pos = best_transition.spawn.global_position + Vector3(0, 0.5, 0)

	controller.global_position = respawn_pos
	if "velocity" in controller:
		controller.velocity = Vector3.ZERO

	gd.health = 100
	gd.bodyStamina = 100
	gd.armStamina = 100
	gd.oxygen = 100
	gd.energy = clampf(gd.energy, 25.0, 100.0)
	gd.hydration = clampf(gd.hydration, 25.0, 100.0)
	gd.mental = clampf(gd.mental, 25.0, 100.0)
	gd.temperature = clampf(gd.temperature, 25.0, 100.0)
	gd.bleeding = false
	gd.fracture = false
	gd.burn = false
	gd.frostbite = false
	gd.insanity = false
	gd.rupture = false
	gd.headshot = false
	gd.starvation = false
	gd.dehydration = false
	gd.overweight = false
	gd.poisoning = false
	gd.isDead = false
	gd.freeze = false
	gd.damage = false
	gd.impact = false
	gd.isOccupied = false
	gd.isPlacing = false
	gd.isInserting = false
	gd.isInspecting = false
	gd.isReloading = false
	gd.isChecking = false
	gd.isClearing = false
	gd.isDrawing = false
	gd.isFiring = false
	gd.isAiming = false
	gd.isScoped = false
	gd.isTransitioning = false
	gd.isCaching = false
	gd.isSleeping = false
	gd.isCrafting = false
	gd.jammed = false
	gd.interaction = false
	gd.transition = false

	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	Loader.FadeOut()
	players.NotifyPlayerRespawn(multiplayer.get_unique_id())
