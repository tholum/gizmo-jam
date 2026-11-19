extends SceneTree
## Three real copies of the game play one online Live Wire round, each running
## the production main scene and driven through its buttons and key events.
## Started by tests/run_online.py, one process per role:
##   host     opens the party on Spin Cycle, switches it to Live Wire in the
##            lobby, starts the round, steps the model, steers its own seat
##            with D, ends the round and returns everyone to the lobby.
##   player   joins, sees the switch, steers with S and dashes with Space, and
##            checks everything in the model it rebuilt from snapshots.
##   quitter  joins, never touches a key, and leaves the party mid-round.
## Checked on the server's model and again on the player's snapshot copy:
## each seat moves only for its own peer's keys, the dash lands on the seat
## that pressed it, the seat nobody steers stands still, and the quitter's
## seat becomes a bot that plays on. The player also checks that its renderer
## and HUD follow the snapshots, then follows the results and the lobby.
##
## The open seats would normally be bots from the start. The host parks them
## until the steering checks are done, so that nothing but a key press can
## move a runner, then lets them play.
## `-- --shots` (under xvfb) saves what the player sees to test-output/online-*.png.
const LiveModel = preload("res://scripts/livewire_model.gd")

var main: Node
var role := "host"
var port := 19801
var shots := false
var clock := 0.0
var start: Array = []

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--role="): role = arg.get_slice("=", 1)
		if arg.begins_with("--port="): port = int(arg.get_slice("=", 1))
		if arg == "--shots": shots = true
	call_deferred("run")

func _process(delta: float) -> bool:
	clock += delta
	if clock > 60.0:
		fail("Timed out in view '%s'" % (main.view if main else "?"))
	return false

func fail(message: String) -> void:
	push_error("%s: %s" % [role, message])
	print("ONLINE CHECK FAILED (%s): %s" % [role, message])
	quit(1)

func check(condition: bool, message: String) -> void:
	if not condition: fail(message)

## Waits for a condition, by the clock rather than by frame count.
func until(condition: Callable, seconds: float = 12.0) -> bool:
	var deadline := clock + seconds
	while clock < deadline:
		if condition.call(): return true
		await process_frame
	return condition.call()

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

func capture(filename: String) -> void:
	if not shots: return
	await create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://test-output")
	root.get_texture().get_image().save_png("res://test-output/" + filename + ".png")

func seat_of(player_name: String) -> int:
	for m in main.session.members:
		if str(m.name) == player_name: return int(m.slot)
	return -1

func at(slot: int) -> Vector2:
	return Vector2(main.model.players[slot].x, main.model.players[slot].z)

func moved(slot: int) -> Vector2:
	return at(slot) - start[slot]

func run() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.test_mode = true
	main.sound_enabled = false
	# Whatever this machine's settings file says, every copy starts on Spin Cycle.
	main.preferred_game = "twisted"
	main.session.select_game("twisted")
	main._show_menu()
	main.name_field.text = role.to_upper()
	if role == "host":
		await host()
	else:
		await guest()

## Remembers where every seat starts; the same on every peer, since each one
## builds the model from the launch.
func note_start() -> void:
	start = []
	for i in 6:
		start.append(at(i))

func host() -> void:
	main._open_host()
	main.port_field.text = str(port)
	main._host()
	check(main.view == "lobby" and main.session.mode == "host", "The host opens a lobby")
	check(await until(func(): return main.session.members.size() == 3, 20.0), "Two clients join the lobby")
	check(main.arena.visible and not main.live_arena.active, "The party opens on Spin Cycle")
	await press("Pick_livewire")
	check(main.session.game == "livewire" and main.live_arena.active and not main.arena.visible, "The host switches the party to Live Wire")
	# Long enough for both guests to have redrawn their lobby; they check it themselves.
	await create_timer(1.0).timeout
	await press("Start")
	check(main.view == "game" and main.model is LiveModel, "The round runs the Live Wire model on the server")
	var model: RefCounted = main.model
	model.countdown = 1.0
	model._next_surge = 9999.0
	var me: int = main.session.my_slot()
	var player := seat_of("PLAYER")
	var quitter := seat_of("QUITTER")
	var parked: Array = []
	for i in 6:
		if i not in [me, player, quitter]:
			check(model.players[i].bot, "Open seats are bots")
			model.players[i].bot = false
			parked.append(i)
	note_start()
	# The player holds S from GO for a second, then dashes.
	check(await until(func(): return model.phase == "running" and model.elapsed >= 1.4), "The server runs the round")
	check(moved(player).y > 2.0 and absf(moved(player).x) < 0.3, "The player's S key runs their own seat down, moved %s" % moved(player))
	check(float(model.players[player].cool) > 0.0, "The player's Space dashes their own seat")
	for i in 6:
		if i != player:
			check(moved(i).length() < 0.05, "Seat %d moved %s on the player's keys" % [i, moved(i)])
			check(float(model.players[i].cool) == 0.0, "Seat %d dashed on the player's key" % i)
	# Now the host's own key.
	await until(func(): return model.elapsed >= 1.6)
	key(KEY_D, true)
	await until(func(): return model.elapsed >= 2.4)
	key(KEY_D, false)
	await until(func(): return model.elapsed >= 2.8)
	check(moved(me).x > 2.0 and absf(moved(me).y) < 0.3, "The host's D key runs the host's seat right, moved %s" % moved(me))
	check(not model.players[me]._r, "And lets go of it")
	check(moved(quitter).length() < 0.05, "Nobody steers the quitter's seat, yet it moved %s" % moved(quitter))
	for i in parked:
		check(moved(i).length() < 0.05, "Parked seat %d moved %s" % [i, moved(i)])
		model.players[i].bot = true
	# The quitter walks out.
	check(await until(func(): return main.session.members.size() == 2, 15.0), "The quitter leaves the party mid-round")
	check(main.view == "game" and model.phase == "running", "The round goes on without them")
	var left: Dictionary = model.players[quitter]
	check(left.bot and str(left.name).ends_with(LiveModel.BOT_SUFFIX), "Their seat becomes a bot, is '%s'" % left.name)
	var from := at(quitter)
	check(await until(func(): return at(quitter).distance_to(from) > 1.0, 6.0), "And the bot plays it")
	await create_timer(1.0).timeout
	# The buzzer, the results, the lobby.
	model.elapsed = 89.0
	check(await until(func(): return main.view == "results", 10.0), "The round ends on the results")
	await create_timer(1.5).timeout
	await press("Back")
	check(main.view == "lobby" and main.model == null and main.live_arena.active, "The host returns everyone to the lobby")
	print("ONLINE_HOST_PASS server-steps-model own-keys-own-seat dash-own-seat disconnect-becomes-bot results lobby")
	await until(func(): return main.session.members.size() == 1, 15.0)
	main._leave()
	quit(0)

func guest() -> void:
	main._open_join()
	main.address_field.text = "127.0.0.1"
	main.port_field.text = str(port)
	main._join()
	check(await until(func(): return main.view == "lobby", 20.0), "The guest reaches the lobby")
	check(not main.session.is_leader(), "A guest is not the party leader")
	# The host's switch arrives with a roster and redraws this lobby.
	check(await until(func(): return main.session.game == "livewire" and main.live_arena.active and not main.arena.visible, 20.0), "The guest sees the host switch to Live Wire")
	var locked: Button = main.screen.find_child("Pick_twisted", true, false)
	var begin: Button = main.screen.find_child("Start", true, false)
	check(locked != null and locked.disabled and begin != null and begin.disabled, "A guest can neither switch games nor start")
	check(not main.session.select_game("twisted"), "And the session refuses if they try")
	if role == "player":
		await capture("online-lobby-guest")
	check(await until(func(): return main.view == "game", 30.0), "The guest is launched into the round")
	check(main.play.ID == "livewire" and main.model is LiveModel and main.live_arena.active, "It is a Live Wire round, on the hex floor")
	var model: RefCounted = main.model
	var me: int = main.session.my_slot()
	note_start()
	check(await until(func(): return model.phase == "running", 15.0), "Snapshots carry the round to the guest")
	if role == "quitter":
		await quitter(model, me)
		return
	var host := seat_of("HOST")
	var other := seat_of("QUITTER")
	key(KEY_S, true)
	await until(func(): return model.elapsed >= 1.0)
	key(KEY_S, false)
	key(KEY_SPACE, true)
	key(KEY_SPACE, false)
	check(await until(func(): return model.elapsed >= 1.4), "The round goes on")
	check(moved(me).y > 2.0 and absf(moved(me).x) < 0.3, "My S key runs my own seat down, moved %s" % moved(me))
	check(float(model.players[me].cool) > 0.0, "My Space dashes my own seat")
	check(int(model.players[me].tiles) >= 3, "Running paints tiles, got %d" % model.players[me].tiles)
	for i in 6:
		if i == host:
			# A guest can skip ahead to a snapshot after the host begins steering right.
			var motion := moved(i)
			check(absf(motion.y) < 0.05 and motion.x >= -0.05, "The host moved on my S key: %s" % motion)
			check(float(model.players[i].cool) == 0.0, "The host dashed on my Space key")
		elif i != me:
			check(moved(i).length() < 0.05, "Seat %d moved %s on my keys" % [i, moved(i)])
	check(main.play.sent.is_empty() or not main.play.sent.get("down", false), "Nothing is left held")
	check(await until(func(): return model.elapsed >= 2.8), "The round goes on")
	check(moved(host).x > 2.0, "The host's key moves the host's seat in my copy, moved %s" % moved(host))
	check(moved(other).length() < 0.05, "The seat nobody steers stands still, moved %s" % moved(other))
	# The renderer and the HUD follow the snapshots.
	var drawn: Dictionary = main.live_arena.runners[me]
	check(drawn.root.visible and Vector2(drawn.pos).distance_to(at(me)) < 0.6, "My runner is drawn where the snapshots put it")
	check(main.play.plates[me].tiles == int(model.players[me].tiles) and main.play.plates[me].role == "YOU", "My plate shows my tiles")
	check(main.play.plates[host].role == "P%d" % (host + 1), "The host's plate is labelled as a player")
	await capture("online-client-game")
	# The quitter's seat is handed to a bot.
	check(await until(func(): return model.players[other].bot, 15.0), "The quitter's seat turns into a bot in my snapshots")
	check(str(model.players[other].name).ends_with(LiveModel.BOT_SUFFIX), "And is labelled as one: '%s'" % model.players[other].name)
	var from := at(other)
	check(await until(func(): return at(other).distance_to(from) > 1.0, 6.0), "The bot plays the seat")
	check(await until(func(): return main.play.plates[other].role == "CPU", 2.0), "Its plate says CPU")
	await capture("online-client-bot")
	check(await until(func(): return main.view == "results", 20.0), "The buzzer and the results reach the guest")
	check(model.phase == "finished" and main.live_arena.active, "On the finished floor")
	var again: Button = main.screen.find_child("Again", true, false)
	check(again != null and again.disabled, "Only the leader can replay")
	await capture("online-client-results")
	check(await until(func(): return main.view == "lobby", 20.0), "The host brings everyone back to the lobby")
	check(main.model == null and main.session.game == "livewire", "Still on Live Wire")
	print("ONLINE_PLAYER_PASS snapshots-drive-model-renderer-hud own-keys-own-seat disconnect-becomes-bot results lobby")
	main._leave()
	check(main.view == "menu" and main.session.game == "twisted" and main.arena.visible and not main.live_arena.active, "Leaving returns a guest to their own game's menu")
	quit(0)

func quitter(model: RefCounted, me: int) -> void:
	check(await until(func(): return model.elapsed >= 3.6, 20.0), "The round goes on")
	check(moved(me).length() < 0.05, "I never pressed a key, yet my seat moved %s" % moved(me))
	print("ONLINE_QUITTER_PASS idle-seat-stands-still left-mid-round")
	main._leave()
	check(main.view == "menu" and main.model == null and main.arena.visible and not main.live_arena.active, "Leaving mid-round returns to the menu")
	await create_timer(0.3).timeout
	quit(0)
