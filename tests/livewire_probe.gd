extends SceneTree
## Live Wire renderer probe: staged screenshots, a few seconds of fake play,
## frame timings and a numeric check of the position smoothing.
##
##   xvfb-run -a $G --path . --audio-driver Dummy --script res://tests/livewire_probe.gd
##
## Options (after `--`): --high (detail on), --quick (screenshots only),
## --no-compare (skip timing the spiral arena), --out=<name> (sub-folder of
## test-output/livewire).
## It never loads livewire_model.gd: the arena is fed a stand-in state with the
## same contract fields, built on the real livewire_grid.gd.

const LiveArena = preload("res://scripts/livewire_arena.gd")
const SpiralArena = preload("res://scripts/arena.gd")
const Grid = preload("res://scripts/livewire_grid.gd")

class FakeState extends RefCounted:
	const GRID_RADIUS := 7
	const HEX_SIZE := 0.9
	const DURATION := 90.0
	const CHARGED_AT := 30.0
	const OVERDRIVE_AT := 70.0
	const MOVE_SPEED := 4.4
	const DASH_SPEED := 11.0
	const DASH_TIME := 0.22
	const DASH_COOLDOWN := 2.5
	const SHOVE_TIME := 0.35
	const LOCK_TIME := 10.0
	const SURGE_WARN := 1.6
	const SURGE_FIRE := 0.45
	const STUN_TIME := 1.3
	var grid: RefCounted
	var owners := PackedByteArray()
	var locks := PackedFloat32Array()
	var surges: Array = []
	var players: Array = []
	var phase := "running"
	var countdown := 0.0
	var elapsed := 0.0
	var round_id := 1
	func stage() -> int:
		return 0 if elapsed < CHARGED_AT else (1 if elapsed < OVERDRIVE_AT else 2)
	func remaining() -> float:
		return maxf(0.0, DURATION - elapsed)

const NAMES := ["BOLT", "NOVA", "ECHO", "FLUX", "PIXEL", "COMET"]

var arena_script: GDScript = LiveArena
var arena: Node3D
var grid: RefCounted
var rng := RandomNumberGenerator.new()
var out_dir := "res://test-output/livewire"
var high_quality := false
var compare := true
var quick := false
var resolution := Vector2i(1440, 900)
var bands: CanvasLayer
var update_usec := 0
var update_calls := 0
var run_cpu_ms := 0.0
var next_surge := 100
# Fake play.
var goals: Array = []
var dash_clock: Array = []
var surge_clock := 0.0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--high": high_quality = true
		if arg == "--no-compare": compare = false
		if arg == "--quick": quick = true
		if arg.begins_with("--out="): out_dir += "/" + arg.trim_prefix("--out=")
	call_deferred("run")

# ------------------------------------------------------------------- helpers

func new_state(round_id: int) -> FakeState:
	var state := FakeState.new()
	state.grid = grid
	state.round_id = round_id
	state.owners.resize(grid.count())
	state.locks.resize(grid.count())
	for i in 6:
		var a := TAU * i / 6.0 + PI / 6.0
		var at := Vector2(sin(a), cos(a)) * 6.2
		state.players.append({"name": NAMES[i], "peer": 0, "bot": i > 0, "x": at.x, "z": at.y,
			"face": a + PI, "speed": 0.0, "stun": 0.0, "shove": 0.0, "dash": 0.0, "cool": 0.0,
			"tiles": 0, "best": 0, "loops": 0, "zaps": 0, "shoves": 0})
	return state

func hex_distance(a: Vector2i, b: Vector2i) -> int:
	var d := a - b
	return maxi(maxi(absi(d.x), absi(d.y)), absi(d.x + d.y))

## Grows six blobs from the runners' tiles until `fill` of the board is owned.
func paint_blobs(state: FakeState, fill: float) -> void:
	var frontier: Array = []
	for i in 6:
		var cell: int = grid.cell_at(Vector2(state.players[i].x, state.players[i].z))
		state.owners[cell] = i + 1
		frontier.append([cell])
	var wanted := int(grid.count() * fill)
	var owned := 6
	var guard := 0
	while owned < wanted and guard < 20000:
		guard += 1
		var seat := rng.randi_range(0, 5)
		var edge: Array = frontier[seat]
		if edge.is_empty():
			continue
		var from: int = edge[rng.randi_range(0, edge.size() - 1)]
		var near: PackedInt32Array = grid.neighbors[from]
		var to := near[rng.randi_range(0, near.size() - 1)]
		if state.owners[to] == 0:
			state.owners[to] = seat + 1
			edge.append(to)
			owned += 1

func lock_patch(state: FakeState, seat: int, centre: Vector2i, reach: int, seconds: float) -> void:
	for i in grid.count():
		if hex_distance(grid.cells[i], centre) <= reach:
			state.owners[i] = seat + 1
			state.locks[i] = seconds

func put(state: FakeState, seat: int, cell: Vector2i, face: float = 0.0) -> void:
	var at: Vector2 = grid.center_of(cell)
	state.players[seat].x = at.x
	state.players[seat].z = at.y
	state.players[seat].face = face

func count_tiles(state: FakeState) -> void:
	for p in state.players:
		p.tiles = 0
	for owner_id in state.owners:
		if owner_id > 0:
			state.players[owner_id - 1].tiles += 1

func show(state: RefCounted, delta: float, own_slot: int = 0) -> void:
	var before := Time.get_ticks_usec()
	arena.update_visuals(state, delta, own_slot)
	update_usec += Time.get_ticks_usec() - before
	update_calls += 1

## Advances the visuals without the state changing (lets eases and flashes run).
func settle(state: RefCounted, seconds: float, own_slot: int = 0) -> void:
	var steps := int(ceil(seconds * 60.0))
	for n in steps:
		show(state, 1.0 / 60.0, own_slot)

func capture(name_value: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out_dir + "/" + name_value + ".png")
	print("LIVEWIRE_SHOT ", name_value)

func busy_board(round_id: int) -> FakeState:
	rng.seed = 90210
	var state := new_state(round_id)
	state.elapsed = 41.0
	put(state, 0, Vector2i(-3, 1), 2.2)
	put(state, 1, Vector2i(3, -5), 0.5)
	put(state, 2, Vector2i(5, -1), -1.2)
	put(state, 3, Vector2i(2, 4), 3.0)
	put(state, 4, Vector2i(-3, 5), 1.0)
	put(state, 5, Vector2i(-5, -1), -2.0)
	paint_blobs(state, 0.74)
	lock_patch(state, 1, Vector2i(3, -5), 1, 8.4)
	lock_patch(state, 3, Vector2i(3, 3), 1, 5.0)
	lock_patch(state, 0, Vector2i(-4, 2), 1, 1.6)
	for p in state.players:
		p.speed = 4.4
	state.players[4].speed = 0.0
	count_tiles(state)
	return state

# ----------------------------------------------------------------- fake play

func play_setup(state: FakeState) -> void:
	goals.clear()
	dash_clock.clear()
	for i in 6:
		goals.append(Vector2(state.players[i].x, state.players[i].z))
		dash_clock.append(1.0 + i * 0.7)
	surge_clock = 0.6

## A stand-in for the simulation, good enough to judge motion and timing.
func play_step(state: FakeState, delta: float) -> void:
	state.elapsed += delta
	for i in grid.count():
		if state.locks[i] > 0.0:
			state.locks[i] = maxf(state.locks[i] - delta, 0.0)
	for i in 6:
		var p: Dictionary = state.players[i]
		p.stun = maxf(p.stun - delta, 0.0)
		p.shove = maxf(p.shove - delta, 0.0)
		p.dash = maxf(p.dash - delta, 0.0)
		if p.stun > 0.0:
			p.speed = 0.0
			continue
		var at := Vector2(p.x, p.z)
		if at.distance_to(goals[i]) < 0.25:
			goals[i] = grid.centers[rng.randi_range(0, grid.count() - 1)]
		dash_clock[i] -= delta
		if dash_clock[i] <= 0.0:
			dash_clock[i] = 3.2
			p.dash = FakeState.DASH_TIME
		var want: Vector2 = (goals[i] - at).normalized()
		var pace := FakeState.DASH_SPEED if p.dash > 0.0 else FakeState.MOVE_SPEED
		at += want * pace * delta
		p.x = at.x
		p.z = at.y
		p.face = atan2(want.x, want.y)
		p.speed = pace
		var cell: int = grid.cell_at(at)
		if cell >= 0 and (state.locks[cell] <= 0.0 or state.owners[cell] == i + 1):
			state.owners[cell] = i + 1
	surge_clock -= delta
	if surge_clock <= 0.0:
		surge_clock = 1.1 if state.stage() == 2 else 2.4
		next_surge += 1
		state.surges.append({"id": next_surge, "axis": rng.randi_range(0, 2), "line": rng.randi_range(-6, 6),
			"warn": FakeState.SURGE_WARN, "fire": FakeState.SURGE_FIRE})
	for surge in state.surges.duplicate():
		if surge.warn > 0.0:
			surge.warn = maxf(surge.warn - delta, 0.0)
			continue
		surge.fire -= delta
		for i in 6:
			var p: Dictionary = state.players[i]
			var cell: int = grid.cell_at(Vector2(p.x, p.z))
			if cell >= 0 and p.stun <= 0.0 and grid.line_of(cell, surge.axis) == surge.line and not surge.has("hit%d" % i):
				surge["hit%d" % i] = true
				p.stun = FakeState.STUN_TIME
				p.zaps += 1
				for c in grid.count():
					if state.owners[c] == i + 1 and rng.randf() < 0.4:
						state.owners[c] = 0
						state.locks[c] = 0.0
		if surge.fire <= 0.0:
			state.surges.erase(surge)

## CPU time this process has used so far, all threads (the software rasteriser
## included), in milliseconds. Linux only; 0 elsewhere. Unlike wall-clock frame
## time it barely moves when other work is competing for the machine.
func cpu_ms() -> float:
	var file := FileAccess.open("/proc/self/stat", FileAccess.READ)
	if file == null:
		return 0.0
	var text := file.get_buffer(2048).get_string_from_ascii()  # /proc files report no length
	var fields := text.substr(text.rfind(")") + 2).split(" ")
	if fields.size() < 13:
		return 0.0
	return (float(fields[11]) + float(fields[12])) * 10.0

## Runs for `seconds` of wall time with real frame deltas, stepping the fake
## simulation at `rate` Hz, and returns the frame times in milliseconds.
func timed_run(state: FakeState, seconds: float, rate: float, own_slot: int = 0) -> Array[float]:
	var frames: Array[float] = []
	var bank := 0.0
	var cpu_before := cpu_ms()
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	var last := Time.get_ticks_usec()
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var now := Time.get_ticks_usec()
		var delta := minf((now - last) / 1000000.0, 0.1)
		frames.append((now - last) / 1000.0)
		last = now
		if state != null:
			bank += delta
			while bank >= 1.0 / rate:
				bank -= 1.0 / rate
				play_step(state, 1.0 / rate)
		show(state, delta, own_slot)
	run_cpu_ms = cpu_ms() - cpu_before
	return frames

func stats(label: String, frames: Array[float]) -> Dictionary:
	var sorted := frames.duplicate()
	sorted.sort()
	var mean := 0.0
	for value in sorted:
		mean += value
	mean /= maxf(sorted.size(), 1)
	var result := {"label": label, "frames": sorted.size(), "mean_ms": snappedf(mean, 0.01),
		"p95_ms": snappedf(sorted[int(sorted.size() * 0.95)], 0.01), "fps": snappedf(1000.0 / mean, 0.1),
		"min_ms": snappedf(sorted[0], 0.01), "median_ms": snappedf(sorted[sorted.size() / 2], 0.01),
		"cpu_ms_per_frame": snappedf(run_cpu_ms / maxf(sorted.size(), 1), 0.01),
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)}
	print("LIVEWIRE_PROBE ", JSON.stringify(result))
	return result

## Feeds straight-line motion sampled at `rate` Hz and reports how even the
## drawn steps are at 60 fps (1.0 = perfectly even) and how far the drawn
## runner trails the true position.
func smoothing_check(rate: float) -> Dictionary:
	var state := new_state(900 + int(rate))
	var p: Dictionary = state.players[0]
	p.x = -8.0
	p.z = 0.0
	p.face = PI / 2.0
	p.speed = FakeState.MOVE_SPEED
	arena.update_visuals(state, 1.0 / 60.0, 0)
	var bank := 0.0
	var truth := -8.0
	var steps: Array[float] = []
	var lag := 0.0
	var last_x: float = arena.runners[0].root.position.x
	for frame in 180:
		truth += FakeState.MOVE_SPEED / 60.0
		bank += 1.0 / 60.0
		while bank >= 1.0 / rate - 0.00001:
			bank -= 1.0 / rate
			p.x = truth - bank * FakeState.MOVE_SPEED
		arena.update_visuals(state, 1.0 / 60.0, 0)
		var x: float = arena.runners[0].root.position.x
		if frame >= 60:
			steps.append(x - last_x)
			lag = maxf(lag, truth - x)
		last_x = x
	var low: float = steps.min()
	var high: float = steps.max()
	# Stop dead: the drawn runner must settle on the target without overshoot.
	p.speed = 0.0
	var overshoot := 0.0
	for frame in 40:
		arena.update_visuals(state, 1.0 / 60.0, 0)
		overshoot = maxf(overshoot, arena.runners[0].root.position.x - float(p.x))
	var result := {"rate_hz": rate, "ideal_step": snappedf(FakeState.MOVE_SPEED / 60.0, 0.0001), "min_step": snappedf(low, 0.0001),
		"max_step": snappedf(high, 0.0001), "evenness": snappedf(low / high, 0.001), "max_lag_units": snappedf(lag, 0.001),
		"stop_overshoot": snappedf(overshoot, 0.001), "rest_error": snappedf(absf(arena.runners[0].root.position.x - float(p.x)), 0.0001)}
	print("LIVEWIRE_SMOOTHING ", JSON.stringify(result))
	return result

# ----------------------------------------------------------------------- run

func run() -> void:
	root.size = resolution
	DirAccess.make_dir_recursive_absolute(out_dir)
	grid = Grid.new(FakeState.GRID_RADIUS, FakeState.HEX_SIZE)
	arena = arena_script.new()
	arena.standalone = true
	root.add_child(arena)
	arena.set_active(true)
	arena.set_detail(high_quality)
	await process_frame
	var report := {"adapter": RenderingServer.get_video_adapter_name(), "resolution": "%dx%d" % [resolution.x, resolution.y],
		"quality": "High" if high_quality else "Balanced"}

	# 1. Idle board (null state), as it would sit behind a menu.
	settle(null, 2.0)
	await capture("01_idle")

	# 2. Countdown, then a fresh board at GO.
	var state := new_state(1)
	state.phase = "countdown"
	state.countdown = 1.4
	settle(state, 0.5)
	await capture("02_countdown")
	state.phase = "running"
	state.countdown = 0.0
	for i in 6:
		state.owners[grid.cell_at(Vector2(state.players[i].x, state.players[i].z))] = i + 1
	settle(state, 1.0)
	await capture("03_go")

	# 3. Busy mid-game board: big territories and three locked regions, one of
	# them about to expire. Seat 0 (lime) is the local player, on their own colour.
	state = busy_board(2)
	settle(state, 1.0)
	await capture("04_midgame")
	# The same board with the HUD bands drawn in, to check the framing.
	bands = CanvasLayer.new()
	root.add_child(bands)
	# Where the HUD sits at the 1440x900 design size: clock and standings,
	# call-out plate, menu button, and the six player plates.
	for band in [Rect2(0, 0, 360, 235), Rect2(485, 0, 470, 150), Rect2(1190, 0, 250, 110), Rect2(0, 750, 1440, 150)]:
		var rect := ColorRect.new()
		rect.color = Color(1.0, 0.2, 0.8, 0.35)
		rect.position = band.position
		rect.size = band.size
		bands.add_child(rect)
	await capture("05_framing_hud_bands")
	bands.queue_free()
	arena.set_menu(true)
	settle(null, 0.1)
	await capture("05b_menu_framing")
	arena.set_menu(false)
	arena.show_identities = true
	settle(state, 0.1)
	await capture("06_identities")
	arena.show_identities = false

	# 4. Surges: early in the warning, late in it, then live with a zapped runner.
	state = busy_board(3)
	put(state, 2, Vector2i(3, 0), -1.2)
	put(state, 0, Vector2i(-2, 0), 1.3)
	settle(state, 0.5)
	state.surges = [{"id": 1, "axis": 0, "line": 0, "warn": 1.45, "fire": 0.45},
		{"id": 2, "axis": 1, "line": 4, "warn": 1.45, "fire": 0.45}]
	settle(state, 0.3)
	await capture("07_surge_early")
	for surge in state.surges:
		surge.warn = 0.28
	settle(state, 0.05)
	await capture("08_surge_late")
	for surge in state.surges:
		surge.warn = 0.0
		surge.fire = 0.33
	state.players[2].stun = 1.2
	state.players[2].speed = 0.0
	state.players[2].zaps = 1
	for i in grid.count():
		if state.owners[i] == 3 and hex_distance(grid.cells[i], Vector2i(4, -1)) <= 2:
			state.owners[i] = 0
	settle(state, 0.12)
	await capture("09_surge_live_zap")
	state.surges.clear()
	state.players[2].stun = 0.8
	settle(state, 0.33)
	await capture("10_stunned")

	# 5. Dash and shove: seat 3 (orange) dashes into seat 1 (violet).
	state = busy_board(4)
	put(state, 3, Vector2i(0, -1), -PI / 2.0)
	put(state, 1, Vector2i(-1, -1), 0.6)
	settle(state, 0.4)
	state.players[3].dash = 0.12
	state.players[3].speed = 11.0
	state.players[3].shoves = 1
	state.players[1].shove = 0.3
	state.players[1].speed = 9.0
	state.players[1].x -= 0.5
	settle(state, 0.15)
	await capture("11_dash_shove")

	# 6. Loop capture: seat 4 (pink) closes a ring; the inside fills and locks.
	state = busy_board(5)
	put(state, 4, Vector2i(-2, 4), 1.0)
	settle(state, 0.4)
	state.players[4].loops = 1
	lock_patch(state, 4, Vector2i(-3, 4), 2, 10.0)
	settle(state, 0.2)
	await capture("12_loop_capture")
	settle(state, 1.2)
	await capture("13_loop_locked")

	# 7. Overdrive: no locks, several surges at once, the stage runs hot.
	state = busy_board(6)
	state.locks.fill(0.0)
	state.elapsed = 78.0
	state.surges = [{"id": 11, "axis": 2, "line": -3, "warn": 0.9, "fire": 0.45},
		{"id": 12, "axis": 0, "line": 5, "warn": 0.3, "fire": 0.45},
		{"id": 13, "axis": 1, "line": -4, "warn": 0.0, "fire": 0.3}]
	settle(state, 0.9)
	await capture("14_overdrive")

	# 8. Winner moment.
	state = busy_board(7)
	state.elapsed = 90.0
	state.phase = "finished"
	settle(state, 0.2)
	arena.celebrate(3)
	settle(state, 0.6)
	await capture("15_celebrate")

	if quick:
		print("LIVEWIRE_PROBE_DONE ", out_dir)
		quit()
		return

	# 9. Fake play: motion, run cycle, surges and flashes, with frame timings.
	rng.seed = 4242
	state = busy_board(8)
	play_setup(state)
	update_usec = 0
	update_calls = 0
	var frames := await timed_run(state, 6.0, 60.0)
	await capture("16_play_60hz")
	report["play_60hz"] = stats("livewire play, state stepped at 60 Hz (server)", frames)
	report["update_visuals_ms"] = snappedf(update_usec / 1000.0 / maxf(update_calls, 1), 0.001)
	print("LIVEWIRE_PROBE update_visuals mean ms ", report["update_visuals_ms"])
	frames = await timed_run(state, 4.0, 20.0)
	await capture("17_play_20hz")
	report["play_20hz"] = stats("livewire play, state stepped at 20 Hz (client)", frames)
	state.elapsed = 74.0
	frames = await timed_run(state, 4.0, 60.0)
	await capture("18_play_overdrive")
	report["play_overdrive"] = stats("livewire overdrive play", frames)
	frames = await timed_run(null, 3.0, 60.0)
	report["idle"] = stats("livewire idle board (null state)", frames)

	# 10. Smoothing, measured without the renderer in the loop.
	report["smoothing_60hz"] = smoothing_check(60.0)
	report["smoothing_20hz"] = smoothing_check(20.0)

	# 11. The spiral arena under the same window and renderer, for comparison.
	if compare:
		arena.set_active(false)
		arena.queue_free()
		await process_frame
		var spiral: Node3D = SpiralArena.new()
		root.add_child(spiral)
		spiral.set_detail(high_quality)
		spiral.set_menu(false)
		await process_frame
		var spiral_frames: Array[float] = []
		var spiral_cpu := cpu_ms()
		var deadline := Time.get_ticks_msec() + 4000
		var last := Time.get_ticks_usec()
		while Time.get_ticks_msec() < deadline:
			await process_frame
			var now := Time.get_ticks_usec()
			spiral_frames.append((now - last) / 1000.0)
			spiral.update_visuals(null, minf((now - last) / 1000000.0, 0.1))
			last = now
		run_cpu_ms = cpu_ms() - spiral_cpu
		report["spiral_arena"] = stats("existing spiral arena (in-game camera, null model)", spiral_frames)
		await capture("99_spiral_arena_reference")
	var file := FileAccess.open(out_dir + "/performance.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t") + "\n")
	file.close()
	print("LIVEWIRE_PROBE_DONE ", out_dir)
	quit()
