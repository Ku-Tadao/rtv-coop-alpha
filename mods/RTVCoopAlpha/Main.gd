extends Node



const CoopFrameworksReady = preload("res://mods/RTVCoopAlpha/HookKit/CoopFrameworksReady.gd")
const CoopLobby = preload("res://mods/RTVCoopAlpha/Game/CoopLobby.gd")
const CoopNet = preload("res://mods/RTVCoopAlpha/Framework/CoopNet.gd")
const CoopPlayers = preload("res://mods/RTVCoopAlpha/Game/CoopPlayers.gd")
const CoopSettings = preload("res://mods/RTVCoopAlpha/Game/CoopSettings.gd")
const RTVCoop = preload("res://mods/RTVCoopAlpha/Game/Coop.gd")

const _COOP_PRELOADS = preload("res://mods/RTVCoopAlpha/_preloads.gd")


const STEAM_EXTENSION_PATH := "res://addons/godotsteam/godotsteam.gdextension"

const HOOK_SCRIPTS := [
	"res://mods/RTVCoopAlpha/Game/Hooks/LoaderHooks.gd",
	"res://mods/RTVCoopAlpha/Game/Hooks/AIHooks.gd",
	"res://mods/RTVCoopAlpha/Game/Hooks/CharacterHooks.gd",
	"res://mods/RTVCoopAlpha/Game/Hooks/InteractHooks.gd",
	"res://mods/RTVCoopAlpha/Game/Hooks/WorldHooks.gd",
	"res://mods/RTVCoopAlpha/Game/Hooks/VehicleHooks.gd",
	"res://mods/RTVCoopAlpha/Game/Hooks/InstrumentHooks.gd",
	"res://mods/RTVCoopAlpha/Game/Hooks/TransitionHooks.gd",
	"res://mods/RTVCoopAlpha/Game/Hooks/FireHooks.gd",
	"res://mods/RTVCoopAlpha/Game/Hooks/BedHooks.gd",
	"res://mods/RTVCoopAlpha/Game/Hooks/SimulationHooks.gd",
	"res://mods/RTVCoopAlpha/Game/Hooks/HitboxHooks.gd",
	"res://mods/RTVCoopAlpha/Game/Hooks/AISpawnerHooks.gd",
	"res://mods/RTVCoopAlpha/Game/Hooks/LootHooks.gd",
	"res://mods/RTVCoopAlpha/Game/Hooks/TraderHooks.gd",
	"res://mods/RTVCoopAlpha/Game/Hooks/EventSystemHooks.gd",
	"res://mods/RTVCoopAlpha/Game/Hooks/CompilerHooks.gd",
	"res://mods/RTVCoopAlpha/Game/Hooks/PlacerHooks.gd",
	"res://mods/RTVCoopAlpha/Game/Hooks/InteractorHooks.gd",
	"res://mods/RTVCoopAlpha/Game/Hooks/InterfaceHooks.gd",
	"res://mods/RTVCoopAlpha/Game/Hooks/CatFeederHooks.gd",
	"res://mods/RTVCoopAlpha/Game/Hooks/MineHooks.gd",
	"res://mods/RTVCoopAlpha/Game/Hooks/LayoutHooks.gd",
]

const SYNC_SCRIPTS := [
	"res://mods/RTVCoopAlpha/Game/Sync/SlotSerializer.gd",
	"res://mods/RTVCoopAlpha/Game/Sync/InteractableSync.gd",
	"res://mods/RTVCoopAlpha/Game/Sync/WorldSync.gd",
	"res://mods/RTVCoopAlpha/Game/Sync/EventSync.gd",
	"res://mods/RTVCoopAlpha/Game/Sync/AISync.gd",
	"res://mods/RTVCoopAlpha/Game/Sync/ContainerSync.gd",
	"res://mods/RTVCoopAlpha/Game/Sync/DownedSync.gd",
	"res://mods/RTVCoopAlpha/Game/Sync/QuestSync.gd",
	"res://mods/RTVCoopAlpha/Game/Sync/FurnitureSync.gd",
	"res://mods/RTVCoopAlpha/Game/Sync/PickupSync.gd",
	"res://mods/RTVCoopAlpha/Game/Sync/VoiceSync.gd",
	"res://mods/RTVCoopAlpha/Game/Sync/LocalStateSync.gd",
	"res://mods/RTVCoopAlpha/Game/Sync/ModBridge.gd",
]

const UI_SCRIPTS := [
	"res://mods/RTVCoopAlpha/UI/DebugOverlay.gd",
	"res://mods/RTVCoopAlpha/UI/LobbyUI.gd",
	"res://mods/RTVCoopAlpha/UI/SleepOverlay.gd",
	"res://mods/RTVCoopAlpha/UI/VoiceUI.gd",
]


var _coop: RTVCoop


var logger: Node = null

const BUILD_STAMP := "2026-04-28T04"

func _ready() -> void:
	print("[RTVCoopAlpha] Main.gd _ready (build %s)" % BUILD_STAMP)
	_try_load_steam_extension()
	_coop = RTVCoop.new()
	get_tree().root.add_child(_coop)
	_coop.boot()
	logger = load("res://mods/RTVCoopAlpha/Game/CoopLogger.gd").new()
	logger.name = "CoopLogger"
	_coop.add_child(logger)
	Engine.set_meta("CoopLogger", logger)
	logger.log_msg("Main", "BUILD: %s" % BUILD_STAMP)
	_spawn_services()
	_spawn_sync()
	_spawn_hooks()
	_spawn_ui()
	await CoopFrameworksReady.wait_async()
	if CoopFrameworksReady.is_available():
		logger.log_msg("Main", "frameworks_ready confirmed (modloader v%s)" % CoopFrameworksReady.lib().version())
	else:
		logger.log_msg("Main", "RTVModLib not present; running without hooks")


func _spawn_services() -> void:
	_add_child_node(CoopNet.new(), "Net")
	_add_child_node(CoopLobby.new(), "Lobby")
	_add_child_node(CoopSettings.new(), "Settings")
	_add_child_node(CoopPlayers.new(), "Players")


func _spawn_sync() -> void:
	for path in SYNC_SCRIPTS:
		var script: GDScript = load(path)
		if script == null:
			push_error("[RTVCoopAlpha] failed to load " + path)
			continue
		var node: Node = script.new()
		_add_child_node(node, "Sync_" + path.get_file().get_basename().replace("Sync", ""))


func _spawn_hooks() -> void:
	for path in HOOK_SCRIPTS:
		var script: GDScript = load(path)
		if script == null:
			push_error("[RTVCoopAlpha] failed to load " + path)
			continue
		var node: Node = script.new()
		_add_child_node(node, path.get_file().get_basename())


func _spawn_ui() -> void:
	for path in UI_SCRIPTS:
		var script: GDScript = load(path)
		if script == null:
			push_error("[RTVCoopAlpha] failed to load " + path)
			continue
		var node: Node = script.new()
		_add_child_node(node, path.get_file().get_basename())


func _add_child_node(node: Node, node_name: String) -> void:
	node.name = node_name
	_coop.add_child(node)


func _try_load_steam_extension() -> void:
	if not FileAccess.file_exists(STEAM_EXTENSION_PATH):
		print("[RTVCoopAlpha] GodotSteam extension not found — local loopback only")
		return
	if GDExtensionManager.is_extension_loaded(STEAM_EXTENSION_PATH):
		print("[RTVCoopAlpha] GodotSteam already loaded")
		return
	var status := GDExtensionManager.load_extension(STEAM_EXTENSION_PATH)
	match status:
		GDExtensionManager.LOAD_STATUS_OK:
			print("[RTVCoopAlpha] GodotSteam extension loaded")
		GDExtensionManager.LOAD_STATUS_ALREADY_LOADED:
			print("[RTVCoopAlpha] GodotSteam extension already loaded")
		GDExtensionManager.LOAD_STATUS_FAILED:
			push_error("[RTVCoopAlpha] GodotSteam LOAD_STATUS_FAILED")
		GDExtensionManager.LOAD_STATUS_NOT_LOADED:
			push_error("[RTVCoopAlpha] GodotSteam LOAD_STATUS_NOT_LOADED")
		GDExtensionManager.LOAD_STATUS_NEEDS_RESTART:
			push_warning("[RTVCoopAlpha] GodotSteam needs editor restart")
		_:
			push_warning("[RTVCoopAlpha] GodotSteam unknown status %d" % status)
