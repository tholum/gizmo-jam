extends SceneTree
## Rules, input, snapshot and bot checks for the Live Wire simulation.

const Model = preload("res://scripts/livewire_model.gd")
const TICK := 1.0 / 60.0
const SNAPSHOT_LIMIT := 1200
const PUBLIC_KEYS := ["name", "peer", "bot", "x", "z", "face", "speed", "stun", "shove",
	"dash", "cool", "tiles", "best", "loops", "zaps", "shoves"]

var failures := 0
var finished := false
var frames := 0
var largest_snapshot := 0

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func _process(_delta: float) -> bool:
	# run() is synchronous, so still being here means a script error cut it short.
	frames += 1
	if frames > 2 and not finished:
		finished = true
		push_error("Live Wire tests stopped before the end")
		quit(1)
	return false

# ------------------------------------------------------------------ helpers

func seats(bots: bool = false) -> Array:
	var slots: Array = []
	for i in 6:
		slots.append({"name": "P%d" % i, "peer": 0 if bots else i + 1, "bot": bots})
	return slots

## A round that has just left the countdown. Seats are idle humans unless `bots`.
func fresh(seed_value: int = 7, bots: bool = false) -> Model:
	var game := Model.new()
	game.begin(seed_value, seats(bots))
	game.step(Model.COUNTDOWN + 0.1)
	return game

func run_for(game: Model, seconds: float) -> void:
	for i in roundi(seconds / TICK):
		game.step(TICK)

func cell(game: Model, q: int, r: int) -> int:
	return int(game.grid.index[Vector2i(q, r)])

func put(game: Model, slot: int, at: int) -> void:
	game.players[slot].x = game.grid.centers[at].x
	game.players[slot].z = game.grid.centers[at].y

func under(game: Model, slot: int) -> int:
	return game.grid.cell_at(Vector2(game.players[slot].x, game.players[slot].z))

func where(game: Model, slot: int) -> Vector2:
	return Vector2(game.players[slot].x, game.players[slot].z)

func paint(game: Model, slot: int, cells: Array) -> void:
	for at in cells:
		game.owners[at] = slot + 1

func owned(game: Model, slot: int) -> int:
	var total := 0
	for owner in game.owners:
		if owner == slot + 1:
			total += 1
	return total

func painted(game: Model) -> int:
	var total := 0
	for owner in game.owners:
		if owner != 0:
			total += 1
	return total

## The cells surrounding a group of cells.
func ring_around(game: Model, inside: Array) -> Array:
	var ring: Array = []
	for at in inside:
		for near in game.grid.neighbors[at]:
			if not inside.has(near) and not ring.has(near):
				ring.append(near)
	return ring

func wire(game: Model) -> PackedByteArray:
	return var_to_bytes(game.snapshot()).compress(FileAccess.COMPRESSION_DEFLATE)

func unwire(packed: PackedByteArray) -> Dictionary:
	return bytes_to_var(packed.decompress_dynamic(65536, FileAccess.COMPRESSION_DEFLATE))

func counts_match(game: Model) -> bool:
	for i in 6:
		if int(game.players[i].tiles) != owned(game, i):
			return false
	return true

func run() -> void:
	test_start_and_countdown()
	test_claim_and_repaint()
	test_lock()
	test_loop_capture()
	test_edge_is_not_a_wall()
	test_scripted_loop()
	test_surge_and_zap()
	test_dash()
	test_shove()
	test_board_bounds()
	test_overdrive()
	test_schedule_and_finish()
	test_ranking()
	test_take_over()
	test_ignored_input()
	test_snapshot()
	test_determinism()
	test_bots_dodge()
	test_bot_round()
	print("LIVEWIRE_TESTS %s (largest snapshot %d bytes)" % ["PASS" if failures == 0 else "FAIL: %d" % failures, largest_snapshot])
	finished = true
	quit(0 if failures == 0 else 1)

# -------------------------------------------------------------------- tests

func test_start_and_countdown() -> void:
	var game := Model.new()
	game.begin(7, seats())
	check(game.players.size() == 6, "Six runners must be created")
	check(game.phase == "countdown" and is_equal_approx(game.countdown, 3.0), "A round starts with a 3 s countdown")
	check(game.owners.size() == game.grid.count() and game.locks.size() == game.grid.count(), "One owner and one lock per cell")
	var distance := where(game, 0).length()
	for i in 6:
		var p: Dictionary = game.players[i]
		var at := where(game, i)
		check(int(game.owners[under(game, i)]) == i + 1 and int(p.tiles) == 1, "The starting tile belongs to its runner")
		check(absf(at.length() - distance) < 0.001 and distance > 2.0, "Runners start on a ring around the centre")
		check(absf(at.angle_to(where(game, (i + 1) % 6))) > deg_to_rad(59.0), "Runners start evenly spaced")
		check(Vector2(sin(float(p.face)), cos(float(p.face))).dot(-at.normalized()) > 0.999, "Runners start facing the centre")
		for key in PUBLIC_KEYS:
			check(p.has(key), "Runner state must include '%s'" % key)
	check(painted(game) == 6, "Only the starting tiles are painted at the start")
	var before := where(game, 0)
	game.command(0, "left", true)
	game.command(0, "dash", true)
	game.step(1.0)
	check(where(game, 0) == before, "Nothing moves in the countdown")
	check(float(game.players[0].dash) == 0.0 and float(game.players[0].cool) == 0.0, "No dashing in the countdown")
	check(painted(game) == 6 and game.elapsed == 0.0 and game.surges.is_empty(), "Nothing is claimed or fired in the countdown")
	check(game.phase == "countdown" and is_equal_approx(game.countdown, 2.0), "The countdown counts down")
	game.step(2.5)
	check(game.phase == "running" and game.countdown == 0.0 and game.elapsed == 0.0, "The countdown must start the round")
	game.step(TICK)
	check(float(game.players[0].x) < before.x, "A direction held through the countdown applies at GO")

func test_claim_and_repaint() -> void:
	var game := fresh()
	var start := where(game, 0)
	game.command(0, "left", true)
	run_for(game, 0.5)
	check(is_equal_approx(float(game.players[0].speed), Model.MOVE_SPEED), "A running runner reports MOVE_SPEED")
	check(is_equal_approx(sin(float(game.players[0].face)), -1.0), "Facing follows movement: left is -x")
	run_for(game, 0.5)
	game.command(0, "left", false)
	check(absf(start.x - float(game.players[0].x) - Model.MOVE_SPEED) < 0.01 and float(game.players[0].z) == start.y, "Left moves along -x at MOVE_SPEED")
	check(int(game.players[0].tiles) >= 3 and counts_match(game), "Running over tiles claims them")
	check(int(game.owners[under(game, 0)]) == 1, "The tile under a runner is theirs")
	check(int(game.players[0].best) == int(game.players[0].tiles), "best tracks the high-water mark")
	game.step(TICK)
	check(float(game.players[0].speed) == 0.0, "An idle runner has no speed")
	# Diagonals are normalised, and up is -z.
	var corner := where(game, 0)
	game.command(0, "right", true)
	game.command(0, "up", true)
	run_for(game, 0.5)
	game.command(0, "right", false)
	game.command(0, "up", false)
	var moved := where(game, 0) - corner
	check(absf(moved.length() - Model.MOVE_SPEED * 0.5) < 0.01, "Diagonal movement is not faster")
	check(moved.x > 0.0 and moved.y < 0.0 and is_equal_approx(moved.x, -moved.y), "Up-right moves along +x and -z")
	# Repainting somebody's tile once they have left it.
	var theirs := cell(game, 3, 0)
	check(int(game.owners[theirs]) == 1 and under(game, 0) != theirs, "Seat 0 painted its trail")
	var had := int(game.players[0].tiles)
	put(game, 1, theirs)
	game.step(TICK)
	check(int(game.owners[theirs]) == 2, "Anyone can repaint an unlocked tile")
	check(int(game.players[0].tiles) == had - 1 and int(game.players[1].tiles) == 2 and counts_match(game), "Repainting moves the score")
	check(int(game.players[0].best) == had, "best keeps the peak after losing tiles")
	# A runner holds the tile they are standing on until they are knocked out of it.
	var home := under(game, 0)
	put(game, 1, home)
	run_for(game, 0.1)
	check(int(game.owners[home]) == 1, "A tile cannot be painted out from under its owner")
	put(game, 1, home)
	game.players[0].stun = 0.5
	game.step(TICK)
	check(int(game.owners[home]) == 2, "A stunned runner cannot hold their tile")

func test_lock() -> void:
	var game := fresh()
	var at := cell(game, 1, 1)
	game.owners[at] = 1
	game.locks[at] = 0.5
	put(game, 1, at)
	game.step(TICK)
	check(int(game.owners[at]) == 1, "A locked tile cannot be repainted by another runner")
	run_for(game, 0.3)
	check(int(game.owners[at]) == 1 and game.locks[at] > 0.1 and game.locks[at] < 0.25, "A lock counts down while it holds")
	run_for(game, 0.3)
	check(game.locks[at] == 0.0, "A lock expires")
	check(int(game.owners[at]) == 2, "An expired lock no longer protects the tile")

func test_loop_capture() -> void:
	var game := fresh()
	var centre := cell(game, 0, 0)
	var ring := ring_around(game, [centre])
	check(ring.size() == 6, "An inner tile has six neighbours")
	paint(game, 0, ring.slice(0, 5))
	game.owners[centre] = 2
	game.step(TICK)
	check(int(game.owners[centre]) == 2 and int(game.players[0].loops) == 0, "An open ring captures nothing")
	put(game, 0, ring[5])
	game.step(TICK)
	check(int(game.owners[centre]) == 1, "Closing a loop captures the tile inside")
	check(int(game.players[0].loops) == 1, "A closed loop is counted")
	check(int(game.players[0].tiles) == 8 and int(game.players[1].tiles) == 1 and counts_match(game), "Captured tiles change the score")
	check(is_equal_approx(game.locks[centre], Model.LOCK_TIME), "Captured tiles are locked for LOCK_TIME")
	for at in ring:
		check(is_equal_approx(game.locks[at], Model.LOCK_TIME), "The loop's own tiles bordering the capture are locked")
	check(game.locks[cell(game, 4, 0)] == 0.0, "Tiles away from the capture are not locked")
	put(game, 1, centre)
	run_for(game, 0.2)
	check(int(game.owners[centre]) == 1, "A captured tile resists repainting while locked")
	game.step(TICK)
	check(int(game.players[0].loops) == 1, "A loop is only counted when it captures something")
	# A tile locked by somebody else survives being enclosed.
	game = fresh()
	paint(game, 0, ring.slice(0, 5))
	game.owners[centre] = 2
	game.locks[centre] = 5.0
	put(game, 0, ring[5])
	game.step(TICK)
	check(int(game.owners[centre]) == 2, "A tile locked by another runner stays theirs inside a loop")
	check(int(game.players[0].loops) == 0 and game.locks[ring[0]] == 0.0, "A loop that captures nothing is not counted and locks nothing")
	# Two tiles inside: the free one is captured, the locked one is not.
	game = fresh()
	var inner := [cell(game, 0, 0), cell(game, 1, 0)]
	var wide := ring_around(game, inner)
	check(wide.size() == 8, "Two tiles are surrounded by eight")
	paint(game, 0, wide.slice(0, 7))
	game.owners[inner[1]] = 3
	game.locks[inner[1]] = 5.0
	put(game, 0, wide[7])
	game.step(TICK)
	check(int(game.owners[inner[0]]) == 1 and int(game.owners[inner[1]]) == 3, "Only unlocked tiles inside a loop are captured")
	check(int(game.players[0].loops) == 1 and game.locks[inner[0]] > 0.0 and game.locks[inner[1]] > 4.9, "A partial capture still counts and locks")

func test_edge_is_not_a_wall() -> void:
	var game := fresh()
	var corner := cell(game, 7, 0)
	var around := ring_around(game, [corner])
	check(around.size() == 3 and game.grid.is_edge(corner), "A corner tile has three neighbours")
	paint(game, 0, around.slice(0, 2))
	put(game, 0, around[2])
	game.step(TICK)
	check(int(game.owners[around[2]]) == 1, "The last tile around the corner is claimed")
	check(int(game.owners[corner]) == 0 and int(game.players[0].loops) == 0, "The board edge does not close a loop")
	# A wall of tiles from edge to edge does not capture the side it cuts off.
	game = fresh()
	var row := Array(game.grid.line_cells(0, -6))
	put(game, 0, row.pop_back())
	paint(game, 0, row)
	game.step(TICK)
	check(owned(game, 0) == row.size() + 2, "The row is painted")
	check(int(game.owners[cell(game, 3, -7)]) == 0 and int(game.players[0].loops) == 0, "Cutting off a strip along the edge captures nothing")

## Four key presses from the starting tile: a human-sized loop in under 3 s.
func test_scripted_loop() -> void:
	var game := fresh()
	var hex_width := game.grid.size * sqrt(3.0)
	var legs := [["left", hex_width * 2.25], ["down", game.grid.size * 3.0],
		["right", hex_width * 2.0], ["up", game.grid.size * 3.0]]
	var presses := 0
	for leg in legs:
		game.command(0, leg[0], true)
		presses += 1
		for i in ceili(float(leg[1]) / Model.MOVE_SPEED / TICK):
			game.step(TICK)
		game.command(0, leg[0], false)
	check(int(game.players[0].loops) == 1, "A left-down-right-up run from the start closes a loop")
	check(int(game.owners[cell(game, 2, 1)]) == 1 and game.locks[cell(game, 2, 1)] > 0.0, "The tile inside the run is captured and locked")
	check(int(game.players[0].tiles) == 9 and counts_match(game), "Eight tiles of trail and one captured")
	check(presses == 4 and game.elapsed < 3.0, "The loop takes four presses and under three seconds")

func test_surge_and_zap() -> void:
	var game := fresh()
	var big := [cell(game, 1, 1), cell(game, 2, 1), cell(game, 0, 1), cell(game, 1, 2), cell(game, 0, 2)]
	var small := [cell(game, 0, -3), cell(game, 1, -3)]
	paint(game, 0, big)
	paint(game, 0, small)
	game.locks[big[1]] = 5.0
	put(game, 0, big[0])
	game.step(TICK)
	check(int(game.players[0].tiles) == 8, "Seat 0 holds three patches")
	check(Array(game.largest_patch(0)).size() == 5, "The largest patch is the five connected tiles")
	game.surges.append({"id": 50, "axis": 0, "line": 1, "warn": 0.2, "fire": Model.SURGE_FIRE})
	run_for(game, 0.1)
	check(float(game.surges[0].warn) > 0.0 and is_equal_approx(float(game.surges[0].fire), Model.SURGE_FIRE), "A surge is telegraphed before it fires")
	check(int(game.players[0].zaps) == 0 and float(game.players[0].stun) == 0.0 and int(game.players[0].tiles) == 8, "A telegraphed line is harmless")
	run_for(game, 0.15)
	check(float(game.surges[0].warn) == 0.0 and float(game.surges[0].fire) > 0.0, "After the warning the line is live")
	check(int(game.players[0].zaps) == 1, "Standing on a live line is a zap")
	check(float(game.players[0].stun) > Model.STUN_TIME - 0.1, "A zap stuns for STUN_TIME")
	for at in big:
		check(int(game.owners[at]) == 0 and game.locks[at] == 0.0, "A zap clears the largest patch and its locks")
	for at in small:
		check(int(game.owners[at]) == 1, "Smaller patches survive a zap")
	check(int(game.players[0].tiles) == 3 and counts_match(game), "The score drops with the lost patch")
	for i in range(1, 6):
		check(int(game.players[i].zaps) == 0 and int(game.players[i].tiles) == 1, "Runners off the line are untouched")
	# Still on the live line and free again: the same surge must not hit twice.
	game.players[0].stun = 0.0
	run_for(game, 0.1)
	check(game.surges.size() == 1 and float(game.surges[0].warn) == 0.0, "The surge is still live")
	check(int(game.players[0].zaps) == 1 and float(game.players[0].stun) == 0.0, "One zap per runner per surge")
	check(int(game.owners[big[0]]) == 1, "A free runner repaints the tile under them")
	run_for(game, Model.SURGE_FIRE)
	check(game.surges.is_empty(), "A surge is removed once it has fired")
	# A different surge is a new zap, and a stunned runner is helpless.
	game.surges.append({"id": 51, "axis": 0, "line": 1, "warn": 0.05, "fire": Model.SURGE_FIRE})
	run_for(game, 0.1)
	check(int(game.players[0].zaps) == 2, "A second surge zaps again")
	check(int(game.owners[small[0]]) == 0 and int(game.owners[small[1]]) == 0 and int(game.owners[big[0]]) == 1, "Each zap takes whatever patch is largest at that moment")
	var bare := cell(game, 2, 1)
	put(game, 0, bare)
	var frozen := where(game, 0)
	game.command(0, "right", true)
	game.command(0, "dash", true)
	run_for(game, Model.STUN_TIME - 0.3)
	check(where(game, 0) == frozen and float(game.players[0].dash) == 0.0 and float(game.players[0].cool) == 0.0, "A stunned runner cannot move or dash")
	check(int(game.owners[bare]) == 0 and float(game.players[0].speed) == 0.0, "A stunned runner does not claim")
	run_for(game, 0.5)
	check(float(game.players[0].stun) == 0.0 and float(game.players[0].x) > frozen.x, "Control returns when the stun ends")

func test_dash() -> void:
	var game := fresh()
	var p: Dictionary = game.players[0]
	var start := where(game, 0)
	game.command(0, "right", true)
	game.command(0, "dash", true)
	check(is_equal_approx(float(p.dash), Model.DASH_TIME) and is_equal_approx(float(p.cool), Model.DASH_COOLDOWN), "Dash starts the burst and its cooldown")
	game.step(TICK)
	check(float(p.speed) > Model.MOVE_SPEED * 2.0, "A dash is much faster than running")
	game.command(0, "right", false)
	game.command(0, "up", true)
	var guard := 0
	while float(p.dash) > 0.0 and guard < 120:
		game.step(TICK)
		guard += 1
	check(float(p.z) == start.y, "No steering in the middle of a dash")
	check(absf(float(p.x) - start.x - Model.DASH_SPEED * Model.DASH_TIME) < 0.01, "A dash covers DASH_SPEED * DASH_TIME")
	check(int(p.tiles) >= 2 and counts_match(game), "A dashing runner claims tiles")
	var after := float(p.x)
	game.command(0, "dash", true)
	check(float(p.dash) == 0.0, "Dash is refused while cooling down")
	run_for(game, 0.2)
	game.command(0, "up", false)
	check(float(p.x) == after and float(p.z) < start.y, "After the dash the held direction applies again")
	check(float(p.cool) > 0.0 and float(p.cool) < Model.DASH_COOLDOWN, "The cooldown counts down")
	run_for(game, Model.DASH_COOLDOWN)
	check(float(p.cool) == 0.0, "The cooldown ends")
	# With nothing held the dash follows the facing (up, from the last move).
	var from := where(game, 0)
	game.command(0, "dash", true)
	check(float(p.dash) > 0.0, "Dash is ready again after the cooldown")
	run_for(game, Model.DASH_TIME + 0.05)
	check(float(p.x) == from.x and absf(from.y - float(p.z) - Model.DASH_SPEED * Model.DASH_TIME) < 0.01, "An unsteered dash goes where the runner faces")
	game.command(0, "dash", false)
	check(float(p.dash) == 0.0, "Releasing dash does nothing")

func test_shove() -> void:
	var game := fresh()
	var a: Dictionary = game.players[0]
	var b: Dictionary = game.players[1]
	put(game, 0, cell(game, 0, 0))
	b.x = 0.7
	b.z = 0.0
	game.command(1, "left", true)
	game.command(0, "right", true)
	game.command(0, "dash", true)
	game.step(TICK)
	check(float(b.shove) > 0.0 and int(a.shoves) == 1, "Dashing into a runner shoves them")
	var from := where(game, 1)
	var guard := 0
	var claimed := false
	while float(b.shove) > 0.0 and guard < 120:
		game.step(TICK)
		guard += 1
		claimed = claimed or int(b.tiles) != 1
	check(float(b.x) - from.x > 1.0, "A shove knocks the runner along the dash direction, whatever they hold")
	check(absf(float(b.z) - from.y) < 0.05, "A shove does not push sideways")
	check(not claimed, "A shoved runner does not claim tiles")
	check(int(a.shoves) == 1 and int(b.shoves) == 0, "One shove per dash")
	var landed := float(b.x)
	run_for(game, 0.2)
	check(float(b.x) < landed and int(b.tiles) > 1, "Control and claiming return after the shove")
	# A dash away from a runner right behind does not drag them along.
	game = fresh()
	put(game, 0, cell(game, 0, 0))
	game.players[1].x = -0.5
	game.players[1].z = 0.0
	game.command(0, "right", true)
	game.command(0, "dash", true)
	run_for(game, 0.1)
	check(float(game.players[1].shove) == 0.0 and int(game.players[0].shoves) == 0, "Only runners in front of a dash are shoved")
	# The same the other way round, and a higher seat shoves a lower one too.
	for facing in [-1.0, 1.0]:
		game = fresh()
		put(game, 0, cell(game, 0, 0))
		game.players[1].x = 0.5
		game.players[1].z = 0.0
		game.command(1, "left" if facing < 0.0 else "right", true)
		game.command(1, "dash", true)
		run_for(game, 0.1)
		check((float(game.players[0].shove) > 0.0) == (facing < 0.0) and int(game.players[1].shoves) == (1 if facing < 0.0 else 0),
			"Seat order does not change who a dash shoves")
	# Two runners dashing at each other both get shoved.
	game = fresh()
	game.players[0].x = -0.6
	game.players[0].z = 0.0
	game.players[1].x = 0.6
	game.players[1].z = 0.0
	game.command(0, "right", true)
	game.command(1, "left", true)
	game.command(0, "dash", true)
	game.command(1, "dash", true)
	run_for(game, 0.1)
	check(int(game.players[0].shoves) == 1 and int(game.players[1].shoves) == 1, "Head-on dashes shove both runners")
	check(float(game.players[0].shove) > 0.0 and float(game.players[1].shove) > 0.0 and float(game.players[0].dash) == 0.0, "Being shoved ends a dash")
	# Shoved onto a live line: the victim is zapped, the dasher stops short.
	game = fresh()
	var spot := game.grid.centers[cell(game, 1, 1)]
	game.players[1].x = spot.x
	game.players[1].z = spot.y
	game.players[0].x = spot.x - 2.0
	game.players[0].z = spot.y
	game.surges.append({"id": 60, "axis": 1, "line": 2, "warn": 0.0, "fire": 5.0})
	game.command(0, "right", true)
	game.command(0, "dash", true)
	game.command(0, "right", false)
	run_for(game, 0.6)
	check(int(game.players[0].shoves) == 1, "The dash connects")
	check(int(game.players[1].zaps) == 1 and float(game.players[1].stun) > 0.0, "A runner shoved onto a live line is zapped")
	check(int(game.players[0].zaps) == 0, "The dasher stays clear of the line")
	# A stunned runner can be shoved too.
	game = fresh()
	put(game, 0, cell(game, 0, 0))
	game.players[1].x = 0.7
	game.players[1].z = 0.0
	game.players[1].stun = 1.0
	game.command(0, "right", true)
	game.command(0, "dash", true)
	run_for(game, 0.3)
	check(float(game.players[1].x) > 1.5 and float(game.players[1].stun) > 0.0, "A stunned runner can still be shoved")

func test_board_bounds() -> void:
	# Everyone runs and dashes straight out; nobody leaves the board.
	var game := fresh()
	for i in 6:
		var at := where(game, i)
		if at.x > 0.5: game.command(i, "right", true)
		if at.x < -0.5: game.command(i, "left", true)
		if at.y > 0.5: game.command(i, "down", true)
		if at.y < -0.5: game.command(i, "up", true)
		game.command(i, "dash", true)
	var inside := true
	for tick in 240:
		game.step(TICK)
		for i in 6:
			inside = inside and under(game, i) >= 0
	check(inside, "Runners running off the edge stay on the board")
	check(float(game.players[0].x) > game.grid.extent() and game.grid.is_edge(under(game, 0)), "The whole board is reachable, edge tiles included")
	check(counts_match(game), "Tile counts stay right at the edge")
	# Pushing into a slanted wall slides along it instead of sticking.
	game = fresh()
	game.command(0, "right", true)
	game.command(0, "down", true)
	run_for(game, 2.0)
	var first := where(game, 0)
	run_for(game, 1.0)
	var second := where(game, 0)
	check(game.grid.is_edge(under(game, 0)), "The runner reached the edge")
	check(second.y - first.y > 0.5 and second.x < first.x, "A runner slides along the board edge")
	check(float(game.players[0].speed) > 0.5, "Sliding along the edge keeps some speed")
	game.command(0, "down", false)
	run_for(game, 0.5)
	var third := where(game, 0)
	check(third.y < second.y - 0.3 and third.x > second.x, "Pushing right into the lower-right wall slides up it")
	# Random mashing on every seat, with surges, dashes and shoves in play.
	game = fresh(31)
	var dice := RandomNumberGenerator.new()
	dice.seed = 99
	inside = true
	var counted := true
	var sane := true
	for tick in 1200:
		for i in 6:
			if dice.randf() < 0.08:
				game.command(i, Model.ACTIONS[dice.randi_range(0, 4)], dice.randf() < 0.6)
		game.step(TICK)
		counted = counted and counts_match(game)
		for i in 6:
			var p: Dictionary = game.players[i]
			inside = inside and under(game, i) >= 0
			sane = sane and is_finite(float(p.x)) and is_finite(float(p.z)) and is_finite(float(p.face)) \
				and float(p.speed) >= 0.0 and float(p.speed) <= Model.DASH_SPEED + 0.01 \
				and float(p.stun) >= 0.0 and float(p.shove) >= 0.0 and float(p.dash) >= 0.0 and float(p.cool) >= 0.0 \
				and int(p.best) >= int(p.tiles)
	check(inside, "Random input never leaves the board")
	check(counted, "Tile counts always match the board")
	check(sane, "Runner state stays finite and in range")
	var shoves := 0
	for p in game.players:
		shoves += int(p.shoves)
	check(shoves > 0, "Random mashing lands some shoves")

func test_overdrive() -> void:
	var game := fresh()
	var centre := cell(game, 0, 0)
	var ring := ring_around(game, [centre])
	var kept := cell(game, 2, 2)
	game.owners[kept] = 2
	game.locks[kept] = 8.0
	game.elapsed = Model.OVERDRIVE_AT - 0.05
	check(game.stage() == 1, "Charged runs up to OVERDRIVE_AT")
	game.step(TICK)
	check(game.locks[kept] > 7.9, "Locks hold until overdrive")
	run_for(game, 0.1)
	check(game.stage() == 2, "Overdrive starts at OVERDRIVE_AT")
	var open := true
	for lock in game.locks:
		open = open and lock == 0.0
	check(open, "Overdrive clears every lock")
	put(game, 1, kept)
	put(game, 1, cell(game, 3, 2))
	paint(game, 0, ring.slice(0, 5))
	put(game, 0, ring[5])
	game.step(TICK)
	check(int(game.owners[centre]) == 1 and int(game.players[0].loops) == 1, "Loops still capture in overdrive")
	open = true
	for lock in game.locks:
		open = open and lock == 0.0
	check(open, "Loops lock nothing in overdrive")
	put(game, 1, centre)
	put(game, 0, cell(game, 4, 0))
	game.step(TICK)
	check(int(game.owners[centre]) == 2, "A tile captured in overdrive can be repainted at once")
	game = fresh()
	check(game.stage() == 0, "A round starts in warmup")
	game.elapsed = Model.CHARGED_AT
	check(game.stage() == 1, "Charged starts at CHARGED_AT")

## A whole round with nobody playing: the surge schedule, then the buzzer.
func test_schedule_and_finish() -> void:
	var game := fresh(17)
	var born: Dictionary = {}
	var live_at: Dictionary = {}
	var gone_at: Dictionary = {}
	var volleys := [[], [], []]
	var most := 0
	var valid := true
	var ticks := 0
	while game.phase == "running" and ticks < 60 * 100:
		var stage := game.stage()
		game.step(TICK)
		ticks += 1
		var fresh_lines := 0
		var present: Dictionary = {}
		for s in game.surges:
			var id := int(s.id)
			present[id] = true
			valid = valid and int(s.axis) >= 0 and int(s.axis) <= 2 and not game.grid.line_cells(int(s.axis), int(s.line)).is_empty()
			if not born.has(id):
				born[id] = game.elapsed
				fresh_lines += 1
				valid = valid and is_equal_approx(float(s.warn), Model.SURGE_WARN)
			if float(s.warn) == 0.0 and not live_at.has(id):
				live_at[id] = game.elapsed
		for id in born:
			if not present.has(id) and not gone_at.has(id):
				gone_at[id] = game.elapsed
		if fresh_lines > 0:
			volleys[stage].append(fresh_lines)
		most = maxi(most, game.surges.size())
	check(valid, "Every surge is a real line that starts with a full warning")
	check(ticks == roundi(Model.DURATION / TICK) or ticks == roundi(Model.DURATION / TICK) + 1, "The round lasts DURATION")
	check(game.phase == "finished" and game.elapsed == Model.DURATION and game.remaining() == 0.0, "The round finishes at DURATION")
	var first := INF
	for id in born:
		first = minf(first, float(born[id]))
	check(first > 2.0 and first < 8.0, "The first surge comes a few seconds in")
	var timed := true
	for id in gone_at:
		timed = timed and absf(float(live_at[id]) - float(born[id]) - Model.SURGE_WARN) < 0.04 \
			and absf(float(gone_at[id]) - float(live_at[id]) - Model.SURGE_FIRE) < 0.04
	check(timed and gone_at.size() > 20, "Surges warn for SURGE_WARN and fire for SURGE_FIRE")
	check(volleys[0].size() >= 3 and volleys[0].size() <= 6 and volleys[0].max() == 1, "Warmup fires single lines every ~7 s")
	check(volleys[1].size() >= 6 and volleys[1].size() <= 10 and volleys[1].min() == 2 and volleys[1].max() == 2, "Charged fires two lines every ~5 s")
	check(volleys[2].size() >= 5 and volleys[2].size() <= 9 and volleys[2].min() >= 2 and volleys[2].max() <= 3, "Overdrive fires two or three lines every ~3 s")
	check(most <= 3, "No more than three surges are on the board at once")
	var zaps := 0
	for p in game.players:
		zaps += int(p.zaps)
	check(zaps > 0, "Runners who never move get zapped")
	# Nothing changes after the buzzer.
	var frozen := var_to_bytes(game.snapshot())
	game.command(0, "left", true)
	game.command(0, "dash", true)
	game.step(1.0)
	check(var_to_bytes(game.snapshot()) == frozen, "A finished round ignores input and time")

func test_ranking() -> void:
	var game := fresh()
	var two := [cell(game, -4, 2), cell(game, -3, 2), cell(game, -2, 2), cell(game, -1, 2), cell(game, 0, 2)]
	paint(game, 2, two)
	paint(game, 4, [cell(game, 1, 2), cell(game, 2, 2), cell(game, 3, 2)])
	paint(game, 0, [cell(game, 0, -2), cell(game, 1, -2), cell(game, 2, -2)])
	game.step(TICK)
	check(int(game.players[2].tiles) == 6 and int(game.players[0].tiles) == 4 and int(game.players[4].tiles) == 4, "Tiles are counted per seat")
	check(game.ranking() == [2, 0, 4, 1, 3, 5], "Ranking is by tiles, highest first")
	check(game.winners() == [2], "The seat with the most tiles wins")
	paint(game, 4, [cell(game, 3, -2), cell(game, 4, -2)])
	game.step(TICK)
	check(game.winners() == [2, 4], "Equal tiles at the top is a draw")
	check(game.ranking().slice(0, 2) == [2, 4], "Tied seats rank together at the top")
	var level := fresh()
	check(level.winners().size() == 6 and level.ranking().size() == 6, "Six equal scores are a six-way draw")

func test_take_over() -> void:
	var game := Model.new()
	var slots := seats()
	slots[4].name = "ABCDEFGHIJKLMNOP"
	game.begin(3, slots)
	game.step(Model.COUNTDOWN + 0.1)
	game.command(3, "left", true)
	game.take_over(3)
	game.take_over(4)
	game.take_over(-1)
	game.take_over(6)
	var p: Dictionary = game.players[3]
	check(p.bot and int(p.peer) == 0, "A disconnected seat becomes a bot")
	check(str(p.name) == "P3 · BOT", "A taken-over seat is renamed")
	check(str(game.players[4].name) == "ABCDEFGHIJKL · BOT", "Long names are trimmed before the suffix")
	check(not p._l and not p._r and not p._u and not p._d, "Held input is cleared on take-over")
	check(not game.players[0].bot and int(game.players[0].peer) == 1, "Other seats are untouched")
	var idle := where(game, 0)
	run_for(game, 2.0)
	check(int(p.tiles) > 2 and int(game.players[4].tiles) > 2, "A taken-over seat plays on by itself")
	check(where(game, 0) == idle, "A human seat with no input stands still")

func test_ignored_input() -> void:
	var game := fresh()
	var before := var_to_bytes(game.players)
	game.command(-1, "left", true)
	game.command(6, "left", true)
	game.command(99, "dash", true)
	game.command(0, "jump", true)
	game.command(0, "duck", true)
	game.command(0, "", true)
	game.command(0, "LEFT", true)
	check(var_to_bytes(game.players) == before, "Out-of-range slots and unknown actions are ignored")
	run_for(game, 0.2)
	check(where(game, 0) == game.grid.centers[cell(game, 4, 0)], "Ignored input moves nobody")

func compare_copy(game: Model, copy: Model, label: String) -> void:
	check(copy.phase == game.phase and copy.practice == game.practice, label + ": phase")
	check(copy.elapsed == game.elapsed and copy.countdown == game.countdown, label + ": clocks")
	check(copy.stage() == game.stage() and copy.remaining() == game.remaining(), label + ": stage")
	check(copy.owners == game.owners, label + ": owners")
	var locks_ok := copy.locks.size() == game.locks.size()
	for i in game.locks.size():
		locks_ok = locks_ok and absf(copy.locks[i] - game.locks[i]) <= 0.1001 and (copy.locks[i] > 0.0) == (game.locks[i] > 0.0)
	check(locks_ok, label + ": locks")
	var surges_ok := copy.surges.size() == game.surges.size()
	if surges_ok:
		for i in game.surges.size():
			var a: Dictionary = game.surges[i]
			var b: Dictionary = copy.surges[i]
			surges_ok = surges_ok and int(a.id) == int(b.id) and int(a.axis) == int(b.axis) and int(a.line) == int(b.line) \
				and absf(float(a.warn) - float(b.warn)) <= 0.001 and absf(float(a.fire) - float(b.fire)) <= 0.001 \
				and (float(a.warn) == 0.0) == (float(b.warn) == 0.0) and b.size() == 5
	check(surges_ok, label + ": surges")
	for i in 6:
		var a: Dictionary = game.players[i]
		var b: Dictionary = copy.players[i]
		var off: Array = []
		if str(a.name) != str(b.name) or int(a.peer) != int(b.peer) or a.bot != b.bot:
			off.append("identity")
		# Positions travel in millimetres, headings in 1/10000 rad, speed in tenths.
		for key in ["x", "z"]:
			if absf(float(a[key]) - float(b[key])) > 0.00051:
				off.append(key)
		if absf(float(a.face) - float(b.face)) > 0.0001:
			off.append("face")
		if absf(float(a.speed) - float(b.speed)) > 0.051:
			off.append("speed")
		# Timers travel in 1/50 s, rounded up so a running timer never reads 0.
		for key in ["stun", "shove", "dash", "cool"]:
			if absf(float(a[key]) - float(b[key])) > 0.0201 or (float(a[key]) > 0.0002) != (float(b[key]) > 0.0):
				off.append(key)
		for key in ["tiles", "best", "loops", "zaps", "shoves"]:
			if int(a[key]) != int(b[key]):
				off.append(key)
		check(off.is_empty(), "%s: runner %d differs in %s" % [label, i, ", ".join(off)])
	check(copy.ranking() == game.ranking() and copy.winners() == game.winners(), label + ": ranking")

func test_snapshot() -> void:
	var game := Model.new()
	game.begin(11, seats(true), 4)
	var copy := Model.new()
	copy.begin(999, seats(), 4)
	var data := game.snapshot()
	check(int(data.id) == 4 and str(data.game) == Model.GAME_ID, "A snapshot carries the round id and the game id")
	for key in data:
		check(not str(key).begins_with("_"), "No server-only keys in a snapshot")
	game.step(1.0)
	copy.apply_snapshot(unwire(wire(game)))
	compare_copy(game, copy, "countdown snapshot")
	game.step(Model.COUNTDOWN)
	game.take_over(2)
	var seen_surge := false
	var seen_lock := false
	var seen_live := false
	for tick in 60 * 45:
		game.step(TICK)
		largest_snapshot = maxi(largest_snapshot, wire(game).size())
		if tick % 7 == 0:
			# The client copy never steps: everything it knows comes off the wire.
			copy.apply_snapshot(unwire(wire(game)))
			compare_copy(game, copy, "snapshot at %.2f s" % game.elapsed)
			seen_surge = seen_surge or not game.surges.is_empty()
			for s in game.surges:
				seen_live = seen_live or float(s.warn) == 0.0
			for lock in game.locks:
				seen_lock = seen_lock or lock > 0.0
	check(seen_surge and seen_live and seen_lock, "The round-trip saw surges, live lines and locks")
	for key in PUBLIC_KEYS:
		check(copy.players[0].has(key), "A restored runner has '%s'" % key)
	# A snapshot is a copy, not a view of the live arrays.
	data = game.snapshot()
	var owners_then: PackedByteArray = data.owners.duplicate()
	run_for(game, 2.0)
	check(data.owners == owners_then, "A snapshot does not change after it is taken")
	# Stale or foreign snapshots are ignored.
	var before := var_to_bytes(copy.snapshot())
	var stale := game.snapshot()
	stale.id = 3
	copy.apply_snapshot(stale)
	var foreign := game.snapshot()
	foreign.game = "rods"
	copy.apply_snapshot(foreign)
	foreign.erase("game")
	copy.apply_snapshot(foreign)
	check(var_to_bytes(copy.snapshot()) == before, "Snapshots for another round or game are ignored")
	# Worst case on the wire: a fully painted mixed board, locks everywhere with
	# unrelated timers, three surges, six busy runners with 16-character names.
	var dice := RandomNumberGenerator.new()
	dice.seed = 5
	var letters := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
	var worst := 0
	for attempt in 20:
		var slots: Array = []
		for i in 6:
			var name := ""
			for k in 16:
				name += letters[dice.randi_range(0, letters.length() - 1)]
			slots.append({"name": name, "peer": dice.randi_range(2, 2147483647), "bot": false})
		var full := Model.new()
		full.begin(attempt, slots, 250 + attempt)
		full.step(Model.COUNTDOWN + 0.1)
		full.elapsed = dice.randf_range(31.0, 69.0)
		for i in full.grid.count():
			full.owners[i] = dice.randi_range(1, 6)
			full.locks[i] = dice.randf_range(0.1, Model.LOCK_TIME) if dice.randf() < 0.7 else 0.0
		for i in 3:
			full.surges.append({"id": 300 + attempt + i, "axis": i, "line": dice.randi_range(-7, 7),
				"warn": dice.randf_range(0.0, Model.SURGE_WARN), "fire": dice.randf_range(0.01, Model.SURGE_FIRE)})
		for p in full.players:
			var at := full.grid.centers[dice.randi_range(0, full.grid.count() - 1)]
			p.x = at.x + dice.randf_range(-0.3, 0.3)
			p.z = at.y + dice.randf_range(-0.3, 0.3)
			p.face = dice.randf_range(-PI, PI)
			p.speed = dice.randf_range(0.0, Model.DASH_SPEED)
			p.stun = dice.randf_range(0.0, Model.STUN_TIME)
			p.shove = dice.randf_range(0.0, Model.SHOVE_TIME)
			p.dash = dice.randf_range(0.0, Model.DASH_TIME)
			p.cool = dice.randf_range(0.0, Model.DASH_COOLDOWN)
			p.tiles = dice.randi_range(0, 60)
			p.best = dice.randi_range(60, 120)
			p.loops = dice.randi_range(0, 30)
			p.zaps = dice.randi_range(0, 12)
			p.shoves = dice.randi_range(0, 30)
		worst = maxi(worst, wire(full).size())
		var mirror := Model.new()
		mirror.begin(0, seats(), 250 + attempt)
		mirror.apply_snapshot(unwire(wire(full)))
		check(mirror.owners == full.owners and str(mirror.players[5].name) == str(full.players[5].name) \
			and int(mirror.players[5].peer) == int(full.players[5].peer), "The worst-case snapshot still round-trips")
	largest_snapshot = maxi(largest_snapshot, worst)
	check(worst < SNAPSHOT_LIMIT, "The worst-case snapshot is %d bytes; the limit is %d" % [worst, SNAPSHOT_LIMIT])

func scripted_round(seed_value: int, checkpoints: Array) -> void:
	var game := Model.new()
	var slots := seats(true)
	slots[0] = {"name": "HUMAN", "peer": 7, "bot": false}
	game.begin(seed_value, slots, 2)
	var dice := RandomNumberGenerator.new()
	dice.seed = 4242
	var deltas := [1.0 / 60.0, 1.0 / 60.0, 1.0 / 30.0, 1.0 / 120.0, 0.05, 1.0 / 60.0, 0.021]
	for tick in 1800:
		if dice.randf() < 0.1:
			game.command(0, Model.ACTIONS[dice.randi_range(0, 4)], dice.randf() < 0.7)
		game.step(deltas[tick % deltas.size()])
		if tick == 600:
			game.take_over(3)
		if tick % 300 == 299:
			checkpoints.append([var_to_bytes(game.snapshot()), var_to_bytes(game.players), game.owners.duplicate(),
				game.locks.duplicate(), var_to_bytes(game.surges), game.elapsed])

func test_determinism() -> void:
	var first: Array = []
	var second: Array = []
	var other: Array = []
	scripted_round(2024, first)
	scripted_round(2024, second)
	scripted_round(2025, other)
	check(first.size() == 6 and float(first[5][5]) > 30.0, "The scripted round ran into the charged stage")
	var same := first.size() == second.size()
	for i in first.size():
		for k in 6:
			same = same and first[i][k] == second[i][k]
	check(same, "The same seed, commands and steps give identical state")
	check(first[5][0] != other[5][0], "A different seed gives a different round")

## A line telegraphed straight through a bot: it should usually step off in
## time, but not every time.
func test_bots_dodge() -> void:
	var trials := 40
	var dodged := 0
	for trial in trials:
		var game := fresh(100 + trial, true)
		run_for(game, 1.0)
		var axis := trial % 3
		game.surges.append({"id": 900, "axis": axis, "line": game.grid.line_of(under(game, 0), axis),
			"warn": Model.SURGE_WARN, "fire": Model.SURGE_FIRE})
		run_for(game, Model.SURGE_WARN + Model.SURGE_FIRE + 0.1)
		check(game.surges.is_empty(), "Only the injected surge is in play")
		if int(game.players[0].zaps) == 0:
			dodged += 1
	check(dodged >= trials * 0.6, "Bots step off a telegraphed line most of the time (%d of %d)" % [dodged, trials])
	check(dodged < trials, "Bots are caught by a surge now and then (%d of %d dodged)" % [dodged, trials])

func test_bot_round() -> void:
	var game := fresh(5, true)
	var ticks := 0
	var at_twenty := -1
	var leaders: Dictionary = {}
	var consistent := true
	while game.phase == "running" and ticks < 60 * 100:
		game.step(TICK)
		ticks += 1
		consistent = consistent and counts_match(game)
		if ticks % 4 == 0:
			largest_snapshot = maxi(largest_snapshot, wire(game).size())
		if at_twenty < 0 and game.elapsed >= 20.0:
			at_twenty = painted(game)
		var ahead: Array = game.winners()
		if ahead.size() == 1:
			leaders[ahead[0]] = true
	check(game.phase == "finished" and game.elapsed == Model.DURATION, "A bot round runs to the buzzer")
	check(consistent, "Tile counts match the board on every tick of a bot round")
	var total := 0
	var zaps := 0
	var loops := 0
	var shoves := 0
	for i in 6:
		var p: Dictionary = game.players[i]
		check(int(p.tiles) == owned(game, i), "Seat %d's final tiles match the board" % i)
		check(int(p.best) >= int(p.tiles) and int(p.best) > 5, "Seat %d's bot painted something" % i)
		check(under(game, i) >= 0, "Seat %d's bot is on the board" % i)
		check(str(p.name) == "P%d" % i and p.bot, "Bots keep their seat's name")
		total += int(p.tiles)
		zaps += int(p.zaps)
		loops += int(p.loops)
		shoves += int(p.shoves)
	check(total == painted(game) and total <= game.grid.count(), "Final tile counts add up to the painted board")
	check(at_twenty >= int(game.grid.count() * 0.7), "Bots paint most of the board within 20 s (%d tiles)" % at_twenty)
	check(leaders.size() >= 2, "The lead changes hands in a bot round")
	check(zaps > 0 and shoves > 0 and loops > 0, "Bots get zapped, shove each other and close loops")
	var order: Array = game.ranking()
	check(order.size() == 6 and game.winners().has(order[0]), "The top of the ranking is a winner")
	for i in 5:
		check(int(game.players[order[i]].tiles) >= int(game.players[order[i + 1]].tiles), "Ranking is in score order")
	check(largest_snapshot < SNAPSHOT_LIMIT, "Live snapshots stay under %d bytes (saw %d)" % [SNAPSHOT_LIMIT, largest_snapshot])
