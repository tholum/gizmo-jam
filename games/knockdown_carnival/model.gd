extends RefCounted
## Host-authoritative authored puck paths. No physics or frame ordering enters scoring.

const SEATS := 6
const LINES := 5
const FIRST_SHARED := SEATS * 3
const TARGETS := FIRST_SHARED + SEATS
const HZ := 60
const STEP := 1.0 / HZ
const COUNTDOWN := 3.0
const LAYOUT_TICKS := 30 * HZ
const ROUND_TICKS := 3 * LAYOUT_TICKS
const NO_TICK := -600
const DIRECT_TRAVEL := 23
const BANK_TRAVEL := 42
const RELOAD := 66
const REPEAT_RELOAD := 113
const FLIP_TICKS := 38
const PLAYER_ROW := 11
const TARGET_ROW := 5
const HEADER := SEATS * PLAYER_ROW + TARGETS * TARGET_ROW

var players: Array[Dictionary] = []
var targets: Array[Dictionary] = []
var pucks: Array[Dictionary] = []
var tick := 0
var round_id := 0
var phase := "countdown"
var countdown := COUNTDOWN
var elapsed := 0.0
var layout := 0
var layout_turn := 0
var _occupied: Array[int] = []
var _owed := 0.0
var _count_ticks := int(COUNTDOWN * HZ)
var _rng := RandomNumberGenerator.new()

func begin(seed_value: int, slots: Array, id: int = 1, _endless: bool = false) -> void:
	_rng.seed = seed_value
	round_id = id
	tick = 0
	elapsed = 0.0
	countdown = COUNTDOWN
	_count_ticks = int(COUNTDOWN * HZ)
	phase = "countdown"
	layout = 0
	_owed = 0.0
	players.clear()
	pucks.clear()
	_occupied.clear()
	for slot in SEATS:
		var seat: Dictionary = slots[slot]
		if seat.get("active", true):
			_occupied.append(slot)
		players.append({"slot": slot, "name": seat.name, "peer": seat.peer, "bot": seat.bot,
			"active": seat.get("active", true), "score": 0, "aim": 2, "shot_line": -1,
			"shot_tick": NO_TICK, "ready": 0, "last_score": NO_TICK, "points": 0, "joint": false,
			"held": 0, "next_aim": 0, "queued": false, "think": 16 + _rng.randi_range(0, 39)})
	_set_layout(0)

func _set_layout(index: int) -> void:
	layout = index
	layout_turn = _rng.randi_range(0, SEATS - 1)
	targets.clear()
	for id in TARGETS:
		var first := tick
		if is_shared(id):
			first += 134 if layout == 0 else 105
		targets.append({"down": NO_TICK, "up": first, "credit": 0})

func remaining() -> float:
	return (ROUND_TICKS - tick) * STEP

func layout_seconds() -> int:
	return ceili(((layout + 1) * LAYOUT_TICKS - tick) * STEP)

static func is_shared(id: int) -> bool:
	return id >= FIRST_SHARED

static func is_bank(line: int) -> bool:
	return line == 0 or line == LINES - 1

static func flight(line: int) -> int:
	return BANK_TRAVEL if is_bank(line) else DIRECT_TRAVEL

func destination(slot: int, line: int) -> int:
	if not is_bank(line):
		return slot * 3 + line - 1
	if line == 0:
		return FIRST_SHARED + slot
	# Each entrance is shared by the neighbors on either side of its edge.
	var index := _occupied.find(slot)
	var previous := _occupied[posmod(index - 1, _occupied.size())] if index >= 0 and _occupied.size() > 1 else posmod(slot - 1, SEATS)
	return FIRST_SHARED + previous

func linked(id: int, at: int = -1) -> int:
	if not is_shared(id) or layout == 0:
		return -1
	var t := tick if at < 0 else at
	var turn := layout_turn + floori(clampi(t - layout * LAYOUT_TICKS, 0, LAYOUT_TICKS - 1) / 600.0)
	var start := posmod(id - FIRST_SHARED - turn, SEATS)
	if start % (3 if layout == 2 else 2) == (2 if layout == 2 else 1):
		return -1
	return FIRST_SHARED + posmod(id - FIRST_SHARED + 1, SEATS)

func usable(id: int) -> bool:
	if not is_shared(id) or layout > 0:
		return true
	for slot in _occupied:
		if destination(slot, 0) == id or destination(slot, LINES - 1) == id:
			return true
	return false

func available(id: int, at: int) -> bool:
	return at >= int(targets[id].up)

func forecast(slot: int, line: int, at: int) -> int:
	if at > (layout + 1) * LAYOUT_TICKS:
		return 0
	var id := destination(slot, line)
	var count := 0
	while id >= 0 and available(id, at):
		count += 1
		id = linked(id, at)
	return count

func command(slot: int, action: String, pressed: bool) -> void:
	if phase == "finished" or slot < 0 or slot >= players.size():
		return
	var player := players[slot]
	if not player.active or player.bot:
		return
	match action:
		"left", "right":
			var bit := 1 if action == "left" else 2
			if pressed and (int(player.held) & bit) == 0:
				_aim(player, -1 if bit == 1 else 1)
				player.next_aim = tick + 16
			player.held = int(player.held) | bit if pressed else int(player.held) & ~bit
		"flick":
			if pressed and phase == "running" and tick >= int(player.ready):
				player.queued = true

func _aim(player: Dictionary, direction: int) -> void:
	player.aim = clampi(int(player.aim) + direction, 0, LINES - 1)

func take_over(slot: int) -> void:
	if slot >= 0 and slot < players.size() and players[slot].active:
		var player := players[slot]
		player.bot = true
		player.held = 0
		player.queued = false
		player.think = maxi(tick + 24, player.ready)

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
	# Resolve a boundary arrival in the old layout before the new board opens.
	_resolve_arrivals()
	if tick < ROUND_TICKS and tick % LAYOUT_TICKS == 0:
		_set_layout(layout + 1)
	for slot in _occupied:
		var player := players[slot]
		if player.bot:
			_bot(player)
		elif player.held in [1, 2] and tick >= int(player.next_aim):
			_aim(player, -1 if player.held == 1 else 1)
			player.next_aim = tick + 9
		if player.queued:
			_launch(player)
			player.queued = false
	if tick >= ROUND_TICKS:
		phase = "finished"

func _launch(player: Dictionary) -> void:
	var line: int = player.aim
	var land := tick + flight(line)
	if tick < int(player.ready) or land > (layout + 1) * LAYOUT_TICKS:
		return
	player.ready = tick + (REPEAT_RELOAD if player.shot_line == line else RELOAD)
	player.shot_line = line
	player.shot_tick = tick
	pucks.append({"slot": player.slot, "line": line, "born": tick, "land": land})

func _resolve_arrivals() -> void:
	if pucks.is_empty():
		return
	# Accumulate all direct and propagated hits before changing the board.
	var credits := PackedInt32Array()
	credits.resize(TARGETS)
	var any := false
	for puck in pucks:
		if puck.land != tick:
			continue
		var id := destination(puck.slot, puck.line)
		while id >= 0 and available(id, tick):
			credits[id] |= 1 << int(puck.slot)
			any = true
			id = linked(id)
	pucks = pucks.filter(func(puck): return puck.land > tick)
	if not any:
		return
	var totals := PackedInt32Array([0, 0, 0, 0, 0, 0])
	var joint := PackedInt32Array([0, 0, 0, 0, 0, 0])
	for id in TARGETS:
		var mask := credits[id]
		if mask == 0:
			continue
		var target := targets[id]
		target.down = tick
		target.credit = mask
		# Personal lanes reset independently. Shared banks reset more slowly
		# and a small relay stagger creates hittable splits in a toppled chain.
		target.up = tick + (315 + posmod(id - FIRST_SHARED - layout_turn, 3) * 31 if is_shared(id)
			else 218 + id % 3 * 24)
		for slot in _occupied:
			if mask & (1 << slot):
				totals[slot] += 1
				joint[slot] |= int((mask & (mask - 1)) != 0)
	for slot in _occupied:
		if totals[slot] == 0:
			continue
		var player := players[slot]
		player.score += totals[slot]
		player.points = totals[slot]
		player.last_score = tick
		player.joint = joint[slot] != 0

func _bot(player: Dictionary) -> void:
	if tick < int(player.think) or tick < int(player.ready):
		return
	var best := -1
	var grade := 0.0
	for line in LINES:
		var land := tick + flight(line)
		var count := forecast(player.slot, line, land)
		var chance := _rng.randf_range(-0.22, 0.22)
		if is_bank(line):
			chance -= 0.34
			for puck in pucks:
				if puck.land < land and destination(puck.slot, puck.line) == destination(player.slot, line):
					chance -= 1.7
		var value := count + chance - (0.22 if line == int(player.shot_line) else 0.0)
		if count > 0 and value > grade:
			grade = value
			best = line
	if best >= 0:
		player.aim = best
		player.queued = true
		player.think = tick + _rng.randi_range(99, 153)
	else:
		player.think = tick + _rng.randi_range(24, 47)

func ranking() -> Array:
	var order := _occupied.duplicate()
	order.sort_custom(func(a, b): return players[a].score > players[b].score if players[a].score != players[b].score else a < b)
	return order

func winners() -> Array:
	var order := ranking()
	if order.is_empty():
		return []
	return order.filter(func(slot): return players[slot].score == players[order[0]].score)

func snapshot() -> Dictionary:
	var data := PackedByteArray()
	data.resize(HEADER)
	for slot in SEATS:
		var p := players[slot]
		var off := slot * PLAYER_ROW
		data.encode_u16(off, p.score)
		data.encode_u8(off + 2, p.aim | (int(p.bot) << 3) | (int(p.joint) << 4))
		data.encode_u8(off + 3, p.shot_line + 1)
		data.encode_s16(off + 4, p.shot_tick)
		data.encode_s16(off + 6, p.ready)
		data.encode_s16(off + 8, p.last_score)
		data.encode_u8(off + 10, p.points)
	for id in TARGETS:
		var target := targets[id]
		var off := SEATS * PLAYER_ROW + id * TARGET_ROW
		data.encode_s16(off, target.down)
		data.encode_s16(off + 2, target.up)
		data.encode_u8(off + 4, target.credit)
	return {"id": round_id, "tick": tick, "count": _count_ticks, "layout": layout, "turn": layout_turn, "state": data}

func apply_snapshot(snap: Dictionary) -> void:
	var data: PackedByteArray = snap.get("state", PackedByteArray())
	var next_tick := int(snap.get("tick", -1))
	var next_count := int(snap.get("count", -1))
	if snap.get("id", 0) != round_id or data.size() != HEADER or next_tick < tick or next_tick > ROUND_TICKS or next_count < 0 or next_count > _count_ticks:
		return
	tick = next_tick
	_count_ticks = next_count
	layout = clampi(int(snap.get("layout", 0)), 0, 2)
	layout_turn = posmod(int(snap.get("turn", 0)), SEATS)
	countdown = _count_ticks * STEP
	elapsed = tick * STEP
	phase = "countdown" if _count_ticks > 0 else ("finished" if tick >= ROUND_TICKS else "running")
	pucks.clear()
	for slot in SEATS:
		var p := players[slot]
		var off := slot * PLAYER_ROW
		var flags := data.decode_u8(off + 2)
		p.score = data.decode_u16(off)
		p.aim = clampi(flags & 7, 0, LINES - 1)
		p.bot = (flags & 8) != 0
		p.joint = (flags & 16) != 0
		p.shot_line = clampi(data.decode_u8(off + 3) - 1, -1, LINES - 1)
		p.shot_tick = data.decode_s16(off + 4)
		p.ready = data.decode_s16(off + 6)
		p.last_score = data.decode_s16(off + 8)
		p.points = data.decode_u8(off + 10)
		if p.active and p.shot_line >= 0 and p.shot_tick <= tick and tick < p.shot_tick + flight(p.shot_line):
			pucks.append({"slot": slot, "line": p.shot_line, "born": p.shot_tick, "land": p.shot_tick + flight(p.shot_line)})
	for id in TARGETS:
		var off := SEATS * PLAYER_ROW + id * TARGET_ROW
		targets[id] = {"down": data.decode_s16(off), "up": data.decode_s16(off + 2), "credit": data.decode_u8(off + 4)}
