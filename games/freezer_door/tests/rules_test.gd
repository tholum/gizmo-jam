extends SceneTree

const Model = preload("res://games/freezer_door/model.gd")

var _errors := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, caption: String) -> void:
	if not ok:
		_errors += 1
		print("FAIL: ", caption)

func round_with(humans: Array, bots: Array = [], seed_value: int = 75) -> RefCounted:
	var seats: Array = []
	for slot in Model.SEATS:
		seats.append({"name": "P%d" % (slot + 1), "peer": slot + 1, "bot": slot in bots,
			"active": slot in humans or slot in bots})
	var round_model := Model.new()
	round_model.begin(seed_value, seats, 23)
	round_model.step(Model.COUNTDOWN)
	return round_model

func tick(state: RefCounted, count: int = 1) -> void:
	state.step(count * Model.STEP)

func tap(state: RefCounted, slot: int) -> void:
	state.command(slot, "hold", true)
	state.command(slot, "hold", false)

func run() -> void:
	test_starters_and_motion()
	test_shared_claim()
	test_maximum_heat()
	test_allowance_and_expiry()
	test_bots_and_snapshots()
	print("FREEZER_DOOR_RULES ", "PASS" if _errors == 0 else "FAIL %d" % _errors)
	quit(int(_errors > 0))

func test_starters_and_motion() -> void:
	var state := round_with([0, 3, 5])
	var stations := {}
	var active: Array = range(Model.DRAWERS).filter(func(drawer): return state.enabled(drawer))
	check(active == [1, 2, 3, 7, 8, 9], "three sparse seats populate exactly six adjacent drawers")
	for p in state.players:
		if not p.active:
			continue
		stations[p.slot] = p.cursor
		check(state.drawers[p.cursor].owner == p.slot, "sparse seat starts on its own drawer")
		for near in Model.NEIGHBORS[p.cursor]:
			check(state.drawers[near].owner == -1, "starter preview is calm even when everyone opens")
	state.players[3].cursor = stations[0]
	tap(state, 3)
	tick(state, Model.RESERVE_TICKS - 1)
	check(state.players[3].score == 0 and state.reserve_left() == 1, "another seat cannot take a reserved starter")
	tap(state, 3)
	tick(state)
	check(state.players[3].score == 0 and state.reserve_left() == 0, "the reservation drains for exactly three seconds")
	tap(state, 3)
	tick(state)
	check(state.players[3].score == 1, "a free former starter is open after the reserve")
	check(state.ranking() == [3, 0, 5] and state.winners() == [3], "inactive seats are excluded from results")
	state.command(0, "left", true)
	tick(state, Model.REPEAT_TICKS * 4)
	state.command(0, "left", false)
	check(state.players[0].cursor % Model.COLS == 1, "direction repeat clamps to the left active column")
	state.command(0, "right", true)
	state.command(0, "right", false)
	tick(state)
	check(state.players[0].cursor % Model.COLS == 2, "a direction tap between host ticks still moves one drawer")
	tick(state, Model.WAVE_TICKS - state.tick)
	for p in state.players:
		if p.active:
			var original: int = stations[p.slot]
			check(p.cursor == 4 - original % Model.COLS + (1 - original / Model.COLS) * Model.COLS,
				"restock mirrors the first set of starters inside the live cabinet")

func test_shared_claim() -> void:
	var state := round_with([0, 2, 4])
	var reversed := round_with([0, 2, 4])
	for pair in [[state, [0, 2]], [reversed, [2, 0]]]:
		var match_state: RefCounted = pair[0]
		tick(match_state, Model.RESERVE_TICKS)
		for slot in pair[1]:
			match_state.players[slot].cursor = 2
			match_state.command(slot, "hold", true)
		tick(match_state)
	check(state.snapshot() == reversed.snapshot(), "identical simultaneous requests ignore arrival order")
	check(state.drawers[2].holders == 5 and state.flow(2) == Model.SELF_FLOW,
		"two seats share a drawer without creating an extra heat source")
	check(state.flow(8) == Model.NEIGHBOR_FLOW, "the neighbor also receives only one source")
	state.players[4].cursor = 2
	tap(state, 4)
	tick(state)
	check(state.players[4].score == 0 and state.players[4].hold == -1, "later arrivals cannot join the same drawer")
	while not Model.bonus(state.drawers[2].heat):
		tick(state)
	var before: int = state.drawers[2].heat
	state.command(2, "hold", false)
	tick(state)
	check(state.players[2].score == 2 and state.players[2].last_drawer == 2
		and state.players[0].score == 0, "first release awards only that seat and records its pop")
	check(state.drawers[2].holders == 1 and not state.drawers[2].spent and state.drawers[2].heat == before + Model.SELF_FLOW,
		"the earlier release leaves the door and heat source active")
	while state.drawers[2].heat <= Model.BAND_HIGH:
		tick(state)
	state.command(0, "hold", false)
	tick(state)
	check(state.players[0].score == 1 and state.drawers[2].spent and not state.drawers[2].holders,
		"the last release samples its own heat and locks the drawer")

	var tapped := round_with([0, 2])
	tick(tapped, Model.RESERVE_TICKS)
	for slot in [0, 2]:
		tapped.players[slot].cursor = 2
	tap(tapped, 0)
	tapped.command(2, "hold", true)
	tick(tapped)
	check(tapped.players[0].score == 1 and tapped.drawers[2].holders == 4 and not tapped.drawers[2].spent,
		"a same-tick tap pays once and leaves the second claimant holding")

func test_maximum_heat() -> void:
	var state := round_with(range(6))
	tick(state, Model.RESERVE_TICKS)
	for slot in 3:
		state.players[slot].cursor = [1, 3, 8][slot]
		state.command(slot, "hold", true)
	tick(state, 55)
	check(state.drawers[2].heat == Model.BAND_LOW and state.forecast(2) == Model.BAND_LOW,
		"an unopened drawer cannot be heated past the band floor")
	for slot in [3, 4]:
		state.players[slot].cursor = 2
		state.command(slot, "hold", true)
	tick(state)
	check(state.flow(2) == Model.MAX_FLOW and state.drawers[2].holders == 24,
		"all three neighbors plus a shared hold still respect the maximum rate")
	var window := 0
	while Model.bonus(state.drawers[2].heat):
		window += 1
		tick(state)
	check(window >= Model.HZ, "even a shared claim starting at the floor gets at least a full bonus second at maximum flow")
	tick(state, 25)
	check(state.drawers[2].heat == Model.MAX_HEAT and state.forecast(2) == Model.MAX_HEAT,
		"actual and forecast heat clamp at their physical maximum")

func test_allowance_and_expiry() -> void:
	var state := round_with([0, 2])
	check(range(Model.DRAWERS).filter(func(drawer): return state.enabled(drawer)) == [2, 3, 8, 9],
		"two players get four drawers in the center")
	tap(state, 0)
	tick(state)
	var first: int = state.players[0].cursor
	var free: int = Model.NEIGHBORS[first].filter(func(drawer): return state.can_claim(0, drawer))[0]
	state.players[0].cursor = free
	tap(state, 0)
	tick(state)
	tick(state, Model.RESERVE_TICKS)
	state.players[0].cursor = state.players[2].cursor
	tap(state, 0)
	tick(state)
	check(state.players[0].used == 2 and state.players[0].score == 2 and state.players[0].hold == -1,
		"a seat may complete only two draws per restock")
	state.command(2, "hold", true)
	tick(state, Model.WAVE_TICKS - state.tick)
	check(state.wave == 1 and state.players[2].score == 0 and state.players[2].hold == -1,
		"unattended holds expire without scoring at the restock boundary")
	tick(state)
	check(state.players[2].hold == -1 and state.players[0].used == 0, "a stale press does not reopen at restock")
	state.command(2, "hold", false)
	state.command(2, "hold", true)
	tick(state)
	check(state.players[2].hold >= 0, "a fresh press can open in the new restock")
	state.take_over(2)
	tick(state)
	check(state.players[2].bot and state.players[2].hold == -1 and state.players[2].score == 0,
		"disconnection clears ownership without awarding a phantom release")

	var final := round_with([5])
	check(range(Model.DRAWERS).filter(func(drawer): return final.enabled(drawer)).size() == 2,
		"solo practice uses a single column")
	tick(final, Model.ROUND_TICKS - 2)
	final.command(5, "hold", true)
	tick(final)
	final.command(5, "hold", false)
	tick(final)
	check(final.phase == "finished" and final.wave == 7 and final.remaining() == 0.0 and final.players[5].score == 1,
		"the last explicit release counts and the match stops after eight eleven-second restocks")

func test_bots_and_snapshots() -> void:
	var bots := round_with([], [0, 2, 4, 5])
	var guest := round_with([], [0, 2, 4, 5])
	for target in [37, 83, 231, 461, 1095, 1760]:
		tick(bots, target - bots.tick)
		var packet: Dictionary = bots.snapshot()
		guest.apply_snapshot(packet)
		check(guest.snapshot() == packet and guest.drawers == bots.drawers
			and guest.wave == bots.wave and guest.phase == bots.phase, "guest round-trips fixed-tick state at tick %d" % target)
		guest.step(1.0)
		check(guest.tick == target, "the guest does not advance authoritative heat locally")
	check(bots.ranking().size() == 4, "four sparse bots keep the active roster")
	for p in bots.players:
		if p.active:
			check(p.score >= 16 and p.score <= 32, "forecast bots complete most draws and obey the score cap")
	var corrupted: Dictionary = bots.snapshot()
	var rows: PackedByteArray = corrupted.state
	rows.encode_u8(1, 255)
	corrupted.state = rows
	var expected: Dictionary = guest.snapshot()
	guest.apply_snapshot(corrupted)
	check(guest.snapshot() == expected, "an invalid snapshot cannot partially mutate the guest")
