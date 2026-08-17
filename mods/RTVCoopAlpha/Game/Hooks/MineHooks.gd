extends "res://mods/RTVCoopAlpha/HookKit/BaseHook.gd"


const CoopAuthority = preload("res://mods/RTVCoopAlpha/Framework/CoopAuthority.gd")

func _log(msg: String) -> void:
    var l = Engine.get_meta("CoopLogger", null)
    if l: l.log_msg("MineHooks", msg)

func _setup_hooks() -> void:
    CoopHook.register(self, "mine-detonate-pre", _on_mine_ready_pre)
    CoopHook.register_replace_or_post(self, "mine-detonate", _replace_mine_detonate, _post_mine_detonate)
    CoopHook.register_replace_or_post(self, "mine-instantdetonate", _replace_mine_instant_detonate, _post_mine_instant_detonate)


func _on_mine_ready_pre() -> void:
    var mine := CoopHook.caller()
    if mine:
        mine.add_to_group("CoopMine")


func _mine_id(mine: Node) -> int:
    if players and players.has_method("CoopPosHash"):
        return players.CoopPosHash(mine.global_position)
    return abs(hash(str(mine.global_position)))


func _replace_mine_detonate() -> void:
    var mine := CoopHook.caller()
    if mine == null or not CoopAuthority.is_active():
        return
    if mine.isDetonated:
        CoopHook.skip_super()
        return
    if mine.get_meta("_coop_detonate_suppressed", false):
        return
    var mid: int = _mine_id(mine)
    _log("Detonate mine_id=%d pos=%s is_host=%s" % [mid, str(mine.global_position), str(CoopAuthority.is_host())])
    if CoopAuthority.is_host():
        interactable.BroadcastMineDetonate.rpc(mid)
    else:
        interactable.SubmitMineDetonate.rpc_id(1, mid)


func _post_mine_detonate() -> void:
    pass


func _replace_mine_instant_detonate() -> void:
    var mine := CoopHook.caller()
    if mine == null or not CoopAuthority.is_active():
        return
    if mine.isDetonated or mine.is_queued_for_deletion():
        CoopHook.skip_super()
        return
    if mine.get_meta("_coop_detonate_suppressed", false):
        return
    var mid: int = _mine_id(mine)
    _log("InstantDetonate mine_id=%d pos=%s is_host=%s" % [mid, str(mine.global_position), str(CoopAuthority.is_host())])
    if CoopAuthority.is_host():
        interactable.BroadcastMineInstantDetonate.rpc(mid)
    else:
        interactable.SubmitMineInstantDetonate.rpc_id(1, mid)


func _post_mine_instant_detonate() -> void:
    pass
