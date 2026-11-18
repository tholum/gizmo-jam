extends SceneTree
## Throwaway art QA: one robot filling the frame, front / side / back, a few clips.
const Kit = preload("res://scripts/arena_kit.gd")
func _initialize() -> void: call_deferred("run")
func shot(name_value: String) -> void:
	for i in 3: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://test-output/closeups/" + name_value + ".png")
func run() -> void:
	root.size = Vector2i(1500, 900)
	DirAccess.make_dir_recursive_absolute("res://test-output/closeups")
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.test_mode = true
	main.sound_enabled = false
	main.arena.set_detail("--high" in OS.get_cmdline_user_args())
	main.session.solo("PLAYER ONE")
	main.session.start_round()
	main.model.countdown = 0.0
	main.model.phase = "running"
	await create_timer(0.4).timeout
	main.set_physics_process(false)
	main.set_process(false)
	main.canvas.visible = false
	main.arena.hud_shade.visible = false
	main.model.waves = []
	for i in 4: main.arena.update_visuals(main.model, 0.033)
	var cam := Camera3D.new()
	main.arena.add_child(cam)
	cam.fov = 28.0
	cam.current = true
	var views := {"front": Vector3(4.2, 1.3, 5.2), "back": Vector3(-4.2, 1.5, 5.2), "side": Vector3(0.6, 1.2, 12.5)}
	for name_value in views:
		cam.position = views[name_value]
		cam.look_at(Vector3(0, 0.62, 5.2))
		await shot("hero-" + name_value)
	cam.position = views["front"]
	cam.look_at(Vector3(0, 0.62, 5.2))
	for p in main.model.players: p.duck = true
	for i in 12: main.arena.update_visuals(main.model, 0.033)
	await shot("hero-duck")
	for p in main.model.players:
		p.duck = false
		p.jump = 0.3
	for i in 3: main.arena.update_visuals(main.model, 0.033)
	cam.look_at(Vector3(0, 1.4, 5.2))
	await shot("hero-jump")
	quit()
