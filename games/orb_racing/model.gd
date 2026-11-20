extends RefCounted
## Host-authoritative fixed-tick simulation. Positions are in Track's screen
## plane. Guests consume snapshots for display and never step the simulation.

const Track = preload("res://games/orb_racing/track.gd")
const SEATS := 6
const LAPS := 3
const COUNTDOWN := 3.0
const ROUND_TIME := 100.0
const FINISH_WINDOW := 12.0
const HZ := 60
const DT := 1.0 / HZ
const SPEED := 8.30
const GRASS_SPEED := 4.3
const ACCEL := 16.0
const BOOST_SPEED := 12.60
const BOOST_TIME := 0.72
const MAX_CHARGES := 2
const BOT_NAMES := ["Comet", "Ripple", "Flint", "Nova", "Orbit", "Drift"]

const INPUT_BITS := {"left": 1, "right": 2, "up": 4, "down": 8}
const PHASES := ["countdown", "running", "finished"]
const ROW_SIZE := 13
const EPS := 0.0000001
const PAD_BOUNDS := Rect2(-Track.PAD_HALF_LENGTH, -Track.PAD_HALF_WIDTH,
	2.0 * Track.PAD_HALF_LENGTH, 2.0 * Track.PAD_HALF_WIDTH)

var track := Track.new()
var rng := RandomNumberGenerator.new()
var players: Array[Dictionary] = []
var active_count := SEATS
var phase := "countdown"
var countdown := COUNTDOWN
var elapsed := 0.0
var round_id := 0
var first_finish := -1.0
var _accumulator := 0.0
var _ready_ticks := 0


func begin(seed_value: int, slots: Array, id: int = 1, _endless: bool = false) -> void:
	rng.seed = seed_value
	round_id = id
	phase = "countdown"
	countdown = COUNTDOWN
	elapsed = 0.0
	first_finish = -1.0
	_accumulator = 0.0
	_ready_ticks = roundi(COUNTDOWN * HZ)
	players.clear()
	active_count = 0
	for i in SEATS:
		var seat: Dictionary = slots[i]
		var active: bool = seat.get("active", true)
		active_count += int(active)
		var pos := track.grid(i, SEATS)
		players.append({
			"name": seat.name, "peer": seat.peer, "bot": seat.bot, "active": active,
			"pos": pos, "velocity": Vector2.ZERO, "laps": 0, "gate": 0,
			"started": false, "progress": 0.0, "finish": -1.0,
			"charges": 1, "boost": 0.0, "picked": 0, "spent": 0,
			"_input": 0, "_dash_down": false, "_dash_queued": false, "_used_pads": 0,
			"_recovering": false,
			"_road": track.project(pos), "_facing": track.gates[0].x,
			"_pace": rng.randf_range(0.91, 1.0), "_lane": rng.randf_range(-1.3, 1.3),
			"_look": rng.randf_range(0.57, 0.8), "_boost_at": rng.randf_range(0.6, 1.6),
		})


func command(slot: int, action: String, pressed: bool) -> void:
	if slot < 0 or slot >= players.size() or phase == "finished":
		return
	var p := players[slot]
	if not p.active or p.bot or p.finish >= 0.0:
		return
	if action == "dash":
		if pressed and not p._dash_down and phase == "running":
			p._dash_queued = true
		p._dash_down = pressed
		return
	var bit: int = INPUT_BITS.get(action, 0)
	p._input = p._input | bit if pressed else p._input & ~bit


func take_over(slot: int) -> void:
	if slot >= 0 and slot < players.size() and players[slot].active:
		var p := players[slot]
		p.bot = true
		p._input = 0
		p._dash_down = false
		p._dash_queued = false


func step(delta: float) -> void:
	if delta <= 0.0 or phase == "finished":
		return
	_accumulator += delta
	while _accumulator + EPS >= DT and phase != "finished":
		_accumulator -= DT
		if _ready_ticks > 0:
			_ready_ticks -= 1
			countdown = float(_ready_ticks) / HZ
			if _ready_ticks == 0:
				phase = "running"
		else:
			var end := deadline()
			var dt := minf(DT, end - elapsed)
			_tick(dt)
			elapsed = minf(end, elapsed + dt)
			if elapsed + EPS >= deadline():
				elapsed = deadline()
				phase = "finished"


func deadline() -> float:
	if first_finish < 0.0: return ROUND_TIME
	return first_finish if active_count == 1 else minf(ROUND_TIME, first_finish + FINISH_WINDOW)


func remaining() -> float:
	return maxf(0.0, deadline() - elapsed)


func _tick(dt: float) -> void:
	for p in players:
		if not p.active or p.finish >= 0.0:
			continue
		var road: Vector3 = p._road
		var direction := _bot_input(p, road.x) if p.bot else _held(p._input)
		if p._dash_queued:
			_start_boost(p, direction)
			p._dash_queued = false
		if direction != Vector2.ZERO:
			p._facing = direction.normalized()
		var grass := absf(road.y) > Track.ROAD_HALF
		var speed := GRASS_SPEED if grass else SPEED
		if p.boost > 0.0 and not grass:
			speed = BOOST_SPEED
			if direction == Vector2.ZERO:
				direction = p._facing
		var velocity: Vector2 = p.velocity.move_toward(direction * speed, ACCEL * dt)
		var from: Vector2 = p.pos
		var to := from + velocity * dt
		var projected := track.project(to, int(road.z))
		var edge := Track.RAIL_HALF - Track.ORB_RADIUS
		if absf(projected.y) > edge:
			var f := track.frame(projected.x)
			var normal := f.y * signf(projected.y)
			to = f.origin + normal * edge
			velocity -= normal * maxf(0.0, velocity.dot(normal)) * 1.25
			projected = track.project(to, int(projected.z))
		p.boost = maxf(0.0, float(p.boost) - dt)
		p.velocity = velocity
		p.pos = to
		p._road = projected
		_collect(p, from, to, projected.x)
		_cross_gate(p, from, to, dt)
		p.progress = _progress(p, projected.x)


static func _held(bits: int) -> Vector2:
	return Vector2(int(bool(bits & 2)) - int(bool(bits & 1)),
		int(bool(bits & 8)) - int(bool(bits & 4))).normalized()


func _start_boost(p: Dictionary, direction: Vector2) -> void:
	if p.charges <= 0:
		return
	p.charges -= 1
	p.spent += 1
	if p.boost <= 0.0:
		var heading: Vector2 = p._facing if direction == Vector2.ZERO else direction.normalized()
		p.velocity = p.velocity.move_toward(heading * BOOST_SPEED, 5.0)
	p.boost += BOOST_TIME


func _collect(p: Dictionary, from: Vector2, to: Vector2, arc: float) -> void:
	if not p.started or p.charges >= MAX_CHARGES:
		return
	for i in track.pads.size():
		if p._used_pads & (1 << i) or absf(track.relative_arc(arc, track.pad_distances[i])) > 4.0:
			continue
		var inverse := track.pads[i].inverse()
		# Drive onto the painted surface from any edge. The swept centerline
		# also covers the case where a step crosses the strip between samples.
		if PAD_BOUNDS.has_point(inverse * from):
			continue
		var on_pad := PAD_BOUNDS.has_point(inverse * to)
		var pad := track.pads[i]
		var swept := Track.crossing(pad, Track.PAD_HALF_WIDTH, from, to) >= 0.0
		if on_pad or swept or Track.crossing(pad, Track.PAD_HALF_WIDTH, to, from) >= 0.0:
			p._used_pads |= 1 << i
			p.charges += 1
			p.picked += 1


func _cross_gate(p: Dictionary, from: Vector2, to: Vector2, dt: float) -> void:
	var fraction := Track.crossing(track.gates[p.gate], Track.ROAD_HALF, from, to)
	if fraction < 0.0:
		return
	if p.gate != 0:
		p.gate = (p.gate + 1) % track.gates.size()
		return
	if p.started:
		p.laps += 1
		p._used_pads = 0
		if p.laps == LAPS:
			p.finish = elapsed + dt * fraction
			p.pos = from.lerp(to, fraction)
			p.velocity = Vector2.ZERO
			p.boost = 0.0
			if first_finish < 0.0 or p.finish < first_finish:
				first_finish = p.finish
			return
	p.started = true
	p.gate = 1


func _progress(p: Dictionary, arc: float) -> float:
	if not p.started or p.finish >= 0.0:
		return float(p.laps) * track.length
	var end := track.length if p.gate == 0 else track.gate_distances[p.gate]
	var start := track.gate_distances[posmod(p.gate - 1, track.gates.size())]
	var center := (start + end) * 0.5
	var within := center + track.relative_arc(arc, center)
	return p.laps * track.length + clampf(within, start, end - 0.001)


## Small post-line tolerance avoids calling a racer back while its orb is
## crossing a bend just ahead of the timing line's centerline projection.
func missed_gate(p: Dictionary, arc: float) -> bool:
	var gate_arc := track.gate_distances[p.gate]
	var past := track.relative_arc(arc, gate_arc)
	if past <= 0.65:
		return false
	var before: float = track.gate_distances[posmod(p.gate - 1, track.gates.size())]
	var sector := fposmod(gate_arc - before, track.length) if p.started else Track.GRID_BEHIND
	# Where the signed wrap falls, prefer forward from the previous sector.
	return past < minf(30.0, (track.length - sector) * 0.5)


func _bot_input(p: Dictionary, arc: float) -> Vector2:
	var velocity: Vector2 = p.velocity
	var look := 2.65 + velocity.length() * float(p._look)
	var from_gate := track.relative_arc(arc, track.gate_distances[p.gate])
	p._recovering = missed_gate(p, arc) or (p._recovering and from_gate > -1.4)
	if p._recovering:
		# Get the center of the orb behind the line before aiming forward.
		var recovery := track.frame(arc - minf(look, from_gate + 2.8))
		return ((recovery.origin - p.pos) / 2.0).limit_length()
	var lane: float = p._lane
	if p.started and p.charges < MAX_CHARGES:
		for i in track.pads.size():
			var ahead := track.relative_arc(track.pad_distances[i], arc)
			if ahead > -2.4 and ahead < 15.0 and not p._used_pads & (1 << i):
				var blend := smoothstep(15.0, look + 1.5, ahead)
				lane = lerpf(lane, track.pad_offsets[i], blend)
				break
	var target := track.frame(arc + look)
	var pos: Vector2 = p.pos
	var want := (target.origin + target.y * lane - pos).normalized() * float(p._pace)
	var current := track.frame(arc)
	if elapsed >= float(p._boost_at) and p.charges > 0 and p.boost <= 0.0:
		var exit := track.frame(arc + look + 6.0)
		if current.x.dot(exit.x) > 0.97 and velocity.dot(current.x) > SPEED * 0.69:
			_start_boost(p, want)
			p._boost_at = elapsed + 2.4 + float(p._pace) * 1.7
	return want


func ranking() -> Array:
	var order := range(players.size()).filter(func(slot): return players[slot].active)
	order.sort_custom(func(a: int, b: int) -> bool:
		var left := players[a]
		var right := players[b]
		if left.finish != right.finish:
			if left.finish < 0.0 or right.finish < 0.0:
				return left.finish >= 0.0
			return left.finish < right.finish
		if left.progress != right.progress:
			return left.progress > right.progress
		return a < b)
	return order


func winners() -> Array:
	var order := ranking()
	if order.is_empty():
		return []
	var lead := players[order[0]]
	if order.size() == 1 and lead.finish < 0.0:
		return []
	var tied: Array = []
	for i in order:
		if players[i].finish == lead.finish and players[i].progress == lead.progress:
			tied.append(i)
	return tied


func snapshot() -> Dictionary:
	var cars := PackedFloat64Array()
	for p in players:
		cars.append_array(PackedFloat64Array([
			p.pos.x, p.pos.y, p.velocity.x, p.velocity.y, p.finish, p.progress, p.boost,
			p.laps, p.gate, p.charges, int(p.started) | (int(p.bot) << 1), p.picked, p.spent,
		]))
	return {"id": round_id, "phase": PHASES.find(phase),
		"clock": PackedFloat64Array([elapsed, countdown, first_finish]), "cars": cars}


func apply_snapshot(data: Dictionary) -> void:
	var clock: PackedFloat64Array = data.get("clock", PackedFloat64Array())
	var cars: PackedFloat64Array = data.get("cars", PackedFloat64Array())
	var state: int = data.get("phase", -1)
	if int(data.get("id", -1)) != round_id or state < 0 or state >= PHASES.size():
		return
	if clock.size() != 3 or cars.size() != players.size() * ROW_SIZE:
		return
	phase = PHASES[state]
	elapsed = clock[0]
	countdown = clock[1]
	first_finish = clock[2]
	for i in players.size():
		var p := players[i]
		var n := i * ROW_SIZE
		p.pos = Vector2(cars[n], cars[n + 1])
		p.velocity = Vector2(cars[n + 2], cars[n + 3])
		p.finish = cars[n + 4]
		p.progress = cars[n + 5]
		p.boost = cars[n + 6]
		p.laps = int(cars[n + 7])
		p.gate = int(cars[n + 8])
		p.charges = int(cars[n + 9])
		p.started = bool(int(cars[n + 10]) & 1)
		p.bot = bool(int(cars[n + 10]) & 2)
		p.picked = int(cars[n + 11])
		p.spent = int(cars[n + 12])
