extends SceneTree

const Model = preload("res://games/bandwagon/model.gd")

var _errors := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, caption: String) -> void:
	if not ok:
		_errors += 1
		print("FAIL: ", caption)

func round_with(active: Array, bots: Array = [], seed_value: int = 75) -> RefCounted:
	var seats: Array = []
	for slot in Model.SEATS:
		seats.append({"name": "P%d" % (slot + 1), "peer": slot + 1,
			"active": slot in active, "bot": slot in bots})
	var state := Model.new()
	state.begin(seed_value, seats, 23)
	state.step(Model.COUNTDOWN)
	return state

func tick(state: RefCounted, count: int = 1) -> void:
	state.step(count * Model.STEP)

func hitch(state: RefCounted, slot: int) -> void:
	state.command(slot, "up", true)
	state.command(slot, "hold", true)
	tick(state, 3)
	state.command(slot, "up", false)

func walk(state: RefCounted, slot: int, axis: String, ticks: int) -> void:
	state.command(slot, axis, true)
	tick(state, ticks)
	state.command(slot, axis, false)

func run() -> void:
	test_fair_crests()
	test_latch_and_cross()
	test_booth_loops()
	test_snapshots()
	print("BANDWAGON_RULES ", "PASS" if _errors == 0 else "FAIL %d" % _errors)
	quit(int(_errors > 0))

func test_fair_crests() -> void:
	for seats in [2, 3, 4, 5, 6]:
		var state := round_with(range(seats))
		var blanks := PackedInt32Array()
		blanks.resize(seats)
		var tie_matches := PackedInt32Array()
		tie_matches.resize(seats)
		var left_crests := PackedInt32Array()
		left_crests.resize(seats)
		var last_tie := 0
		for fork in Model.FORKS:
			check(state.fork == fork and state.tiebreak != last_tie, "tie arrow alternates every fork")
			last_tie = state.tiebreak
			var crests := [-1, 0, 1].map(func(crest):
				return state.players.filter(func(p): return p.active and p.crest == crest).size())
			check(crests == [seats / 2, seats % 2, seats / 2], "each fork evenly divides both crests")
			for slot in seats:
				var p: Dictionary = state.players[slot]
				blanks[slot] += int(p.crest == 0)
				left_crests[slot] += int(p.crest == -1)
				tie_matches[slot] += int(state.tiebreak == p.crest)
			tick(state, Model.FORK_TICKS)
		check(state.phase == "finished" and state.elapsed == 90.0, "six forks in exactly ninety seconds")
		check(Array(tie_matches).max() - Array(tie_matches).min() <= 1, "ties are balanced across starting seats")
		check(Array(blanks).max() - Array(blanks).min() <= 1, "odd blanks rotate evenly")
		if seats == 3:
			check(Array(left_crests) == [2, 2, 2], "three-person crew gets two starts with each crest")

func test_latch_and_cross() -> void:
	var state := round_with([0, 2, 5])
	var permuted := round_with([0, 2, 5])
	for pair in [[state, [0, 2, 5]], [permuted, [5, 2, 0]]]:
		var match_state: RefCounted = pair[0]
		for slot in pair[1]:
			match_state.command(slot, "up", true)
			match_state.command(slot, "hold", true)
		tick(match_state, 3)
		for slot in pair[1]:
			match_state.command(slot, "up", false)
	check(state.snapshot() == permuted.snapshot(), "same-tick latch commands commute")
	check(state.players[0].riding and state.players[2].riding and state.players[5].riding,
		"sparse simultaneous seats all ride their own hitches")
	check(state.players[0].hitch != state.players[5].hitch, "hitches have distinct wide targets")

	state.command(0, "left", true)
	state.command(2, "right", true)
	tick(state)
	check(state.left_pulls == 1 and state.right_pulls == 1 and state.lead_route() == state.tiebreak,
		"opposing tugs follow the advertised tie, neutral rides without voting")
	state.command(5, "left", true)
	tick(state)
	check(state.lead_route() == -1 and state.left_pulls == 2, "majority overrides the tie route")
	state.command(0, "hold", false)
	tick(state)
	check(not state.players[0].riding and state.left_pulls == 1, "release removes a seat's tug")
	state.command(5, "left", false)
	tick(state, Model.LOCK_TICK - state.tick)
	check(state.locked_route == 1 and state.locked_riders == ((1 << 2) | (1 << 5)),
		"lock seals the current majority and exactly the riders")
	state.command(2, "hold", false)
	state.command(5, "left", true)
	tick(state, Model.CROSS_TICK - Model.LOCK_TICK - 1)
	check(state.players[2].riding and state.players[5].pull == 0 and state.players[2].score == 0,
		"release and tug cannot change the locked result, which stays public before crossing")
	check(Model.CROSS_TICK - Model.LOCK_TICK >= Model.HZ / 2, "lock precedes crossing by at least a beat")
	tick(state)
	for p in state.players:
		if p.active:
			var expected: int = 1 + int(p.crest == 1) if p.slot in [2, 5] else 0
			check(p.score == expected and p.last_points == expected, "crossing banks the advertised 0, 1, or 2")
	tick(state, Model.FORK_TICKS - Model.CROSS_TICK)
	check(state.fork == 1 and state.locked_route == 0 and not state.players[5].riding,
		"the next fork restores the starting lane and clears the prior lock")

func test_booth_loops() -> void:
	for route in [-1, 1]:
		var slot := 5 if route == -1 else 0
		var state := round_with(range(Model.SEATS))
		hitch(state, slot)
		var p: Dictionary = state.players[slot]
		p.crest = -route
		var outward := "left" if route == -1 else "right"
		var inward := "right" if route == -1 else "left"
		var across := ceili((absi(p.hitch.x - Model.BOOTHS[route].x) - Model.BOOTH_RANGE.x) / float(Model.MOVE))
		# Put the widest possible trip at the threshold. The last horizontal
		# step crosses into the marked pad on the last valid booth tick.
		tick(state, Model.BOOTH_CLOSE_TICK - 1 - across - 3 - state.tick)
		state.command(slot, "hold", false)
		walk(state, slot, "down", 3)
		walk(state, slot, outward, across)
		check(state.tick == Model.BOOTH_CLOSE_TICK - 1 and p.crest == route, "last safe booth entry switches the crest")
		state.command(slot, "hold", true)
		walk(state, slot, inward, across)
		walk(state, slot, "up", 3)
		check(p.riding and state.tick < Model.LOCK_TICK, "farthest seat returns from either booth at base speed")
		check(2 * (across + 3) <= Model.LOCK_TICK - Model.BOOTH_CLOSE_TICK, "a full loop fits the three-second margin")

		var late := round_with(range(Model.SEATS))
		late.players[slot].crest = -route
		tick(late, Model.BOOTH_CLOSE_TICK - across)
		walk(late, slot, outward, across)
		check(late.players[slot].crest == -route, "entry at closing tick cannot change crest")

func test_snapshots() -> void:
	var config := [0, 3, 5]
	var host := round_with(config, [3, 5])
	var guest := round_with(config)
	check(host.snapshot().state.size() == 51, "snapshot packs all six seats and sealed result into 51 bytes")
	for age in [3, Model.BOOTH_CLOSE_TICK, Model.LOCK_TICK, Model.CROSS_TICK, Model.FORK_TICKS]:
		tick(host, age - host.tick)
		guest.apply_snapshot(host.snapshot())
		check(guest.snapshot() == host.snapshot() and guest.lead_route() == host.lead_route(),
			"guest agrees on position, score, pulls, route and frozen results")
	tick(host, Model.LOCK_TICK)
	guest.apply_snapshot(host.snapshot())
	var before: Dictionary = guest.snapshot()
	var malformed := before.duplicate(true)
	malformed.state.encode_u8(2, 0xFF)
	guest.apply_snapshot(malformed)
	check(guest.snapshot() == before, "invalid bonus mask is rejected without mutation")
	malformed = before.duplicate(true)
	malformed.state.encode_s8(0, -host.locked_route)
	guest.apply_snapshot(malformed)
	check(guest.snapshot() == before, "a locked route inconsistent with the frozen tally is rejected")
	guest.command(3, "hold", false)
	tick(guest, 5)
	check(guest.snapshot() == before, "the guest cannot change the authoritative fixed-tick state")
	tick(host, Model.ROUND_TICKS - host.tick)
	guest.apply_snapshot(host.snapshot())
	check(host.players[3].score > 0 and host.players[5].score > 0, "optional bots engage and score")
	check(guest.phase == "finished" and guest.snapshot() == host.snapshot() and guest.winners() == host.winners(),
		"final results stay synchronized")
