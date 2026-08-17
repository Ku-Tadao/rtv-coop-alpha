extends "res://Scripts/Explosion.gd"


const CoopAuthority = preload("res://mods/RTVCoopAlpha/Framework/CoopAuthority.gd")


func CheckOverlap() -> void:
	if CoopAuthority.is_active() and not CoopAuthority.is_host():
		return
	super()


func CheckLOS(target) -> void:
	var head_pos: Vector3 = target.global_position + Vector3(0, 1.5, 0)
	if target.get("head") and target.head:
		head_pos = target.head.global_position

	LOS.look_at(head_pos, Vector3.UP, true)
	LOS.force_raycast_update()

	if LOS.is_colliding():
		if LOS.get_collider().is_in_group("AI"):
			target.ExplosionDamage(LOS.global_basis.z)
		if LOS.get_collider().is_in_group("Player"):
			target.get_child(0).ExplosionDamage()


func CheckAlert() -> void:
	if CoopAuthority.is_active() and not CoopAuthority.is_host():
		return
	super()
