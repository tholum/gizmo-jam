extends SceneTree
## Fixed-step rules, optional seats, the compact wire format, and repeatable digital-input matches.

const M = preload("res://games/popcorn_catch/model.gd")
var _checks := 0
var _failures := 0

func _initialize() -> void:
	_clock_and_movement()
	_touchdown_and_ties()
	_bank_and_spill()
	_wire_and_determinism()
	_party_pacing()
	print("POPCORN_RULES %s: %d checks, %d failures" % ["PASS" if _failures == 0 else "FAIL", _checks, _failures])
	quit(mini(_failures, 1))

func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		printerr("FAIL: ", message)

func _seats(active: Array, bots: Array = []) -> Array:
	var slots: Array = []
	for slot in M.SEATS:
		slots.append({"name": "P%d" % (slot + 1), "peer": slot + 1, "active": slot in active, "bot": slot in bots})
	return slots

func _make(active: Array, bots: Array = [], seed_value: int = 42) -> RefCounted:
	var model := M.new()
	model.begin(seed_value, _seats(active, bots), 15)
	return model

func _isolated(active: Array = [0]) -> RefCounted:
	var model := _make(active)
	model.step(M.COUNTDOWN)
	model._next_wave = M.ROUND_TICKS + 1
	for player in model.players:
		player.pos = Vector2(8, 1)
	return model

func _steer(model: RefCounted, slot: int, goal: Vector2) -> void:
	var player: Dictionary = model.players[slot]
	var offset := goal - Vector2(player.pos) - Vector2(player.vel) * 0.052
	var mask := 0 if offset.length_squared() < 0.19 ** 2 else M.movement_mask(offset)
	for action in M.DIRS:
		var bit: int = M.DIRS[action]
		if (int(player.input) ^ mask) & bit:
			model.command(slot, action, (mask & bit) != 0)

func _land(model: RefCounted, pos: Vector2) -> Dictionary:
	model._add_drop(pos, 10, false)
	var target: Dictionary = model.drops[-1]
	model.step(M.STEP * 9)
	_check(target.winner == -1, "A forecast cannot be caught before touchdown")
	model.step(M.STEP)
	return target

func _clock_and_movement() -> void:
	var model := _make([0, 4])
	var start: Vector2 = model.players[0].pos
	var empty_start: Vector2 = model.players[1].pos
	model.command(0, "right", true)
	model.command(0, "down", true)
	model.command(1, "right", true)
	model.step(M.COUNTDOWN - M.STEP)
	_check(model.phase == "countdown" and model.tick == 0 and model.players[0].pos == start, "Countdown freezes movement")
	model.step(M.STEP + 0.5)
	var moved: Vector2 = model.players[0].pos - start
	_check(model.phase == "running" and moved.x > 2.5 and is_equal_approx(moved.x, moved.y), "Held movement begins at GO with normalized diagonals")
	_check(model.players[1].pos == empty_start and model.players[1].input == 0, "An empty seat ignores input")
	model.step(10.0)
	_check(Vector2(model.players[0].pos).length() <= M.FIELD_RADIUS + 0.00001, "The playfield clamps the bowl")
	model.take_over(1)
	model.take_over(0)
	_check(model.players[0].bot and model.players[0].input == 0 and not model.players[1].bot, "Takeover only applies to occupied seats and clears held movement")
	model.players[4].carry = 4
	model.step(100.0)
	var frozen: Dictionary = model.snapshot()
	model.command(4, "right", true)
	model.step(10.0)
	_check(model.tick == M.ROUND_TICKS and model.phase == "finished" and model.remaining() == 0.0 and model.snapshot() == frozen,
		"Exactly 90 seconds of play, frozen after the cutoff")
	_check(model.players[4].score == 0, "Unbanked popcorn scores zero")
	model.players[0].score = 44
	model.players[4].score = 44
	_check(model.ranking() == [0, 4] and model.winners() == [0, 4], "Only occupied seats rank, and equal banked scores draw")

func _touchdown_and_ties() -> void:
	var model := _isolated([0, 2, 5])
	model.players[0].pos = Vector2(0.7, 0)
	model.players[2].pos = Vector2(0.4, 0)
	model.players[4].pos = Vector2.ZERO
	model.players[5].pos = Vector2(0, M.CATCH_RADIUS + 0.001)
	var first := _land(model, Vector2.ZERO)
	_check(first.winner == 2 and model.players[2].carry == 1 and model.players[4].carry == 0 and model.players[2].score == 0,
		"Closest occupied bowl wins at touchdown and catching does not bank")
	model.players[0].pos = Vector2(0, 1.045)
	model.players[2].pos = Vector2(1.045, 0)
	_check(_land(model, Vector2.ZERO).winner == -1, "A just-outside bowl misses the catch")
	model.players[0].pos = Vector2(0, 1.036)
	_check(_land(model, Vector2.ZERO).winner == 0, "A just-inside bowl catches")
	model.players[0].pos = Vector2(0, 0.2)
	model.players[2].pos = Vector2(0, -0.2)
	model.players[5].pos = Vector2(0.2, 0)
	var awards := [0, 0, 0, 0, 0, 0]
	for i in 6:
		var result := _land(model, Vector2.ZERO)
		awards[result.winner] += 1
	_check(awards == [2, 0, 2, 0, 0, 2], "Every occupied exact-tie contender wins twice across six consecutive ties")

func _bank_and_spill() -> void:
	var model := _isolated()
	var player: Dictionary = model.players[0]
	player.pos = Vector2.ZERO
	for i in M.WOBBLE:
		_land(model, Vector2.ZERO)
	_check(player.carry == M.WOBBLE and player.lost == 0, "The fifth kernel warns before any spill")
	_land(model, Vector2.ZERO)
	_check(player.carry == 3 and player.lost == 3 and player.spilled == 3 and player.last_spill == model.tick,
		"The next catch spills three from the old load of five and keeps the new catch")
	_land(model, Vector2.ZERO)
	for slot in M.SEATS:
		player.pos = M.shelf(slot) * 0.8
		model.step(M.STEP)
		_check(player.in_shelf == -1, "A bank requires entry inside the shelf circle")
		player.pos = M.shelf(slot)
		model.step(M.STEP)
		_check(player.bank_points == 6 and player.bank_shelf == slot and player.score == 6 * (slot + 1) and player.carry == 0,
			"Every equally sized shelf deposits four kernels plus two bonus points")
		player.carry = M.BIG_BANK
		model.step(M.STEP)
		_check(player.score == 6 * (slot + 1), "A player must leave and re-enter to bank again")
	player.carry = 5
	player.pos = M.shelf(0)
	model.step(M.STEP)
	_check(player.bank_points == 7 and player.score == 43 and player.big_banks == 7, "Five kernels can safely earn the largest bank")

func _wire_and_determinism() -> void:
	var first := _make([0, 2, 4, 5], [0, 2, 4, 5])
	var second := _make([0, 2, 4, 5], [0, 2, 4, 5])
	var guest := _make([0, 2, 4, 5], [0, 2, 4, 5])
	var stale: Dictionary = first.snapshot()
	for i in 186:
		first.step(0.5)
		for frame in 10:
			second.step(0.05)
		var packet: Dictionary = first.snapshot()
		_check(packet == second.snapshot(), "Same seed and input are independent of step chunking")
		guest.apply_snapshot(packet)
		_check(guest.snapshot() == packet, "Client re-encodes compact snapshots byte for byte")
		_check(guest.players[1].active == false and guest.players[5].active and guest.drops.size() <= M.MAX_DROPS,
			"Snapshots preserve the assigned lineup and stay within the wire budget")
	guest.apply_snapshot(stale)
	_check(guest.tick == M.ROUND_TICKS and guest.winners() == first.winners(), "Late packets do not rewind results")
	var isolated := _isolated()
	var bowl: Dictionary = isolated.players[0]
	bowl.pos = Vector2.ZERO
	bowl.carry = 5
	_land(isolated, Vector2.ZERO)
	var replica := _make([0])
	replica.apply_snapshot(isolated.snapshot())
	_check(replica.players[0].last_spill == bowl.last_spill and replica.players[0].spilled == 3 and replica.players[0].carry == 3,
		"LAN clients retain explicit spill feedback")
	isolated = _isolated()
	isolated.players[0].pos = M.shelf(5)
	isolated.players[0].carry = 5
	isolated.step(M.STEP)
	replica = _make([0])
	replica.apply_snapshot(isolated.snapshot())
	_check(replica.players[0].bank_points == 7 and replica.players[0].bank_shelf == 5 and replica.players[0].last_bank == 1,
		"LAN clients retain the biggest bank, its time and the shelf")

func _party_pacing() -> void:
	var scenarios := [
		{"active": [2], "bots": []},
		{"active": [0, 2, 4], "bots": []},
		{"active": [0, 1, 4, 5], "bots": [1, 5]},
		{"active": [0, 1, 2, 3, 4, 5], "bots": []},
	]
	for scenario in scenarios:
		for seed_value in [1, 55, 2401]:
			_play_match(scenario.active, scenario.bots, seed_value)

func _play_match(active: Array, bots: Array, seed_value: int) -> void:
	var m := _make(active, bots, seed_value)
	m.step(M.COUNTDOWN)
	var goals := {}
	var last_catch := {}
	var gaps := {}
	var first_banks := {}
	var last_land := 0
	var longest_land_gap := 0
	var leaders: Array = []
	var lead_changes := 0
	var burst_count := 0
	for slot in active:
		goals[slot] = m.players[slot].pos
		last_catch[slot] = 0
		gaps[slot] = 0
	for t in M.ROUND_TICKS:
		for slot in active:
			var p: Dictionary = m.players[slot]
			if int(p.last_catch) > int(last_catch[slot]):
				gaps[slot] = maxi(gaps[slot], p.last_catch - last_catch[slot])
				last_catch[slot] = p.last_catch
			if p.score > 0 and not first_banks.has(slot):
				first_banks[slot] = t
			if p.bot:
				continue
			if t % 8 == 0:
				goals[slot] = _human_goal(m, slot)
			_steer(m, slot, goals[slot])
		m.step(M.STEP)
		for drop in m.drops:
			if drop.land == m.tick:
				longest_land_gap = maxi(longest_land_gap, drop.land - last_land)
				last_land = drop.land
		if m.burst_tick == m.tick:
			burst_count += 1
		if m.tick % 60 == 0 and m.winners() != leaders:
			leaders = m.winners()
			lead_changes += 1
	var scores: Array = []
	var catches: Array = []
	for slot in active:
		scores.append(m.players[slot].score)
		catches.append(m.players[slot].caught)
		gaps[slot] = maxi(gaps[slot], M.ROUND_TICKS - last_catch[slot])
		_check(m.players[slot].score > 15 and m.players[slot].caught >= 12, "Each occupied seat has regular meaningful chances to catch and bank")
	longest_land_gap = maxi(longest_land_gap, M.ROUND_TICKS - last_land)
	_check(first_banks.size() == active.size() and first_banks.values().max() < 12 * M.HZ,
		"Each occupied seat banks in the opening within 12 seconds")
	_check(burst_count >= 8 and longest_land_gap < 3 * M.HZ, "Later center bursts recur without board-wide quiet stretches")
	print("lineup %s bots %s seed %d scores %s caught %s winners %s lead changes %d longest quiet %.2fs, longest individual catch gap %.2fs"
		% [active, bots, seed_value, scores, catches, m.winners(), lead_changes, longest_land_gap * M.STEP, gaps.values().max() * M.STEP])

func _human_goal(m: RefCounted, slot: int) -> Vector2:
	var p: Dictionary = m.players[slot]
	var here: Vector2 = p.pos
	var shelf_goal: Vector2 = m.nearest_shelf(here)
	var to_bank := here.distance_to(shelf_goal) / M.SPEED + 0.32
	var desired := 4 if slot % 3 != 1 else 5
	if p.carry >= desired or (p.carry > 0 and m.remaining() < to_bank + 0.6):
		return shelf_goal
	var best := INF
	var goal := here
	for drop in m.drops:
		var age: int = m.tick - drop.born
		var seconds: float = (drop.land - m.tick) * M.STEP
		var dist := here.distance_to(drop.pos)
		if age < 15 + slot % 3 * 7 or seconds <= 0.0 or dist > seconds * M.SPEED * 0.82 + 0.6:
			continue
		var cost := dist + seconds * 2.4
		for other in m.players:
			if other.active and other.slot != slot and Vector2(other.pos).distance_to(drop.pos) + 0.5 < dist:
				cost += 1.8
		if cost < best:
			best = cost
			goal = drop.pos
	if is_inf(best) and p.carry != 0 and m.tick - p.last_catch > 135:
		return shelf_goal
	return goal
