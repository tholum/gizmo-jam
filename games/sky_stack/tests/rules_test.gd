extends SceneTree

const Model = preload("res://games/sky_stack/model.gd")

func _initialize() -> void:
	_placement()
	_priority()
	_contest()
	_pacing()
	_snapshots()
	_balance()
	print("SKY STACK RULES PASS")
	quit()

func _round(humans: Array, bots: Array = [], seed_value: int = 13, id: int = 1) -> RefCounted:
	var model := Model.new()
	var slots := []
	for slot in Model.SEATS:
		slots.append({"name": "P%d" % (slot + 1), "peer": slot + 1, "bot": slot in bots,
			"active": slot in humans or slot in bots})
	model.begin(seed_value, slots, id)
	model.step(Model.COUNTDOWN)
	assert(model.phase == "running" and model.tick == 0)
	return model

func _request(model: RefCounted, slot: int, piece: int) -> void:
	var p: Dictionary = model.players[slot]
	while p.choice != piece:
		model.command(slot, "right", true)
	model.command(slot, "confirm", true)

func _place_all(model: RefCounted) -> void:
	for slot in model.occupied:
		model.command(slot, "confirm", true)

func _placement() -> void:
	var surface := PackedInt32Array([0, 0, 0, 2, 2, 0, 0, 0, 0])
	assert(Model.landing(surface, 4, 3) == 2, "center and adjacent stud are enough for 3")
	assert(Model.landing(surface, 4, 5) == -1, "5 needs 3 supported studs")
	assert(Model.landing(surface, 5, 3) == -1, "center cannot hang off the side")
	assert(Model.landing(surface, 0, 3) == -1, "over the bay fence")
	assert(Model.landing(surface, 0, 1) == 0)
	assert(Model.landing(PackedInt32Array([0, 0, 4, 2, 2, 2, 0, 0, 0]), 4, 5) == -1,
		"three low contacts cannot collide with a higher block")
	var model := _round([0])
	model.players[0].surface = PackedInt32Array([0, 3, 0, 0, 1, 3, 1, 0, 0])
	model.step(3)
	assert(model.fit(0) == Model.SINGLE_MOLD and model.studs(0).size() == Model.LANES)
	model.command(0, "confirm", true)
	assert(model.players[0].score == 4)

func _priority() -> void:
	for slots in [[1, 5], [0, 3, 5], [0, 1, 3, 5], [0, 1, 2, 3, 4, 5]]:
		var model := _round(slots)
		var firsts := {}
		for wave in Model.WAVES:
			var queue: Array[int] = model.priority_order()
			assert(queue.size() == slots.size())
			for slot in slots:
				assert(queue.count(slot) == 1)
			var first := queue[0]
			firsts[first] = int(firsts.get(first, 0)) + 1
			var next: Array[int] = model.priority_order(1)
			assert(next[0] == queue[1])
			model.step(float(Model.DRAFT_TICKS) / Model.HZ)
			_place_all(model)
			model.step((Model.SETTLE_TICKS + 1.0) / Model.HZ)
		assert(firsts.size() == slots.size())
		assert(int(firsts.values().max()) - int(firsts.values().min()) <= 1)

func _contest() -> void:
	var model := _round([0, 2, 3, 5])
	var order: Array[int] = model.priority_order()
	_request(model, order[0], Model.TALL)
	_request(model, order[1], Model.TALL)
	_request(model, order[2], Model.WIDE)
	_request(model, order[3], Model.WIDE)
	model.step((Model.DRAFT_TICKS - 1.0) / Model.HZ)
	assert(model.stage == Model.DRAFT and model.awards[Model.TALL] == -1)
	model.step(1.0 / Model.HZ)
	assert(model.stage == Model.BUILD)
	assert(model.awards[Model.TALL] == order[0] and model.awards[Model.WIDE] == order[2])
	assert(model.players[order[1]].piece == Model.BASIC and model.players[order[3]].piece == Model.BASIC)
	var initial: int = model.players[order[0]].cursor
	model.command(order[0], "left", false)
	assert(model.players[order[0]].cursor == initial, "release is never a second move")
	model.command(order[0], "left", true)
	assert(model.players[order[0]].cursor != initial)
	var cursor: int = model.players[order[0]].cursor
	model.step(10)
	assert(model.stage == Model.SETTLE)
	assert(model.players[order[0]].automatic and model.players[order[0]].score == 3)
	assert(Model.block_parts(model.players[order[0]].blocks[0]).x == cursor)
	assert(model.players[order[1]].automatic and model.players[order[1]].score == 1)
	model.step(2)
	assert(model.wave == 1 and model.stage == Model.DRAFT and model.priority_order()[0] == order[1])
	for slot in model.occupied:
		assert(model.players[slot].request == Model.NO_REQUEST and not model.players[slot].placed)
	var slots: Array = model.players.duplicate(true)
	model.begin(13, slots, 2)
	assert(model.phase == "countdown" and model.wave == 0 and model.occupied.size() == 4)
	for slot in model.occupied:
		assert(model.players[slot].blocks.is_empty() and model.players[slot].last_place == -1)
	assert(model.priority_order()[0] == order[1], "same seed on rematch rotates initial seat")

func _pacing() -> void:
	for humans in [[0], [0, 5], [0, 2, 4], [0, 1, 2, 3, 4, 5]]:
		var quick := _round(humans)
		for unused in Model.WAVES:
			quick.step(3)
			_place_all(quick)
			quick.step(2.0 + 1.0 / Model.HZ)
		assert(quick.phase == "finished" and quick.tick == Model.WAVES * (5 * Model.HZ + 1))
		assert(quick.winners().size() == humans.size())
		for slot in humans:
			assert(quick.players[slot].blocks.size() == Model.WAVES and quick.players[slot].score == 6)
		var idle := _round(humans)
		idle.step(90)
		assert(idle.phase == "finished" and idle.tick == Model.WAVES * Model.WAVE_TICKS)
		assert(idle.ranking().size() == humans.size())
		for slot in humans:
			assert(idle.players[slot].blocks.size() == 6 and idle.players[slot].automatic)
	var mixed := _round([0, 5], [2, 4])
	mixed.take_over(5)
	for unused in Model.WAVES:
		_request(mixed, 0, Model.TALL)
		mixed.step(3)
		_place_all(mixed)
		while mixed.stage != Model.DRAFT and mixed.phase != "finished":
			mixed.step(1.0 / Model.HZ)
	assert(mixed.tick < 50 * Model.HZ, "two humans plus two bots need no deadline wait")
	for slot in mixed.occupied:
		assert(mixed.players[slot].blocks.size() == Model.WAVES)

func _snapshots() -> void:
	var live := _round([0, 1, 5], [3])
	var client := _round([0, 1, 5], [3], 99)
	for interval in [0.75, 2.25, 0.8, 1.3, 6.0, 7.0, 34.0, 90.0]:
		live.step(interval)
		for slot in [0, 1, 5]:
			live.command(slot, "right", true)
			live.command(slot, "confirm", true)
		var wire := var_to_bytes(live.snapshot()).compress(FileAccess.COMPRESSION_DEFLATE)
		assert(wire.size() < 1024)
		client.apply_snapshot(bytes_to_var(wire.decompress_dynamic(1024 * 8, FileAccess.COMPRESSION_DEFLATE)))
		assert(var_to_bytes(client.snapshot()) == var_to_bytes(live.snapshot()))
		for slot in live.occupied:
			assert(client.players[slot].surface == live.players[slot].surface)
			assert(client.players[slot].score == live.players[slot].score)
		assert(client.ranking() == live.ranking())
		assert(client.priority_order() == live.priority_order())
		assert(client.mold(Model.TALL, 1) == live.mold(Model.TALL, 1))

func _scripted(model: RefCounted, first_request: int = Model.TALL) -> Array:
	for wave in Model.WAVES:
		for slot in model.occupied:
			_request(model, slot, first_request if slot == 0 and wave == 0 else Model.TALL)
		model.step(3)
		_place_all(model)
		model.step(2.0 + 1.0 / Model.HZ)
	var heights := []
	for slot in model.occupied:
		heights.append(model.players[slot].score)
	return heights

func _balance() -> void:
	var tall := _round([0, 2, 5])
	var basic := _round([0, 2, 5])
	var wide := _round([0, 2, 5])
	for model in [tall, basic, wide]:
		model.mold_start = 1
		model.priority_start = 1
	assert(_scripted(tall) == [8, 10, 10])
	assert(_scripted(basic, Model.BASIC) == [8, 10, 10])
	assert(_scripted(wide, Model.WIDE) == [10, 10, 10], "a foundation can turn a loss into a tie")

	for count in [2, 3, 6]:
		var totals := PackedInt32Array()
		totals.resize(count)
		var trials := 180
		for seed_value in trials:
			var model := _round(range(count), [], seed_value)
			var heights := _scripted(model)
			for slot in count:
				totals[slot] += heights[slot]
		var spread := float(Array(totals).max() - Array(totals).min()) / trials
		assert(spread < 0.50, "identical strategies must not systematically favor a seat")
