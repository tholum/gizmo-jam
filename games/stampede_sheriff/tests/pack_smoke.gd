extends SceneTree
## Run with --fixed-fps 60, the built PCK and a core-only project. A display plus --capture-dir
## saves countdown.png, herd.png and results.png from the actual game.

const ID := "stampede_sheriff"
const Registry = preload("res://scripts/game_registry.gd")
const PackCore = preload("res://scripts/pack_core.gd")
const Platform = preload("res://scripts/platform.gd")

var _main: Node
var _failures := 0
var _checks := 0
var _capture_dir := ""

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		printerr("FAIL: ", message)

func _frames(count: int = 3) -> void:
	for i in count:
		await process_frame

func _run() -> void:
	var path := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--pack="):
			path = arg.trim_prefix("--pack=")
		elif arg.begins_with("--capture-dir="):
			_capture_dir = arg.trim_prefix("--capture-dir=")
	if path.is_empty():
		printerr("Pass --pack=/absolute/path/to/stampede_sheriff-1.1.0.pck after --")
		quit(1)
		return

	var device := 0
	for id in Input.get_connected_joypads():
		device = maxi(device, id + 1)
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)
	_main.test_mode = true
	_main.sound_enabled = false
	if "--compact" in OS.get_cmdline_user_args():
		root.min_size = Vector2i.ZERO
		root.size = Vector2i(800, 600)
	else:
		root.size = Vector2i(1280, 720) if Platform.handheld else Vector2i(1280, 800)
	if not _capture_dir.is_empty():
		_main.graphics_level = "balanced"
		_main._apply_graphics()
	await _frames()

	var table := PackCore.read_pck(path)
	_check(not table.has("error") and not str(table).contains("tests/"), "Valid PCK excludes test scripts")
	var reason: String = _main.packs._load_pack(ID, path, "untrusted", "", FileAccess.get_file_as_bytes(path).size())
	_check(reason.is_empty(), "Core Pack Manager loads Stampede Sheriff: " + reason)
	if not reason.is_empty():
		quit(1)
		return
	var entry := Registry.entry(ID)
	_check(entry.core_min == 10 and entry.net == 1 and entry.version == "1.1.0" and entry.optional_seats and entry.info.number == "06",
		"Registry has the release metadata")
	_check(entry.actions == ["up", "down", "left", "right", "clap"], "Registry accepts all five game actions")
	_main._add_game(ID)
	_main._select_game(ID)
	_check(_main.games[ID].INFO == entry.info, "Manifest and module match")
	_main.games[ID].build_rules()
	await _frames()
	_main._clear_overlay()

	if not Platform.handheld:
		_main.pads.claim(device)
		_main.pads.keyboard_used = true
		await _button(device + 1, JOY_BUTTON_A, true)
		await _button(device + 1, JOY_BUTTON_A, false)
	_main._solo()
	_main.set_physics_process(false)
	await _frames()
	var model: RefCounted = _main.model
	_check(model != null and model.phase == "countdown" and _main.view == "game", "Core starts a real solo countdown")
	if model == null:
		quit(1)
		return
	var own: int = _main.session.my_slot()
	_check(model.players.size() == 6 and _main.hud_root.find_child("HatchAnnouncement", true, false) != null,
		"Full six-seat board exposes the hatch HUD")
	var camera: Camera3D = _main.play.arena().camera
	var border_fits := true
	for i in 48:
		var at: Vector2 = Vector2.from_angle(TAU * i / 48) * model.FIELD_RADIUS
		border_fits = border_fits and root.get_visible_rect().has_point(camera.unproject_position(Vector3(at.x, 0.0, at.y)))
	_check(border_fits, "The entire playable stockyard fits the camera")
	await _capture("countdown")

	# Reset the real model to a repeatable seed so screenshots and control
	# checks do not depend on the random seed picked by Session.
	var slots: Array = _main.session.slots()
	model.begin(1088, slots, model.round_id)
	model.step(model.COUNTDOWN)
	if Platform.handheld:
		await _touch_controls(model, own)
	else:
		await _desktop_controls(model, own, device)

	# Use the authoritative simulation, including the hatch announcement,
	# then capture an active second herd with its gold critter visible.
	for i in model.SEATS:
		model.take_over(i)
	model.step(float(model.FIRST_RELEASE - model.HATCH_WARNING + 2 - model.tick) / model.HZ)
	await _frames()
	var announcement: Control = _main.hud_root.find_child("HatchAnnouncement", true, false)
	_check(model.next_hatch >= 0 and announcement.visible,
		"Hatch is announced on the round HUD before it opens")
	var clock: Control = _main.hud_root.find_child("StampedeClock", true, false)
	var clock_rect := clock.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, clock.size)
	var playfield_clear := true
	for direction in 48:
		for radius in [0.2, 0.4, 0.6, 0.8, 1.0]:
			var point: Vector2 = Vector2.from_angle(TAU * direction / 48) * model.FIELD_RADIUS * radius
			var projected := camera.unproject_position(Vector3(point.x, 0.8, point.y))
			playfield_clear = playfield_clear and not clock_rect.grow(8).has_point(projected)
	_check(playfield_clear, "Hatch announcement leaves the playable field visible")
	_check("hatch_warning" in _main.sound_log, "A hatch warning emits a distinct cue")
	model.step(float(model.HATCH_WARNING) / model.HZ)
	await _frames()
	_check(model.wave == 1 and "hatch_open" in _main.sound_log, "Hatch release has its own cue")
	while model.wave < 2 and model.phase == "running":
		model.step(0.05)
	model.step(0.58)
	await _frames()
	_check(model.wave == 2 and model.critters.any(func(c): return c.value == 2), "Second herd presents a gold critter")
	_check(_main.play.arena()._hatches[model.last_hatch].ring.visible, "The opening hatch has a visible marker")
	await _capture("herd")

	model.step(100.0)
	_check(model.phase == "finished" and model.tick == model.ROUND_TICKS and not model.winners().is_empty(),
		"Real game ends at 90 seconds with a score result")
	_main.set_physics_process(true)
	for i in 115:
		await process_frame
		if _main.view == "results":
			break
	_check(_main.view == "results" and _main.play.champion_stats(model.players[model.ranking()[0]]).contains("POINT"),
		"Core enters results and shows points")
	if not _capture_dir.is_empty():
		await _frames(60)
	await _capture("results")
	print("STAMPEDE_PACK_SMOKE %s (%s): %d checks, %d failures" %
		["PASS" if _failures == 0 else "FAIL", "handheld" if Platform.handheld else "desktop", _checks, _failures])
	quit(mini(_failures, 1))

func _desktop_controls(model: RefCounted, own: int, device: int) -> void:
	_check(_main.shared_screen and _main.seat_pads.size() == 2, "Core seated a second independent controller")
	if _main.seat_pads.size() < 2:
		return
	var extra: int = _main.seat_pads[0]
	var before: Vector2 = model.players[own].pos
	await _key(KEY_D, true)
	await _key(KEY_SPACE, true)
	model.step(0.34)
	await _frames()
	_check(model.players[own].pos.x > before.x + 1.0 and model.players[own].claps == 1, "WASD moves and Space claps once")
	_check("clap" in _main.sound_log or "clap_hit" in _main.sound_log, "A local clap emits a cue")
	_check(model.players[extra].claps == 0, "Space only affects player one")
	await _key(KEY_SPACE, false)
	await _key(KEY_D, false)
	await _key(KEY_UP, true)
	_check(model.players[own].input == model.DIRS.up, "Arrow keys send the correct direction")
	await _key(KEY_UP, false)
	await _button(device, JOY_BUTTON_DPAD_RIGHT, true)
	_check(model.players[own].input == model.DIRS.right, "Primary D-pad steers player one")
	await _axis(device + 1, JOY_AXIS_LEFT_X, 0.84)
	_check(model.players[extra].input == model.DIRS.right, "Second pad's stick steers its own seat")
	await _button(device + 1, JOY_BUTTON_A, true)
	model.step(0.25)
	_check(model.players[extra].claps == 1 and model.players[own].claps == 1, "Second pad's A claps independently")
	model.step(1.5)
	await _frames()
	model.step(0.02)
	_check(model.players[extra].claps == 1, "Holding A does not repeat after cooldown")
	await _button(device + 1, JOY_BUTTON_A, false)
	await _axis(device + 1, JOY_AXIS_LEFT_X, 0.0)
	await _button(device, JOY_BUTTON_DPAD_RIGHT, false)
	_check(model.players[extra].input == 0 and model.players[own].input == 0, "Pad release clears both seats")

func _touch_controls(model: RefCounted, own: int) -> void:
	var layer: Control = _main.find_child("TouchControls", true, false)
	_check(layer != null and _main.play.touch_layout().right_label == "CLAP", "Handheld uses the real labeled touch layer")
	if layer == null:
		return
	var p: Dictionary = model.players[own]
	var left := layer.size * Vector2(0.20, 0.53)
	var right := layer.size * Vector2(0.82, 0.53)
	var before: Vector2 = p.pos
	await _touch(0, left, true)
	var drag := InputEventScreenDrag.new()
	drag.index = 0
	drag.position = left + Vector2(layer.size.y * 0.095, 0)
	Input.parse_input_event(drag)
	await _frames()
	_check(p.input == model.DIRS.right, "Left thumb drag steers through the real touch widget")
	await _touch(1, right, true)
	model.step(0.42)
	_check(p.pos.x > before.x + 1.1 and p.claps == 1, "Right tap claps with left thumb still steering")
	await _touch(1, right, false)
	await _touch(0, left, false)
	_check(p.input == 0, "Lifting the steering thumb releases its direction")

func _key(code: Key, press: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = press
	Input.parse_input_event(event)
	await _frames()

func _button(device: int, code: JoyButton, press: bool) -> void:
	var event := InputEventJoypadButton.new()
	event.button_index = code
	event.device = device
	event.pressed = press
	Input.parse_input_event(event)
	await _frames()

func _axis(device: int, axis: JoyAxis, value: float) -> void:
	var event := InputEventJoypadMotion.new()
	event.axis = axis
	event.axis_value = value
	event.device = device
	Input.parse_input_event(event)
	await _frames()

func _touch(index: int, pos: Vector2, press: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = pos
	event.pressed = press
	Input.parse_input_event(event)
	await _frames()

func _capture(key: String) -> void:
	if _capture_dir.is_empty() or DisplayServer.get_name() == "headless":
		return
	await _frames()
	await RenderingServer.frame_post_draw
	_check(root.get_texture().get_image().save_png(_capture_dir.path_join(key + ".png")) == OK, "Captured " + key)
