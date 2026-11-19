extends SceneTree
## Times every step of a bot round of one game's model alone (no rendering),
## and prints the slowest steps with the round clock: `STEP {json}`. Shows
## whether a hitch is the simulation's (CPU, GDScript) or the renderer's.
##   godot --headless --path . --script tests/model_step_trace.gd -- --game=livewire --secs=60

func _initialize() -> void:
	var game := "livewire"
	var secs := 60.0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--game="): game = arg.trim_prefix("--game=")
		if arg.begins_with("--secs="): secs = float(arg.trim_prefix("--secs="))
	var Model = load("res://scripts/livewire_model.gd" if game == "livewire" else "res://scripts/round_model.gd")
	var model: RefCounted = Model.new()
	var seats: Array = []
	for i in 6: seats.append({"peer": 0, "name": "BOT%d" % i, "bot": true})
	model.begin(74219, seats, 1)
	model.countdown = 0.0
	model.phase = "running"
	var steps: Array = []
	var t := 0.0
	while t < secs and model.phase == "running":
		var before := Time.get_ticks_usec()
		model.step(1.0 / 30.0)
		steps.append([(Time.get_ticks_usec() - before) / 1000.0, snappedf(float(model.elapsed), 0.01)])
		t += 1.0 / 30.0
	var ms: Array = steps.map(func(s): return s[0])
	ms.sort()
	steps.sort_custom(func(a, b): return a[0] > b[0])
	print("STEP ", JSON.stringify({"steps": steps.size(), "median_ms": snappedf(ms[ms.size() / 2], 0.01), "p99_ms": snappedf(ms[int(ms.size() * 0.99)], 0.01),
		"slowest": steps.slice(0, 8).map(func(s): return "%.1fms@%.2fs" % [s[0], s[1]])}))
	quit()
