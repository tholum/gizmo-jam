extends SceneTree
## Second half of `tools/build.py --pack`: turns Godot's exported pack into a
## game pack, checks it, and optionally installs it as a developer pack.
##   godot --headless --path . --script res://tools/pack_tool.gd -- \
##       <raw.pck> <out.pck> <id> [--dev-install]
## Keeps only res://games/<id>/ and Godot's converted resources
## (res://.godot/imported/, res://.godot/exported/), dropping the project-wide
## files every export adds (project.binary, the uid and class caches, the
## project icon). The result must pass the same checks the game applies
## (scripts/pack_core.gd) or the tool fails.

const PackCore = preload("res://scripts/pack_core.gd")

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 3:
		_fail("usage: <raw.pck> <out.pck> <id> [--dev-install]")
		return
	var raw: String = args[0]
	var out: String = args[1]
	var id: String = args[2]
	var info := PackCore.read_pck(raw)
	if info.has("error"):
		_fail("cannot read %s: %s" % [raw, info.error])
		return
	var src := FileAccess.open(raw, FileAccess.READ)
	var tmp := OS.get_cache_dir().path_join("gizmojam-pack-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(tmp)
	var packer := PCKPacker.new()
	if packer.pck_start(out) != OK:
		_fail("cannot write " + out)
		return
	var kept := 0
	for e in info.files:
		var p: String = e.path
		if not (p.begins_with("res://games/%s/" % id) or p.begins_with("res://.godot/imported/") or p.begins_with("res://.godot/exported/")):
			print("  drop  ", p)
			continue
		src.seek(e.offset)
		var piece := tmp.path_join(str(kept))
		var w := FileAccess.open(piece, FileAccess.WRITE)
		w.store_buffer(src.get_buffer(e.size))
		w.close()
		packer.add_file(p, piece)
		print("  keep  ", p)
		kept += 1
	packer.flush()
	for i in kept: DirAccess.remove_absolute(tmp.path_join(str(i)))
	DirAccess.remove_absolute(tmp)
	# The game's own checks, with no core list (this is the source tree).
	var problem := PackCore.verify_pack(out, id, FileAccess.get_file_as_bytes(out).size(), "", {})
	if not problem.is_empty():
		_fail(problem)
		return
	var game: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://games/%s/game.json" % id))
	if typeof(game) != TYPE_DICTIONARY:
		_fail("games/%s/game.json is not a JSON object" % id)
		return
	var entry := PackCore.game_entry(game, id, "signed", "", 0)
	if entry.has("error"):
		_fail("games/%s/game.json: %s" % [id, entry.error])
		return
	print("PACK %s %s kept=%d" % [id, out, kept])
	if "--dev-install" in args:
		var dest := "user://dev-games/%s.pck" % id
		DirAccess.make_dir_recursive_absolute("user://dev-games")
		DirAccess.copy_absolute(out, dest)
		print("DEV-INSTALLED ", ProjectSettings.globalize_path(dest))
	quit(0)

func _fail(message: String) -> void:
	printerr("PACK FAILED: ", message)
	quit(1)
