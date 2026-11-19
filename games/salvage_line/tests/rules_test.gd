extends SceneTree
## Run with Godot --headless --script games/salvage_line/tests/rules_test.gd.

const Model = preload("res://games/salvage_line/model.gd")
const DIRECTIONS := ["up", "down", "left", "right"]

var _checks := 0
var _failures: Array[String] = []

func _initialize() -> void:
	_test_round_clock()
	_test_hook_cut_and_drift()
	_test_bank_and_refill()
	_test_banked_weight_and_rank()
	_test_tow_speed()
	_test_contested_hook()
	_test_snapshot_and_tick_batching()
	_test_contested_round()
	_test_human_seats()
	_test_active_solo()
	for failure in _failures:
		push_error(failure)
	print("Salvage Line: %d checks, %d failures" % [_checks, _failures.size()])
	quit(int(not _failures.is_empty()))

func _check(holds: bool, description: String) -> void:
	_checks += 1
	if not holds:
		_failures.append(description)

func _slots(humans: int) -> Array:
	var seats := []
	for i in Model.SEATS:
		seats.append({"name": "Tug %d" % (i + 1), "peer": 810 + i, "bot": i >= humans})
	return seats

func _model(seed_value: int = 12, humans: int = Model.SEATS, start: bool = true):
	var game = Model.new()
	game.begin(seed_value, _slots(humans), 71)
	if start:
		game.step(Model.COUNTDOWN)
	return game

func _tap(game, seat: int) -> void:
	game.command(seat, "winch", true)
	game.command(seat, "winch", false)

func _carried(game, cargo: Dictionary, slot: int, at: Vector2, direction: Vector2) -> void:
	game.players[slot].pos = at
	game.players[slot].velocity = Vector2.ZERO
	game.players[slot].towing = cargo.id
	cargo.owner = slot
	cargo.pos = at + direction * Model.TOW_LENGTH
	cargo.velocity = Vector2.ZERO
	cargo.drift_until = 0
	cargo.protected_until = 0

func _test_round_clock() -> void:
	var game = _model(12, 6, false)
	_tap(game, 0)
	game.step(Model.COUNTDOWN - Model.STEP)
	_check(game.phase == "countdown" and game.tick == 0 and is_equal_approx(game.countdown, Model.STEP), "Countdown holds the simulation")
	game.step(Model.STEP)
	_check(game.phase == "running" and game.tick == 0 and game.remaining() == Model.ROUND_TIME, "Round starts after exactly three seconds")
	game.step(1.0)
	_check(game.players[0].towing == -1, "Countdown winch presses do not queue")
	game.step(300.0)
	_check(game.phase == "finished" and game.tick == Model.ROUND_TICKS and game.remaining() == 0.0, "Round stops at exactly 90 seconds")
	var final: Dictionary = game.snapshot()
	game.step(5.0)
	_tap(game, 0)
	_check(game.snapshot() == final, "Finished round cannot advance or accept input")

func _test_hook_cut_and_drift() -> void:
	var game = _model()
	var cargo: Dictionary = game.crates[0]
	game.crates.assign([cargo])
	cargo.pos = Vector2(-2.1, 0)
	for seat in [0, 1, 2]:
		game.players[seat].pos = Vector2.ZERO
	_check(game.action_target(0).kind == "hook" and game.action_target(0).crate == cargo.id, "Free tug highlights reachable cargo")
	game.command(0, "winch", true)
	game.step(Model.STEP)
	_check(game.players[0].towing == cargo.id and game.players[0].hook_tick == game.tick and cargo.owner == 0, "First tap hooks highlighted cargo")
	game.command(0, "winch", true)
	game.step(Model.STEP)
	_check(cargo.owner == 0, "Holding winch does not retrigger release")
	game.command(0, "winch", false)
	_check(game.line_protected(cargo) and game.action_target(1).kind == "idle", "New ropes have cut protection")
	_tap(game, 1)
	game.step((Model.PROTECTION_TICKS - 1) * Model.STEP)
	_check(cargo.owner == 0 and not game.line_protected(cargo), "Protection expires on its advertised tick")
	cargo.pos = Vector2(-0.7, 0)
	_check(not game.line_taut(cargo) and game.action_target(1).kind == "idle", "Rivals cannot cut slack rope")
	cargo.pos = Vector2(-2.1, 0)
	var midpoint: Vector2 = game.rope_midpoint(cargo)
	_check(game.action_target(1) == {"kind": "cut", "crate": cargo.id, "at": midpoint}, "Free rival highlights taut midpoint")
	game.players[0].velocity = Vector2(3.0, 0)
	_tap(game, 1)
	_tap(game, 2)
	game.step(Model.STEP)
	var cut_count: int = game.players.filter(func(p): return p.cut_tick == game.tick).size()
	_check(cut_count == 1 and game.players[0].lost_tick == game.tick and game.players[0].towing == -1, "Simultaneous cuts produce one severed line")
	_check(cargo.owner == -1 and cargo.drift_until == game.tick + Model.DRIFT_TICKS, "Severed cargo enters temporary drift")
	var release_pos: Vector2 = cargo.pos
	_tap(game, 2)
	game.step((Model.DRIFT_TICKS - 1) * Model.STEP)
	_check(cargo.owner == -1 and not cargo.pos.is_equal_approx(release_pos) and game.action_target(2).kind == "idle", "Drifting crate moves and rejects early taps")
	game.step(Model.STEP)
	_check(game.action_target(2).kind == "hook", "Drift expiry restores the hook highlight")
	_tap(game, 2)
	game.step(Model.STEP)
	_check(cargo.owner == 2 and game.players[2].towing == cargo.id, "Crate can be stolen on first eligible drift tick")

func _test_bank_and_refill() -> void:
	var game = _model()
	var cargo: Dictionary = game.crates[0]
	var other: Dictionary = game.crates[1]
	cargo.heavy = true
	var dock := Model.harbor_center(0)
	_carried(game, cargo, 0, dock - Vector2(3.2, 0), Vector2.LEFT)
	other.pos = game.players[0].pos
	game.players[1].pos = game.rope_midpoint(cargo)
	_check(game.line_protected(cargo) and game.action_target(1).kind != "cut", "Owner approach protects an otherwise exposed line")
	_check(game.action_target(0).kind == "release", "Carrying outside the dock prioritizes release over nearby loose cargo")
	_tap(game, 0)
	game.step(Model.STEP)
	_check(game.players[0].score == 0 and cargo.owner == -1 and cargo.drift_until == game.tick + Model.DRIFT_TICKS, "Manual release gives no score and drifts")
	_carried(game, cargo, 0, dock + Vector2(2.05, 0), Vector2.LEFT)
	game.players[0].velocity = Vector2(3.7, 0)
	game.command(0, "right", true)
	_check(game.action_target(0).kind == "deliver", "Dock accepts a legal trailing crate when tug is inside the dock")
	var count: int = game.crates.size()
	var last_id: int = game.crates.back().id
	_tap(game, 0)
	game.step(Model.STEP)
	_check(Vector2(game.players[0].pos).distance_to(dock) > Model.HARBOR_RADIUS and game.players[0].score == 2 and game.players[0].bank_amount == 2 and game.players[0].bank_tick == game.tick, "Docked heavy delivers two weight even when same-step movement leaves the dock")
	_check(game.crates.size() == count - 1 and game.players[0].towing == -1 and not game.crates.has(cargo), "Banked cargo vanishes and clears the tow")
	game.step((Model.REFILL_TICKS - 1) * Model.STEP)
	_check(game.crates.size() == count - 1, "Replacement respects refill delay")
	game.step(Model.STEP)
	_check(game.crates.size() == count and game.crates.back().id > last_id, "Refill restores stock with a fresh ID")

func _test_banked_weight_and_rank() -> void:
	var game = _model()
	for i in 2:
		var cargo: Dictionary = game.crates[0]
		cargo.heavy = false
		var dock := Model.harbor_center(0)
		_carried(game, cargo, 0, dock, Vector2.LEFT)
		_tap(game, 0)
		game.step(Model.STEP)
		_check(game.players[0].bank_amount == 1 and game.players[0].score == i + 1, "Light deliveries add one at a time")
	var cargo: Dictionary = game.crates[0]
	cargo.heavy = true
	_carried(game, cargo, 4, Model.harbor_center(4), Vector2.RIGHT)
	_tap(game, 4)
	game.step(Model.STEP)
	_check(game.winners() == [0, 4] and game.ranking() == [0, 4, 1, 2, 3, 5], "Equal banked weight draws regardless of crate count")

func _test_tow_speed() -> void:
	var game = _model()
	var light: Dictionary = game.crates[0]
	var heavy: Dictionary = game.crates[1]
	light.heavy = false
	heavy.heavy = true
	_carried(game, light, 0, Vector2.ZERO, Vector2.LEFT)
	_carried(game, heavy, 1, Vector2.ZERO, Vector2.LEFT)
	game.players[2].pos = Vector2.ZERO
	for i in 3:
		game.command(i, "right", true)
	game.step(0.65)
	var light_travel: float = game.players[0].pos.x
	var heavy_travel: float = game.players[1].pos.x
	_check(game.players[2].pos.x > light_travel and light_travel > heavy_travel, "Heavy cargo slows tugs more than light cargo")
	_check(Vector2(game.players[1].pos).distance_to(heavy.pos) <= Model.TOW_LENGTH + 0.002, "Cargo respects the maximum tow length")

func _test_contested_hook() -> void:
	var winners := {}
	for frame in Model.SEATS:
		var game = _model(91)
		var cargo: Dictionary = game.crates[0]
		game.crates.assign([cargo])
		cargo.pos = Vector2.ZERO
		game.step(frame * Model.STEP)
		for i in Model.SEATS:
			game.players[i].pos = Vector2.ZERO
			_tap(game, i)
		game.step(Model.STEP)
		var count: int = game.players.filter(func(p): return p.towing == cargo.id).size()
		_check(count == 1, "Exactly one tug wins a contested crate")
		winners[cargo.owner] = true
	_check(winners.size() == Model.SEATS, "Exact hook ties rotate through all six seats")
	var game = _model(91)
	var cargo: Dictionary = game.crates[0]
	game.crates.assign([cargo])
	cargo.pos = Vector2.ZERO
	game.players[0].pos = Vector2(1.5, 0)
	game.players[5].pos = Vector2(0, 1.0)
	_tap(game, 0)
	_tap(game, 5)
	game.step(Model.STEP)
	_check(cargo.owner == 5, "Contested hook prefers a closer tug before rotating ties")

func _test_snapshot_and_tick_batching() -> void:
	var host = _model(13, 0)
	var same = _model(13, 0)
	var guest = _model(13, 0, false)
	var max_wire_size := 0
	for i in 180:
		host.step(10.0 * Model.STEP)
		for frame in 10:
			same.step(Model.STEP)
			var wire: Dictionary = same.snapshot()
			guest.apply_snapshot(wire)
			max_wire_size = maxi(max_wire_size, var_to_bytes(wire).size())
			_check(guest.snapshot() == wire, "Guest reconstructs the exact wire state at tick %d" % guest.tick)
			for seat in Model.SEATS:
				_check(guest.action_target(seat) == same.action_target(seat), "Guest reproduces action target at tick %d for seat %d" % [guest.tick, seat])
		_check(host.snapshot() == same.snapshot(), "Seeded simulation is unchanged by ten-tick batches")
	_check(max_wire_size < 1024, "Wire state stays under 1 KB")
	print("Max full-state wire bytes: ", max_wire_size)
	var final: Dictionary = guest.snapshot()
	var bad := final.duplicate()
	bad.state = PackedByteArray([1, 2])
	guest.apply_snapshot(bad)
	guest.step(4.0)
	guest.take_over(1)
	_check(guest.snapshot() == final, "Guest rejects incomplete snapshots and runs no local simulation")

func _test_contested_round() -> void:
	var total_winners := {}
	var cuts := 0
	var banks := 0
	var first := Model.ROUND_TICKS
	for seed_value in 24:
		var game = _model(seed_value, 0)
		var seed_cuts := 0
		var seed_banks := 0
		for frame in Model.ROUND_TICKS:
			game.step(Model.STEP)
			for p in game.players:
				if p.cut_tick == game.tick:
					seed_cuts += 1
				if p.bank_tick == game.tick:
					seed_banks += 1
					first = mini(first, game.tick)
		for seat in game.winners():
			total_winners[seat] = true
		_check(seed_banks >= 100 and seed_cuts > 0, "Seed %d sees both regular deliveries and live cuts" % seed_value)
		_check(game.phase == "finished", "Contested seed reaches the end of the round")
		cuts += seed_cuts
		banks += seed_banks
	_check(total_winners.size() == Model.SEATS, "Different seeds allow every seat to win")
	print("24 CPU rounds: %d deliveries, %d cuts, fastest first delivery %.2fs" % [banks, cuts, first * Model.STEP])

	# Keep one crate in a two-player contest while another player harvests
	# the rest of the field. Every cut must still yield a hook window.
	var game = _model(5)
	var cargo: Dictionary = game.crates[0]
	var scripted_cuts := 0
	var scripted_hooks := 0
	for i in 12:
		_carried(game, cargo, 0, Vector2(0, -10.0), Vector2.UP)
		game.players[1].pos = game.rope_midpoint(cargo)
		game.players[1].velocity = Vector2.ZERO
		_tap(game, 1)
		game.step(Model.STEP)
		if game.players[1].cut_tick == game.tick:
			scripted_cuts += 1
		for frame in Model.DRIFT_TICKS:
			_active_commands(game, 2)
			game.step(Model.STEP)
		_tap(game, 0)
		game.step(Model.STEP)
		if cargo.owner == 0:
			scripted_hooks += 1
		for frame in Model.PROTECTION_TICKS:
			_active_commands(game, 2)
			game.step(Model.STEP)
	var concurrent_score: int = game.players[2].score
	game.step(Model.ROUND_TIME)
	_check(scripted_cuts == 12 and scripted_hooks == 12, "Repeated cuts preserve a recovery path")
	_check(game.phase == "finished" and concurrent_score >= 5, "A repeated cutting contest does not stop the clock or other deliveries")
	print("Repeated contest: %d cuts, %d rehooks, %d weight banked by a third tug" % [scripted_cuts, scripted_hooks, concurrent_score])

func _steer(game, seat: int, goal: Vector2) -> void:
	var at: Vector2 = game.players[seat].pos
	var heading := posmod(roundi((goal - at).angle() / (TAU / 8.0)), 8)
	var masks := [8, 10, 2, 6, 4, 5, 1, 9]
	for direction in DIRECTIONS:
		game.command(seat, direction, (int(masks[heading]) & int(Model.DIRS[direction])) != 0)

func _active_commands(game, seat: int) -> void:
	var p: Dictionary = game.players[seat]
	var target: Dictionary = game.action_target(seat)
	var dock := Model.harbor_center(seat)
	var at: Vector2 = p.pos
	var goal := dock
	if p.towing < 0:
		var best := INF
		goal = at
		for cargo in game.crates:
			if cargo.owner >= 0 or game.tick < cargo.drift_until:
				continue
			var cost := at.distance_to(cargo.pos) + dock.distance_to(cargo.pos) * 0.35
			if cost < best:
				best = cost
				goal = cargo.pos
	_steer(game, seat, goal)
	if target.kind in ["hook", "cut", "deliver"]:
		_tap(game, seat)

func _test_human_seats() -> void:
	for humans in range(2, Model.SEATS + 1):
		var game = _model(19, humans)
		for i in 640:
			_active_commands(game, humans - 1)
			game.step(Model.STEP)
		for i in Model.SEATS:
			var p: Dictionary = game.players[i]
			_check(p.slot == i and p.peer == 810 + i and p.name == "Tug %d" % (i + 1) and p.bot == (i >= humans), "%d humans preserve identity at seat %d" % [humans, i])
		_check(game.players[humans - 1].score > 0 and game.players[humans - 1].score > game.players[0].score, "Active human winch and steering outscore idle in a %d-human lobby" % humans)
		_check(game.players[0].score == 0, "Idle controls do not bank cargo")
		game.take_over(humans - 1)
		var last: Dictionary = game.players[humans - 1]
		_check(last.bot and last.peer == 809 + humans and last.input == 0, "Takeover preserves an occupied seat and clears held input")

func _test_active_solo() -> void:
	var wins := 0
	var draws := 0
	for seat in Model.SEATS:
		var seat_wins := 0
		for seed_value in 8:
			var slots := _slots(0)
			slots[seat].bot = false
			var game = Model.new()
			game.begin(seed_value, slots)
			game.step(Model.COUNTDOWN)
			for frame in Model.ROUND_TICKS:
				_active_commands(game, seat)
				game.step(Model.STEP)
			var winners: Array = game.winners()
			if winners.has(seat):
				if winners.size() == 1:
					seat_wins += 1
				else:
					draws += 1
		_check(seat_wins > 0, "Eight-way controls can win against five CPUs from seat %d" % seat)
		wins += seat_wins
	_check(wins >= 12, "Active steering and timed winch remain competitive across seeded Solo rounds")
	print("48 active Solo rounds: %d wins, %d draws" % [wins, draws])
