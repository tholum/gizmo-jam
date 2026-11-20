extends SceneTree

const Model = preload("res://games/wobble_workshop/model.gd")

var _failures := 0
var _checks := 0

func _initialize() -> void:
	_test_detent()
	_test_forecast_and_clock()
	_test_rotating_claims(3, 0)
	_test_rotating_claims(4, 2)
	_test_rotating_claims(6, 0)
	_test_bots_and_snapshots()
	print("WOBBLE_WORKSHOP_RULES %s (%d checks)" % ["PASS" if _failures == 0 else "FAIL", _checks])
	quit(1 if _failures else 0)

func _expect(ok: bool, issue: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		printerr(issue)

func _start(count: int, bots: int = 0) -> RefCounted:
	var state := Model.new()
	var seats := []
	for slot in count:
		seats.append({"name": "P%d" % (slot + 1), "bot": slot >= count - bots})
	state.begin(731, seats)
	state.step(Model.COUNTDOWN)
	return state

func _wind(state: RefCounted, slot: int, joint: int) -> void:
	state.command(slot, Model.JOINT_ACTIONS[joint], true)
	state.command(slot, Model.REHEARSAL_ACTIONS[state.rehearsal], true)

func _drop(state: RefCounted, slot: int, joint: int) -> void:
	state.command(slot, Model.JOINT_ACTIONS[joint], false)

func _latch_firsts(state: RefCounted, count: int) -> void:
	for slot in count:
		_wind(state, slot, state.players[slot].dedicated)
	state.step(Model.DETENT_OPEN * Model.STEP)
	for slot in count:
		_drop(state, slot, state.players[slot].dedicated)
	state.step(Model.STEP)

func _test_detent() -> void:
	var state := _start(2)
	var joint: int = state.players[0].dedicated
	_wind(state, 0, joint)
	state.step((Model.DETENT_OPEN - 1) * Model.STEP)
	_drop(state, 0, joint)
	state.step(Model.STEP)
	_expect(state.players[0].score == 0 and state.players[0].feedback == 2, "Early release should recoil with a retry cue.")
	_wind(state, 0, joint)
	state.step(Model.DETENT_OPEN * Model.STEP)
	_expect(state.in_detent(0), "The striped band starts within one second.")
	state.command(0, "cancel", true)
	_drop(state, 0, joint)
	state.step(Model.STEP)
	_expect(state.players[0].score == 0, "Cancel and stale release must not latch.")
	_wind(state, 0, joint)
	state.step(Model.DETENT_CLOSE * Model.STEP)
	_expect(state.in_detent(0), "The full visible detent window should remain playable.")
	_drop(state, 0, joint)
	_drop(state, 0, joint)
	state.step(Model.STEP)
	_expect(state.players[0].score == 1 and state.joints[joint].owner == 0, "Late eligible release should latch exactly once.")
	var next: int = state.options(0)[0]
	_wind(state, 0, next)
	state.step((Model.DETENT_CLOSE + 1) * Model.STEP)
	_drop(state, 0, next)
	state.step(Model.STEP)
	_expect(state.players[0].score == 1 and state.players[0].feedback == 4, "An expired hold should unwind without consuming the shared allowance.")

func _test_forecast_and_clock() -> void:
	var state := _start(2)
	var joint: int = state.players[0].dedicated
	var partner: int = state.players[1].dedicated
	var forecast: Dictionary = state.projection(0)
	var base: int = state.torque
	_expect(forecast.solo == base + state.joints[joint].force, "Solo ghost must match the exact proposed torque.")
	_expect(forecast.partner == 1 and forecast.partner_joint == partner and forecast.paired == base, "Opposing first moves should pair.")
	_wind(state, 0, joint)
	state.step(Model.DETENT_CENTER * Model.STEP)
	_drop(state, 0, joint)
	state.step(Model.STEP)
	_expect(state.torque == forecast.solo and state.projection(1).solo == forecast.paired, "Partner commit must update the other seat's forecast immediately.")
	_wind(state, 1, partner)
	state.step(Model.DETENT_CENTER * Model.STEP)
	_drop(state, 1, partner)
	state.step(Model.STEP)
	_expect(state.torque == forecast.paired and Model.safe(state.torque), "Combined commits must match the pair forecast.")
	state.step(state.deadline_ticks() * Model.STEP)
	_expect(state.window() == "bell" and state.players[0].score == 2 and state.players[1].score == 2, "At the bell an upright toy pays each contributor once.")
	state.step((Model.ROUND_TICKS - state.tick) * Model.STEP)
	_expect(state.elapsed == 90.0 and state.rehearsal == 4 and state.phase == "finished", "Five complete 18-second rehearsals should finish at 90 seconds.")

	var late := _start(2)
	late.step((Model.WORK_TICKS - Model.DETENT_OPEN) * Model.STEP)
	_expect(late.projection(0).partner == -1 and late.projection(0).correction == "none", "A partner cannot be suggested when neither sweep can reach the band before bell.")
	var lost := _start(2)
	_wind(lost, 0, lost.players[0].dedicated)
	lost.step((Model.WORK_TICKS - 20) * Model.STEP)
	lost.take_over(1)
	_expect(lost.projection(0).partner == -1, "A fresh takeover bot needs more time to release than a human.")

func _test_rotating_claims(count: int, bots: int) -> void:
	var state := _start(count, bots)
	var winners := PackedInt32Array()
	var first_joints := []
	var humans := count - bots
	for slot in humans:
		first_joints.append([])
	for rehearsal in Model.REHEARSALS:
		var expected_shared := 2 if count == 3 else (3 if count == 4 else 4)
		_expect(state.joints.size() == count + expected_shared, "Crew of %d has the wrong shared board size." % count)
		for slot in humans:
			first_joints[slot].append(state.players[slot].dedicated)
		_latch_firsts(state, humans)
		if bots > 0:
			state.step(4.0)
		_expect(state.players.slice(0, count).all(func(p: Dictionary) -> bool: return p.latched), "All first latches should score before shared claims.")
		_expect(Model.safe(state.torque) or state.options(0).any(func(j: int) -> bool: return Model.safe(state.torque + state.joints[j].force)), "Each all-first crew must retain an upright route.")
		var joint: int = state.options(0)[0]
		for slot in humans:
			_wind(state, slot, joint)
		state.step(Model.DETENT_CENTER * Model.STEP)
		for slot in humans:
			_drop(state, slot, joint)
		state.step(Model.STEP)
		var winner: int = state.joints[joint].owner
		winners.append(winner)
		_expect(winner >= 0 and state.players[winner].shared == joint, "Batch must settle exactly one owner.")
		for slot in humans:
			if slot == winner:
				_expect(state.options(slot).is_empty(), "A shared latch must consume the allowance.")
			else:
				_expect(state.players[slot].feedback == 3 and not state.options(slot).is_empty() and joint not in state.options(slot), "A simultaneous loser should immediately have another eligible choice.")
				var forecast: Dictionary = state.projection(slot)
				_expect(forecast.partner < 0 or forecast.partner_joint != forecast.joint, "A paired forecast must exclude same-joint conflicts.")
		state.step((Model.REHEARSAL_TICKS - state.age()) * Model.STEP)
	for slot in humans:
		var expected_wins := Model.REHEARSALS / humans
		_expect(winners.count(slot) in [expected_wins, expected_wins + 1], "Same-tick all-human claims must rotate fairly.")
		_expect(first_joints[slot].slice(0, mini(count, Model.REHEARSALS)).all(func(j: int) -> bool: return first_joints[slot].count(j) <= (2 if count < Model.REHEARSALS else 1)), "Dedicated physical assignments should rotate.")

func _test_bots_and_snapshots() -> void:
	var host := _start(6, 6)
	var guest := _start(6, 6)
	for rehearsal in Model.REHEARSALS:
		for duration in [0.35, 2.4, 7.3, 6.7, 1.25]:
			host.step(duration)
			guest.apply_snapshot(host.snapshot())
			_expect(guest.tick == host.tick and guest.torque == host.torque and guest.joints == host.joints, "Guests must reconstruct authoritative timing, torque and joints.")
			for slot in Model.SEATS:
				_expect(guest.players[slot].score == host.players[slot].score and guest.projection(slot) == host.projection(slot), "Guests must have exact points and forecasts.")
	_expect(host.players.all(func(p: Dictionary) -> bool: return p.score >= Model.REHEARSALS), "Bots should latch reliably across the round.")
