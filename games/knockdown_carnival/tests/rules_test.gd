extends SceneTree
## Fixed-step scoring, route access, snapshot replay and repeat-shot pacing.

const M = preload("res://games/knockdown_carnival/model.gd")
const Module = preload("res://games/knockdown_carnival/module.gd")
var _checks := 0
var _failures := 0

func _initialize() -> void:
	_round_and_input()
	_sparse_banks()
	_arrivals()
	_boundary()
	_replay()
	_pacing()
	print("KNOCKDOWN_RULES %s: %d checks, %d failures" % ["PASS" if _failures == 0 else "FAIL", _checks, _failures])
	quit(mini(_failures, 1))

func _check(ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		printerr("FAIL: ", detail)

func _make(active: Array, bots: Array = [], seed_value: int = 98, go: bool = true) -> RefCounted:
	var seats := []
	for slot in M.SEATS:
		seats.append({"name": "Seat %d" % (slot + 1), "peer": slot + 1, "bot": slot in bots, "active": slot in active})
	var model := M.new()
	model.begin(seed_value, seats, 9)
	if go:
		model.step(M.COUNTDOWN)
	return model

func _aim(model: RefCounted, slot: int, line: int) -> void:
	var action := "left" if line < int(model.players[slot].aim) else "right"
	for i in absi(line - int(model.players[slot].aim)):
		model.command(slot, action, true)
		model.command(slot, action, false)

func _shot(model: RefCounted, slot: int, line: int) -> void:
	_aim(model, slot, line)
	model.command(slot, "flick", true)

func _round_and_input() -> void:
	_check(Module.new(null).make_model().get_script() == M, "Module loads the host model")
	var model := _make([2, 5], [], 98, false)
	model.command(2, "left", true)
	model.command(2, "left", true)
	model.command(0, "right", true)
	model.command(2, "flick", true)
	model.step(M.COUNTDOWN)
	_check(model.players[2].aim == 1 and model.players[0].aim == 2, "Countdown permits deliberate aim edges only on active seats")
	_check(model.phase == "running" and model.pucks.is_empty(), "Countdown flick cannot launch")
	model.step(M.STEP * 16)
	_check(model.players[2].aim == 0, "Held aim repeats at the fixed tick")
	model.command(2, "left", false)
	_shot(model, 2, 1)
	model.step(M.STEP * (M.DIRECT_TRAVEL + 1))
	_check(model.players[2].score == 1, "A direct shot scores one on arrival")
	model.command(2, "flick", true)
	model.step((M.RELOAD + 1) * M.STEP)
	_check(model.players[2].shot_tick == 17, "An early flick is discarded during reload")
	model.take_over(0)
	model.take_over(5)
	_check(model.players[5].bot and not model.players[0].bot, "Only occupied seats can be taken over")
	model.step(100.0)
	var frozen: Dictionary = model.snapshot()
	model.command(2, "right", true)
	model.step(100.0)
	_check(model.snapshot() == frozen and model.tick == M.ROUND_TICKS, "Match ends exactly after 90 seconds")
	_check(model.ranking().size() == 2 and model.ranking().has(2) and model.ranking().has(5), "Only occupied seats reach results")

func _sparse_banks() -> void:
	for active in [[0, 1], [0, 3], [1, 5], [0, 2, 5], [0, 1, 3, 4], [0, 1, 2, 3, 4, 5]]:
		var model := _make(active)
		for i in active.size():
			var left: int = active[i]
			var right: int = active[(i + 1) % active.size()]
			_check(model.destination(left, 0) == model.destination(right, 4),
				"Every bank entrance is contestable in lineup %s" % [active])
			_check(model.destination(left, 4) != model.destination(left, 0), "A seat can choose between two shared lines")
	var solo := _make([4])
	_check(solo.destination(4, 0) != solo.destination(4, 4), "Solo has two different bank entrances")

func _arrivals() -> void:
	var model := _make([0, 4])
	model.step((M.LAYOUT_TICKS * 2 + 200) * M.STEP)
	var shared: int = model.destination(0, 4)
	var count: int = model.forecast(0, 4, model.tick + 1 + M.BANK_TRAVEL)
	_shot(model, 0, 4)
	_shot(model, 4, 0)
	model.step(M.STEP * M.BANK_TRAVEL)
	_check(model.players[0].score == 0 and model.players[4].score == 0, "Travel never scores before arrival")
	model.step(M.STEP)
	_check(model.players[0].score == count and model.players[4].score == count, "Both launches earn full same-tick chain credit")
	_check(model.targets[shared].credit == (1 << 0) | (1 << 4) and model.players[0].joint and model.players[4].joint,
		"Target mask and both flash badges identify joint credit")
	var reset: int = model.targets[shared].up
	_check(not model.available(shared, reset - 1) and model.available(shared, reset), "Forecast matches the exact stand-up tick")
	var separate := _make([0, 4])
	separate.step(160 * M.STEP)
	_shot(separate, 4, 0)
	separate.step(M.STEP)
	_shot(separate, 0, 4)
	separate.step(M.STEP * (M.BANK_TRAVEL + 1))
	_check(separate.players[4].score == 1 and separate.players[0].score == 0 and not separate.players[4].joint,
		"A one-tick-earlier arrival wins even when launched by a higher seat number")

func _boundary() -> void:
	var model := _make([0, 4])
	model.step((M.LAYOUT_TICKS - M.BANK_TRAVEL - 1) * M.STEP)
	_check(model.forecast(0, 4, M.LAYOUT_TICKS) == 1 and model.forecast(0, 4, M.LAYOUT_TICKS + 1) == 0,
		"Old-board boundary permits a puck whose travel ends at the bell")
	_shot(model, 0, 4)
	_shot(model, 4, 0)
	model.step((M.BANK_TRAVEL + 1) * M.STEP)
	_check(model.layout == 1 and model.players[0].score == 1 and model.players[4].score == 1,
		"Boundary arrivals are credited to both seats before re-racking")
	model.step((M.LAYOUT_TICKS - M.DIRECT_TRAVEL) * M.STEP)
	_shot(model, 0, 2)
	model.step(M.STEP)
	_check(model.pucks.is_empty(), "A shot crossing the layout boundary is discarded")

func _replay() -> void:
	var a := _make([0, 2, 3, 5], [2, 3])
	var b := _make([0, 2, 3, 5], [2, 3])
	var client := _make([0, 2, 3, 5], [2, 3], 98, false)
	for i in 180:
		if i % 3 == 0:
			_shot(a, 0, posmod(i / 3, M.LINES))
			_shot(b, 0, posmod(i / 3, M.LINES))
		a.step(M.STEP * 30)
		for single in 30:
			b.step(M.STEP)
		var wire: Dictionary = a.snapshot()
		if a.pucks.size() > 0 and i < 10:
			_check(wire.state.size() == M.HEADER and M.HEADER < 256, "Live travel fits in a compact, fixed snapshot")
		_check(wire == b.snapshot(), "Same seed and commands replay identically with different frame grouping")
		client.apply_snapshot(wire)
		_check(client.snapshot() == wire and client.pucks.size() == a.pucks.size(), "Client reconstructs a lossless snapshot and in-flight pucks")
		var stale := wire.duplicate()
		stale.tick -= 1
		client.apply_snapshot(stale)
		_check(client.snapshot() == wire, "Late snapshots cannot roll back visual state")
	_check(a.layout == 2 and a.players[2].score > 20 and a.players[3].score > 20, "Optional bots contribute to the full match")

func _pacing() -> void:
	for lineup in [[[0, 1, 4], []], [[0, 1, 3, 4], [3, 4]], [[0, 1, 2, 3, 4, 5], []]]:
		var active: Array = lineup[0]
		var model := _make(active, lineup[1], 450)
		var personal_hits := {}
		for i in M.ROUND_TICKS:
			if i >= int(model.players[0].ready):
				_shot(model, 0, 2)
			if i >= int(model.players[1].ready):
				var best := -1
				var points := 0
				for line in [0, 4, 1, 3, 2]:
					var value: int = model.forecast(1, line, i + 1 + M.flight(line))
					if value > points:
						points = value
						best = line
				if best >= 0:
					_shot(model, 1, best)
			for slot in active:
				if slot > 1 and slot not in lineup[1] and i >= int(model.players[slot].ready):
					var line := posmod(floori(i / 67.0) + slot, M.LINES)
					_shot(model, slot, line)
			model.step(M.STEP)
			if int(model.players[1].last_score) == model.tick:
				personal_hits[model.layout] = true
		_check(model.players[1].score > model.players[0].score * 2,
			"Reading the forecast beats repeating the quickest line in lineup %s" % [active])
		_check(personal_hits.size() == 3 and model.players[1].score >= 45,
			"The lead stays reachable across all three boards in lineup %s" % [active])
