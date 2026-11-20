extends RefCounted
## Host-authoritative dohyo simulation. All game clocks use 60 Hz ticks.

const SEATS := 6
const HZ := 60
const STEP := 1.0 / HZ
const COUNTDOWN := 3.0
const ROUND_TIME := 90
const ROUND_TICKS := ROUND_TIME * HZ
const RADIUS := 5.8
const BODY_DIAMETER := 0.98
const WINDUP := 12
const SWING := 11
const COOLDOWN := 84
const RESPAWN := 84
const GUARD := 38
const CREDIT := 120
const HIT_FLASH := 17
const SHOVE_RANGE := 1.85
const HALF_ANGLE := deg_to_rad(39.0)
const WALK_SPEED := 4.95
const ACCEL := 39.0
const BRAKE := 45.0
const PLANT_DELAY := 9
const PLANTED_FORCE := 0.43
const KNOCK_SPEED := 15.1
const KNOCK_DRAG := 3.26
const NEVER := -1000
const INPUT := {"up": 1, "down": 2, "left": 4, "right": 8}

# Fixed row order for net v1. No physics inputs or bot scratch state travel.
enum { X, Z, VX, VZ, FACE, GAIT, READY, STRIKE, RETURN, GUARD_END,
	HIT, POINTS, OUTS, CREDIT_SEAT, FLAGS, ROW_SIZE }

var rng := RandomNumberGenerator.new()
var players: Array[Dictionary] = []
var active_count := 0
var phase := "countdown"
var countdown := COUNTDOWN
var elapsed := 0.0
var tick := 0
var round_id := 0
var strike_count := 0
var hit_count := 0

var _owed := 0.0
var _count_ticks := roundi(COUNTDOWN * HZ)
var _spawn_angle := 0.0

func begin(seed_value: int, slots: Array, id: int = 1, _endless: bool = false) -> void:
	rng.seed = seed_value
	round_id = id
	phase = "countdown"
	countdown = COUNTDOWN
	elapsed = 0.0
	tick = 0
	strike_count = 0
	hit_count = 0
	_owed = 0.0
	_count_ticks = roundi(COUNTDOWN * HZ)
	_spawn_angle = rng.randf_range(-0.19, 0.19)
	players.clear()
	active_count = 0
	for i in SEATS:
		var seat: Dictionary = slots[i]
		var active: bool = seat.get("active", true)
		active_count += int(active)
		var pos := socket(i, 3.05)
		players.append({
			"name": seat.name, "peer": seat.peer, "bot": seat.bot, "active": active,
			"pos": pos, "velocity": Vector2.ZERO, "face": (-pos).angle(), "gait": 0.0,
			"score": 0, "outs": 0, "last_credit": -1, "alive": active, "planted": false,
			"ready_tick": 0, "strike_tick": NEVER, "respawn_tick": NEVER,
			"guard_until": 0, "hit_tick": NEVER,
			"input": 0, "queued": false, "drive": Vector2.ZERO, "knock": Vector2.ZERO,
			"still": 0, "last_shove": -1, "tie_break": rng.randi(),
			"think_tick": 1 + i * 2, "intent": Vector2.ZERO, "sidestep": 1.0 if rng.randf() < 0.5 else -1.0,
			"boldness": rng.randf(), "bot_target": -1,
		})

func socket(index: int, radius: float) -> Vector2:
	return Vector2.from_angle(_spawn_angle + (index + 0.5) * TAU / SEATS) * radius

func remaining() -> float:
	return maxf(0.0, ROUND_TIME - elapsed)

func command(slot: int, action: String, pressed: bool) -> void:
	if slot < 0 or slot >= players.size() or phase == "finished":
		return
	var p := players[slot]
	if not p.active or p.bot:
		return
	if action == "shove":
		if pressed and phase == "running" and p.alive:
			p.queued = true
	elif INPUT.has(action):
		var bit: int = INPUT[action]
		p.input = int(p.input) | bit if pressed else int(p.input) & ~bit

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
	# Give simultaneous returns separate, clear sockets. The first choice
	# rotates with the tick instead of always going to seat one.
	for offset in SEATS:
		var i := (tick + offset) % SEATS
		if players[i].active and players[i].respawn_tick == tick:
			_respawn(i)

	for i in SEATS:
		var p := players[i]
		if not p.alive:
			continue
		var direction := _think(i) if p.bot else _held_direction(p.input)
		var committed: bool = tick < int(p.strike_tick) + 4
		if tick >= int(p.strike_tick) + SWING and not direction.is_zero_approx():
			p.face = direction.angle()
		if p.queued and tick >= int(p.ready_tick) and tick >= int(p.guard_until):
			p.strike_tick = tick + WINDUP
			p.ready_tick = tick + COOLDOWN
			committed = true
		p.queued = false
		var speed := WALK_SPEED * (0.35 if committed else 1.0)
		if tick - int(p.hit_tick) < HIT_FLASH:
			speed *= 0.46
		p.drive = p.drive.move_toward(direction * speed, (BRAKE if direction.is_zero_approx() else ACCEL) * STEP)
		p.gait = p.drive.length()
		p.still = int(p.still) + 1 if direction.is_zero_approx() and float(p.gait) <= 0.42 and not committed else 0
		p.planted = int(p.still) >= PLANT_DELAY and p.knock.length_squared() < 0.32

	_resolve_shoves()
	for p in players:
		if not p.alive:
			continue
		p.velocity = p.drive + p.knock
		p.pos += p.velocity * STEP
		p.knock = p.knock.move_toward(Vector2.ZERO, 0.9 * STEP) * exp(-KNOCK_DRAG * STEP)

	_resolve_crowding()
	# All attacks and movement have resolved before credit or the final result.
	for i in SEATS:
		if players[i].alive and players[i].pos.length_squared() >= RADIUS * RADIUS:
			_ring_out(i)
	if tick >= ROUND_TICKS:
		for p in players:
			if int(p.strike_tick) > tick:
				p.strike_tick = NEVER
		phase = "finished"

func _held_direction(mask: int) -> Vector2:
	return Vector2(float((mask >> 3) & 1) - float((mask >> 2) & 1),
		float((mask >> 1) & 1) - float(mask & 1)).normalized()

func _resolve_shoves() -> void:
	var attackers: Array[int] = []
	for i in SEATS:
		if players[i].alive and players[i].strike_tick == tick:
			attackers.append(i)
	if attackers.is_empty():
		return
	strike_count += attackers.size()
	for victim in SEATS:
		var target := players[victim]
		if not target.alive or tick < int(target.guard_until):
			continue
		var impulse := Vector2.ZERO
		var credit := -1
		var best := 0.0
		for attacker in attackers:
			if attacker == victim:
				continue
			var source := players[attacker]
			var offset: Vector2 = target.pos - source.pos
			if offset.length_squared() > SHOVE_RANGE * SHOVE_RANGE:
				continue
			var facing := Vector2.from_angle(source.face)
			var away := offset.normalized()
			var aim := away.dot(facing)
			if aim < cos(HALF_ANGLE):
				continue
			var strength := lerpf(0.84, 1.0, aim) * lerpf(1.0, 0.84, offset.length() / SHOVE_RANGE)
			impulse += (away * 0.72 + facing * 0.28).normalized() * strength
			# One point at most. Same-tick hits credit the strongest shove;
			# a seeded tie-break also handles perfectly symmetric hits.
			var tied := is_equal_approx(strength, best)
			if credit < 0 or (strength > best and not tied) or (tied and source.tie_break > players[credit].tie_break):
				best = strength
				credit = attacker
		if credit >= 0:
			var force := KNOCK_SPEED * (PLANTED_FORCE if target.planted else 1.0)
			target.knock = (target.knock * 0.42 + impulse * force).limit_length(force * 1.17)
			target.hit_tick = tick
			target.last_shove = credit
			target.planted = false
			target.still = 0
			hit_count += 1

func _resolve_crowding() -> void:
	# Equal corrections computed from the same positions per pass keep
	# contact symmetric. Corrections alone cannot push a robot off the lip.
	var shift: Array[Vector2] = []
	shift.resize(SEATS)
	for _pass in 3:
		shift.fill(Vector2.ZERO)
		for i in SEATS:
			var a := players[i]
			if not a.alive or a.pos.length_squared() >= RADIUS * RADIUS:
				continue
			for j in range(i + 1, SEATS):
				var b := players[j]
				if not b.alive or b.pos.length_squared() >= RADIUS * RADIUS:
					continue
				var offset: Vector2 = b.pos - a.pos
				var distance := offset.length()
				if distance >= BODY_DIAMETER:
					continue
				var axis := offset / distance if distance > 0.00001 else Vector2.from_angle((i + j) * 2.4)
				var correction := axis * (BODY_DIAMETER - distance) * 0.5
				shift[i] -= correction
				shift[j] += correction
		for i in SEATS:
			if not shift[i].is_zero_approx():
				players[i].pos = (players[i].pos + shift[i]).limit_length(RADIUS - 0.001)

func _ring_out(slot: int) -> void:
	var p := players[slot]
	p.alive = false
	p.outs += 1
	p.last_credit = -1
	if int(p.last_shove) >= 0 and tick - int(p.hit_tick) <= CREDIT:
		p.last_credit = p.last_shove
		players[int(p.last_credit)].score += 1
	p.respawn_tick = tick + RESPAWN
	p.strike_tick = NEVER
	p.queued = false
	p.planted = false
	if active_count == 1:
		phase = "finished"

func _respawn(slot: int) -> void:
	var p := players[slot]
	var at := Vector2.ZERO
	var best := -1.0
	for offset in SEATS + 1:
		var candidate := socket((slot + offset) % SEATS, 1.87) if offset < SEATS else Vector2.ZERO
		var clearance := INF
		for other in players:
			if other.alive:
				clearance = minf(clearance, candidate.distance_squared_to(other.pos))
		if clearance > best:
			at = candidate
			best = clearance
	p.pos = at
	p.velocity = Vector2.ZERO
	p.drive = Vector2.ZERO
	p.knock = Vector2.ZERO
	p.gait = 0.0
	p.face = (-at).angle() if not at.is_zero_approx() else socket(slot, 1.0).angle()
	p.alive = true
	p.guard_until = tick + GUARD
	p.hit_tick = NEVER
	p.last_shove = -1
	p.still = 0
	p.think_tick = tick
	p.intent = Vector2.ZERO
	p.bot_target = -1

func _think(slot: int) -> Vector2:
	var p := players[slot]
	if tick < int(p.think_tick):
		return p.intent
	# Stagger reactions so the bots leave room to slip a shove or line one up.
	p.think_tick = tick + rng.randi_range(11, 19)
	var at: Vector2 = p.pos
	var edge := at.length()
	var target := -1
	var best := INF
	for i in SEATS:
		var rival := players[i]
		if i == slot or not rival.alive or tick < int(rival.guard_until):
			continue
		var distance := at.distance_to(rival.pos)
		var exposed: float = rival.pos.length() * lerpf(0.16, 0.42, p.boldness)
		var preference := distance - exposed - (0.30 if i == p.bot_target else 0.0)
		if preference < best:
			best = preference
			target = i
	p.bot_target = target
	if target < 0 or edge > RADIUS - 1.02 or (edge > 3.2 and not p.knock.is_zero_approx()):
		p.intent = _octant(-at)
		return p.intent

	var rival := players[target]
	var offset: Vector2 = rival.pos - at
	var lead: Vector2 = offset + rival.velocity.limit_length(WALK_SPEED) * 0.11
	var direction := _octant(lead)
	var distance := offset.length()
	var incoming: bool = int(rival.strike_tick) > tick and int(rival.strike_tick) - tick <= 7
	var threatened := incoming and distance < 1.82 and (-offset).normalized().dot(Vector2.from_angle(rival.face)) > 0.84
	if threatened and rng.randf() < 0.41:
		direction = _octant(offset.orthogonal() * float(p.sidestep) - at * 0.32)
	elif distance < 1.57 and tick >= int(p.ready_tick) and tick >= int(p.guard_until):
		p.queued = rng.randf() < lerpf(0.36, 0.68, p.boldness)
	elif distance < 1.36:
		# Brake between swings, or orbit for a better angle near the rim.
		direction = Vector2.ZERO if edge < 2.7 else _octant(offset.orthogonal() * float(p.sidestep) - at * 0.28)
	elif edge > 4.35 and direction.dot(at.normalized()) > 0.24:
		direction = _octant(offset.orthogonal() * float(p.sidestep) - at * 0.58)
	p.intent = direction
	return direction

func _octant(direction: Vector2) -> Vector2:
	return Vector2.ZERO if direction.length_squared() < 0.001 else Vector2.from_angle(snappedf(direction.angle(), PI / 4.0))

func take_over(slot: int) -> void:
	if slot < 0 or slot >= players.size():
		return
	var p := players[slot]
	if not p.active:
		return
	p.bot = true
	p.input = 0
	p.queued = false
	p.think_tick = tick

func ranking() -> Array:
	var order := range(players.size()).filter(func(i): return players[i].active)
	order.sort_custom(func(a, b):
		if players[a].score != players[b].score:
			return players[a].score > players[b].score
		return a < b)
	return order

func winners() -> Array:
	var order := ranking()
	if order.is_empty() or (active_count == 1 and not players[order[0]].alive):
		return []
	var best: int = players[order[0]].score
	return order.filter(func(i): return players[i].score == best)

func snapshot() -> Dictionary:
	var seats := PackedInt32Array()
	seats.resize(players.size() * ROW_SIZE)
	for i in players.size():
		var p := players[i]
		var row := i * ROW_SIZE
		seats[row + X] = roundi(p.pos.x * 256.0)
		seats[row + Z] = roundi(p.pos.y * 256.0)
		seats[row + VX] = roundi(p.velocity.x * 128.0)
		seats[row + VZ] = roundi(p.velocity.y * 128.0)
		seats[row + FACE] = roundi(float(p.face) * 1024.0)
		seats[row + GAIT] = roundi(float(p.gait) * 64.0)
		seats[row + READY] = p.ready_tick
		seats[row + STRIKE] = p.strike_tick
		seats[row + RETURN] = p.respawn_tick
		seats[row + GUARD_END] = p.guard_until
		seats[row + HIT] = p.hit_tick
		seats[row + POINTS] = p.score
		seats[row + OUTS] = p.outs
		seats[row + CREDIT_SEAT] = p.last_credit
		seats[row + FLAGS] = int(p.alive) | (int(p.planted) << 1) | (int(p.bot) << 2)
	return {"id": round_id, "tick": tick, "count": _count_ticks, "strikes": strike_count, "hits": hit_count, "seats": seats}

func apply_snapshot(data: Dictionary) -> void:
	var seats: PackedInt32Array = data.get("seats", PackedInt32Array())
	if seats.size() != players.size() * ROW_SIZE:
		return
	_count_ticks = int(data.count)
	countdown = _count_ticks * STEP
	tick = int(data.tick)
	elapsed = tick * STEP
	phase = "countdown" if _count_ticks > 0 else ("finished" if tick >= ROUND_TICKS else "running")
	strike_count = int(data.strikes)
	hit_count = int(data.hits)
	for i in players.size():
		var p := players[i]
		var row := i * ROW_SIZE
		p.pos = Vector2(seats[row + X], seats[row + Z]) / 256.0
		p.velocity = Vector2(seats[row + VX], seats[row + VZ]) / 128.0
		p.face = seats[row + FACE] / 1024.0
		p.gait = seats[row + GAIT] / 64.0
		p.ready_tick = seats[row + READY]
		p.strike_tick = seats[row + STRIKE]
		p.respawn_tick = seats[row + RETURN]
		p.guard_until = seats[row + GUARD_END]
		p.hit_tick = seats[row + HIT]
		p.score = seats[row + POINTS]
		p.outs = seats[row + OUTS]
		p.last_credit = seats[row + CREDIT_SEAT]
		p.alive = p.active and (seats[row + FLAGS] & 1) != 0
		p.planted = (seats[row + FLAGS] & 2) != 0
		p.bot = (seats[row + FLAGS] & 4) != 0
		if active_count == 1 and p.active and not p.alive and phase == "running":
			phase = "finished"
