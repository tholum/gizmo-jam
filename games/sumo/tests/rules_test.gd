extends SceneTree
## Shove timing, ring-out attribution, respawns, and deterministic results.

const Model = preload("res://games/sumo/model.gd")
var failures := 0

func check(condition: bool, label: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL ", label)

func fixture() -> RefCounted:
	var seats := []
	for i in Model.SEATS:
		seats.append({"name": str(i), "peer": i + 1, "bot": false})
	var model := Model.new()
	model.begin(415, seats, 44)
	model.step(Model.COUNTDOWN)
	for i in Model.SEATS:
		model.players[i].pos = model.socket(i, 4.5)
	return model

func setup_pair(model: RefCounted) -> void:
	model.players[0].pos = Vector2(0, 0)
	model.players[0].face = 0.0
	model.players[1].pos = Vector2(1.2, 0)

func _initialize() -> void:
	var model := fixture()
	setup_pair(model)
	model.command(0, "shove", true)
	model.step(Model.STEP)
	check(model.players[0].strike_tick == 1 + Model.WINDUP, "windup tick")
	model.command(0, "up", true)
	model.command(0, "shove", true)
	model.step((Model.WINDUP - 1) * Model.STEP)
	check(model.hit_count == 0 and model.players[0].face == 0.0, "windup shows a committed aim before contact")
	model.step(Model.STEP)
	check(model.players[1].last_shove == 0 and model.strike_count == 1, "committed swing and cooldown")
	check(model.players[1].velocity.x > 5.0, "real shove imparts velocity")
	model.command(0, "up", false)
	model.command(0, "shove", true)
	model.step(0.4)
	check(model.strike_count == 1, "cooldown suppresses spam")

	model = fixture()
	setup_pair(model)
	model.tick = 30
	model.players[0].strike_tick = 31
	model.step(Model.STEP)
	var loose: float = model.players[1].velocity.length()
	model = fixture()
	setup_pair(model)
	model.step((Model.PLANT_DELAY + 2) * Model.STEP)
	check(model.players[1].planted, "release and delay plants feet")
	model.players[0].strike_tick = model.tick + 1
	model.step(Model.STEP)
	check(is_equal_approx(model.players[1].velocity.length() / loose, Model.PLANTED_FORCE), "stance mitigates knockback")
	check(not model.players[1].planted, "impact breaks stance")

	model = fixture()
	setup_pair(model)
	model.players[1].guard_until = Model.GUARD
	model.players[0].strike_tick = 1
	model.step(Model.STEP)
	check(model.hit_count == 0, "spawn shield blocks credited shoves")
	model.players[1].face = PI
	model.command(1, "shove", true)
	model.step(0.3)
	check(model.strike_count == 1, "spawn shield blocks outgoing shove")

	model = fixture()
	setup_pair(model)
	model.players[1].pos = Vector2(0.0, -1.2)
	model.players[0].strike_tick = 1
	model.step(Model.STEP)
	check(model.hit_count == 0, "side target is outside the cone")
	model.players[1].pos = Vector2(Model.SHOVE_RANGE + 0.01, 0)
	model.players[0].strike_tick = 2
	model.step(Model.STEP)
	check(model.hit_count == 0, "out of reach")

	model = fixture()
	model.players[0].pos = Vector2(4.65, 0)
	model.players[1].pos = Vector2(Model.RADIUS - 0.020, 0)
	model.command(0, "right", true)
	model.step(0.18)
	check(model.players[1].alive and model.players[1].last_shove == -1, "normal crowding cannot award a shove or passively eject")
	model.command(1, "right", true)
	model.step(0.1)
	check(model.players[1].outs == 1 and model.players[1].last_credit == -1, "self-fall has no credit")
	var returning: int = model.players[1].respawn_tick
	model.command(1, "right", false)
	model.step((returning - model.tick - 1) * Model.STEP)
	check(not model.players[1].alive, "still out one tick before return")
	model.step(Model.STEP)
	check(model.players[1].alive and model.players[1].pos.length() < 2.0 and model.players[1].guard_until == model.tick + Model.GUARD, "1.4s return near center with guard")

	model = fixture()
	setup_pair(model)
	model.players[0].strike_tick = 1
	model.step(Model.STEP)
	model.players[2].pos = Vector2(4.2, 0)
	model.players[2].face = 0.0
	model.players[1].pos = Vector2(5.6, 0)
	model.players[2].strike_tick = 2
	model.step(0.1)
	check(model.players[1].last_credit == 2 and model.players[0].score == 0 and model.players[2].score == 1, "last real shove gets credit")
	model.players[3].last_shove = 0
	model.players[3].hit_tick = model.tick - Model.CREDIT
	model.players[3].pos = Vector2(Model.RADIUS + 0.03, 0)
	model.step(Model.STEP)
	check(model.players[3].last_credit == -1 and model.players[0].score == 0, "credit expires")

	model = fixture()
	model.tick = Model.ROUND_TICKS - 1
	model.players[0].pos = Vector2(-0.56, 5.77)
	model.players[1].pos = Vector2(0.56, 5.77)
	model.players[0].face = 0.0
	model.players[1].face = PI
	for i in 2:
		model.players[i].strike_tick = Model.ROUND_TICKS
	model.step(Model.STEP)
	check(model.phase == "finished" and model.elapsed == Model.ROUND_TIME, "exact 90 sec finish")
	check(model.players[0].score == 1 and model.players[1].score == 1, "reciprocal same-tick scoring survives the buzzer")
	check(model.winners() == [0, 1], "equal leaders draw")
	var guest := fixture()
	var payload := var_to_bytes(model.snapshot()).compress(FileAccess.COMPRESSION_DEFLATE)
	guest.apply_snapshot(bytes_to_var(payload.decompress_dynamic(65536, FileAccess.COMPRESSION_DEFLATE)))
	check(guest.snapshot() == model.snapshot() and guest.winners() == model.winners(), "net v1 snapshot round trip")

	var slots := []
	for i in Model.SEATS:
		slots.append({"name": str(i), "peer": i + 1, "bot": true})
	model = Model.new()
	guest = Model.new()
	model.begin(918, slots)
	guest.begin(918, slots)
	for i in 3100:
		model.step(3 * Model.STEP)
	for i in 5580:
		guest.step(Model.STEP)
	check(model.snapshot() == guest.snapshot(), "determinism with different step batches")
	print("SUMO RULES ", "PASS" if failures == 0 else "FAILED")
	quit(0 if failures == 0 else 1)
