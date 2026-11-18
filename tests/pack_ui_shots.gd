extends SceneTree
## Screenshots of the game-pack UI, for review. Needs a display:
##   python3 tools/build.py --pack example
##   mkdir -p /tmp/gj-shots/dev-games && cp builds/packs/example-*.pck /tmp/gj-shots/dev-games/example.pck
##   xvfb-run -a .tools/Godot_v4.5.1-stable_linux.x86_64 --path . --audio-driver Dummy \
##       --script tests/pack_ui_shots.gd -- --packs-dir=/tmp/gj-shots --dev-mode
## Writes test-output/packs-*.png: the menu with a developer pack, the
## developer-mode warning, the consent question, a lobby with members in
## different states, and an example round.

var main: Node

func _initialize() -> void:
	call_deferred("run")

func shot(filename: String) -> void:
	await create_timer(0.6).timeout
	await RenderingServer.frame_post_draw
	# Once a pack is loaded res:// reads from packs, so write by real path.
	var folder := ProjectSettings.globalize_path("res://").path_join("test-output")
	DirAccess.make_dir_recursive_absolute(folder)
	root.get_texture().get_image().save_png(folder.path_join("packs-" + filename + ".png"))
	print("shot ", filename)

func run() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.test_mode = true
	main.set_motion_speed(1.0)
	main.name_field.text = "TIM"
	main._select_game("example")
	await shot("menu")
	main.dev_mode = false
	main._toggle_dev_mode()
	await shot("dev-warning")
	main._clear_overlay()
	main.dev_mode = true
	main._show_menu()
	main._ask_consent("sumo", "ab".repeat(32), "SUMO", "BOLT")
	await shot("consent")
	main.pending_consent = {}
	main._clear_overlay()
	main._open_host()
	main.port_field.text = "47931"
	main._host()
	# Pretend three guests in different states for the chips.
	var fake := [[101, "NOVA", 1, {"build": 3, "legacy": false, "games": {}}, {"game": "example", "state": "downloading", "progress": 42}],
		[102, "ECHO", 2, {"build": 0, "legacy": true, "games": {}}, {}],
		[103, "FLUX", 3, {"build": 3, "legacy": false, "games": {"example": {"net": 1, "sha256": main.games["example"].main.session.party_games()["example"].sha256, "trust": "untrusted"}}}, {}]]
	for f in fake:
		main.session.members.append({"peer": f[0], "name": f[1], "slot": f[2]})
		main.session.caps[f[0]] = f[3]
		if not f[4].is_empty(): main.session.states[f[0]] = f[4]
	main.session.select_game("example")
	main._show_lobby()
	await shot("lobby")
	main.session.members = main.session.members.slice(0, 1)
	main.session.caps.clear()
	main.session.states.clear()
	main.session.start_round()
	main.model.countdown = 0.2
	await create_timer(3.0).timeout
	for i in 4:
		main.session.send_input("jump", true)
		await create_timer(0.1).timeout
		main.session.send_input("jump", false)
		await create_timer(0.4).timeout
	await shot("round")
	main.model.elapsed = 29.9
	await create_timer(3.0).timeout
	await shot("results")
	main._leave()
	quit(0)
