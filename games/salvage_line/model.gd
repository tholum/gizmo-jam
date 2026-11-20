extends RefCounted
## Host-authoritative fixed-step simulation in arena x/z coordinates.

const SEATS := 6
const HZ := 20
const STEP := 1.0 / HZ
const COUNTDOWN := 3.0
const ROUND_TIME := 90
const ROUND_TICKS := ROUND_TIME * HZ
const FIELD_RADIUS := 14.0
const HARBOR_DISTANCE := 11.3
const HARBOR_RADIUS := 2.1
const DOCK_RADIUS := HARBOR_RADIUS
const APPROACH_RADIUS := 3.3
const HOOK_RANGE := 2.9
const CUT_RANGE := 2.4
const TOW_LENGTH := 2.2
const TAUT_DISTANCE := 1.5
const PROTECTION_TICKS := 17
const DRIFT_TICKS := 18
const REFILL_TICKS := 31

const DIRS := {"up": 1, "down": 2, "left": 4, "right": 8}
const BOAT_ACCEL := 34.0
const FREE_SPEED := 5.9
const LIGHT_SPEED := 4.8
const HEAVY_SPEED := 3.7
const BOT_THROTTLE := 0.66
const CRATE_COUNT := 7
const NO_TICK := -1000
const POSE_SCALE := 1024.0
const ANGLE_SCALE := 8192.0
const PLAYER_ROW := 23
const CRATE_ROW := 16

var players: Array[Dictionary] = []
var crates: Array[Dictionary] = []
var phase := "countdown"
var countdown := COUNTDOWN
var elapsed := 0.0
var tick := 0
var round_id := 0

var _rng := RandomNumberGenerator.new()
var _count_ticks := int(COUNTDOWN * HZ)
var _owed := 0.0
var _next_crate := 0
var _spawn_lane := 0
var _priority := 0
var _refills: Array[int] = []
var _guest := false

static func harbor_center(slot: int) -> Vector2:
	return Vector2.from_angle(slot * TAU / SEATS) * HARBOR_DISTANCE

static func direction(mask: int) -> Vector2:
	return Vector2(int((mask & 8) != 0) - int((mask & 4) != 0),
		int((mask & 2) != 0) - int((mask & 1) != 0)).normalized()

func begin(seed_value: int, slots: Array, id: int = 1, _endless: bool = false) -> void:
	_rng.seed = seed_value
	round_id = id
	phase = "countdown"
	countdown = COUNTDOWN
	elapsed = 0.0
	tick = 0
	_count_ticks = int(COUNTDOWN * HZ)
	_owed = 0.0
	_guest = false
	_next_crate = 0
	_spawn_lane = _rng.randi_range(0, SEATS - 1)
	_priority = _rng.randi_range(0, SEATS - 1)
	_refills.clear()
	players.clear()
	crates.clear()
	for i in SEATS:
		var seat: Dictionary = slots[i]
		var outward := harbor_center(i).normalized()
		players.append({
			"slot": i, "name": seat.name, "peer": seat.peer, "bot": seat.bot, "active": seat.get("active", true),
			"pos": _snap_pose(outward * 9.2), "velocity": Vector2.ZERO, "face": (-outward).angle(),
			"score": 0, "towing": -1, "hook_tick": NO_TICK, "cut_tick": NO_TICK,
			"lost_tick": NO_TICK, "bank_tick": NO_TICK, "bank_amount": 0,
			"input": 0, "winch_down": false, "queued": false,
			"bot_offset": _rng.randi_range(0, 159), "bot_cut_after": 0,
		})
	for i in CRATE_COUNT:
		_spawn_crate()

func remaining() -> float:
	return maxf(0.0, ROUND_TIME - elapsed)

func command(slot: int, action: String, pressed: bool) -> void:
	if _guest or slot < 0 or slot >= players.size() or phase == "finished":
		return
	var p := players[slot]
	if not p.active or p.bot:
		return
	if action == "winch":
		if pressed and not p.winch_down and phase == "running":
			p.queued = true
		p.winch_down = pressed
	elif DIRS.has(action):
		var bit: int = DIRS[action]
		p.input = int(p.input) | bit if pressed else int(p.input) & ~bit

func take_over(slot: int) -> void:
	if _guest or slot < 0 or slot >= players.size() or phase == "finished":
		return
	var p := players[slot]
	if not p.active:
		return
	p.bot = true
	p.input = 0
	p.winch_down = false
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
			_tick()

func _tick() -> void:
	# Resolve the displayed winch target before applying movement. In
	# particular, steering away from a dock on the same tap still banks.
	var intents: Array[Dictionary] = []
	for p in players:
		if not p.active or (not p.bot and not p.queued):
			continue
		var target := action_target(p.slot)
		if p.bot:
			p.queued = _bot_winch(p, target)
		if p.queued and target.kind != "idle":
			target.slot = p.slot
			target.distance = Vector2(p.pos).distance_squared_to(target.at)
			intents.append(target)
		p.queued = false

	tick += 1
	elapsed = tick * STEP
	_resolve(intents)
	while not _refills.is_empty() and _refills[0] <= tick:
		_refills.pop_front()
		_spawn_crate()

	var moves := PackedVector2Array()
	moves.resize(SEATS)
	for p in players:
		if p.active:
			moves[p.slot] = _bot_move(p) if p.bot else direction(p.input)
	for p in players:
		if not p.active:
			continue
		var want := moves[p.slot]
		var cargo := _crate(p.towing)
		var speed := FREE_SPEED if cargo.is_empty() else (HEAVY_SPEED if cargo.heavy else LIGHT_SPEED)
		if not want.is_zero_approx():
			p.face = want.angle()
		p.velocity = _snap_pose(Vector2(p.velocity).move_toward(want * speed, BOAT_ACCEL * STEP))
		p.pos = _snap_pose(Vector2(p.pos + p.velocity * STEP).limit_length(FIELD_RADIUS))
	for crate in crates:
		_move_crate(crate)
	if tick >= ROUND_TICKS:
		phase = "finished"

func _crate(id: int) -> Dictionary:
	for crate in crates:
		if crate.id == id:
			return crate
	return {}

func _spawn_crate() -> void:
	# Cycle around the six harbors with seeded offsets, checking separation on
	# each replacement. New cargo receives a fresh ID when old cargo banks.
	_spawn_lane = posmod(_spawn_lane + 5, SEATS)
	var lane := _spawn_lane * TAU / SEATS
	var best := Vector2.ZERO
	var best_gap := -1.0
	for attempt in 12:
		var angle := lane + _rng.randf_range(-0.72, 0.72)
		var radius := _rng.randf_range(1.5, 5.4)
		var candidate := Vector2.from_angle(angle) * radius
		var gap := INF
		for crate in crates:
			gap = minf(gap, candidate.distance_squared_to(crate.pos))
		if gap > best_gap:
			best = candidate
			best_gap = gap
		if gap >= 2.6 ** 2:
			break
	_next_crate += 1
	crates.append({
		"id": _next_crate, "pos": _snap_pose(best), "velocity": Vector2.ZERO,
		"heavy": _rng.randf() < 0.38, "owner": -1, "drift_until": 0, "protected_until": 0,
	})

func _move_crate(crate: Dictionary) -> void:
	var at: Vector2 = crate.pos
	var velocity: Vector2 = crate.velocity
	if crate.owner >= 0:
		var p := players[crate.owner]
		var before := at
		var toward: Vector2 = p.pos - at
		if toward.length_squared() > TOW_LENGTH ** 2:
			# Follow the tug only when the line pulls tight, including through turns.
			at = p.pos - toward.normalized() * TOW_LENGTH
		crate.pos = _snap_pose(at)
		crate.velocity = _snap_pose(((at - before) / STEP).limit_length(FREE_SPEED))
	else:
		crate.pos = _snap_pose((at + velocity * STEP).limit_length(FIELD_RADIUS))
		crate.velocity = _snap_pose(velocity.move_toward(Vector2.ZERO, 3.2 * STEP))

func rope_midpoint(crate: Dictionary) -> Vector2:
	if crate.owner < 0:
		return crate.pos
	return (Vector2(players[crate.owner].pos) + Vector2(crate.pos)) * 0.5

func line_taut(crate: Dictionary) -> bool:
	return crate.owner >= 0 and Vector2(players[crate.owner].pos).distance_squared_to(crate.pos) >= TAUT_DISTANCE ** 2

func line_protected(crate: Dictionary) -> bool:
	if crate.owner < 0:
		return false
	var at: Vector2 = players[crate.owner].pos
	return tick < int(crate.protected_until) or at.distance_squared_to(harbor_center(crate.owner)) <= APPROACH_RADIUS ** 2

func _can_bank(p: Dictionary, crate: Dictionary) -> bool:
	var dock := harbor_center(p.slot)
	return dock.distance_squared_to(p.pos) <= HARBOR_RADIUS ** 2 and dock.distance_squared_to(crate.pos) <= (HARBOR_RADIUS + TOW_LENGTH + 0.002) ** 2

func action_target(slot: int) -> Dictionary:
	var target := {"kind": "idle", "crate": -1, "at": Vector2.ZERO}
	if slot < 0 or slot >= players.size() or phase != "running":
		return target
	var p := players[slot]
	if not p.active:
		return target
	target.at = p.pos
	if p.towing >= 0:
		var cargo := _crate(p.towing)
		if not cargo.is_empty():
			var dock := harbor_center(slot)
			return {"kind": "deliver", "crate": p.towing, "at": dock} if _can_bank(p, cargo) else {
				"kind": "release", "crate": p.towing, "at": cargo.pos}
		return target
	var best := INF
	for crate in crates:
		var at: Vector2 = crate.pos
		var reach := HOOK_RANGE
		var kind := "hook"
		if crate.owner >= 0:
			if line_protected(crate) or not line_taut(crate):
				continue
			at = rope_midpoint(crate)
			reach = CUT_RANGE
			kind = "cut"
		elif tick < int(crate.drift_until):
			continue
		var distance := Vector2(p.pos).distance_squared_to(at)
		if distance <= reach ** 2 and distance < best:
			best = distance
			target = {"kind": kind, "crate": crate.id, "at": at}
	return target

func _resolve(intents: Array[Dictionary]) -> void:
	# Apply actions selected from the same frame. A bank or manual release
	# expires pending cuts. Contested hooks and cuts go to the closest tug,
	# with seeded rotating seat priority when distances are equal.
	const ORDER := {"deliver": 0, "release": 1, "cut": 2, "hook": 3}
	intents.sort_custom(func(a, b):
		if a.kind != b.kind:
			return ORDER[a.kind] < ORDER[b.kind]
		if a.distance != b.distance:
			return a.distance < b.distance
		return posmod(a.slot - tick - _priority, SEATS) < posmod(b.slot - tick - _priority, SEATS))
	for intent in intents:
		var cargo := _crate(intent.crate)
		if cargo.is_empty():
			continue
		var p := players[intent.slot]
		match intent.kind:
			"deliver":
				p.bank_amount = 2 if cargo.heavy else 1
				p.score += p.bank_amount
				p.bank_tick = tick
				p.towing = -1
				crates.erase(cargo)
				_refills.append(tick + REFILL_TICKS)
			"release":
				_release(cargo)
			"cut":
				if cargo.owner >= 0:
					p.cut_tick = tick
					players[cargo.owner].lost_tick = tick
					_release(cargo)
			"hook":
				if cargo.owner < 0 and tick >= int(cargo.drift_until):
					p.towing = cargo.id
					p.hook_tick = tick
					cargo.owner = p.slot
					cargo.protected_until = tick + PROTECTION_TICKS
					_move_crate(cargo)

func _release(cargo: Dictionary) -> void:
	var owner := players[cargo.owner]
	var velocity: Vector2 = cargo.velocity
	cargo.velocity = _snap_pose((velocity + Vector2(owner.velocity) * 0.45).limit_length(5.2))
	owner.towing = -1
	cargo.owner = -1
	cargo.protected_until = 0
	cargo.drift_until = tick + DRIFT_TICKS

func _bot_move(p: Dictionary) -> Vector2:
	var at: Vector2 = p.pos
	var dock := harbor_center(p.slot)
	if p.towing >= 0:
		return (dock - at).limit_length() * BOT_THROTTLE
	var closest := INF
	var goal := at
	for cargo in crates:
		var where: Vector2 = cargo.pos
		var distance := at.distance_to(where)
		var weight := 0.8 if cargo.heavy else 0.0
		var cost := distance + dock.distance_to(where) * 0.21 - weight
		if cargo.owner >= 0:
			# Occasionally intercept a nearby exposed rival. The cooldown leaves
			# free tugs time to tow their own cargo after a successful cut.
			if not _bot_can_cut(p) or distance > 6.7 or line_protected(cargo) or not line_taut(cargo):
				continue
			where = rope_midpoint(cargo) + Vector2(players[cargo.owner].velocity) * 0.12
			cost = at.distance_to(where) + 0.35
		else:
			cost += maxf(0.0, (int(cargo.drift_until) - tick) * STEP * FREE_SPEED - distance)
		if cost < closest:
			closest = cost
			goal = where
	return (goal - at).limit_length() * BOT_THROTTLE

func _bot_can_cut(p: Dictionary) -> bool:
	return tick >= int(p.bot_cut_after) and posmod(tick + int(p.bot_offset), 160) < 86

func _bot_winch(p: Dictionary, target: Dictionary) -> bool:
	match target.kind:
		"deliver", "hook":
			return true
		"cut":
			if _bot_can_cut(p):
				p.bot_cut_after = tick + 78
				return true
	return false

func ranking() -> Array:
	var order := range(players.size()).filter(func(slot): return players[slot].active)
	order.sort_custom(func(a, b):
		return players[a].score > players[b].score if players[a].score != players[b].score else a < b)
	return order

func winners() -> Array:
	var order := ranking()
	if order.is_empty():
		return []
	return order.filter(func(i): return players[i].score == players[order[0]].score)

static func _snap_pose(value: Vector2) -> Vector2:
	return value.snapped(Vector2.ONE / POSE_SCALE)

func snapshot() -> Dictionary:
	var rows := PackedByteArray()
	rows.resize(SEATS * PLAYER_ROW + crates.size() * CRATE_ROW)
	var o := 0
	for p in players:
		_encode_vector(rows, o, p.pos)
		_encode_vector(rows, o + 4, p.velocity)
		rows.encode_s16(o + 8, roundi(p.face * ANGLE_SCALE))
		rows.encode_u16(o + 10, p.score)
		rows.encode_s16(o + 12, p.towing)
		rows.encode_s16(o + 14, p.hook_tick)
		rows.encode_s16(o + 16, p.cut_tick)
		rows.encode_s16(o + 18, p.lost_tick)
		rows.encode_s16(o + 20, p.bank_tick)
		rows.encode_u8(o + 22, int(p.bot) | (int(p.bank_amount) << 1))
		o += PLAYER_ROW
	for cargo in crates:
		rows.encode_u16(o, cargo.id)
		_encode_vector(rows, o + 2, cargo.pos)
		_encode_vector(rows, o + 6, cargo.velocity)
		rows.encode_s8(o + 10, cargo.owner)
		rows.encode_u16(o + 11, cargo.drift_until)
		rows.encode_u16(o + 13, cargo.protected_until)
		rows.encode_u8(o + 15, int(cargo.heavy))
		o += CRATE_ROW
	return {"id": round_id, "tick": tick, "count": _count_ticks, "state": rows}

func apply_snapshot(data: Dictionary) -> void:
	var raw: Variant = data.get("state")
	var next_tick: Variant = data.get("tick")
	var next_count: Variant = data.get("count")
	var id: Variant = data.get("id")
	if not (raw is PackedByteArray and id is int and next_tick is int and next_count is int):
		return
	if players.size() != SEATS or next_tick < 0 or next_tick > ROUND_TICKS or next_count < 0 or next_count > int(COUNTDOWN * HZ):
		return
	var rows: PackedByteArray = raw
	var cargo_bytes := rows.size() - SEATS * PLAYER_ROW
	if cargo_bytes < 0 or cargo_bytes % CRATE_ROW != 0 or cargo_bytes > CRATE_COUNT * CRATE_ROW:
		return
	@warning_ignore("integer_division")
	var cargo_count := cargo_bytes / CRATE_ROW
	var o := SEATS * PLAYER_ROW
	var ids := {}
	for i in cargo_count:
		var cargo_id := rows.decode_u16(o)
		var owner := rows.decode_s8(o + 10)
		if cargo_id == 0 or ids.has(cargo_id) or owner < -1 or owner >= SEATS:
			return
		ids[cargo_id] = true
		o += CRATE_ROW
	_guest = true
	round_id = id
	tick = next_tick
	_count_ticks = next_count
	countdown = _count_ticks * STEP
	elapsed = tick * STEP
	phase = "countdown" if _count_ticks > 0 else ("finished" if tick == ROUND_TICKS else "running")
	o = 0
	for p in players:
		p.pos = _decode_vector(rows, o)
		p.velocity = _decode_vector(rows, o + 4)
		p.face = rows.decode_s16(o + 8) / ANGLE_SCALE
		p.score = rows.decode_u16(o + 10)
		p.towing = rows.decode_s16(o + 12)
		p.hook_tick = rows.decode_s16(o + 14)
		p.cut_tick = rows.decode_s16(o + 16)
		p.lost_tick = rows.decode_s16(o + 18)
		p.bank_tick = rows.decode_s16(o + 20)
		p.bot = (rows.decode_u8(o + 22) & 1) != 0
		p.bank_amount = rows.decode_u8(o + 22) >> 1
		o += PLAYER_ROW
	crates.clear()
	for i in cargo_count:
		crates.append({
			"id": rows.decode_u16(o), "pos": _decode_vector(rows, o + 2), "velocity": _decode_vector(rows, o + 6),
			"owner": rows.decode_s8(o + 10), "drift_until": rows.decode_u16(o + 11),
			"protected_until": rows.decode_u16(o + 13), "heavy": rows.decode_u8(o + 15) != 0,
		})
		o += CRATE_ROW

static func _encode_vector(rows: PackedByteArray, o: int, value: Vector2) -> void:
	rows.encode_s16(o, roundi(value.x * POSE_SCALE))
	rows.encode_s16(o + 2, roundi(value.y * POSE_SCALE))

static func _decode_vector(rows: PackedByteArray, o: int) -> Vector2:
	return Vector2(rows.decode_s16(o), rows.decode_s16(o + 2)) / POSE_SCALE
