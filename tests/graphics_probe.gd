extends SceneTree
## Render a repeatable round, exercise inputs, and record frame/resource costs.
##
## Arguments (after `--`):
##   --iteration=<name>   output folder under test-output/iterations/
##   --level=low|balanced|high   graphics quality (default balanced)
##   --high               same as --level=high
##   --size=WxH           window size (default 1440x900)
##   --default-window     same as --size=1280x800
##   --game=twisted|livewire   which game's round to measure (default twisted);
##                        Live Wire stops after the timing and the results shot
var main: Node
var frames: Array[float] = []
var iteration := "current"
var baseline := false
var resolution := Vector2i(1440, 900)
var level := "balanced"
var game := "twisted"

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--iteration="): iteration = arg.trim_prefix("--iteration=")
		if arg == "--baseline": baseline = true
		if arg == "--default-window": resolution = Vector2i(1280, 800)
		if arg == "--high": level = "high"
		if arg.begins_with("--level="): level = arg.trim_prefix("--level=").to_lower()
		if arg.begins_with("--game="): game = arg.trim_prefix("--game=")
		if arg.begins_with("--size="):
			var parts := arg.trim_prefix("--size=").split("x")
			resolution = Vector2i(int(parts[0]), int(parts[1]))
	call_deferred("run")

func capture(name_value: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://test-output/iterations/" + iteration + "/" + name_value + ".png")

func run() -> void:
	root.size = resolution
	DirAccess.make_dir_recursive_absolute("res://test-output/iterations/" + iteration)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.test_mode = true
	main.sound_enabled = false
	main.graphics_level = level
	main._apply_graphics()
	# Whatever this machine's settings file says, the probe measures `game`.
	main.preferred_game = game
	main.session.select_game(game)
	main._show_menu()
	await create_timer(0.5).timeout
	await capture("menu")
	main.session.solo("PLAYER ONE")
	main.session.start_round()
	main.model.begin(74219, main.model.players.duplicate(true), main.model.round_id)
	await process_frame
	main.model.countdown = 0.0
	main.model.phase = "running"
	for p in main.model.players: p.bot = true
	await create_timer(1.0).timeout
	await capture("game")
	# Time the round as it runs for a player: the root draws straight to the
	# screen when it can (scripts/scaled_view.gd), which only captures forbid.
	main.scaled_view.force_direct = true
	# The captures above ran without it, slower, and may have lowered the
	# dynamic scale; start from the round's starting scale, as a round does.
	main.scaled_view.restore()
	var deadline := Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline:
		var before := Time.get_ticks_usec()
		await process_frame
		frames.append((Time.get_ticks_usec() - before) / 1000.0)
	main.scaled_view.force_direct = false
	frames.sort()
	var mean := 0.0
	for value in frames: mean += value
	mean /= frames.size()
	var stats := {"frames": frames.size(), "mean_ms": mean, "p95_ms": frames[int(frames.size() * 0.95)], "p99_ms": frames[int(frames.size() * 0.99)], "fps": 1000.0 / mean,
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"rendering_driver": RenderingServer.get_current_rendering_method(),
		"adapter": RenderingServer.get_video_adapter_name(), "resolution": "%dx%d" % [resolution.x, resolution.y], "quality": level.capitalize(),
		"render_scale": main.scaled_view.scale if main.scaled_view and main.scaled_view.enabled() else root.scaling_3d_scale, "window": "%dx%d" % [root.size.x, root.size.y], "game": game}
	var file := FileAccess.open("res://test-output/iterations/" + iteration + "/performance.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(stats, "\t") + "\n")
	print("GRAPHICS_PROBE ", JSON.stringify(stats))
	if game == "livewire":
		main.model.elapsed = 89.7
		for i in 600:
			await process_frame
			if main.view == "results": break
		await create_timer(0.4).timeout
		await capture("results")
		quit()
		return
	# Freeze simulation to inspect distinct action and feedback poses without
	# including capture overhead in the measurement above.
	main.set_physics_process(false)
	main.set_process(false)
	main.damage_shade.visible = false
	main.feedback_time = 0.0
	main.play.last_hp = 7
	main.play.last_score = 0
	for r in main.arena.runners:
		r.hp = 7
		r.score = 0
	main.model.waves = [{"id":200,"at":main.model.progress + 0.55,"kind":"jump","done":false}]
	for p in main.model.players:
		p.jump = -1.0
		p.duck = false
		p.flash = 0.0
		p.hp = 7
		p.score = 0
	main.model.players[0].jump = 0.30
	main.arena.update_visuals(main.model, 0.033)
	main._update_hud()
	await capture("jump")
	main.model.players[0].jump = -1.0
	main.model.players[0].duck = true
	main.model.waves[0].kind = "duck"
	for i in 10: main.arena.update_visuals(main.model, 0.033)
	main._update_hud()
	await capture("duck")
	main.model.players[0].duck = false
	main.model.players[0].hp = 6
	main.model.players[0].flash = 0.42
	main.arena.update_visuals(main.model, 0.033)
	main._update_hud()
	main._process(0.0)
	await capture("hit")
	for p in main.model.players:
		p.hp = 0
		p.out_at = main.model.elapsed
	main.model.players[0].hp = 6
	main.model.players[0].out_at = -1.0
	main.model.players[0].score = 10
	main.model.players[0].best_streak = 8
	main.model.phase = "finished"
	main._show_results()
	main.arena.update_visuals(main.model, 0.033)
	await capture("results")
	quit()
