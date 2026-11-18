extends SceneTree
## LAN discovery end to end, as two real Godot processes running the real game
## scene. The host opens a party through the Host dialog; the browser opens the
## Join dialog, waits for the party to appear in the list, presses Enter on the
## focused entry and checks the roster it joined. Run by tests/run_tests.py.
##
##   --role=host|browser  --port=<ENet port>  --discovery=<discovery port>
##   --target=127.0.0.1   send beacons by unicast instead of broadcast (deterministic)
##   --best-effort        report, rather than fail, when no beacon arrives
##   --junk               (browser) expect the incompatible beacon the runner sends
const Discovery = preload("res://scripts/discovery.gd")
const HOST_NAME := "HOSTBOT"
const BROWSER_NAME := "BROWSEBOT"
var main: Node
var role := "host"
var game_port := 0
var best_effort := false
var expect_junk := false
var clock := 0.0
var limit := 20.0
var finished := false
var phase := "start"
var saw_guest := false

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--role="): role = arg.get_slice("=", 1)
		if arg.begins_with("--port="): game_port = int(arg.get_slice("=", 1))
		if arg.begins_with("--discovery="): Discovery.port_override = int(arg.get_slice("=", 1))
		if arg.begins_with("--target="): Discovery.target_override = arg.get_slice("=", 1)
		if arg == "--best-effort": best_effort = true
		if arg == "--junk": expect_junk = true
	call_deferred("run")

func run() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.test_mode = true
	main.sound_enabled = false
	main.set_motion_speed(12.0)
	if role == "host":
		limit = 30.0
		main.name_field.text = HOST_NAME
		main._open_host()
		main.port_field.text = str(game_port)
		main._host()
		check(main.view == "lobby" and main.session.mode == "host", "Host dialog must open the lobby")
		check(main.beacon != null and main.beacon.is_advertising(), "Hosting must start the LAN beacon")
		check(main.beacon.port == Discovery.port_override, "Beacon must use the test discovery port")
		print("HOST_ADVERTISING port=%d discovery=%d" % [game_port, main.beacon.port])
		phase = "hosting"
	else:
		limit = 8.0 if best_effort else 15.0
		main.name_field.text = BROWSER_NAME
		main._open_join()
		check(main.lan_browser != null and main.lan_browser.status == "listening", "Join dialog must start listening")
		check(main.lan_empty.visible, "An empty list must show the searching state")
		print("BROWSER_LISTENING discovery=%d" % main.lan_browser.port)
		phase = "searching"

func _process(delta: float) -> bool:
	clock += delta
	if finished or main == null:
		return false
	if clock > limit:
		if role == "browser" and best_effort and phase == "searching":
			print("BROADCAST_NOT_RECEIVED: no beacon arrived within %.0fs; this environment may block UDP broadcast" % limit)
			done(0)
		else:
			fail("Timed out in phase %s" % phase)
		return false
	if role == "host":
		host_step()
	else:
		browser_step()
	return false

func host_step() -> void:
	var count: int = main.session.members.size()
	if count == 2 and not saw_guest:
		saw_guest = true
		var names: Array = main.session.members.map(func(m): return m.name)
		check(BROWSER_NAME in names, "Host roster must include the browser: %s" % str(names))
		print("HOST_ROSTER %s" % ",".join(names))
	if saw_guest and count == 1:
		# The guest left: check that leaving the party silences the beacon.
		main._leave()
		# The beacon notices on its next frame that the session stopped hosting.
		await process_frame
		await process_frame
		check(not main.beacon.is_advertising(), "Leaving the party must stop the beacon")
		check(Discovery.own_id.is_empty(), "Leaving must clear the beacon id")
		print("HOST_PASS advertised-joined-left-beacon-stopped")
		done(0)

func browser_step() -> void:
	if phase == "searching":
		var mine: Array = main.lan_parties.filter(func(p): return p.name == HOST_NAME)
		if expect_junk:
			var other: Array = main.lan_parties.filter(func(p): return p.name == "OLDBUILD")
			if other.is_empty() or mine.is_empty():
				return
			check(not other[0].compatible, "A beacon from another version must be marked incompatible")
			check(main.lan_rows[main.lan_parties.find(other[0])].disabled, "An incompatible party must not be joinable")
		elif mine.is_empty():
			return
		var party: Dictionary = mine[0]
		check(party.port == game_port, "Discovered port must be the host's ENet port")
		check(party.players == 1 and party.max == 6 and not party.round, "Beacon must report 1/6 in the lobby: %s" % str(party))
		check(party.game == "Spin Cycle", "Beacon must name the game")
		var row: Button = main.lan_rows[main.lan_parties.find(party)]
		check(row.visible and not row.disabled, "The discovered party must be a live entry")
		check(not main.lan_empty.visible, "The searching state must hide once a party is listed")
		print("BROWSER_FOUND %s at %s:%d (%s)" % [party.name, party.ip, party.port, "this computer" if party.local else "remote"])
		if best_effort:
			print("BROADCAST_RECEIVED via %s" % party.ip)
		# Press Enter on the focused entry, like a player would.
		phase = "focusing"
		if not row.has_focus():
			row.grab_focus()
		await process_frame
		check(row.has_focus(), "The entry must take keyboard focus")
		for pressed in [true, false]:
			var key := InputEventKey.new()
			key.keycode = KEY_ENTER
			key.physical_keycode = KEY_ENTER
			key.pressed = pressed
			root.push_input(key)
		phase = "joining"
		check(not is_instance_valid(main.lan_browser) or (not main.lan_browser.is_inside_tree() and main.lan_browser.role == "idle"), "Joining must close the Join dialog's listener")
		check(main.session.mode == "joining" or main.session.mode == "client", "Enter on the entry must start joining (mode=%s)" % main.session.mode)
		check(main.address == party.ip and main.server_port == game_port, "Join must use the beacon's source address and advertised port")
	elif phase == "joining":
		if main.session.mode == "client" and main.session.members.size() == 2 and main.view == "lobby":
			var names: Array = main.session.members.map(func(m): return m.name)
			check(HOST_NAME in names and BROWSER_NAME in names, "Joined roster must hold host and browser: %s" % str(names))
			print("BROWSER_ROSTER %s" % ",".join(names))
			print("BROWSER_PASS discovered-entry-enter-joined-roster")
			phase = "leaving"
			main._leave()
			done(0)

func check(condition: bool, message: String) -> void:
	if not condition:
		fail(message)

func done(code: int) -> void:
	if finished: return
	finished = true
	await create_timer(0.3).timeout
	if main:
		main.session.close()
	quit(code)

func fail(message: String) -> void:
	if finished: return
	finished = true
	push_error(message)
	quit(1)
