extends Object

#I genuinely dont even know if this helps. But Im keeping it. 

# --- Framework layer ---
const _fw_evt = preload("res://mods/RTVCoopAlpha/Framework/CoopEvents.gd")
const _fw_auth = preload("res://mods/RTVCoopAlpha/Framework/CoopAuthority.gd")
const _fw_rpc = preload("res://mods/RTVCoopAlpha/Framework/CoopRPC.gd")
const _fw_svc = preload("res://mods/RTVCoopAlpha/Framework/SyncService.gd")
const _fw_adp = preload("res://mods/RTVCoopAlpha/Framework/SyncAdapter.gd")
const _fw_psp = preload("res://mods/RTVCoopAlpha/Framework/PlayerStateProxy.gd")
const _fw_net = preload("res://mods/RTVCoopAlpha/Framework/CoopNet.gd")
const _fw_api = preload("res://mods/RTVCoopAlpha/Framework/CoopAPI.gd")

# --- HookKit ---
const _fwr = preload("res://mods/RTVCoopAlpha/HookKit/CoopFrameworksReady.gd")
const _hook = preload("res://mods/RTVCoopAlpha/HookKit/CoopHook.gd")
const _dsp = preload("res://mods/RTVCoopAlpha/HookKit/CoopDispatch.gd")
const _bhook = preload("res://mods/RTVCoopAlpha/HookKit/BaseHook.gd")

# --- Game layer ---
const _scn = preload("res://mods/RTVCoopAlpha/Game/CoopScene.gd")
const _coop = preload("res://mods/RTVCoopAlpha/Game/Coop.gd")
const _lobby = preload("res://mods/RTVCoopAlpha/Game/CoopLobby.gd")
const _set = preload("res://mods/RTVCoopAlpha/Game/CoopSettings.gd")
const _cbuf = preload("res://mods/RTVCoopAlpha/Game/CoopCharacterBuffer.gd")
const _csf = preload("res://mods/RTVCoopAlpha/Game/CoopSceneFlow.gd")
const _pl = preload("res://mods/RTVCoopAlpha/Game/CoopPlayers.gd")

# --- Game sync modules ---
const _bsync = preload("res://mods/RTVCoopAlpha/Game/Sync/BaseSync.gd")
const _slot = preload("res://mods/RTVCoopAlpha/Game/Sync/SlotSerializer.gd")
const _int = preload("res://mods/RTVCoopAlpha/Game/Sync/InteractableSync.gd")
const _wrld = preload("res://mods/RTVCoopAlpha/Game/Sync/WorldSync.gd")
const _ev = preload("res://mods/RTVCoopAlpha/Game/Sync/EventSync.gd")
const _ai = preload("res://mods/RTVCoopAlpha/Game/Sync/AISync.gd")
const _cont = preload("res://mods/RTVCoopAlpha/Game/Sync/ContainerSync.gd")
const _qu = preload("res://mods/RTVCoopAlpha/Game/Sync/QuestSync.gd")
const _fu = preload("res://mods/RTVCoopAlpha/Game/Sync/FurnitureSync.gd")
const _pk = preload("res://mods/RTVCoopAlpha/Game/Sync/PickupSync.gd")
const _vc = preload("res://mods/RTVCoopAlpha/Game/Sync/VoiceSync.gd")
const _ls = preload("res://mods/RTVCoopAlpha/Game/Sync/LocalStateSync.gd")
const _mb = preload("res://mods/RTVCoopAlpha/Game/Sync/ModBridge.gd")

# --- Game types ---
const _pup = preload("res://mods/RTVCoopAlpha/Game/Types/Puppet.gd")
