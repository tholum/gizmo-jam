extends SceneTree
## Touch controls, driven by real touch events through the engine.
##
##   $G --headless --path . --audio-driver Dummy --script res://tests/test_touch.gd -- --handheld
##   $G --headless --path . --audio-driver Dummy --script res://tests/test_touch.gd
##   ... -- --handheld --safe-inset=120    (a phone with a camera cut-out)
##
## With --handheld: Spin Cycle's halves jump and duck, Live Wire's stick holds
## the right directions (diagonals included) and lets go, the right side
## dashes, and the HUD menu button pauses. Without it (desktop): no touch layer
## exists and the HUD is unchanged. Prints TOUCH_TESTS_PASS or exits 1.

const Platform = preload("res://scripts/platform.gd")
var main: Node
var failures: Array = []
var checks := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		failures.append(what)
		push_error("TOUCH CHECK FAILED: " + what)

func run() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	main.test_mode = true
	await frames(10)
	var layer: Node = main.find_child("TouchControls", true, false)
	if not Platform.handheld:
		check(layer == null, "desktop has no touch layer")
		check(main.ui_scale_for(Vector2(1280, 800)) == clampf(minf(1280 / 1440.0, 800 / 900.0), 0.85, 1.5), "desktop scale rule unchanged")
		await start("twisted")
		check(main.hud_menu.text == "ESC  ·  MENU", "desktop menu button text")
		check(main.hud_names.visible, "desktop names hint shown")
		finish("desktop")
		return
	check(layer != null, "handheld has a touch layer")
	check(main.ui_scale_for(Vector2(2400, 1080)) > 1.5, "phone UI is drawn larger than desktop's maximum")
	var size: Vector2 = layer.size

	# Spin Cycle: right half jumps, left half ducks while held.
	await start("twisted")
	check(main.hud_menu.text == "MENU", "handheld menu button text")
	var me: Dictionary = main.model.players[main.session.my_slot()]
	await tap(1, Vector2(size.x * 0.8, size.y * 0.5))
	check(float(me.jump) >= 0.0, "tap on the right half jumps")
	await frames(40)
	await touch(2, Vector2(size.x * 0.2, size.y * 0.5), true)
	await frames(3)
	check(bool(me.duck), "holding the left half ducks")
	await touch(2, Vector2(size.x * 0.2, size.y * 0.5), false)
	await frames(3)
	check(not bool(me.duck), "lifting the left finger stands up")

	# The HUD menu button pauses, even as a second finger.
	await touch(3, Vector2(size.x * 0.2, size.y * 0.5), true)
	var menu_point: Vector2 = main.hud_menu.get_global_transform_with_canvas() * (main.hud_menu.size * 0.5)
	await tap(4, menu_point)
	check(main.paused, "the menu button pauses")
	check(not bool(me.duck), "pausing lets go of the duck")
	main._toggle_pause()
	await touch(3, Vector2(size.x * 0.2, size.y * 0.5), false)
	main._leave()
	await frames(5)

	# Live Wire: a floating stick on the left, dash on the right.
	await start("livewire")
	var module: RefCounted = main.play
	var origin := Vector2(size.x * 0.2, size.y * 0.55)
	var reach: float = size.y * 0.1
	await touch(5, origin, true)
	check(not module.sent.values().has(true), "a resting thumb holds nothing")
	var expected := {
		Vector2(1, 0): ["right"], Vector2(1, 1): ["right", "down"], Vector2(0, 1): ["down"],
		Vector2(-1, 1): ["left", "down"], Vector2(-1, 0): ["left"], Vector2(-1, -1): ["left", "up"],
		Vector2(0, -1): ["up"], Vector2(1, -1): ["right", "up"],
	}
	for direction in expected:
		# Back to the centre first, so each direction is fresh (no hysteresis).
		await drag(5, origin)
		await drag(5, origin + direction.normalized() * reach)
		var held: Array = []
		for action in ["up", "down", "left", "right"]:
			if bool(module.sent.get(action, false)): held.append(action)
		held.sort()
		var want: Array = expected[direction].duplicate()
		want.sort()
		check(held == want, "stick %s holds %s (got %s)" % [direction, want, held])
	await touch(5, origin + Vector2(reach, 0), false)
	check(not module.sent.values().has(true), "lifting the stick lets go of every direction")
	var player: Dictionary = main.model.players[main.session.my_slot()]
	await tap(6, Vector2(size.x * 0.85, size.y * 0.5))
	await frames(2)
	check(float(player.dash) > 0.0 or float(player.cool) > 0.0, "tap on the right half dashes")
	finish("handheld")

func start(id: String) -> void:
	main.session.select_game(id)
	main.preferred_game = id
	main.session.solo("PLAYER ONE")
	main.session.start_round()
	await frames(5)
	main.model.countdown = 0.0
	main.model.phase = "running"
	await frames(5)

func frames(count: int) -> void:
	for i in count:
		await process_frame

## A touch at `pos` in canvas units, sent through the engine as from the screen.
func touch(index: int, pos: Vector2, pressed: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = root.get_final_transform() * pos
	event.pressed = pressed
	Input.parse_input_event(event)
	await frames(2)

func drag(index: int, pos: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.index = index
	event.position = root.get_final_transform() * pos
	Input.parse_input_event(event)
	await frames(2)

func tap(index: int, pos: Vector2) -> void:
	await touch(index, pos, true)
	await touch(index, pos, false)

func finish(mode: String) -> void:
	if failures.is_empty():
		print("TOUCH_TESTS_PASS %s (%d checks)" % [mode, checks])
		quit(0)
	else:
		print("TOUCH_TESTS_FAIL %s: %s" % [mode, ", ".join(failures)])
		quit(1)
