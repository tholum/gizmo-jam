extends RefCounted
## The host resolves release edges as a batch. Committed joints add their exact
## signed leverage immediately. Presentation and bots read that same projection.

const SEATS := 6
const HZ := 20
const STEP := 1.0 / HZ
const COUNTDOWN := 3.0
const COUNT_TICKS := 3 * HZ
const REHEARSALS := 5
const REHEARSAL_TICKS := 18 * HZ
const PAYOFF_TICKS := 28
const WORK_TICKS := REHEARSAL_TICKS - PAYOFF_TICKS
const ROUND_TICKS := REHEARSALS * REHEARSAL_TICKS
const DETENT_OPEN := 13
const DETENT_CENTER := 19
const DETENT_CLOSE := 72
const UPRIGHT := 2
const STOP := 9
const JOINT_ACTIONS := ["j0", "j1", "j2", "j3", "j4", "j5", "j6", "j7", "j8", "j9"]
const REHEARSAL_ACTIONS := ["r1", "r2", "r3", "r4", "r5"]
const ROW := 10
const FEEDBACK := ["", "latch", "miss", "claimed", "unwound"]

var players: Array[Dictionary] = []
var joints: Array[Dictionary] = []
var phase := "countdown"
var countdown := COUNTDOWN
var elapsed := 0.0
var tick := 0
var round_id := 0
var rehearsal := 0
var torque := 0

var _active: Array[int] = []
var _seed_offset := 0
var _mirror := 1
var _count := COUNT_TICKS
var _owed := 0.0
var _guest := false

func begin(seed_value: int, seats: Array, id: int = 1, _endless: bool = false) -> void:
	round_id = id
	phase = "countdown"
	countdown = COUNTDOWN
	elapsed = 0.0
	tick = 0
	rehearsal = 0
	_count = COUNT_TICKS
	_owed = 0.0
	_guest = false
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	_seed_offset = rng.randi_range(0, 59)
	_mirror = -1 if rng.randi_range(0, 1) == 0 else 1
	players.clear()
	_active.clear()
	for slot in SEATS:
		var info: Dictionary = seats[slot] if slot < seats.size() else {}
		var active: bool = info.get("active", not info.is_empty())
		players.append({"slot": slot, "active": active, "name": info.get("name", ""),
			"peer": info.get("peer", 0), "bot": info.get("bot", false), "score": 0, "wins": 0})
		if active:
			_active.append(slot)
	_start_rehearsal()

func _start_rehearsal() -> void:
	var count := _active.size()
	var mirror := _mirror * (1 if rehearsal % 2 == 0 else -1)
	torque = mirror * (1 + (rehearsal + _seed_offset) % 2)
	joints.clear()
	for p in players:
		p.merge({"dedicated": -1, "latched": false, "shared": -1, "focus": -1, "holding": -1,
			"started": -1, "queued": -1, "feedback": 0, "stamp": -1, "bonus": 0}, true)
	for joint in count:
		var slot := _active[(joint + rehearsal + _seed_offset) % count]
		var leverage := (6 + joint / 2) * (-1 if joint % 2 == 0 else 1) * _mirror
		joints.append({"seat": slot, "owner": -1, "force": leverage})
		players[slot].dedicated = joint
		players[slot].focus = joint
	var shared_count := clampi(1 + count / 2, 2, 4)
	for shared in shared_count:
		var physical := (shared + rehearsal + _seed_offset) % shared_count
		var strength := 4
		if count % 2 == 1 and physical < 2:
			strength = 6 + count / 2
		elif physical >= 2 and count != 5:
			strength = 8
		if count % 2 == 0 and physical == shared_count - 1 and rehearsal % 2 == 1:
			strength += 3
		var leverage := strength * (-1 if physical % 2 == 0 else 1) * mirror
		joints.append({"seat": -1, "owner": -1, "force": leverage})

func age() -> int:
	return tick - rehearsal * REHEARSAL_TICKS

func window() -> String:
	if phase == "countdown":
		return "countdown"
	return "work" if age() < WORK_TICKS else "bell"

func deadline_ticks() -> int:
	return maxi(0, WORK_TICKS - age())

func remaining() -> float:
	return (ROUND_TICKS - tick) * STEP

static func safe(value: int) -> bool:
	return absi(value) <= UPRIGHT

func options(slot: int) -> Array[int]:
	var result: Array[int] = []
	if window() == "bell" or slot < 0 or slot >= players.size():
		return result
	var p := players[slot]
	if not p.active or p.shared >= 0:
		return result
	if not p.latched:
		result.append(p.dedicated)
		return result
	for joint in range(_active.size(), joints.size()):
		if joints[joint].owner < 0:
			result.append(joint)
	return result

func projection(slot: int, joint: int = -1) -> Dictionary:
	var possible := options(slot)
	if slot >= 0 and slot < players.size() and joint < 0:
		joint = players[slot].focus
	if joint not in possible:
		joint = -1
	var solo: int = torque + (joints[joint].force if joint >= 0 else 0)
	var result := {"joint": joint, "solo": solo, "partner": -1, "partner_joint": -1,
		"paired": solo, "correction": "upright" if safe(solo) else "none"}
	if joint >= 0 and not _can_reach(slot, joint):
		result.correction = "none"
		return result
	if joint >= 0 and not safe(solo):
		for partner in _active:
			if partner == slot:
				continue
			for other in options(partner):
				if joint == other or not _can_reach(partner, other):
					continue
				var paired: int = solo + joints[other].force
				if safe(paired) and (result.partner < 0 or absi(paired) < absi(result.paired)):
					result.merge({"partner": partner, "partner_joint": other, "paired": paired, "correction": "partner"}, true)
	return result

func _can_reach(slot: int, joint: int) -> bool:
	if window() == "countdown":
		return true
	var p := players[slot]
	var held_ticks: int = tick - p.started if p.holding == joint else 0
	if p.bot:
		if p.holding >= 0 and p.holding != joint:
			return false
		var order := posmod(_active.find(slot) - rehearsal, _active.size())
		var waits := maxi(0, (166 if p.latched else 34) + order * 9 - age()) if held_ticks == 0 else 0
		return deadline_ticks() > waits + maxi(0, DETENT_CENTER + 6 - held_ticks)
	return deadline_ticks() > maxi(0, DETENT_OPEN - held_ticks)

func alternate(slot: int, selected: int = -1) -> int:
	if slot < 0 or slot >= players.size():
		return -1
	if selected < 0:
		selected = players[slot].focus
	var partner_option := -1
	for joint in options(slot):
		if joint == selected:
			continue
		var forecast := projection(slot, joint)
		if forecast.correction == "upright":
			return joint
		if forecast.correction == "partner" and partner_option < 0:
			partner_option = joint
	return partner_option

func sweep_progress(slot: int) -> float:
	var p := players[slot]
	return clampf(float(tick - p.started) / DETENT_CENTER, 0.0, 1.0) if p.holding >= 0 else 0.0

func in_detent(slot: int) -> bool:
	var p := players[slot]
	return p.holding >= 0 and tick - p.started >= DETENT_OPEN and tick - p.started <= DETENT_CLOSE

func command(slot: int, action: String, pressed: bool) -> void:
	if _guest or slot < 0 or slot >= SEATS or window() != "work":
		return
	var p := players[slot]
	if not p.active or p.bot:
		return
	if action == "cancel" and pressed:
		_cancel(p)
		p.queued = -1
		return
	var tag := REHEARSAL_ACTIONS.find(action)
	if tag >= 0:
		if pressed and tag == rehearsal:
			_hold(p)
		return
	var joint := JOINT_ACTIONS.find(action)
	if joint < 0:
		return
	if pressed:
		if p.holding < 0 and p.queued < 0 and joint in options(slot):
			p.focus = joint
	elif p.holding == joint:
		_release(p)

func _hold(p: Dictionary) -> void:
	if p.holding < 0 and p.queued < 0 and int(p.focus) in options(p.slot):
		p.holding = p.focus
		p.started = tick

func _release(p: Dictionary) -> void:
	var joint: int = p.holding
	if joint in options(p.slot):
		if in_detent(p.slot):
			p.queued = joint
		else:
			_stamp(p, 2)
	_cancel(p)

func _cancel(p: Dictionary) -> void:
	p.holding = -1
	p.started = -1

func _stamp(p: Dictionary, feedback: int) -> void:
	p.feedback = feedback
	p.stamp = age()

func take_over(slot: int) -> void:
	if _guest or slot < 0 or slot >= SEATS or not players[slot].active or phase == "finished":
		return
	var p := players[slot]
	p.bot = true
	_cancel(p)
	p.queued = -1

func step(delta: float) -> void:
	if _guest or phase == "finished":
		return
	_owed += delta
	while _owed + 0.00000001 >= STEP and phase != "finished":
		_owed -= STEP
		if _count > 0:
			_count -= 1
			countdown = _count * STEP
			if _count == 0:
				phase = "running"
		else:
			_step_tick()

func _step_tick() -> void:
	if window() == "work":
		_think()
		_commit_batch()
		for p in players:
			if p.holding >= 0 and tick - p.started >= DETENT_CLOSE:
				_cancel(p)
				_stamp(p, 4)
	tick += 1
	elapsed = tick * STEP
	match age():
		WORK_TICKS:
			for p in players:
				_cancel(p)
				if p.latched and safe(torque):
					p.score += 1
					p.bonus = 1
		REHEARSAL_TICKS:
			if tick == ROUND_TICKS:
				phase = "finished"
			else:
				rehearsal += 1
				_start_rehearsal()

func _commit_batch() -> void:
	var count := _active.size()
	for joint in joints.size():
		var claims: Array[int] = []
		for slot in _active:
			var p := players[slot]
			if p.queued == joint:
				p.queued = -1
				if joint in options(slot):
					claims.append(slot)
		if claims.is_empty():
			continue
		# A prior disputed win yields to seats with fewer wins. The seeded
		# physical assignment and joint-local rotation break remaining ties.
		var start := (_seed_offset + rehearsal + joint) % count
		claims.sort_custom(func(a: int, b: int) -> bool:
			if players[a].wins != players[b].wins:
				return players[a].wins < players[b].wins
			return posmod(_active.find(a) - start, count) < posmod(_active.find(b) - start, count))
		var winner := players[claims[0]]
		if claims.size() > 1:
			winner.wins += 1
		joints[joint].owner = winner.slot
		torque += joints[joint].force
		winner.score += 1
		if joints[joint].seat < 0:
			winner.shared = joint
		else:
			winner.latched = true
		winner.focus = -1
		_stamp(winner, 1)
		for p in players:
			if p.slot != winner.slot and p.focus == joint:
				if p.holding == joint or p.slot in claims:
					_cancel(p)
					_stamp(p, 3)
				p.focus = -1
	for p in players:
		if p.active and p.focus < 0:
			var available := options(p.slot)
			if not available.is_empty():
				p.focus = available[0]

func _think() -> void:
	for seat in _active:
		var p := players[seat]
		if not p.bot:
			continue
		if p.holding >= 0:
			if tick - p.started >= DETENT_CENTER + 6:
				_release(p)
			continue
		var available := options(seat)
		if available.is_empty():
			continue
		var order := posmod(_active.find(seat) - rehearsal, _active.size())
		if age() < (34 if not p.latched else 166) + order * 9:
			continue
		if not p.latched:
			p.focus = available[0]
			_hold(p)
			continue
		var best := -1
		var smallest := absi(torque)
		for joint in available:
			var forecast := projection(seat, joint)
			if absi(forecast.solo) < smallest or (best < 0 and forecast.correction == "partner" and age() < WORK_TICKS - 52):
				best = joint
				smallest = absi(forecast.solo)
		if best >= 0 and age() < WORK_TICKS - DETENT_CENTER - 6:
			p.focus = best
			_hold(p)

func ranking() -> Array:
	var order := _active.duplicate()
	order.sort_custom(func(a, b): return players[a].score > players[b].score if players[a].score != players[b].score else a < b)
	return order

func winners() -> Array:
	var order := ranking()
	if order.is_empty():
		return []
	return order.filter(func(slot): return players[slot].score == players[order[0]].score)

func snapshot() -> Dictionary:
	var rows := PackedByteArray()
	rows.resize(ROW * SEATS)
	for p in players:
		var at: int = p.slot * ROW
		rows.encode_u8(at, p.score)
		rows.encode_s8(at + 1, p.shared)
		rows.encode_s8(at + 2, p.focus)
		rows.encode_s8(at + 3, p.holding)
		rows.encode_s16(at + 4, p.started - rehearsal * REHEARSAL_TICKS if p.started >= 0 else -1)
		rows.encode_s16(at + 6, p.stamp)
		rows.encode_u8(at + 8, p.feedback)
		rows.encode_u8(at + 9, int(p.latched) | (int(p.bot) << 1) | (int(p.bonus) << 2))
	return {"id": round_id, "tick": tick, "count": _count, "state": rows}

func apply_snapshot(data: Dictionary) -> void:
	var rows: Variant = data.get("state")
	var next_tick: Variant = data.get("tick")
	var next_count: Variant = data.get("count")
	if data.get("id") != round_id or not (rows is PackedByteArray and next_tick is int and next_count is int):
		return
	if rows.size() != ROW * SEATS or players.size() != SEATS or next_tick < tick or next_tick > ROUND_TICKS:
		return
	if next_count < 0 or next_count > _count or (next_count > 0 and next_tick != 0):
		return
	var next_rehearsal := mini(REHEARSALS - 1, int(next_tick) / REHEARSAL_TICKS)
	var next_age: int = next_tick - next_rehearsal * REHEARSAL_TICKS
	var decoded: Array[Dictionary] = []
	var claimed := PackedInt32Array()
	for p in players:
		var at: int = p.slot * ROW
		var score: int = rows.decode_u8(at)
		var shared: int = rows.decode_s8(at + 1)
		var focus: int = rows.decode_s8(at + 2)
		var holding: int = rows.decode_s8(at + 3)
		var start: int = rows.decode_s16(at + 4)
		var stamp: int = rows.decode_s16(at + 6)
		var feedback: int = rows.decode_u8(at + 8)
		var flags: int = rows.decode_u8(at + 9)
		var latched := bool(flags & 1)
		var bonus := int(bool(flags & 4))
		if flags > 7 or score < p.score or score > REHEARSALS * 3 or feedback >= FEEDBACK.size():
			return
		if focus < -1 or focus >= joints.size() or holding < -1 or holding >= joints.size():
			return
		if shared < -1 or (shared >= 0 and (shared < _active.size() or shared >= joints.size() or shared in claimed or not latched)):
			return
		if (holding >= 0 and (holding != focus or start < 0 or next_age - start > DETENT_CLOSE or next_age >= WORK_TICKS)) or (holding < 0 and start != -1) or start > next_age:
			return
		if stamp < -1 or stamp > next_age or (stamp < 0) != (feedback == 0) or (bonus and (not latched or next_age < WORK_TICKS)):
			return
		if not p.active and (focus >= 0 or latched or score or feedback):
			return
		if next_count > 0 and (latched or score or holding >= 0 or feedback):
			return
		if shared >= 0:
			claimed.append(shared)
		decoded.append({"score": score, "shared": shared, "focus": focus, "holding": holding,
			"started": start + next_rehearsal * REHEARSAL_TICKS if start >= 0 else -1,
			"stamp": stamp, "feedback": feedback, "latched": latched, "bot": bool(flags & 2), "bonus": bonus})
	_guest = true
	tick = next_tick
	elapsed = tick * STEP
	_count = next_count
	countdown = _count * STEP
	rehearsal = next_rehearsal
	phase = "countdown" if _count > 0 else ("finished" if tick == ROUND_TICKS else "running")
	_start_rehearsal()
	for p in players:
		p.merge(decoded[p.slot], true)
		var mounted := [p.dedicated if p.latched else -1, p.shared]
		for joint in mounted:
			if joint >= 0:
				joints[joint].owner = p.slot
				torque += joints[joint].force
