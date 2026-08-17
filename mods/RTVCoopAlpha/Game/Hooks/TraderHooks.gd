extends "res://mods/RTVCoopAlpha/HookKit/BaseHook.gd"



const CoopAuthority = preload("res://mods/RTVCoopAlpha/Framework/CoopAuthority.gd")

func _setup_hooks() -> void:
	CoopHook.register(self, "trader-_ready-post", _on_trader_ready_post)
	CoopHook.register_replace_or_post(self, "trader-completetask", _replace_trader_complete, _post_trader_complete)


func _on_trader_ready_post() -> void:
	var trader := CoopHook.caller()
	if trader == null or not CoopAuthority.is_active() or quest == null:
		return
	if CoopAuthority.is_host():
		var completed: Array = quest.get_completed(trader.traderData.name)
		trader.tasksCompleted.clear()
		for task_name in completed:
			trader.tasksCompleted.append(task_name)
	else:
		trader.tasksCompleted.clear()
		if quest.has_state_for(trader.traderData.name):
			for task_name in quest.get_completed(trader.traderData.name):
				trader.tasksCompleted.append(task_name)
		quest.RequestTraderState.rpc_id(1, trader.traderData.name)


func _replace_trader_complete(task_data) -> void:
	var trader := CoopHook.caller()
	if trader == null or not CoopAuthority.is_active() or quest == null:
		return
	if CoopAuthority.is_host():
		return

	if not quest.has_state_for(trader.traderData.name):
		Loader.Message("Syncing trader state… try again in a moment.", Color.ORANGE)
		CoopHook.skip_super()
		return
	if quest.get_completed(trader.traderData.name).has(task_data.name):
		Loader.Message("Task already completed.", Color.ORANGE)
		CoopHook.skip_super()
		return
	trader.PlayTraderTask()
	Loader.Message("Task Completed: " + task_data.name, Color.GREEN)
	quest.SubmitTaskCompletion.rpc_id(1, trader.traderData.name, task_data.name)
	CoopHook.skip_super()


func _post_trader_complete(task_data) -> void:
	var trader := CoopHook.caller()
	if trader == null or not CoopAuthority.is_active() or not CoopAuthority.is_host() or quest == null:
		return
	quest.coop_trader_state[trader.traderData.name] = trader.tasksCompleted.duplicate()
	quest._persist_host()
	quest.BroadcastTaskCompletion.rpc(trader.traderData.name, task_data.name)
