extends RefCounted
## The server owns this simulation. Rendering and networking consume snapshots.

const SEATS := 6
const MAX_HITS := 7
const JUMP_DURATION := 0.68
const JUMP_CLEARANCE := 0.36
const JUMP_BUFFER := 0.20
const SOLO_DURATION := 90.0
const BOT_NAMES := ["BOLT", "NOVA", "ECHO", "FLUX", "PIXEL", "COMET"]

var players: Array = []
var waves: Array = []
var elapsed := 0.0
var countdown := 3.0
var progress := 0.0
var speed := 0.68
var phase := "countdown"
var round_id := 0
var rng := RandomNumberGenerator.new()
var next_wave := 1.35
var wave_id := 0
var practice := false
var active_count := SEATS

func begin(seed_value: int, slots: Array, id: int = 1, endless: bool = false) -> void:
	rng.seed = seed_value
	round_id = id
	practice = endless
	players.clear()
	waves.clear()
	elapsed = 0.0
	countdown = 3.0
	progress = 0.0
	speed = 0.68
	phase = "countdown"
	next_wave = 1.35
	wave_id = 0
	active_count = 0
	for i in SEATS:
		var seat: Dictionary = slots[i]
		var active: bool = seat.get("active", true)
		if active: active_count += 1
		players.append({"name": seat.name, "peer": seat.peer, "bot": seat.bot,
			"active": active, "hp": MAX_HITS if active else 0, "score": 0, "streak": 0, "best_streak": 0,
			"jump": -1.0, "jump_buffer": 0.0, "duck": false, "flash": 0.0, "out_at": -1.0,
			"planned": -1, "reaction": 0.25, "mistake": false})
	_generate_waves()

func _generate_waves() -> void:
	while next_wave < progress + 8.0:
		waves.append({"id": wave_id, "at": next_wave, "kind": "jump" if rng.randf() < 0.5 else "duck", "done": false})
		next_wave += rng.randf_range(1.05, 1.35)
		wave_id += 1

func command(slot: int, action: String, pressed: bool) -> void:
	if slot < 0 or slot >= players.size() or phase != "running":
		return
	var p: Dictionary = players[slot]
	if p.hp <= 0:
		return
	if action == "duck":
		p.duck = pressed
		if pressed: p.jump_buffer = 0.0
	elif action == "jump" and pressed:
		if float(p.jump) < 0.0:
			p.jump = 0.0
		elif float(p.jump) >= JUMP_DURATION - JUMP_BUFFER:
			p.jump_buffer = JUMP_BUFFER

static func jump_height(p: Dictionary) -> float:
	if float(p.jump) < 0.0:
		return 0.0
	return sin(clampf(float(p.jump) / JUMP_DURATION, 0.0, 1.0) * PI) * 0.95

static func clears(p: Dictionary, kind: String) -> bool:
	if kind == "jump":
		return jump_height(p) >= JUMP_CLEARANCE
	return p.duck and float(p.jump) < 0.0

func step(delta: float) -> void:
	if phase == "finished":
		return
	if countdown > 0.0:
		countdown = maxf(0.0, countdown - delta)
		if countdown <= 0.0:
			phase = "running"
		return
	elapsed += delta
	speed = minf(1.70, 0.68 + elapsed * 0.010)
	for i in players.size():
		var p: Dictionary = players[i]
		p.flash = maxf(0.0, float(p.flash) - delta)
		if float(p.jump) >= 0.0:
			p.jump += delta
			if float(p.jump) >= JUMP_DURATION:
				p.jump = -1.0
		if float(p.jump) < 0.0 and float(p.jump_buffer) > 0.0 and p.hp > 0:
			p.jump = 0.0
			p.jump_buffer = 0.0
		p.jump_buffer = maxf(0.0, float(p.jump_buffer) - delta)
		if p.bot and p.hp > 0:
			_bot_step(i)
	progress += speed * delta
	for wave in waves:
		if not wave.done and float(wave.at) <= progress:
			wave.done = true
			for p in players:
				if p.hp <= 0:
					continue
				if clears(p, wave.kind):
					p.score += 1
					p.streak += 1
					p.best_streak = maxi(p.best_streak, p.streak)
				else:
					p.hp -= 1
					p.streak = 0
					p.flash = 0.42
					if p.hp == 0:
						p.out_at = elapsed
						p.duck = false
						p.jump = -1.0
	waves = waves.filter(func(w): return float(w.at) > progress - 1.2)
	_generate_waves()
	var alive := players.filter(func(p): return p.hp > 0).size()
	var survived := alive == 1 and (active_count > 1 or elapsed >= SOLO_DURATION)
	if alive == 0 or (not practice and survived):
		phase = "finished"

func _bot_step(slot: int) -> void:
	var p: Dictionary = players[slot]
	var upcoming := next_obstacle()
	if upcoming.is_empty():
		return
	var eta := (float(upcoming.at) - progress) / speed
	if int(p.planned) != int(upcoming.id):
		p.planned = upcoming.id
		p.reaction = rng.randf_range(0.20, 0.36)
		p.mistake = rng.randf() < minf(0.44, 0.13 + elapsed * 0.002 + slot * 0.015)
		p.duck = false
	if eta < float(p.reaction) and not p.mistake:
		command(slot, upcoming.kind, true)

func next_obstacle() -> Dictionary:
	for w in waves:
		if not w.done:
			return w
	return {}

func take_over(slot: int) -> void:
	if slot >= 0 and slot < players.size() and players[slot].get("active", true):
		players[slot].bot = true
		players[slot].peer = 0
		players[slot].duck = false
		players[slot].jump_buffer = 0.0
		players[slot].name = str(players[slot].name).left(12) + " · BOT"

func ranking() -> Array:
	var order := range(players.size()).filter(func(i): return players[i].get("active", true))
	order.sort_custom(func(a, b):
		var pa: Dictionary = players[a]
		var pb: Dictionary = players[b]
		if (pa.hp > 0) != (pb.hp > 0):
			return pa.hp > 0
		if not is_equal_approx(float(pa.out_at), float(pb.out_at)):
			return float(pa.out_at) > float(pb.out_at)
		if pa.score != pb.score:
			return pa.score > pb.score
		return pa.hp > pb.hp)
	return order

func winners() -> Array:
	var order := ranking()
	if order.is_empty(): return []
	var best: Dictionary = players[order[0]]
	if order.size() == 1 and best.hp == 0: return []
	return order.filter(func(i):
		var p: Dictionary = players[i]
		return (p.hp > 0) == (best.hp > 0) and is_equal_approx(float(p.out_at), float(best.out_at)) and p.score == best.score and p.hp == best.hp)

func snapshot() -> Dictionary:
	return {"id": round_id, "players": players.duplicate(true), "waves": waves.duplicate(true),
		"elapsed": elapsed, "countdown": countdown, "progress": progress,
		"speed": speed, "phase": phase, "practice": practice}

func apply_snapshot(data: Dictionary) -> void:
	if int(data.get("id", -1)) != round_id:
		return
	players = data.players
	waves = data.waves
	elapsed = data.elapsed
	countdown = data.countdown
	progress = data.progress
	speed = data.speed
	phase = data.phase
	practice = data.practice
