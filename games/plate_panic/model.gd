extends RefCounted
## Host-authoritative table simulation. All distances are in board units.

const SEATS := 6
const HZ := 60
const STEP := 1.0 / HZ
const COUNTDOWN := 3.0
const ROUND_TIME := 90
const ROUND_TICKS := ROUND_TIME * HZ
const FIELD_RADIUS := 10.8
const POCKET_DISTANCE := 9.35
const POCKET_RADIUS := 1.26
const MARBLE_RADIUS := 0.31
const MARBLE_COUNT := 10
const WEDGE_LIFE := 120
const WEDGE_COOLDOWN := 153
const WEDGE_RADIUS := 0.88
const WEDGE_OFFSET := 0.72
const WEDGE_POCKET_CLEARANCE := 2.85
const DROP_PREVIEW := 42

const DIRS := {"up": 1, "down": 2, "left": 4, "right": 8}
const PLAYER_SPEED := 6.9
const PLAYER_ACCEL := 40.0
const PLAYER_START_RADIUS := 4.4
const TILT_MASS := 2.15 * FIELD_RADIUS
const TILT_RESPONSE := 4.8
const GRAVITY := 13.0
const ROLL_DRAG := 0.83
const ROLL_SPEED := 8.6
const MARBLE_EDGE := FIELD_RADIUS - MARBLE_RADIUS
const WEDGE_SPEED := 12.4
const WEDGE_GRIP := 33
const WEDGE_MIN_SPEED := 0.45
const DROP_DISTANCE := 2.65
const DROP_CLEARANCE := 1.43
const DROP_SPACING := 24
const DROP_SPEED := 2.8
const STUCK_TICKS := 225
const STUCK_DISTANCE := 1.25
const MAX_STUCK_DROPS := 2
const BOT_REPLAN := 13
const PARKED_LEAN := PLAYER_START_RADIUS + 0.45
const PARKED_RELEASE := PLAYER_START_RADIUS + 0.1
const PARKED_DEEP_START := 7.3
const PARKED_DEEP_FULL := 8.4
const PARKED_TIME := 0.7
const PARKED_TIME_CAP := 1.02
const PARKED_TRAVEL_SPEED := 2.7
const PARKED_SIDEWAYS_CREDIT := 0.35
const BOT_CHALLENGE_START_SCORE := 5
const BOT_CHALLENGE_MARGIN := 4
const BOT_CHALLENGE_PLACE_GAP := HZ
const BOT_CHALLENGE_REDIRECT_GAP := 245
const NO_TICK := -600

const HEADER := 6
const PLAYER_ROW := 25
const MARBLE_ROW := 9
const DROP_ROW := 7
const POSE_SCALE := 512.0
const ANGLE_SCALE := 4096.0
const ANGLE_LIMIT := 12867 # floor(PI * ANGLE_SCALE)
const TILT_SCALE := 16384.0

var players: Array[Dictionary] = []
var marbles: Array[Dictionary] = []
var drops: Array[Dictionary] = []
var tilt := Vector2.ZERO
var phase := "countdown"
var countdown := COUNTDOWN
var elapsed := 0.0
var tick := 0
var round_id := 0

var _rng := RandomNumberGenerator.new()
var _count_ticks := int(COUNTDOWN * HZ)
var _owed := 0.0
var _pockets: Array[Vector2] = []
var _drop_sites: Array[Vector2] = []
var _drop_bag: Array[int] = []
var _last_drop := -1
var _drop_turn := 0.0

static func pocket(slot: int) -> Vector2:
	return Vector2.from_angle(-PI * 0.5 + slot * TAU / SEATS) * POCKET_DISTANCE

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
	tilt = Vector2.ZERO
	_count_ticks = int(COUNTDOWN * HZ)
	_owed = 0.0
	_last_drop = -1
	_drop_bag.clear()
	_drop_sites.clear()
	_pockets.clear()
	players.clear()
	marbles.clear()
	drops.clear()
	var turn := 1.0 if _rng.randi_range(0, 1) == 0 else -1.0
	var start_angle := _rng.randf_range(0.0, TAU)
	var inner_angle := _rng.randf_range(0.0, TAU)
	var drop_angle := _rng.randf_range(0.0, TAU)
	# Spread planning over the frame budget without giving a fixed seat first move.
	var planning_offset := _rng.randi_range(0, SEATS - 1)
	_drop_turn = turn * 0.72
	for i in SEATS:
		var seat: Dictionary = slots[i]
		var goal := pocket(i)
		var outward := goal.normalized()
		_pockets.append(goal)
		# Start near the center so an idle seat puts less weight on its own pocket.
		players.append({
			"name": seat.name, "peer": seat.peer, "bot": seat.bot, "slot": i,
			"pos": outward * PLAYER_START_RADIUS, "velocity": Vector2.ZERO, "face": outward.angle(),
			"score": 0, "last_score": NO_TICK, "wedge_pos": Vector2.ZERO,
			"wedge_face": 0.0, "wedge_tick": NO_TICK, "deflections": 0, "last_deflect": NO_TICK,
			"input": 0, "queued": false, "pressure_time": 0.0, "target": -1, "replan": 1 + posmod(i - planning_offset, SEATS) * 2,
		})
		var lane := Vector2.from_angle(start_angle + i * TAU / SEATS)
		_add_marble(i + 1, lane * 4.75, lane.orthogonal() * (turn * 2.65))
		_drop_sites.append(Vector2.from_angle(drop_angle + i * TAU / SEATS) * DROP_DISTANCE)
	for i in MARBLE_COUNT - SEATS:
		var lane := Vector2.from_angle(inner_angle + i * TAU / (MARBLE_COUNT - SEATS))
		_add_marble(SEATS + i + 1, lane * 1.14, lane.orthogonal() * (-turn * 2.05))

func remaining() -> float:
	return maxf(0.0, ROUND_TIME - elapsed)

func command(slot: int, action: String, pressed: bool) -> void:
	if slot < 0 or slot >= players.size() or phase == "finished":
		return
	var p := players[slot]
	if p.bot:
		return
	if action == "wedge":
		if pressed and phase == "running" and tick + 1 - int(p.wedge_tick) >= WEDGE_COOLDOWN:
			p.queued = true
	elif DIRS.has(action):
		var bit: int = DIRS[action]
		p.input = int(p.input) | bit if pressed else int(p.input) & ~bit

func take_over(slot: int) -> void:
	if slot < 0 or slot >= players.size() or phase == "finished":
		return
	var p := players[slot]
	p.bot = true
	p.input = 0
	p.queued = false
	p.target = -1
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
	var mass := Vector2.ZERO
	var wedges: Array[Dictionary] = []
	var parked := _parked_rival()
	# Use the round's rotation to choose either flank without favoring one side.
	var flank := 4 if _drop_turn > 0.0 else 2
	for i in SEATS:
		var p := players[i]
		var before: Vector2 = p.pos
		var want := direction(p.input)
		if p.bot:
			var offset := posmod(i - parked, SEATS)
			if parked >= 0 and (offset == 3 or offset == flank):
				want = (_pockets[i].normalized() * FIELD_RADIUS - before).limit_length()
			else:
				want = _bot_move(i)
		if want.length_squared() > 0.0001:
			p.face = want.angle()
		p.velocity = Vector2(p.velocity).move_toward(want * PLAYER_SPEED, PLAYER_ACCEL * STEP)
		p.pos = (p.pos + p.velocity * STEP).limit_length(FIELD_RADIUS)
		if not p.bot:
			# Travel across the lane eases pressure less than changing the lean
			# along its axis. Deep in the lane, movement leaves the cup loaded.
			var pressure := _pocket_pressure(i)
			if pressure >= PARKED_LEAN:
				var travel_weight := 1.0 - smoothstep(PARKED_DEEP_START, PARKED_DEEP_FULL, pressure)
				var axial_travel := absf(pressure - before.dot(_pockets[i].normalized()))
				var travel := lerpf(axial_travel, before.distance_to(p.pos), PARKED_SIDEWAYS_CREDIT)
				var still_time := STEP - travel * travel_weight / PARKED_TRAVEL_SPEED
				p.pressure_time = clampf(float(p.pressure_time) + still_time, 0.0, PARKED_TIME_CAP)
			elif pressure < PARKED_RELEASE:
				p.pressure_time = maxf(0.0, float(p.pressure_time) - 2.0 * STEP)
		mass += p.pos
		if p.queued:
			_place_wedge(p)
			p.queued = false
		var age := tick - int(p.wedge_tick)
		if age >= 0 and age < WEDGE_LIFE:
			wedges.append(p)
	var slope := (mass / TILT_MASS).limit_length()
	tilt = tilt.lerp(slope, 1.0 - exp(-TILT_RESPONSE * STEP))
	if tilt.length_squared() < 0.000000000001:
		tilt = Vector2.ZERO
	_roll_marbles(wedges)
	_release_drops()
	if tick == ROUND_TICKS:
		phase = "finished"

func _place_wedge(p: Dictionary) -> void:
	if tick - int(p.wedge_tick) < WEDGE_COOLDOWN:
		return
	var at: Vector2 = p.pos + Vector2.from_angle(p.face) * WEDGE_OFFSET
	if not wedge_site_open(at):
		return
	p.wedge_pos = at
	p.wedge_face = p.face
	p.wedge_tick = tick

func wedge_site_open(at: Vector2) -> bool:
	if at.length_squared() > (MARBLE_EDGE - WEDGE_RADIUS) ** 2:
		return false
	for center in _pockets:
		if at.distance_squared_to(center) < WEDGE_POCKET_CLEARANCE ** 2:
			return false
	for center in _drop_sites:
		if at.distance_squared_to(center) < DROP_CLEARANCE ** 2:
			return false
	return true

func _add_marble(id: int, at: Vector2, speed: Vector2) -> void:
	marbles.append({"id": id, "pos": at, "velocity": speed, "grip_until": NO_TICK, "stall_origin": at, "stalled": 0})

func _roll_marbles(wedges: Array[Dictionary]) -> void:
	var starts: Array[Vector2] = []
	for marble in marbles:
		var at: Vector2 = marble.pos
		starts.append(at)
		# A routed marble briefly keeps its new heading even against a full slope.
		var guided := tick < int(marble.get("grip_until", NO_TICK))
		var accel := tilt * GRAVITY * (0.16 if guided else 1.0)
		var drag := 0.33 if guided else ROLL_DRAG
		var speed: Vector2 = (marble.velocity + accel * STEP) * (1.0 - drag * STEP)
		# Let a fast shot coast after the guide ends instead of snapping to roll speed.
		var cap := maxf(ROLL_SPEED, Vector2(marble.velocity).length() * (1.0 - drag * STEP))
		speed = speed.limit_length(cap)
		var end := at + speed * STEP
		if not guided and speed.length_squared() >= WEDGE_MIN_SPEED ** 2:
			var hit := _first_wedge(at, end, wedges)
			if not hit.is_empty():
				var wedge: Dictionary = hit.wedge
				var fraction: float = hit.fraction
				speed = Vector2.from_angle(wedge.wedge_face) * WEDGE_SPEED
				end = at.lerp(end, fraction) + speed * (STEP * (1.0 - fraction))
				marble.grip_until = tick + WEDGE_GRIP
				wedge.deflections += 1
				wedge.last_deflect = tick
		marble.pos = end
		marble.velocity = speed
	_collide_marbles()

	var stuck_drops := drops.size()
	for i in range(marbles.size() - 1, -1, -1):
		var marble := marbles[i]
		var at := starts[i]
		var end := Vector2(marble.pos).limit_length(MARBLE_EDGE)
		if end != marble.pos:
			var outward := end.normalized()
			var speed: Vector2 = marble.velocity
			marble.velocity = speed - outward * maxf(speed.dot(outward), 0.0) * 1.14
		marble.pos = end
		var scored := false
		for slot in SEATS:
			if Geometry2D.get_closest_point_to_segment(_pockets[slot], at, end).distance_squared_to(_pockets[slot]) <= POCKET_RADIUS ** 2:
				players[slot].score += 1
				players[slot].last_score = tick
				scored = true
				break
		# Measure progress over a patch, so rattling against the rim counts as stuck.
		var anchor: Vector2 = marble.get("stall_origin", at)
		if anchor.distance_squared_to(end) >= STUCK_DISTANCE ** 2:
			marble.stall_origin = end
			marble.stalled = 0
		else:
			marble.stalled = int(marble.get("stalled", 0)) + 1
		var stuck := int(marble.stalled) >= STUCK_TICKS and stuck_drops < MAX_STUCK_DROPS
		if scored or stuck:
			stuck_drops += 1
			marbles.remove_at(i)
			_queue_drop(marble.id)

func _first_wedge(at: Vector2, end: Vector2, wedges: Array[Dictionary]) -> Dictionary:
	var travel := end - at
	var travel_sq := travel.length_squared()
	var first := 2.0
	var winner: Dictionary = {}
	for wedge in wedges:
		var offset: Vector2 = at - wedge.wedge_pos
		var outside := offset.length_squared() - WEDGE_RADIUS ** 2
		var projection := offset.dot(travel)
		var discriminant := projection ** 2 - travel_sq * outside
		# Placement under a marble cannot fire it. A roll has to enter from outside.
		if outside <= 0.0 or projection >= 0.0 or discriminant < 0.0:
			continue
		var fraction := (-projection - sqrt(discriminant)) / travel_sq
		if fraction > 1.0 or fraction > first:
			continue
		if fraction == first:
			# Exact overlaps go to the most recent placement, then rotate seat priority.
			if wedge.wedge_tick < winner.wedge_tick:
				continue
			if wedge.wedge_tick == winner.wedge_tick and posmod(wedge.slot - tick, SEATS) >= posmod(winner.slot - tick, SEATS):
				continue
		first = fraction
		winner = wedge
	return {} if winner.is_empty() else {"wedge": winner, "fraction": first}

func _collide_marbles() -> void:
	for i in marbles.size():
		var a := marbles[i]
		for j in range(i + 1, marbles.size()):
			var b := marbles[j]
			var away: Vector2 = b.pos - a.pos
			var gap_sq := away.length_squared()
			if gap_sq >= (2.0 * MARBLE_RADIUS) ** 2:
				continue
			var gap := sqrt(gap_sq)
			var relative: Vector2 = a.velocity - b.velocity
			var normal := away / gap if gap > 0.00001 else relative.normalized()
			if normal.is_zero_approx():
				normal = Vector2(a.pos).normalized().orthogonal()
			if normal.is_zero_approx():
				normal = Vector2.RIGHT.rotated(_drop_turn)
			var overlap := normal * ((2.0 * MARBLE_RADIUS - gap) * 0.5)
			a.pos -= overlap
			b.pos += overlap
			var impulse := normal * (maxf(0.0, relative.dot(normal)) * 0.83)
			a.velocity -= impulse
			b.velocity += impulse

func _queue_drop(id: int) -> void:
	if _drop_bag.is_empty():
		for i in SEATS:
			_drop_bag.append(i)
		for i in range(SEATS - 1, 0, -1):
			var j := _rng.randi_range(0, i)
			var site := _drop_bag[j]
			_drop_bag[j] = _drop_bag[i]
			_drop_bag[i] = site
		# Cycle through all six equivalent lanes before reusing one.
		if _drop_bag.back() == _last_drop:
			_drop_bag[SEATS - 1] = _drop_bag[0]
			_drop_bag[0] = _last_drop
	_last_drop = _drop_bag.pop_back()
	var at := _drop_sites[_last_drop]
	var due := tick + DROP_PREVIEW
	for drop in drops:
		if drop.pos == at:
			due = maxi(due, int(drop.tick) + DROP_SPACING)
	drops.append({"id": id, "pos": at, "tick": due})

func _release_drops() -> void:
	var i := 0
	while i < drops.size():
		var drop := drops[i]
		if tick < int(drop.tick):
			i += 1
			continue
		var at: Vector2 = drop.pos
		_add_marble(drop.id, at, at.normalized().rotated(_drop_turn) * DROP_SPEED)
		drops.remove_at(i)

func _parked_rival() -> int:
	var best_cpu := 0
	for p in players:
		if p.bot:
			best_cpu = maxi(best_cpu, p.score)
	var challenge_score := maxi(BOT_CHALLENGE_START_SCORE, best_cpu - BOT_CHALLENGE_MARGIN)
	var strongest := PARKED_RELEASE
	var parked := -1
	for rival in players:
		if rival.bot:
			continue
		# Give a new wedge time to catch a roll. A contact buys more time.
		var recent_wedge := (tick - int(rival.wedge_tick) <= BOT_CHALLENGE_PLACE_GAP
			or tick - int(rival.last_deflect) <= BOT_CHALLENGE_REDIRECT_GAP)
		var scoring_threat := int(rival.score) >= challenge_score and not recent_wedge
		if not scoring_threat and float(rival.pressure_time) < PARKED_TIME:
			continue
		var pressure := _pocket_pressure(rival.slot)
		if pressure >= strongest:
			strongest = pressure
			parked = rival.slot
	return parked

func _pocket_pressure(slot: int) -> float:
	return Vector2(players[slot].pos).dot(_pockets[slot].normalized())

func _bot_move(slot: int) -> Vector2:
	var p := players[slot]
	var goal := _pockets[slot]
	var pos: Vector2 = p.pos
	var target: Dictionary = {}
	var ready := tick - int(p.wedge_tick) >= WEDGE_COOLDOWN
	if ready:
		# Face the pocket just as an incoming roll is about to cross the catch zone.
		var shot := pos.direction_to(goal)
		var next_speed := Vector2(p.velocity).move_toward(shot * PLAYER_SPEED, PLAYER_ACCEL * STEP)
		var site := (pos + next_speed * STEP).limit_length(FIELD_RADIUS) + shot * WEDGE_OFFSET
		if site.distance_squared_to(goal) < 8.2 ** 2 and wedge_site_open(site):
			for marble in marbles:
				var at: Vector2 = marble.pos
				if int(marble.grip_until) > tick or at.distance_squared_to(site) <= WEDGE_RADIUS ** 2:
					continue
				var future := _predict_roll(marble, 0.41)
				if Geometry2D.get_closest_point_to_segment(site, at, future).distance_squared_to(site) < (WEDGE_RADIUS * 0.87) ** 2:
					p.queued = true
					return shot
	if tick >= int(p.replan):
		var best := INF
		for marble in marbles:
			var waypoint := _bot_intercept(marble, pos, goal)
			if waypoint == Vector2.INF:
				continue
			var cost := pos.distance_to(waypoint) + waypoint.distance_to(goal) * 0.80
			if int(marble.id) == int(p.target):
				cost -= 0.65
			if cost < best:
				best = cost
				target = marble
			p.target = target.get("id", -1)
		p.replan = tick + BOT_REPLAN
	else:
		for marble in marbles:
			if marble.id == p.target:
				target = marble
				break
	if not target.is_empty():
		var waypoint := _bot_intercept(target, pos, goal)
		if waypoint != Vector2.INF:
			return (waypoint - pos).limit_length()
	# Lean hardest when there is a short lane to this pocket. Equal, static
	# fallback positions would leave central marbles with no downhill route.
	var nearest := 12.0
	for marble in marbles:
		nearest = minf(nearest, goal.distance_to(marble.pos))
	var lean := lerpf(0.99, 0.61, smoothstep(6.0, 10.5, nearest))
	return (goal * lean - pos).limit_length()

func _bot_intercept(marble: Dictionary, pos: Vector2, goal: Vector2) -> Vector2:
	var result := Vector2.INF
	var best := INF
	for lead: float in [0.27, 0.56, 0.89]:
		var site := _predict_roll(marble, lead)
		var range_sq := site.distance_squared_to(goal)
		if range_sq > 8.65 ** 2 or not wedge_site_open(site):
			continue
		var waypoint := site - site.direction_to(goal) * WEDGE_OFFSET
		var distance := pos.distance_to(waypoint)
		var cost := maxf(0.0, distance - lead * PLAYER_SPEED) + distance * 0.45 + sqrt(range_sq) * 0.25
		if cost < best:
			best = cost
			result = waypoint
	return result

func _predict_roll(marble: Dictionary, lead: float) -> Vector2:
	var at: Vector2 = marble.pos
	var speed: Vector2 = marble.velocity
	var drag := 1.0 - exp(-ROLL_DRAG * lead)
	var future_speed := (speed * (1.0 - drag) + tilt * (GRAVITY / ROLL_DRAG) * drag).limit_length(ROLL_SPEED)
	return (at + (speed + future_speed) * (lead * 0.5)).limit_length(MARBLE_EDGE)

func ranking() -> Array:
	var order := range(players.size())
	order.sort_custom(func(a, b):
		return players[a].score > players[b].score if players[a].score != players[b].score else a < b)
	return order

func winners() -> Array:
	var order := ranking()
	if order.is_empty():
		return []
	return order.filter(func(i): return players[i].score == players[order[0]].score)

func snapshot() -> Dictionary:
	# Little-endian display state. Score, event ticks and IDs are lossless.
	var rows := PackedByteArray()
	rows.resize(HEADER + SEATS * PLAYER_ROW + marbles.size() * MARBLE_ROW + drops.size() * DROP_ROW)
	rows.encode_u8(0, marbles.size())
	rows.encode_u8(1, drops.size())
	_encode_vector(rows, 2, tilt, TILT_SCALE, false)
	var o := HEADER
	for p in players:
		_encode_vector(rows, o, p.pos, POSE_SCALE)
		_encode_vector(rows, o + 4, p.velocity, POSE_SCALE)
		rows.encode_s16(o + 8, _encode_angle(p.face))
		_encode_vector(rows, o + 10, p.wedge_pos, POSE_SCALE)
		rows.encode_s16(o + 14, _encode_angle(p.wedge_face))
		rows.encode_s16(o + 16, p.wedge_tick)
		rows.encode_s16(o + 18, p.last_score)
		rows.encode_u16(o + 20, p.score)
		rows.encode_u16(o + 22, p.deflections)
		rows.encode_u8(o + 24, int(p.bot))
		o += PLAYER_ROW
	for marble in marbles:
		rows.encode_u8(o, marble.id)
		_encode_vector(rows, o + 1, marble.pos, POSE_SCALE)
		_encode_vector(rows, o + 5, marble.velocity, POSE_SCALE)
		o += MARBLE_ROW
	for drop in drops:
		rows.encode_u8(o, drop.id)
		_encode_vector(rows, o + 1, drop.pos, POSE_SCALE)
		rows.encode_u16(o + 5, drop.tick)
		o += DROP_ROW
	return {"id": round_id, "tick": tick, "count": _count_ticks, "state": rows}

func apply_snapshot(data: Dictionary) -> void:
	var raw: Variant = data.get("state")
	if not raw is PackedByteArray or players.size() != SEATS:
		return
	var rows: PackedByteArray = raw
	if rows.size() < HEADER + SEATS * PLAYER_ROW:
		return
	var marble_count := rows.decode_u8(0)
	var drop_count := rows.decode_u8(1)
	if marble_count + drop_count > MARBLE_COUNT or rows.size() != HEADER + SEATS * PLAYER_ROW + marble_count * MARBLE_ROW + drop_count * DROP_ROW:
		return
	var next_tick: Variant = data.get("tick")
	var next_count: Variant = data.get("count")
	var id: Variant = data.get("id")
	if not (id is int and next_tick is int and next_count is int):
		return
	if next_tick < 0 or next_tick > ROUND_TICKS or next_count < 0 or next_count > COUNTDOWN * HZ:
		return
	round_id = id
	_count_ticks = next_count
	countdown = _count_ticks * STEP
	tick = next_tick
	elapsed = tick * STEP
	phase = "countdown" if _count_ticks > 0 else ("finished" if tick == ROUND_TICKS else "running")
	tilt = _decode_vector(rows, 2, TILT_SCALE)
	var o := HEADER
	for p in players:
		p.pos = _decode_vector(rows, o, POSE_SCALE)
		p.velocity = _decode_vector(rows, o + 4, POSE_SCALE)
		p.face = rows.decode_s16(o + 8) / ANGLE_SCALE
		p.wedge_pos = _decode_vector(rows, o + 10, POSE_SCALE)
		p.wedge_face = rows.decode_s16(o + 14) / ANGLE_SCALE
		p.wedge_tick = rows.decode_s16(o + 16)
		p.last_score = rows.decode_s16(o + 18)
		p.score = rows.decode_u16(o + 20)
		p.deflections = rows.decode_u16(o + 22)
		p.bot = rows.decode_u8(o + 24) != 0
		o += PLAYER_ROW
	marbles.clear()
	for i in marble_count:
		_add_marble(rows.decode_u8(o), _decode_vector(rows, o + 1, POSE_SCALE), _decode_vector(rows, o + 5, POSE_SCALE))
		o += MARBLE_ROW
	drops.clear()
	for i in drop_count:
		drops.append({"id": rows.decode_u8(o), "pos": _decode_vector(rows, o + 1, POSE_SCALE), "tick": rows.decode_u16(o + 5)})
		o += DROP_ROW

func _encode_vector(rows: PackedByteArray, o: int, value: Vector2, scale: float, nearest: bool = true) -> void:
	rows.encode_s16(o, roundi(value.x * scale) if nearest else int(value.x * scale))
	rows.encode_s16(o + 2, roundi(value.y * scale) if nearest else int(value.y * scale))

func _decode_vector(rows: PackedByteArray, o: int, scale: float) -> Vector2:
	return Vector2(rows.decode_s16(o), rows.decode_s16(o + 2)) / scale

func _encode_angle(angle: float) -> int:
	return clampi(roundi(wrapf(angle, -PI, PI) * ANGLE_SCALE), -ANGLE_LIMIT, ANGLE_LIMIT)
