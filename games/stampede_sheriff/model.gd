extends RefCounted
## Host-authoritative 60 Hz herding simulation. All distances are in board units.

const SEATS := 6
const HZ := 60
const STEP := 1.0 / HZ
const COUNTDOWN := 3.0
const ROUND_TIME := 90
const ROUND_TICKS := ROUND_TIME * HZ
const FIELD_RADIUS := 10.9
const PEN_DISTANCE := 8.85
const PEN_RADIUS := 1.36
const HATCH_DISTANCE := 3.30
const HATCHES := 3
const HATCH_NAMES := ["A", "B", "C"]
const HERD_SIZE := 4
const MAX_CRITTERS := 18
const FIRST_RELEASE := 4 * HZ
const RELEASE_INTERVAL := 390
const HATCH_WARNING := 90
const LAUNCH_TICKS := 43
const LAUNCH_SPEED := 4.45
const PLAYER_SPEED := 5.65
const PLAYER_ACCEL := 33.0
const PRESSURE_RANGE := 2.50
const PRESSURE_NEAR := 1.12
const CRITTER_SPEED := 1.10
const HERD_SPEED := 3.45
const CRITTER_TURN := 8.5
const CLAP_RANGE := 2.75
const CLAP_ANGLE := deg_to_rad(36.0)
const CLAP_DOT := cos(CLAP_ANGLE)
const CLAP_IMPULSE := 5.35
const CLAP_DRAG := 9.7
const CLAP_COOLDOWN := 66
const CLAP_RECOVERY := 96
const NO_TICK := -600
const DIRS := {"up": 1, "down": 2, "left": 4, "right": 8}

const BOT_BEHIND := 1.53
const BOT_REPLAN := 21
const CRITTER_ROW := 12
const PLAYER_ROW := 18
const ANGLE_SCALE := 4096.0
const ANGLE_LIMIT := 12867 # floor(PI * ANGLE_SCALE), so decoding stays inside the wrap

var rng := RandomNumberGenerator.new()
var players: Array[Dictionary] = []
var critters: Array[Dictionary] = []
var phase := "countdown"
var countdown := COUNTDOWN
var elapsed := 0.0
var tick := 0
var round_id := 0
var next_hatch := -1
var release_tick := FIRST_RELEASE
var wave := 0
var last_hatch := -1

var _count_ticks := int(COUNTDOWN * HZ)
var _owed := 0.0
var _hatch_bag: Array[int] = []
var _serial := 0

static func pen(slot: int) -> Vector2:
	return Vector2.from_angle(-PI * 0.5 + slot * TAU / SEATS) * PEN_DISTANCE

static func hatch(index: int) -> Vector2:
	return Vector2.from_angle(PI / 6.0 + index * TAU / HATCHES) * HATCH_DISTANCE

static func direction(mask: int) -> Vector2:
	return Vector2(int((mask & 8) != 0) - int((mask & 4) != 0),
		int((mask & 2) != 0) - int((mask & 1) != 0)).normalized()

static func heal_fraction(crit: Dictionary, now: int) -> float:
	return 1.0 - clampf(float(int(crit.recover_tick) - now) / CLAP_RECOVERY, 0.0, 1.0)

func begin(seed_value: int, slots: Array, id: int = 1, _endless: bool = false) -> void:
	rng.seed = seed_value
	round_id = id
	phase = "countdown"
	countdown = COUNTDOWN
	elapsed = 0.0
	tick = 0
	next_hatch = -1
	release_tick = FIRST_RELEASE
	wave = 0
	last_hatch = -1
	_count_ticks = int(COUNTDOWN * HZ)
	_owed = 0.0
	_serial = 0
	_hatch_bag.clear()
	players.clear()
	critters.clear()
	for i in SEATS:
		var seat: Dictionary = slots[i]
		var outward := pen(i).normalized()
		players.append({
			"name": seat.name, "peer": seat.peer, "bot": seat.bot, "active": seat.get("active", true),
			"pos": outward * 6.1, "velocity": Vector2.ZERO, "face": (-outward).angle(),
			"score": 0, "gold": 0, "last_score": NO_TICK, "clap_tick": NO_TICK,
			"clap_face": 0.0, "hits": 0, "claps": 0,
			"input": 0, "queued": false, "target": -1, "replan": 1 + i * 2,
		})
		# Each starting animal has a matching neighbour on every other radial lane.
		var start := outward.rotated(PI / SEATS * 0.48)
		_add_critter(start * 4.4, start.rotated(PI / 2.5), 1, 0)

func remaining() -> float:
	return maxf(0.0, ROUND_TIME - elapsed)

func command(slot: int, action: String, pressed: bool) -> void:
	if slot < 0 or slot >= players.size() or phase == "finished":
		return
	var p := players[slot]
	if not p.active or p.bot:
		return
	if action == "clap":
		if pressed and phase == "running" and tick - int(p.clap_tick) >= CLAP_COOLDOWN:
			p.queued = true
	elif DIRS.has(action):
		var bit: int = DIRS[action]
		p.input = int(p.input) | bit if pressed else int(p.input) & ~bit

func take_over(slot: int) -> void:
	if slot >= 0 and slot < players.size() and players[slot].active:
		var p := players[slot]
		p.bot = true
		p.input = 0
		p.queued = false
		p.replan = tick

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
	var clapping: Array[int] = []
	for i in SEATS:
		var p := players[i]
		if not p.active:
			continue
		var want: Vector2 = _bot_move(i) if p.bot else direction(p.input)
		if not want.is_zero_approx():
			p.face = want.angle()
		p.velocity = p.velocity.move_toward(want * PLAYER_SPEED, PLAYER_ACCEL * STEP)
		p.pos = (p.pos + p.velocity * STEP).limit_length(FIELD_RADIUS)
		if p.queued and tick - int(p.clap_tick) >= CLAP_COOLDOWN:
			p.clap_tick = tick
			p.clap_face = p.face
			p.claps += 1
			clapping.append(i)
		p.queued = false
	_push(clapping)
	_walk_critters()
	_hatch_schedule()
	if tick == ROUND_TICKS:
		phase = "finished"

func _push(clapping: Array[int]) -> void:
	if clapping.is_empty():
		return
	for crit in critters:
		if tick < maxi(crit.recover_tick, crit.launch_tick):
			continue
		var best := -1
		var nearest := CLAP_RANGE * CLAP_RANGE
		# Competing simultaneous claps go to the closest valid cone.
		for slot in clapping:
			var p := players[slot]
			var offset: Vector2 = crit.pos - p.pos
			var length := offset.length_squared()
			if length < 0.0001 or length > nearest:
				continue
			if offset.dot(Vector2.from_angle(p.clap_face)) < sqrt(length) * CLAP_DOT:
				continue
			if length == nearest and best >= 0:
				# Rotate exact ties across the seats.
				if posmod(slot - tick, SEATS) >= posmod(best - tick, SEATS):
					continue
			nearest = length
			best = slot
		if best >= 0:
			var away: Vector2 = players[best].pos.direction_to(crit.pos)
			crit.face = away.angle()
			crit.impulse = away * CLAP_IMPULSE
			crit.recover_tick = tick + CLAP_RECOVERY
			players[best].hits += 1

func _walk_critters() -> void:
	var separation: Array[Vector2] = []
	separation.resize(critters.size())
	separation.fill(Vector2.ZERO)
	for a in critters.size():
		for b in range(a + 1, critters.size()):
			var gap: Vector2 = critters[a].pos - critters[b].pos
			var len_sq := gap.length_squared()
			if len_sq >= 0.76 * 0.76 or len_sq < 0.000001:
				continue
			var distance := sqrt(len_sq)
			var force := gap * (3.0 * (0.76 - distance) / distance)
			separation[a] += force
			separation[b] -= force

	# Iterate backwards so removing a penned critter never skips the next one.
	for i in range(critters.size() - 1, -1, -1):
		var crit := critters[i]
		var at: Vector2 = crit.pos
		var heading := Vector2.from_angle(crit.face)
		var speed := LAUNCH_SPEED
		if tick >= int(crit.launch_tick):
			var pressure := _pressure(at)
			var influence := clampf(pressure.length(), 0.0, 1.0)
			var wanted := heading
			if influence > 0.035:
				wanted = pressure.normalized()
			if at.length_squared() > (FIELD_RADIUS - 0.48) ** 2:
				var outward := at.normalized()
				if influence <= 0.035:
					wanted = -outward.rotated(0.34 if crit.id % 2 else -0.34)
				elif wanted.dot(outward) > -0.12:
					# Slide around the stockyard fence when pressure points into it.
					var tangent := outward.orthogonal()
					var slide := wanted.dot(tangent)
					if absf(slide) < 0.12:
						slide = heading.dot(tangent)
					var side := signf(slide) if absf(slide) > 0.01 else (1.0 if crit.id % 2 else -1.0)
					wanted = (tangent * side - outward * 0.52).normalized()
			var max_turn := (CRITTER_TURN * (0.32 + 0.68 * influence)) * STEP
			if not wanted.is_equal_approx(heading):
				crit.face = rotate_toward(crit.face, wanted.angle(), max_turn)
			heading = Vector2.from_angle(crit.face)
			speed = lerpf(CRITTER_SPEED, HERD_SPEED, influence)
		crit.velocity = heading * speed + crit.impulse + separation[i].limit_length(1.8)
		crit.impulse = crit.impulse.move_toward(Vector2.ZERO, CLAP_DRAG * STEP)
		var end: Vector2 = (at + crit.velocity * STEP).limit_length(FIELD_RADIUS)
		crit.pos = end
		for slot in SEATS:
			var p := players[slot]
			if not p.active:
				continue
			# The center of a critter must touch the marked circular pen.
			var center := pen(slot)
			if Geometry2D.get_closest_point_to_segment(center, at, end).distance_squared_to(center) <= PEN_RADIUS * PEN_RADIUS:
				p.score += crit.value
				p.gold += int(crit.value == 2)
				p.last_score = tick
				critters.remove_at(i)
				break

func _pressure(at: Vector2) -> Vector2:
	var total := Vector2.ZERO
	for p in players:
		if not p.active:
			continue
		var away: Vector2 = at - p.pos
		var length := away.length_squared()
		if length >= PRESSURE_RANGE * PRESSURE_RANGE:
			continue
		if length <= 0.001:
			away = Vector2.from_angle(p.face) * 0.032
			length = away.length_squared()
		var distance := sqrt(length)
		var force := 1.0 - smoothstep(PRESSURE_NEAR, PRESSURE_RANGE, distance)
		total += away * (force / distance)
	return total

func _hatch_schedule() -> void:
	if next_hatch < 0 and tick >= release_tick - HATCH_WARNING and release_tick <= ROUND_TICKS - HZ:
		if critters.size() > MAX_CRITTERS - HERD_SIZE:
			# Reserve capacity before revealing the hatch so an announced herd always arrives.
			release_tick = tick + HATCH_WARNING + 1
			return
		next_hatch = _choose_hatch()
	if next_hatch < 0 or tick < release_tick:
		return
	last_hatch = next_hatch
	next_hatch = -1
	wave += 1
	var at := hatch(last_hatch)
	# Four different lanes fan across the interior before anyone can turn a critter.
	var inward := (-at).angle() + rng.randf_range(-0.30, 0.30)
	var gold := rng.randi_range(0, HERD_SIZE - 1) if wave % 2 == 0 else -1
	for i in HERD_SIZE:
		var lane := Vector2.from_angle(inward + (i - (HERD_SIZE - 1) * 0.5) * 0.75)
		_add_critter(at + lane * 0.33, lane, 2 if i == gold else 1, tick + LAUNCH_TICKS)
	release_tick = tick + RELEASE_INTERVAL

func _choose_hatch() -> int:
	if _hatch_bag.is_empty():
		for i in HATCHES:
			_hatch_bag.append(i)
		for i in range(HATCHES - 1, 0, -1):
			var swap := rng.randi_range(0, i)
			var item := _hatch_bag[i]
			_hatch_bag[i] = _hatch_bag[swap]
			_hatch_bag[swap] = item
		if _hatch_bag.back() == last_hatch:
			var first := _hatch_bag[0]
			_hatch_bag[0] = _hatch_bag.back()
			_hatch_bag[HATCHES - 1] = first
	return _hatch_bag.pop_back()

func _add_critter(at: Vector2, facing: Vector2, value: int, launch: int) -> void:
	_serial += 1
	critters.append({"id": _serial, "pos": at, "face": facing.angle(),
		"velocity": Vector2.ZERO, "impulse": Vector2.ZERO, "value": value,
		"recover_tick": NO_TICK, "launch_tick": launch})

func _bot_move(slot: int) -> Vector2:
	var p := players[slot]
	var goal := pen(slot)
	var target: Dictionary = {}
	if tick >= int(p.replan):
		var best := INF
		for crit in critters:
			if tick < int(crit.launch_tick):
				continue
			var at: Vector2 = crit.pos
			var route := at.direction_to(goal)
			var behind := at - route * BOT_BEHIND
			var cost: float = p.pos.distance_to(behind) + at.distance_to(goal) * 0.52
			cost -= 1.5 * (int(crit.value) - 1) + (1.28 if crit.id == p.target else 0.0)
			if cost < best:
				best = cost
				target = crit
		p.target = target.get("id", -1)
		p.replan = tick + BOT_REPLAN
	else:
		for crit in critters:
			if crit.id == p.target:
				target = crit
				break
	if target.is_empty():
		var rest: Vector2 = goal * 0.55 - p.pos
		return rest.limit_length(1.0)

	var at: Vector2 = target.pos
	var pos: Vector2 = p.pos
	var toward := at.direction_to(goal)
	var offset := pos - at
	var waypoint := at - toward * BOT_BEHIND
	# Circle around the critter before closing in from behind. Avoid accidentally
	# driving it towards the rival's side while approaching from the front.
	var nearest := Geometry2D.get_closest_point_to_segment(at, pos, waypoint)
	if offset.dot(toward) > -0.35 and nearest.distance_to(at) < 1.35:
		var side := signf(toward.cross(offset))
		if is_zero_approx(side):
			side = 1.0 if slot % 2 == 0 else -1.0
		waypoint = at + toward.orthogonal() * side * 2.28 - toward * 0.62
	var move := (waypoint - pos).limit_length(1.0)
	var look := move.normalized() if not move.is_zero_approx() else Vector2.from_angle(p.face)
	var distance := offset.length()
	if distance >= 1.3 and distance <= CLAP_RANGE - 0.18 and at.distance_to(goal) > 2.2:
		var away := -offset / distance
		if away.dot(toward) > 0.96 and look.dot(away) > CLAP_DOT + 0.05 and tick >= int(target.recover_tick):
			p.queued = true
	return move

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

func snapshot() -> Dictionary:
	# 6 fixed player rows, then up to 18 critter rows, all little-endian. IDs
	# persist until penning so clients can interpolate across insertions/removals.
	var rows := PackedByteArray()
	rows.resize(SEATS * PLAYER_ROW + critters.size() * CRITTER_ROW)
	for i in SEATS:
		var p := players[i]
		var o := i * PLAYER_ROW
		_encode_pose(rows, o, p)
		rows.encode_s16(o + 6, p.clap_tick)
		rows.encode_s16(o + 8, _encode_angle(p.clap_face))
		rows.encode_s16(o + 10, p.last_score)
		rows.encode_u8(o + 12, p.score)
		rows.encode_u8(o + 13, p.claps)
		rows.encode_u16(o + 14, p.hits)
		rows.encode_u8(o + 16, p.gold)
		rows.encode_u8(o + 17, int(p.bot))
	for i in critters.size():
		var crit := critters[i]
		var o := SEATS * PLAYER_ROW + CRITTER_ROW * i
		_encode_pose(rows, o, crit)
		rows.encode_u8(o + 6, crit.id)
		rows.encode_u8(o + 7, crit.value)
		rows.encode_s16(o + 8, crit.recover_tick)
		rows.encode_s16(o + 10, crit.launch_tick)
	return {"id": round_id, "tick": tick, "count": _count_ticks, "next": next_hatch,
		"release": release_tick, "wave": wave, "last": last_hatch, "state": rows}

func apply_snapshot(data: Dictionary) -> void:
	var rows: PackedByteArray = data.get("state", PackedByteArray())
	var extra := rows.size() - SEATS * PLAYER_ROW
	if extra < 0 or extra % CRITTER_ROW != 0 or extra > MAX_CRITTERS * CRITTER_ROW:
		return
	_count_ticks = data.count
	countdown = _count_ticks * STEP
	tick = data.tick
	elapsed = tick * STEP
	phase = "countdown" if _count_ticks > 0 else ("finished" if tick >= ROUND_TICKS else "running")
	next_hatch = data.next
	release_tick = data.release
	wave = data.wave
	last_hatch = data.last
	for i in SEATS:
		var p := players[i]
		var o := i * PLAYER_ROW
		_decode_pose(rows, o, p)
		p.clap_tick = rows.decode_s16(o + 6)
		p.clap_face = rows.decode_s16(o + 8) / ANGLE_SCALE
		p.last_score = rows.decode_s16(o + 10)
		p.score = rows.decode_u8(o + 12)
		p.claps = rows.decode_u8(o + 13)
		p.hits = rows.decode_u16(o + 14)
		p.gold = rows.decode_u8(o + 16)
		p.bot = rows.decode_u8(o + 17) > 0
	critters.clear()
	for o in range(SEATS * PLAYER_ROW, rows.size(), CRITTER_ROW):
		var crit := {"id": rows.decode_u8(o + 6), "value": rows.decode_u8(o + 7),
			"recover_tick": rows.decode_s16(o + 8), "launch_tick": rows.decode_s16(o + 10)}
		_decode_pose(rows, o, crit)
		critters.append(crit)

func _encode_pose(rows: PackedByteArray, o: int, entity: Dictionary) -> void:
	rows.encode_s16(o, roundi(float(entity.pos.x) * 512.0))
	rows.encode_s16(o + 2, roundi(float(entity.pos.y) * 512.0))
	rows.encode_s16(o + 4, _encode_angle(entity.face))

func _encode_angle(angle: float) -> int:
	return clampi(roundi(wrapf(angle, -PI, PI) * ANGLE_SCALE), -ANGLE_LIMIT, ANGLE_LIMIT)

func _decode_pose(rows: PackedByteArray, o: int, entity: Dictionary) -> void:
	entity.pos = Vector2(rows.decode_s16(o), rows.decode_s16(o + 2)) / 512.0
	entity.face = rows.decode_s16(o + 4) / ANGLE_SCALE
