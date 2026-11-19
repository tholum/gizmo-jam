extends SceneTree
## Low (as it runs on a GPU such as a Raspberry Pi) against High on one frozen
## frame of a Spin Cycle round, both at full 3D resolution so what differs is
## the look, not the pixel count: baked light and fog against the engine's, the
## robot mesh, MSAA and silhouette shadows. Saves high.png, low.png and a x4
## difference image under test-output/low-vs-high/ and prints `LVH {json}`.
##
##   xvfb-run -a godot --path . --audio-driver Dummy --script tests/low_vs_high.gd

var resolution := Vector2i(1280, 720)

func _initialize() -> void:
	run.call_deferred()

func shot() -> Image:
	for i in 3: await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func run() -> void:
	root.size = resolution
	DirAccess.make_dir_recursive_absolute("res://test-output/low-vs-high")
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.test_mode = true
	main.sound_enabled = false
	main.arena.software = false
	main.graphics_level = "high"
	main._apply_graphics()
	main.preferred_game = "twisted"
	main.session.select_game("twisted")
	main.session.solo("PLAYER ONE")
	main.session.start_round()
	main.model.begin(74219, main.model.players.duplicate(true), main.model.round_id)
	await process_frame
	main.model.countdown = 0.0
	main.model.phase = "running"
	for p in main.model.players: p.bot = true
	await create_timer(1.5).timeout
	main.set_process(false)
	main.set_physics_process(false)
	var arena: Node3D = main.arena
	arena.set_process(false)
	for r in arena.runners:
		if r.visual.anim: r.visual.anim.speed_scale = 0.0
	for p in arena.find_children("*", "CPUParticles3D", true, false):
		p.visible = false
	var high: Image = await shot()
	main.graphics_level = "low"
	main._apply_graphics()
	# Full resolution, but still through scripts/scaled_view.gd (whose stretch
	# pass also draws Low's HUD shade bands).
	main.scaled_view.set_scale(0.9999)
	for p in arena.find_children("*", "CPUParticles3D", true, false):
		p.visible = false
	var low: Image = await shot()
	high.save_png("res://test-output/low-vs-high/high.png")
	low.save_png("res://test-output/low-vs-high/low.png")
	var diff := Image.create(resolution.x, resolution.y, false, Image.FORMAT_RGB8)
	var total := 0.0
	var signed := Vector3.ZERO
	for y in resolution.y:
		for x in resolution.x:
			var a := high.get_pixel(x, y)
			var b := low.get_pixel(x, y)
			var d := Vector3(b.r - a.r, b.g - a.g, b.b - a.b) * 255.0
			signed += d
			total += (absf(d.x) + absf(d.y) + absf(d.z)) / 3.0
			diff.set_pixel(x, y, Color(minf(absf(d.x) * 4.0 / 255.0, 1.0), minf(absf(d.y) * 4.0 / 255.0, 1.0), minf(absf(d.z) * 4.0 / 255.0, 1.0)))
	diff.save_png("res://test-output/low-vs-high/diff_x4.png")
	var n := float(resolution.x * resolution.y)
	print("LVH ", JSON.stringify({"mean_abs": snappedf(total / n, 0.01),
		"mean_signed_rgb": [snappedf(signed.x / n, 0.01), snappedf(signed.y / n, 0.01), snappedf(signed.z / n, 0.01)]}))
	quit()
