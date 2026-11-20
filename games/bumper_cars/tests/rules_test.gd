extends SceneTree
## Platform timing, collision credit, optional seats and snapshot parity.

const Model = preload("res://games/bumper_cars/model.gd")

var checks := 0
var failures := 0

func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL ", label)

func fixture(active: Array = [0, 1, 2, 3, 4, 5], bots: bool = false) -> RefCounted:
	var seats: Array = []
	for i in Model.SEATS:
		seats.append({"name": "DRIVER %d" % (i + 1), "peer": i + 1 if not bots else 0,
			"bot": bots, "active": i in active})
	var model := Model.new()
	model.begin(415, seats, 44)
	return model

func _initialize() -> void:
	test_determinism()
	test_ring_drop()
	test_boost()
	test_sparse_slots()
	test_single_driver()
	print("BUMPER RULES ", "PASS" if failures == 0 else "FAILED", " (", checks, " checks)")
	quit(0 if failures == 0 else 1)

func test_determinism() -> void:
	var model := fixture([0, 1, 2, 3, 4, 5], true)
	var repeat := fixture([0, 1, 2, 3, 4, 5], true)
	model.step(Model.COUNTDOWN - Model.MAX_STEP)
	check(model.phase == "countdown" and model.countdown > 0.0, "countdown remains active before GO")
	model.step(Model.MAX_STEP)
	repeat.step(Model.COUNTDOWN)
	check(model.phase == "running" and model.elapsed == 0.0, "GO starts the running clock")
	model.step(Model.ROUND_TIME)
	repeat.step(Model.ROUND_TIME)
	check(model.phase == "finished" and model.snapshot() == repeat.snapshot()
		and model.ranking() == repeat.ranking(), "same seeded six-car round produces identical results")

func test_ring_drop() -> void:
	var model := fixture()
	model.step(Model.COUNTDOWN)
	var warn_at: float = Model.DROP_TIMES[0] - Model.WARN_TIME
	model.step(warn_at - Model.MAX_STEP)
	check(not model.warning() and model.ring_level == 0, "no warning before the four-second window")
	model.step(2.0 * Model.MAX_STEP)
	check(model.warning() and model.safe_radius() == Model.RADII[0], "warning leaves the outer ring intact")
	model.players[0].pos = Vector2.RIGHT * (Model.RADII[1] + 0.2)
	model.players[1].pos = Vector2.LEFT * (Model.RADII[1] - 0.2)
	model.step(Model.WARN_TIME - 2.0 * Model.MAX_STEP)
	check(model.ring_level == 0 and model.players[0].alive, "driver on warning ring is safe before the drop")
	model.step(2.0 * Model.MAX_STEP)
	check(model.ring_level == 1 and model.safe_radius() == Model.RADII[1] and not model.warning(), "the drop advances the safe radius once")
	check(not model.players[0].alive and model.players[1].alive, "the dropped ring takes only the outer driver")
	check(model.ranking().back() == 0 and model.players[1].kos == 0, "a ring drop ranks the fallen driver without awarding a KO")

func test_boost() -> void:
	var model := fixture()
	model.players[0].pos = Vector2(Model.RADII[0] - 1.9, 0)
	model.players[1].pos = Vector2(Model.RADII[0] - 0.15, 0)
	model.command(0, "right", true)
	model.command(0, "dash", true)
	check(model.boost_count == 0, "boost does not fire during countdown")
	model.step(Model.COUNTDOWN)
	model.command(0, "dash", true)
	model.command(0, "dash", true)
	model.step(0.18)
	check(model.boost_count == 1 and model.hit_count == 1, "boost cooldown allows one credited impact")
	check(model.players[0].alive and not model.players[1].alive and model.players[0].kos == 1,
		"an actual boost collision can shove a rival out and earn a KO")

func test_sparse_slots() -> void:
	var model := fixture([0, 2, 5])
	var guest := fixture([0, 2, 5])
	model.step(Model.COUNTDOWN)
	check(model.alive_count() == 3 and model.ranking() == [0, 2, 5], "sparse lineups rank only their three active slots")
	var inactive: Dictionary = model.players[1].duplicate()
	model.take_over(1)
	model.command(1, "right", true)
	model.take_over(0)
	model.step(Model.MAX_STEP)
	check(model.players[1] == inactive, "vacant driver cannot move, fall or be taken over")
	check(model.players[0].bot and model.players[0].peer == 0, "active takeover keeps the seat and drops peer ownership")
	model.players[0].pos = Vector2.RIGHT * (Model.RADII[0] + 1.0)
	model.players[2].pos = Vector2.LEFT * (Model.RADII[0] + 1.0)
	model.step(Model.MAX_STEP)
	model.step(0.7)
	check(model.phase == "finished" and model.winners() == [5], "one survivor ends a multi-driver round")
	check(model.players[1] == inactive and model.players[0].fall_time > 0.0, "only active falls animate after the round")
	var snapshot: Dictionary = bytes_to_var(var_to_bytes(model.snapshot()))
	guest.apply_snapshot(snapshot)
	check(guest.snapshot() == model.snapshot() and guest.ranking() == model.ranking()
		and guest.winners() == model.winners(), "sparse host and guest agree on synchronized state and placement")
	check(guest.active_count == 3 and not guest.players[1].alive and guest.players[1].fall_time == 0.0,
		"receiving a snapshot never fills a vacant launch slot")

func test_single_driver() -> void:
	var model := fixture([0])
	model.players[0].pos = Vector2.ZERO
	model.step(Model.COUNTDOWN)
	model.step(Model.ROUND_TIME - Model.MAX_STEP)
	check(model.phase == "running" and model.alive_count() == 1, "opponent-free player continues until the timer ends")
	model.step(2.0 * Model.MAX_STEP)
	check(model.elapsed == Model.ROUND_TIME and model.phase == "finished" and model.winners() == [0],
		"solo survival through timeout wins")
	model = fixture([0])
	model.players[0].pos = Vector2.RIGHT * (Model.RADII[0] + 0.1)
	model.step(Model.COUNTDOWN)
	model.step(Model.MAX_STEP)
	check(model.phase == "finished" and model.alive_count() == 0 and model.winners().is_empty(), "solo fall ends without a winner")
