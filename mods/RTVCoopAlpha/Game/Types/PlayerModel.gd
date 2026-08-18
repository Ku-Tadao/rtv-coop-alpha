extends Node3D


var audioInstance3D = preload("res://Resources/AudioInstance3D.tscn")
var flashVFX = preload("res://Effects/Muzzle_Flash.tscn")
const AI_GUARD_SCENE = preload("res://AI/Guard/AI_Guard.tscn")


var aiInstance: Node = null


var currentWeaponFile: String = ""
var currentAnim: String = ""
var currentWeaponNode: Node = null
var animPlayer: AnimationPlayer = null


const PUPPET_TRANSFORM = Transform3D(
    Vector3(-1, 0, 0),
    Vector3(0, 1, 0),
    Vector3(0, 0, -1),
    Vector3.ZERO
)

const RIFLE_GRIP = Transform3D(
    Vector3(-0.168531, 0.17101, 0.97075),
    Vector3(0.983905, -0.0301536, 0.176127),
    Vector3(0.0593909, 0.984808, -0.163175),
    Vector3(0.1, 0.12, 0.03)
)
const PISTOL_GRIP = Transform3D(
    Vector3(0.174912, 0.0847189, 0.980934),
    Vector3(0.982636, 0.047607, -0.179328),
    Vector3(-0.0618917, 0.995267, -0.07492),
    Vector3(0.073, 0.108, 0.01)
)


func _ready():

    aiInstance = AI_GUARD_SCENE.instantiate()
    aiInstance.name = "AI"
    aiInstance.set_meta("coop_puppet_mode", true)
    aiInstance.transform = PUPPET_TRANSFORM
    add_child(aiInstance)

    if aiInstance.is_in_group("AI"):
        aiInstance.remove_from_group("AI")

    _isolate_puppet_resources(aiInstance)
    _coop_strip_puppet_pickups(aiInstance)
    var gizmo = aiInstance.get_node_or_null("Gizmo")
    if gizmo:
        gizmo.hide()
    if aiInstance.container:
        var container_collider = aiInstance.container.get_node_or_null("StaticBody3D")
        if container_collider == null:
            for child in aiInstance.container.get_children():
                if child is StaticBody3D:
                    container_collider = child
                    break
        if container_collider:
            container_collider.collision_layer = 0
            container_collider.collision_mask = 0
            if container_collider.is_in_group("Interactable"):
                container_collider.remove_from_group("Interactable")

    aiInstance.show()
    aiInstance.pause = true
    aiInstance.collision_layer = 0
    aiInstance.collision_mask = 0
    aiInstance.process_mode = Node.PROCESS_MODE_INHERIT

    if aiInstance.skeleton:
        aiInstance.skeleton.process_mode = Node.PROCESS_MODE_INHERIT
        aiInstance.skeleton.show_rest_only = false
        aiInstance.skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE

    if aiInstance.animator:
        aiInstance.animator.active = false

    animPlayer = aiInstance.get_node_or_null("Guard/Animations")

    if animPlayer:
        animPlayer.play("Rifle_Idle", 0.3)

    call_deferred("CaptureInitialWeaponFile")
    call_deferred("_coop_probe_rig")


# Logged once per puppet so we know what the rig actually offers before promising
# animations. The mod plays named clips off an AnimationPlayer and disables the
# AnimationTree, but the AI code drives blend spaces like
# "parameters/Rifle/Combat/blend_position" with a strafe value -- so directional
# locomotion may already exist and simply not be reachable the way we drive it.
func _coop_probe_rig() -> void:
    await get_tree().process_frame
    if aiInstance == null:
        return
    var player := aiInstance.get_node_or_null("Guard/Animations")
    if player and player is AnimationPlayer:
        var clips: PackedStringArray = player.get_animation_list()
        _coop_log("rig clips (%d): %s" % [clips.size(), ", ".join(clips)])
    else:
        _coop_log("rig clips: no AnimationPlayer at Guard/Animations")

    if aiInstance.animator:
        var params: Array = []
        for prop in aiInstance.animator.get_property_list():
            var n: String = str(prop.get("name", ""))
            if n.begins_with("parameters/"):
                params.append(n)
        _coop_log("rig tree params (%d): %s" % [params.size(), ", ".join(params)])
    else:
        _coop_log("rig tree: no AnimationTree")


func CaptureInitialWeaponFile():
    await get_tree().physics_frame
    await get_tree().physics_frame
    if aiInstance && aiInstance.weapon && aiInstance.weapon.slotData && aiInstance.weapon.slotData.itemData:
        currentWeaponFile = aiInstance.weapon.slotData.itemData.file
        currentWeaponNode = aiInstance.weapon


func _isolate_puppet_resources(ai: Node) -> void:
    if ai.mesh:
        if ai.mesh.mesh:
            ai.mesh.mesh = ai.mesh.mesh.duplicate(true)
        if ai.mesh.skin:
            ai.mesh.skin = ai.mesh.skin.duplicate(true)
        for i in ai.mesh.get_surface_override_material_count():
            var mat = ai.mesh.get_active_material(i)
            if mat:
                ai.mesh.set_surface_override_material(i, mat.duplicate(true))
    if ai.animator and ai.animator.tree_root:
        ai.animator.tree_root = ai.animator.tree_root.duplicate(true)


func _coop_strip_puppet_pickups(node: Node) -> void:
    if node is Pickup:
        if node.is_in_group("Item"):
            node.remove_from_group("Item")
        if node is CollisionObject3D:
            node.collision_layer = 0
            node.collision_mask = 0
        if node.has_method("Freeze"):
            node.Freeze()
    for child in node.get_children():
        _coop_strip_puppet_pickups(child)


func _pick_animation(state: Dictionary) -> String:
    var weaponType: String = state.get("weapon", "rifle")
    var prefix = "Pistol" if weaponType == "pistol" else "Rifle"
    var condition: String = state.get("animCondition", "Group")
    var blend: float = state.get("animBlend", 1.0)

    # The rig ships no unarmed locomotion at all -- Trader is the only clip with
    # empty hands, and it is a standing pose. Anything other than standing still
    # will show a carry pose no matter what we pick.
    if not state.get("hasWeapon", true):
        return "Trader"

    match condition:
        "Group":
            # A lowered weapon is the Guard pose. Without this, a lowered weapon
            # still renders on an aiming clip and the spine override drives it
            # into the body when the player looks down.
            if int(state.get("weaponPosition", 1)) == 1:
                return prefix + "_Guard"
            return prefix + "_Idle"
        "Guard":
            return prefix + "_Guard"
        "MovementLow":
            return prefix + "_Walk_F"
        "Movement":
            if blend >= 4.0:
                return prefix + "_Sprint_F"
            elif blend >= 2.0:
                return prefix + "_Aim_Run_F"
            else:
                return prefix + "_Aim_Walk_F"
        "Defend":
            return prefix + "_Aim_Idle"
        "Combat":
            return prefix + "_Aim_Walk_F"
        "Hunt":
            if blend >= 0.5:
                return prefix + "_Aim_Crouch_F"
            # Squat was tried here for a lowered weapon and is a resting squat,
            # not a tactical crouch. Aim_Crouch_Idle reads better even though it
            # raises the weapon.
            return prefix + "_Aim_Crouch_Idle"

    return prefix + "_Idle"


func ApplyAnimState(state: Dictionary):

    if !aiInstance:
        return

    if !animPlayer:
        animPlayer = aiInstance.get_node_or_null("Guard/Animations")
        if !animPlayer:
            return

    if !aiInstance.visible:
        aiInstance.show()
    if aiInstance.pause:
        aiInstance.pause = false
    if aiInstance.skeleton && aiInstance.skeleton.show_rest_only:
        aiInstance.skeleton.show_rest_only = false

    var weaponType: String = state.get("weapon", "rifle")
    var hasWeapon: bool = state.get("hasWeapon", true)


    var targetAnim = _pick_animation(state)
    if targetAnim != currentAnim:
        animPlayer.play(targetAnim, 0.3)
        currentAnim = targetAnim


    var weaponFile: String = state.get("weaponFile", "")
    if weaponFile != currentWeaponFile:
        if SwapWeapon(weaponFile):
            currentWeaponFile = weaponFile

    if aiInstance.weapons:
        for child in aiInstance.weapons.get_children():
            child.visible = hasWeapon


    var is_firing: bool = state.get("isFiring", false)
    var shots: int = state.get("shots", 0)
    var suppressed: bool = state.get("suppressed", false)
    var fireMode: int = state.get("fireMode", 1)
    if not is_firing and _active_fire_audio and is_instance_valid(_active_fire_audio):
        _active_fire_audio.stop()
        _active_fire_audio.queue_free()
        _active_fire_audio = null
    for i in shots:
        PlayPuppetFireEffect(suppressed, fireMode)

    _apply_puppet_attachments(state.get("attachments", []))
    _apply_puppet_flashlight(state.get("flashlight", false))
    _apply_puppet_spine_pitch(state.get("pitch", 0.0))
    _apply_puppet_backpack(state.get("backpackFile", ""))
    _update_puppet_flashlight_transform()


func OnPuppetDeath():
    if !aiInstance:
        return
    if animPlayer:
        animPlayer.stop()
    if aiInstance.animator:
        aiInstance.animator.active = false
    if aiInstance.skeleton:
        if _spine_bone >= 0:
            aiInstance.skeleton.set_bone_global_pose_override(_spine_bone, Transform3D(), 0.0, false)
        aiInstance.skeleton.Activate(Vector3(0, 0, -1), 20)
        aiInstance.skeleton.simulationTime = 999.0


func OnPuppetRespawn():
    if !aiInstance:
        return

    if aiInstance.skeleton:
        aiInstance.skeleton.DeactivateBones()
        aiInstance.skeleton.isActive = false
        aiInstance.skeleton.simulationTimer = 0.0
        aiInstance.skeleton.show_rest_only = false
        aiInstance.skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE

    # Keep the AnimationTree disabled — puppets use direct AnimationPlayer. Fuck you, AnimationTree.
    if aiInstance.animator:
        aiInstance.animator.active = false

    if !animPlayer:
        animPlayer = aiInstance.get_node_or_null("Guard/Animations")
    if animPlayer:
        currentAnim = ""
        animPlayer.play("Rifle_Idle", 0.3)


func _coop_log(msg: String) -> void:
    var l = Engine.get_meta("CoopLogger", null)
    if l: l.log_msg("PlayerModel", msg)


var _shots_played: int = 0


func PlayPuppetFireEffect(suppressed: bool = false, fireMode: int = 1):
    if not is_instance_valid(currentWeaponNode):
        return
    var muzzleNode = currentWeaponNode.get_node_or_null("Muzzle")
    if !muzzleNode:
        return

    # This path never ran in 1.0.0 and is the leading crash suspect: it adds two
    # nodes to a muzzle that SwapWeapon never cleans, because SwapWeapon only
    # frees children of aiInstance.weapons -- a different node. If that is the
    # bug, muzzle_children climbs without bound. Sampled, not per shot, so the
    # log stays readable during sustained fire.
    _shots_played += 1
    if _shots_played % 25 == 0:
        _coop_log("fire shots=%d muzzle_children=%d weapon=%s on_ai_weapon=%s" % [
            _shots_played,
            muzzleNode.get_child_count(),
            currentWeaponFile,
            str(aiInstance != null and currentWeaponNode == aiInstance.weapon),
        ])
    if !suppressed:
        var flash = flashVFX.instantiate()
        muzzleNode.add_child(flash)
        flash.Emit(true, 0.05)
    if _active_fire_audio and is_instance_valid(_active_fire_audio):
        _active_fire_audio.stop()
        _active_fire_audio.queue_free()
        _active_fire_audio = null
    var audio = audioInstance3D.instantiate()
    muzzleNode.add_child(audio)
    if currentWeaponNode.slotData and currentWeaponNode.slotData.itemData:
        var weaponData = currentWeaponNode.slotData.itemData
        if suppressed and weaponData.get("fireSuppressed"):
            audio.PlayInstance(weaponData.fireSuppressed, 20, 200)
        elif fireMode == 2 and weaponData.get("fireAuto"):
            audio.PlayInstance(weaponData.fireAuto, 20, 200)
            _active_fire_audio = audio
        elif weaponData.get("fireSemi"):
            audio.PlayInstance(weaponData.fireSemi, 20, 200)


func SwapWeapon(file: String) -> bool:
    if !aiInstance || !aiInstance.weapons:
        return false

    var weapon = null
    if file != "":
        var scene = Database.get(file)
        if !scene:
            return false
        weapon = scene.instantiate()
        if weapon == null:
            return false

    if _active_fire_audio and is_instance_valid(_active_fire_audio):
        _active_fire_audio.stop()
        _active_fire_audio.queue_free()
        _active_fire_audio = null

    var freed: int = aiInstance.weapons.get_child_count()
    for child in aiInstance.weapons.get_children():
        child.queue_free()
    currentWeaponNode = null
    _coop_log("swap to='%s' freed=%d" % [file, freed])

    if weapon == null:
        return true
    aiInstance.weapons.add_child(weapon)
    currentWeaponNode = weapon

    if weapon.is_in_group("Item"):
        weapon.remove_from_group("Item")
    weapon.collision_layer = 0
    weapon.collision_mask = 0
    weapon.freeze = true

    if weapon.slotData && weapon.slotData.itemData && weapon.slotData.itemData.weaponType == "Pistol":
        weapon.transform = PISTOL_GRIP
    else:
        weapon.transform = RIFLE_GRIP
    weapon.show()

    if weapon.slotData && weapon.slotData.itemData:
        var weaponData = weapon.slotData.itemData
        if weaponData.weaponAction != "Manual" && weaponData.compatible.size() > 0:
            if weaponData.compatible[0].subtype == "Magazine":
                var attachments = weapon.get_node_or_null("Attachments")
                if attachments:
                    var magazine = attachments.get_node_or_null(weaponData.compatible[0].file)
                    if magazine:
                        magazine.show()
    return true


var _current_attachments: Array = []
var _current_flashlight: bool = false
var _spine_bone: int = -1
var _spine_pitch: float = 0.0
var _spine_target: float = 0.0


func _process(delta: float) -> void:
    if !aiInstance or !aiInstance.skeleton:
        return
    var skel: Skeleton3D = aiInstance.skeleton
    if animPlayer and animPlayer.is_playing():
        skel.advance(delta)
    var puppet = get_parent()
    if puppet and (puppet.get("isDead") or puppet.get("isDowned")):
        return
    if _spine_bone < 0:
        _spine_bone = aiInstance.spineData.bone if aiInstance.spineData else 12
    _spine_pitch = lerp(_spine_pitch, _spine_target, clampf(10.0 * delta, 0.0, 1.0))
    var bonePose: Transform3D = skel.get_bone_global_pose_no_override(_spine_bone)
    bonePose.basis = bonePose.basis.rotated(bonePose.basis.x, -_spine_pitch * spine_share)
    skel.set_bone_global_pose_override(_spine_bone, bonePose, 1.0, true)


func _apply_puppet_attachments(attachmentFiles: Array):
    if not is_instance_valid(currentWeaponNode) or attachmentFiles == _current_attachments:
        return
    _current_attachments = attachmentFiles.duplicate()

    var attachments = currentWeaponNode.get_node_or_null("Attachments")
    if !attachments:
        return

    for child in attachments.get_children():
        child.hide()

    for file in attachmentFiles:
        var node = attachments.get_node_or_null(str(file))
        if node:
            node.show()


var _current_backpack_file: String = ""
var _current_backpack_node: Node = null
var _active_fire_audio: Node = null

func _apply_puppet_backpack(file: String):
    if file == _current_backpack_file:
        return
    var l = Engine.get_meta("CoopLogger", null)
    if l and file != "":
        l.log_msg("PlayerModel", "backpack file='%s' backpacks_node=%s" % [file, str(aiInstance.backpacks != null) if aiInstance else "no_ai"])
    _current_backpack_file = file
    if _current_backpack_node and is_instance_valid(_current_backpack_node):
        _current_backpack_node.queue_free()
        _current_backpack_node = null
    if file == "" or !aiInstance or !aiInstance.backpacks:
        return
    var scene = Database.get(file)
    if !scene:
        if l: l.log_msg("PlayerModel", "  → Database.get('%s') returned null" % file)
        return
    var bp = scene.instantiate()
    aiInstance.backpacks.add_child(bp)
    bp.transform = Transform3D(
        Vector3(-1, 0, 0),
        Vector3(0, 0.97, 0.24),
        Vector3(0, 0.24, -0.97),
        Vector3(0, -0.05, -0.25)
    )
    _current_backpack_node = bp
    if bp.is_in_group("Item"):
        bp.remove_from_group("Item")
    if bp is CollisionObject3D:
        bp.collision_layer = 0
        bp.collision_mask = 0
    if bp.has_method("Freeze"):
        bp.Freeze()
    bp.show()
    var bp_mesh = bp.get_node_or_null("Mesh")
    if bp_mesh:
        bp_mesh.visibility_range_end = 400.0


# The spine bone is rotated by the sender's camera pitch, unclamped. Look far
# enough down and the torso over-rotates until the weapon swings out behind the
# character. Raised looks correct, so the limits are asymmetric.
#
# Sign convention was not verified against the rig -- if the wrong end clamps,
# swap these two numbers. _apply_puppet_spine_pitch logs the raw value when it
# saturates, so the real range is observable rather than guessed.
# Measured, not guessed: looking fully down reports raw pitch -0.965, and at
# -0.9 the weapon was still inside the torso. Down is the negative end.
# Tunable live: F6 lowers the limit, F7 raises it, F8 reports the current value
# and the deepest raw pitch seen. Shared across every puppet so one adjustment
# applies to all of them. Read the value out of the log and hard-code it here
# once it looks right -- this is a calibration knob, not a feature.
# Tuning showed the clamp is the wrong lever: min was opened to -1.60, past the
# deepest observed raw pitch of -1.571 (-pi/2, straight down). Clamping only
# trades "weapon inside the torso" for "weapon stuck at chest".
#
# The real problem is that one spine bone absorbs the whole look-pitch, so
# looking down folds the character at the waist and the arms follow. The share
# below controls how much of it the spine takes; the rest should eventually go
# to the neck/head. F6 lowers the share, F7 raises it, F8 reports.
static var spine_pitch_min: float = -1.60
const SPINE_PITCH_MAX := 1.2
static var spine_share: float = 0.7
const SPINE_TUNE_STEP := 0.05

static var _deepest_raw: float = 0.0

var _pitch_clamp_logged: bool = false


func _apply_puppet_spine_pitch(pitch: float):
    _deepest_raw = minf(_deepest_raw, pitch)
    _spine_target = clampf(pitch, spine_pitch_min, SPINE_PITCH_MAX)


func _input(event: InputEvent) -> void:
    if not (event is InputEventKey and event.pressed and not event.echo):
        return
    match event.physical_keycode:
        KEY_F6:
            spine_share = maxf(0.0, spine_share - SPINE_TUNE_STEP)
        KEY_F7:
            spine_share = minf(1.5, spine_share + SPINE_TUNE_STEP)
        KEY_F8:
            _coop_log("SPINE TUNE: share=%.2f min=%.2f deepest_raw=%.3f bones=%s" % [
                spine_share, spine_pitch_min, _deepest_raw, _coop_bone_names()])
            return
        _:
            return
    _coop_log("SPINE TUNE: share=%.2f" % spine_share)


# Logged on demand so the neck/head bone can be identified by name -- splitting
# the pitch across two bones is what actually fixes looking down.
func _coop_bone_names() -> String:
    if aiInstance == null or aiInstance.skeleton == null:
        return "<no skeleton>"
    var skel: Skeleton3D = aiInstance.skeleton
    var names: Array = []
    for i in skel.get_bone_count():
        names.append("%d:%s" % [i, skel.get_bone_name(i)])
    return ", ".join(names)


var _puppet_spotlight: SpotLight3D = null

func _apply_puppet_flashlight(on: bool):
    if on == _current_flashlight:
        return
    _current_flashlight = on

    if !aiInstance:
        return

    if on:
        if !_puppet_spotlight:
            _puppet_spotlight = SpotLight3D.new()
            _puppet_spotlight.name = "_coop_flashlight"
            _puppet_spotlight.spot_angle = 30.0
            _puppet_spotlight.spot_range = 50.0
            _puppet_spotlight.light_energy = 20.0
            _puppet_spotlight.light_color = Color.WHITE
            _puppet_spotlight.shadow_enabled = false
            aiInstance.add_child(_puppet_spotlight)
        _puppet_spotlight.visible = true
    else:
        if _puppet_spotlight:
            _puppet_spotlight.visible = false


func _update_puppet_flashlight_transform():
    if !_puppet_spotlight or !_puppet_spotlight.visible:
        return
    if aiInstance and aiInstance.eyes:
        _puppet_spotlight.global_position = aiInstance.eyes.global_position
        _puppet_spotlight.global_basis = aiInstance.eyes.global_basis * Basis(Vector3.UP, PI)
