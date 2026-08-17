extends CanvasLayer



const CoopAuthority = preload("res://mods/RTVCoopAlpha/Framework/CoopAuthority.gd")
const RTVCoop = preload("res://mods/RTVCoopAlpha/Game/Coop.gd")

const ACCENT := Color(0.56, 0.79, 0.23, 1.0)
const STATUS_UPDATE_INTERVAL := 0.2


var fontMedium: FontFile = load("res://Fonts/Lora-Medium.ttf")
var fontSemiBold: FontFile = load("res://Fonts/Lora-SemiBold.ttf")


var coopButton: Button = null
var coopPanel: Control = null
var menuMain: Control = null

var steamLabel: RichTextLabel
var statusLabel: RichTextLabel
var playersLabel: RichTextLabel
var hostBtn: Button
var inviteBtn: Button
var dcBtn: Button
var continueBtn: Button
var newGameBtn: Button
var waitingLabel: RichTextLabel

var settingsToggleBtn: Button
var settingsContainer: VBoxContainer
var lootSlider: HSlider
var statsSlider: HSlider
var aiSlider: HSlider
var dayRateSlider: HSlider
var nightRateSlider: HSlider
var lootValueLabel: Label
var statsValueLabel: Label
var aiValueLabel: Label
var dayRateValueLabel: Label
var nightRateValueLabel: Label

var injected: bool = false
var steam_signals_hooked: bool = false
var _status_accum: float = 0.0


func _net() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.net if coop else null


func _lobby() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.lobby if coop else null


func _players() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.players if coop else null


func _settings() -> Node:
	var coop := RTVCoop.get_instance()
	return coop.settings if coop else null


func _ready() -> void:
	layer = 50


func _process(delta: float) -> void:
	_hook_steam_signals_once()

	var scene := get_tree().current_scene
	if scene == null:
		return

	if scene.name != "Map":
		if not injected:
			_try_inject(scene)
		if coopPanel and coopPanel.visible:
			_status_accum += delta
			if _status_accum >= STATUS_UPDATE_INTERVAL:
				_status_accum = 0.0
				_update_status()
	else:
		if coopPanel:
			coopPanel.hide()
		injected = false
		coopButton = null
		coopPanel = null
		menuMain = null
		_status_accum = 0.0


func _hook_steam_signals_once() -> void:
	if steam_signals_hooked:
		return
	var lobby := _lobby()
	if lobby == null:
		return
	lobby.lobby_created_ok.connect(_on_lobby_created_ok)
	lobby.lobby_create_failed.connect(_on_lobby_create_failed)
	lobby.lobby_joined_ok.connect(_on_lobby_joined_ok)
	lobby.lobby_join_failed.connect(_on_lobby_join_failed)
	steam_signals_hooked = true
	print("[LobbyUI] Steam lobby signals hooked")


func _try_inject(scene: Node) -> void:
	var buttons: Node = scene.get_node_or_null("Main/Buttons")
	if buttons == null:
		return
	menuMain = scene.get_node_or_null("Main")

	for child in buttons.get_children():
		if child.name == "CoopBtn":
			injected = true
			return

	if buttons.get_child_count() == 0:
		return

	var template_btn: Button = buttons.get_child(0)
	coopButton = template_btn.duplicate()
	coopButton.name = "CoopBtn"
	coopButton.text = "Co-op"

	for sig in coopButton.get_signal_list():
		for conn in coopButton.get_signal_connection_list(sig.name):
			if coopButton.is_connected(sig.name, conn.callable):
				coopButton.disconnect(sig.name, conn.callable)

	coopButton.pressed.connect(_on_coop_pressed)
	buttons.add_child(coopButton)
	buttons.move_child(coopButton, 2)

	_create_panel(scene)
	injected = true
	print("[LobbyUI] Co-op button injected")


func _create_panel(scene: Node) -> void:
	coopPanel = Control.new()
	coopPanel.name = "CoopPanel"
	coopPanel.set_anchors_preset(Control.PRESET_FULL_RECT)
	coopPanel.hide()
	scene.add_child(coopPanel)

	var buttons: Node = scene.get_node_or_null("Main/Buttons")
	var template_btn: Button = buttons.get_child(0) if buttons and buttons.get_child_count() > 0 else null

	var button_column := VBoxContainer.new()
	button_column.anchor_left = 0.5
	button_column.anchor_right = 0.5
	button_column.anchor_top = 0.5
	button_column.anchor_bottom = 0.5
	button_column.offset_left = -160
	button_column.offset_right = 160
	button_column.offset_top = -150
	button_column.offset_bottom = 150
	button_column.grow_horizontal = Control.GROW_DIRECTION_BOTH
	button_column.grow_vertical = Control.GROW_DIRECTION_BOTH
	button_column.add_theme_constant_override("separation", 6)
	coopPanel.add_child(button_column)

	hostBtn = _clone_menu_btn(template_btn, "Host Game")
	hostBtn.pressed.connect(_on_host)
	button_column.add_child(hostBtn)

	inviteBtn = _clone_menu_btn(template_btn, "Invite Friend")
	inviteBtn.pressed.connect(_on_invite)
	button_column.add_child(inviteBtn)

	dcBtn = _clone_menu_btn(template_btn, "Disconnect")
	dcBtn.pressed.connect(_on_dc)
	button_column.add_child(dcBtn)

	button_column.add_child(_divider())

	continueBtn = _clone_menu_btn(template_btn, "Continue")
	continueBtn.pressed.connect(_on_continue)
	button_column.add_child(continueBtn)

	newGameBtn = _clone_menu_btn(template_btn, "New Game")
	newGameBtn.pressed.connect(_on_new_game)
	button_column.add_child(newGameBtn)

	waitingLabel = _make_label(13, "[center][color=#e0c850]Waiting for host to start...[/color][/center]")
	waitingLabel.visible = false
	button_column.add_child(waitingLabel)

	button_column.add_child(_divider())

	var return_btn := _clone_menu_btn(template_btn, "Return")
	return_btn.pressed.connect(_on_return)
	button_column.add_child(return_btn)

	var game_theme := load("res://UI/Themes/Theme.tres")
	var info_panel := Panel.new()
	info_panel.anchor_left = 0.5
	info_panel.anchor_right = 0.5
	info_panel.anchor_top = 0.5
	info_panel.anchor_bottom = 0.5
	info_panel.offset_left = 190
	info_panel.offset_right = 510
	info_panel.offset_top = -200
	info_panel.offset_bottom = 200
	info_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	info_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	if game_theme:
		info_panel.theme = game_theme
	coopPanel.add_child(info_panel)

	var info_margin := MarginContainer.new()
	info_margin.anchor_right = 1.0
	info_margin.anchor_bottom = 1.0
	info_margin.add_theme_constant_override("margin_left", 16)
	info_margin.add_theme_constant_override("margin_top", 16)
	info_margin.add_theme_constant_override("margin_right", 16)
	info_margin.add_theme_constant_override("margin_bottom", 16)
	info_panel.add_child(info_margin)

	var info_outer := VBoxContainer.new()
	info_outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_outer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	info_margin.add_child(info_outer)

	var info_scroll := ScrollContainer.new()
	info_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	info_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	info_outer.add_child(info_scroll)

	var info_column := VBoxContainer.new()
	info_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_column.add_theme_constant_override("separation", 6)
	info_scroll.add_child(info_column)

	steamLabel = _make_label(13, "[color=gray]Steam: checking...[/color]")
	steamLabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_column.add_child(steamLabel)

	statusLabel = _make_label(14, "Disconnected")
	statusLabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_column.add_child(statusLabel)

	info_column.add_child(_divider())

	var players_header := _make_label(11, "[color=gray]PLAYERS[/color]")
	players_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_column.add_child(players_header)

	playersLabel = _make_label(13, "[color=gray]Not connected[/color]")
	playersLabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_column.add_child(playersLabel)

	info_column.add_child(_divider())

	settingsToggleBtn = Button.new()
	settingsToggleBtn.text = "Settings  ▸"
	settingsToggleBtn.add_theme_font_override("font", fontMedium)
	settingsToggleBtn.add_theme_font_size_override("font_size", 12)
	settingsToggleBtn.flat = true
	settingsToggleBtn.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	settingsToggleBtn.add_theme_color_override("font_hover_color", ACCENT)
	settingsToggleBtn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	settingsToggleBtn.pressed.connect(_toggle_settings)
	info_column.add_child(settingsToggleBtn)

	settingsContainer = VBoxContainer.new()
	settingsContainer.add_theme_constant_override("separation", 2)
	settingsContainer.visible = false
	info_column.add_child(settingsContainer)

	var loot_row := _create_setting_row("Loot", 0.0, 5.0, 0.25, 1.0)
	lootSlider = loot_row[0]
	lootValueLabel = loot_row[1]
	lootSlider.value_changed.connect(func(v): _on_setting_changed("loot_multiplier", v, lootValueLabel))
	settingsContainer.add_child(loot_row[2])

	var stats_row := _create_setting_row("Stat Drain", 0.0, 3.0, 0.25, 1.0)
	statsSlider = stats_row[0]
	statsValueLabel = stats_row[1]
	statsSlider.value_changed.connect(func(v): _on_setting_changed("stats_drain_multiplier", v, statsValueLabel))
	settingsContainer.add_child(stats_row[2])

	var ai_row := _create_setting_row("AI Count", 0.0, 3.0, 0.25, 1.0)
	aiSlider = ai_row[0]
	aiValueLabel = ai_row[1]
	aiSlider.value_changed.connect(func(v): _on_setting_changed("ai_multiplier", v, aiValueLabel))
	settingsContainer.add_child(ai_row[2])

	var day_row := _create_setting_row("Day Rate", 0.25, 5.0, 0.25, 1.0)
	dayRateSlider = day_row[0]
	dayRateValueLabel = day_row[1]
	dayRateSlider.value_changed.connect(func(v): _on_setting_changed("day_rate_multiplier", v, dayRateValueLabel))
	settingsContainer.add_child(day_row[2])

	var night_row := _create_setting_row("Night Rate", 0.25, 5.0, 0.25, 1.0)
	nightRateSlider = night_row[0]
	nightRateValueLabel = night_row[1]
	nightRateSlider.value_changed.connect(func(v): _on_setting_changed("night_rate_multiplier", v, nightRateValueLabel))
	settingsContainer.add_child(night_row[2])


func _make_label(size: int, text: String) -> RichTextLabel:
	var lbl := RichTextLabel.new()
	lbl.bbcode_enabled = true
	lbl.fit_content = true
	lbl.scroll_active = false
	lbl.add_theme_font_override("normal_font", fontMedium)
	lbl.add_theme_font_size_override("normal_font_size", size)
	lbl.text = text
	return lbl


func _create_setting_row(label_text: String, min_val: float, max_val: float, step: float, default: float) -> Array:
	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 0)
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var header := HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(header)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_override("font", fontMedium)
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(lbl)

	var val_lbl := Label.new()
	val_lbl.text = str(default) + "x"
	val_lbl.add_theme_font_override("font", fontMedium)
	val_lbl.add_theme_font_size_override("font_size", 12)
	val_lbl.add_theme_color_override("font_color", ACCENT)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header.add_child(val_lbl)

	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = step
	slider.value = default
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(200, 20)
	container.add_child(slider)

	return [slider, val_lbl, container]


func _on_setting_changed(key: String, value: float, label: Label) -> void:
	label.text = str(value) + "x"
	var settings := _settings()
	if settings and CoopAuthority.is_host():
		settings.Set(key, value)


func _divider() -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, 6)
	return s


func _clone_menu_btn(template_btn, text: String) -> Button:
	if template_btn:
		var btn: Button = template_btn.duplicate()
		btn.text = text
		for sig in btn.get_signal_list():
			for conn in btn.get_signal_connection_list(sig.name):
				if btn.is_connected(sig.name, conn.callable):
					btn.disconnect(sig.name, conn.callable)
		return btn
	return _make_btn(text)


func _make_btn(text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.add_theme_font_override("font", fontMedium)
	btn.add_theme_font_size_override("font_size", 14)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.12, 0.9)
	style.border_color = Color(0.25, 0.25, 0.25, 0.9)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	btn.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate()
	hover.border_color = ACCENT
	hover.bg_color = Color(0.16, 0.16, 0.16, 0.9)
	btn.add_theme_stylebox_override("hover", hover)
	var pressed := style.duplicate()
	pressed.bg_color = Color(0.08, 0.08, 0.08, 0.9)
	btn.add_theme_stylebox_override("pressed", pressed)
	var disabled := style.duplicate()
	disabled.bg_color = Color(0.08, 0.08, 0.08, 0.5)
	disabled.border_color = Color(0.15, 0.15, 0.15, 0.5)
	btn.add_theme_stylebox_override("disabled", disabled)
	btn.add_theme_color_override("font_disabled_color", Color(0.3, 0.3, 0.3))
	return btn


func _update_status() -> void:
	var net := _net()
	var lobby := _lobby()

	if lobby and lobby.available:
		steamLabel.text = "[color=#8fc93a]Steam:[/color] " + lobby.MyName()
	elif lobby:
		steamLabel.text = "[color=gray]Steam: not available[/color]"
	else:
		steamLabel.text = "[color=gray]Steam: not loaded[/color]"

	var steam_ok: bool = lobby != null and lobby.available
	var is_host: bool = net != null and net.IsActive() and net.IsHost()
	var is_client: bool = net != null and net.IsActive() and not net.IsHost()
	var is_connected: bool = is_host or is_client

	if net == null:
		statusLabel.text = "[color=gray]Network not loaded[/color]"
	elif not net.IsActive():
		statusLabel.text = "[color=gray]Disconnected[/color]"
	elif is_host:
		var peers: int = multiplayer.get_peers().size()
		var transport_tag: String = "Steam" if net.IsSteamTransport() else "ENet"
		statusLabel.text = "[color=#8fc93a]Hosting[/color] (%s) — %d player(s)" % [transport_tag, peers + 1]
	else:
		var transport_tag2: String = "Steam" if net.IsSteamTransport() else "ENet"
		statusLabel.text = "[color=#8fc93a]Connected[/color] (%s)" % transport_tag2

	hostBtn.disabled = is_connected
	inviteBtn.disabled = not (is_host and steam_ok and lobby.InLobby())
	dcBtn.disabled = not is_connected

	_update_player_list(is_connected)
	_update_start_buttons(is_host, is_client)


func _update_player_list(is_connected: bool) -> void:
	if not is_connected:
		playersLabel.text = "[color=gray]Not connected[/color]"
		return
	var players := _players()
	var names: Array = []
	var my_id: int = multiplayer.get_unique_id()
	if players and players.peer_names:
		var ids: Array = players.peer_names.keys()
		ids.sort()
		for id in ids:
			var name_str: String = str(players.peer_names[id])
			var tag: String = " [color=gray](you)[/color]" if id == my_id else ""
			var role: String = " [color=#8fc93a][host][/color]" if id == 1 else ""
			names.append(name_str + role + tag)
	if names.is_empty():
		playersLabel.text = "[color=gray]Waiting for players...[/color]"
	else:
		playersLabel.text = "\n".join(names)


func _update_start_buttons(is_host: bool, is_client: bool) -> void:
	continueBtn.visible = is_host
	newGameBtn.visible = is_host
	waitingLabel.visible = is_client
	settingsToggleBtn.visible = is_host
	if not is_host:
		settingsContainer.visible = false

	if is_host:
		var has_save: bool = Loader.ValidateShelter() != ""
		continueBtn.disabled = not has_save


func _toggle_settings() -> void:
	settingsContainer.visible = not settingsContainer.visible
	settingsToggleBtn.text = "Settings  ▾" if settingsContainer.visible else "Settings  ▸"


func _on_coop_pressed() -> void:
	if coopPanel and menuMain:
		coopPanel.show()
		menuMain.hide()
		_status_accum = STATUS_UPDATE_INTERVAL
		_update_status()


func _on_return() -> void:
	if coopPanel and menuMain:
		coopPanel.hide()
		menuMain.show()


func _on_host() -> void:
	var net := _net()
	if net == null or not net.HostGame():
		return
	var lobby := _lobby()
	if lobby and lobby.available:
		lobby.CreateLobby()


func _on_invite() -> void:
	var lobby := _lobby()
	if lobby:
		lobby.OpenInviteOverlay()


func _on_dc() -> void:
	var net := _net()
	if net:
		net.Disconnect()
	var lobby := _lobby()
	if lobby:
		lobby.LeaveLobby()


func _on_continue() -> void:
	var net := _net()
	if net == null or not net.IsActive() or not net.IsHost():
		return
	var target: String = Loader.ValidateShelter()
	if target == "":
		return
	if coopPanel:
		coopPanel.hide()
	Loader.LoadScene(target)


func _on_new_game() -> void:
	var net := _net()
	if net == null or not net.IsActive() or not net.IsHost():
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	var modes: Node = scene.get_node_or_null("Modes")
	if coopPanel:
		coopPanel.hide()
	if modes:
		modes.show()


func _on_lobby_created_ok(id: int) -> void:
	print("[LobbyUI] Steam lobby created: %d" % id)


func _on_lobby_create_failed(reason: String) -> void:
	print("[LobbyUI] Steam lobby create failed: %s" % reason)


func _on_lobby_joined_ok(_id: int, host_id: int) -> void:
	print("[LobbyUI] Steam lobby joined; host=%d — connecting peer" % host_id)
	var net := _net()
	if net:
		net.JoinSteam(host_id)


func _on_lobby_join_failed(reason: String) -> void:
	print("[LobbyUI] Steam lobby join failed: %s" % reason)
