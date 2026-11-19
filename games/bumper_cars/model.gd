extends RefCounted
## The host drives every car in a flat XZ simulation. The arena animates the
## falling cars and platforms from the same timers sent to guests.

const ID := "bumper_cars"
const SEATS := 6
const ROUND_TIME := 102.0
const COUNTDOWN := 3.0
const RADII := [14.0, 11.7, 9.4, 7.1, 4.9, 2.9]
const DROP_TIMES := [22.0, 42.0, 60.0, 76.0, 89.0]
const WARN_TIME := 4.0
const BODY_RADIUS := 0.85
const BOOST_COOLDOWN := 3.6
const FALL_DURATION := 1.4
const BOT_NAMES := ["Clutch", "Skid", "Torque", "Axle", "Sparky", "Buckle"]

const MAX_STEP := 1.0 / 60.0
const SPEED := 7.8
const ACCEL := 15.0
const DRAG := 5.0
const TURN_SPEED := 9.0
const BOOST_SPEED := 14.0
const BOOST_TIME := 0.29
const SHOVE_WINDOW := 2.0
const MAX_SPEED := 18.0

const SNAP_FLOATS := 9
const SNAP_INTS := 3

var rng := RandomNumberGenerator.new()
var players: Array = []
var phase := "countdown"
var countdown := COUNTDOWN
var elapsed := 0.0
var round_id := 0
var ring_level := 0
var hit_count := 0
var boost_count := 0

func begin(seed_value: int, slots: Array, id: int = 1, _endless: bool = false) -> void:
	rng.seed = seed_value
	round_id = id
	phase = "countdown"
	countdown = COUNTDOWN
	elapsed = 0.0
	ring_level = 0
	hit_count = 0
	boost_count = 0
	players.clear()
	var rotation := rng.randf_range(-PI, PI)
	for i in SEATS:
		var seat: Dictionary = slots[i]
		var pos := Vector2.from_angle(rotation + i * TAU / SEATS) * 8.6
		players.append({
			"name": seat.name, "peer": seat.peer, "bot": seat.bot,
			"pos": pos, "velocity": Vector2.ZERO, "heading": atan2(-pos.x, pos.y),
			"alive": true, "fall_time": 0.0, "kos": 0, "survived": 0.0,
			"cooldown": 0.0, "boost": 0.0,
			"_left": false, "_right": false, "_up": false, "_down": false,
			"_hit_by": -1, "_hit_at": -SHOVE_WINDOW, "_target": -1, "_think": 0.0,
			"_weave": rng.randf_range(-1.0, 1.0), "_bold": false,
		})

func command(slot: int, action: String, pressed: bool) -> void:
	if slot < 0 or slot >= players.size() or phase == "finished":
		return
	var p: Dictionary = players[slot]
	if p.bot or not p.alive:
		return
	match action:
		"left", "right", "up", "down":
			p["_" + action] = pressed
		"dash":
			if pressed and phase == "running":
				_start_boost(p, _held(p))

func _held(p: Dictionary) -> Vector2:
	return Vector2(int(p._right) - int(p._left), int(p._down) - int(p._up)).normalized()

func _start_boost(p: Dictionary, direction: Vector2) -> void:
	if float(p.cooldown) > 0.0:
		return
	var heading: float = p.heading
	if direction == Vector2.ZERO:
		direction = Vector2(sin(heading), -cos(heading))
	else:
		p.heading = atan2(direction.x, -direction.y)
	p.velocity = (direction * 11.6 + p.velocity * 0.24).limit_length(BOOST_SPEED)
	p.boost = BOOST_TIME
	p.cooldown = BOOST_COOLDOWN
	boost_count += 1

func step(delta: float) -> void:
	if delta <= 0.0:
		return
	if phase == "finished":
		_advance_falls(delta)
		return
	if phase == "countdown":
		countdown = maxf(0.0, countdown - delta)
		if countdown <= 0.000001:
			countdown = 0.0
			phase = "running"
		return
	while delta > 0.000001 and phase == "running":
		var dt := minf(delta, MAX_STEP)
		delta -= dt
		_tick(dt)

func _tick(dt: float) -> void:
	elapsed = minf(ROUND_TIME, elapsed + dt)
	_advance_falls(dt)
	while ring_level < DROP_TIMES.size() and elapsed + 0.000001 >= DROP_TIMES[ring_level]:
		ring_level += 1
		_check_edge(false)

	var inputs: Array[Vector2] = []
	for i in players.size():
		var p: Dictionary = players[i]
		inputs.append(_bot_input(i) if p.alive and p.bot else _held(p))
	for i in players.size():
		var p: Dictionary = players[i]
		if p.alive:
			p.survived = elapsed
			_drive(p, inputs[i], dt)
	for i in players.size():
		if not players[i].alive:
			continue
		for j in range(i + 1, players.size()):
			if players[j].alive:
				_collide(i, j)
	_check_edge(true)
	if elapsed >= ROUND_TIME or alive_count() <= 1:
		phase = "finished"

func _drive(p: Dictionary, want: Vector2, dt: float) -> void:
	var heading: float = p.heading
	var velocity: Vector2 = p.velocity
	if float(p.boost) > 0.0:
		var forward := Vector2(sin(heading), -cos(heading))
		velocity = velocity.move_toward(forward * BOOST_SPEED, ACCEL * dt)
		p.boost = maxf(0.0, float(p.boost) - dt)
	elif want != Vector2.ZERO:
		p.heading = rotate_toward(heading, atan2(want.x, -want.y), TURN_SPEED * dt)
		velocity = velocity.move_toward(want * SPEED, ACCEL * dt)
	else:
		velocity = velocity.move_toward(Vector2.ZERO, DRAG * dt)
	p.velocity = velocity
	p.pos += velocity * dt
	p.cooldown = maxf(0.0, float(p.cooldown) - dt)

func _collide(i: int, j: int) -> void:
	var a: Dictionary = players[i]
	var b: Dictionary = players[j]
	var offset: Vector2 = b.pos - a.pos
	var gap := BODY_RADIUS * 2.0
	if offset.length_squared() >= gap * gap:
		return
	var distance := offset.length()
	var normal := offset / distance if distance > 0.0001 else Vector2.RIGHT
	var separation := normal * (gap - distance) * 0.5
	a.pos -= separation
	b.pos += separation
	var va: Vector2 = a.velocity
	var vb: Vector2 = b.velocity
	var attack_a := va.dot(normal)
	var attack_b := -vb.dot(normal)
	var closing := attack_a + attack_b
	if closing <= 0.0:
		return
	var impulse := closing * 0.73
	var boost_a: bool = float(a.boost) > 0.0 and attack_a > 4.0
	var boost_b: bool = float(b.boost) > 0.0 and attack_b > 4.0
	a.velocity = (va - normal * (impulse + (4.0 if boost_b else 0.0))).limit_length(MAX_SPEED)
	b.velocity = (vb + normal * (impulse + (4.0 if boost_a else 0.0))).limit_length(MAX_SPEED)
	if boost_a:
		a.boost = 0.0
	if boost_b:
		b.boost = 0.0
	if closing >= 1.6:
		hit_count += 1
	if impulse >= 2.6:
		if attack_a > 1.2:
			b._hit_by = i
			b._hit_at = elapsed
		if attack_b > 1.2:
			a._hit_by = j
			a._hit_at = elapsed

func _check_edge(credit_shove: bool) -> void:
	var radius_sq := safe_radius() * safe_radius()
	for p in players:
		if not p.alive or Vector2(p.pos).length_squared() <= radius_sq:
			continue
		p.alive = false
		p.survived = elapsed
		p.boost = 0.0
		if credit_shove and int(p._hit_by) >= 0 and elapsed - float(p._hit_at) <= SHOVE_WINDOW:
			players[int(p._hit_by)].kos += 1

func _advance_falls(dt: float) -> void:
	for p in players:
		if p.alive or float(p.fall_time) >= FALL_DURATION:
			continue
		var fall_step := minf(dt, FALL_DURATION - float(p.fall_time))
		var decay := exp(-4.0 * fall_step)
		p.pos += p.velocity * ((1.0 - decay) * 0.25)
		p.velocity *= decay
		p.fall_time = float(p.fall_time) + fall_step

## Look ahead far enough to brake before open water. As soon as a ring
## flashes, bots plan around the smaller disk but may still get shoved out.
func _bot_input(slot: int) -> Vector2:
	var p: Dictionary = players[slot]
	var pos: Vector2 = p.pos
	var vel: Vector2 = p.velocity
	var radius: float = RADII[ring_level + (1 if warning() else 0)]
	var margin := clampf(radius * 0.24, 0.65, 3.4)
	var outward := maxf(0.0, vel.dot(pos.normalized()))
	var braking_distance := outward * (0.13 + outward / (2.0 * ACCEL))
	if pos.length() + braking_distance > radius - margin or (pos + vel * 0.29).length() > radius - margin:
		return -pos.normalized()
	if elapsed >= float(p._think):
		_plan_attack(slot, radius)
	var other: int = p._target
	if other < 0 or not players[other].alive:
		# Give a car something to do between targets and while the edge clears.
		return (Vector2.from_angle(elapsed * 0.65 + slot) * radius * 0.38 - pos).normalized()
	var target: Dictionary = players[other]
	var lead: Vector2 = target.pos + target.velocity * 0.18
	var offset := lead - pos
	var weave := offset.normalized().orthogonal() * float(p._weave) * minf(2.0, offset.length() * 0.3)
	var aim := (lead + weave).limit_length(radius - margin)
	var direction := (aim - pos).normalized()
	var charge_end := pos + direction * (BOOST_SPEED * BOOST_TIME + minf(4.0, radius * 0.34))
	if p._bold and float(p.cooldown) <= 0.0 and offset.length() < 5.5 \
			and direction.dot(offset.normalized()) > 0.8 and charge_end.length() < radius - 0.4:
		_start_boost(p, direction)
		p._bold = false
	return direction

func _plan_attack(slot: int, radius: float) -> void:
	var p: Dictionary = players[slot]
	p._think = elapsed + rng.randf_range(0.25, 0.55)
	p._bold = rng.randf() < lerpf(0.16, 0.72, float(ring_level) / DROP_TIMES.size())
	p._target = -1
	var best := INF
	for i in players.size():
		if i == slot or not players[i].alive:
			continue
		var target_pos: Vector2 = players[i].pos
		var edge_penalty := maxf(0.0, target_pos.length() - radius + 0.7) * 4.0
		var cost := Vector2(p.pos).distance_to(target_pos) + edge_penalty + rng.randf_range(0.0, 2.4)
		if cost < best:
			best = cost
			p._target = i

func safe_radius() -> float:
	return RADII[ring_level]

func warning() -> bool:
	return phase == "running" and ring_level < DROP_TIMES.size() and elapsed >= DROP_TIMES[ring_level] - WARN_TIME

func remaining() -> float:
	return maxf(0.0, ROUND_TIME - elapsed)

func alive_count() -> int:
	var count := 0
	for p in players:
		if p.alive:
			count += 1
	return count

func take_over(slot: int) -> void:
	if slot < 0 or slot >= players.size():
		return
	var p: Dictionary = players[slot]
	if p.bot:
		return
	p.bot = true
	p.peer = 0
	p.name = str(p.name).left(12) + " · BOT"
	p._left = false
	p._right = false
	p._up = false
	p._down = false
	p._think = elapsed

## Surviving cars lead, with knockouts breaking a timeout. Cars that fell
## place by survival time, so a shared final fall can be a draw.
func _compare(a: Dictionary, b: Dictionary) -> int:
	if a.alive != b.alive:
		return 1 if a.alive else -1
	if a.alive:
		return int(a.kos) - int(b.kos)
	return roundi(float(a.survived) * 1000.0) - roundi(float(b.survived) * 1000.0)

func ranking() -> Array:
	var order := range(players.size())
	order.sort_custom(func(a, b):
		var result := _compare(players[a], players[b])
		return a < b if result == 0 else result > 0)
	return order

func winners() -> Array:
	var order := ranking()
	if order.is_empty():
		return []
	var best: Dictionary = players[order[0]]
	return order.filter(func(i): return _compare(players[i], best) == 0)

## Parallel arrays carry all presentation and ranking state without the
## repeating Dictionary keys or the host-only controls and bot plans.
func snapshot() -> Dictionary:
	var names := PackedStringArray()
	var cars := PackedFloat32Array()
	var seats := PackedInt32Array()
	for p in players:
		names.append(p.name)
		cars.append_array(PackedFloat32Array([
			p.pos.x, p.pos.y, p.velocity.x, p.velocity.y, p.heading,
			p.fall_time, p.survived, p.cooldown, p.boost,
		]))
		seats.append_array(PackedInt32Array([p.peer, p.kos, int(p.alive) | (int(p.bot) << 1)]))
	return {"id": round_id, "game": ID, "phase": phase, "countdown": countdown, "elapsed": elapsed,
		"ring_level": ring_level, "hit_count": hit_count, "boost_count": boost_count,
		"names": names, "cars": cars, "seats": seats}

func apply_snapshot(data: Dictionary) -> void:
	if int(data.get("id", -1)) != round_id or data.get("game") != ID:
		return
	if not (data.get("names") is PackedStringArray and data.get("cars") is PackedFloat32Array
			and data.get("seats") is PackedInt32Array and data.get("phase") is String
			and data.get("countdown") is float and data.get("elapsed") is float):
		return
	var names: PackedStringArray = data.names
	var cars: PackedFloat32Array = data.cars
	var seats: PackedInt32Array = data.seats
	if names.size() != players.size() or cars.size() != players.size() * SNAP_FLOATS \
			or seats.size() != players.size() * SNAP_INTS:
		return
	phase = data.phase
	countdown = data.countdown
	elapsed = data.elapsed
	ring_level = clampi(int(data.get("ring_level", 0)), 0, DROP_TIMES.size())
	hit_count = int(data.get("hit_count", 0))
	boost_count = int(data.get("boost_count", 0))
	for i in players.size():
		var p: Dictionary = players[i]
		var at := i * SNAP_FLOATS
		var seat := i * SNAP_INTS
		p.name = names[i]
		p.peer = seats[seat]
		p.kos = seats[seat + 1]
		p.alive = (seats[seat + 2] & 1) != 0
		p.bot = (seats[seat + 2] & 2) != 0
		p.pos = Vector2(cars[at], cars[at + 1])
		p.velocity = Vector2(cars[at + 2], cars[at + 3])
		p.heading = cars[at + 4]
		p.fall_time = cars[at + 5]
		p.survived = cars[at + 6]
		p.cooldown = cars[at + 7]
		p.boost = cars[at + 8]
