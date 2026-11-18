extends SceneTree
## Throwaway art QA: staged poses from the game camera and a close camera.
## Usage: godot --path . --script tools/art-probe/closeup.gd -- [--high] [--out=name]
var main: Node
var out := "closeups"
var high := false

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--high": high = true
		if arg.begins_with("--out="): out = arg.trim_prefix("--out=")
	call_deferred("run")

func shot(name_value: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://test-output/%s/%s.png" % [out, name_value])

func close_camera(at: Vector3, from: Vector3, fov: float = 30.0) -> Camera3D:
	var cam := Camera3D.new()
	main.arena.add_child(cam)
	cam.position = from
	cam.look_at(at)
	cam.fov = fov
	cam.current = true
	return cam

func stage(setup: Callable, steps: int = 12) -> void:
	for p in main.model.players:
		p.jump = -1.0
		p.duck = false
		p.flash = 0.0
		p.hp = 7
	for r in main.arena.runners:
		r.hp = 7
		r.out = -1.0
	setup.call()
	for i in steps: main.arena.update_visuals(main.model, 0.033)
	main._update_hud()

func run() -> void:
	root.size = Vector2i(1280, 800)
	DirAccess.make_dir_recursive_absolute("res://test-output/" + out)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.test_mode = true
	main.sound_enabled = false
	main.graphics_level = "high" if high else "balanced"
	main.arena.set_detail(high)
	main._show_menu()
	await create_timer(0.8).timeout
	await shot("menu")
	main.session.solo("PLAYER ONE")
	main.session.start_round()
	main.model.begin(74219, main.model.players.duplicate(true), main.model.round_id)
	await process_frame
	await shot("countdown")
	main.model.countdown = 0.0
	main.model.phase = "running"
	for p in main.model.players: p.bot = true
	await create_timer(1.2).timeout
	await shot("game")
	main.set_physics_process(false)
	main.set_process(false)
	main.damage_shade.visible = false
	var progress: float = main.model.progress
	var wide := close_camera(Vector3(0.2, 0.7, 5.2), Vector3(7.5, 2.6, 8.8), 34.0)
	var cams := {"": null, "close-": wide}
	for prefix in cams:
		if cams[prefix]: cams[prefix].current = true
		else: main.arena.camera.current = true
		stage(func(): main.model.waves = [{"id": 300, "at": progress + 1.0, "kind": "jump", "done": false}])
		await shot(prefix + "run")
		stage(func():
			main.model.waves = [{"id": 301, "at": progress + 0.02, "kind": "jump", "done": false}]
			for i in 6: main.model.players[i].jump = 0.34 if i != 3 else -1.0
			main.model.players[5].jump = 0.12)
		await shot(prefix + "jump")
		stage(func():
			main.model.waves = [{"id": 302, "at": progress + 0.02, "kind": "duck", "done": false}]
			for i in 6: main.model.players[i].duck = i != 3)
		await shot(prefix + "duck")
		stage(func():
			main.model.waves = [{"id": 303, "at": progress - 0.12, "kind": "duck", "done": true}]
			main.model.players[0].hp = 6
			main.model.players[0].flash = 0.42
			main.model.players[2].hp = 6
			main.model.players[2].flash = 0.42, 5)
		await shot(prefix + "hit")
		stage(func():
			main.model.waves = [{"id": 304, "at": progress - 0.2, "kind": "jump", "done": true}]
			main.model.players[4].hp = 0, 14)
		await shot(prefix + "knockout")
	main.arena.camera.current = true
	for p in main.model.players:
		p.hp = 0
		p.out_at = main.model.elapsed
	main.model.players[0].hp = 6
	main.model.players[0].out_at = -1.0
	main.model.players[0].score = 10
	main.model.phase = "finished"
	main._show_results()
	for i in 20: main.arena.update_visuals(main.model, 0.033)
	await create_timer(0.6).timeout
	await shot("results")
	print("CLOSEUP_DONE")
	quit()
