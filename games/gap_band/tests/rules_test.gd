extends SceneTree

const Model = preload("res://games/gap_band/model.gd")
var _errors := 0

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, detail: String) -> void:
	if not ok:
		_errors += 1
		push_error("GAP BAND: " + detail)

func round_with(active: Array, bots: Array = [], seed_value: int = 317) -> RefCounted:
	var seats := []
	for slot in Model.SEATS:
		seats.append({"name": "P%d" % (slot + 1), "active": slot in active, "bot": slot in bots})
	var state := Model.new()
	state.begin(seed_value, seats, 55)
	return state

func advance(state: RefCounted, ticks: int = 1) -> void:
	state.step(ticks * Model.STEP)

func submit(state: RefCounted, seat: int, target: int, revise: bool, index: int = 0) -> void:
	state.command(seat, Model.MEASURE_ACTIONS[index], revise)
	state.command(seat, Model.SLOT_ACTIONS[target], true)

func _run() -> void:
	_test_deadlines()
	_test_simultaneous_batch()
	_test_fair_accents()
	_test_bots()
	_test_snapshot()
	print("GAP_BAND_RULES ", "PASS" if _errors == 0 else "FAIL %d" % _errors)
	quit(int(_errors > 0))

func _test_deadlines() -> void:
	var state := round_with([0, 2, 5])
	var cell: int = state.accent
	var spare: int = (cell + 1) % state.cells
	submit(state, 0, cell, false)
	advance(state, Model.COUNT_TICKS)
	check(state.players[0].note == -1 and state.deadline_ticks() == Model.PLACE_TICKS, "countdown input never latches")
	submit(state, 0, cell, false)
	submit(state, 0, spare, false)
	check(state.players[0].note == -1, "claims are queued until the host processes the tick")
	advance(state)
	check(state.players[0].note == cell, "first complete confirmation wins")
	submit(state, 0, spare, false)
	advance(state, Model.PLACE_TICKS - 2)
	submit(state, 2, cell, false)
	state.command(5, Model.MEASURE_ACTIONS[0], false)
	advance(state)
	check(state.window() == "revise" and state.players[0].note == cell and state.players[2].note == cell,
		"the last Place tick commits before changing phase")
	state.command(5, Model.SLOT_ACTIONS[spare], true)
	submit(state, 5, spare, false)
	advance(state)
	check(state.players[5].note == -1 and state.can_confirm(state.players[5]), "stale Place input expires and an unplaced seat can act in Revise")
	submit(state, 5, spare, true)
	advance(state)
	submit(state, 5, cell, true)
	advance(state)
	check(not state.players[5].placed and state.players[5].revised and state.players[5].note == spare,
		"late placement spends Revise with no second action")
	advance(state, Model.SEAL_TICK - state.age())
	submit(state, 2, spare, true)
	check(state.deadline_ticks() == 0 and state.players[2].note == cell, "zero seals the ownership")
	check(state.players[0].score == 0 and state.players[2].score == 0 and state.players[5].score == 1,
		"colliding accent is muted, a solo off-accent earns one")
	var heard := []
	while state.measure == 0:
		if state.beat() >= 0 and not heard.has(state.beat()):
			heard.append(state.beat())
		advance(state)
	check(heard == range(state.cells), "playback visits every cell including empty and muted rests")
	submit(state, 0, cell, false)
	advance(state)
	check(state.players[0].note == -1, "another measure's tag cannot place into this measure")
	submit(state, 0, cell, false, 1)
	advance(state)
	check(state.players[0].note == cell and state.players[5].score == 1, "new measure clears notes and preserves points")

func _test_simultaneous_batch() -> void:
	for queue_order in [[0, 1, 2], [2, 1, 0]]:
		var state := round_with([0, 1, 2])
		advance(state, Model.COUNT_TICKS)
		var cell: int = state.accent
		var rest: int = (cell + 1) % state.cells
		var third: int = (cell + 2) % state.cells
		submit(state, 0, cell, false)
		submit(state, 1, cell, false)
		submit(state, 2, rest, false)
		advance(state, Model.SEAL_TICK - 1)
		var destinations := [third, rest, cell]
		for seat in queue_order:
			submit(state, seat, destinations[seat], true)
		check(state.owners()[cell] == [0, 1], "unprocessed revision preserves checked notes")
		advance(state)
		check(state.owners()[cell] == [2] and state.owners()[rest] == [1], "seal uses the post-batch ownership")
		check(state.players[0].last_points == 1 and state.players[1].last_points == 1 and state.players[2].last_points == 2,
			"last valid revisions score once without seat-order bias")

func _test_fair_accents() -> void:
	for count in range(2, Model.SEATS + 1):
		var state := round_with(range(count))
		var same := round_with(range(count))
		check(state.cells == count + 1 and state.accents == same.accents, "seeded accents are stable for each supported seat count")
		var frequencies := PackedInt32Array()
		frequencies.resize(state.cells)
		var prior := -1
		for cell in state.accents:
			frequencies[cell] += 1
			check(cell != prior, "accent never repeats back-to-back")
			prior = cell
		var sorted := Array(frequencies)
		sorted.sort()
		check(sorted[-1] - sorted[0] <= 1, "all cells get near-equal accent frequency over nine measures")
	var first := round_with(range(Model.SEATS))
	var other := round_with(range(Model.SEATS), [], 984)
	check(first.accents != other.accents, "different seeds change accent order")
	advance(first, Model.COUNT_TICKS + Model.ROUND_TICKS)
	check(first.phase == "finished" and first.elapsed == 90.0 and first.measure == 8 and first.winners().size() == Model.SEATS,
		"nine measures, exactly 90 gameplay seconds, with tied winners")

func _test_bots() -> void:
	var state := round_with([0, 3, 5], [3, 5])
	advance(state, Model.COUNT_TICKS)
	submit(state, 0, state.accent, false)
	advance(state, 25)
	check(state.players[3].aim >= 0 and state.players[3].aim != state.accent and state.players[3].note < 0,
		"CPU visibly aims at a viable gap before committing")
	advance(state, 14)
	var bot_cell: int = state.players[3].note
	check(bot_cell >= 0 and state.owners()[bot_cell] == [3], "CPU claims the previewed gap")
	advance(state, Model.PLACE_TICKS - state.age())
	submit(state, 0, bot_cell, true)
	advance(state, Model.SEAL_TICK - state.age())
	check(state.players[3].last_points == 2 and state.players[3].note == state.accent,
		"CPU responds to a collision and the newly open accent")
	check(state.players[5].last_points == 1, "second CPU retains its solo")
	state.take_over(0)
	advance(state, Model.MEASURE_TICKS - state.age() + Model.PLACE_TICKS)
	check(state.players[0].bot and state.players[0].note >= 0, "disconnect takeover receives a CPU action next measure")

func _test_snapshot() -> void:
	var host := round_with([1, 4])
	var guest := round_with([1, 4])
	advance(host, Model.COUNT_TICKS + 1)
	var older: Dictionary = host.snapshot()
	submit(host, 1, host.accent, false)
	advance(host, Model.SEAL_TICK + Model.COUNT_IN_TICKS - 1)
	var latest: Dictionary = host.snapshot()
	guest.apply_snapshot(latest)
	check(guest.snapshot() == latest and guest.beat() == host.beat() and guest.winners() == [1], "guest reconstructs confirmed timing, beat and score")
	guest.apply_snapshot(older)
	guest.command(1, Model.MEASURE_ACTIONS[0], true)
	advance(guest, Model.ROUND_TICKS)
	check(guest.snapshot() == latest, "guest never rewinds or steps the host clock")
	var malformed := latest.duplicate(true)
	malformed.state.encode_s8(1 * Model.ROW, host.cells)
	guest.apply_snapshot(malformed)
	check(guest.snapshot() == latest, "malformed row is rejected atomically")
