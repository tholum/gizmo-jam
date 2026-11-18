extends SceneTree
## Two actual ENet peers routed through a delay/loss UDP proxy by run_latency.py.
const Network = preload("res://scripts/session.gd")
const Model = preload("res://scripts/round_model.gd")
var session: Node
var model: RefCounted
var role := "host"
var server_port := 17777
var clock := 0.0
var trial_clock := 0.0
var snapshot_clock := 0.0
var last_snapshot := 0.0
var received := 0
var acted: Dictionary = {}
var ending := false
var ending_clock := 0.0
func _initialize() -> void:
	Engine.max_fps = 120
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--role="): role = arg.get_slice("=", 1)
		if arg.begins_with("--port="): server_port = int(arg.get_slice("=", 1))
	call_deferred("run")
func run() -> void:
	var main := Node.new()
	main.name = "Main"
	root.add_child(main)
	session = Network.new()
	session.name = "Session"
	main.add_child(session)
	session.failed.connect(func(message): fail(message))
	session.roster_changed.connect(func():
		if role == "host" and session.members.size() == 2 and session.round_number == 0: session.start_round())
	session.round_started.connect(launched)
	session.input_received.connect(func(slot, action, pressed):
		if model: model.command(slot, action, pressed))
	session.snapshot_received.connect(snapshot)
	var error: Error = session.host_game("SERVER", server_port) if role == "host" else session.join_game("DELAYED CLIENT", "127.0.0.1", server_port)
	if error != OK: fail("Could not open ENet peer")
func launched(seed_value: int, seats: Array, number: int) -> void:
	model = Model.new()
	model.begin(18823, seats, number, true)
	model.elapsed = 75.0
	model.countdown = 0.0
	model.phase = "running"
	for i in model.players.size(): model.players[i].bot = i != 1
	trial_clock = 0.0
func snapshot(data: Dictionary) -> void:
	if not model: return
	model.apply_snapshot(data)
	last_snapshot = clock
	received += 1
	if float(data.elapsed) >= 96.5:
		var p: Dictionary = data.players[session.my_slot()]
		if p.hp < 6 or p.score < 20: fail("Delayed client cleared too few rods: " + str(p))
		else:
			print("CLIENT_LATENCY_PASS ", JSON.stringify({"hp":p.hp,"score":p.score,"snapshots":received,"speed":data.speed,"elapsed":data.elapsed}))
			quit()
func _physics_process(delta: float) -> bool:
	if role == "host" and model and not ending: model.step(delta)
	return false
func _process(delta: float) -> bool:
	clock += delta
	if clock > 35: fail("Latency case timed out")
	if not model: return false
	trial_clock += delta
	if role == "host":
		snapshot_clock += delta
		if snapshot_clock >= 0.05:
			snapshot_clock = 0
			session.send_snapshot(model.snapshot())
		if not ending and trial_clock >= 22.0:
			var p: Dictionary = model.players[1]
			if p.hp < 6 or p.score < 20: fail("Authoritative score failed: " + str(p))
			print("SERVER_LATENCY_PASS ", JSON.stringify({"hp":p.hp,"score":p.score,"elapsed":model.elapsed,"speed":model.speed}))
			ending = true
		if ending:
			ending_clock += delta
			if ending_clock >= 1.0: quit()
	elif received > 0 and model.phase == "running":
		var wave: Dictionary = model.next_obstacle()
		if not wave.is_empty():
			var predicted_progress: float = model.progress + (clock - last_snapshot) * model.speed
			var eta: float = (float(wave.at) - predicted_progress) / model.speed
			if eta <= 0.40 and not acted.has(wave.id):
				acted[wave.id] = true
				session.send_input("duck", wave.kind == "duck")
				if wave.kind == "jump": session.send_input("jump", true)
	return false
func fail(message: String) -> void:
	push_error(message)
	quit(1)
