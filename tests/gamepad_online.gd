extends SceneTree
## A host with two players on its screen (the keyboard and a second gamepad)
## and a remote guest play one online Live Wire round. Started by
## tests/run_gamepad_online.py, one process per role:
##   host   seats pad 1 from the menu, hosts, waits for the guest, starts the
##          round, steers the pad's seat with the stick, unplugs the pad
##          mid-round, ends the round and returns to the lobby.
##   guest  joins, checks the roster it was sent (three members, two of them
##          the host machine's), steers its own seat with S, and follows the
##          pad's seat and its hand-over to a bot through the snapshots.
## Checked on the server's model and on the guest's snapshot copy: the pad
## moves only its own seat, the guest's key only the guest's, and the guest
## treats the host's extra seat as just another player.
const LiveModel = preload("res://scripts/livewire_model.gd")

var main: Node
var role := "host"
var port := 19811
var clock := 0.0
var start: Array = []

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--role="): role = arg.get_slice("=", 1)
		if arg.begins_with("--port="): port = int(arg.get_slice("=", 1))
	call_deferred("run")

func _process(delta: float) -> bool:
	clock += delta
	if clock > 60.0:
		fail("Timed out in view '%s'" % (main.view if main else "?"))
	return false

## Real pads plugged into this machine keep their device ids; simulated pads
## start after them.
func d(n: int) -> int:
	var base := 0
	for id in Input.get_connected_joypads(): base = maxi(base, id + 1)
	return base + n

func fail(message: String) -> void:
	push_error("%s: %s" % [role, message])
	print("GAMEPAD ONLINE CHECK FAILED (%s): %s" % [role, message])
	quit(1)

func check(condition: bool, message: String) -> void:
	if not condition: fail(message)

func until(condition: Callable, seconds: float = 12.0) -> bool:
	var deadline := clock + seconds
	while clock < deadline:
		if condition.call(): return true
		await process_frame
	return condition.call()

func frames(count: int = 2) -> void:
	for i in count:
		await process_frame

func tap(device: int, index: JoyButton) -> void:
	for pressed in [true, false]:
		var event := InputEventJoypadButton.new()
		event.device = device
		event.button_index = index
		event.pressed = pressed
		Input.parse_input_event(event)
		await frames()

func stick(device: int, value: float) -> void:
	var event := InputEventJoypadMotion.new()
	event.device = device
	event.axis = JOY_AXIS_LEFT_X
	event.axis_value = value
	Input.parse_input_event(event)

func key(code: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)

func press(node_name: String) -> void:
	var button: Button = main.screen.find_child(node_name, true, false)
	check(button != null and not button.disabled, "No live %s button on the %s screen" % [node_name, main.view])
	button.pressed.emit()
	await process_frame

func seat_of(player_name: String) -> int:
	for m in main.session.members:
		if str(m.name) == player_name: return int(m.slot)
	return -1

func at(slot: int) -> Vector2:
	return Vector2(main.model.players[slot].x, main.model.players[slot].z)

func moved(slot: int) -> Vector2:
	return at(slot) - start[slot]

func note_start() -> void:
	start = []
	for i in 6:
		start.append(at(i))

func run() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.test_mode = true
	main.sound_enabled = false
	main.preferred_game = "twisted"
	main.session.select_game("twisted")
	main._show_menu()
	main.name_field.text = role.to_upper()
	if role == "host":
		await host()
	else:
		await guest()

func host() -> void:
	# Pad 0 takes player one; pad 1 joins as a player of its own.
	await tap(d(0), JOY_BUTTON_DPAD_DOWN)
	await tap(d(1), JOY_BUTTON_A)
	check(Array(main.pads.extras) == [d(1)], "Pad 1 joins on the menu")
	main._open_host()
	main.port_field.text = str(port)
	main._host()
	check(main.view == "lobby" and main.session.mode == "host", "The host opens a lobby")
	check(main.session.members.size() == 2 and main.session.pad_slot(d(1)) == 1, "The pad's player is seated in the lobby")
	check(main.screen.find_child("PadHint", true, false) != null, "The lobby says how pads join")
	check(await until(func(): return main.session.members.size() == 3, 20.0), "The guest joins")
	var guest_seat := seat_of("GUEST")
	check(guest_seat == 2, "The guest takes the next open seat, got %d" % guest_seat)
	check(main.session.votes_needed() == 1, "Two machines: one vote passes, got %d" % main.session.votes_needed())
	await press("Pick_livewire")
	await create_timer(1.0).timeout
	await press("Start")
	check(main.view == "game" and main.model is LiveModel, "A Live Wire round on the server")
	check(main.shared_screen and main.is_local(0) and main.is_local(1) and not main.is_local(2), "Two players on the host's screen")
	var model: RefCounted = main.model
	model.countdown = 1.0
	model._next_surge = 9999.0
	var parked: Array = []
	for i in range(3, 6):
		check(model.players[i].bot, "Open seats are bots")
		model.players[i].bot = false
		parked.append(i)
	note_start()
	# Held from before GO, as a key would be.
	stick(d(1), 0.9)
	check(await until(func(): return model.phase == "running" and model.elapsed >= 1.4), "The server runs the round")
	check(moved(1).x > 2.0 and absf(moved(1).y) < 1.0, "The pad's stick runs its own seat right, moved %s" % moved(1))
	check(moved(0).length() < 0.05, "The host's own seat stands still, moved %s" % moved(0))
	check(moved(guest_seat).y > 2.0 and absf(moved(guest_seat).x) < 0.3, "The guest's S runs the guest's seat, moved %s" % moved(guest_seat))
	for i in parked:
		check(moved(i).length() < 0.05, "Parked seat %d moved %s" % [i, moved(i)])
	stick(d(1), 0.0)
	await until(func(): return model.elapsed >= 2.0)
	check(not model.players[1]._r, "The stick let go")
	for i in parked:
		model.players[i].bot = true
	# The pad is unplugged mid-round.
	Input.joy_connection_changed.emit(d(1), false)
	await frames()
	check(model.players[1].bot and main.session.members.size() == 2, "The unplugged pad's seat becomes a bot")
	await until(func(): return model.elapsed >= 3.5)
	model.elapsed = 89.0
	check(await until(func(): return main.view == "results", 10.0), "The round ends on the results")
	await create_timer(1.0).timeout
	await press("Back")
	check(main.view == "lobby", "Back to the lobby")
	print("GAMEPAD_ONLINE_HOST_PASS pad-seat-own-input guest-own-input unplug-becomes-bot lobby")
	await until(func(): return main.session.members.size() == 1, 15.0)
	main._leave()
	quit(0)

func guest() -> void:
	main._open_join()
	main.address_field.text = "127.0.0.1"
	main.port_field.text = str(port)
	main._join()
	check(await until(func(): return main.view == "lobby" and main.session.members.size() == 3, 20.0), "The guest reaches the lobby with three members")
	var extras: Array = main.session.members.filter(func(m): return m.has("pad"))
	check(extras.size() == 1 and int(extras[0].peer) == 1 and str(extras[0].name) == "PLAYER 2", "One extra seat on the host machine")
	check(main.session.my_slot() == 2, "The guest's own seat, got %d" % main.session.my_slot())
	check(main._member_name(main.session.leader_id) == "HOST", "The host machine's first member is its host")
	check(main.session.votes_needed() == 1, "Votes count machines, not seats")
	if Input.get_connected_joypads().is_empty():
		check(main.screen.find_child("PadHint", true, false) == null, "No pad hint without pads")
	check(await until(func(): return main.view == "game", 30.0), "The guest is launched into the round")
	var model: RefCounted = main.model
	var me: int = main.session.my_slot()
	check(not main.shared_screen and main.local_mask == 1 << me, "One player on the guest's screen")
	check(main.play.plates[me].own and not main.play.plates[1].own and main.play.plates[1].role == "P2", "The host's pad seat is another player's plate")
	check(await until(func(): return model.phase == "running", 15.0), "Snapshots carry the round to the guest")
	note_start()
	key(KEY_S, true)
	await until(func(): return model.elapsed >= 1.4)
	key(KEY_S, false)
	check(moved(me).y > 1.5, "The guest's S runs its own seat, moved %s" % moved(me))
	check(moved(1).x > 1.5, "The pad's seat moves on the guest's screen too, moved %s" % moved(1))
	check(await until(func(): return model.players[1].bot, 10.0), "The unplugged pad's seat turns into a bot for the guest")
	check(await until(func(): return main.view == "lobby", 20.0), "The guest follows the host back to the lobby")
	check(main.session.members.size() == 2, "The unplugged pad's seat is gone from the roster")
	print("GAMEPAD_ONLINE_GUEST_PASS roster pad-seat-snapshots own-input bot-handover lobby")
	main._leave()
	quit(0)
