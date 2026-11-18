extends SceneTree
## A Gizmo Jam 0.2.0 guest in tests/run_packs.py. Run inside the 0.2.0 source
## tree (--path), so it uses only what 0.2.0's main scene has. It joins, must
## stay in the lobby while the party plays a game it does not have, and must
## then be launched into the Spin Cycle round that follows.

var main: Node
var port := 19901
var clock := 0.0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--port="): port = int(arg.get_slice("=", 1))
	call_deferred("run")

func _process(delta: float) -> bool:
	clock += delta
	if clock > 100.0: fail("Timed out in view '%s'" % (main.view if main else "?"))
	return false

func fail(message: String) -> void:
	push_error("legacy: " + message)
	print("PACK CHECK FAILED (legacy): " + message)
	quit(1)

func until(condition: Callable, seconds: float) -> bool:
	var deadline := clock + seconds
	while clock < deadline:
		if condition.call(): return true
		await process_frame
	return condition.call()

func run() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.test_mode = true
	main.sound_enabled = false
	main.preferred_game = "twisted"
	main.session.select_game("twisted")
	main._show_menu()
	main.name_field.text = "LEGACY"
	main._open_join()
	main.address_field.text = "127.0.0.1"
	main.port_field.text = str(port)
	main._join()
	if not await until(func(): return main.view == "lobby", 20.0): fail("The 0.2.0 guest reaches the lobby")
	# Whatever the host plays first, this build must not be launched into it.
	if not await until(func(): return main.view == "game", 80.0): fail("The 0.2.0 guest is launched into a round")
	if main.play.ID != "twisted" or main.session.game != "twisted":
		fail("The first round this build plays must be Spin Cycle, was %s" % main.play.ID)
	if not await until(func(): return main.view == "lobby", 20.0): fail("Back to the lobby")
	print("PACK_LEGACY_PASS sat-out-unknown-game played-builtin")
	await until(func(): return main.session.mode == "offline", 20.0)
	quit(0)
