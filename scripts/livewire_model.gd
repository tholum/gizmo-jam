extends RefCounted
## Live Wire: six runners paint a hex reactor floor; most tiles at the buzzer wins.
## The server owns this simulation. Rendering and networking consume its state.
##
## This file has the same shape as round_model.gd so main.gd can drive either
## game: begin / command / step / take_over / ranking / winners / snapshot /
## apply_snapshot, plus `players`, `phase`, `countdown`, `elapsed`, `round_id`.
##
## ---------------------------------------------------------------- RULES
## * Claiming: the tile under a runner becomes theirs. Anyone can repaint a
##   tile by running over it, unless it is locked by somebody else.
## * Loops: when a runner's tiles fully enclose a region (the board edge does
##   NOT count as a wall), every unlocked tile inside becomes theirs, and the
##   captured tiles plus the runner's own tiles bordering them are locked for
##   LOCK_TIME seconds. Locked tiles cannot be repainted by other runners.
## * Surges: a line of the board (see livewire_grid.gd) is telegraphed for
##   SURGE_WARN seconds, then live for SURGE_FIRE seconds. A runner standing on
##   a live line is stunned for STUN_TIME and their largest connected patch of
##   tiles goes neutral (locks on it are cleared). One zap per runner per surge.
## * Dash: a short burst on a cooldown. Dashing into another runner shoves
##   them: they are knocked along the dash direction and lose control briefly.
## * Stages by elapsed time: 0 warmup, 1 charged (CHARGED_AT), 2 overdrive
##   (OVERDRIVE_AT). Surges get more frequent and fire more lines at once. At
##   overdrive every lock is cleared and loops no longer lock anything.
## * The round ends at DURATION. Rank by tiles owned; equal tiles is a draw.
##
## ------------------------------------------------------- STATE CONTRACT
## The renderer and HUD read these fields directly, on the server and (after
## apply_snapshot) on clients. Treat the names and meanings as frozen; adding
## fields is fine.
##
##   grid      livewire_grid.gd instance: GRID_RADIUS, HEX_SIZE.
##   owners    PackedByteArray, one per cell: 0 neutral, else slot + 1.
##   locks     PackedFloat32Array, one per cell: seconds of lock left, 0 = open.
##   surges    Array of {id: int, axis: int, line: int, warn: float, fire: float}.
##             warn > 0: telegraphing (seconds until live). warn == 0: live for
##             `fire` more seconds. Entries are removed when fire reaches 0.
##   players   Array of six Dictionaries, by seat:
##       name: String, peer: int, bot: bool, active: bool (from the launch lineup)
##       x, z: float     board position; grid.cell_at(Vector2(x, z)) is the tile
##       face: float     heading in radians; direction = (sin(face), cos(face))
##                       in (x, z), so it can be assigned to Node3D.rotation.y
##       speed: float    current speed in world units/second (0 when idle)
##       stun: float     seconds left stunned by a surge, 0 = free
##       shove: float    seconds left being knocked back, 0 = free
##       dash: float     seconds left of the active dash, 0 = not dashing
##       cool: float     seconds until dash is ready, 0 = ready
##       tiles: int      tiles owned right now (the score)
##       best: int       most tiles held at any moment this round
##       loops: int      loops closed
##       zaps: int       times zapped by a surge
##       shoves: int     shoves landed on other runners
##     Keys starting with "_" are server-only (held input, bot plans) and are
##     left out of snapshots.
##   phase     "countdown" | "running" | "finished"
##   countdown seconds left before GO (3 -> 0)
##   elapsed   seconds of play since GO
##
## Input: command(slot, action, pressed) with action in ACTIONS. The four
## directions are held (pressed / released); "dash" fires on press. "up" is -z
## (away from the camera), "right" is +x.
##
## ------------------------------------------------- IMPLEMENTATION NOTES
## * Free and dashing runners claim; stunned or shoved runners do not. A tile
##   cannot be repainted while its owner is standing on it and able to claim.
## * Loops are checked after every claim: whatever the claimer's tiles cut off
##   from the edge cells is captured, except tiles locked by somebody else.
## * Runner centres stay inside the largest regular hexagon that fits in the
##   board, so the walls are straight and the centre is always over a tile.
## * Directions pressed during the countdown are remembered and apply at GO.
## * snapshot() is a packed wire format, not these fields: read state from a
##   model that has had apply_snapshot() called on it. Over the wire positions
##   are exact to 1 mm, timers to 1/50 s and locks to 1/10 s (rounded up).

const Grid = preload("res://scripts/livewire_grid.gd")

const GAME_ID := "livewire"
const SEATS := 6
const ACTIONS := ["left", "right", "up", "down", "dash"]
const BOT_NAMES := ["BOLT", "NOVA", "ECHO", "FLUX", "PIXEL", "COMET"]
const BOT_SUFFIX := " · BOT"

const GRID_RADIUS := 7
const HEX_SIZE := 0.9
const DURATION := 90.0
const CHARGED_AT := 30.0
const OVERDRIVE_AT := 70.0
const MOVE_SPEED := 4.4
const RUNNER_RADIUS := 0.32
const DASH_SPEED := 11.0
const DASH_TIME := 0.22
const DASH_COOLDOWN := 2.5
const SHOVE_SPEED := 9.0
const SHOVE_TIME := 0.35
const LOCK_TIME := 10.0
const SURGE_WARN := 1.6
const SURGE_FIRE := 0.45
const STUN_TIME := 1.3

## Tuning that is not part of the state contract.
const COUNTDOWN := 3.0
## Hexes between the board centre and each starting tile.
const START_RING := 4
## Centre distance at which a dash connects with another runner.
const SHOVE_REACH := 0.8
## How quickly overlapping runners are pushed apart (1 / seconds).
const SEPARATION := 10.0
## Longest slice of time simulated at once; longer frames are split up.
const MAX_STEP := 1.0 / 30.0
## Seconds into the round of the first surge, then the gap per stage.
const SURGE_FIRST := 4.0
const SURGE_GAP := [7.0, 5.0, 3.0]
const SURGE_JITTER := 0.15
## Share of surge lines drawn through a runner instead of at random.
const SURGE_AIM := 0.5
## Extra weight every runner gets when an aimed surge picks its target; the
## rest of the weight is their tile count, so leaders draw more fire.
const SURGE_AIM_BASE := 8.0

## Bot personalities by seat: seconds between decisions, seconds before a new
## telegraph registers, chance to never notice a surge, appetite for dashing
## at people, and how sloppy the tile choice is.
const BOT_REACT := [0.22, 0.30, 0.18, 0.34, 0.26, 0.20]
const BOT_NOTICE := [0.35, 0.30, 0.40, 0.30, 0.40, 0.35]
const BOT_SLIP := [0.15, 0.13, 0.18, 0.14, 0.16, 0.12]
const BOT_RAGE := [0.30, 0.12, 0.42, 0.18, 0.35, 0.22]
const BOT_WANDER := [0.5, 0.4, 0.6, 0.45, 0.55, 0.65]
## Chance per decision to stop and dither for a moment.
const BOT_HESITATE := 0.012
## How close an opponent has to be before a bot considers dashing at them.
const BOT_REACH := 1.9
## Cost bonus for the tile a bot is already heading for.
const BOT_COMMIT := 0.5
## A bot keeps its held direction while it is within this angle of the goal.
const BOT_STEER_SLACK := 0.56

## Snapshot quantisation (units per world unit, radian or second).
const SNAP_RUNNER_BYTES := 23
const SNAP_POSITION := 1000.0
const SNAP_ANGLE := 10000.0
const SNAP_SPEED := 10.0
const SNAP_TIMER := 50.0
const SNAP_LOCK := 10.0

var grid := Grid.new(GRID_RADIUS, HEX_SIZE)
var owners := PackedByteArray()
var locks := PackedFloat32Array()
var surges: Array = []
var players: Array = []
var phase := "countdown"
var countdown := COUNTDOWN
var elapsed := 0.0
var round_id := 0
var rng := RandomNumberGenerator.new()
## Accepted for interface parity with round_model.gd. A timed game has no
## endless variant, so this is stored and synced but changes no rule.
var practice := false

var _next_surge := SURGE_FIRST
var _surge_id := 0
var _ticks := 0
var _overdrive := false
## Surge id -> bitmask of the seats it has already zapped.
var _zapped: Dictionary = {}
var _edge := PackedInt32Array()
var _walls := PackedVector2Array()
var _apothem := 0.0

func _init() -> void:
	for i in grid.count():
		if grid.is_edge(i):
			_edge.append(i)
	# Runner centres are kept inside the largest regular hexagon that fits in
	# the tiles: straight walls to slide along, and always over a valid tile.
	_apothem = 1.5 * grid.size * grid.radius + 0.5 * grid.size - 0.01
	for k in 6:
		var angle := deg_to_rad(30.0 + 60.0 * k)
		_walls.append(Vector2(cos(angle), sin(angle)))

func begin(seed_value: int, slots: Array, id: int = 1, endless: bool = false) -> void:
	rng.seed = seed_value
	round_id = id
	practice = endless
	phase = "countdown"
	countdown = COUNTDOWN
	elapsed = 0.0
	surges = []
	players = []
	owners = PackedByteArray()
	owners.resize(grid.count())
	owners.fill(0)
	locks = PackedFloat32Array()
	locks.resize(grid.count())
	locks.fill(0.0)
	_next_surge = SURGE_FIRST
	_surge_id = 0
	_ticks = 0
	_overdrive = false
	_zapped = {}
	var ring := mini(START_RING, grid.radius)
	for i in SEATS:
		var seat: Dictionary = slots[i]
		var active: bool = seat.get("active", true)
		var cell: int = grid.index[Grid.DIRS[i] * ring]
		var at := grid.centers[cell]
		if active:
			owners[cell] = i + 1
		players.append({"name": seat.name, "peer": seat.peer, "bot": seat.bot, "active": active,
			"x": at.x, "z": at.y, "face": atan2(-at.x, -at.y), "speed": 0.0,
			"stun": 0.0, "shove": 0.0, "dash": 0.0, "cool": 0.0,
			"tiles": int(active), "best": int(active), "loops": 0, "zaps": 0, "shoves": 0,
			"_l": false, "_r": false, "_u": false, "_d": false,
			"_dx": 0.0, "_dz": 0.0, "_kx": 0.0, "_kz": 0.0, "_hit": 0,
			"_think": 0.0, "_goal": -1, "_flee": false, "_seen": {}})

func command(slot: int, action: String, pressed: bool) -> void:
	if slot < 0 or slot >= players.size() or phase == "finished":
		return
	var p: Dictionary = players[slot]
	if not p.active:
		return
	# Directions are remembered during the countdown so a key that is already
	# down at GO counts, but nothing moves until then.
	match action:
		"left":
			p._l = pressed
		"right":
			p._r = pressed
		"up":
			p._u = pressed
		"down":
			p._d = pressed
		"dash":
			if pressed and phase == "running":
				_start_dash(p)

func _held(p: Dictionary) -> Vector2:
	return Vector2(float(int(p._r) - int(p._l)), float(int(p._d) - int(p._u)))

func _start_dash(p: Dictionary) -> void:
	if float(p.cool) > 0.0 or float(p.dash) > 0.0 or float(p.stun) > 0.0 or float(p.shove) > 0.0:
		return
	var dir := _held(p)
	if dir == Vector2.ZERO:
		dir = Vector2(sin(float(p.face)), cos(float(p.face)))
	dir = dir.normalized()
	p._dx = dir.x
	p._dz = dir.y
	p._hit = 0
	p.face = atan2(dir.x, dir.y)
	p.dash = DASH_TIME
	p.cool = DASH_COOLDOWN

func step(delta: float) -> void:
	if phase == "finished" or delta <= 0.0:
		return
	if phase == "countdown":
		countdown = maxf(0.0, countdown - delta)
		if countdown <= 0.0:
			phase = "running"
		return
	var left := delta
	while left > 0.000001 and phase == "running":
		var dt := minf(left, MAX_STEP)
		left -= dt
		_tick(dt)

func _tick(dt: float) -> void:
	_ticks += 1
	elapsed = minf(DURATION, elapsed + dt)
	if stage() == 2 and not _overdrive:
		_overdrive = true
		locks.fill(0.0)
	else:
		for i in locks.size():
			if locks[i] > 0.0:
				locks[i] = maxf(0.0, locks[i] - dt)
	_step_surges(dt)
	for i in players.size():
		if players[i].active and players[i].bot:
			_bot_step(i, dt)
	for p in players:
		if p.active:
			_move(p, dt)
	_collide(dt)
	_claim()
	_zap()
	_count()
	if elapsed >= DURATION:
		phase = "finished"
		for p in players:
			p.speed = 0.0

# ------------------------------------------------------------------ runners

func _clamp(pos: Vector2) -> Vector2:
	for n in _walls:
		var over := pos.dot(n) - _apothem
		if over > 0.0:
			pos -= n * over
	return pos

func _place(p: Dictionary, target: Vector2) -> void:
	var to := _clamp(target)
	if grid.cell_at(to) >= 0:
		p.x = to.x
		p.z = to.y

func _move(p: Dictionary, dt: float) -> void:
	p.cool = maxf(0.0, float(p.cool) - dt)
	p.stun = maxf(0.0, float(p.stun) - dt)
	var vel := Vector2.ZERO
	if float(p.shove) > 0.0:
		# Knockback eases out, so a shove is a sharp hit that skids to a stop.
		# A burst that ends inside this slice only moves for what is left of it.
		vel = Vector2(p._kx, p._kz) * SHOVE_SPEED * (float(p.shove) / SHOVE_TIME) * minf(1.0, float(p.shove) / dt)
		p.shove = maxf(0.0, float(p.shove) - dt)
	elif float(p.stun) > 0.0:
		pass
	elif float(p.dash) > 0.0:
		vel = Vector2(p._dx, p._dz) * DASH_SPEED * minf(1.0, float(p.dash) / dt)
		p.dash = maxf(0.0, float(p.dash) - dt)
	else:
		var dir := _held(p)
		if dir != Vector2.ZERO:
			vel = dir.normalized() * MOVE_SPEED
			p.face = atan2(dir.x, dir.y)
	var from := Vector2(p.x, p.z)
	if vel != Vector2.ZERO:
		_place(p, from + vel * dt)
	p.speed = from.distance_to(Vector2(p.x, p.z)) / dt

func _shove(from: Dictionary, target: int) -> void:
	var p: Dictionary = players[target]
	p.shove = SHOVE_TIME
	p.dash = 0.0
	p._kx = from._dx
	p._kz = from._dz
	from._hit = int(from._hit) | (1 << target)
	from.shoves = int(from.shoves) + 1

func _collide(dt: float) -> void:
	var push := minf(1.0, SEPARATION * dt) * 0.5
	for i in players.size():
		var a: Dictionary = players[i]
		if not a.active:
			continue
		for j in range(i + 1, players.size()):
			var b: Dictionary = players[j]
			if not b.active:
				continue
			var gap := Vector2(float(b.x) - float(a.x), float(b.z) - float(a.z))
			var dist := gap.length()
			if dist < SHOVE_REACH:
				# Both checks are made before either shove lands, so two
				# runners dashing into each other both go flying.
				var a_hits := float(a.dash) > 0.0 and (int(a._hit) & (1 << j)) == 0 \
					and gap.dot(Vector2(a._dx, a._dz)) >= 0.0
				var b_hits := float(b.dash) > 0.0 and (int(b._hit) & (1 << i)) == 0 \
					and gap.dot(Vector2(b._dx, b._dz)) <= 0.0
				if a_hits:
					_shove(a, j)
				if b_hits:
					_shove(b, i)
			if dist < RUNNER_RADIUS * 2.0:
				var away := gap / dist if dist > 0.0001 else Vector2.from_angle(float(i * SEATS + j))
				var shift := away * (RUNNER_RADIUS * 2.0 - dist) * push
				_place(a, Vector2(a.x, a.z) - shift)
				_place(b, Vector2(b.x, b.z) + shift)

# -------------------------------------------------------------------- tiles

func _claim() -> void:
	var here := PackedInt32Array()
	var able: Array[bool] = []
	for p in players:
		here.append(grid.cell_at(Vector2(p.x, p.z)) if p.active else -1)
		able.append(p.active and float(p.stun) <= 0.0 and float(p.shove) <= 0.0)
	# The seat that goes first rotates so no seat wins every contested tile.
	for k in players.size():
		var slot := (k + _ticks) % players.size()
		var cell := here[slot]
		if not able[slot] or cell < 0:
			continue
		var owner := int(owners[cell])
		if owner == slot + 1:
			continue
		if owner != 0:
			if locks[cell] > 0.0:
				continue
			# A runner holds the tile they are standing on.
			if here[owner - 1] == cell and able[owner - 1]:
				continue
		owners[cell] = slot + 1
		_enclose(slot)

## Capture whatever `slot`'s tiles now wall off from the edge of the board.
func _enclose(slot: int) -> void:
	var mine := slot + 1
	var total := grid.count()
	var open := PackedByteArray()
	open.resize(total)
	open.fill(0)
	var stack := PackedInt32Array()
	for i in _edge:
		if owners[i] != mine:
			open[i] = 1
			stack.append(i)
	while not stack.is_empty():
		var at := stack[stack.size() - 1]
		stack.remove_at(stack.size() - 1)
		for near in grid.neighbors[at]:
			if open[near] == 0 and owners[near] != mine:
				open[near] = 1
				stack.append(near)
	var captured := PackedInt32Array()
	for i in total:
		if open[i] == 0 and owners[i] != mine and locks[i] <= 0.0:
			owners[i] = mine
			captured.append(i)
	if captured.is_empty():
		return
	players[slot].loops = int(players[slot].loops) + 1
	if stage() >= 2:
		return
	for i in captured:
		locks[i] = LOCK_TIME
		for near in grid.neighbors[i]:
			if owners[near] == mine:
				locks[near] = LOCK_TIME

## The cells of `slot`'s biggest connected patch (the first one found on a tie).
func largest_patch(slot: int) -> PackedInt32Array:
	var mine := slot + 1
	var seen := PackedByteArray()
	seen.resize(grid.count())
	seen.fill(0)
	var best := PackedInt32Array()
	for start in grid.count():
		if owners[start] != mine or seen[start] == 1:
			continue
		var patch := PackedInt32Array([start])
		seen[start] = 1
		var read := 0
		while read < patch.size():
			for near in grid.neighbors[patch[read]]:
				if owners[near] == mine and seen[near] == 0:
					seen[near] = 1
					patch.append(near)
			read += 1
		if patch.size() > best.size():
			best = patch
	return best

func _count() -> void:
	var totals := PackedInt32Array()
	totals.resize(players.size() + 1)
	totals.fill(0)
	for owner in owners:
		if owner < totals.size():
			totals[owner] += 1
	for i in players.size():
		var p: Dictionary = players[i]
		if not p.active:
			continue
		p.tiles = totals[i + 1]
		p.best = maxi(int(p.best), totals[i + 1])

# ------------------------------------------------------------------- surges

func _step_surges(dt: float) -> void:
	var expired := false
	for s in surges:
		if float(s.warn) > 0.0:
			s.warn = float(s.warn) - dt
			if float(s.warn) <= 0.0:
				s.fire = maxf(0.0, SURGE_FIRE + float(s.warn))
				s.warn = 0.0
		else:
			s.fire = maxf(0.0, float(s.fire) - dt)
		if float(s.fire) <= 0.0:
			expired = true
			_zapped.erase(int(s.id))
	if expired:
		surges = surges.filter(func(s): return float(s.fire) > 0.0)
	if elapsed >= _next_surge:
		var now := stage()
		var lines := 1 if now == 0 else (2 if now == 1 else rng.randi_range(2, 3))
		for k in lines:
			_spawn_surge()
		_next_surge = elapsed + float(SURGE_GAP[now]) * rng.randf_range(1.0 - SURGE_JITTER, 1.0 + SURGE_JITTER)

func _spawn_surge() -> void:
	for attempt in 8:
		var axis := rng.randi_range(0, 2)
		var line := rng.randi_range(-grid.radius, grid.radius)
		if rng.randf() < SURGE_AIM:
			var cell := _aim_cell()
			if cell >= 0:
				line = grid.line_of(cell, axis)
		var taken := false
		for s in surges:
			if int(s.axis) == axis and int(s.line) == line:
				taken = true
		if taken:
			continue
		surges.append({"id": _surge_id, "axis": axis, "line": line, "warn": SURGE_WARN, "fire": SURGE_FIRE})
		_surge_id += 1
		return

## The tile under a runner picked at random, weighted towards the leaders.
func _aim_cell() -> int:
	var total := 0.0
	for p in players:
		if p.active:
			total += SURGE_AIM_BASE + float(p.tiles)
	var pick := rng.randf() * total
	var aimed_at := {}
	for p in players:
		if not p.active:
			continue
		aimed_at = p
		pick -= SURGE_AIM_BASE + float(p.tiles)
		if pick <= 0.0:
			break
	return -1 if aimed_at.is_empty() else grid.cell_at(Vector2(aimed_at.x, aimed_at.z))

func _zap() -> void:
	for s in surges:
		if float(s.warn) > 0.0:
			continue
		var done := int(_zapped.get(int(s.id), 0))
		for i in players.size():
			if not players[i].active or done & (1 << i) != 0:
				continue
			var p: Dictionary = players[i]
			var cell := grid.cell_at(Vector2(p.x, p.z))
			if cell < 0 or grid.line_of(cell, int(s.axis)) != int(s.line):
				continue
			done |= 1 << i
			p.stun = STUN_TIME
			p.dash = 0.0
			p.zaps = int(p.zaps) + 1
			for lost in largest_patch(i):
				owners[lost] = 0
				locks[lost] = 0.0
		_zapped[int(s.id)] = done

# --------------------------------------------------------------------- bots
# Bots only ever act through command(), exactly like a remote player.

func _on_lines(cell: int, lines: Array) -> bool:
	for line in lines:
		if grid.line_of(cell, line.x) == line.y:
			return true
	return false

func _eight(to: Vector2) -> Vector2:
	var ax := absf(to.x)
	var az := absf(to.y)
	return Vector2(signf(to.x) if ax > 0.414 * az else 0.0, signf(to.y) if az > 0.414 * ax else 0.0)

func _hold(slot: int, want: Vector2) -> void:
	var p: Dictionary = players[slot]
	if bool(p._l) != (want.x < 0.0):
		command(slot, "left", want.x < 0.0)
	if bool(p._r) != (want.x > 0.0):
		command(slot, "right", want.x > 0.0)
	if bool(p._u) != (want.y < 0.0):
		command(slot, "up", want.y < 0.0)
	if bool(p._d) != (want.y > 0.0):
		command(slot, "down", want.y > 0.0)

func _bot_step(slot: int, dt: float) -> void:
	var p: Dictionary = players[slot]
	p._think = float(p._think) - dt
	if float(p.stun) > 0.0 or float(p.shove) > 0.0 or float(p.dash) > 0.0:
		return
	var pos := Vector2(p.x, p.z)
	var here := grid.cell_at(pos)
	if here < 0:
		return
	var goal := int(p._goal)
	var arrived: bool = goal >= 0 and (here == goal or (not p._flee and int(owners[goal]) == slot + 1))
	if float(p._think) <= 0.0 or arrived:
		if _bot_plan(slot, pos, here):
			return
	_bot_steer(slot, pos, here)

## Picks a goal tile. Returns true when the bot dashed and is done for now.
func _bot_plan(slot: int, pos: Vector2, here: int) -> bool:
	var p: Dictionary = players[slot]
	var timed := float(p._think) <= 0.0
	if timed:
		p._think = float(BOT_REACT[slot]) * rng.randf_range(0.7, 1.3)
	# Surges register after a beat, and now and then not at all.
	var seen: Dictionary = {}
	var lines: Array = []
	var soonest := INF
	for s in surges:
		var id := int(s.id)
		if p._seen.has(id):
			seen[id] = p._seen[id]
		elif float(s.warn) <= 0.0 or SURGE_WARN - float(s.warn) >= float(BOT_NOTICE[slot]):
			seen[id] = rng.randf() >= float(BOT_SLIP[slot])
		if seen.get(id, false):
			lines.append(Vector2i(int(s.axis), int(s.line)))
			if grid.line_of(here, int(s.axis)) == int(s.line):
				soonest = minf(soonest, float(s.warn))
	p._seen = seen
	var danger := soonest < INF
	if timed and not danger and rng.randf() < BOT_HESITATE:
		p._goal = -1
		p._flee = false
		p._think = rng.randf_range(0.3, 0.6)
		return false
	var mine := slot + 1
	var forward := Vector2(sin(float(p.face)), cos(float(p.face)))
	# Sticking with the tile already chosen keeps a bot from dithering.
	var committed := -1 if p._flee else int(p._goal)
	var best := -1
	var best_cost := INF
	for cell in grid.count():
		if _on_lines(cell, lines):
			continue
		var owner := int(owners[cell])
		var to := grid.centers[cell] - pos
		var dist := to.length()
		var cost := dist
		if danger:
			# Get off the line; a tile worth having breaks ties.
			if owner == mine or locks[cell] > 0.0:
				cost += 0.35
		else:
			if owner == mine:
				continue
			if owner != 0:
				if locks[cell] > 0.0:
					continue
				var holder: Dictionary = players[owner - 1]
				if holder.active and grid.cell_at(Vector2(holder.x, holder.z)) == cell:
					continue
			else:
				cost -= 0.25
			if dist > 0.001:
				cost -= 0.45 * forward.dot(to / dist)
			cost += rng.randf() * float(BOT_WANDER[slot])
			if cell == committed:
				cost -= BOT_COMMIT
			if dist < 5.0:
				for i in players.size():
					if i != slot and players[i].active and grid.centers[cell].distance_to(Vector2(players[i].x, players[i].z)) < dist - 0.2:
						cost += 0.8
						break
		if cost < best_cost:
			best_cost = cost
			best = cell
	p._goal = best
	p._flee = danger
	if float(p.cool) > 0.0:
		return false
	if danger:
		# Late to notice: burn the dash to get clear.
		if soonest < 0.5 and best >= 0:
			_hold(slot, _eight(grid.centers[best] - pos))
			command(slot, "dash", true)
			return true
		return false
	var foe := -1
	var foe_dist := BOT_REACH
	for i in players.size():
		var other: Dictionary = players[i]
		if i == slot or not other.active:
			continue
		var gap := pos.distance_to(Vector2(other.x, other.z))
		if gap < foe_dist and float(other.shove) <= 0.0:
			foe = i
			foe_dist = gap
	if foe >= 0:
		if rng.randf() < float(BOT_RAGE[slot]):
			_hold(slot, _eight(Vector2(players[foe].x, players[foe].z) - pos))
			command(slot, "dash", true)
			return true
	elif best >= 0 and pos.distance_to(grid.centers[best]) > 4.5 and rng.randf() < 0.3:
		_hold(slot, _eight(grid.centers[best] - pos))
		command(slot, "dash", true)
		return true
	return false

func _bot_steer(slot: int, pos: Vector2, here: int) -> void:
	var p: Dictionary = players[slot]
	var want := Vector2.ZERO
	var goal := int(p._goal)
	if goal >= 0:
		var to := grid.centers[goal] - pos
		if to.length() > 0.08:
			# Eight directions rarely point straight at the goal. Keep the
			# current one while it is roughly right instead of flickering
			# between the two nearest every frame.
			var now := _held(p)
			want = now if now != Vector2.ZERO and absf(now.angle_to(to)) < BOT_STEER_SLACK else _eight(to)
	if want != Vector2.ZERO:
		# Do not walk onto a line the bot knows is about to fire.
		var ahead := grid.cell_at(pos + want.normalized() * MOVE_SPEED * 0.2)
		for s in surges:
			if float(s.warn) < 0.6 and p._seen.get(int(s.id), false) and ahead >= 0 \
					and grid.line_of(ahead, int(s.axis)) == int(s.line) \
					and grid.line_of(here, int(s.axis)) != int(s.line):
				want = Vector2.ZERO
	_hold(slot, want)

# ---------------------------------------------------------------- interface

## 0 warmup, 1 charged, 2 overdrive.
func stage() -> int:
	return 0 if elapsed < CHARGED_AT else (1 if elapsed < OVERDRIVE_AT else 2)

func remaining() -> float:
	return maxf(0.0, DURATION - elapsed)

func take_over(slot: int) -> void:
	if slot < 0 or slot >= players.size() or not players[slot].active:
		return
	var p: Dictionary = players[slot]
	p.bot = true
	p.peer = 0
	p._l = false
	p._r = false
	p._u = false
	p._d = false
	p._goal = -1
	p._flee = false
	p._think = 0.0
	p._seen = {}
	p.name = str(p.name).left(12) + BOT_SUFFIX

## Seat indices by tiles owned, highest first (equal tiles: lower seat first).
func ranking() -> Array:
	var order := range(players.size()).filter(func(slot): return players[slot].active)
	order.sort_custom(func(a, b):
		if int(players[a].tiles) != int(players[b].tiles):
			return int(players[a].tiles) > int(players[b].tiles)
		return a < b)
	return order

## Every seat tied for the most tiles.
func winners() -> Array:
	var top := 0
	for p in players:
		if p.active:
			top = maxi(top, int(p.tiles))
	return range(players.size()).filter(func(i): return players[i].active and int(players[i].tiles) == top)

## Sent 20 times a second, so it is packed tightly: positions in millimetres,
## headings in 1/10000 rad, speed in tenths, timers in 1/50 s and locks in
## tenths of a second (both rounded up, so "active" survives the trip), surges
## as five ints each, and no server-only "_" keys. apply_snapshot() turns it
## back into the fields of the state contract.
func snapshot() -> Dictionary:
	var names := PackedStringArray()
	var peers := PackedInt32Array()
	var runners := PackedByteArray()
	runners.resize(players.size() * SNAP_RUNNER_BYTES)
	for i in players.size():
		var p: Dictionary = players[i]
		var at := i * SNAP_RUNNER_BYTES
		names.append(str(p.name))
		peers.append(int(p.peer))
		runners.encode_s32(at, roundi(float(p.x) * SNAP_POSITION))
		runners.encode_s32(at + 4, roundi(float(p.z) * SNAP_POSITION))
		runners.encode_s16(at + 8, clampi(roundi(float(p.face) * SNAP_ANGLE), -32768, 32767))
		runners.encode_u8(at + 10, clampi(roundi(float(p.speed) * SNAP_SPEED), 0, 255))
		runners.encode_u8(at + 11, _pack_time(float(p.stun), SNAP_TIMER))
		runners.encode_u8(at + 12, _pack_time(float(p.shove), SNAP_TIMER))
		runners.encode_u8(at + 13, _pack_time(float(p.dash), SNAP_TIMER))
		runners.encode_u8(at + 14, _pack_time(float(p.cool), SNAP_TIMER))
		runners.encode_u16(at + 15, clampi(int(p.tiles), 0, 65535))
		runners.encode_u16(at + 17, clampi(int(p.best), 0, 65535))
		runners.encode_u8(at + 19, clampi(int(p.loops), 0, 255))
		runners.encode_u8(at + 20, clampi(int(p.zaps), 0, 255))
		runners.encode_u8(at + 21, clampi(int(p.shoves), 0, 255))
		runners.encode_u8(at + 22, 1 if p.bot else 0)
	var held := PackedByteArray()
	held.resize(locks.size())
	for i in locks.size():
		held[i] = _pack_time(locks[i], SNAP_LOCK)
	var lines := PackedInt32Array()
	for s in surges:
		lines.append_array(PackedInt32Array([int(s.id), int(s.axis), int(s.line),
			ceili(float(s.warn) * 1000.0), ceili(float(s.fire) * 1000.0)]))
	return {"id": round_id, "game": GAME_ID, "phase": phase, "practice": practice,
		"elapsed": elapsed, "countdown": countdown,
		"owners": owners.duplicate(), "locks": held, "surges": lines,
		"names": names, "peers": peers, "runners": runners}

static func _pack_time(seconds: float, scale: float) -> int:
	return clampi(ceili(seconds * scale - 0.0001), 0, 255)

func apply_snapshot(data: Dictionary) -> void:
	if int(data.get("id", -1)) != round_id or str(data.get("game", "")) != GAME_ID:
		return
	# Anything that is not shaped like one of our snapshots is dropped whole.
	if not (data.get("runners") is PackedByteArray and data.get("locks") is PackedByteArray
			and data.get("owners") is PackedByteArray and data.get("surges") is PackedInt32Array
			and data.get("names") is PackedStringArray and data.get("peers") is PackedInt32Array
			and data.get("phase") is String and data.get("elapsed") is float and data.get("countdown") is float):
		return
	var runners: PackedByteArray = data.runners
	var held: PackedByteArray = data.locks
	var lines: PackedInt32Array = data.surges
	var tiles: PackedByteArray = data.owners
	if runners.size() != players.size() * SNAP_RUNNER_BYTES or held.size() != grid.count() \
			or tiles.size() != grid.count() or lines.size() % 5 != 0 \
			or data.names.size() != players.size() or data.peers.size() != players.size():
		return
	phase = data.phase
	practice = bool(data.get("practice", false))
	elapsed = data.elapsed
	countdown = data.countdown
	owners = tiles.duplicate()
	for i in held.size():
		locks[i] = held[i] / SNAP_LOCK
	surges = []
	for i in range(0, lines.size(), 5):
		surges.append({"id": lines[i], "axis": lines[i + 1], "line": lines[i + 2],
			"warn": lines[i + 3] / 1000.0, "fire": lines[i + 4] / 1000.0})
		# Keep ids unique if this copy ever has to carry the round on.
		_surge_id = maxi(_surge_id, lines[i] + 1)
	for i in players.size():
		var p: Dictionary = players[i]
		var at := i * SNAP_RUNNER_BYTES
		p.name = data.names[i]
		p.peer = data.peers[i]
		p.x = runners.decode_s32(at) / SNAP_POSITION
		p.z = runners.decode_s32(at + 4) / SNAP_POSITION
		p.face = runners.decode_s16(at + 8) / SNAP_ANGLE
		p.speed = runners.decode_u8(at + 10) / SNAP_SPEED
		p.stun = runners.decode_u8(at + 11) / SNAP_TIMER
		p.shove = runners.decode_u8(at + 12) / SNAP_TIMER
		p.dash = runners.decode_u8(at + 13) / SNAP_TIMER
		p.cool = runners.decode_u8(at + 14) / SNAP_TIMER
		p.tiles = runners.decode_u16(at + 15)
		p.best = runners.decode_u16(at + 17)
		p.loops = runners.decode_u8(at + 19)
		p.zaps = runners.decode_u8(at + 20)
		p.shoves = runners.decode_u8(at + 21)
		p.bot = runners.decode_u8(at + 22) != 0
	_overdrive = stage() == 2
	_next_surge = maxf(_next_surge, elapsed)
