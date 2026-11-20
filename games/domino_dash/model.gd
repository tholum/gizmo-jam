extends RefCounted
## The host advances the authored domino falls. Presentation reads start ticks.

const SEATS := 6
const BRANCHES := 3
const HZ := 20
const STEP := 1.0 / HZ
const COUNTDOWN := 3.0
const WAVES := 6
const WAVE_TICKS := 15 * HZ
const ROUND_TICKS := WAVES * WAVE_TICKS
const PERIOD := 46
const OPEN_TICKS := 15
const FALL_TICKS := 4
const STARTER_LENGTH := 3
const BRIDGE_LENGTH := 4
const STARTER_REACH := 0.85
const DIAMOND_REACH := 0.91
const SPEED := 6.25
const POSE_SCALE := 256.0
const FIELD := Vector2(13.0, 6.05)
const PLAYER_BYTES := 13
const CHAIN_BYTES := 4
const SNAP_BYTES := SEATS * PLAYER_BYTES + (SEATS + BRANCHES) * CHAIN_BYTES
const DIRS := {"up": 1, "down": 2, "left": 4, "right": 8}
const OPEN_AT := [52, 122, 208]
const BRIDGE_ROTATION := [0, 2, 1, 1, 0, 2]
const FOUR_STATION_ROTATION := [0, 2, 1, 3, 0, 2]
const STATIONS := [[0, 1], [2, 1, 4], [0, 1, 2, 5], [0, 1, 2, 3, 4], [0, 1, 2, 3, 4, 5]]

var players: Array[Dictionary] = []
var starters: Array[Dictionary] = []
var bridges: Array[Dictionary] = []
var phase := "countdown"
var countdown := COUNTDOWN
var elapsed := 0.0
var tick := 0
var wave := 0
var round_id := 0

var _active_count := 0
var _priority := 0
var _first_bridge := 1
var _station_offset := 0
var _count_ticks := roundi(COUNTDOWN * HZ)
var _owed := 0.0
var _guest := false

static func branch_x(branch: int) -> float:
	return (branch - 1) * 8.0

static func diamond_pos(branch: int, side: int) -> Vector2:
	return Vector2(branch_x(branch), _sign(side) * 1.53)

static func starter_pos(station: int) -> Vector2:
	return Vector2(branch_x(station_branch(station)), _sign(station % 2) * 4.6)

static func spawn_pos(station: int) -> Vector2:
	return starter_pos(station) + Vector2(0, _sign(station % 2) * 1.08)

static func station_branch(station: int) -> int:
	# The first two stations face each other across the center bridge.
	return [1, 0, 2][floori(station / 2.0)]

static func domino_pos(index: int, side: int, rank: int, shared: bool) -> Vector2:
	if shared:
		return Vector2(branch_x(index) + (rank - 1.5) * 0.75 * _sign(side), 0)
	return starter_pos(index) - Vector2(0, _sign(index % 2) * 0.74 * rank)

static func _sign(side: int) -> int:
	return 1 if side == 0 else -1

func begin(seed_value: int, slots: Array, id: int = 1, _endless: bool = false) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	round_id = id
	phase = "countdown"
	countdown = COUNTDOWN
	elapsed = 0.0
	tick = 0
	wave = 0
	_owed = 0.0
	_count_ticks = roundi(COUNTDOWN * HZ)
	_guest = false
	_active_count = slots.filter(func(seat): return seat.get("active", true)).size()
	_priority = rng.randi_range(0, maxi(0, _active_count - 1))
	_first_bridge = rng.randi_range(0, BRANCHES - 1)
	_station_offset = rng.randi_range(0, maxi(0, _active_count - 1))
	players.clear()
	var active_index := 0
	for slot in SEATS:
		var seat: Dictionary = slots[slot]
		var active: bool = seat.get("active", true)
		var station := _station(active_index, 0) if active else 0
		var side := station % 2
		players.append({
			"slot": slot, "name": seat.name, "peer": seat.peer, "bot": seat.bot, "active": active,
			"station": station, "order": active_index if active else -1, "score": 0, "last_point": -1,
			"pos": _snap(spawn_pos(station)), "vel": Vector2.ZERO, "side": side, "input": 0,
			"down": false, "queued": false, "bot_offset": rng.randi_range(0, 99),
		})
		active_index += int(active)
	_reload()

func remaining() -> float:
	return maxf(0.0, (ROUND_TICKS - tick) * STEP)

func wave_remaining() -> float:
	return maxf(0.0, ((wave + 1) * WAVE_TICKS - tick) * STEP)

func opens_in(branch: int) -> int:
	return maxi(0, _opening_tick(branch) - tick)

func _opening_tick(branch: int) -> int:
	return wave * WAVE_TICKS + OPEN_AT[posmod(branch - _first_bridge - BRIDGE_ROTATION[wave], BRANCHES)]

func alignment(branch: int) -> int:
	return posmod(maxi(0, tick - _opening_tick(branch)), PERIOD)

func aligned(branch: int) -> bool:
	return possible_falls(BRIDGE_LENGTH) > 0 and opens_in(branch) == 0 and alignment(branch) < OPEN_TICKS

func possible_falls(length: int) -> int:
	var remaining_ticks := (wave + 1) * WAVE_TICKS - tick
	return mini(length, ceili(float(remaining_ticks) / FALL_TICKS))

func action_target(slot: int) -> Dictionary:
	var idle := {"kind": "idle", "index": -1, "side": 0, "at": Vector2.ZERO}
	if slot < 0 or slot >= players.size() or phase != "running" or not players[slot].active or possible_falls(STARTER_LENGTH) == 0:
		return idle
	var p := players[slot]
	var at: Vector2 = p.pos
	if starters[slot].owner < 0:
		var starter := starter_pos(p.station)
		if at.distance_squared_to(starter) <= STARTER_REACH ** 2:
			return {"kind": "starter", "index": slot, "side": p.station % 2, "at": starter}
		return idle
	for branch in BRANCHES:
		if bridges[branch].owner >= 0:
			continue
		for side in 2:
			var diamond := diamond_pos(branch, side)
			if at.distance_squared_to(diamond) <= DIAMOND_REACH ** 2:
				return {"kind": "bridge" if aligned(branch) else "wait", "index": branch, "side": side, "at": diamond}
	return idle

func command(slot: int, action: String, pressed: bool) -> void:
	if _guest or slot < 0 or slot >= players.size() or phase == "finished":
		return
	var p := players[slot]
	if not p.active or p.bot:
		return
	if DIRS.has(action):
		var bit: int = DIRS[action]
		p.input = int(p.input) | bit if pressed else int(p.input) & ~bit
	elif action == "topple":
		if pressed and not p.down and phase == "running":
			p.queued = true
		p.down = pressed

func take_over(slot: int) -> void:
	if _guest or slot < 0 or slot >= players.size() or not players[slot].active or phase == "finished":
		return
	var p := players[slot]
	p.bot = true
	p.input = 0
	p.down = false
	p.queued = false

func step(delta: float) -> void:
	if _guest or phase == "finished":
		return
	_owed += delta
	while _owed + 0.00000001 >= STEP and phase != "finished":
		_owed -= STEP
		if _count_ticks > 0:
			_count_ticks -= 1
			countdown = _count_ticks * STEP
			if _count_ticks == 0:
				phase = "running"
		else:
			_step_tick()

func _step_tick() -> void:
	var reload := tick == (wave + 1) * WAVE_TICKS
	if reload:
		wave += 1
		_reload()
	var claims: Array[Dictionary] = []
	for p in players:
		if not p.active or not (p.queued or p.bot):
			continue
		var target := action_target(p.slot)
		var age := tick - wave * WAVE_TICKS
		var think := age >= 8 + int(p.bot_offset) % 11
		if p.bot and (not think or (target.kind == "bridge" and alignment(target.index) < _bot_delay(p))):
			continue
		if target.kind == "starter" or target.kind == "bridge":
			target.slot = p.slot
			target.distance = Vector2(p.pos).distance_squared_to(target.at)
			claims.append(target)
		p.queued = false

	tick += 1
	elapsed = tick * STEP
	_resolve(claims)
	for chain in starters:
		_score_fall(chain, STARTER_LENGTH)
	for chain in bridges:
		_score_fall(chain, BRIDGE_LENGTH)

	for p in players:
		if not p.active:
			continue
		var direction := _bot_move(p) if p.bot else _direction(p.input)
		var next := _snap(Vector2(p.pos) + direction * SPEED * STEP)
		next = next.clamp(-FIELD, FIELD)
		p.vel = _snap((next - Vector2(p.pos)) * HZ)
		p.pos = _snap(next)
		if absf(direction.y) > 0.1:
			p.side = 1 if direction.y > 0 else 0
	if tick == ROUND_TICKS:
		phase = "finished"

func _station(order: int, wave_index: int) -> int:
	if _active_count <= 1:
		return 0
	var shift := 0 if _active_count == 2 else wave_index
	if _active_count == 4:
		shift = FOUR_STATION_ROTATION[wave_index]
	return STATIONS[_active_count - 2][posmod(order + _station_offset + shift, _active_count)]

func _reload() -> void:
	starters.clear()
	bridges.clear()
	for p in players:
		p.station = _station(p.order, wave) if p.active else 0
		starters.append({"owner": -1, "start": 0, "side": p.station % 2})
		p.pos = _snap(spawn_pos(p.station))
		p.vel = Vector2.ZERO
		p.side = p.station % 2
		p.queued = false
	for branch in BRANCHES:
		bridges.append({"owner": -1, "start": 0, "side": 0})

func _resolve(claims: Array[Dictionary]) -> void:
	var lead := _priority + wave
	claims.sort_custom(func(a, b):
		if a.distance != b.distance:
			return a.distance < b.distance
		# Equal reach gives the trailing contestant the chance to catch up.
		if players[a.slot].score != players[b.slot].score:
			return players[a.slot].score < players[b.slot].score
		return posmod(players[a.slot].order - lead, _active_count) < posmod(players[b.slot].order - lead, _active_count))
	for claim in claims:
		var chain := starters[claim.index] if claim.kind == "starter" else bridges[claim.index]
		if chain.owner < 0:
			chain.owner = claim.slot
			chain.start = tick
			chain.side = claim.side

func _score_fall(chain: Dictionary, length: int) -> void:
	if chain.owner < 0:
		return
	var age := tick - int(chain.start)
	if age < length * FALL_TICKS and age % FALL_TICKS == 0:
		var p := players[chain.owner]
		p.score += 1
		p.last_point = tick

func _bot_delay(p: Dictionary) -> int:
	return 4 + posmod(int(p.bot_offset) + 3 * wave, 8)

func _bot_move(p: Dictionary) -> Vector2:
	var at: Vector2 = p.pos
	if starters[p.slot].owner < 0:
		return (starter_pos(p.station) - at).limit_length(0.8)
	var best := INF
	var goal := at
	for branch in BRANCHES:
		if bridges[branch].owner >= 0:
			continue
		for side in 2:
			var pad := diamond_pos(branch, side)
			var distance := at.distance_to(pad)
			var arrival := ceili(maxf(0.0, distance - DIAMOND_REACH * 0.8) / (SPEED * STEP * 0.78))
			var before_open := maxi(0, opens_in(branch) - arrival)
			var gate := posmod(maxi(0, tick + arrival - _opening_tick(branch)), PERIOD)
			var delay := _bot_delay(p)
			var wait := posmod(delay - gate, PERIOD) if gate < delay or gate >= OPEN_TICKS else 0
			var cost := float(arrival + before_open + wait) + distance * 0.35
			if cost < best:
				best = cost
				goal = pad
	return (goal - at).limit_length(0.8)

static func _direction(mask: int) -> Vector2:
	return Vector2(int((mask & 8) != 0) - int((mask & 4) != 0),
		int((mask & 2) != 0) - int((mask & 1) != 0)).normalized()

func ranking() -> Array:
	var order := range(players.size()).filter(func(slot): return players[slot].active)
	order.sort_custom(func(a, b):
		return players[a].score > players[b].score if players[a].score != players[b].score else a < b)
	return order

func winners() -> Array:
	var order := ranking()
	return order.filter(func(i): return players[i].score == players[order[0]].score) if not order.is_empty() else []

static func _snap(pos: Vector2) -> Vector2:
	return pos.snapped(Vector2.ONE / POSE_SCALE)

func snapshot() -> Dictionary:
	var rows := PackedByteArray()
	rows.resize(SNAP_BYTES)
	var offset := 0
	for p in players:
		_encode_vector(rows, offset, p.pos)
		_encode_vector(rows, offset + 4, p.vel)
		rows.encode_u16(offset + 8, p.score)
		rows.encode_s16(offset + 10, p.last_point)
		rows.encode_u8(offset + 12, int(p.bot) | (int(p.side) << 1))
		offset += PLAYER_BYTES
	for chain in starters + bridges:
		rows.encode_s8(offset, chain.owner)
		rows.encode_u16(offset + 1, chain.start)
		rows.encode_u8(offset + 3, chain.side)
		offset += CHAIN_BYTES
	return {"id": round_id, "tick": tick, "count": _count_ticks, "state": rows}

func apply_snapshot(data: Dictionary) -> void:
	var rows: Variant = data.get("state")
	var next_tick: Variant = data.get("tick")
	var next_count: Variant = data.get("count")
	var id: Variant = data.get("id")
	if not (rows is PackedByteArray and next_tick is int and next_count is int and id is int):
		return
	if players.size() != SEATS or rows.size() != SNAP_BYTES or next_tick < 0 or next_tick > ROUND_TICKS:
		return
	if next_count < 0 or next_count > roundi(COUNTDOWN * HZ) or (next_count > 0 and next_tick > 0):
		return
	var next_wave := floori(maxi(0, next_tick - 1) / float(WAVE_TICKS))
	var offset := SEATS * PLAYER_BYTES
	for index in SEATS + BRANCHES:
		var owner: int = rows.decode_s8(offset)
		var start: int = rows.decode_u16(offset + 1)
		if owner < -1 or owner >= SEATS or rows.decode_u8(offset + 3) > 1:
			return
		if owner == -1:
			if start != 0:
				return
		elif not players[owner].active or start <= next_wave * WAVE_TICKS or start > next_tick or (index < SEATS and owner != index):
			return
		offset += CHAIN_BYTES
	_guest = true
	round_id = id
	tick = next_tick
	wave = next_wave
	_count_ticks = next_count
	countdown = _count_ticks * STEP
	elapsed = tick * STEP
	phase = "countdown" if _count_ticks > 0 else ("finished" if tick == ROUND_TICKS else "running")
	offset = 0
	for p in players:
		p.station = _station(p.order, wave) if p.active else 0
		p.pos = _decode_vector(rows, offset)
		p.vel = _decode_vector(rows, offset + 4)
		p.score = rows.decode_u16(offset + 8)
		p.last_point = rows.decode_s16(offset + 10)
		var flags: int = rows.decode_u8(offset + 12)
		p.bot = (flags & 1) != 0
		p.side = (flags >> 1) & 1
		offset += PLAYER_BYTES
	for chain in starters + bridges:
		chain.owner = rows.decode_s8(offset)
		chain.start = rows.decode_u16(offset + 1)
		chain.side = rows.decode_u8(offset + 3)
		offset += CHAIN_BYTES

static func _encode_vector(rows: PackedByteArray, offset: int, pos: Vector2) -> void:
	rows.encode_s16(offset, roundi(pos.x * POSE_SCALE))
	rows.encode_s16(offset + 2, roundi(pos.y * POSE_SCALE))

static func _decode_vector(rows: PackedByteArray, offset: int) -> Vector2:
	return Vector2(rows.decode_s16(offset), rows.decode_s16(offset + 2)) / POSE_SCALE
