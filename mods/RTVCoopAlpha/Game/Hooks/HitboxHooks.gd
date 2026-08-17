extends "res://mods/RTVCoopAlpha/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoopAlpha/Framework/CoopAuthority.gd")

func _setup_hooks() -> void:
	CoopHook.register_replace_or_post(self, "hitbox-applydamage", _replace_hitbox_apply_damage, _post_hitbox_apply_damage)


func _replace_hitbox_apply_damage(damage: float) -> void:
	var hitbox := CoopHook.caller()
	if hitbox == null:
		return
	if not CoopAuthority.is_active() or CoopAuthority.is_host():
		return
	var owner_node: Node = hitbox.owner
	if owner_node == null or not owner_node.has_meta("network_uuid"):
		return

	var final_damage: float = 0.0
	match hitbox.type:
		"Head": final_damage = 100.0
		"Torso": final_damage = damage
		"Leg_L", "Leg_R": final_damage = damage / 2.0
		_: final_damage = damage

	if ai:
		ai.RequestAIDamage.rpc_id(1, int(owner_node.get_meta("network_uuid")), hitbox.type, final_damage)
		CoopHook.skip_super()


func _post_hitbox_apply_damage(_damage: float) -> void:
	pass
