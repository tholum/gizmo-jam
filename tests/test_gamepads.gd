extends SceneTree
## Several gamepads on one machine, driven through Input.parse_input_event as
## real pads would be (distinct device ids, buttons and stick motion):
##   - with no pad around, the menu is exactly the keyboard one;
##   - the first pad takes player one on a TV with no keyboard, and moves the
##     menu's focus; other pads join with A or Start and leave with B without
##     ever pressing a menu button; B closes a dialog and focus comes back;
##   - a solo round seats every joined pad; Spin Cycle's jump and duck work
##     from each pad and from player one's pad and keys; B mid-round ducks
##     rather than leaving; Start pauses and B resumes; an unplugged pad's
##     seat is handed to a bot;
##   - in Live Wire the stick steers with hysteresis, A dashes, and each seat
##     moves only for its own pad;
##   - the shared-screen HUD marks every local player and calls their events
##     out over their own plates.
## Prints GAMEPAD_TESTS PASS.

var main: Node
var clock := 0.0

func _initialize() -> void:
	call_deferred("run")

func _process(delta: float) -> bool:
	clock += delta
	if clock > 60.0:
		fail("Timed out")
	return false

func fail(message: String) -> void:
	push_error(message)
	print("GAMEPAD CHECK FAILED: ", message)
	quit(1)

func check(condition: bool, message: String) -> void:
	if not condition: fail(message)

func frames(count: int = 2) -> void:
	for i in count:
		await process_frame

func button(device: int, index: JoyButton, pressed: bool) -> void:
	var event := InputEventJoypadButton.new()
	event.device = device
	event.button_index = index
	event.pressed = pressed
	Input.parse_input_event(event)
	await frames()

func tap(device: int, index: JoyButton) -> void:
	await button(device, index, true)
	await button(device, index, false)

func axis(device: int, which: JoyAxis, value: float) -> void:
	var event := InputEventJoypadMotion.new()
	event.device = device
	event.axis = which
	event.axis_value = value
	Input.parse_input_event(event)
	await frames()

func key(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
	await frames()

func focused() -> Control:
	return root.gui_get_focus_owner()

func solo_text() -> String:
	var solo: Button = main.screen.find_child("Solo", true, false)
	return solo.text if solo else ""

func run_round() -> void:
	main.model.countdown = 0.0
	main.model.phase = "running"
	await frames()

func run() -> void:
	# A real window's shape: menu focus moves by on-screen geometry.
	root.size = Vector2i(1280, 720)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.test_mode = true
	main.sound_enabled = false
	main.preferred_game = "twisted"
	main.session.select_game("twisted")
	main.player_name = "TV"
	main._show_menu()
	await frames()
	var pads: Node = main.pads
	# Headless: no real pads are plugged in.
	check(pads.devices.is_empty(), "No pads before any pad event")
	check(main.screen.find_child("LocalPlayers", true, false) == null, "Keyboard-only menu has no local players panel")
	check(solo_text() == "PLAY SOLO  ·  VS 5 BOTS", "Keyboard-only solo button unchanged")
	check(focused() != null and focused().name == "Solo", "Solo has focus on the menu")

	# The first pad takes player one, and its d-pad moves the menu's focus.
	await tap(0, JOY_BUTTON_DPAD_DOWN)
	check(pads.primary == 0, "First pad takes player one")
	check(main.screen.find_child("LocalPlayers", true, false) != null, "Local players panel appears with a pad")
	check(focused() != null and focused().name != "Solo", "Player one's d-pad moves the menu focus")
	await tap(0, JOY_BUTTON_DPAD_UP)
	check(focused() != null and focused().name == "Solo", "D-pad up returns to Solo")
	# Every part of the menu can be reached with the d-pad alone.
	var seen := {}
	for i in 5:
		await tap(0, JOY_BUTTON_DPAD_DOWN)
		seen[focused().get_meta("graphics", focused().name)] = true
	check(seen.has("balanced") or seen.has("low") or seen.has("high"), "D-pad down reaches the graphics keys: %s" % [seen.keys()])
	await tap(0, JOY_BUTTON_DPAD_RIGHT)
	for i in 8:
		await tap(0, JOY_BUTTON_DPAD_UP)
	check(focused().name == "Card_twisted", "D-pad up climbs back to the first game, at %s" % focused().name)
	await tap(0, JOY_BUTTON_DPAD_RIGHT)
	check(focused().name == "How", "D-pad right reaches the card's How to play")
	# The stick moves focus once per push, with the same hysteresis as play.
	await tap(0, JOY_BUTTON_DPAD_LEFT)
	await axis(0, JOY_AXIS_LEFT_Y, 0.9)
	await axis(0, JOY_AXIS_LEFT_Y, 1.0)
	check(focused().name == "Card_livewire", "One stick push moves focus one step, at %s" % focused().name)
	await axis(0, JOY_AXIS_LEFT_Y, 0.0)
	main.screen.find_child("Solo", true, false).grab_focus()

	# Other pads join with A or Start; their A never presses the focused button.
	await tap(1, JOY_BUTTON_A)
	check(main.view == "menu", "Another pad's A joins instead of pressing Solo")
	check(Array(pads.extras) == [1], "Pad 1 joined")
	check(solo_text() == "PLAY  ·  2 PLAYERS VS 4 BOTS", "Solo button counts the players: " + solo_text())
	check(focused() != null and focused().name == "Solo", "Focus survives the menu rebuild")
	await tap(2, JOY_BUTTON_START)
	await tap(3, JOY_BUTTON_A)
	check(Array(pads.extras) == [1, 2, 3], "Pads 2 and 3 joined")
	await tap(3, JOY_BUTTON_B)
	check(Array(pads.extras) == [1, 2], "Pad 3 left with B")
	await tap(3, JOY_BUTTON_DPAD_DOWN)
	check(Array(pads.extras) == [1, 2] and focused().name == "Solo", "An unjoined pad's d-pad does nothing")
	var panel: Control = main.screen.find_child("LocalPlayers", true, false)
	check(panel != null and panel.get_child_count() >= 4, "Panel lists three players and the hint")

	# Player one's B closes a dialog; focus goes back to the screen.
	main._rules("twisted")
	await frames()
	check(main.overlay.get_child_count() > 0, "How-to-play is open")
	check(main.screen.focus_behavior_recursive == Control.FOCUS_BEHAVIOR_DISABLED, "The screen gives up focus under a dialog")
	check(focused() != null and main.overlay.is_ancestor_of(focused()), "Focus is inside the dialog")
	await tap(2, JOY_BUTTON_A)
	check(main.overlay.get_child_count() > 0 and Array(pads.extras) == [1, 2], "Extra pads cannot press dialog buttons or rejoin")
	await tap(0, JOY_BUTTON_B)
	await frames()
	check(main.overlay.get_child_count() == 0, "Player one's B closes the dialog")
	check(focused() != null and main.screen.is_ancestor_of(focused()), "Focus is back on the menu")

	# Player one's A presses Solo: a round with three players here.
	main.screen.find_child("Solo", true, false).grab_focus()
	await tap(0, JOY_BUTTON_A)
	check(main.view == "game", "Player one's A starts the round")
	check(main.session.members.size() == 3, "Three seats on this machine")
	check(main.session.pad_slot(1) == 1 and main.session.pad_slot(2) == 2, "Pads seated in join order")
	check(main.model.players[1].name == "PLAYER 2" and not main.model.players[1].bot, "Pad seat is a player")
	check(main.model.players[3].bot, "Empty seats are bots")
	check(main.shared_screen and main.local_mask == 0b111, "Shared screen marks three local seats")
	check(main.play.plates[1].own and main.play.plates[2].own and not main.play.plates[3].own, "Every local plate is marked")
	check(main.play.plates[1].role == "P2" and main.play.plates[0].role == "P1", "Shared screen roles are player numbers")
	check(main.plate_calls[1] != null and main.plate_calls[3] == null, "Call-outs over local plates only")
	await run_round()
	var players: Array = main.model.players
	# Spin Cycle from each pad.
	await tap(1, JOY_BUTTON_A)
	check(float(players[1].jump) >= 0.0, "Pad 1's A jumps seat 1")
	check(float(players[2].jump) < 0.0 and float(players[0].jump) < 0.0, "Only seat 1 jumped")
	await button(2, JOY_BUTTON_DPAD_DOWN, true)
	check(players[2].duck, "Pad 2's d-pad down ducks seat 2")
	await button(2, JOY_BUTTON_DPAD_DOWN, false)
	check(not players[2].duck, "Releasing stands seat 2 up")
	await axis(2, JOY_AXIS_TRIGGER_RIGHT, 0.9)
	check(players[2].duck, "A held trigger ducks")
	await axis(2, JOY_AXIS_TRIGGER_RIGHT, 0.0)
	check(not players[2].duck, "Trigger released")
	await button(1, JOY_BUTTON_B, true)
	check(players[1].duck and pads.is_extra(1), "B mid-round ducks and does not leave")
	await button(1, JOY_BUTTON_B, false)
	await tap(0, JOY_BUTTON_A)
	check(float(players[0].jump) >= 0.0, "Player one's pad jumps seat 0")
	await key(KEY_S, true)
	check(players[0].duck, "The keyboard still drives player one")
	await key(KEY_S, false)
	await axis(0, JOY_AXIS_LEFT_Y, 0.8)
	check(players[0].duck, "Player one's stick down ducks")
	await axis(0, JOY_AXIS_LEFT_Y, 0.0)
	check(not players[0].duck, "Stick centred stands up")
	# Shared-screen feedback goes over the hit player's own plate.
	players[2].hp = 5
	main._update_hud()
	check(main.plate_calls[2].visible and str(main.plate_calls[2].message).begins_with("HIT!"), "Seat 2's hit is called out over its plate")
	check(not main.hud_feedback.visible, "No whole-screen call-out on a shared screen")
	# Start pauses, B resumes.
	await tap(0, JOY_BUTTON_START)
	check(main.paused, "Start pauses")
	await tap(1, JOY_BUTTON_START)
	check(main.paused, "An extra pad's Start does not resume")
	await tap(0, JOY_BUTTON_B)
	check(not main.paused, "B resumes")
	# Unplugging a pad mid-round hands its seat to a bot.
	Input.joy_connection_changed.emit(2, false)
	await frames()
	check(players[2].bot, "Unplugged pad's seat becomes a bot")
	check(main.session.pad_slot(2) == -1 and not main.is_local(2), "Unplugged pad loses its seat")
	check(Array(main.seat_pads) == [1, 1], "Only pad 1 still drives a seat")
	main.session.lobby()
	await frames()
	check(main.view == "menu", "Back on the menu")
	check(Array(pads.extras) == [1], "Pad 1 is still in")

	# Live Wire: stick with hysteresis, A dashes.
	main._select_game("livewire")
	await frames()
	main._solo()
	await frames()
	check(main.view == "game" and main.play.ID == "livewire", "Live Wire round")
	await run_round()
	players = main.model.players
	await axis(1, JOY_AXIS_LEFT_X, 0.9)
	check(players[1]._r and not players[0]._r, "Pad 1's stick steers seat 1 only")
	await axis(1, JOY_AXIS_LEFT_X, 0.4)
	check(players[1]._r, "Stick inside the hysteresis band keeps the direction")
	await axis(1, JOY_AXIS_LEFT_X, 0.2)
	check(not players[1]._r, "Stick back near centre lets go")
	await axis(1, JOY_AXIS_LEFT_X, 0.4)
	check(not players[1]._r, "Below the turn-on threshold nothing is held")
	await tap(1, JOY_BUTTON_A)
	check(float(players[1].dash) > 0.0 or float(players[1].cool) > 0.0, "Pad 1's A dashes seat 1")
	check(float(players[0].dash) <= 0.0 and float(players[0].cool) <= 0.0, "Seat 0 did not dash")
	await button(0, JOY_BUTTON_DPAD_UP, true)
	check(players[0]._u and not players[1]._u, "Player one's d-pad steers seat 0")
	await tap(0, JOY_BUTTON_A)
	check(float(players[0].dash) > 0.0 or float(players[0].cool) > 0.0, "Player one's A dashes")
	await button(0, JOY_BUTTON_DPAD_UP, false)
	check(not players[0]._u, "D-pad released")
	await key(KEY_D, true)
	check(players[0]._r, "Keys still steer player one")
	await key(KEY_D, false)
	main._toggle_pause()
	await frames()
	check(not players[1]._r and not players[0]._u, "Pause lets go of everything")
	main._toggle_pause()
	main.session.lobby()
	await frames()

	# Leaving at the menu, and a pad that is unplugged there.
	await tap(1, JOY_BUTTON_BACK)
	check(pads.extras.is_empty(), "Back leaves")
	await tap(4, JOY_BUTTON_A)
	check(Array(pads.extras) == [4], "Pad 4 joined")
	Input.joy_connection_changed.emit(4, false)
	await frames()
	check(pads.extras.is_empty() and not (4 in pads.devices), "Unplugged on the menu: gone")
	check(solo_text() == "PLAY SOLO  ·  VS 5 BOTS", "Back to a solo round")
	main.session.solo("TV")
	main._sync_local_seats()
	main.session.start_round()
	await frames()
	check(not main.shared_screen and main.play.plates[0].role == "YOU", "One player here: the usual YOU plate")
	print("GAMEPAD_TESTS PASS")
	quit()
