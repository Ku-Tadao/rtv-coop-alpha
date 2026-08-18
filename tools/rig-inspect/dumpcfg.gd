extends SceneTree
func _initialize() -> void:
	ProjectSettings.load_resource_pack("D:/SteamLibrary/steamapps/common/Road to Vostok/RTV.pck")
	var f := FileAccess.open("res://project.godot", FileAccess.READ)
	print(f.get_as_text() if f else "no project.godot in pck")
	quit()
