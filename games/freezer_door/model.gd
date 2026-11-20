extends RefCounted
## The host samples input edges together. Heat and scoring only use integer ticks.

const SEATS := 6
const COLS := 6
const DRAWERS := 12
const HZ := 20
const STEP := 1.0 / HZ
const COUNTDOWN := 3.0
const COUNT_TICKS := 3 * HZ
const WAVES := 8
const WAVE_TICKS := 11 * HZ
const ROUND_TICKS := WAVES * WAVE_TICKS
const RESERVE_TICKS := 3 * HZ
const MAX_CLAIMS := 2
const BAND_LOW := 144
const BAND_HIGH := 324
const MAX_HEAT := 396
const SELF_FLOW := 3
const NEIGHBOR_FLOW := 2
const MAX_FLOW := SELF_FLOW + 3 * NEIGHBOR_FLOW
const BEAT_TICKS := HZ / 2
const REPEAT_TICKS := 5
const DIRS := {"up": 1, "down": 2, "left": 4, "right": 8}
const PLAYER_BYTES := 9
const DRAWER_BYTES := 3
const SNAP_BYTES := SEATS * PLAYER_BYTES + DRAWERS * DRAWER_BYTES
const NEIGHBORS := [
	[1, 6], [0, 2, 7], [1, 3, 8], [2, 4, 9], [3, 5, 10], [4, 11],
	[0, 7], [1, 6, 8], [2, 7, 9], [3, 8, 10], [4, 9, 11], [5, 10],
]
var players: Array[Dictionary] = []
var drawers: Array[Dictionary] = []
var phase := "countdown"
var countdown := COUNTDOWN
var elapsed := 0.0
var tick := 0
var wave := 0
var round_id := 0

var _seed := 0
var _count := COUNT_TICKS
var _owed := 0.0
var _guest := false
var _active_count := 0

func begin(seed_value: int, slots: Array, id: int = 1, _endless: bool = false) -> void:
	_seed = seed_value
	round_id = id
	phase = "countdown"
	countdown = COUNTDOWN
	elapsed = 0.0
	tick = 0
	wave = 0
	_count = COUNT_TICKS
	_owed = 0.0
	_guest = false
	_active_count = 0
	players.clear()
	for slot in SEATS:
		var seat: Dictionary = slots[slot] if slot < slots.size() else {}
		var active: bool = seat.get("active", not seat.is_empty())
		players.append({
			"slot": slot, "name": seat.get("name", ""), "peer": seat.get("peer", 0),
			"bot": seat.get("bot", false), "active": active, "order": _active_count if active else -1,
			"score": 0, "cursor": 0, "hold": -1, "used": 0, "last_tick": -1, "last_drawer": -1,
			"last_points": 0, "grab_tick": -1, "dirs": 0, "nudge": 0, "repeat_at": 0,
			"down": false, "press": false, "release": false, "abandon": false, "bot_target": -1,
		})
		_active_count += int(active)
	_reload()

func _left_col() -> int:
	return (COLS - _active_count) / 2

func enabled(drawer: int) -> bool:
	var column := drawer % COLS
	return column >= _left_col() and column < _left_col() + _active_count

func _starter(order: int) -> int:
	# Alternate sides and rows and shift the station assignment every two waves.
	# Each layout remains a checkerboard inside the occupied columns.
	var index := posmod(order + wave / 2 + posmod(_seed, _active_count), _active_count)
	if wave % 2:
		return _left_col() + _active_count - 1 - index + (1 - index % 2) * COLS
	return _left_col() + index + (index % 2) * COLS

func _reload() -> void:
	drawers.clear()
	for drawer in DRAWERS:
		# The initial thermometer pattern is mirrored and independent of seat count.
		var column := drawer % COLS - _left_col()
		var position := column + (drawer / COLS) * _active_count
		var pair := absi(mini(position, _active_count * 2 - 1 - position))
		var heat := 32 + posmod(posmod(_seed, 37) + pair * 19 + (wave / 2) * 23, 57)
		drawers.append({"owner": -1, "heat": heat, "holders": 0, "spent": false})
	for p in players:
		if not p.active:
			continue
		p.cursor = _starter(p.order)
		p.hold = -1
		p.used = 0
		p.grab_tick = -1
		p.bot_target = -1
		drawers[p.cursor].owner = p.slot

func remaining() -> float:
	return (ROUND_TICKS - tick) * STEP

func wave_remaining() -> float:
	return ((wave + 1) * WAVE_TICKS - tick) * STEP

func reserve_left() -> int:
	return maxi(0, RESERVE_TICKS - (tick - wave * WAVE_TICKS))

func can_claim(slot: int, drawer: int) -> bool:
	var d := drawers[drawer]
	return enabled(drawer) and not d.spent and d.holders == 0 and (reserve_left() == 0 or d.owner in [-1, slot])

func flow(drawer: int) -> int:
	var rate := SELF_FLOW if drawers[drawer].holders else 0
	for adjacent in NEIGHBORS[drawer]:
		if drawers[adjacent].holders:
			rate += NEIGHBOR_FLOW
	return rate

func _project(drawer: int, ticks: int) -> int:
	var d := drawers[drawer]
	if d.spent or not enabled(drawer):
		return d.heat
	var cap := MAX_HEAT if d.holders else BAND_LOW
	return mini(cap, int(d.heat) + flow(drawer) * ticks)

func forecast(drawer: int) -> int:
	return _project(drawer, BEAT_TICKS)

static func bonus(heat: int) -> bool:
	return heat >= BAND_LOW and heat <= BAND_HIGH

func command(slot: int, action: String, pressed: bool) -> void:
	if _guest or slot < 0 or slot >= players.size() or phase == "finished":
		return
	var p := players[slot]
	if not p.active or p.bot:
		return
	if DIRS.has(action):
		var bit: int = DIRS[action]
		if pressed and not (p.dirs & bit):
			p.nudge |= bit
		p.dirs = int(p.dirs) | bit if pressed else int(p.dirs) & ~bit
	elif action == "hold" and p.down != pressed:
		p.down = pressed
		if phase == "running":
			if pressed:
				p.press = true
			else:
				p.release = true

func take_over(slot: int) -> void:
	if _guest or slot < 0 or slot >= players.size() or not players[slot].active or phase == "finished":
		return
	var p := players[slot]
	p.bot = true
	p.dirs = 0
	p.nudge = 0
	p.down = false
	p.press = false
	p.release = false
	p.abandon = p.hold >= 0

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
	# Gather from the same board. Simultaneous grabs get the same eligibility,
	# even if one claimant also released before the host sampled the buttons.
	var claims := PackedInt32Array()
	claims.resize(SEATS)
	claims.fill(-1)
	for p in players:
		if not p.active:
			continue
		if p.bot and not p.abandon:
			_think(p)
		if p.hold < 0 and p.press and p.used < MAX_CLAIMS and can_claim(p.slot, p.cursor):
			claims[p.slot] = p.cursor
	for p in players:
		if p.hold >= 0 and (p.release or p.abandon):
			_release(p, not p.abandon)
	for p in players:
		var drawer := claims[int(p.slot)]
		if drawer >= 0:
			p.hold = drawer
			p.grab_tick = tick + 1
			drawers[drawer].holders |= 1 << int(p.slot)
	for p in players:
		# A quick tap still earns a treat. A release followed by a final press
		# while idle starts the hold, matching the last sampled button state.
		if claims[int(p.slot)] >= 0 and not p.down:
			_release(p, true)
		p.press = false
		p.release = false
		p.abandon = false

	for drawer in DRAWERS:
		drawers[drawer].heat = _project(drawer, 1)
	for p in players:
		if p.active and not p.bot:
			_move(p)
	tick += 1
	elapsed = tick * STEP
	if tick == (wave + 1) * WAVE_TICKS:
		for p in players:
			if p.hold >= 0:
				_release(p, false)
		if tick == ROUND_TICKS:
			phase = "finished"
		else:
			wave += 1
			_reload()

func _release(p: Dictionary, score: bool) -> void:
	var drawer: int = p.hold
	var d := drawers[drawer]
	p.hold = -1
	p.used += 1
	if score:
		p.last_points = 2 if bonus(d.heat) else 1
		p.score += p.last_points
		p.last_tick = tick + 1
		p.last_drawer = drawer
	d.holders &= ~(1 << int(p.slot))
	d.spent = d.holders == 0

func _move(p: Dictionary) -> void:
	var edge: int = p.nudge
	p.nudge = 0
	if p.hold >= 0:
		return
	if edge == 0 and tick < p.repeat_at:
		return
	var bits: int = edge if edge else p.dirs
	if bits == 0:
		return
	var x: int = p.cursor % COLS + int(bool(bits & 8)) - int(bool(bits & 4))
	var y: int = p.cursor / COLS + int(bool(bits & 2)) - int(bool(bits & 1))
	p.cursor = clampi(x, _left_col(), _left_col() + _active_count - 1) + clampi(y, 0, 1) * COLS
	p.repeat_at = tick + REPEAT_TICKS

func _think(p: Dictionary) -> void:
	var age := tick - wave * WAVE_TICKS
	var stagger := posmod(int(p.order) * 17 + wave * 11 + posmod(_seed, 27), 30)
	if p.hold >= 0:
		var drawer: int = p.hold
		var heat: int = drawers[drawer].heat
		# Slow seats keep a door open longer, but react if the forecast
		# indicates another drawer is pushing them past the stripe.
		var target := BAND_LOW + 30 + stagger * 4
		p.release = bonus(heat) and (heat >= target or forecast(drawer) > BAND_HIGH)
		p.release = p.release or heat > BAND_HIGH or wave_remaining() <= 0.3
		p.down = not p.release
		return
	if p.used >= MAX_CLAIMS or age < 7 + stagger or tick < p.repeat_at:
		return
	if p.used > 0 and tick - int(p.last_tick) < 12 + stagger:
		return
	if p.used == 0 and can_claim(p.slot, p.cursor):
		p.press = true
		p.down = true
		return
	if p.bot_target < 0 or not can_claim(p.slot, p.bot_target):
		p.bot_target = _pick_drawer(p)
	if p.bot_target < 0:
		return
	if p.cursor == p.bot_target:
		p.press = true
		p.down = true
		return
	var x := move_toward(float(p.cursor % COLS), float(p.bot_target % COLS), 1.0)
	var y := move_toward(float(p.cursor / COLS), float(p.bot_target / COLS), 1.0)
	p.cursor = int(x) + int(y) * COLS
	p.repeat_at = tick + REPEAT_TICKS

func _pick_drawer(p: Dictionary) -> int:
	var best := -1
	var best_value := -9999
	for i in DRAWERS:
		var drawer := (i + int(p.order) * 2 + wave) % DRAWERS
		if not can_claim(p.slot, drawer):
			continue
		var distance := absi(drawer % COLS - p.cursor % COLS) + absi(drawer / COLS - p.cursor / COLS)
		var value := forecast(drawer) - distance * 24
		if value > best_value:
			best_value = value
			best = drawer
	return best

func ranking() -> Array:
	var order := range(players.size()).filter(func(slot): return players[slot].active)
	order.sort_custom(func(a, b):
		return players[a].score > players[b].score if players[a].score != players[b].score else a < b)
	return order

func winners() -> Array:
	var order := ranking()
	return order.filter(func(slot): return players[slot].score == players[order[0]].score) if not order.is_empty() else []

func snapshot() -> Dictionary:
	var rows := PackedByteArray()
	rows.resize(SNAP_BYTES)
	var at := 0
	for p in players:
		rows.encode_u8(at, p.score)
		rows.encode_u8(at + 1, p.cursor)
		rows.encode_u8(at + 2, int(p.used) | (int(p.bot) << 2) | (int(p.last_points) << 3))
		rows.encode_s8(at + 3, p.hold)
		rows.encode_s16(at + 4, p.last_tick)
		rows.encode_s8(at + 6, p.last_drawer)
		rows.encode_s16(at + 7, p.grab_tick)
		at += PLAYER_BYTES
	for d in drawers:
		rows.encode_u16(at, d.heat)
		rows.encode_u8(at + 2, int(d.holders) | (int(d.spent) << SEATS))
		at += DRAWER_BYTES
	return {"id": round_id, "tick": tick, "count": _count, "state": rows}

func apply_snapshot(data: Dictionary) -> void:
	var rows: Variant = data.get("state")
	var next_tick: Variant = data.get("tick")
	var next_count: Variant = data.get("count")
	if not (rows is PackedByteArray and next_tick is int and next_count is int and data.get("id") is int):
		return
	if players.size() != SEATS or rows.size() != SNAP_BYTES or next_tick < 0 or next_tick > ROUND_TICKS:
		return
	if next_count < 0 or next_count > COUNT_TICKS or (next_count > 0 and next_tick > 0):
		return

	var masks := PackedInt32Array()
	masks.resize(DRAWERS)
	var at := 0
	for p in players:
		var flags: int = rows.decode_u8(at + 2)
		var held: int = rows.decode_s8(at + 3)
		var last: int = rows.decode_s16(at + 4)
		var popped: int = rows.decode_s8(at + 6)
		var grabbed: int = rows.decode_s16(at + 7)
		if rows.decode_u8(at) > WAVES * MAX_CLAIMS * 2 or rows.decode_u8(at + 1) >= DRAWERS:
			return
		if p.active and not enabled(rows.decode_u8(at + 1)):
			return
		if (flags & 3) > MAX_CLAIMS or flags >> 3 > 2 or held < -1 or held >= DRAWERS or popped < -1 or popped >= DRAWERS:
			return
		if last < -1 or last > next_tick or grabbed < -1 or grabbed > next_tick:
			return
		if (last >= 0) != (popped >= 0) or (last >= 0) != (flags >> 3 > 0):
			return
		if held >= 0:
			if not p.active or not enabled(held) or grabbed < 0 or (flags & 3) >= MAX_CLAIMS or next_tick == ROUND_TICKS:
				return
			masks[held] |= 1 << int(p.slot)
		at += PLAYER_BYTES
	for drawer in DRAWERS:
		var flags: int = rows.decode_u8(at + 2)
		if rows.decode_u16(at) > MAX_HEAT or (flags & 63) != masks[drawer] or flags > 127:
			return
		if (flags & 64) and masks[drawer]:
			return
		at += DRAWER_BYTES

	_guest = true
	round_id = data.id
	tick = next_tick
	wave = mini(WAVES - 1, tick / WAVE_TICKS)
	_count = next_count
	countdown = _count * STEP
	elapsed = tick * STEP
	phase = "countdown" if _count > 0 else ("finished" if tick == ROUND_TICKS else "running")
	for d in drawers:
		d.owner = -1
	at = 0
	for p in players:
		p.score = rows.decode_u8(at)
		p.cursor = rows.decode_u8(at + 1)
		var flags: int = rows.decode_u8(at + 2)
		p.used = flags & 3
		p.bot = bool(flags & 4)
		p.last_points = flags >> 3
		p.hold = rows.decode_s8(at + 3)
		p.last_tick = rows.decode_s16(at + 4)
		p.last_drawer = rows.decode_s8(at + 6)
		p.grab_tick = rows.decode_s16(at + 7)
		if p.active:
			drawers[_starter(p.order)].owner = p.slot
		at += PLAYER_BYTES
	for d in drawers:
		d.heat = rows.decode_u16(at)
		var flags: int = rows.decode_u8(at + 2)
		d.holders = flags & 63
		d.spent = bool(flags & 64)
		at += DRAWER_BYTES
