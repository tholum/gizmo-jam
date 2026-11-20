extends RefCounted
## Confirmations carry the displayed measure and phase, never a client clock.
## Receipt latches a choice. Each host tick applies the whole batch before sealing.

const SEATS := 6
const HZ := 20
const STEP := 1.0 / HZ
const COUNTDOWN := 3.0
const COUNT_TICKS := 3 * HZ
const MEASURES := 9
const PLACE_TICKS := 4 * HZ
const SEAL_TICK := 7 * HZ
const MEASURE_TICKS := 10 * HZ
const ROUND_TICKS := MEASURES * MEASURE_TICKS
const COUNT_IN_TICKS := 9
const ROW := 5
const MEASURE_ACTIONS := ["m1", "m2", "m3", "m4", "m5", "m6", "m7", "m8", "m9"]
const SLOT_ACTIONS := ["s1", "s2", "s3", "s4", "s5", "s6", "s7"]

var players: Array[Dictionary] = []
var phase := "countdown"
var countdown := COUNTDOWN
var elapsed := 0.0
var tick := 0
var round_id := 0
var measure := 0
var cells := 0
var accent := -1
var accents: Array[int] = []

var _active: Array[int] = []
var _count := COUNT_TICKS
var _owed := 0.0
var _guest := false

func begin(seed_value: int, seats: Array, id: int = 1, _endless: bool = false) -> void:
	round_id = id
	phase = "countdown"
	countdown = COUNTDOWN
	elapsed = 0.0
	tick = 0
	measure = 0
	_count = COUNT_TICKS
	_owed = 0.0
	_guest = false
	players.clear()
	_active.clear()
	for seat in SEATS:
		var info: Dictionary = seats[seat] if seat < seats.size() else {}
		var active: bool = info.get("active", not info.is_empty())
		players.append({
			"slot": seat, "active": active, "name": info.get("name", ""), "peer": info.get("peer", 0),
			"bot": info.get("bot", false), "score": 0, "last_points": 0,
			"note": -1, "placed": false, "revised": false, "aim": -1, "tag": false, "queued": -1,
		})
		if active:
			_active.append(seat)
	cells = maxi(2, _active.size() + 1)
	_deal_accents(seed_value)
	_start_measure()

func _deal_accents(seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var cycle: Array = range(cells)
	for i in range(cells - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var value: int = cycle[i]
		cycle[i] = cycle[j]
		cycle[j] = value
	accents.clear()
	for i in MEASURES:
		accents.append(cycle[i % cells])

func _start_measure() -> void:
	accent = accents[measure]
	for p in players:
		p.note = -1
		p.placed = false
		p.revised = false
		p.aim = -1
		p.tag = false
		p.queued = -1
		p.last_points = 0

func age() -> int:
	return tick - measure * MEASURE_TICKS

func window() -> String:
	if phase == "countdown":
		return "countdown"
	if age() < PLACE_TICKS:
		return "place"
	if age() < SEAL_TICK:
		return "revise"
	return "playback"

func deadline_ticks() -> int:
	match window():
		"place": return PLACE_TICKS - age()
		"revise": return SEAL_TICK - age()
	return 0

func can_confirm(p: Dictionary) -> bool:
	match window():
		"place": return p.active and not p.placed
		"revise": return p.active and not p.revised
	return false

func owners() -> Array:
	var result := []
	for cell in cells:
		result.append([])
	for seat in _active:
		var note: int = players[seat].note
		if note >= 0:
			result[note].append(seat)
	return result

func command(slot: int, action: String, pressed: bool) -> void:
	if _guest or slot < 0 or slot >= SEATS:
		return
	var p := players[slot]
	if p.bot or not can_confirm(p) or p.queued >= 0:
		return
	var tag := MEASURE_ACTIONS.find(action)
	if tag >= 0:
		p.tag = tag == measure and pressed == (window() == "revise")
		return
	var target := SLOT_ACTIONS.find(action)
	if target >= 0:
		if pressed and p.tag and target < cells:
			p.queued = target
		p.tag = false

func take_over(slot: int) -> void:
	if _guest or slot < 0 or slot >= SEATS or not players[slot].active or phase == "finished":
		return
	var p := players[slot]
	p.bot = true
	p.tag = false

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
	var measure_age := age()
	if measure_age < SEAL_TICK:
		_think()
		for p in players:
			if p.queued >= 0 and can_confirm(p):
				p.note = p.queued
				if measure_age < PLACE_TICKS:
					p.placed = true
				else:
					p.revised = true
				p.aim = -1
				p.queued = -1
	tick += 1
	elapsed = tick * STEP
	match age():
		PLACE_TICKS:
			for p in players:
				p.tag = false
				p.aim = -1
		SEAL_TICK:
			_seal()
		MEASURE_TICKS:
			if tick == ROUND_TICKS:
				phase = "finished"
			else:
				measure += 1
				_start_measure()

func _seal() -> void:
	var by_cell := owners()
	for p in players:
		p.tag = false
		p.aim = -1
		if p.note >= 0 and by_cell[p.note].size() == 1:
			p.last_points = 2 if p.note == accent else 1
			p.score += p.last_points

func _think() -> void:
	var start := 0 if age() < PLACE_TICKS else PLACE_TICKS
	var taken := owners()
	for seat in _active:
		var p := players[seat]
		if not p.bot or not can_confirm(p) or p.queued >= 0:
			continue
		var preview_at := start + 12 + posmod(seat - measure, SEATS) * 4
		if age() < preview_at:
			continue
		var solo: bool = p.note >= 0 and taken[p.note].size() == 1
		var target: int = p.note if solo else -1
		if taken[accent].is_empty():
			target = accent
		elif not solo:
			for offset in cells:
				var cell := (seat + measure + offset) % cells
				if taken[cell].is_empty():
					target = cell
					break
		if target == p.note or target < 0:
			p.aim = -1
		elif p.aim != target:
			p.aim = target
		elif age() >= preview_at + 7:
			p.queued = target
			taken[target].append(seat)

func beat() -> int:
	if window() != "playback" or age() < SEAL_TICK + COUNT_IN_TICKS:
		return -1
	var progress := age() - SEAL_TICK - COUNT_IN_TICKS
	return mini(cells - 1, floori(float(progress * cells) / (MEASURE_TICKS - SEAL_TICK - COUNT_IN_TICKS)))

func beat_progress() -> float:
	var progress := age() - SEAL_TICK - COUNT_IN_TICKS
	return clampf(float(progress * cells) / (MEASURE_TICKS - SEAL_TICK - COUNT_IN_TICKS) - beat(), 0.0, 1.0)

func remaining() -> float:
	return (ROUND_TICKS - tick) * STEP

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
		rows.encode_s8(at, p.note)
		rows.encode_s8(at + 1, p.aim)
		rows.encode_u8(at + 2, p.score)
		rows.encode_u8(at + 3, p.last_points)
		rows.encode_u8(at + 4, int(p.placed) | (int(p.revised) << 1) | (int(p.bot) << 2))
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
	var next_measure := mini(MEASURES - 1, floori(float(next_tick) / MEASURE_TICKS))
	var next_age: int = next_tick - next_measure * MEASURE_TICKS
	var decoded: Array[Dictionary] = []
	for p in players:
		var at: int = p.slot * ROW
		var note: int = rows.decode_s8(at)
		var aim: int = rows.decode_s8(at + 1)
		var score: int = rows.decode_u8(at + 2)
		var payoff: int = rows.decode_u8(at + 3)
		var flags: int = rows.decode_u8(at + 4)
		if note < -1 or note >= cells or aim < -1 or aim >= cells or flags > 7:
			return
		if bool(flags & 3) != (note >= 0) or score < p.score or score > MEASURES * 2 or payoff > 2 or payoff > score:
			return
		if (flags & 2 and next_age < PLACE_TICKS) or (payoff and (next_age < SEAL_TICK or note < 0)):
			return
		if (aim >= 0 and (not (flags & 4) or next_age >= SEAL_TICK)) or (not p.active and (note >= 0 or aim >= 0 or score > 0)):
			return
		if next_count > 0 and (note >= 0 or aim >= 0 or score > 0):
			return
		decoded.append({"note": note, "aim": aim, "score": score, "last_points": payoff,
			"placed": bool(flags & 1), "revised": bool(flags & 2), "bot": bool(flags & 4)})
	_guest = true
	tick = next_tick
	elapsed = tick * STEP
	_count = next_count
	countdown = _count * STEP
	measure = next_measure
	accent = accents[measure]
	phase = "countdown" if _count > 0 else ("finished" if tick == ROUND_TICKS else "running")
	for p in players:
		p.merge(decoded[p.slot], true)
