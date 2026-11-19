extends SceneTree
## Fixed-tick rules, a digital-control race and deterministic full bot races.

const Model = preload("res://games/orb_racing/model.gd")
const Track = preload("res://games/orb_racing/track.gd")
const ACTIONS := {"left": 1, "right": 2, "up": 4, "down": 8}
const DIGITAL := [2, 10, 8, 9, 1, 5, 4, 6]
var _checks := 0
var _failures := 0
var _max_wire := 0


func _initialize() -> void:
	_grid_and_gates()
	_charge_and_rails()
	_finish_and_timeout()
	_takeover()
	_digital_race()
	_seeded_races()
	print("ORB_RACE %s: %d checks, %d failures, max snapshot %d bytes" %
		["PASS" if _failures == 0 else "FAIL", _checks, _failures, _max_wire])
	quit(mini(_failures, 1))


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		printerr("FAIL: ", message)


func _slots(bots: bool) -> Array:
	var seats: Array = []
	for i in Model.SEATS:
		seats.append({"name": "Driver %d" % (i + 1), "peer": i + 1, "bot": bots})
	return seats


func _new_race(bots: bool = false, seed_value: int = 123) -> RefCounted:
	var race := Model.new()
	race.begin(seed_value, _slots(bots), 31)
	return race


func _place(race: RefCounted, slot: int, pos: Vector2, velocity: Vector2 = Vector2.ZERO) -> void:
	var p: Dictionary = race.players[slot]
	p.pos = pos
	p.velocity = velocity
	p._road = race.track.project(pos)


func _pass(race: RefCounted, gate: int, lateral: float = 0.0, direction: float = 1.0) -> void:
	var frame: Transform2D = race.track.gates[gate]
	_place(race, 0, frame * Vector2(-0.05 * direction, lateral), frame.x * (direction * 7.0))
	race.step(Model.DT)


func _grid_and_gates() -> void:
	var race := _new_race()
	var line: Transform2D = race.track.gates[0]
	var gap: float = race.track.length
	for i in race.track.gates.size() - 1:
		gap = minf(gap, race.track.gate_distances[i + 1] - race.track.gate_distances[i])
	_check(gap > Model.BOOST_SPEED * Model.DT * 2.0, "Ordered timing lines cannot overlap a swept step")
	for i in Model.SEATS:
		var p: Dictionary = race.players[i]
		var offset: Vector2 = p.pos - line.origin
		_check(is_equal_approx(offset.dot(line.x), -Track.GRID_BEHIND), "Every lane starts equally far behind the line")
		_check(absf(offset.dot(line.y)) + Track.ORB_RADIUS <= Track.ROAD_HALF, "Each grid orb fits on the road")
		_check(p.laps == 0 and p.gate == 0 and p.progress == 0.0 and not p.started, "No credit in the grid")

	var p: Dictionary = race.players[0]
	var spawn: Vector2 = p.pos
	race.command(0, "right", true)
	race.command(0, "dash", true)
	race.step(2.8)
	_check(race.phase == "countdown" and p.pos == spawn and p.spent == 0, "Countdown holds motion and boost")
	race.step(0.2)
	_check(race.phase == "running" and p.pos == spawn, "Three-second grid countdown")
	race.step(0.9)
	_check(p.started and p.laps == 0 and p.gate == 1 and p.spent == 0, "Driving off the grid only starts lap 1")
	race.command(0, "right", false)
	_pass(race, 2)
	_check(p.gate == 1, "Crossing a later gate cannot advance the order")
	_pass(race, 0)
	_check(p.laps == 0, "Re-crossing the line without the sector gates earns no lap")
	_pass(race, 1, 0, -1)
	_check(p.gate == 1, "Crossing backward earns no credit")
	_pass(race, 1, Track.ROAD_HALF + 0.4)
	_check(p.gate == 1, "The grass beyond a timing line earns no credit")
	_pass(race, 1, Track.ROAD_HALF - 0.03)
	_check(p.gate == 2, "A forward crossing near the edge of the road counts")
	for gate in range(2, race.track.gates.size()):
		_pass(race, gate)
	_check(p.gate == 0 and p.laps == 0, "All six route gates arm the lap line")
	_pass(race, 0)
	_check(p.gate == 1 and p.laps == 1, "Crossing the armed line earns exactly one lap")

	# The crossing point itself decides width. Both end points may be wider
	# or narrower than the line as a swept step moves diagonally.
	var gate: Transform2D = race.track.gates[2]
	_check(Track.crossing(gate, 2.0, gate * Vector2(-2, 5), gate * Vector2(2, -5)) >= 0.0,
		"A swept diagonal can cross between its endpoints")
	_check(Track.crossing(gate, 2.0, gate * Vector2(-2, 9), gate * Vector2(2, 0)) < 0.0,
		"An endpoint inside the lane does not rescue an out-of-bounds crossing")


func _charge_and_rails() -> void:
	var race := _new_race()
	race.step(Model.COUNTDOWN)
	var p: Dictionary = race.players[0]
	race.command(0, "right", true)
	for i in 6:
		race.command(0, "dash", true)
	race.step(0.1)
	_check(p.spent == 1 and p.charges == 0 and p.boost > 0.0, "One held press spends one charge")
	race.command(0, "right", false)
	race.command(0, "dash", false)
	race.step(0.8)
	race.command(0, "dash", true)
	race.step(Model.DT)
	_check(p.spent == 1, "Empty boost cannot fire")
	race.command(0, "dash", false)
	p.started = true
	p.gate = 1
	var strip: Transform2D = race.track.pads[0]
	_place(race, 0, strip * Vector2(-1.02, 0), strip.x * 8.0)
	race.step(Model.DT * 2)
	_check(p.charges == 1 and p.picked == 1, "Driving onto gold restores a charge")
	race.command(0, "dash", true)
	race.command(0, "dash", false)
	race.step(Model.DT)
	_place(race, 0, strip * Vector2(-1.02, 0), strip.x * 8.0)
	race.step(Model.DT * 2)
	_check(p.charges == 0 and p.picked == 1, "Crossing the same strip twice in a lap cannot farm a charge")
	for i in range(1, race.track.pads.size()):
		strip = race.track.pads[i]
		_place(race, 0, strip * Vector2(-1.02, 0), strip.x * 8.0)
		race.step(Model.DT * 2)
	_check(p.charges == Model.MAX_CHARGES and p.picked == 3, "Other charge strips remain available and respect capacity")
	var boost_before: float = p.boost
	race.command(0, "dash", true)
	race.command(0, "dash", false)
	race.step(Model.DT)
	_check(p.charges == Model.MAX_CHARGES - 1 and p.boost > boost_before,
		"A second press uses one charge to extend the boost")
	p.gate = 0
	_pass(race, 0)
	p.charges = 0
	strip = race.track.pads[0]
	_place(race, 0, strip * Vector2(-1.02, 0), strip.x * 8.0)
	race.step(Model.DT * 2)
	_check(p.charges == 1 and p.picked == 4, "Completing a lap resets strip availability")

	var line: Transform2D = race.track.frame(-16.0)
	race.command(0, "right", true)
	_place(race, 0, line * Vector2(0, Track.ROAD_HALF + 0.5))
	race.step(0.65)
	_check(is_equal_approx(p.velocity.length(), Model.GRASS_SPEED), "Grass holds the lower speed")
	race.command(0, "right", false)
	race.command(0, "down", true)
	race.step(1.6)
	_check(absf(race.track.project(p.pos).y) <= Track.RAIL_HALF - Track.ORB_RADIUS + 0.01, "Rail contains a held outward input")
	race.command(0, "down", false)
	var overlap := Vector2(-15, 17)
	_place(race, 0, overlap)
	_place(race, 1, overlap)
	race.command(0, "right", true)
	race.command(1, "right", true)
	race.step(0.45)
	_check(p.pos == race.players[1].pos and p.pos.x > overlap.x + 0.5, "Overlapping orbs ghost without slowing one another")


func _finish_and_timeout() -> void:
	var race := _new_race()
	race.step(Model.COUNTDOWN)
	race.step(10.0)
	var line: Transform2D = race.track.gates[0]
	var start: float = race.elapsed
	for i in 2:
		var p: Dictionary = race.players[i]
		p.started = true
		p.laps = 2
		_place(race, i, line * Vector2(-0.08 + i * 0.05, i), line.x * 7.0)
	var stranded: Dictionary = race.players[2]
	stranded.started = true
	stranded.laps = 2
	stranded.gate = 6
	var past: float = race.track.gate_distances[6] + 1.0
	_place(race, 2, race.track.frame(past).origin)
	race.step(Model.DT)
	var first: float = race.players[1].finish
	var last: float = race.players[0].finish
	_check(start < first and first < last and last < race.elapsed, "Finish time is interpolated within the step and sorts both finishers")
	_check(race.winners() == [1] and race.ranking().slice(0, 3) == [1, 0, 2], "Finishers beat a nearly complete DNF")
	_check(stranded.progress < 2.0 * race.track.length + race.track.gate_distances[6], "DNF arc cannot pass its uncollected gate")
	var clone := _new_race()
	clone.apply_snapshot(bytes_to_var(var_to_bytes(race.snapshot())))
	_check(clone.snapshot() == race.snapshot() and clone.winners() == race.winners(), "Wire keeps the same fractional times and order")
	race.step(11.9)
	_check(race.phase == "running", "DNFs still get the rest of the 12-second window")
	race.step(1.0)
	_check(race.phase == "finished" and race.elapsed == first + Model.FINISH_WINDOW, "Finish window ends at the exact first finish plus 12 seconds")

	race = _new_race()
	race.step(Model.COUNTDOWN + 99.99)
	_check(race.phase == "running", "The hard cap has not expired at the last tick")
	race.step(1.0)
	_check(race.phase == "finished" and race.elapsed == Model.ROUND_TIME and race.winners().size() == 6,
		"The hard cap resolves a no-finisher race with deterministic tied progress")
	race = _new_race()
	race.step(Model.COUNTDOWN + 94.0)
	var late: Dictionary = race.players[0]
	late.started = true
	late.laps = 2
	_pass(race, 0)
	_check(late.finish > 94.0 and race.deadline() == Model.ROUND_TIME, "A late winner cannot extend the hard cap")
	race.step(10.0)
	_check(race.elapsed == Model.ROUND_TIME and race.winners() == [0], "A truncated finish window keeps the late winner")


func _takeover() -> void:
	var race := _new_race()
	race.step(Model.COUNTDOWN)
	var p: Dictionary = race.players[0]
	p.started = true
	p.gate = 2
	_place(race, 0, race.track.frame(race.track.gate_distances[2] + 4.0).origin)
	race.take_over(0)
	race.step(5.0)
	_check(p.bot and p.gate >= 3, "A replacement bot returns to a missed gate and collects it")


func _digital_race() -> void:
	var race := _new_race()
	race.step(Model.COUNTDOWN)
	var p: Dictionary = race.players[0]
	var previous := 0
	for tick in Model.HZ * 90:
		var road: Vector3 = p._road
		var target: Vector2 = race.track.frame(road.x + 6.9).origin
		var pos: Vector2 = p.pos
		var wanted: int = DIGITAL[posmod(roundi((target - pos).angle() / (TAU / 8.0)), 8)]
		for action in ACTIONS:
			var bit: int = ACTIONS[action]
			if (wanted ^ previous) & bit:
				race.command(0, action, bool(wanted & bit))
		previous = wanted
		race.step(Model.DT)
		if p.finish >= 0.0:
			break
	_check(p.laps == 3 and p.finish >= 60.0 and p.finish <= 90.0,
		"Three laps using public eight-way human steering take 60–90 seconds (%.3fs)" % float(p.finish))
	print("Digital steering finish %.3fs" % float(p.finish))


func _seeded_races() -> void:
	var earliest := INF
	var latest := 0.0
	for seed_value in [1, 7, 11, 29, 42, 97, 120, 153, 239, 811, 3325, 8191]:
		var race := _new_race(true, seed_value)
		var replay := _new_race(true, seed_value)
		var mirrored := _new_race(true, seed_value)
		for sample in 415:
			race.step(0.2)
			var wire := var_to_bytes(race.snapshot()).compress(FileAccess.COMPRESSION_DEFLATE)
			_max_wire = maxi(_max_wire, wire.size())
			mirrored.apply_snapshot(bytes_to_var(wire.decompress_dynamic(1024, FileAccess.COMPRESSION_DEFLATE)))
			if race.phase == "finished":
				break
		replay.step(103.0)
		var times: Array = race.players.map(func(p): return p.finish)
		for p in race.players:
			_check(p.laps == Model.LAPS and p.finish > 0.0 and p.spent > 0 and p.picked > 0,
				"Seed %d: each bot finishes and uses the same pickups and boosts" % seed_value)
		_check(replay.snapshot() == race.snapshot(), "Seed %d: frame partition cannot change race outcome" % seed_value)
		_check(mirrored.snapshot() == race.snapshot(), "Seed %d: snapshots reproduce the authoritative result" % seed_value)
		_check(race.elapsed == race.first_finish + Model.FINISH_WINDOW, "Seed %d: deadline is timed to the winner" % seed_value)
		_check(race.first_finish >= 60.0 and race.first_finish <= 90.0, "Seed %d: competitive finish time" % seed_value)
		earliest = minf(earliest, times.min())
		latest = maxf(latest, times.max())
	print("72 seeded bot finishes %.3f–%.3fs" % [earliest, latest])
	_check(_max_wire < 1024, "Largest compressed snapshot stays under 1 KB")
