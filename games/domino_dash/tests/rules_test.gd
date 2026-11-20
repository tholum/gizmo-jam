extends SceneTree

const M = preload("res://games/domino_dash/model.gd")

var _errors := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, caption: String) -> void:
	if not ok:
		_errors += 1
		print("FAIL: ", caption)

func seats(humans: Array, bots: Array = []) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for slot in M.SEATS:
		result.append({"name": "P%d" % (slot + 1), "peer": slot + 1, "bot": slot in bots,
			"active": slot in humans or slot in bots})
	return result

func new_round(lineup: Array, seed_value: int = 23) -> RefCounted:
	var state := M.new()
	state.begin(seed_value, lineup, 74)
	state.step(M.COUNTDOWN)
	return state

func tap(state: RefCounted, slot: int) -> void:
	state.command(slot, "topple", true)
	state.command(slot, "topple", false)

func claim_starter(state: RefCounted, slot: int) -> void:
	state.players[slot].pos = M.starter_pos(state.players[slot].station)
	tap(state, slot)

func run() -> void:
	test_starter()
	test_bridges()
	test_cutoff()
	test_lineup_rotation()
	test_human_pacing()
	test_bots()
	test_replication()
	print("DOMINO_DASH_RULES ", "PASS" if _errors == 0 else "FAIL %d" % _errors)
	quit(int(_errors > 0))

func test_starter() -> void:
	var state := new_round(seats([0, 4]))
	check(state.phase == "running" and state.wave == 0 and state.wave_remaining() == 15.0, "countdown ends at first full wave")
	check(state.action_target(0).kind == "idle", "spawn requires a short move")
	var action := "up" if state.players[0].station % 2 == 0 else "down"
	state.command(0, action, true)
	state.step(M.STEP)
	state.command(0, action, false)
	check(state.action_target(0).kind == "starter", "single inward step reaches own starter")
	state.command(0, "topple", true)
	state.step(M.STEP)
	check(state.starters[0].owner == 0 and state.players[0].score == 1, "one tap scores the first fall")
	state.step(M.STEP * (M.FALL_TICKS - 1))
	check(state.players[0].score == 1, "score waits for the next domino")
	state.step(M.STEP * (M.FALL_TICKS + 1))
	check(state.players[0].score == M.STARTER_LENGTH, "complete starter awards three points")
	tap(state, 0)
	tap(state, 3)
	state.step(M.STEP)
	check(state.players[0].score == 3 and state.players[3].score == 0, "spent and inactive starters cannot score")
	state.players[4].pos = M.starter_pos(state.players[0].station)
	check(state.action_target(4).kind == "idle", "numbered starts are reserved for their contestant")
	check(state.ranking() == [0, 4] and state.winners() == [0], "scoring and results preserve sparse seats")

func test_bridges() -> void:
	var state := new_round(seats([0, 5]))
	var branch := first_branch(state)
	state.players[0].pos = M.diamond_pos(branch, 0)
	check(state.action_target(0).kind == "idle", "bridge requires the contestant's starter")
	for slot in [0, 5]:
		claim_starter(state, slot)
	state.step(M.STEP)
	var open_at: int = state.tick + state.opens_in(branch)
	state.players[0].pos = M.diamond_pos(branch, 0)
	state.players[5].pos = M.diamond_pos(branch, 1)
	check(state.action_target(0).kind == "wait", "scheduled bridges show the approaching opening")
	tap(state, 0)
	state.step((open_at - state.tick) * M.STEP)
	check(state.bridges[branch].owner == -1 and state.action_target(0).kind == "bridge",
		"press before alignment does not carry over")
	state.step(M.OPEN_TICKS * M.STEP)
	tap(state, 0)
	state.step(M.STEP)
	check(state.bridges[branch].owner == -1 and state.action_target(0).kind == "wait", "amber diamonds refuse a tap")
	state.step((M.PERIOD - M.OPEN_TICKS - 1) * M.STEP)
	check(state.action_target(0).kind == "bridge" and state.action_target(5).kind == "bridge",
		"both approaches offer the same green window")
	state.players[0].pos += Vector2(0.2, 0)
	tap(state, 5)
	tap(state, 0)
	state.step(M.STEP)
	check(state.bridges[branch].owner == 5 and state.bridges[branch].side == 1,
		"closest simultaneous tap claims bridge in its direction regardless of message order")
	state.step((M.BRIDGE_LENGTH - 1) * M.FALL_TICKS * M.STEP)
	check(state.players[5].score == M.STARTER_LENGTH + M.BRIDGE_LENGTH, "each fallen bridge domino credits its claimant")
	tap(state, 0)
	state.step(M.STEP)
	check(state.bridges[branch].owner == 5 and state.players[0].score == M.STARTER_LENGTH, "spent bridge stays owned")

func test_cutoff() -> void:
	var state := new_round(seats([0, 2]))
	state.step((M.WAVE_TICKS - 2) * M.STEP)
	claim_starter(state, 2)
	state.step(2 * M.STEP)
	check(state.players[2].score == 1 and state.wave == 0, "two ticks before cutoff allow only one actual fall")
	var old_station: int = state.players[2].station
	state.step(M.STEP)
	check(state.wave == 1 and state.starters[2].owner == -1 and state.players[2].score == 1,
		"new wave preserves scored falls and cancels the rest")
	check(Vector2(state.players[2].pos).distance_to(M.spawn_pos(old_station)) < 0.01, "reload returns contestants to their starting positions")
	state.step(M.WAVE_TICKS * (M.WAVES - 1) * M.STEP)
	check(state.phase == "finished" and state.wave == M.WAVES - 1 and state.tick == M.ROUND_TICKS and state.remaining() == 0.0,
		"six waves run exactly 90 seconds")
	check(state.players[2].score == 1, "unclaimed waves never award points")

func first_branch(state: RefCounted) -> int:
	var branch := 0
	for index in M.BRANCHES:
		if state.opens_in(index) < state.opens_in(branch):
			branch = index
	return branch

func test_lineup_rotation() -> void:
	for count in [3, 4, 5, 6]:
		var state := new_round(seats(range(count)))
		var single: Array[int] = []
		single.resize(count)
		single.fill(0)
		var first_counts := [0, 0, 0]
		for wave in M.WAVES:
			first_counts[first_branch(state)] += 1
			var groups := [[], [], []]
			for slot in count:
				groups[M.station_branch(state.players[slot].station)].append(slot)
			for group in groups:
				if group.size() == 1:
					single[group[0]] += 1
			state.step(M.WAVE_TICKS * M.STEP)
			if wave == 0:
				state.step(M.STEP)
		check(first_counts == [2, 2, 2], "each bridge opens first twice")
		check(single.max() - single.min() <= 1, "station rotation shares isolated starts across %d humans" % count)

func test_human_pacing() -> void:
	for lineup in [seats([0, 5]), seats([0, 2, 5]), seats(range(6))]:
		var state := new_round(lineup)
		for expected_wave in M.WAVES:
			for slot in state.ranking():
				claim_starter(state, slot)
			state.step(M.STEP)
			for branch in range(M.BRANCHES):
				check(state.opens_in(branch) > 0, "after starters, the bridge schedule still gives contestants travel time")
			var branches := range(M.BRANCHES)
			branches.sort_custom(func(a, b): return state.opens_in(a) < state.opens_in(b))
			for branch in branches:
				for slot in state.ranking():
					var station: int = state.players[slot].station
					if M.station_branch(station) == branch or state.ranking().size() == 2:
						state.players[slot].pos = M.diamond_pos(branch, station % 2)
					else:
						state.players[slot].pos = Vector2(0, 5.7)
				state.step(state.opens_in(branch) * M.STEP)
				for slot in state.ranking():
					tap(state, slot)
				state.step(M.STEP)
			check(state.bridges[branches[-1]].start >= expected_wave * M.WAVE_TICKS + M.OPEN_AT[-1], "last opening keeps rivalry late in every wave")
			if expected_wave < M.WAVES - 1:
				state.step((M.WAVE_TICKS - (state.tick - expected_wave * M.WAVE_TICKS) + 1) * M.STEP)
		var scores: Array = []
		for slot in state.ranking():
			scores.append(state.players[slot].score)
		check(scores.max() - scores.min() <= 4, "mirrored same-tick human tactics stay close across %d occupied seats: %s" % [scores.size(), scores])

func test_bots() -> void:
	var state := new_round(seats([0, 5], [1, 4]))
	for slot in [0, 5]:
		claim_starter(state, slot)
	state.step(M.STEP)
	var branch := first_branch(state)
	state.players[0].pos = M.diamond_pos(branch, 0)
	state.step(state.opens_in(branch) * M.STEP)
	tap(state, 0)
	state.step(M.STEP)
	check(state.bridges[branch].owner == 0, "a quick human can beat both bots on opening tick")
	state.step(M.WAVE_TICKS * M.STEP - state.elapsed)
	var bots_scored: bool = state.players[1].score > M.STARTER_LENGTH or state.players[4].score > M.STARTER_LENGTH
	check(bots_scored and state.players[5].score == M.STARTER_LENGTH,
		"2H + 2B bots use the same legal bridges, while a passive human sees only own starter score")
	state.take_over(5)
	state.step((M.ROUND_TICKS - state.tick) * M.STEP)
	check(state.players[5].bot and state.players[5].score > M.WAVES * M.STARTER_LENGTH,
		"seat takeover clears human input and keeps playing")
	check(state.players[2].score == 0 and state.players[3].score == 0, "bots never activate vacant seats")
	var solo := new_round(seats([4]))
	claim_starter(solo, 4)
	solo.step((M.FALL_TICKS * M.STARTER_LENGTH) * M.STEP)
	check(solo.players[4].score == 3, "solo has a usable numbered starter")

func test_replication() -> void:
	var lineup := seats([0, 5], [1, 4])
	var host := new_round(lineup)
	var other := new_round(lineup)
	var guest := new_round(lineup)
	for slot in [0, 5]:
		claim_starter(host, slot)
		claim_starter(other, slot)
	for i in M.ROUND_TICKS:
		host.step(M.STEP)
		other.step(M.STEP * 0.25)
		other.step(M.STEP * 0.75)
		var snap: Dictionary = host.snapshot()
		guest.apply_snapshot(snap)
		if snap != other.snapshot() or snap != guest.snapshot() or host.players[0].station != guest.players[0].station:
			check(false, "guest reconstruction and chunked step are identical at tick %d" % host.tick)
			break
	check(host.snapshot().state.size() == 114, "compact raw snapshot")
	var before: Dictionary = guest.snapshot()
	guest.command(0, "up", true)
	guest.step(0.5)
	guest.apply_snapshot({"id": 2, "tick": 47, "count": 0, "state": PackedByteArray([7, 19])})
	check(guest.snapshot() == before, "guest ignores local mutations and malformed snapshots")
	guest.begin(23, lineup, 75)
	check(guest.round_id == 75 and guest.tick == 0 and guest.countdown == M.COUNTDOWN and guest.players[1].score == 0
		and guest.bridges[0].owner == -1, "new round fully resets state and authorities")
