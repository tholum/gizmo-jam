extends RefCounted
## The host moves all seats, settles taps, then exchanges reciprocal offers.

const SEATS := 6
const HZ := 20
const STEP := 1.0 / HZ
const COUNTDOWN := 3.0
const COUNT_TICKS := 3 * HZ
const BELLS := 7
const BELL_TICKS := 12 * HZ
const ROUND_TICKS := BELLS * BELL_TICKS
const RESERVE_TICK := 7 * HZ
const FIT_TICKS := 2 * HZ
const CUTOFF_TICK := BELL_TICKS - FIT_TICKS
const FLOOR_MIN := Vector2i(104, 224)
const FLOOR_MAX := Vector2i(696, 373)
const MOVE := 13
const DIAGONAL := 9
const TRADE_RANGE := 108
const FIT_RANGE := 21
const PATTERNS := 5
const DIRS := {"up": 1, "down": 2, "left": 4, "right": 8}
const ROW := 14
const SIX_HATS := [0, 1, 1, 2, 2, 0]
const SIX_WANTS := [1, 0, 2, 1, 0, 2]

var players: Array[Dictionary] = []
var phase := "countdown"
var countdown := COUNTDOWN
var elapsed := 0.0
var tick := 0
var bell := 0
var round_id := 0

var _seed := 0
var _count := COUNT_TICKS
var _owed := 0.0
var _guest := false
var _active: Array[int] = []

func begin(seed_value: int, slots: Array, id: int = 1, _endless: bool = false) -> void:
	_seed = seed_value
	round_id = id
	phase = "countdown"
	countdown = COUNTDOWN
	elapsed = 0.0
	tick = 0
	bell = 0
	_count = COUNT_TICKS
	_owed = 0.0
	_guest = false
	_active.clear()
	players.clear()
	for slot in SEATS:
		var seat: Dictionary = slots[slot] if slot < slots.size() else {}
		var active: bool = seat.get("active", not seat.is_empty())
		players.append({
			"slot": slot, "name": seat.get("name", ""), "peer": seat.get("peer", 0),
			"bot": seat.get("bot", false), "active": active, "score": 0, "last_points": 0,
			"hat": 0, "want": 0, "pos": Vector2i.ZERO, "spot": Vector2i.ZERO,
			"target": -1, "offer": -1, "fit_started": -1, "traded": false,
			"trade_tick": -1, "trade_partner": -1, "trade_paid": false, "dirs": 0, "held": false, "tap": false,
			"bot_offer_tick": -1, "bot_avoids": -1, "bot_avoid_until": -1,
		})
		if active:
			_active.append(slot)
	for order in _active.size():
		var p := players[_active[order]]
		p.spot = Vector2i(400 + (2 * order - _active.size() + 1) * 30, FLOOR_MIN.y)
	_start_bell()

func _start_bell() -> void:
	for order in _active.size():
		var p := players[_active[order]]
		p.pos = Vector2i(400 + (2 * order - _active.size() + 1) * 45, 287 + (order % 2) * 47)
		var hats := _deal(order, bell)
		p.hat = hats.x
		p.want = hats.y
		p.target = -1
		p.offer = -1
		p.fit_started = -1
		p.traded = false
		p.tap = false
		p.trade_tick = -1
		p.trade_paid = false
		p.bot_offer_tick = -1
		p.bot_avoids = -1
		p.bot_avoid_until = -1
		p.trade_partner = -1
	_refresh_targets()

func _deal(order: int, index: int) -> Vector2i:
	var size := _active.size()
	var role := posmod(order - _seed - index, size)
	var hat := role
	var want := role + 1
	match size:
		2:
			# Four mutual bells, with the three lopsided ones alternating leverage.
			if index % 2 == 0:
				want = 1 - role
			else:
				role = posmod(order - _seed - (index >> 1), size)
				hat = role
				want = 1 if role == 0 else 2
		3:
			# The three odd bells each put a different adjacent pair in a mutual deal.
			want = (role + 1) % size
			if index % 2 == 1 and role == 1:
				want = 0
		4:
			want = role ^ 1 if index % 2 == 0 else (role + 1) % size
		5:
			want = (role + 1 + (index % 2)) % size
		6:
			hat = SIX_HATS[role]
			want = SIX_WANTS[role]
	var pattern := posmod(_seed + 2 * index, PATTERNS)
	return Vector2i((hat + pattern) % PATTERNS, (want + pattern) % PATTERNS)

func remaining() -> float:
	return (ROUND_TICKS - tick) * STEP

func bell_age() -> int:
	return tick - bell * BELL_TICKS

func reserve_open() -> bool:
	return phase == "running" and _reserve_at(bell_age() + 1)

func can_fit(p: Dictionary) -> bool:
	return reserve_open() and _on_spot(p)

func _reserve_at(age: int) -> bool:
	return age >= RESERVE_TICK and age <= CUTOFF_TICK

func _on_spot(p: Dictionary) -> bool:
	return p.active and p.fit_started < 0 and p.pos.distance_squared_to(p.spot) <= FIT_RANGE * FIT_RANGE

func _in_range(p: Dictionary, q: Dictionary) -> bool:
	return p.active and q.active and p.slot != q.slot and p.fit_started < 0 and q.fit_started < 0 and (
		p.pos.distance_squared_to(q.pos) <= TRADE_RANGE * TRADE_RANGE)

func can_trade(p: Dictionary, partner: int) -> bool:
	if partner < 0 or partner >= SEATS:
		return false
	var q := players[partner]
	return _in_range(p, q) and p.hat != q.hat

func command(slot: int, action: String, pressed: bool) -> void:
	if _guest or slot < 0 or slot >= SEATS or phase == "finished":
		return
	var p := players[slot]
	if not p.active or p.bot:
		return
	if action == "tap":
		if pressed and not p.held and phase == "running":
			p.tap = not p.tap
		p.held = pressed
	elif DIRS.has(action):
		var bit: int = DIRS[action]
		p.dirs = int(p.dirs) | bit if pressed else int(p.dirs) & ~bit

func take_over(slot: int) -> void:
	if _guest or slot < 0 or slot >= SEATS or not players[slot].active or phase == "finished":
		return
	var p := players[slot]
	p.bot = true
	p.held = false
	p.tap = false
	p.dirs = 0
	p.offer = -1

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
	for slot in _active:
		var p := players[slot]
		if p.fit_started >= 0 and tick == p.fit_started + FIT_TICKS:
			p.hat = p.want
	if bell_age() == BELL_TICKS:
		_ring()
		return
	for slot in _active:
		if players[slot].bot:
			_think(players[slot])
	for slot in _active:
		var p := players[slot]
		if p.fit_started < 0:
			_move(p)
	var cancelling := 0
	for slot in _active:
		if players[slot].tap and players[slot].offer >= 0:
			cancelling |= 1 << slot
	_refresh_targets()
	# Accept a visible offer first. Otherwise a tap on an open spot claims the fitting.
	var fitting := 0
	for slot in _active:
		var p := players[slot]
		if p.tap and not (cancelling & (1 << slot)) and _reserve_at(bell_age()) and _on_spot(p) and not _reciprocating(p):
			fitting |= 1 << slot
	for slot in _active:
		var p := players[slot]
		if not p.tap:
			continue
		p.tap = false
		if cancelling & (1 << slot):
			p.offer = -1
		elif fitting & (1 << slot):
			p.pos = p.spot
			p.fit_started = tick
		elif can_trade(p, p.target):
			p.offer = p.target
			p.bot_offer_tick = tick
	_refresh_targets()
	for slot in _active:
		var p := players[slot]
		var partner: int = p.offer
		if partner > slot and players[partner].offer == slot:
			_exchange(p, players[partner])
	_refresh_targets()

func _reciprocating(p: Dictionary) -> bool:
	if not can_trade(p, p.target):
		return false
	var q := players[p.target]
	return q.offer == p.slot and not q.tap

func _move(p: Dictionary) -> void:
	var bits: int = p.dirs
	var x := int(bool(bits & 8)) - int(bool(bits & 4))
	var y := int(bool(bits & 2)) - int(bool(bits & 1))
	var speed := DIAGONAL if x and y else MOVE
	p.pos = (p.pos + Vector2i(x, y) * speed).clamp(FLOOR_MIN, FLOOR_MAX)

func _refresh_targets() -> void:
	for slot in _active:
		var p := players[slot]
		if p.offer >= 0 and not can_trade(p, p.offer):
			p.offer = -1
		if p.offer >= 0:
			p.target = p.offer
			continue
		var previous: int = p.target
		var closest := TRADE_RANGE * TRADE_RANGE
		var target := -1
		for other in _active:
			var q := players[other]
			if not _in_range(p, q):
				continue
			var distance: int = p.pos.distance_squared_to(q.pos)
			if distance < closest or (distance == closest and (target < 0 or other == previous)):
				closest = distance
				target = other
		p.target = target

func _exchange(p: Dictionary, q: Dictionary) -> void:
	var old: int = p.hat
	p.hat = q.hat
	q.hat = old
	for seat in [p, q]:
		seat.offer = -1
		seat.trade_tick = tick
		seat.trade_partner = q.slot if seat == p else p.slot
		seat.trade_paid = not seat.traded
		if seat.trade_paid:
			seat.traded = true
			seat.score += 1

func _ring() -> void:
	for slot in _active:
		var p := players[slot]
		var points := 2 * int(p.hat == p.want)
		p.score += points
		p.last_points = points
		p.offer = -1
		p.tap = false
	if tick == ROUND_TICKS:
		phase = "finished"
		_refresh_targets()
	else:
		bell += 1
		_start_bell()

func _think(p: Dictionary) -> void:
	p.dirs = 0
	if p.fit_started >= 0:
		return
	var age := bell_age()
	if (not p.traded or p.hat != p.want) and age >= RESERVE_TICK + 6 + 2 * (p.slot % 3) and age <= CUTOFF_TICK:
		p.offer = -1
		_steer(p, p.spot)
		p.tap = _on_spot(p)
		return
	if p.offer >= 0 and tick - p.bot_offer_tick >= 25:
		p.bot_avoids = p.offer
		p.bot_avoid_until = tick + 19
		p.offer = -1
	if p.offer >= 0 or age < 7 + 4 * p.slot or (p.traded and p.hat == p.want):
		return
	var goal := -1
	var best := -1000000
	for slot in _active:
		var q := players[slot]
		if slot == p.slot or q.fit_started >= 0 or p.hat == q.hat:
			continue
		if (p.traded and p.want != q.hat) or (slot == p.bot_avoids and tick < p.bot_avoid_until and q.offer != p.slot):
			continue
		var priority := int(p.want == q.hat) * 1000000 + int(q.want == p.hat) * 550000
		priority += int(q.offer == p.slot) * 1600000
		priority -= p.pos.distance_squared_to(q.pos)
		if priority > best:
			goal = slot
			best = priority
	if goal < 0:
		return
	var q := players[goal]
	if p.target == goal and can_trade(p, goal):
		p.tap = true
	else:
		_steer(p, q.pos)

func _steer(p: Dictionary, goal: Vector2i) -> void:
	var delta: Vector2i = goal - p.pos
	if absi(delta.x) >= DIAGONAL:
		p.dirs |= 4 if delta.x < 0 else 8
	if absi(delta.y) >= DIAGONAL:
		p.dirs |= 1 if delta.y < 0 else 2

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
	rows.resize(ROW * SEATS)
	for p in players:
		var at: int = p.slot * ROW
		rows.encode_u16(at, p.pos.x)
		rows.encode_u16(at + 2, p.pos.y)
		rows.encode_u8(at + 4, p.score)
		rows.encode_u8(at + 5, p.hat)
		rows.encode_s8(at + 6, p.target)
		rows.encode_s8(at + 7, p.offer)
		rows.encode_s16(at + 8, p.fit_started)
		rows.encode_s16(at + 10, p.trade_tick)
		rows.encode_s8(at + 12, p.trade_partner)
		rows.encode_u8(at + 13, int(p.traded) | (int(p.bot) << 1) | (int(p.trade_paid) << 2) | (int(p.last_points) << 3))
	return {"id": round_id, "tick": tick, "count": _count, "state": rows}

func apply_snapshot(data: Dictionary) -> void:
	var rows: Variant = data.get("state")
	var next_tick: Variant = data.get("tick")
	var next_count: Variant = data.get("count")
	if not (rows is PackedByteArray and next_tick is int and next_count is int and data.get("id") is int):
		return
	if players.size() != SEATS or rows.size() != ROW * SEATS or next_tick < 0 or next_tick > ROUND_TICKS:
		return
	if next_count < 0 or next_count > COUNT_TICKS or (next_count > 0 and next_tick > 0):
		return
	var next_bell := mini(BELLS - 1, floori(float(next_tick) / BELL_TICKS))
	var start := next_bell * BELL_TICKS
	var decoded: Array[Dictionary] = []
	for p in players:
		var at: int = p.slot * ROW
		var pos := Vector2i(rows.decode_u16(at), rows.decode_u16(at + 2))
		var score: int = rows.decode_u8(at + 4)
		var hat: int = rows.decode_u8(at + 5)
		var target: int = rows.decode_s8(at + 6)
		var offer: int = rows.decode_s8(at + 7)
		var fit: int = rows.decode_s16(at + 8)
		var trade: int = rows.decode_s16(at + 10)
		var partner: int = rows.decode_s8(at + 12)
		var flags: int = rows.decode_u8(at + 13)
		var last := flags >> 3
		if score > BELLS * 3 or hat >= PATTERNS or last not in [0, 2] or last > score:
			return
		if not _valid_peer(p.slot, target) or not _valid_peer(p.slot, offer) or not _valid_peer(p.slot, partner):
			return
		if offer >= 0 and offer != target:
			return
		if fit != -1 and (fit < start + RESERVE_TICK or fit > mini(next_tick, start + CUTOFF_TICK) or pos != p.spot):
			return
		if trade != -1 and (trade <= start or trade >= start + BELL_TICKS or trade > next_tick):
			return
		if bool(flags & 1) != (trade >= 0) or (partner >= 0) != (trade >= 0) or (flags & 4 and not flags & 1):
			return
		if p.active:
			if pos != pos.clamp(FLOOR_MIN, FLOOR_MAX):
				return
		elif pos != Vector2i.ZERO or score != 0 or hat != 0 or target >= 0 or offer >= 0 or fit >= 0 or partner >= 0:
			return
		decoded.append({"pos": pos, "score": score, "hat": hat, "target": target, "offer": offer,
			"fit_started": fit, "trade_tick": trade, "trade_partner": partner,
			"traded": bool(flags & 1), "bot": bool(flags & 2), "trade_paid": bool(flags & 4), "last_points": last})

	_guest = true
	round_id = data.id
	tick = next_tick
	bell = next_bell
	_count = next_count
	countdown = _count * STEP
	elapsed = tick * STEP
	phase = "countdown" if _count > 0 else ("finished" if tick == ROUND_TICKS else "running")
	for p in players:
		p.merge(decoded[p.slot], true)
	for order in _active.size():
		players[_active[order]].want = _deal(order, bell).y

func _valid_peer(slot: int, peer: int) -> bool:
	return peer == -1 or (peer >= 0 and peer < SEATS and peer != slot and players[peer].active)
