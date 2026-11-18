extends RefCounted
## Pulse: the simulation. A beat ticks faster and faster; press on the beat
## to score, press off it and your streak resets and you are locked out for a
## moment. Highest score after ROUND_TIME wins.
##
## The surface main.gd and Session rely on (every game model has it):
##   players          six dictionaries with at least name, peer, bot
##   phase            "countdown", "running" or "finished"
##   countdown        seconds left before GO (main draws 3-2-1)
##   elapsed          seconds since GO
##   round_id         the round number from begin()
##   begin(seed, slots, id)   a fresh round; slots from Session.slots()
##   command(slot, action, pressed)  one player's input (server only)
##   step(delta)      advance the simulation (server only)
##   take_over(slot)  a player left: a bot plays their seat from now on
##   ranking()        seats best first; winners() seats sharing first place
##   snapshot() / apply_snapshot(data)  server state for clients; must carry
##                    "id": round_id and stay well under 1 KB
## Everything random comes from `rng`, seeded by the server, so bots behave
## the same on every replay of a seed.

const SEATS := 6
const ROUND_TIME := 30.0
const COUNTDOWN := 3.0
## Seconds between beats at the start and at the end of a round.
const BEAT_START := 0.8
const BEAT_END := 0.45
## A press counts if it lands this close to a beat.
const WINDOW := 0.13
const LOCKOUT := 0.35

var rng := RandomNumberGenerator.new()
var players: Array = []
var phase := "countdown"
var countdown := COUNTDOWN
var elapsed := 0.0
var round_id := 0
## Time of the next beat (in `elapsed` seconds), and the one just gone.
var next_beat := 0.0
var last_beat := -10.0
var beat_count := 0

func begin(seed_value: int, slots: Array, id: int = 1, _endless: bool = false) -> void:
	rng.seed = seed_value
	round_id = id
	phase = "countdown"
	countdown = COUNTDOWN
	elapsed = 0.0
	next_beat = BEAT_START
	last_beat = -10.0
	beat_count = 0
	players.clear()
	for i in SEATS:
		var seat: Dictionary = slots[i]
		players.append({"name": seat.name, "peer": seat.peer, "bot": seat.bot,
			"score": 0, "streak": 0, "best_streak": 0, "misses": 0, "lock": 0.0,
			"scored_beat": -1, "flash": 0.0, "bot_press": -1.0, "skill": rng.randf_range(0.55, 0.85)})

func beat_interval() -> float:
	return lerpf(BEAT_START, BEAT_END, clampf(elapsed / ROUND_TIME, 0.0, 1.0))

## 0 on a beat, rising to 1 just before the next: drives the pulse ring.
func beat_phase() -> float:
	var span := maxf(0.01, next_beat - last_beat)
	return clampf((elapsed - last_beat) / span, 0.0, 1.0)

func command(slot: int, action: String, pressed: bool) -> void:
	if action != "jump" or not pressed or phase != "running": return
	if slot < 0 or slot >= players.size() or players[slot].bot: return
	_press(slot)

func _press(slot: int) -> void:
	var p: Dictionary = players[slot]
	if p.lock > 0.0: return
	var near_last := elapsed - last_beat
	var near_next := next_beat - elapsed
	var beat := -1
	if near_last <= WINDOW: beat = beat_count
	elif near_next <= WINDOW: beat = beat_count + 1
	if beat >= 0 and beat != p.scored_beat:
		p.scored_beat = beat
		p.streak += 1
		p.best_streak = maxi(p.best_streak, p.streak)
		p.score += 1 + mini(p.streak / 5, 3)
		p.flash = 1.0
	else:
		p.streak = 0
		p.misses += 1
		p.lock = LOCKOUT
		p.flash = -1.0

func step(delta: float) -> void:
	if phase == "finished": return
	if phase == "countdown":
		countdown -= delta
		if countdown <= 0.0:
			countdown = 0.0
			phase = "running"
		return
	elapsed += delta
	while elapsed >= next_beat:
		last_beat = next_beat
		beat_count += 1
		next_beat += beat_interval()
		_plan_bots()
	for i in players.size():
		var p: Dictionary = players[i]
		p.lock = maxf(0.0, p.lock - delta)
		p.flash = move_toward(p.flash, 0.0, delta * 3.0)
		if p.bot and p.bot_press >= 0.0 and elapsed >= p.bot_press:
			p.bot_press = -1.0
			_press(i)
	if elapsed >= ROUND_TIME:
		phase = "finished"

## Each bot decides once per beat when it will press: near the next beat if
## it gets this one right, somewhere off the beat if not.
func _plan_bots() -> void:
	for p in players:
		if not p.bot: continue
		if rng.randf() < p.skill:
			p.bot_press = next_beat + rng.randf_range(-WINDOW * 0.8, WINDOW * 0.8)
		elif rng.randf() < 0.5:
			p.bot_press = last_beat + (next_beat - last_beat) * 0.5
		else:
			p.bot_press = -1.0

func take_over(slot: int) -> void:
	if slot >= 0 and slot < players.size():
		players[slot].bot = true

func ranking() -> Array:
	var order: Array = range(players.size())
	order.sort_custom(func(a, b):
		if players[a].score != players[b].score: return players[a].score > players[b].score
		return a < b)
	return order

func winners() -> Array:
	var best := 0
	for p in players: best = maxi(best, p.score)
	var list: Array = []
	for i in players.size():
		if players[i].score == best: list.append(i)
	return list

func snapshot() -> Dictionary:
	var seats: Array = []
	for p in players:
		seats.append([p.score, p.streak, p.best_streak, p.misses, snappedf(p.flash, 0.01), p.bot])
	return {"id": round_id, "phase": phase, "countdown": snappedf(countdown, 0.01), "elapsed": snappedf(elapsed, 0.001),
		"next": snappedf(next_beat, 0.001), "last": snappedf(last_beat, 0.001), "beat": beat_count, "seats": seats}

func apply_snapshot(data: Dictionary) -> void:
	phase = str(data.get("phase", phase))
	countdown = float(data.get("countdown", countdown))
	elapsed = float(data.get("elapsed", elapsed))
	next_beat = float(data.get("next", next_beat))
	last_beat = float(data.get("last", last_beat))
	beat_count = int(data.get("beat", beat_count))
	var seats: Array = data.get("seats", [])
	for i in mini(seats.size(), players.size()):
		var s: Array = seats[i]
		if s.size() < 6: continue
		var p: Dictionary = players[i]
		p.score = int(s[0]); p.streak = int(s[1]); p.best_streak = int(s[2]); p.misses = int(s[3])
		p.flash = float(s[4]); p.bot = bool(s[5])
