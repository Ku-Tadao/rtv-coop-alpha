extends "res://mods/RTVCoopAlpha/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoopAlpha/Framework/CoopAuthority.gd")

func _log(msg: String) -> void:
	var l = Engine.get_meta("CoopLogger", null)
	if l: l.log_msg("LootHooks", msg)

func _setup_hooks() -> void:
	CoopHook.register(self, "lootcontainer-_ready-pre", _on_loot_container_ready_pre)
	CoopHook.register_replace_or_post(self, "lootcontainer-_ready", _replace_loot_container_ready, _post_loot_container_ready)
	CoopHook.register_replace_or_post(self, "lootcontainer-interact", _replace_loot_container_interact, _post_loot_container_interact)
	CoopHook.register_replace_or_post(self, "lootsimulation-_ready", _replace_loot_simulation_ready, _post_loot_simulation_ready)
	CoopHook.register_replace_or_post(self, "pickup-interact", _replace_pickup_interact, _post_pickup_interact)
	CoopHook.register_replace_or_post(self, "uimanager-opencontainer", _replace_uimanager_open, _post_uimanager_open)


func _on_loot_container_ready_pre() -> void:
	var lc := CoopHook.caller()
	if lc == null:
		return
	lc.add_to_group("CoopLootContainer")
	if not CoopAuthority.is_active() or players == null:
		return
	var s: int = players.CoopSeedForNode(lc)
	if s != 0:
		seed(s)
		lc.set_meta("_coop_lc_seeded", true)


func _replace_loot_container_ready() -> void:
	var lc := CoopHook.caller()
	if lc == null or not CoopAuthority.is_active():
		return

	if CoopAuthority.is_client():
		lc.ClearBuckets()
		lc.loot.clear()
		lc.storage.clear()
		lc.storaged = false
		CoopHook.skip_super()
		return

	var loot_mult: float = 1.0
	if settings:
		loot_mult = settings.Get("loot_multiplier", 1.0)

	if lc.custom.is_empty() and not lc.locked and not lc.furniture:
		lc.ClearBuckets()
		lc.FillBuckets()
		_generate_loot_scaled(lc, loot_mult)

	if not lc.custom.is_empty() and not lc.force:
		lc.table = lc.custom.pick_random()
		lc.ClearBuckets()
		lc.FillBucketsCustom()
		_generate_loot_scaled(lc, loot_mult)

	if not lc.custom.is_empty() and lc.force:
		lc.table = lc.custom.pick_random()
		for index in lc.table.items.size():
			lc.CreateLoot(lc.table.items[index])

	if lc.stash:
		if randi_range(0, 100) > 10:
			lc.process_mode = Node.PROCESS_MODE_DISABLED
			lc.hide()

	CoopHook.skip_super()


func _post_loot_container_ready() -> void:
	var lc := CoopHook.caller()
	if lc != null and lc.has_meta("_coop_lc_seeded"):
		randomize()
		lc.remove_meta("_coop_lc_seeded")


func _generate_loot_scaled(lc: Node, mult: float) -> void:
	var full_passes: int = int(mult)
	var frac: float = mult - float(full_passes)
	for _i in full_passes:
		lc.GenerateLoot()
	if frac > 0.0 and randf() < frac:
		lc.GenerateLoot()


func _replace_loot_container_interact() -> void:
	var lc := CoopHook.caller()
	_log("_replace_loot_container_interact FIRED lc=%s" % str(lc))
	if lc == null:
		return
	if lc.locked:
		_log("  → locked, skip")
		CoopHook.skip_super()
		return
	if not CoopAuthority.is_active():
		_log("  → not active, fallthrough to vanilla")
		return
	_log("  → calling TryOpenContainer (players=%s, has_method=%s)" % [str(players != null), str(players.has_method("TryOpenContainer") if players else false)])
	if players and players.has_method("TryOpenContainer"):
		players.TryOpenContainer(lc)
		CoopHook.skip_super()


func _post_loot_container_interact() -> void:
	pass


func _replace_loot_simulation_ready() -> void:
	var ls := CoopHook.caller()
	if ls == null or not CoopAuthority.is_active() or CoopAuthority.is_host():
		return
	if ls.get_child_count() > 0:
		ls.get_child(0).queue_free()
	CoopHook.skip_super()


func _post_loot_simulation_ready() -> void:
	pass


func _replace_pickup_interact() -> void:
	var pu := CoopHook.caller()
	if pu == null or not CoopAuthority.is_active():
		return
	var uuid: int = int(pu.get_meta("network_uuid", -1))
	if uuid < 0:
		if pu.get("interface") and pu.interface.has_method("PlayError"):
			pu.interface.PlayError()
		CoopHook.skip_super()
		return
	if players and players.has_method("RequestPickup"):
		players.RequestPickup(uuid)
	CoopHook.skip_super()


func _post_pickup_interact() -> void:
	pass


func _replace_uimanager_open(_c) -> void:
	if not CoopAuthority.is_active() or players == null:
		return
	if players.container_open_bypassed:
		return
	if container:
		container.TryOpenContainer(_c)
		CoopHook.skip_super()


func _post_uimanager_open(_c) -> void:
	pass
