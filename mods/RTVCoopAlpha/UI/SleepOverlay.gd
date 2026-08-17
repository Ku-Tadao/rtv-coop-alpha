extends CanvasLayer



const RTVCoop = preload("res://mods/RTVCoopAlpha/Game/Coop.gd")

var label: Label
var font: FontFile = load("res://Fonts/Lora-Medium.ttf")


func _ready() -> void:
	layer = 90
	label = Label.new()
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("outline_size", 5)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.anchor_left = 0.0
	label.anchor_right = 1.0
	label.anchor_top = 0.0
	label.offset_top = 80
	label.offset_bottom = 130
	label.visible = false
	add_child(label)


func _process(_delta: float) -> void:
	var coop := RTVCoop.get_instance()
	if coop == null or coop.players == null or coop.net == null or not coop.net.IsActive():
		label.visible = false
		return
	var players := coop.players
	var ready_ids: Array = players.get_meta("coop_sleep_ready_ids", [])
	var total: int = players.get_meta("coop_sleep_total", 0)
	if total <= 1 or ready_ids.is_empty():
		label.visible = false
		return
	label.visible = true
	label.text = "Sleeping: %d/%d ready" % [ready_ids.size(), total]
