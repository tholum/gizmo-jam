extends SceneTree

const Model = preload("res://games/hat_clause/model.gd")

var _errors := 0

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, detail: String) -> void:
	if not ok:
		_errors += 1
		print("FAIL: ", detail)

func round_with(active: Array, bots: Array = [], seed_value: int = 3) -> RefCounted:
	var seats: Array = []
	for slot in Model.SEATS:
		seats.append({"name": "P%d" % (slot + 1), "active": slot in active, "bot": slot in bots})
	var state := Model.new()
	state.begin(seed_value, seats, 43)
	state.step(Model.COUNTDOWN)
	return state

func advance(state: RefCounted, ticks: int = 1) -> void:
	state.step(ticks * Model.STEP)

func tap(state: RefCounted, slot: int) -> void:
	state.command(slot, "tap", true)
	state.command(slot, "tap", false)

func _run() -> void:
	test_targets()
	test_swaps()
	test_fitting()
	test_deals()
	test_snapshots()
	print("HAT_CLAUSE_RULES ", "PASS" if _errors == 0 else "FAIL %d" % _errors)
	quit(int(_errors > 0))

func test_targets() -> void:
	var state := round_with([0, 2, 3])
	state.players[0].pos = Vector2i(400, 300)
	state.players[2].pos = Vector2i(350, 300)
	state.players[3].pos = Vector2i(450, 300)
	state.players[0].target = 3
	advance(state)
	check(state.players[0].target == 3, "equal-distance preview preserves the current target")
	state.players[0].target = -1
	advance(state)
	check(state.players[0].target == 2, "equal-distance preview otherwise uses stable seat order")
	state.command(0, "right", true)
	advance(state)
	state.command(0, "right", false)
	check(state.players[0].target == 3, "walking makes crowded nearby partners selectable")
	state.players[0].hat = state.players[3].hat
	tap(state, 0)
	tap(state, 3)
	advance(state)
	check(state.players[0].offer == -1 and state.players[3].offer == -1, "same-pattern hats cannot be offered")

func _pair_seats(state: RefCounted) -> void:
	for slot in Model.SEATS:
		var p: Dictionary = state.players[slot]
		p.pos = Vector2i(160 + (slot >> 1) * 225 + (slot % 2) * 48, 303)
		p.hat = slot % 2

func test_swaps() -> void:
	var state := round_with(range(Model.SEATS))
	_pair_seats(state)
	tap(state, 0)
	advance(state)
	check(state.players[0].offer == 1 and state.players[0].score == 0, "one offer never exchanges hats")
	tap(state, 0)
	advance(state)
	check(state.players[0].offer == -1, "tapping an unmatched offer cancels it")
	tap(state, 0)
	advance(state)
	state.players[0].pos.y = 224
	state.players[1].pos.y = 373
	advance(state)
	check(state.players[0].offer == -1, "moving out of range cancels the offer")

	_pair_seats(state)
	for slot in [4, 2, 0, 5, 1, 3]:
		tap(state, slot)
	advance(state)
	for p in state.players:
		check(p.hat == 1 - p.slot % 2 and p.score == 1 and p.trade_paid and p.trade_partner == (p.slot ^ 1),
			"three disjoint reciprocal offers swap and pay together")
	for slot in [5, 4, 3, 2, 1, 0]:
		tap(state, slot)
	advance(state)
	for p in state.players:
		check(p.hat == p.slot % 2 and p.score == 1 and not p.trade_paid, "repeat swaps still exchange hats once and pay no extra point")
	advance(state, Model.BELL_TICKS - 1 - state.tick)
	var before: int = state.players[0].score
	var expected := 2 * int(state.players[0].hat == state.players[0].want)
	for slot in Model.SEATS:
		tap(state, slot)
	advance(state)
	check(state.bell == 1 and state.players[0].score == before + expected, "bell takes precedence over taps and banks the match once")
	check(not state.players[0].traded and state.players[0].trade_tick == -1, "new bell resets exchange state")

func test_fitting() -> void:
	var early := round_with([0, 1])
	early.players[0].pos = early.players[0].spot
	early.players[1].pos = Model.FLOOR_MAX
	tap(early, 0)
	advance(early)
	check(early.players[0].fit_started == -1, "reserve cannot be used early")

	var state := round_with(range(Model.SEATS))
	for p in state.players:
		p.pos = p.spot
	advance(state, Model.CUTOFF_TICK - 1 - state.tick)
	for p in state.players:
		check(state.can_fit(p), "final valid fitting tap is announced")
		tap(state, p.slot)
	advance(state)
	for p in state.players:
		check(p.fit_started == Model.CUTOFF_TICK and p.hat != p.want, "last valid tap starts a full two-second fitting")
		state.command(p.slot, "down", true)
	advance(state, Model.FIT_TICKS - 1)
	for p in state.players:
		check(p.pos == p.spot and p.score == 0 and p.hat != p.want, "fitting commits movement and delays hat change")
	advance(state)
	for p in state.players:
		check(p.score == 2 and p.last_points == 2 and p.fit_started == -1 and p.hat != p.want,
			"last-tick fitting completes before single bell payout and reset")

	var late := round_with([1, 4])
	late.players[1].pos = late.players[1].spot
	advance(late, Model.CUTOFF_TICK)
	check(not late.can_fit(late.players[1]), "public fitting prompt closes a tick before taps arrive too late")
	tap(late, 1)
	advance(late)
	check(late.players[1].fit_started == -1, "too-late fitting tap does not commit")

	var overlap := round_with([0, 1])
	overlap.players[0].pos = overlap.players[0].spot
	overlap.players[1].pos = overlap.players[1].spot + Vector2i(0, 39)
	advance(overlap, Model.RESERVE_TICK)
	tap(overlap, 1)
	advance(overlap)
	tap(overlap, 0)
	advance(overlap)
	check(overlap.players[0].traded and overlap.players[0].fit_started == -1,
		"accepting a reciprocal offer takes precedence on a fitting spot")

func test_deals() -> void:
	for active in [[1, 4], [0, 3, 5], [0, 1, 3, 4], [0, 1, 2, 3, 5], range(Model.SEATS)]:
		var state := round_with(active)
		var desirable := {}
		var reciprocal := {}
		for slot in active:
			desirable[slot] = 0
			reciprocal[slot] = 0
		for bell in Model.BELLS:
			var patterns := {}
			for slot in active:
				var p: Dictionary = state.players[slot]
				patterns[p.hat] = true
				check(p.hat != p.want, "tickets start unmatched each bell")
				var holders: Array = state.players.filter(func(q): return q.active and q.hat == p.want)
				desirable[slot] += int(not holders.is_empty())
				reciprocal[slot] += int(holders.any(func(q): return q.want == p.hat))
				check(_can_reach_spot(p.spot), "personal fitting spot is reachable from any floor corner within two seconds")
			if active.size() == 6:
				check(patterns.size() == 3, "six seats receive duplicate hats")
			advance(state, Model.BELL_TICKS)
		check(desirable.values().max() - desirable.values().min() <= 1, "held desired-hat opportunities rotate evenly")
		check(reciprocal.values().max() == reciprocal.values().min(), "mutually desirable opportunities are balanced")
		if active.size() == 2:
			check(reciprocal.values() == [4, 4], "two seats mix four mutual bells with three lopsided bells")
		check(state.phase == "finished" and state.tick == Model.ROUND_TICKS and state.elapsed == 84.0,
			"seven twelve-second bells finish exactly at 84 seconds")

func _can_reach_spot(spot: Vector2i) -> bool:
	for x in [Model.FLOOR_MIN.x, Model.FLOOR_MAX.x]:
		for y in [Model.FLOOR_MIN.y, Model.FLOOR_MAX.y]:
			var delta := (Vector2i(x, y) - spot).abs()
			for jumps in range(Model.FIT_TICKS + 1):
				var direction := Vector2i(int(delta.x >= Model.DIAGONAL), int(delta.y >= Model.DIAGONAL))
				if delta.length_squared() <= Model.FIT_RANGE * Model.FIT_RANGE:
					break
				if jumps == Model.FIT_TICKS:
					return false
				var speed := Model.DIAGONAL if direction.x and direction.y else Model.MOVE
				delta = (delta - direction * speed).abs()
	return true

func test_snapshots() -> void:
	var host := round_with([0, 1, 3, 5], [3, 5])
	var guest := round_with([0, 1, 3, 5])
	for tick in [1, 25, 100, Model.RESERVE_TICK, Model.CUTOFF_TICK, Model.BELL_TICKS,
			3 * Model.BELL_TICKS + 13, Model.ROUND_TICKS]:
		advance(host, tick - host.tick)
		guest.apply_snapshot(host.snapshot())
		check(guest.snapshot() == host.snapshot(), "compact snapshot carries the host’s movement, consent, fitting, trades and scores")
		check(guest.players[5].want == host.players[5].want, "guest derives the same ticket refresh")
	var good: Dictionary = guest.snapshot()
	var bad: Dictionary = good.duplicate(true)
	bad.state.encode_s8(7, 5)
	guest.apply_snapshot(bad)
	check(guest.snapshot() == good, "invalid target/offer state is rejected atomically")
