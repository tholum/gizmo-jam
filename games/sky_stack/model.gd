extends RefCounted
## The authority drops solid blocks onto a small integer grid. Each block joins
## a contact under its middle stud, and at least half its footprint must touch.
## A legal tower can have overhangs, but no unsupported island can score.

const SEATS := 6
const LANES := 9
const CENTER := 4
const WAVES := 6
const HZ := 60
const COUNTDOWN := 3.0
const DRAFT_TICKS := 3 * HZ
const WAVE_TICKS := 15 * HZ
const SETTLE_TICKS := 2 * HZ
const LAST_CALL_TICKS := 3 * HZ
const BASIC := 0
const TALL := 1
const WIDE := 2
const DRAFT := "draft"
const BUILD := "build"
const SETTLE := "settle"
const NO_REQUEST := -1
## Each Tall gains three levels. The next mold forecasts how much of a
## platform a builder will need to gain all three above their current lead.
const TALL_MOLDS := [Vector2i(1, 3), Vector2i(5, 3), Vector2i(3, 3),
	Vector2i(1, 3), Vector2i(5, 3), Vector2i(3, 3)]
const WIDE_MOLD := Vector2i(5, 1)
const BASIC_MOLD := Vector2i(3, 1)
const SINGLE_MOLD := Vector2i(1, 1)

var players: Array = []
var occupied: Array[int] = []
var phase := "countdown"
var stage := DRAFT
var countdown := COUNTDOWN
var elapsed := 0.0
var round_id := 0
var wave := 0
var wave_ticks := 0
var settle_ticks := 0
var tick := 0
var priority_start := 0
var mold_start := 0
var awards := PackedInt32Array([-1, -1, -1])
var _carry := 0.0

func begin(seed_value: int, slots: Array, id: int = 1, _endless: bool = false) -> void:
	round_id = id
	phase = "countdown"
	countdown = COUNTDOWN
	stage = DRAFT
	elapsed = 0.0
	_carry = 0.0
	tick = 0
	wave = 0
	wave_ticks = 0
	settle_ticks = 0
	awards.fill(-1)
	players.clear()
	occupied.clear()
	for i in SEATS:
		var seat: Dictionary = slots[i]
		var active := bool(seat.get("active", true))
		if active:
			occupied.append(i)
		var surface := PackedInt32Array()
		surface.resize(LANES)
		players.append({"name": seat.name, "peer": seat.peer, "bot": seat.bot, "active": active,
			"score": 0, "surface": surface, "blocks": PackedInt32Array(), "choice": BASIC,
			"request": NO_REQUEST, "piece": BASIC, "cursor": CENTER, "placed": false,
			"automatic": false, "last_place": -1, "style": posmod(seed_value + i * 7, 5)})
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	priority_start = posmod(rng.randi_range(0, maxi(0, occupied.size() - 1)) + id - 1, maxi(1, occupied.size()))
	mold_start = rng.randi_range(0, TALL_MOLDS.size() - 1)

func priority_order(offset: int = 0) -> Array[int]:
	var order: Array[int] = []
	for i in occupied.size():
		order.append(occupied[(priority_start + wave + offset + i) % occupied.size()])
	return order

func mold(kind: int, offset: int = 0) -> Vector2i:
	match kind:
		TALL: return TALL_MOLDS[(mold_start + wave + offset) % TALL_MOLDS.size()]
		WIDE: return WIDE_MOLD
	return BASIC_MOLD

## Returns the landing level if the center and enough adjacent studs support
## the block. Since it lands above the highest column, there is no overlap.
static func landing(surface: PackedInt32Array, center: int, width: int) -> int:
	if center < 0 or center >= LANES or width < 1 or width % 2 == 0:
		return -1
	var radius := width >> 1
	if center - radius < 0 or center + radius >= LANES:
		return -1
	var level := surface[center]
	var contacts := 0
	for x in range(center - radius, center + radius + 1):
		if surface[x] > level:
			return -1
		if surface[x] == level:
			contacts += 1
	return level if contacts >= radius + 1 else -1

static func legal_centers(surface: PackedInt32Array, width: int) -> Array[int]:
	var centers: Array[int] = []
	for x in LANES:
		if landing(surface, x, width) >= 0:
			centers.append(x)
	return centers

func fit(slot: int) -> Vector2i:
	var p: Dictionary = players[slot]
	var wanted := mold(p.piece)
	if wanted == BASIC_MOLD and legal_centers(p.surface, wanted.x).is_empty():
		return SINGLE_MOLD
	return wanted

func studs(slot: int) -> Array[int]:
	return legal_centers(players[slot].surface, fit(slot).x)

static func block_parts(block: int) -> Vector4i:
	# Columns, level, footprint and height fit in 15 bits at six waves.
	return Vector4i(block & 15, (block >> 4) & 31, (block >> 9) & 7, (block >> 12) & 7)

func command(slot: int, action: String, pressed: bool) -> void:
	if phase != "running" or not pressed or slot < 0 or slot >= SEATS:
		return
	var p: Dictionary = players[slot]
	if not p.active or p.bot:
		return
	if stage == DRAFT:
		match action:
			"left": p.choice = posmod(p.choice - 1, 3)
			"right": p.choice = posmod(p.choice + 1, 3)
			"confirm": p.request = p.choice
	elif stage == BUILD and not p.placed:
		match action:
			"left": _move_cursor(slot, -1)
			"right": _move_cursor(slot, 1)
			"confirm": _place(slot, p.cursor)

func _move_cursor(slot: int, direction: int) -> void:
	var p: Dictionary = players[slot]
	var options := studs(slot)
	if not options.is_empty():
		p.cursor = options[posmod(options.find(p.cursor) + direction, options.size())]

func _best_center(surface: PackedInt32Array, size: Vector2i, anchor: int = CENTER) -> int:
	var best := -1
	var best_level := -1
	for x in legal_centers(surface, size.x):
		var level := surface[x]
		if level > best_level or (level == best_level and absi(x - anchor) < absi(best - anchor)):
			best = x
			best_level = level
	return best

func _place(slot: int, x: int, automatic: bool = false) -> void:
	var p: Dictionary = players[slot]
	var size := fit(slot)
	var level := landing(p.surface, x, size.x)
	if p.placed or level < 0:
		return
	p.placed = true
	p.automatic = automatic
	p.last_place = tick
	var blocks: PackedInt32Array = p.blocks
	blocks.append(x | (level << 4) | (size.x << 9) | (size.y << 12))
	p.blocks = blocks
	_raise_surface(p, Vector4i(x, level, size.x, size.y))

static func _raise_surface(player: Dictionary, block: Vector4i) -> void:
	var surface: PackedInt32Array = player.surface
	var radius := block.z >> 1
	for x in range(block.x - radius, block.x + radius + 1):
		surface[x] = block.y + block.w
	player.surface = surface
	player.score = maxi(player.score, block.y + block.w)

func _resolve_draft() -> void:
	for slot in priority_order():
		var p: Dictionary = players[slot]
		var request: int = p.request
		if request > BASIC and awards[request] < 0 and not legal_centers(p.surface, mold(request).x).is_empty():
			awards[request] = slot
			p.piece = request
		p.cursor = _best_center(p.surface, fit(slot))
	stage = BUILD

func _start_next_wave() -> void:
	if wave == WAVES - 1:
		phase = "finished"
		return
	wave += 1
	wave_ticks = 0
	settle_ticks = 0
	stage = DRAFT
	awards.fill(-1)
	for slot in occupied:
		var p: Dictionary = players[slot]
		p.choice = BASIC
		p.request = NO_REQUEST
		p.piece = BASIC
		p.placed = false
		p.automatic = false

func _auto_place(slot: int) -> void:
	var p: Dictionary = players[slot]
	var size := fit(slot)
	if landing(p.surface, p.cursor, size.x) < 0:
		p.cursor = _best_center(p.surface, size)
	if p.cursor < 0:
		p.piece = BASIC
		p.cursor = _best_center(p.surface, fit(slot))
	_place(slot, p.cursor, true)

func _bot_draft(slot: int) -> void:
	var p: Dictionary = players[slot]
	var tall := mold(TALL)
	var top := _best_center(p.surface, tall)
	var wide := _best_center(p.surface, WIDE_MOLD)
	# Builders ask for the mold that grows their tower now, filtering out
	# foundations that strand their higher stud on the last waves.
	if top >= 0 and (p.surface[top] + tall.y > p.score or wide < 0):
		p.choice = TALL
	elif wide >= 0 and wave < WAVES - 1:
		p.choice = WIDE
	p.request = p.choice

func _bot_build(slot: int) -> void:
	var p: Dictionary = players[slot]
	var size := fit(slot)
	var upcoming := mold(TALL, 1)
	var best_value := -1
	for x in legal_centers(p.surface, size.x):
		var level: int = p.surface[x]
		var projected: PackedInt32Array = p.surface.duplicate()
		for j in range(x - (size.x >> 1), x + (size.x >> 1) + 1):
			projected[j] = level + size.y
		var next_center := _best_center(projected, upcoming)
		var growth: int = projected[next_center] + upcoming.y if next_center >= 0 else 0
		var value := maxi(p.score, level + size.y) * 24 + growth * 5 - absi(x - CENTER - int(p.style) + 2)
		if value > best_value:
			p.cursor = x
			best_value = value
	_place(slot, p.cursor)

func step(delta: float) -> void:
	_carry += delta * HZ
	while _carry >= 1.0 and phase != "finished":
		_carry -= 1.0
		if phase == "countdown":
			countdown = maxf(0.0, countdown - 1.0 / HZ)
			if countdown < 0.5 / HZ:
				countdown = 0.0
				phase = "running"
		else:
			_advance()

func _advance() -> void:
	tick += 1
	elapsed = float(tick) / HZ
	wave_ticks += 1
	match stage:
		DRAFT:
			for slot in occupied:
				var p: Dictionary = players[slot]
				if p.bot and wave_ticks >= 56 + p.style * 19 and p.request < 0:
					_bot_draft(slot)
			if wave_ticks >= DRAFT_TICKS:
				_resolve_draft()
		BUILD:
			var all_placed := true
			for slot in occupied:
				var p: Dictionary = players[slot]
				if p.placed:
					continue
				if p.bot and wave_ticks >= DRAFT_TICKS + 55 + p.style * 24:
					_bot_build(slot)
				elif wave_ticks >= WAVE_TICKS - SETTLE_TICKS:
					_auto_place(slot)
				all_placed = all_placed and p.placed
			if all_placed:
				stage = SETTLE
		SETTLE:
			settle_ticks += 1
			if settle_ticks >= SETTLE_TICKS:
				_start_next_wave()

func take_over(slot: int) -> void:
	if slot in occupied:
		players[slot].bot = true

func remaining() -> float:
	match stage:
		DRAFT: return maxf(0.0, float(DRAFT_TICKS - wave_ticks) / HZ)
		BUILD: return maxf(0.0, float(WAVE_TICKS - SETTLE_TICKS - wave_ticks) / HZ)
	return maxf(0.0, float(SETTLE_TICKS - settle_ticks) / HZ)

func ranking() -> Array:
	var order := occupied.duplicate()
	order.sort_custom(func(a, b):
		return players[a].score > players[b].score if players[a].score != players[b].score else a < b)
	return order

func winners() -> Array:
	var order := ranking()
	if order.is_empty():
		return order
	var high: int = players[order[0]].score
	return order.filter(func(slot): return players[slot].score == high)

func snapshot() -> Dictionary:
	var seats: Array = []
	for p in players:
		var flags: int = p.choice | ((p.request + 1) << 2) | (p.piece << 4) | (p.cursor << 6)
		flags |= (int(p.placed) << 10) | (int(p.automatic) << 11) | (int(p.bot) << 12) | (p.style << 13)
		seats.append([flags, p.last_place, p.blocks.duplicate()])
	return {"id": round_id, "phase": phase, "stage": stage, "countdown": countdown, "tick": tick,
		"wave": wave, "wave_ticks": wave_ticks, "settle_ticks": settle_ticks,
		"start": priority_start, "molds": mold_start, "awards": awards.duplicate(), "seats": seats}

func apply_snapshot(data: Dictionary) -> void:
	round_id = int(data.id)
	phase = str(data.phase)
	stage = str(data.stage)
	countdown = float(data.countdown)
	tick = int(data.tick)
	elapsed = float(tick) / HZ
	wave = int(data.wave)
	wave_ticks = int(data.wave_ticks)
	settle_ticks = int(data.settle_ticks)
	priority_start = int(data.start)
	mold_start = int(data.molds)
	awards = data.awards.duplicate()
	for i in SEATS:
		var seat: Array = data.seats[i]
		var p: Dictionary = players[i]
		var flags: int = seat[0]
		p.choice = flags & 3
		p.request = ((flags >> 2) & 3) - 1
		p.piece = (flags >> 4) & 3
		p.cursor = (flags >> 6) & 15
		p.placed = (flags >> 10) & 1 != 0
		p.automatic = (flags >> 11) & 1 != 0
		p.bot = (flags >> 12) & 1 != 0
		p.style = (flags >> 13) & 7
		p.last_place = int(seat[1])
		p.blocks = seat[2].duplicate()
		p.score = 0
		var surface: PackedInt32Array = p.surface
		surface.fill(0)
		p.surface = surface
		for block in p.blocks:
			_raise_surface(p, block_parts(block))
