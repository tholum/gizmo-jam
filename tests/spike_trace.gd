extends SceneTree
## Hitch hunter: plays a bot round (Spin Cycle's bots cannot lose, so it runs
## the whole time) and prints every frame that takes more than twice the median,
## with what changed since the frame before: rods, runners knocked out, scene
## objects, draw calls, script time, nodes, and the round clock. Also prints a
## `SPIKES {json}` summary.
##
## Arguments (after `--`): --game=twisted|livewire  --level=low  --size=WxH  --secs=20

var game := "twisted"
var level := "low"
var resolution := Vector2i(1280, 720)
var secs := 20.0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--game="): game = arg.trim_prefix("--game=")
		if arg.begins_with("--level="): level = arg.trim_prefix("--level=")
		if arg.begins_with("--secs="): secs = float(arg.trim_prefix("--secs="))
		if arg.begins_with("--size="):
			var parts := arg.trim_prefix("--size=").split("x")
			resolution = Vector2i(int(parts[0]), int(parts[1]))
	run.call_deferred()

func state(main: Node) -> Dictionary:
	var m: RefCounted = main.model
	var d := {
		"t": snappedf(float(m.elapsed), 0.01),
		"objects": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		"draws": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"objs_alive": Performance.get_monitor(Performance.OBJECT_COUNT),
		"process_ms": snappedf(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, 0.1),
		"physics_ms": snappedf(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, 0.1),
		"vmem_mb": snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1),
	}
	if "waves" in m: d["waves"] = m.waves.size()
	if "speed" in m: d["speed"] = snappedf(float(m.speed), 0.01)
	return d

func run() -> void:
	root.size = resolution
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.test_mode = true
	main.sound_enabled = false
	main.graphics_level = level
	main._apply_graphics()
	main.preferred_game = game
	main.session.select_game(game)
	main.session.solo("PLAYER ONE")
	main.session.start_round()
	main.model.begin(74219, main.model.players.duplicate(true), main.model.round_id)
	await process_frame
	main.model.countdown = 0.0
	main.model.phase = "running"
	for p in main.model.players: p.bot = true
	var frames: Array = []
	var deadline := Time.get_ticks_msec() + int(secs * 1000.0)
	var prev := state(main)
	while Time.get_ticks_msec() < deadline:
		if game == "twisted":
			for p in main.model.players: p.hp = 1000
		elif float(main.model.elapsed) > 80.0:
			main.model.elapsed = 20.0
		var before := Time.get_ticks_usec()
		await process_frame
		var ms := (Time.get_ticks_usec() - before) / 1000.0
		var now := state(main)
		frames.append({"ms": ms, "now": now, "prev": prev})
		prev = now
	var sorted: Array = frames.map(func(f): return f.ms)
	sorted.sort()
	var median: float = sorted[sorted.size() / 2]
	var spikes := 0
	for i in frames.size():
		var f: Dictionary = frames[i]
		if i < 5 or f.ms < median * 2.0: continue
		spikes += 1
		var changed := {}
		for k in f.now:
			if f.now[k] != f.prev[k]: changed[k] = "%s->%s" % [f.prev[k], f.now[k]]
		print("SPIKE %.1fms (median %.1f) frame %d: %s" % [f.ms, median, i, JSON.stringify(changed)])
	print("SPIKES ", JSON.stringify({"frames": frames.size(), "median_ms": snappedf(median, 0.1), "spikes": spikes,
		"p99_ms": snappedf(sorted[int(sorted.size() * 0.99)], 0.1), "max_ms": snappedf(sorted[-1], 0.1)}))
	quit()
