extends SceneTree
## Runs the actual host model and DEFLATE wire format without loading a venue.

const M = preload("res://games/plate_panic/model.gd")
const SEEDS := [0, 1, 2, 3, 4, 5, 1088, 10577,
	2025966576, 681158627, 1997977686, 2097307919, 1826382604, 1688593873,
	579101445, 628695689, 1475180530, 1261045472, 1076770988, 161548593,
	1718027149, 1337726122, 733694395, 841511162]
const KEYS := [Vector2.RIGHT, Vector2(1, 1), Vector2.DOWN, Vector2(-1, 1),
	Vector2.LEFT, Vector2(-1, -1), Vector2.UP, Vector2(1, -1)]

var _checks := 0
var _failures := 0

func _initialize() -> void:
	_clock_and_movement()
	_tilt_authority()
	_bot_counters_parked_weight()
	_solo_parking_vs_keyboard()
	_solo_repeated_steering()
	_solo_blind_wedge_cadence()
	_six_wedge_shots()
	_wedge_against_tilt()
	_wedge_limits()
	_drop_and_stall()
	_final_tick_wire()
	_symmetric_drop_bags()
	_seeded_matches()
	print("PLATE_PANIC_RULES %s: %d checks, %d failures" % ["PASS" if _failures == 0 else "FAIL", _checks, _failures])
	quit(mini(_failures, 1))

func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		printerr("FAIL: ", message)

func _make(seed_value: int = 1, bots: bool = false) -> RefCounted:
	var m := M.new()
	var seats: Array = []
	for i in M.SEATS:
		seats.append({"name": "P%d" % (i + 1), "peer": i + 1, "bot": bots})
	m.begin(seed_value, seats, 42)
	return m

func _empty(seed_value: int = 1) -> RefCounted:
	var m := _make(seed_value)
	m.step(M.COUNTDOWN)
	m.marbles.clear()
	return m

func _steer(m: RefCounted, slot: int, key: Vector2) -> void:
	m.command(slot, "up", key.y < 0.0)
	m.command(slot, "down", key.y > 0.0)
	m.command(slot, "left", key.x < 0.0)
	m.command(slot, "right", key.x > 0.0)

func _total(scores: Array) -> int:
	return scores.reduce(func(a, b): return a + b, 0)

func _clock_and_movement() -> void:
	var m := _make()
	var start: Vector2 = m.players[0].pos
	var initial: Array[Dictionary] = m.marbles.duplicate(true)
	m.command(0, "wedge", true)
	m.command(0, "right", true)
	m.command(0, "down", true)
	m.step(M.COUNTDOWN - M.STEP)
	_check(m.phase == "countdown" and m.tick == 0 and m.players[0].pos == start and m.marbles == initial,
		"Countdown freezes players and marbles")
	m.step(M.STEP)
	_check(m.phase == "running" and m.tick == 0 and m.countdown == 0.0, "GO starts at the end of 180 clock ticks")
	m.step(0.15)
	var moved: Vector2 = m.players[0].pos - start
	_check(moved.x > 0.0 and is_equal_approx(moved.x, moved.y) and m.players[0].wedge_tick == M.NO_TICK,
		"Digital diagonal movement starts on GO and early wedge taps are discarded")
	_check(is_equal_approx(M.direction(10).length(), 1.0) and M.direction(15).is_zero_approx(), "Diagonals are normalized and opposition cancels")
	m.command(0, "wedge", true)
	m.take_over(0)
	_check(m.players[0].bot and m.players[0].input == 0 and not m.players[0].queued and m.players[0].peer == 1,
		"Bot takeover transfers the seat and clears pending commands")
	m.step(100.0)
	var frozen: Dictionary = m.snapshot()
	m.step(4.0)
	m.command(1, "wedge", true)
	m.take_over(1)
	_check(m.phase == "finished" and m.tick == M.ROUND_TICKS and m.elapsed == 90.0 and m.remaining() == 0.0 and m.snapshot() == frozen,
		"The scoreboard freezes exactly at 90 seconds")
	m.players[2].score = 301
	m.players[4].score = 301
	m.players[4].last_score = 80
	_check(m.ranking().slice(0, 2) == [2, 4] and m.winners() == [2, 4], "Tied leaders share the win")

func _tilt_authority() -> void:
	var m := _make()
	m.step(M.COUNTDOWN + 1.0)
	_check(m.tilt == Vector2.ZERO, "Six symmetric standing players cancel to zero slope")
	m.command(0, "up", true)
	m.step(M.STEP)
	var first: Vector2 = m.tilt
	m.step(1.5)
	_check(first.y < 0.0 and first.length() < 0.01 and m.tilt.dot(Vector2.UP) > 0.20,
		"One moving player tilts the table gradually even with all six slots occupied")
	for i in range(1, M.SEATS):
		m.command(i, "up", true)
	m.step(3.0)
	_check(m.tilt.length() <= 1.000001 and m.tilt.dot(Vector2.UP) > 0.99,
		"Coordinated weight reaches the slope cap")
	_check(m.players.all(func(p): return Vector2(p.pos).length() <= M.FIELD_RADIUS + 0.00001), "The rim bounds all six players")
	var tilt_only: Array[int] = []
	for slot in M.SEATS:
		var lane := _empty()
		var outward := M.pocket(slot).normalized()
		lane.players[slot].pos += outward * 4.5
		lane._add_marble(1, outward * 4.0, Vector2.ZERO)
		lane.step(3.0)
		tilt_only.append(lane.players[slot].score)
	_check(tilt_only == [1, 1, 1, 1, 1, 1], "Each seat can score a center-lane roll by tilt alone with five other seats on the table")

func _bot_counters_parked_weight() -> void:
	var m := _make(626106622, true)
	m.players[0].bot = false
	m.step(M.COUNTDOWN)
	m.command(0, "up", true)
	m.step(36 * M.STEP)
	_check(m._parked_rival() == -1, "The CPUs give the player time before responding to pocket pressure")
	m.step(18 * M.STEP)
	m.command(0, "up", false)
	m.step(2.5)
	var flank := 4 if m._drop_turn > 0.0 else 2
	_check(m._parked_rival() == 0 and m.players[3].pos.y > M.FIELD_RADIUS - 0.15
		and Vector2(m.players[flank].pos).dot(M.pocket(flank).normalized()) > M.FIELD_RADIUS - 0.15,
		"The opposite CPU and one flank lean back after the Solo player parks")
	m.command(0, "down", true)
	m.step(1.2)
	_check(m._parked_rival() == -1, "The CPUs release their counter when the player moves out of their pocket lane")
	var aiming := _make(626106622, true)
	aiming.players[0].bot = false
	aiming.step(M.COUNTDOWN)
	aiming.command(0, "up", true)
	aiming.step(9 * M.STEP)
	aiming.command(0, "up", false)
	aiming.step(0.24)
	aiming.command(0, "wedge", true)
	aiming.step(M.STEP)
	_check(aiming.players[0].pos.y < -M.PARKED_LEAN and aiming._parked_rival() == -1
		and aiming.players[0].wedge_tick == aiming.tick,
		"A short stop to aim and place a wedge leaves the CPUs free to chase")

func _solo_repeated_steering() -> void:
	for approach: int in [24, 60]:
		for pulse: int in [3, 6, 9, 12]:
			var moves := [[Vector2.LEFT, pulse], [Vector2.ZERO, 36], [Vector2.RIGHT, pulse], [Vector2.ZERO, 36]]
			_check(_solo_steering_cannot_win(approach, moves),
				"An Up approach of %d ticks followed by repeated %d-tick lateral pulses cannot evade Solo defense" % [approach, pulse])
	for duration: int in [24, 40, 72]:
		var moves := [[Vector2(1, -1), duration], [Vector2(-1, -1), duration]]
		_check(_solo_steering_cannot_win(65, moves), "Alternating %d-tick outward diagonals cannot win Solo" % duration)
	for approach: int in [12, 18, 24]:
		var lateral := [[Vector2.RIGHT, 18], [Vector2.LEFT, 18]]
		_check(_solo_steering_cannot_win(approach, lateral, 18),
			"Continuous lateral steering after a %d-tick approach cannot win Solo" % approach)
	var radial := [[Vector2.DOWN, 24], [Vector2.ZERO, 13], [Vector2.UP, 24], [Vector2.ZERO, 13]]
	_check(_solo_steering_cannot_win(65, radial), "Repeated shallow trips inward from the rim cannot win Solo")
	for duration: int in [24, 32, 54]:
		var mid_lane := [[Vector2.UP, duration], [Vector2.DOWN, duration]]
		_check(_solo_steering_cannot_win(24, mid_lane, 18, duration / 2),
			"Repeated %d-tick radial steering in the middle of the lane cannot win Solo" % duration)

func _solo_steering_cannot_win(approach: int, moves: Array, pause: int = 0, retreat: int = 0) -> bool:
	var m := _make(626106622, true)
	m.players[0].bot = false
	m.step(M.COUNTDOWN)
	_steer(m, 0, Vector2.UP)
	m.step(approach * M.STEP)
	_steer(m, 0, Vector2.ZERO)
	m.step(pause * M.STEP)
	_steer(m, 0, Vector2.DOWN)
	m.step(retreat * M.STEP)
	while m.phase == "running":
		for move: Array in moves:
			_steer(m, 0, move[0])
			m.step(int(move[1]) * M.STEP)
	return 0 not in m.winners()

func _solo_blind_wedge_cadence() -> void:
	var m := _make(626106622, true)
	m.players[0].bot = false
	m.step(M.COUNTDOWN)
	var defended_ticks := 0
	while m.phase == "running":
		var key := Vector2.ZERO
		if m.tick < 18:
			key = Vector2.UP
		elif m.tick >= 36:
			key = Vector2.DOWN if (m.tick - 24) % 48 < 24 else Vector2.UP
		_steer(m, 0, key)
		if m.tick % 192 == 53:
			m.command(0, "wedge", true)
		m.step(M.STEP)
		defended_ticks += int(m._parked_rival() == 0)
	_check(defended_ticks >= 600 and m.players[0].score <= 48,
		"Repeated radial steering and blind wedge taps leave time for a CPU response")

func _solo_parking_vs_keyboard() -> void:
	# Solo always assigns the human the north seat. Rotating the human
	# between seats would conceal how well holding Up works from this seat.
	var totals := {}
	var active_wins := 0
	var redirects := 0
	for seed_value in [626106622, 827827120, 823720998, 819604056]:
		for duration: int in [0, 12, 42, 54, 66, M.ROUND_TICKS, -1]:
			var m := _make(seed_value, true)
			m.players[0].bot = false
			m.step(M.COUNTDOWN)
			while m.phase == "running":
				if duration == -1:
					var aim: Vector2 = m._bot_move(0)
					var place: bool = m.players[0].queued
					m.players[0].queued = false
					var key: Vector2 = KEYS[posmod(roundi(aim.angle() / (PI / 4.0)), KEYS.size())]
					_steer(m, 0, key if aim.length_squared() > 0.19 ** 2 else Vector2.ZERO)
					if place:
						m.command(0, "wedge", true)
				else:
					m.command(0, "up", m.tick < duration)
				m.step(3 * M.STEP)
			var score: int = m.players[0].score
			totals[duration] = totals.get(duration, 0) + score
			if duration == -1:
				active_wins += int(m.winners() == [0])
				redirects += m.players[0].deflections
			elif duration > 0:
				_check(0 not in m.winners(), "Parking Up for %d ticks cannot win Solo seed %d" % [duration, seed_value])
	_check(totals[-1] > totals[0] and totals[-1] > totals[M.ROUND_TICKS] and active_wins > 0,
		"Keyboard play wins rounds and outscores idle or holding Up across the paired Solo seeds")
	_check(redirects >= 40, "Keyboard play reliably redirects marbles across the paired Solo seeds")
	print("Solo north seat: points by Up duration (keyboard = -1) %s, keyboard wins %d" % [totals, active_wins])

func _six_wedge_shots() -> void:
	var m := _empty()
	# Digital aiming per seat, including the four pockets between D-pad headings.
	for slot in M.SEATS:
		var goal := M.pocket(slot)
		var key: Vector2 = KEYS[posmod(roundi(goal.angle() / (PI / 4.0)), KEYS.size())]
		var shot := key.normalized()
		var site := goal - shot * 4.35
		var cross := shot.orthogonal()
		m.players[slot].pos = site - shot * M.WEDGE_OFFSET
		m._add_marble(slot + 1, site - cross * 1.28, cross * 3.3)
		_steer(m, slot, key)
		m.command(slot, "wedge", true)
	m.step(M.STEP)
	for slot in M.SEATS:
		_steer(m, slot, Vector2.ZERO)
	m.step(0.99)
	var scores: Array = m.players.map(func(p): return p.score)
	var redirects: Array = m.players.map(func(p): return p.deflections)
	_check(scores == [1, 1, 1, 1, 1, 1] and redirects == scores and m.tilt.is_zero_approx(),
		"Six simultaneous digital wedge shots each score on a balanced table")
	print("six balanced shots: scores=%s redirects=%s" % [scores, redirects])

func _wedge_against_tilt() -> void:
	var results: Array = []
	for use_wedge in [false, true]:
		var m := _empty()
		var shot := Vector2.UP
		var site := M.pocket(0) - shot * 4.8
		m.players[0].pos = site - shot * M.WEDGE_OFFSET
		for slot in range(1, M.SEATS):
			m.players[slot].pos = Vector2.DOWN * 9.6
		m.step(1.0)
		_check(m.tilt.dot(Vector2.DOWN) > 0.99, "Five rivals can hold a full adverse slope")
		m._add_marble(1, site + shot * 1.21, Vector2.DOWN * 4.0)
		m.command(0, "up", true)
		if use_wedge:
			m.command(0, "wedge", true)
		m.step(M.STEP)
		m.command(0, "up", false)
		m.step(0.88)
		results.append([m.players[0].score, m.players[0].deflections])
		if use_wedge:
			_check(m.players[0].last_deflect > m.players[0].wedge_tick,
				"An actual uphill redirect records contact after wedge placement")
	_check(results == [[0, 0], [1, 1]], "A deliberate wedge reverses the incoming roll and scores uphill under maximum tilt")

func _wedge_limits() -> void:
	var opening_clear := true
	for seed_value in SEEDS:
		var opening := _make(seed_value)
		opening.step(M.COUNTDOWN)
		for i in M.SEATS:
			opening.command(i, "wedge", true)
		opening.step(M.STEP)
		opening_clear = opening_clear and opening.players.all(func(p): return p.wedge_tick == 1)
	_check(opening_clear, "All seats can place their starting wedge on GO")
	var m := _empty()
	var p: Dictionary = m.players[0]
	var shot := Vector2.RIGHT
	m.command(0, "right", true)
	m.step(3 * M.STEP)
	m.command(0, "right", false)
	m.step(8 * M.STEP)
	p.pos = M.pocket(0) - shot * M.WEDGE_OFFSET
	m.command(0, "wedge", true)
	m.step(M.STEP)
	_check(p.wedge_tick == M.NO_TICK, "No wedges inside a pocket")
	p.pos = m._drop_sites[0] - shot * M.WEDGE_OFFSET
	m.command(0, "wedge", true)
	m.step(M.STEP)
	_check(p.wedge_tick == M.NO_TICK, "No wedges at future drop sites")
	var site := Vector2(0, -5.0)
	p.pos = site - shot * M.WEDGE_OFFSET
	m._add_marble(1, site, Vector2.ZERO)
	m.command(0, "wedge", true)
	m.step(M.STEP)
	var placed: int = p.wedge_tick
	_check(placed == m.tick and p.wedge_pos == site and is_zero_approx(p.wedge_face) and p.deflections == 0 and p.last_deflect == M.NO_TICK,
		"A wedge remembers the released direction and cannot launch a marble already over it")
	m.step((M.WEDGE_LIFE - 1) * M.STEP)
	_check(m.tick - p.wedge_tick == M.WEDGE_LIFE - 1, "Wedge remains active through its final whole tick")
	m.marbles.clear()
	m._add_marble(1, site - shot * (M.WEDGE_RADIUS + 0.025), shot * 5.0)
	m.command(0, "wedge", true)
	m.step(M.STEP)
	_check(m.tick - p.wedge_tick == M.WEDGE_LIFE and p.deflections == 0,
		"Expired wedge does not redirect and cannot immediately be replaced")
	m.step((M.WEDGE_COOLDOWN - M.WEDGE_LIFE - 1) * M.STEP)
	m.command(0, "wedge", true)
	m.step(M.STEP)
	_check(p.wedge_tick == placed + M.WEDGE_COOLDOWN, "The next tap works on the first tick off cooldown")

func _drop_and_stall() -> void:
	var m := _empty()
	var at := M.pocket(2)
	m._add_marble(8, at - at.normalized() * 1.32, at.normalized() * 5.0)
	m.step(M.STEP)
	_check(m.players[2].score == 1 and m.players[2].last_score == m.tick and m.marbles.is_empty() and m.drops.size() == 1,
		"Crossing a pocket scores for its owner and reserves a drop")
	var drop: Dictionary = m.drops[0].duplicate()
	m.step((M.DROP_PREVIEW - 1) * M.STEP)
	_check(m.marbles.is_empty() and m.drops[0] == drop and drop.tick == m.tick + 1,
		"The stable preview precedes the due tick")
	m.step(M.STEP)
	_check(m.drops.is_empty() and m.marbles.size() == 1 and m.marbles[0].pos == drop.pos and m.marbles[0].id == drop.id,
		"The scored marble reappears at the previewed point with the same ID")
	m.marbles.clear()
	m._add_marble(9, Vector2.ZERO, Vector2.ZERO)
	m.step((M.STUCK_TICKS - 1) * M.STEP)
	_check(m.marbles.size() == 1 and m.drops.is_empty(), "An idle marble is allowed time to be recovered by players")
	m.step(M.STEP)
	_check(m.marbles.is_empty() and m.drops.size() == 1 and m.drops[0].id == 9 and m.players[2].score == 1,
		"A genuinely stuck marble previews the same neutral reset without a point")
	var rim := _empty()
	for p in rim.players:
		p.pos = Vector2.RIGHT * 9.0
	rim.step(1.0)
	rim._add_marble(1, Vector2.RIGHT * (M.FIELD_RADIUS - M.MARBLE_RADIUS), Vector2.ZERO)
	rim.step(M.STUCK_TICKS * M.STEP)
	_check(rim.marbles.is_empty() and rim.drops.size() == 1, "A marble pinned to the boundary by tilt also resets")

func _final_tick_wire() -> void:
	var host := _empty()
	var replica := _make()
	host.tick = M.ROUND_TICKS - 2
	host.elapsed = host.tick * M.STEP
	host.players[1].score = 301
	host.players[4].score = 300
	host.players[4].deflections = 270
	# A wedge here clears both the pocket and the drop lanes.
	host.players[0].pos = M.pocket(0) * 0.60
	host.command(0, "wedge", true)
	host.step(M.STEP)
	var anchor := M.pocket(4)
	host._add_marble(8, anchor + anchor.direction_to(Vector2.ZERO) * 1.32, anchor.normalized() * 5.0)
	host.step(M.STEP)
	var wire := var_to_bytes(host.snapshot()).compress(FileAccess.COMPRESSION_DEFLATE)
	replica.apply_snapshot(bytes_to_var(wire.decompress_dynamic(65536, FileAccess.COMPRESSION_DEFLATE)))
	_check(replica.phase == "finished" and replica.winners() == [1, 4] and replica.players[4].last_score == M.ROUND_TICKS
		and replica.players[4].score == 301 and replica.players[4].deflections == 270,
		"The final scoring tick, ties and multi-byte counters survive the wire")
	_check(replica.snapshot() == host.snapshot() and replica.players[0].wedge_tick == M.ROUND_TICKS - 1
		and replica.drops[0].tick == M.ROUND_TICKS + M.DROP_PREVIEW,
		"The final active wedge and future drop remain exact on the frozen scoreboard")

func _symmetric_drop_bags() -> void:
	var fair := true
	for seed_value in SEEDS:
		var m := _empty(seed_value)
		var previous := Vector2.INF
		for cycle in 3:
			var sum := Vector2.ZERO
			var points := {}
			for lane in M.SEATS:
				m._queue_drop(1)
				var at: Vector2 = m.drops.pop_back().pos
				fair = fair and at != previous and is_equal_approx(at.length(), M.DROP_DISTANCE)
				points[at] = true
				previous = at
				sum += at
			fair = fair and points.size() == M.SEATS and sum.length() < 0.00001
			var positions := points.keys()
			for at: Vector2 in positions:
				var adjacent := positions.filter(func(other): return is_equal_approx(at.distance_to(other), M.DROP_DISTANCE))
				fair = fair and adjacent.size() == 2
	_check(fair, "Every seed supplies all six equally spaced neutral lanes once per bag without immediate repeats")

func _seeded_matches() -> void:
	var high_packet := 0
	var by_seat := [0, 0, 0, 0, 0, 0]
	for seed_value in SEEDS:
		var host := _make(seed_value, true)
		var client := _make(seed_value)
		var wire_ok := true
		var identity_ok := true
		var bounds_ok := true
		var full_samples := 0
		var samples := 0
		var most_idle := 0
		var last_point := 0
		var previous_score := 0
		while host.phase != "finished":
			host.step(3 * M.STEP)
			var snap: Dictionary = host.snapshot()
			var packed := var_to_bytes(snap).compress(FileAccess.COMPRESSION_DEFLATE)
			high_packet = maxi(high_packet, packed.size())
			client.apply_snapshot(bytes_to_var(packed.decompress_dynamic(65536, FileAccess.COMPRESSION_DEFLATE)))
			wire_ok = wire_ok and packed.size() < 450 and client.snapshot() == snap and client.phase == host.phase
			var in_play: Array = host.marbles + host.drops
			var ids := {}
			for item in in_play:
				ids[item.id] = true
			identity_ok = identity_ok and in_play.size() == M.MARBLE_COUNT and ids.size() == M.MARBLE_COUNT
			bounds_ok = bounds_ok and host.tilt.length() <= 1.000001 and client.tilt.length() <= 1.0
			full_samples += int(host.marbles.size() >= 8)
			samples += 1
			var total := _total(host.players.map(func(p): return p.score))
			if total > previous_score:
				most_idle = maxi(most_idle, host.tick - last_point)
				last_point = host.tick
				previous_score = total
		var scores: Array = host.players.map(func(p): return p.score)
		var redirects: Array = host.players.map(func(p): return p.deflections)
		most_idle = maxi(most_idle, host.tick - last_point)
		print("bot seed %d: scores=%s redirects=%s longest gap=%.2fs at least eight live=%.1f%%" %
			[seed_value, scores, redirects, most_idle * M.STEP, 100.0 * full_samples / samples])
		_check(wire_ok and client.winners() == host.winners() and client.ranking() == host.ranking(),
			"20 Hz wire round-trips byte for byte through the final scoreboard (seed %d)" % seed_value)
		_check(identity_ok and bounds_ok and full_samples > samples * 0.62, "Marbles are conserved and the table remains populated (seed %d)" % seed_value)
		_check(scores.min() >= 5 and _total(scores) >= 90 and most_idle <= 6 * M.HZ,
			"Every bot scores with sustained six-seat scoring (seed %d)" % seed_value)
		_check(redirects.min() >= 5, "All six bots actually redirect marbles (seed %d)" % seed_value)
		for slot in M.SEATS:
			by_seat[slot] += scores[slot]
		if seed_value == SEEDS[0]:
			var replay := _make(seed_value, true)
			replay.step(M.COUNTDOWN + M.ROUND_TIME)
			_check(replay.snapshot() == host.snapshot(), "Seeded simulation is deterministic across step chunking")
			var final: Dictionary = client.snapshot()
			client.apply_snapshot({"tick": 0, "count": 0, "id": 99, "state": PackedByteArray([0, 0])})
			_check(client.snapshot() == final, "Malformed packet does not alter the replica")
	_check(by_seat.max() <= by_seat.min() * 1.45, "The benchmark seeds show no persistent high-scoring seat")
	print("aggregate scores by seat: %s, peak DEFLATE snapshot: %d bytes" % [by_seat, high_packet])
