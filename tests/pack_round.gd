extends SceneTree
## Game packs in a real party, one process per role, started by
## tests/run_packs.py. Every process runs the production main scene.
##
## Scenario "signed": the host has the example game installed from a signed
## catalog; the guest has nothing. The host picks the example game; the guest
## fetches the catalog and the pack from the host's file server, checks them
## and loads the game; a 0.2.0 guest (tests/legacy_guest.gd) is shown as
## needing an update. The round launches for host and guest only, the 0.2.0
## seat is a bot, the guest's key reaches its own seat. Back in the lobby the
## host picks Spin Cycle and all three are launched.
##
## Scenario "dev": the host has the example game as an unsigned developer pack.
## A guest in developer mode is asked, accepts, and gets it from the host; a
## guest without developer mode sits the round out.
const Registry = preload("res://scripts/game_registry.gd")

var main: Node
var role := "host"
var scenario := "signed"
var port := 19901
var clock := 0.0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--role="): role = arg.get_slice("=", 1)
		if arg.begins_with("--scenario="): scenario = arg.get_slice("=", 1)
		if arg.begins_with("--port="): port = int(arg.get_slice("=", 1))
	call_deferred("run")

func _process(delta: float) -> bool:
	clock += delta
	if clock > 100.0:
		fail("Timed out in view '%s'" % (main.view if main else "?"))
	return false

func fail(message: String) -> void:
	push_error("%s: %s" % [role, message])
	print("PACK CHECK FAILED (%s): %s" % [role, message])
	quit(1)

func check(condition: bool, message: String) -> void:
	if not condition: fail(message)

func until(condition: Callable, seconds: float = 15.0) -> bool:
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
	var button: Button = main.find_child(node_name, true, false)
	check(button != null and not button.disabled, "No live %s button on the %s screen" % [node_name, main.view])
	button.pressed.emit()
	await process_frame

func peer_named(player_name: String) -> int:
	for m in main.session.members:
		if str(m.name) == player_name: return int(m.peer)
	return 0

func state_of(player_name: String) -> String:
	return str(main.session.member_state(peer_named(player_name)).state)

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
		if scenario == "signed": await host_signed()
		elif scenario == "web": await host_web()
		elif scenario == "browser": await host_browser()
		else: await host_dev()
	else:
		await guest()

func open_lobby() -> void:
	main._open_host()
	main.port_field.text = str(port)
	main._host()
	check(main.view == "lobby" and main.session.mode == "host", "The host opens a lobby")
	check(main.session.file_port > 0, "The host serves files")

func host_signed() -> void:
	var trust: String = Registry.entry("example").get("trust", "")
	check(trust == "signed", "The host has the example game from the signed catalog (trust '%s', notes %s)" % [trust, main.packs.problems])
	await open_lobby()
	check(await until(func(): return main.session.members.size() == 3, 25.0), "Two guests join")
	# The 0.2.0 guest never says what it has; after HELLO_WAIT it is legacy.
	check(await until(func(): return main.session.caps.has(peer_named("LEGACY")), 8.0), "The 0.2.0 guest is recognised")
	check(main.session.caps[peer_named("LEGACY")].legacy, "as a 0.2.0 build")
	check(not main.session.caps[peer_named("GUEST")].legacy, "The new guest sent its capabilities")
	await press("Pick_example")
	check(main.session.game == "example", "The host picks the example game")
	check(state_of("LEGACY") == "needs_update", "The 0.2.0 guest needs an update, is %s" % state_of("LEGACY"))
	check(await until(func(): return state_of("GUEST") == "ready", 30.0), "The guest gets the game, is %s" % state_of("GUEST"))
	var sha: String = Registry.entry("example").sha256
	check(int(main.file_server.served.get("/packs/%s.pck" % sha, 0)) >= 1, "The guest downloaded the pack from the host: %s" % main.file_server.served)
	check(int(main.file_server.served.get("/catalog", 0)) >= 1, "and the host's catalog")
	check(main.session.waiting_count() == 0, "Nobody to wait for")
	await press("Start")
	check(main.view == "game" and main.play.ID == "example", "The example round starts on the host")
	var guest_seat := -1
	var legacy_seat := -1
	for m in main.session.members:
		if m.name == "GUEST": guest_seat = int(m.slot)
		if m.name == "LEGACY": legacy_seat = int(m.slot)
	check(main.session.round_peers.size() == 2 and peer_named("GUEST") in main.session.round_peers, "Host and guest are in the round: %s" % [main.session.round_peers])
	check(main.model.players[legacy_seat].bot, "A bot plays the 0.2.0 guest's seat")
	check(not main.model.players[guest_seat].bot, "The guest plays their own seat")
	check(await until(func(): return main.model.phase == "running", 10.0), "The round runs")
	var guest: Dictionary = main.model.players[guest_seat]
	check(await until(func(): return int(guest.score) + int(guest.misses) >= 2, 20.0), "The guest's key presses reach their seat")
	main.model.elapsed = 29.5
	check(await until(func(): return main.view == "results", 10.0), "The round ends on the results")
	await create_timer(1.0).timeout
	await press("Back")
	check(main.view == "lobby", "Back to the lobby")
	await press("Pick_twisted")
	check(await until(func(): return main.session.waiting_count() == 0 and state_of("LEGACY") == "ready", 5.0), "Everyone can play Spin Cycle")
	await create_timer(1.0).timeout
	await press("Start")
	check(main.view == "game" and main.play.ID == "twisted", "The Spin Cycle round starts")
	check(main.session.round_peers.size() == 3, "All three are in it: %s" % [main.session.round_peers])
	await create_timer(2.0).timeout
	main.session.lobby()
	check(await until(func(): return main.view == "lobby", 5.0), "The host returns everyone to the lobby")
	await create_timer(2.0).timeout
	print("PACK_HOST_PASS signed-catalog download-from-host legacy-sits-out own-seat builtin-for-all")
	main._leave()
	quit(0)

func host_dev() -> void:
	var trust: String = Registry.entry("example").get("trust", "")
	check(trust == "untrusted", "The host has the example game as a developer pack (trust '%s', notes %s)" % [trust, main.packs.problems])
	await open_lobby()
	check(await until(func(): return main.session.members.size() == 3, 25.0), "Two guests join")
	await press("Pick_example")
	check(await until(func(): return state_of("NODEV") == "untrusted", 15.0), "The guest without developer mode refuses it, is %s (caps %s, states %s)" % [state_of("NODEV"), main.session.caps.get(peer_named("NODEV")), main.session.states])
	check(await until(func(): return state_of("DEVGUEST") == "ready", 30.0), "The developer guest accepts and gets it, is %s" % state_of("DEVGUEST"))
	await press("Start")
	check(main.view == "game" and main.play.ID == "example", "The example round starts")
	check(main.session.round_peers.size() == 2 and peer_named("DEVGUEST") in main.session.round_peers, "Host and the developer guest play: %s" % [main.session.round_peers])
	await create_timer(3.0).timeout
	main.session.lobby()
	check(await until(func(): return main.view == "lobby", 5.0), "Back to the lobby")
	await create_timer(2.0).timeout
	print("PACK_HOST_PASS untrusted-pack consent dev-mode-off-sits-out")
	main._leave()
	quit(0)

## Browser guests: one guest joins over ENet, one the way the browser build
## does (party.json from the host's file server, then a WebSocket). Both fetch
## the example pack from the host and play it.
func host_web() -> void:
	main.browser_guests = true
	await open_lobby()
	check(main.session.web_port > 0, "The host accepts browsers")
	check(await until(func(): return main.packs.web.get("state", "") == "ready", 10.0), "The browser build is ready to serve: %s" % main.packs.web)
	var note: Label = main.find_child("JoinNote", true, false)
	check(note != null and "http://" in note.text, "The lobby tells browsers where to go: '%s'" % (note.text if note else ""))
	check(await until(func(): return main.session.members.size() == 3, 25.0), "A native and a browser guest join")
	var web_peer := peer_named("WEBGUEST")
	check(main.session.is_browser(web_peer) and not main.session.is_browser(peer_named("GUEST")), "The host knows which guest is in a browser")
	await press("Pick_example")
	check(await until(func(): return state_of("GUEST") == "ready" and state_of("WEBGUEST") == "ready", 30.0), "Both guests get the game: %s / %s" % [state_of("GUEST"), state_of("WEBGUEST")])
	await press("Start")
	check(main.session.round_peers.size() == 3, "All three play: %s" % [main.session.round_peers])
	var seat := -1
	for m in main.session.members:
		if m.name == "WEBGUEST": seat = int(m.slot)
	check(await until(func(): return main.model.phase == "running", 10.0), "The round runs")
	var p: Dictionary = main.model.players[seat]
	check(await until(func(): return int(p.score) + int(p.misses) >= 2, 20.0), "The browser guest's keys reach their seat")
	main.model.elapsed = 29.5
	check(await until(func(): return main.view == "results", 10.0), "Results")
	await create_timer(1.0).timeout
	await press("Back")
	await create_timer(2.0).timeout
	print("PACK_HOST_PASS browser-guest-over-websocket same-party pack-download")
	main._leave()
	quit(0)

## A real browser (tests/run_browser.py drives headless Chrome) loads the
## browser build from this host, joins, is launched into a Spin Cycle round
## and presses Space.
func host_browser() -> void:
	main.browser_guests = true
	await open_lobby()
	check(await until(func(): return main.packs.web.get("state", "") == "ready", 10.0), "The browser build is ready to serve: %s" % main.packs.web)
	print("HOST_READY file_port=%d web_port=%d" % [main.session.file_port, main.session.web_port])
	check(await until(func(): return peer_named("BROWSER") != 0, 90.0), "The browser joins the party")
	var peer := peer_named("BROWSER")
	check(main.session.is_browser(peer), "over a WebSocket")
	check(int(main.file_server.served.get("/index.wasm", 0)) >= 1, "after loading the game from this host: %s" % main.file_server.served)
	var seat := -1
	for m in main.session.members:
		if int(m.peer) == peer: seat = int(m.slot)
	var inputs := [0]
	main.session.input_received.connect(func(slot, _action, _pressed): if slot == seat: inputs[0] += 1)
	await create_timer(2.0).timeout
	await press("Start")
	check(peer in main.session.round_peers, "The browser guest is in the round")
	check(await until(func(): return inputs[0] >= 2, 40.0), "Its Space presses reach its seat (%d)" % inputs[0])
	await create_timer(1.0).timeout
	main.session.lobby()
	await create_timer(2.0).timeout
	print("PACK_HOST_PASS real-browser-loaded-joined-launched-input")
	main._leave()
	quit(0)

func join() -> void:
	main._open_join()
	main.address_field.text = "127.0.0.1"
	main.port_field.text = str(port)
	main._join()
	check(await until(func(): return main.view == "lobby", 20.0), "The guest reaches the lobby")

func guest() -> void:
	check(not Registry.has("example"), "The guest starts without the example game")
	if role == "webguest":
		# The browser build's menu and join, minus the browser.
		main.on_web = true
		# On the website (https) the browser build plays solo and points to the download.
		main._show_menu()
		check(main.screen.find_child("JoinPage", true, false) == null and main.screen.find_child("GetGame", true, false) != null, "The website build offers the download instead of joining")
		main.web_party = true
		main._show_menu()
		main.name_field.text = "WEBGUEST"
		await press("JoinPage")
		check(await until(func(): return main.view == "lobby", 20.0), "The browser guest reaches the lobby")
		check(main.multiplayer.multiplayer_peer is WebSocketMultiplayerPeer, "over a WebSocket")
	else:
		await join()
	check(await until(func(): return main.session.game == "example", 30.0), "The guest sees the host pick the example game")
	if role == "nodev":
		check(await until(func(): return main.packs.status("example").get("state", "") == "untrusted", 15.0), "Without developer mode the unsigned game is refused")
		check(not Registry.has("example"), "and never loaded")
		check(await until(func(): return main.session.sitting_out(), 20.0), "This guest sits the round out")
		check(main.view == "lobby", "in the lobby")
		check(await until(func(): return not main.session.sitting_out(), 30.0), "until the round ends")
		print("PACK_NODEV_PASS refused-unsigned sat-out")
		await until(func(): return main.session.mode == "offline", 20.0)
		quit(0)
		return
	if role == "devguest":
		check(await until(func(): return main.overlay.find_child("AcceptUntrusted", true, false) != null, 20.0), "The developer guest is asked about the unsigned game")
		var accept: Button = main.overlay.find_child("AcceptUntrusted", true, false)
		accept.pressed.emit()
	check(await until(func(): return Registry.has("example"), 30.0), "The guest loads the example game (state %s)" % main.packs.status("example"))
	var trust: String = Registry.entry("example").trust
	check(trust == ("untrusted" if role == "devguest" else "signed"), "with the right trust: %s" % trust)
	check(main.games.has("example"), "and its module")
	check(await until(func(): return main.view == "game", 40.0), "The guest is launched into the round")
	check(main.play.ID == "example", "an example round")
	if role == "devguest":
		check(await until(func(): return main.view == "lobby", 30.0), "Back to the lobby")
		print("PACK_DEVGUEST_PASS asked-accepted-downloaded played")
		await until(func(): return main.session.mode == "offline", 20.0)
		quit(0)
		return
	check(await until(func(): return main.model.phase == "running", 15.0), "The round runs here too")
	for i in 6:
		key(KEY_SPACE, true)
		await create_timer(0.1).timeout
		key(KEY_SPACE, false)
		await create_timer(0.25).timeout
	check(await until(func(): return main.view == "results", 30.0), "The guest sees the results")
	check(await until(func(): return main.view == "lobby", 20.0), "and the lobby")
	if scenario == "web":
		print("PACK_%s_PASS pack-from-host played results" % role.to_upper())
		await until(func(): return main.session.mode == "offline", 20.0)
		quit(0)
		return
	check(await until(func(): return main.view == "game" and main.play.ID == "twisted", 30.0), "Then a Spin Cycle round")
	check(await until(func(): return main.view == "lobby", 20.0), "and the lobby again")
	print("PACK_GUEST_PASS catalog-from-host pack-from-host verified loaded played builtin")
	await until(func(): return main.session.mode == "offline", 20.0)
	quit(0)
