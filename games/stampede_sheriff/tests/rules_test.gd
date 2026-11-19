extends SceneTree
## Host rules, scripted eight-way movement, and the actual compressed wire format.

const M = preload("res://games/stampede_sheriff/model.gd")
const SEEDS := [0, 1, 2, 3, 4, 5, 1088, 10577]
var _failures := 0
var _checks := 0

func _initialize() -> void:
	_clock_and_ties()
	_walk_six_lanes()
	_clap_and_recovery()
	_rival_steal()
	_edge_lane()
	_hatches()
	_seeded_matches()
	print("STAMPEDE_RULES %s: %d checks, %d failures" % ["PASS" if _failures == 0 else "FAIL", _checks, _failures])
	quit(mini(_failures, 1))

func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		printerr("FAIL: ", message)

func _make(seed_value: int = 1, bots: bool = false) -> RefCounted:
	var model := M.new()
	var seats: Array = []
	for i in M.SEATS:
		seats.append({"name": "P%d" % (i + 1), "peer": i + 1, "bot": bots})
	model.begin(seed_value, seats, 42)
	return model

func _isolated() -> RefCounted:
	var model := _make()
	model.step(M.COUNTDOWN)
	model.critters.clear()
	for i in M.SEATS:
		model.players[i].pos = M.pen(i).normalized() * M.FIELD_RADIUS
	return model

func _clock_and_ties() -> void:
	var m := _make()
	var initial: Vector2 = m.players[0].pos
	m.command(0, "clap", true)
	m.command(0, "right", true)
	m.step(M.COUNTDOWN - M.STEP)
	_check(m.phase == "countdown" and m.tick == 0 and m.players[0].pos == initial, "Countdown freezes play")
	m.step(M.STEP)
	m.step(0.15)
	_check(m.phase == "running" and m.players[0].pos.x > initial.x and m.players[0].claps == 0,
		"Held movement starts at GO and countdown claps are discarded")
	m.step(200.0)
	var frozen: Dictionary = m.snapshot()
	m.step(30.0)
	m.command(0, "clap", true)
	_check(m.phase == "finished" and m.tick == 5400 and m.elapsed == 90 and m.remaining() == 0.0 and m.snapshot() == frozen,
		"Exactly 90 seconds and no changes after the cutoff")
	m.players[2].score = 88
	m.players[4].score = 88
	_check(m.ranking().slice(0, 2) == [2, 4] and m.winners() == [2, 4], "Equal leading scores share the win")

func _walk_six_lanes() -> void:
	var m := _isolated()
	for i in M.SEATS:
		var outward := M.pen(i).normalized()
		m.players[i].pos = outward.rotated(-0.06) * 2.7
		m._add_critter(outward * 4.35, outward.rotated(0.82), 1, 0)
	var ran := 0
	while ran < 210 and not m.critters.is_empty():
		for i in M.SEATS:
			var target := _find(m, i + 7)
			if target.is_empty():
				_steer(m, i, Vector2.ZERO)
			else:
				var at: Vector2 = target.pos
				var behind := at - at.direction_to(M.pen(i)) * 1.53
				_steer(m, i, behind - Vector2(m.players[i].pos))
		m.step(3 * M.STEP)
		ran += 3
	_check(m.players.all(func(p): return p.score == 1 and p.claps == 0),
		"Six simultaneous eight-direction walkers can each turn and pen a moving critter with no claps")
	print("six walking-only lanes: %s at %.2fs" % [m.players.map(func(p): return p.score), m.elapsed])

func _steer(m: RefCounted, slot: int, want: Vector2) -> void:
	var mask := 0
	if want.length_squared() > 0.14 ** 2:
		var sector := posmod(roundi(want.angle() / (PI / 4.0)), 8)
		mask = [M.DIRS.right, M.DIRS.right | M.DIRS.down, M.DIRS.down,
			M.DIRS.left | M.DIRS.down, M.DIRS.left, M.DIRS.left | M.DIRS.up,
			M.DIRS.up, M.DIRS.right | M.DIRS.up][sector]
	var before: int = m.players[slot].input
	for action in M.DIRS:
		var bit: int = M.DIRS[action]
		if (before ^ mask) & bit:
			m.command(slot, action, (mask & bit) != 0)

func _find(m: RefCounted, id: int) -> Dictionary:
	for crit in m.critters:
		if crit.id == id:
			return crit
	return {}

func _clap_and_recovery() -> void:
	var m := _isolated()
	var p: Dictionary = m.players[0]
	p.pos = Vector2.ZERO
	p.face = 0.0
	m._add_critter(Vector2(2.26, 0.16), Vector2.UP, 1, 0)
	m._add_critter(Vector2(1.27, 1.2), Vector2.UP, 1, 0)
	m._add_critter(Vector2(-1.4, 0.05), Vector2.UP, 1, 0)
	m._add_critter(Vector2(2.83, 0.0), Vector2.UP, 1, 0)
	var inside: Dictionary = m.critters[0]
	for i in 8:
		m.command(0, "clap", true)
	m.step(M.STEP)
	_check(inside.impulse.x > 4.5 and inside.impulse.y > 0.0 and p.hits == 1 and p.claps == 1,
		"One clap pushes only the nearby forward-cone target away from the sheriff")
	_check(is_zero_approx(M.heal_fraction(inside, m.tick)) and m.critters.slice(1).all(func(c): return c.recover_tick == M.NO_TICK),
		"Recovery starts at zero for the struck critter only")
	var recovery: int = inside.recover_tick
	var other: Dictionary = m.players[1]
	other.pos = p.pos
	other.face = p.face
	m.command(1, "clap", true)
	m.step(M.STEP)
	_check(other.claps == 1 and other.hits == 0 and inside.recover_tick == recovery,
		"A second sheriff cannot reset the same critter’s recovery")
	m.command(0, "clap", true)
	m.step(float(M.CLAP_COOLDOWN) * M.STEP)
	_check(p.claps == 1 and M.heal_fraction(inside, m.tick) > 0.65 and M.heal_fraction(inside, m.tick) < 1.0,
		"Clap cooldown discards spam while the longer animal recovery keeps filling")
	m.step(float(recovery - m.tick) * M.STEP)
	p.pos = Vector2(inside.pos) - Vector2(2.0, 0.0)
	p.face = 0.0
	m.command(0, "clap", true)
	m.step(M.STEP)
	_check(p.hits > 1 and inside.recover_tick > recovery, "Critter can be struck again after the ring finishes")

	var simultaneous := _isolated()
	simultaneous.players[0].pos = Vector2.ZERO
	simultaneous.players[1].pos = Vector2(0.6, 0.0)
	simultaneous.players[0].face = 0.0
	simultaneous.players[1].face = 0.0
	simultaneous._add_critter(Vector2(1.95, 0.0), Vector2.RIGHT, 1, 0)
	simultaneous.command(0, "clap", true)
	simultaneous.command(1, "clap", true)
	simultaneous.step(M.STEP)
	_check(simultaneous.players[0].hits == 0 and simultaneous.players[1].hits == 1, "Closest simultaneous valid clap wins")

func _rival_steal() -> void:
	var m := _isolated()
	var toward := M.pen(3).normalized()
	var at := M.pen(3) - toward * 2.6
	m.players[0].pos = at - toward * 1.85
	m.players[0].face = toward.angle()
	m._add_critter(at, toward, 2, 0)
	m.command(0, "clap", true)
	m.step(M.STEP)
	_check(m.players[0].hits == 1 and m.players[0].score == 0, "Clapping a gold critter does not claim it")
	m.players[0].pos = M.pen(0)
	m.players[3].pos = at - toward * 1.22
	m.command(3, "down", true)
	m.step(1.05)
	_check(m.players[3].score == 2 and m.players[3].gold == 1 and m.players[0].score == 0 and m.critters.is_empty(),
		"Rival walks a recovering critter into their pen and collects double once")
	m.step(0.12)
	_check(m.players[3].score == 2, "A penned critter cannot score twice")
	m.take_over(3)
	_check(m.players[3].bot and m.players[3].input == 0 and m.players[3].score == 2,
		"Bot takeover clears held input and retains the seat’s score")

func _edge_lane() -> void:
	var m := _isolated()
	var outward := Vector2.RIGHT
	var start := outward * (M.FIELD_RADIUS - 0.03)
	m.players[0].pos = start - outward * 1.10
	m._add_critter(start, outward, 1, 0)
	m.step(0.55)
	var at: Vector2 = m.critters[0].pos
	_check(absf((at - start).dot(outward.orthogonal())) > 1.0 and at.length() <= M.FIELD_RADIUS,
		"Steady outward pressure sends a critter along the fence instead of pinning it")
	print("fence lane: %.2f units displaced in %.2fs under steady outward pressure" % [start.distance_to(at), m.elapsed])

func _hatches() -> void:
	var camper := _isolated()
	var clear := _isolated()
	var time := float(M.FIRST_RELEASE - M.HATCH_WARNING) * M.STEP
	camper.step(time)
	clear.step(time)
	var hatch_id: int = camper.next_hatch
	_check(hatch_id >= 0 and camper.release_tick - camper.tick == M.HATCH_WARNING and camper.critters.is_empty(),
		"Neutral hatch location appears a full 1.5 seconds ahead")
	camper.players[0].pos = M.hatch(hatch_id)
	camper.players[0].face = (-M.hatch(hatch_id)).angle()
	camper.step(float(M.HATCH_WARNING) * M.STEP)
	clear.step(float(M.HATCH_WARNING) * M.STEP)
	var minimum := INF
	for frame in M.LAUNCH_TICKS - 1:
		camper.command(0, "clap", true)
		camper.step(M.STEP)
		clear.step(M.STEP)
	for i in M.HERD_SIZE:
		minimum = minf(minimum, Vector2(camper.critters[i].pos).distance_to(M.hatch(hatch_id)))
		_check(camper.critters[i].pos.is_equal_approx(clear.critters[i].pos), "Camping does not alter a protected launch lane")
	_check(camper.players[0].hits == 0 and minimum > M.CLAP_RANGE, "Herd clears clap range from the hatch before it can be hit")
	print("hatch camping: %d hits, nearest release lane %.2f units at protection end (clap range %.2f)" %
		[camper.players[0].hits, minimum, M.CLAP_RANGE])

	var route: Array[int] = [hatch_id]
	for wave in range(2, 10):
		camper.critters.clear()
		camper.step(float(camper.release_tick - camper.tick) * M.STEP)
		route.append(camper.last_hatch)
		var gold: int = camper.critters.filter(func(c): return c.value == 2).size()
		_check(camper.critters.size() == M.HERD_SIZE and gold == int(wave % 2 == 0), "Every other herd contains one gold critter")
	for i in range(1, route.size()):
		_check(route[i] != route[i - 1], "Hatches never repeat consecutively")
	for i in range(0, route.size(), M.HATCHES):
		_check(route.slice(i, i + M.HATCHES).has(0) and route.slice(i, i + M.HATCHES).has(1) and route.slice(i, i + M.HATCHES).has(2),
			"Each rotation gives every hatch a release")

	var full := _isolated()
	for i in M.MAX_CRITTERS:
		full._add_critter(Vector2.ZERO, Vector2.RIGHT, 1, M.ROUND_TICKS)
	full.step(float(M.FIRST_RELEASE + 1) * M.STEP)
	_check(full.next_hatch == -1 and full.wave == 0 and full.critters.size() == M.MAX_CRITTERS,
		"An overfull field postpones the announcement and keeps the existing critters")

func _seeded_matches() -> void:
	var high_packet := 0
	for seed_value in SEEDS:
		var host := _make(seed_value, true)
		var client := _make(seed_value, false)
		host.step(M.COUNTDOWN)
		var high_herd := 0
		var score_gap := 0.0
		var last_change := 0.0
		var points := 0
		var packet_ok := true
		var replica_ok := true
		while host.phase != "finished":
			host.step(0.05)
			var snap: Dictionary = host.snapshot()
			var packed := var_to_bytes(snap).compress(FileAccess.COMPRESSION_DEFLATE)
			high_packet = maxi(high_packet, packed.size())
			packet_ok = packet_ok and packed.size() < 1000
			var decoded: Dictionary = bytes_to_var(packed.decompress_dynamic(65536, FileAccess.COMPRESSION_DEFLATE))
			client.apply_snapshot(decoded)
			replica_ok = replica_ok and client.snapshot() == snap and client.phase == host.phase and client.winners() == host.winners()
			high_herd = maxi(high_herd, host.critters.size())
			var sum := 0
			for p in host.players:
				sum += int(p.score)
			if sum > points:
				score_gap = maxf(score_gap, host.elapsed - last_change)
				last_change = host.elapsed
				points = sum
		var scores: Array = host.players.map(func(p): return p.score)
		var claps: Array = host.players.map(func(p): return p.claps)
		var hits: Array = host.players.map(func(p): return p.hits)
		_check(scores.min() >= 2 and points >= 28 and host.wave >= 9 and high_herd <= M.MAX_CRITTERS,
			"Six active bots sustain herding through the round (seed %d)" % seed_value)
		_check(claps.max() <= 23 and hits.reduce(func(a, b): return a + b, 0) >= claps.reduce(func(a, b): return a + b, 0) * 0.88,
			"Bots use occasional, deliberate claps (seed %d)" % seed_value)
		_check(packet_ok and replica_ok, "Every 20 Hz snapshot fits and exactly round-trips (seed %d)" % seed_value)
		print("seed %d: scores %s, %d waves, peak %d critters, claps %s, %.1fs longest scoring gap" %
			[seed_value, scores, host.wave, high_herd, claps, maxf(score_gap, 90.0 - last_change)])
		if seed_value == SEEDS.front():
			var replay := _make(seed_value, true)
			replay.step(93.5)
			_check(replay.snapshot() == host.snapshot(), "Fixed ticks make the seeded replay independent of step chunking")
	print("largest DEFLATE snapshot at 20 Hz: %d bytes" % high_packet)
