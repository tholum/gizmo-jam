extends SceneTree
## Loads a built PCK through the real core, then exercises its menu, controls
## and results. Run from a core-only build-6 project to verify pack isolation.

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
		printerr("Pass --pack=/absolute/path/to/orb_racing-1.0.0.pck after --")
		quit(1)
		return

	var physical: Array = Input.get_connected_joypads()
	var base := 0
	for id in physical:
		base = maxi(base, id + 1)
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)
	_main.test_mode = true
	_main.sound_enabled = false
	root.size = Vector2i(1280, 720) if Platform.handheld else Vector2i(1280, 800)
	await _frames()

	var file_table := PackCore.read_pck(path)
	_check(not file_table.has("error"), "The game pack has a readable file table")
	_check(not str(file_table).contains("tests/"), "The pack contains no test scripts")
	var result: String = _main.packs._load_pack("orb_racing", path, "untrusted", "", FileAccess.get_file_as_bytes(path).size())
	_check(result.is_empty(), "Pack Manager accepts Orb Racing: " + result)
	if not result.is_empty():
		quit(1)
		return
	var entry := Registry.entry("orb_racing")
	_check(entry.core_min == 6 and entry.net == 1 and entry.version == "1.0.0" and entry.info.number == "05",
		"Registry shows the requested pack metadata")
	_main._add_game("orb_racing")
	_main._select_game("orb_racing")
	_check(_main.games.orb_racing.INFO == entry.info, "The module and manifest have the same menu card")
	_main.games.orb_racing.build_rules()
	await _frames()
	_main._clear_overlay()

	# Seat a second pad using the same join event a real controller sends.
	if not Platform.handheld:
		_main.pads.claim(base)
		_main.pads.keyboard_used = true
		await _button(base + 1, JOY_BUTTON_A, true)
		await _button(base + 1, JOY_BUTTON_A, false)
	_main._solo()
	_main.set_physics_process(false)
	await _frames()
	var race: RefCounted = _main.model
	_check(race != null and _main.view == "game" and race.phase == "countdown", "Menu starts a race on the grid")
	if race == null:
		quit(1)
		return
	_check(_main.hud_root.find_child("CurrentRoute", true, false) != null, "Current gate context is visible in the round HUD")
	var camera: Camera3D = _main.play.arena().camera
	var player_count: int = race.players.size()
	var fits := true
	for i in range(0, race.track.points.size(), 4):
		var section: Transform2D = race.track.frame(race.track.distances[i])
		for side: float in [-1.0, 1.0]:
			var edge := section * Vector2(0, side * 7.75)
			fits = fits and root.get_visible_rect().has_point(camera.unproject_position(Vector3(edge.x, 0.4, edge.y)))
	_check(fits and player_count == 6, "The shared camera fits the entire circuit and six orbs")
	await _capture("grid")

	race.step(3.0)
	if Platform.handheld:
		await _touch_controls(race)
	else:
		await _desktop_controls(race, base)
	await _capture("controls")

	# Free-run the exact same host model, then let main's normal finish hold
	# transition into the results view. This skips wall-clock waiting only.
	var own: int = _main.session.my_slot()
	for i in player_count:
		if i != own and not race.players[i].bot:
			race.take_over(i)
	race.step(12.0)
	await _capture("race")
	race.step(100.0)
	_check(race.phase == "finished" and race.winners().size() == 1, "The real game model reaches a winner and its cutoff")
	_main.set_physics_process(true)
	for i in 115:
		await process_frame
		if _main.view == "results":
			break
	_check(_main.view == "results", "Core transitions into the race results")
	_check(_main.play.result_summary().contains("FINISHED") and _main.play.champion_stats(race.players[race.ranking()[0]]).contains("LAPS"),
		"Results show the finish count and lap stats")
	var rows: Array[Node] = _main.screen.find_children("*", "Label", true, false)
	_check(rows.any(func(label: Label) -> bool: return label.text.begins_with("DNF · ")),
		"The unfinished local racer has a DNF with a distance percentage")
	if not _capture_dir.is_empty():
		await _frames(60)
	await _capture("results")
	print("ORB_PACK_SMOKE %s (%s): %d checks, %d failures" %
		["PASS" if _failures == 0 else "FAIL", "handheld" if Platform.handheld else "desktop", _checks, _failures])
	quit(mini(_failures, 1))


func _desktop_controls(race: RefCounted, device: int) -> void:
	_check(_main.shared_screen and _main.seat_pads.size() == 2, "A second controller has an independent seat")
	if _main.seat_pads.size() < 2:
		return
	var own: int = _main.session.my_slot()
	var extra: int = _main.seat_pads[0]
	var before: Vector2 = race.players[own].pos
	await _key(KEY_D, true)
	await _key(KEY_SPACE, true)
	race.step(0.45)
	_check(race.players[own].pos.x > before.x + 1.0 and race.players[own].spent == 1,
		"WASD is screen-relative and Space spends one primary charge")
	_check(race.players[extra].spent == 0, "Keyboard boost only affects player one")
	await _key(KEY_SPACE, false)
	await _key(KEY_D, false)
	await _key(KEY_UP, true)
	_check(race.players[own]._input == 4, "Arrow keys steer on the matching axis")
	await _key(KEY_UP, false)
	await _button(device, JOY_BUTTON_DPAD_RIGHT, true)
	_check(race.players[own]._input == 2, "The primary pad's D-pad steers player one")
	await _axis(device + 1, JOY_AXIS_LEFT_X, 0.84)
	_check(race.players[extra]._input == 2, "The second pad's stick steers its own orb")
	await _button(device + 1, JOY_BUTTON_A, true)
	race.step(0.25)
	_check(race.players[extra].spent == 1 and race.players[own].spent == 1, "The second pad's A spends its own charge")
	await _button(device + 1, JOY_BUTTON_A, false)
	await _axis(device + 1, JOY_AXIS_LEFT_X, 0.0)
	await _button(device, JOY_BUTTON_DPAD_RIGHT, false)
	_check(race.players[extra]._input == 0 and race.players[own]._input == 0, "Pad release clears both seats")


func _touch_controls(race: RefCounted) -> void:
	var touch_layer: Control = _main.find_child("TouchControls", true, false)
	_check(touch_layer != null, "Handheld creates the real touch layer")
	if touch_layer == null:
		return
	var p: Dictionary = race.players[_main.session.my_slot()]
	var origin := touch_layer.size * Vector2(0.20, 0.52)
	var before: Vector2 = p.pos
	await _touch(0, origin, true)
	await _drag(0, origin + Vector2(touch_layer.size.y * 0.095, 0))
	_check(p._input == 2, "Left thumb drag routes through touch steering")
	var boost := touch_layer.size * Vector2(0.81, 0.52)
	await _touch(1, boost, true)
	race.step(0.55)
	_check(p.pos.x > before.x + 2.0 and p.spent == 1, "Right tap spends one charge with the steering finger still down")
	await _touch(1, boost, false)
	await _touch(0, origin, false)
	_check(p._input == 0, "Lifting the steering thumb releases its direction")


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


func _drag(index: int, pos: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.index = index
	event.position = pos
	Input.parse_input_event(event)
	await _frames()


func _capture(key: String) -> void:
	if _capture_dir.is_empty() or DisplayServer.get_name() == "headless":
		return
	await _frames()
	await RenderingServer.frame_post_draw
	var photo := root.get_texture().get_image()
	_check(photo.save_png(_capture_dir.path_join(key + ".png")) == OK, "Captured " + key)
