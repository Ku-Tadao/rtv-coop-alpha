extends SceneTree

## Headless introspection of the game's rig.
##
## Answers the structural questions that otherwise cost a build, a session and a
## screenshot each: which bones exist and how they parent, which animations ship,
## and what the AnimationTree's blend spaces actually blend between. It renders
## nothing and judges nothing -- looks are still a human call.
##
##   godot --headless --path tools/rig-inspect --script res://inspect.gd -- <pck> [scene]
##
## Defaults to the AI scene, which is what the co-op puppet is built from.

const DEFAULT_PCK := "D:/SteamLibrary/steamapps/common/Road to Vostok/RTV.pck"


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var pck: String = args[0] if args.size() > 0 else DEFAULT_PCK

	if not FileAccess.file_exists(pck):
		push_error("pack not found: " + pck)
		quit(1)
		return
	if not ProjectSettings.load_resource_pack(pck):
		push_error("could not mount: " + pck)
		quit(1)
		return
	print("mounted: ", pck, "\n")

	var targets: Array = []
	if args.size() > 1:
		targets.append(args[1])
	else:
		targets = _find_scenes()

	for path in targets:
		_report(path)
	quit()


## The AI scene is not at a documented path, so search rather than assume one.
func _find_scenes() -> Array:
	var found: Array = []
	var pending: Array = ["res://"]
	while not pending.is_empty() and found.size() < 12:
		var current: String = pending.pop_front()
		var dir := DirAccess.open(current)
		if dir == null:
			continue
		dir.list_dir_begin()
		var entry := dir.get_next()
		while entry != "":
			var full: String = current.path_join(entry)
			if dir.current_is_dir():
				pending.append(full)
			elif entry.get_extension() in ["tscn", "scn"]:
				var lower := entry.to_lower()
				if lower.contains("ai") or lower.contains("agent") or lower.contains("guard"):
					found.append(full)
			entry = dir.get_next()
		dir.list_dir_end()
	if found.is_empty():
		push_warning("no AI-looking scene found; pass one explicitly")
	return found


func _report(path: String) -> void:
	print("=".repeat(70))
	print(path)
	print("=".repeat(70))

	var packed := load(path) as PackedScene
	if packed == null:
		print("  not a PackedScene\n")
		return
	var root := packed.instantiate()
	if root == null:
		print("  failed to instantiate\n")
		return

	for node in _walk(root):
		if node is Skeleton3D:
			_report_skeleton(node)
		elif node is AnimationPlayer:
			var clips: PackedStringArray = node.get_animation_list()
			print("\nAnimationPlayer %s -- %d clip(s)" % [node.name, clips.size()])
			for clip in clips:
				var anim := node.get_animation(clip)
				print("  %-28s %6.2fs loop=%s tracks=%d" % [
					clip, anim.length, anim.loop_mode != Animation.LOOP_NONE, anim.get_track_count()])
		elif node is AnimationTree:
			_report_tree(node)

	root.free()
	print("")


func _report_skeleton(skel: Skeleton3D) -> void:
	print("\nSkeleton3D %s -- %d bone(s)" % [skel.name, skel.get_bone_count()])
	for i in skel.get_bone_count():
		var parent: int = skel.get_bone_parent(i)
		print("  %2d %-20s parent=%s" % [
			i, skel.get_bone_name(i),
			skel.get_bone_name(parent) if parent >= 0 else "-"])


## The blend spaces are the interesting part: knowing which clips sit at which
## blend point is what says whether directional locomotion exists at all.
func _report_tree(tree: AnimationTree) -> void:
	print("\nAnimationTree %s" % tree.name)
	var root_node := tree.tree_root
	if root_node == null:
		print("  no tree_root")
		return
	_describe_node(root_node, "")


func _describe_node(node: AnimationNode, prefix: String) -> void:
	var kind := node.get_class()
	print("  %s%s (%s)" % [prefix, node.resource_name if node.resource_name else kind, kind])

	if node is AnimationNodeBlendSpace1D:
		for i in node.get_blend_point_count():
			var point := node.get_blend_point_node(i)
			print("  %s  [%.2f] %s" % [
				prefix, node.get_blend_point_position(i), _animation_of(point)])
		return
	if node is AnimationNodeBlendSpace2D:
		for i in node.get_blend_point_count():
			print("  %s  %s %s" % [
				prefix, node.get_blend_point_position(i),
				_animation_of(node.get_blend_point_node(i))])
		return

	for child_name in node.get_property_list().map(func(p): return str(p.get("name", ""))):
		if not child_name.begins_with("states/") or not child_name.ends_with("/node"):
			continue
		var child = node.get(child_name)
		if child is AnimationNode:
			_describe_node(child, prefix + "  ")


func _animation_of(node: AnimationNode) -> String:
	if node is AnimationNodeAnimation:
		return node.animation
	return node.get_class() if node else "<empty>"


func _walk(node: Node) -> Array:
	var out: Array = [node]
	for child in node.get_children():
		out.append_array(_walk(child))
	return out
