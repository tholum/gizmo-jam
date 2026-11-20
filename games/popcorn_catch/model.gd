extends RefCounted
## Fixed-step, host-authoritative Popcorn Catch rules.
const SEATS := 6
const HZ := 60
const STEP := 1.0 / HZ
const COUNTDOWN := 3.0
const ROUND_TIME := 90
const ROUND_TICKS := ROUND_TIME * HZ
const FIELD_RADIUS := 11.35
const SHELF_DISTANCE := 9.90
const SHELF_RADIUS := 1.42
const CATCH_RADIUS := 1.04
const BIG_BANK := 4
const BANK_BONUS := 2
const WOBBLE := 5
const LAST_SERVE := 86 * HZ
const SPEED := 8.4
const ACCEL := 84.0
const BRAKE := 108.0
const NO_TICK := -600
const MARK_TIME := 29
const MAX_DROPS := 32
const PLAYER_ROW := 18
const DROP_ROW := 11
const SCALE := 512.0
const TIE_DISTANCE_SQ := 0.00001
const DIRS := {"up": 1, "down": 2, "left": 4, "right": 8}
const MOVE_MASKS := [8, 10, 2, 6, 4, 5, 1, 9]

var players: Array[Dictionary] = []
var drops: Array[Dictionary] = []
var phase := "countdown"
var countdown := COUNTDOWN
var elapsed := 0.0
var tick := 0
var round_id := 0
var burst_tick := NO_TICK

var _rng := RandomNumberGenerator.new()
var _shelves: Array[Vector2] = []
var _occupied: Array[int] = []
var _count_ticks := int(COUNTDOWN * HZ)
var _owed := 0.0
var _next_wave := 1
var _wave := 0
var _shared_round := 0
var _next_drop := 0
var _tie_priority := 0

static func shelf(slot: int) -> Vector2:
	return Vector2.from_angle(-PI * 0.5 + TAU * slot / SEATS) * SHELF_DISTANCE

static func direction(mask: int) -> Vector2:
	return Vector2(int((mask & 8) != 0) - int((mask & 4) != 0),
		int((mask & 2) != 0) - int((mask & 1) != 0)).normalized()

static func movement_mask(want: Vector2) -> int:
	if want.length_squared() < 0.14 ** 2:
		return 0
	return MOVE_MASKS[posmod(roundi(want.angle() / (PI * 0.25)), 8)]

func begin(seed_value: int, slots: Array, id: int = 1, _endless: bool = false) -> void:
	_rng.seed = seed_value
	round_id = id
	phase = "countdown"
	countdown = COUNTDOWN
	elapsed = 0.0
	tick = 0
	burst_tick = NO_TICK
	_count_ticks = int(COUNTDOWN * HZ)
	_owed = 0.0
	_next_wave = 1
	_wave = 0
	_shared_round = 0
	_next_drop = 0
	_tie_priority = _rng.randi_range(0, SEATS - 1)
	players.clear()
	drops.clear()
	_shelves.clear()
	_occupied.clear()
	for slot in SEATS:
		var seat: Dictionary = slots[slot]
		var occupied: bool = seat.get("active", true)
		_shelves.append(shelf(slot))
		if occupied:
			_occupied.append(slot)
		players.append({
			"name": seat.name, "peer": seat.peer, "bot": seat.bot, "slot": slot, "active": occupied,
			"pos": _shelves[slot].normalized() * 6.0, "vel": Vector2.ZERO, "input": 0,
			"score": 0, "carry": 0, "caught": 0, "lost": 0, "big_banks": 0,
			"last_catch": NO_TICK, "last_bank": NO_TICK, "last_spill": NO_TICK, "bank_points": 0,
			"bank_shelf": -1, "in_shelf": -1, "spilled": 0,
			"replan": 0, "goal": Vector2.ZERO,
		})
	if not _occupied.is_empty():
		_shared_round = _rng.randi_range(0, _occupied.size() - 1)

func remaining() -> float:
	return maxf(0.0, ROUND_TIME - elapsed)

func command(slot: int, action: String, pressed: bool) -> void:
	if phase == "finished" or slot < 0 or slot >= players.size() or not DIRS.has(action):
		return
	var player := players[slot]
	if not player.active or player.bot:
		return
	var bit: int = DIRS[action]
	player.input = int(player.input) | bit if pressed else int(player.input) & ~bit

func take_over(slot: int) -> void:
	if slot >= 0 and slot < players.size() and players[slot].active:
		var player := players[slot]
		player.bot = true
		player.input = 0
		player.replan = tick

func step(delta: float) -> void:
	if phase == "finished":
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
			_tick()

func _tick() -> void:
	tick += 1
	elapsed = tick * STEP
	_schedule()
	for slot in _occupied:
		var player := players[slot]
		_move(player, _bot_move(player) if player.bot else direction(player.input))
	for drop in drops:
		if drop.land == tick:
			_touchdown(drop)
	while not drops.is_empty() and drops[0].land + MARK_TIME < tick:
		drops.pop_front()
	if tick >= ROUND_TICKS:
		phase = "finished"

func _move(player: Dictionary, want: Vector2) -> void:
	var velocity: Vector2 = player.vel
	velocity = velocity.move_toward(want * SPEED, (BRAKE if want == Vector2.ZERO else ACCEL) * STEP)
	player.pos = (Vector2(player.pos) + velocity * STEP).limit_length(FIELD_RADIUS)
	player.vel = velocity
	var at := _shelf_at(player.pos)
	if at >= 0 and at != int(player.in_shelf) and player.carry > 0:
		_bank(player, at)
	player.in_shelf = at

func _shelf_at(pos: Vector2) -> int:
	if pos.length_squared() < (SHELF_DISTANCE - SHELF_RADIUS) ** 2:
		return -1
	for slot in SEATS:
		if pos.distance_squared_to(_shelves[slot]) <= SHELF_RADIUS ** 2:
			return slot
	return -1

func _bank(player: Dictionary, at: int) -> void:
	var count: int = player.carry
	if count >= BIG_BANK:
		count += BANK_BONUS
		player.big_banks += 1
	player.score += count
	player.bank_points = count
	player.bank_shelf = at
	player.last_bank = tick
	player.carry = 0

func _touchdown(drop: Dictionary) -> void:
	var distance := CATCH_RADIUS ** 2 + TIE_DISTANCE_SQ
	for slot in _occupied:
		var squared: float = drop.pos.distance_squared_to(players[slot].pos)
		if squared <= CATCH_RADIUS ** 2:
			distance = minf(distance, squared)
	var winner := -1
	var ties := 0
	for offset in SEATS:
		var slot := (_tie_priority + offset) % SEATS
		var player := players[slot]
		if not player.active:
			continue
		var squared: float = drop.pos.distance_squared_to(player.pos)
		if squared > CATCH_RADIUS ** 2 or squared - distance > TIE_DISTANCE_SQ:
			continue
		ties += 1
		if winner < 0:
			winner = slot
	drop.winner = winner
	if winner < 0:
		return
	if ties > 1:
		_tie_priority = (winner + 1) % SEATS
	var player := players[winner]
	if player.carry >= WOBBLE:
		var lost := ceili(int(player.carry) * 0.5)
		player.carry -= lost
		player.lost += lost
		player.spilled = lost
		player.last_spill = tick
	player.carry += 1
	player.caught += 1
	player.last_catch = tick

func _schedule() -> void:
	if tick == LAST_SERVE:
		_lane_wave(true)
		return
	if tick < _next_wave or tick >= LAST_SERVE - 111:
		return
	var opening := tick < 13 * HZ
	var late := tick >= 52 * HZ
	var pattern := (_wave % 4) if late else (_wave % 5)
	if not opening and pattern == (0 if late else 3):
		_center_wave(late)
	elif not opening and pattern == (2 if late else 1):
		_shared_wave()
	else:
		_lane_wave(opening)
	_wave += 1
	_next_wave += 106 if opening else (123 if late else 127)

func _lane_wave(opening: bool) -> void:
	var lean := _rng.randf_range(0.13, 0.32) * (1.0 if _wave % 2 == 0 else -1.0)
	var depth := _rng.randf_range(6.9, 7.45) if opening or _wave % 3 == 1 else _rng.randf_range(5.0, 6.0)
	for slot in _occupied:
		var lane: Vector2 = _shelves[slot].normalized()
		_add_drop(lane.rotated(lean) * depth, 89 + 6 * (_wave % 3), false)

func _shared_wave() -> void:
	# Alternate the pairing among occupied seats. A two-player lineup always shares one target.
	var count := _occupied.size()
	if count < 2:
		_lane_wave(false)
		return
	var offset := _shared_round % count
	_shared_round += 1
	for i in range(0, count - 1, 2):
		var a: Vector2 = _shelves[_occupied[(offset + i) % count]]
		var b: Vector2 = _shelves[_occupied[(offset + i + 1) % count]]
		var mid := a.lerp(b, 0.5) * 0.64
		var bend := -mid.normalized() if mid.length() > 0.02 else a.orthogonal().normalized()
		var at := mid + bend * _rng.randf_range(-0.42, 0.42)
		var stagger := 117 + (i / 2) * 3
		_add_drop(at, stagger, false)
		# Two landings per pair reward a player who stays, and let a rival contest the second.
		_add_drop(at + bend * 2.22, stagger + 34, false)
	if count % 2 == 1:
		var spare: Vector2 = _shelves[_occupied[(offset + count - 1) % count]]
		_add_drop(spare * 0.57, 124, false)

func _center_wave(late: bool) -> void:
	burst_tick = tick
	var sites := clampi(_occupied.size() + 1, 2, 5) if late else clampi(_occupied.size(), 2, 4)
	var turn := _rng.randf_range(0.0, TAU)
	for i in sites:
		var at := Vector2.from_angle(turn + TAU * i / sites) * (2.2 if late else 1.6)
		_add_drop(at, 141 + 11 * i, true)

func _add_drop(pos: Vector2, travel: int, center: bool) -> void:
	var land := tick + travel
	if land > ROUND_TICKS:
		return
	_next_drop += 1
	drops.append({"id": _next_drop, "pos": pos, "born": tick, "land": land, "center": center, "winner": -1})
	# Keep touchdown order stable even when forecasts overlap one another.
	drops.sort_custom(func(a, b): return a.land < b.land or (a.land == b.land and a.id < b.id))

func nearest_shelf(pos: Vector2) -> Vector2:
	var nearest := _shelves[0]
	for at in _shelves:
		if pos.distance_squared_to(at) < pos.distance_squared_to(nearest):
			nearest = at
	return nearest

func _bot_move(player: Dictionary) -> Vector2:
	var pos: Vector2 = player.pos
	var velocity: Vector2 = player.vel
	if tick >= player.replan:
		var slot: int = player.slot
		player.replan = tick + 13 + slot % 3
		var shelf_goal := nearest_shelf(pos)
		var home := _shelves[slot].normalized()
		var target := home * 6.05
		var bank_at := 3 if (int(player.caught) + slot) % 3 != 0 else BIG_BANK
		if player.carry >= bank_at or (player.carry > 0 and remaining() < pos.distance_to(shelf_goal) / SPEED + 0.8):
			target = shelf_goal
		else:
			var best := INF
			for drop in drops:
				if tick - int(drop.born) < 33 + slot % 3 * 6 or drop.land <= tick:
					continue
				var dist: float = pos.distance_to(drop.pos)
				var seconds := (int(drop.land) - tick) * STEP
				if dist > seconds * SPEED * 0.88 + 0.55:
					continue
				var lane_alignment := home.dot(Vector2(drop.pos).normalized())
				var away_cost := (1.0 - lane_alignment) * 3.6 if not drop.center else 2.0
				var cost := dist + seconds * 1.25 + away_cost
				for other_slot in _occupied:
					if other_slot == slot:
						continue
					var other: Dictionary = players[other_slot]
					if Vector2(other.pos).distance_to(drop.pos) + 1.05 < dist:
						cost += 1.65
				if cost < best:
					best = cost
					target = drop.pos
			if is_inf(best) and player.carry > 0 and (tick - int(player.last_catch) >= 125 or remaining() < 3.5):
				target = shelf_goal
		player.goal = target
	var offset: Vector2 = player.goal - pos - velocity * 0.046
	return direction(movement_mask(offset))

func ranking() -> Array:
	var order: Array = _occupied.duplicate()
	order.sort_custom(func(a, b):
		return players[a].score > players[b].score if players[a].score != players[b].score else a < b)
	return order

func winners() -> Array:
	var order := ranking()
	if order.is_empty():
		return []
	return order.filter(func(slot): return players[slot].score == players[order[0]].score)

func snapshot() -> Dictionary:
	# Six fixed player records and only the live/recent targets, well below ENet's MTU.
	var rows := PackedByteArray()
	rows.resize(SEATS * PLAYER_ROW + drops.size() * DROP_ROW)
	for i in SEATS:
		var player := players[i]
		var o := i * PLAYER_ROW
		_encode_pos(rows, o, player.pos)
		rows.encode_u16(o + 4, player.score)
		rows.encode_u8(o + 6, int(player.carry) | (int(player.bot) << 3))
		rows.encode_u8(o + 7, player.big_banks)
		rows.encode_u16(o + 8, player.caught)
		rows.encode_u16(o + 10, player.lost)
		rows.encode_s16(o + 12, player.last_catch)
		rows.encode_s16(o + 14, player.last_bank)
		rows.encode_u8(o + 16, int(player.bank_points) | ((int(player.bank_shelf) + 1) << 3))
		# Spill is the latest catch when recent, and carries its original tick otherwise.
		rows.encode_u8(o + 17, (int(player.spilled) << 6) | clampi(tick - int(player.last_spill), 0, 63))
	for i in drops.size():
		var drop := drops[i]
		var o := SEATS * PLAYER_ROW + i * DROP_ROW
		_encode_pos(rows, o, drop.pos)
		rows.encode_u16(o + 4, drop.id)
		rows.encode_u16(o + 6, drop.born)
		rows.encode_u16(o + 8, drop.land)
		rows.encode_u8(o + 10, int(drop.center) | ((int(drop.winner) + 1) << 1))
	return {"id": round_id, "tick": tick, "count": _count_ticks, "burst": burst_tick, "state": rows}

func apply_snapshot(data: Dictionary) -> void:
	var rows: PackedByteArray = data.get("state", PackedByteArray())
	var extra := rows.size() - SEATS * PLAYER_ROW
	if data.get("id", 0) != round_id or extra < 0 or extra > MAX_DROPS * DROP_ROW or extra % DROP_ROW != 0:
		return
	var new_tick := int(data.get("tick", -1))
	var new_count := int(data.get("count", -1))
	if new_tick < tick or new_tick > ROUND_TICKS or new_count < 0 or new_count > _count_ticks:
		return
	_count_ticks = new_count
	countdown = _count_ticks * STEP
	tick = new_tick
	elapsed = tick * STEP
	phase = "countdown" if _count_ticks > 0 else ("finished" if tick >= ROUND_TICKS else "running")
	burst_tick = int(data.get("burst", NO_TICK))
	for i in SEATS:
		var player := players[i]
		var o := i * PLAYER_ROW
		player.pos = _decode_pos(rows, o)
		player.score = rows.decode_u16(o + 4)
		var flags := rows.decode_u8(o + 6)
		player.carry = flags & 7
		player.bot = (flags & 8) != 0
		player.big_banks = rows.decode_u8(o + 7)
		player.caught = rows.decode_u16(o + 8)
		player.lost = rows.decode_u16(o + 10)
		player.last_catch = rows.decode_s16(o + 12)
		player.last_bank = rows.decode_s16(o + 14)
		var bank := rows.decode_u8(o + 16)
		player.bank_points = bank & 7
		player.bank_shelf = (bank >> 3) - 1
		var spill := rows.decode_u8(o + 17)
		player.spilled = spill >> 6
		player.last_spill = NO_TICK if (spill & 63) == 63 else tick - (spill & 63)
	drops.clear()
	for o in range(SEATS * PLAYER_ROW, rows.size(), DROP_ROW):
		var flags := rows.decode_u8(o + 10)
		drops.append({"pos": _decode_pos(rows, o), "id": rows.decode_u16(o + 4),
			"born": rows.decode_u16(o + 6), "land": rows.decode_u16(o + 8),
			"center": (flags & 1) != 0, "winner": (flags >> 1) - 1})

static func _encode_pos(rows: PackedByteArray, o: int, pos: Vector2) -> void:
	rows.encode_s16(o, roundi(pos.x * SCALE))
	rows.encode_s16(o + 2, roundi(pos.y * SCALE))

static func _decode_pos(rows: PackedByteArray, o: int) -> Vector2:
	return Vector2(rows.decode_s16(o), rows.decode_s16(o + 2)) / SCALE
