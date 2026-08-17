extends "res://mods/RTVCoopAlpha/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoopAlpha/Framework/CoopAuthority.gd")

func _setup_hooks() -> void:
	CoopHook.register(self, "transition-interact-post", _on_transition_interact_post)


func _on_transition_interact_post() -> void:
	var tr := CoopHook.caller()
	if tr == null or not CoopAuthority.is_host() or not CoopAuthority.is_active():
		return
	if tr.locked or tr.tutorialExit:
		return
	if interactable:
		interactable.BroadcastTransitionDrain.rpc(tr.energy, tr.hydration)
