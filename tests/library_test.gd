extends SceneTree
## The game library, driven through its buttons (tests/run_packs.py, scenario
## "library"). This process serves a signed test catalog and the example pack
## from its own file server, then: Check for new games lists the example,
## Install fetches, checks and loads it so its card is on the menu, and Remove
## deletes it again.
const Registry = preload("res://scripts/game_registry.gd")
const FileServer = preload("res://scripts/file_server.gd")

var main: Node
var clock := 0.0
var serve_port := 0
var pack_file := ""
var catalog_file := ""

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--serve-port="): serve_port = int(arg.get_slice("=", 1))
		if arg.begins_with("--pack-file="): pack_file = arg.get_slice("=", 1)
		if arg.begins_with("--catalog-file="): catalog_file = arg.get_slice("=", 1)
	call_deferred("run")

func _process(delta: float) -> bool:
	clock += delta
	if clock > 60.0: fail("Timed out")
	return false

func fail(message: String) -> void:
	push_error("library: " + message)
	print("PACK CHECK FAILED (library): " + message)
	quit(1)

func check(condition: bool, message: String) -> void:
	if not condition: fail(message)

func until(condition: Callable, seconds: float = 15.0) -> bool:
	var deadline := clock + seconds
	while clock < deadline:
		if condition.call(): return true
		await process_frame
	return condition.call()

func press(node_name: String) -> void:
	var button: Button = main.find_child(node_name, true, false)
	check(button != null and not button.disabled, "No live %s button" % node_name)
	button.pressed.emit()
	await process_frame

func run() -> void:
	var server: Node = FileServer.new()
	root.add_child(server)
	check(server.start(serve_port) == serve_port, "The test server listens")
	server.serve("/catalog.json", catalog_file, "application/json")
	server.serve("/example.pck", pack_file)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.test_mode = true
	check(not Registry.has("example"), "Nothing installed at first")
	await press("Library")
	check(main.library_open and main.overlay.find_child("Row_example", true, false) == null, "The library opens, without the example yet")
	await _press_text("CHECK FOR NEW GAMES")
	check(await until(func(): return main.overlay.find_child("Install_example", true, false) != null), "Check for new games lists the example")
	await press("Install_example")
	check(await until(func(): return Registry.has("example") and main.games.has("example"), 20.0), "Install fetches and loads it (%s)" % main.packs.status("example"))
	check(main.packs.installed_packs().has("example"), "and records it")
	check(await until(func(): return main.overlay.find_child("Remove_example", true, false) != null), "The library offers Remove")
	await press("Remove_example")
	check(not main.packs.installed_packs().has("example"), "Remove forgets it")
	check(DirAccess.get_files_at(main.packs.root.path_join("games/example")).is_empty(), "and deletes the file")
	await press("LibraryDone")
	check(not main.library_open and main.view == "menu", "Done closes the library")
	check(main.screen.find_child("Card_example", true, false) != null, "The game stays on the menu until a restart")
	print("PACK_LIBRARY_PASS check-install-load-remove")
	quit(0)

func _press_text(text: String) -> void:
	for button in main.overlay.find_children("*", "Button", true, false):
		if button.text == text:
			button.pressed.emit()
			await process_frame
			return
	fail("No button " + text)
