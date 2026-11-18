extends SceneTree
## Automated production-input playthrough. This is not a human feel test.
## Spin Cycle: two natural rounds and a max-speed drill. Live Wire: one full
## solo round against five bots, steered by an autopilot that only ever presses
## W A S D and Space through the production key handler. `-- --only=livewire`
## runs just that round.
const LIVE_KEYS := {KEY_W: Vector2(0, -1), KEY_S: Vector2(0, 1), KEY_A: Vector2(-1, 0), KEY_D: Vector2(1, 0)}
var main: Node
## Live Wire trial: keys the autopilot is holding, and what it has seen so far.
var live := false
var live_down: Dictionary = {}
var live_goal := -1
var live_think := 0.0
var live_stats := {"dashes": 0, "tile_changes": 0, "travelled": 0.0}
var live_last := {"tiles": 1, "cool": 0.0, "pos": Vector2.ZERO, "shot": false}
var acted: Dictionary = {}
var rounds: Array = []
var finishing := false
var crossings: Dictionary = {}
var clip_started := false
var clip_tick := 0
var clip_count := 0
var round_index := 0
var drill := false
var trial_elapsed := 0.0
var stage := "round"
var output := "res://test-output/iterations/4/playthrough"

func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	root.size = Vector2i(1440, 900)
	DirAccess.make_dir_recursive_absolute(output + "/clip")
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.test_mode = true
	main.sound_enabled = false
	main.arena.set_detail(true)
	# Whatever this machine's settings file says, the run starts on Spin Cycle.
	main.preferred_game = "twisted"
	main.session.select_game("twisted")
	main.session.solo("AUTOPLAY")
	# `-- --only=livewire` skips the three Spin Cycle trials.
	if "--only=livewire" in OS.get_cmdline_user_args():
		round_index = 3
		start_live()
		return
	start_round()

func start_round() -> void:
	acted.clear()
	key(KEY_S, false)
	main.session.start_round()
	main.model.begin(74219 + round_index * 31, main.session.slots(), main.model.round_id, drill)
	if drill:
		main.model.elapsed = 75.0
		main.model.countdown = 0.0
		main.model.phase = "running"
	trial_elapsed = 0.0
	finishing = false

func key(code: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func capture(name_value: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output + "/" + name_value + ".png")

func _process(delta: float) -> bool:
	if not is_instance_valid(main) or not main.model or finishing: return false
	trial_elapsed += delta
	if live:
		live_process(delta)
		return false
	if trial_elapsed > 200.0:
		push_error("Automated round timed out")
		quit(1)
		return false
	if main.model.phase == "running":
		var wave: Dictionary = main.model.next_obstacle()
		if not wave.is_empty():
			var eta: float = (float(wave.at) - main.model.progress) / main.model.speed
			if eta <= 0.29 and not acted.has(wave.id):
				acted[wave.id] = true
				# One intentional first-wave miss in each natural round
				# exercises hit feedback; every later action uses real key events.
				if drill or int(wave.id) != 0:
					key(KEY_S, wave.kind == "duck")
					if wave.kind == "jump":
						key(KEY_SPACE, true)
						key(KEY_SPACE, false)
			if eta > 0 and eta < 0.025 and not crossings.has(wave.kind) and int(wave.id) > 0:
				crossings[wave.kind] = true
				capture(wave.kind + "-crossing")
			if wave.kind == "jump" and eta < 0.32 and int(wave.id) > 0 and not clip_started:
				clip_started = true
		if clip_started and clip_count < 20:
			clip_tick += 1
			if clip_tick % 3 == 0:
				capture("clip/frame%04d" % clip_count)
				clip_count += 1
	if main.model.phase == "finished" or (drill and trial_elapsed >= 30.0):
		finishing = true
		call_deferred("finish_trial")
	return false

func finish_trial() -> void:
	key(KEY_S, false)
	var own: Dictionary = main.model.players[0]
	var data := {"trial":round_index + 1, "type":"overdrive-drill" if drill else "natural-solo-round", "elapsed":main.model.elapsed, "score":own.score, "hp":own.hp, "best_streak":own.best_streak, "speed":main.model.speed}
	rounds.append(data)
	if drill:
		assert(own.hp == 7 and own.score >= 25, "Full-speed production input must clear every drill rod")
	else:
		assert(main.model.winners() == [0] and own.hp == 6 and own.score >= 10, "Autoplay must win a natural round after one deliberate miss")
		if main.view != "results": main._show_results()
		await create_timer(0.35).timeout
		await capture("round%d-results" % (round_index + 1))
	print("PLAYTHROUGH_TRIAL ", JSON.stringify(data))
	round_index += 1
	if round_index == 2: drill = true
	if round_index < 3:
		start_round()
	else:
		start_live()

# ------------------------------------------------------------------ Live Wire

func live_fail(message: String) -> void:
	push_error("Live Wire playthrough: " + message)
	print("PLAYTHROUGH_FAIL " + message)
	quit(1)

## Back to the menu, pick Live Wire the way the card does, and play solo.
func start_live() -> void:
	main.session.lobby()
	if main.view != "menu" or main.model != null: live_fail("Spin Cycle did not hand back the menu")
	main._select_game("livewire")
	if main.session.game != "livewire" or not main.live_arena.active or main.arena.visible:
		live_fail("Picking Live Wire must put the hex floor on stage")
	main.session.start_round()
	main.model.begin(90417, main.session.slots(), main.model.round_id)
	if main.view != "game" or not main.model.has_method("largest_patch"): live_fail("The solo round is not Live Wire")
	live_last.pos = Vector2(main.model.players[0].x, main.model.players[0].z)
	trial_elapsed = 0.0
	finishing = false
	live = true

func live_hold(want: Vector2) -> void:
	for code in LIVE_KEYS:
		var dir: Vector2 = LIVE_KEYS[code]
		var down: bool = (dir.x != 0.0 and signf(want.x) == dir.x) or (dir.y != 0.0 and signf(want.y) == dir.y)
		if down != live_down.get(code, false):
			live_down[code] = down
			key(code, down)

## Where to go next: off a charging line first, else the nearest tile worth painting.
func live_plan(model: RefCounted, pos: Vector2, here: int) -> int:
	var hot: Array = []
	for s in model.surges:
		hot.append(Vector2i(int(s.axis), int(s.line)))
	var danger := false
	for line in hot:
		if model.grid.line_of(here, line.x) == line.y: danger = true
	var best := -1
	var best_cost := INF
	for cell in model.grid.count():
		var on_line := false
		for line in hot:
			if model.grid.line_of(cell, line.x) == line.y: on_line = true
		if on_line: continue
		var owner := int(model.owners[cell])
		if not danger and (owner == 1 or (owner != 0 and model.locks[cell] > 0.0)): continue
		var cost: float = model.grid.centers[cell].distance_to(pos) - (0.4 if owner == 0 else 0.0)
		if cost < best_cost:
			best_cost = cost
			best = cell
	return best

func live_process(delta: float) -> void:
	var model: RefCounted = main.model
	var own: Dictionary = model.players[0]
	if trial_elapsed > 400.0: live_fail("The round never ended (elapsed %.1f, view %s)" % [model.elapsed, main.view])
	if model.phase == "running":
		var pos := Vector2(own.x, own.z)
		var here: int = model.grid.cell_at(pos)
		live_think -= delta
		if live_think <= 0.0 or live_goal < 0 or int(model.owners[live_goal]) == 1:
			live_think = 0.12
			live_goal = live_plan(model, pos, here)
		var to: Vector2 = model.grid.centers[live_goal] - pos if live_goal >= 0 else Vector2.ZERO
		var want := Vector2.ZERO
		if to.length() > 0.1:
			want = Vector2(signf(to.x) if absf(to.x) > 0.414 * absf(to.y) else 0.0, signf(to.y) if absf(to.y) > 0.414 * absf(to.x) else 0.0)
		live_hold(want)
		# Dash whenever it is ready and there is somewhere to go.
		if float(own.cool) <= 0.0 and float(own.stun) <= 0.0 and want != Vector2.ZERO:
			key(KEY_SPACE, true)
			key(KEY_SPACE, false)
		if float(own.cool) > float(live_last.cool) + 1.0: live_stats.dashes += 1
		if int(own.tiles) != int(live_last.tiles): live_stats.tile_changes += 1
		live_stats.travelled += pos.distance_to(live_last.pos)
		live_last.cool = float(own.cool)
		live_last.tiles = int(own.tiles)
		live_last.pos = pos
		if model.elapsed > 45.0 and not live_last.shot:
			live_last.shot = true
			capture("livewire-mid")
	elif model.phase == "finished":
		live_hold(Vector2.ZERO)
	if main.view == "results":
		finishing = true
		call_deferred("finish_live")

func finish_live() -> void:
	var model: RefCounted = main.model
	var own: Dictionary = model.players[0]
	var data := {"trial": round_index + 1, "type": "livewire-solo-round", "elapsed": model.elapsed, "tiles": own.tiles, "rank": model.ranking().find(0) + 1,
		"peak": own.best, "dashes": live_stats.dashes, "tile_changes": live_stats.tile_changes, "travelled": snappedf(live_stats.travelled, 0.1),
		"loops": own.loops, "zaps": own.zaps, "shoves": own.shoves}
	rounds.append(data)
	print("PLAYTHROUGH_TRIAL ", JSON.stringify(data))
	if model.phase != "finished" or model.elapsed != 90.0: live_fail("The round must end at 90 seconds, ended at %.2f" % model.elapsed)
	if live_stats.travelled < 100.0: live_fail("Key events must move the runner (travelled %.1f)" % live_stats.travelled)
	if int(own.best) < 12 or live_stats.tile_changes < 40: live_fail("Running must paint tiles and change the score (peak %d, %d changes)" % [own.best, live_stats.tile_changes])
	if live_stats.dashes < 5: live_fail("Space must dash (%d dashes)" % live_stats.dashes)
	if not main.play.sent.is_empty(): live_fail("Keys were still held on the results screen")
	if not main.live_arena.active or main.arena.visible: live_fail("The results must sit on the hex floor")
	await create_timer(0.35).timeout
	await capture("livewire-results")
	for code in LIVE_KEYS:
		key(code, false)
	var file := FileAccess.open(output + "/results.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"automated":true,"input_path":"Input.parse_input_event -> production keyboard handling","trials":rounds},"\t") + "\n")
	print("PLAYTHROUGH_PASS %slivewire-solo-round production-key-events" % ("two-natural-rounds overdrive-drill " if rounds.size() == 4 else ""))
	quit()
