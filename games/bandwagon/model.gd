extends RefCounted
## Independent hitches and integer movement. The host updates every seat before
## tallying the turnout, then keeps one sealed result through the crossing.

const SEATS := 6
const HZ := 20
const STEP := 1.0 / HZ
const COUNTDOWN := 3.0
const COUNT_TICKS := 3 * HZ
const FORKS := 6
const FORK_TICKS := 15 * HZ
const LOCK_TICK := FORK_TICKS - 30
const BOOTH_CLOSE_TICK := LOCK_TICK - 3 * HZ
const CROSS_TICK := FORK_TICKS - 8
const ROUND_TICKS := FORKS * FORK_TICKS
const MOVE := 16
const DIAGONAL := 11
const HITCH_Y := 226
const HITCH_RANGE := Vector2i(21, 21)
const START_Y := 282
const BOOTH_Y := 272
const BOOTH_RANGE := Vector2i(35, 22)
const FLOOR_MIN := Vector2i(88, HITCH_Y)
const FLOOR_MAX := Vector2i(712, 316)
const DIRS := {"up": 1, "down": 2, "left": 4, "right": 8}
const PLAYER_BYTES := 8
const SNAP_BYTES := 3 + PLAYER_BYTES * SEATS
const ODD_TIE_CRESTS := {3: [[1], [0], [0], [2], [2], [1]],
	5: [[1, 2], [0, 2], [0, 4], [1, 2], [1, 3], [3, 4]]}
const BOOTHS := { -1: Vector2i(138, BOOTH_Y), 1: Vector2i(662, BOOTH_Y) }

var players: Array[Dictionary] = []
var phase := "countdown"
var countdown := COUNTDOWN
var elapsed := 0.0
var tick := 0
var fork := 0
var round_id := 0
var tiebreak := -1
var locked_route := 0
var locked_riders := 0
var locked_bonus := 0
var left_pulls := 0
var right_pulls := 0

var _seed := 0
var _count := COUNT_TICKS
var _owed := 0.0
var _guest := false
var _active_count := 0
var _active_mask := 0

func begin(seed_value: int, slots: Array, id: int = 1, _endless: bool = false) -> void:
	_seed = seed_value
	round_id = id
	phase = "countdown"
	countdown = COUNTDOWN
	elapsed = 0.0
	tick = 0
	fork = 0
	_count = COUNT_TICKS
	_owed = 0.0
	_guest = false
	_active_count = 0
	_active_mask = 0
	players.clear()
	for slot in SEATS:
		var seat: Dictionary = slots[slot] if slot < slots.size() else {}
		var active: bool = seat.get("active", not seat.is_empty())
		players.append({
			"slot": slot, "name": seat.get("name", ""), "peer": seat.get("peer", 0),
			"bot": seat.get("bot", false), "active": active, "order": _active_count if active else -1,
			"score": 0, "last_points": 0, "hitch": Vector2i.ZERO, "pos": Vector2i.ZERO,
			"crest": 0, "riding": false, "pull": 0, "dirs": 0, "hold": false, "bot_booth": 0,
		})
		if active:
			_active_mask |= 1 << slot
			_active_count += 1
	_start_fork()

func _start_fork() -> void:
	tiebreak = _fork_tiebreak(fork)
	locked_route = 0
	locked_riders = 0
	locked_bonus = 0
	left_pulls = 0
	right_pulls = 0
	for p in players:
		if not p.active:
			continue
		p.hitch = Vector2i(400 + (2 * int(p.order) - _active_count + 1) * 28, HITCH_Y)
		p.pos = Vector2i(p.hitch.x, START_Y)
		p.crest = _starting_crest(p.order)
		p.riding = false
		p.pull = 0
		p.bot_booth = 0

func _fork_tiebreak(index: int) -> int:
	return -1 if posmod(_seed + index, 2) == 0 else 1

func _starting_crest(order: int) -> int:
	# Swap the pair on every other fork so alternating ties favor each seat
	# three times in a two-player match. In odd crews the blank walks one seat.
	var index := posmod(order - posmod(_seed, _active_count), _active_count)
	if _active_count % 2:
		if index == fork % _active_count:
			return 0
		return tiebreak if index in ODD_TIE_CRESTS[_active_count][fork] else -tiebreak
	return -1 if posmod(index - fork / 2, 2) == 0 else 1

func remaining() -> float:
	return (ROUND_TICKS - tick) * STEP

func fork_age() -> int:
	return tick - fork * FORK_TICKS

func booths_open() -> bool:
	return fork_age() < BOOTH_CLOSE_TICK

func lead_route() -> int:
	if locked_route != 0:
		return locked_route
	if left_pulls == right_pulls:
		return tiebreak
	return -1 if left_pulls > right_pulls else 1

static func inside(pos: Vector2i, center: Vector2i, reach: Vector2i) -> bool:
	var distance := (pos - center).abs()
	return distance.x <= reach.x and distance.y <= reach.y

func command(slot: int, action: String, pressed: bool) -> void:
	if _guest or slot < 0 or slot >= SEATS or phase == "finished":
		return
	var p := players[slot]
	if not p.active or p.bot:
		return
	if action == "hold":
		p.hold = pressed
	elif DIRS.has(action):
		var bit: int = DIRS[action]
		p.dirs = int(p.dirs) | bit if pressed else int(p.dirs) & ~bit

func take_over(slot: int) -> void:
	if _guest or slot < 0 or slot >= SEATS or not players[slot].active or phase == "finished":
		return
	var p := players[slot]
	p.bot = true
	p.hold = false
	p.dirs = 0

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
	tick += 1
	elapsed = tick * STEP
	var age := fork_age()
	if age <= LOCK_TICK:
		# Bots inspect the preceding tally. Their decisions and all seat motion
		# are in before the new tally is computed.
		for p in players:
			if p.active:
				if p.bot:
					_think(p, age)
				_move(p, age < BOOTH_CLOSE_TICK)
		_tally()
		if age == LOCK_TICK:
			_seal()
	elif age == CROSS_TICK:
		for p in players:
			var seat_bit := 1 << int(p.slot)
			p.last_points = int(bool(locked_riders & seat_bit)) + int(bool(locked_bonus & seat_bit))
			p.score += p.last_points
	elif age == FORK_TICKS:
		if tick == ROUND_TICKS:
			phase = "finished"
		else:
			fork += 1
			_start_fork()

func _move(p: Dictionary, booths_available: bool) -> void:
	var bits: int = p.dirs
	var x := int(bool(bits & 8)) - int(bool(bits & 4))
	var y := int(bool(bits & 2)) - int(bool(bits & 1))
	if p.riding and p.hold:
		p.pull = x
		return
	var speed := DIAGONAL if x and y else MOVE
	p.riding = false
	p.pull = 0
	p.pos = (p.pos + Vector2i(x, y) * speed).clamp(FLOOR_MIN, FLOOR_MAX)
	if p.hold and inside(p.pos, p.hitch, HITCH_RANGE):
		p.riding = true
		p.pos = p.hitch
		p.pull = x
	elif booths_available:
		for route in BOOTHS:
			if inside(p.pos, BOOTHS[route], BOOTH_RANGE):
				p.crest = route

func _tally() -> void:
	left_pulls = 0
	right_pulls = 0
	for p in players:
		if p.riding:
			left_pulls += int(p.pull == -1)
			right_pulls += int(p.pull == 1)

func _seal() -> void:
	locked_route = lead_route()
	for p in players:
		if p.riding:
			var seat_bit := 1 << int(p.slot)
			locked_riders |= seat_bit
			if p.crest == locked_route:
				locked_bonus |= seat_bit

func _think(p: Dictionary, age: int) -> void:
	# A booth trip is public and committed once started. Some bots ride for a
	# point while others deliberately switch to the currently leading crest.
	var switch_at := 62 + posmod(int(p.order) * 13 + fork * 5, 34)
	var lead := lead_route()
	if age == switch_at and p.riding and p.crest != lead and (int(p.order) + fork) % 3 != 0:
		p.bot_booth = lead
	if p.bot_booth != 0 and p.crest == p.bot_booth:
		p.bot_booth = 0
	p.hold = p.bot_booth == 0
	if p.riding and p.hold:
		p.dirs = 0 if (int(p.order) + fork) % 5 == 0 else (4 if p.crest == -1 else (8 if p.crest == 1 else 0))
		return
	var target: Vector2i = p.hitch if p.hold else BOOTHS[p.bot_booth]
	var offset: Vector2i = target - p.pos
	p.dirs = 0
	if absi(offset.x) > DIAGONAL / 2:
		p.dirs |= 4 if offset.x < 0 else 8
	if absi(offset.y) > DIAGONAL / 2:
		p.dirs |= 1 if offset.y < 0 else 2

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
	rows.encode_s8(0, locked_route)
	rows.encode_u8(1, locked_riders)
	rows.encode_u8(2, locked_bonus)
	var at := 3
	for p in players:
		rows.encode_u16(at, p.pos.x)
		rows.encode_u16(at + 2, p.pos.y)
		rows.encode_u8(at + 4, p.score)
		rows.encode_s8(at + 5, p.crest)
		rows.encode_s8(at + 6, p.pull)
		rows.encode_u8(at + 7, int(p.riding) | (int(p.bot) << 1) | (int(p.last_points) << 2))
		at += PLAYER_BYTES
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
	var next_fork := mini(FORKS - 1, int(next_tick) / FORK_TICKS)
	var age: int = next_tick - next_fork * FORK_TICKS
	var route: int = rows.decode_s8(0)
	var riders: int = rows.decode_u8(1)
	var bonus: int = rows.decode_u8(2)
	if absi(route) > 1 or (age >= LOCK_TICK) != (route != 0):
		return
	if riders & ~_active_mask or bonus & ~riders or (route == 0 and riders != 0):
		return
	var observed_riders := 0
	var observed_bonus := 0
	var pulls := 0
	var at := 3
	for p in players:
		var pos := Vector2i(rows.decode_u16(at), rows.decode_u16(at + 2))
		var score: int = rows.decode_u8(at + 4)
		var crest: int = rows.decode_s8(at + 5)
		var pull: int = rows.decode_s8(at + 6)
		var flags: int = rows.decode_u8(at + 7)
		var last := flags >> 2
		var riding := bool(flags & 1)
		if score > FORKS * 2 or last > 2 or last > score or absi(crest) > 1 or absi(pull) > 1 or (pull != 0 and not riding):
			return
		if p.active:
			if pos != pos.clamp(FLOOR_MIN, FLOOR_MAX) or (riding and pos != p.hitch):
				return
		elif riding or pos != Vector2i.ZERO or score != 0 or crest != 0:
			return
		if riding:
			var seat_bit := 1 << int(p.slot)
			observed_riders |= seat_bit
			pulls += pull
			if crest == route:
				observed_bonus |= seat_bit
		if age >= CROSS_TICK:
			var seat_bit := 1 << int(p.slot)
			if last != int(bool(riders & seat_bit)) + int(bool(bonus & seat_bit)):
				return
		at += PLAYER_BYTES
	if route != 0 and (riders != observed_riders or bonus != observed_bonus or
			route != (_fork_tiebreak(next_fork) if pulls == 0 else signi(pulls))):
		return

	_guest = true
	round_id = data.id
	tick = next_tick
	fork = next_fork
	tiebreak = _fork_tiebreak(fork)
	_count = next_count
	countdown = _count * STEP
	elapsed = tick * STEP
	phase = "countdown" if _count > 0 else ("finished" if tick == ROUND_TICKS else "running")
	locked_route = route
	locked_riders = riders
	locked_bonus = bonus
	at = 3
	for p in players:
		p.pos = Vector2i(rows.decode_u16(at), rows.decode_u16(at + 2))
		p.score = rows.decode_u8(at + 4)
		p.crest = rows.decode_s8(at + 5)
		p.pull = rows.decode_s8(at + 6)
		var flags: int = rows.decode_u8(at + 7)
		p.riding = bool(flags & 1)
		p.bot = bool(flags & 2)
		p.last_points = flags >> 2
		at += PLAYER_BYTES
	_tally()
