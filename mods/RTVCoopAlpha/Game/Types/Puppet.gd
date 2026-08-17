class_name Puppet extends CharacterBody3D



const RTVCoop = preload("res://mods/RTVCoopAlpha/Game/Coop.gd")

const LERP_SPEED := 18.0


var peer_id: int = 0
var isDead: bool = false
var isDowned: bool = false

var targetPosition: Vector3 = Vector3.ZERO
var targetRotation: Vector3 = Vector3.ZERO
var hasTarget: bool = false


@onready var playerModel: Node = get_node_or_null("PlayerModel")


func _physics_process(delta: float) -> void:
	if hasTarget and not isDowned:
		global_position = global_position.lerp(targetPosition, LERP_SPEED * delta)
		global_rotation.y = lerp_angle(global_rotation.y, targetRotation.y, LERP_SPEED * delta)


func SetTarget(pos: Vector3, rot: Vector3) -> void:
	targetPosition = pos
	targetRotation = rot
	if not hasTarget:
		global_position = pos
		global_rotation = rot
		hasTarget = true


func ApplyAnimState(state: Dictionary) -> void:
	if isDead or isDowned:
		return
	if playerModel and playerModel.has_method("ApplyAnimState"):
		playerModel.ApplyAnimState(state)


func OnDowned() -> void:
	isDowned = true
	_set_hitbox_interactable(true)
	if playerModel and playerModel.has_method("OnPuppetDeath"):
		playerModel.OnPuppetDeath()


func OnRevived() -> void:
	isDowned = false
	_set_hitbox_interactable(false)
	if playerModel and playerModel.has_method("OnPuppetRespawn"):
		playerModel.OnPuppetRespawn()


func OnDeath() -> void:
	isDead = true
	isDowned = false
	_set_hitbox_interactable(false)
	if playerModel and playerModel.has_method("OnPuppetDeath"):
		playerModel.OnPuppetDeath()


func OnRespawn() -> void:
	isDead = false
	if playerModel and playerModel.has_method("OnPuppetRespawn"):
		playerModel.OnPuppetRespawn()


func Interact() -> void:
	pass


func UpdateTooltip() -> void:
	if not isDowned:
		return
	var gd = preload("res://Resources/GameData.tres")
	var player_name: String = "Player %d" % peer_id
	var coop := RTVCoop.get_instance()
	if coop and coop.players and coop.players.has_method("GetPlayerName"):
		player_name = coop.players.GetPlayerName(peer_id)
	gd.tooltip = "Revive " + player_name


func _set_hitbox_interactable(enabled: bool) -> void:
	var hitbox: Node = get_node_or_null("Hitbox")
	if hitbox == null:
		return
	if enabled:
		if not hitbox.is_in_group("Interactable"):
			hitbox.add_to_group("Interactable")
		hitbox.collision_layer = 128
		hitbox.position = Vector3(0, 0.3, 0)
		var shape: CollisionShape3D = hitbox.get_node_or_null("CollisionShape3D")
		if shape and shape.shape is CapsuleShape3D:
			shape.shape = shape.shape.duplicate()
			shape.shape.height = 0.6
			shape.shape.radius = 0.5
	else:
		if hitbox.is_in_group("Interactable"):
			hitbox.remove_from_group("Interactable")
		hitbox.collision_layer = 64
		hitbox.position = Vector3(0, 0.9, 0)
		var shape: CollisionShape3D = hitbox.get_node_or_null("CollisionShape3D")
		if shape and shape.shape is CapsuleShape3D:
			shape.shape = shape.shape.duplicate()
			shape.shape.height = 1.8
			shape.shape.radius = 0.4


func WeaponDamage(_type: String, finalDamage: float) -> void:
	var coop := RTVCoop.get_instance()
	if coop == null:
		return
	var iac: Node = coop.get_sync("interactable")
	if iac and iac.has_method("RequestPlayerDamage"):
		iac.RequestPlayerDamage(peer_id, int(finalDamage), 0)
