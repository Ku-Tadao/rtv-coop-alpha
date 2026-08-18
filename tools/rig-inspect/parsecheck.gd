extends SceneTree

## Parse every mod script with the game's pack mounted.
##
## Godot rejects an entire script on a parse error and says nothing at the point
## of use -- the mixed-indentation bug shipped exactly that way, and remote
## players were invisible-but-solid for a release because of it. No amount of
## Python can catch that; only the engine knows whether GDScript is valid.
##
## The game's autoloads (Loader, Database, Simulation, ...) are registered from
## project settings this tool project does not have, so scripts that use them
## report `Identifier "X" not declared`. That is expected and is filtered by
## tools/parsecheck.py, which is what you should actually run. Everything else --
## syntax, indentation, arity against a known type -- is a real failure.
##
## Output is machine-read: one `### <path>` marker per script, then whatever
## Godot writes to stderr while parsing it.

const PCK := "D:/SteamLibrary/steamapps/common/Road to Vostok/RTV.pck"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: -- <mod archive as .zip>")
		quit(2)
		return
	if not ProjectSettings.load_resource_pack(PCK):
		push_error("could not mount game pack: " + PCK)
		quit(2)
		return
	if not ProjectSettings.load_resource_pack(args[0]):
		push_error("could not mount mod (must be named .zip or .pck): " + args[0])
		quit(2)
		return

	var scripts: Array = []
	_collect("res://mods", scripts)
	scripts.sort()

	for path in scripts:
		# Flushed so the marker cannot be reordered against the errors it owns.
		print("### %s" % path)
		var src := FileAccess.get_file_as_string(path)
		if src == "":
			print("!!! EMPTY")
			continue
		var s := GDScript.new()
		s.source_code = src
		if s.reload(true) != OK:
			print("!!! FAILED")
	print("### done")
	quit(0)


func _collect(dir_path: String, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			_collect(full, out)
		elif entry.get_extension() == "gd":
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
