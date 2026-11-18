extends SceneTree
## Exercise the real menu -> host lobby -> round -> party menu -> results flow,
## first for Spin Cycle, then for Live Wire (game selection, arena swap,
## production key events, the HUD states, results, switching games in a party).
## `-- --only=livewire` skips the Spin Cycle half.
const LIVE_KEYS := [KEY_W, KEY_A, KEY_S, KEY_D, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_SPACE]
const Discovery = preload("res://scripts/discovery.gd")
var main: Node
var only := ""

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="): only = arg.get_slice("=", 1)
	call_deferred("run")

## Unlike assert(), a failed check ends the run with an error instead of hanging it.
func check(condition: bool, message: String) -> void:
	if not condition:
		push_error("SMOKE CHECK FAILED: " + message)
		print("SMOKE CHECK FAILED: " + message)
		quit(1)

func key(code: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)

func frames(count: int) -> void:
	for i in count:
		await process_frame

func capture(filename: String) -> void:
	await create_timer(0.2).timeout
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://test-output")
	root.get_texture().get_image().save_png("res://test-output/" + filename + ".png")

## Captures after a short, exact delay so mid-animation feedback is visible.
func snap(filename: String, delay: float) -> void:
	await create_timer(delay).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://test-output/" + filename + ".png")

func frames_until(condition: Callable, limit: int = 600) -> bool:
	for i in limit:
		if condition.call(): return true
		await process_frame
	return false

## The round HUD states a calm mid-round frame never shows: the countdown, a
## clear, a hit, an elimination and a late round with spread-out scores.
func hud_states() -> void:
	main.set_motion_speed(1.0)
	main.session.start_round()
	assert(main.view == "game" and main.model.phase == "countdown")
	await snap("countdown-slam", 0.10)
	await snap("countdown", 0.5)
	main.model.countdown = 0.0
	main.model.phase = "running"
	var first: Dictionary = main.model.next_obstacle()
	await frames_until(func():
		var wave: Dictionary = main.model.next_obstacle()
		return not wave.is_empty() and (float(wave.at) - main.model.progress) / main.model.speed < 0.26)
	main.model.command(0, first.kind, true)
	var cleared: bool = await frames_until(func(): return main.model.players[0].score > 0)
	assert(cleared, "Acting on the cue must clear the first rod")
	await snap("clear", 0.10)
	main.model.command(0, "duck", false)
	# Stand still for the next rod: a real hit through the real pipeline.
	var struck: bool = await frames_until(func(): return main.model.players[0].hp < 7)
	assert(struck, "An ignored rod must cost a hit")
	await snap("hit", 0.09)
	var hp := [3, 5, 1, 0, 6, 2]
	var score := [41, 38, 44, 12, 40, 31]
	for i in 6:
		main.model.players[i].hp = hp[i]
		main.model.players[i].score = score[i]
	main.model.players[3].out_at = 21.0
	main.model.elapsed = 72.0
	await process_frame
	await process_frame
	main.model.players[5].hp = 0
	main.model.players[5].out_at = 72.0
	await snap("eliminated", 0.12)
	await snap("late", 0.7)
	main.set_motion_speed(12.0)

## The Join dialog's nearby-party list: searching, a mix of parties (one real
## beacon over loopback, the rest injected with LAN source addresses), and the
## note shown when another program holds the discovery port.
func join_list_states() -> void:
	main._open_join()
	assert(main.address_field != null and main.port_field != null)
	assert(main.lan_browser.status == "listening" and main.lan_empty.visible, "An empty list shows the searching state")
	await capture("join-dialog")
	var sender := PacketPeerUDP.new()
	sender.set_dest_address("127.0.0.1", main.lan_browser.port)
	sender.put_packet(Discovery.beacon_bytes("51de0001", "PLAYER TWO", 7777, 1, false, "Spin Cycle"))
	var fakes := [
		[{"id": "51de0002", "name": "Sam’s Den", "port": 7777, "players": 3, "max": 6, "round": false, "game": "Spin Cycle", "compatible": true}, "192.168.1.42"],
		[{"id": "51de0003", "name": "ROBOKID", "port": 7790, "players": 4, "max": 6, "round": true, "game": "Spin Cycle", "compatible": true}, "192.168.1.17"],
		[{"id": "", "name": "OLDBUILD", "port": 0, "players": 0, "max": 6, "round": false, "game": "", "compatible": false}, "192.168.1.66"]]
	for fake in fakes:
		main.lan_browser._heard(fake[0], fake[1])
	await frames_until(func(): return main.lan_parties.size() == 4)
	sender.close()
	assert(main.lan_parties.size() == 4 and not main.lan_empty.visible, "Discovered parties replace the searching state")
	assert(main.lan_rows[0].has_focus(), "The first joinable party takes focus")
	assert(main.lan_rows[3].disabled, "An incompatible party cannot be joined")
	await capture("join-dialog-parties")
	main._clear_overlay()
	var squatter := PacketPeerUDP.new()
	squatter.bind(Discovery.port_override, "0.0.0.0")
	main._open_join()
	assert(main.lan_browser.status == "busy" and main.address_field.has_focus(), "A taken port fails softly; manual join stays usable")
	await capture("join-dialog-busy")
	squatter.close()

func run() -> void:
	# Keep discovery on a private port and on loopback: never broadcast from tests.
	var probe := PacketPeerUDP.new()
	probe.bind(0, "127.0.0.1")
	Discovery.port_override = probe.get_local_port()
	probe.close()
	Discovery.target_override = "127.0.0.1"
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.test_mode = true
	main.sound_enabled = false
	# Whatever this machine's settings file says, the run starts on Spin Cycle.
	main.preferred_game = "twisted"
	main.session.select_game("twisted")
	main._show_menu()
	main.name_field.text = "PLAYER ONE"
	# The menu was built before test_mode sped up UI motion; let its entrance land.
	await create_timer(0.6).timeout
	if only != "livewire":
		await spin_cycle_flow()
	await livewire_flow()
	print("UI_FLOW_PASS %slivewire-select-swap-keys-hud-results-switch" % ("" if only == "livewire" else "menu-host-lobby-keyboard-round-party-results-lobby-menu "))
	quit()

func spin_cycle_flow() -> void:
	# Host now goes through the in-page dialog that owns the port field.
	main._open_host()
	assert(main.port_field != null, "Host dialog must expose the port field")
	await capture("host-dialog")
	main.port_field.text = "19777"
	main._host()
	assert(main.view == "lobby" and main.session.mode == "host")
	assert(main.beacon.is_advertising(), "Hosting makes the party visible on the LAN")
	await capture("lobby")
	main.session.start_round()
	assert(main.view == "game" and main.model.players.size() == 6)
	await process_frame
	assert(main.beacon.is_advertising(), "The party stays visible during rounds")
	main.model.countdown = 0.0
	main.model.phase = "running"
	# Send actual keyboard events to the production input handler.
	var key := InputEventKey.new()
	key.physical_keycode = KEY_SPACE
	key.pressed = true
	Input.parse_input_event(key)
	await process_frame
	assert(main.model.players[0].jump >= 0.0)
	# Capture the shared, side-by-side lineup after the test jump lands.
	await create_timer(0.7).timeout
	key.physical_keycode = KEY_S
	key.keycode = KEY_S
	key.pressed = true
	Input.parse_input_event(key)
	await process_frame
	await process_frame
	assert(main.model.players[0].duck, "Production key-down must hold duck")
	key.pressed = false
	Input.parse_input_event(key)
	await process_frame
	await process_frame
	assert(not main.model.players[0].duck, "Production key-up must release duck")
	await capture("game")
	main._toggle_pause()
	assert(main.paused)
	await capture("party")
	main._toggle_pause()
	await hud_states()
	# Complete a round with bots, exercising results construction and replay.
	for p in main.model.players:
		p.bot = true
	for i in 120 * 60:
		main.model.step(1.0 / 60.0)
		if main.model.phase == "finished": break
	assert(main.model.phase == "finished")
	main._show_results()
	await capture("results")
	main.session.lobby()
	assert(main.view == "lobby")
	main._leave()
	assert(main.view == "menu")
	await capture("menu")
	await join_list_states()
	main._clear_overlay()
	main._rules()
	await capture("rules")
	# Solo results: champion plate, podium and confetti.
	main._clear_overlay()
	main.session.solo("PLAYER ONE")
	main.session.start_round()
	for p in main.model.players:
		p.hp = 0
		p.out_at = 40.0 + p.score
	main.model.players[0].hp = 4
	main.model.players[0].out_at = -1.0
	main.model.players[0].score = 37
	main.model.players[0].best_streak = 14
	main.model.elapsed = 58.0
	main.model.phase = "finished"
	main._show_results()
	assert(main.view == "results")
	await capture("results-solo")
	main._leave()
	assert(main.view == "menu")

# ------------------------------------------------------------------ Live Wire

## Presses a named button on the current screen, as a click would.
func press(node_name: String) -> void:
	var button: Button = main.screen.find_child(node_name, true, false)
	check(button != null, "No button named %s on the %s screen" % [node_name, main.view])
	check(not button.disabled, "%s is disabled" % node_name)
	button.pressed.emit()
	await process_frame

## Which arena is on screen. Exactly one of them may be, with its own camera.
func on_stage() -> String:
	var spiral: bool = main.arena.visible and main.arena.camera.current
	var hexes: bool = main.live_arena.visible and main.live_arena.active and main.live_arena.camera.current
	check(spiral != hexes, "Exactly one arena must be on screen (spiral=%s hexes=%s)" % [spiral, hexes])
	return "livewire" if hexes else "twisted"

## Lets the bots play `seconds` of the round at once, the local seat included,
## then hands the seat back with nothing held and no surge of its own pending.
func fast_forward(seconds: float) -> void:
	var model: RefCounted = main.model
	var was_bot: Array = []
	for p in model.players:
		was_bot.append(p.bot)
		p.bot = true
	for i in int(seconds * 30.0):
		model.step(1.0 / 30.0)
	for i in 6:
		model.players[i].bot = was_bot[i]
	for action in ["left", "right", "up", "down"]:
		model.command(main.session.my_slot(), action, false)
	model.surges.clear()
	model._next_surge = 9999.0
	var own: Dictionary = model.players[main.session.my_slot()]
	own.stun = 0.0
	own.shove = 0.0
	# The HUD did not watch any of that; do not let it replay it as events.
	main.play.last_tiles = int(own.tiles)
	main.play.last_zaps = int(own.zaps)
	main.play.last_loops = int(own.loops)
	main.play.last_shoves = int(own.shoves)

func own_cell() -> int:
	var own: Dictionary = main.model.players[main.session.my_slot()]
	return main.model.grid.cell_at(Vector2(own.x, own.z))

func add_surge(id: int, axis: int, line: int, warn: float = 1.6) -> void:
	main.model.surges.append({"id": id, "axis": axis, "line": line, "warn": warn, "fire": 0.45})

## The HUD must never cover a tile: projects every tile corner through the
## round camera into the 1440x900 design space and compares it with the bands
## and corners the HUD draws in, then checks the widgets stay inside those.
func board_is_clear() -> void:
	var grid: RefCounted = main.model.grid
	var camera: Camera3D = main.live_arena.camera
	var bounds := Rect2()
	var first := true
	# Where the HUD draws: the call-out and feedback band, the plates (with the
	# local plate's 1.1 scale and the leader tab), the status stack, the menu corner.
	var hud := [Rect2(360, 0, 720, 195), Rect2(0, 764, 1440, 136), Rect2(0, 0, 360, 212), Rect2(1170, 0, 270, 104)]
	for i in grid.count():
		for k in 6:
			var a := deg_to_rad(30.0 + 60.0 * k)
			var corner := Vector3(grid.centers[i].x + cos(a) * grid.size, 0.0, grid.centers[i].y + sin(a) * grid.size)
			# With the canvas_items stretch the camera already answers in design units.
			var at: Vector2 = camera.unproject_position(corner)
			bounds = Rect2(at, Vector2.ZERO) if first else bounds.expand(at)
			first = false
			for zone in hud:
				check(not zone.has_point(at), "Tile %d is under the HUD at %s" % [i, at])
	print("LIVEWIRE_BOARD design-space bounds x %d..%d, y %d..%d" % [bounds.position.x, bounds.end.x, bounds.position.y, bounds.end.y])
	check(root.get_visible_rect().size == Vector2(1440, 900), "The design space is 1440x900")
	for plate in main.play.plates:
		# The leader tab (outline included) is the highest thing a plate draws: 6 px above its top edge.
		var top: float = plate.position.y + plate.size.y * (1.0 - plate.scale.y) - 6.0 * plate.scale.y
		check(top >= 764.0, "A player plate reaches up to y=%.1f, into the board" % top)
	var feedback: Control = main.hud_feedback
	# Outlined text, tilted: its lowest point over the board's top row (x 509..931).
	var lowest: float = feedback.position.y + feedback.size.y * 0.5 + feedback.font_size * 0.34 + feedback.outline_px + feedback.font_size * 0.06 + (720.0 - 509.0) * absf(feedback.tilt)
	check(lowest <= 196.0, "Feedback text reaches down to y=%.1f, onto the first row of tiles" % lowest)

func livewire_flow() -> void:
	var live: RefCounted = main.games["livewire"]
	main.set_motion_speed(12.0)
	check(main.view == "menu" and main.session.game == "twisted", "The Live Wire half starts on the menu with Spin Cycle picked")
	check(on_stage() == "twisted", "Spin Cycle's arena belongs behind its menu")
	# --- choosing the game on the menu
	main.sound_log.clear()
	await press("Card_livewire")
	check(main.session.game == "livewire" and main.preferred_game == "livewire", "Clicking the Live Wire card must select it")
	check(on_stage() == "livewire", "The hex floor must replace the spiral behind the menu")
	check("voice:game_livewire" in main.sound_log, "The announcer names the picked game")
	await capture("menu-livewire")
	main.screen.find_child("Card_livewire", true, false).get_node("How").pressed.emit()
	check(main.overlay.get_child_count() > 0, "Each card opens its own how-to-play dialog")
	await capture("rules-livewire")
	main._clear_overlay()
	await press("Card_twisted")
	check(main.session.game == "twisted" and on_stage() == "twisted", "Picking Spin Cycle swaps the arena back")
	await press("Card_livewire")
	# --- the lobby: the leader switches, everyone sees it
	main._open_host()
	main.port_field.text = "19778"
	main._host()
	check(main.view == "lobby" and main.session.game == "livewire", "Hosting starts a party on the selected game")
	check(on_stage() == "livewire", "The lobby sits in front of the selected game's arena")
	await capture("lobby-livewire")
	await press("Pick_twisted")
	check(main.session.game == "twisted" and on_stage() == "twisted", "The party leader switches games in the lobby")
	await press("Pick_livewire")
	check(main.session.game == "livewire" and on_stage() == "livewire", "And back again")
	# A guest's lobby: same panel, no live switch. (Real guests are in tests/network_peer.gd.)
	main.session.members.append({"peer": 77, "name": "NOVA PRIME", "slot": 1})
	main.session.leader_id = 77
	main._show_lobby()
	var locked: Button = main.screen.find_child("Pick_twisted", true, false)
	check(locked != null and locked.disabled, "A guest cannot switch games")
	check(not main.session.select_game("twisted") and main.session.game == "livewire", "The session refuses a guest's pick")
	await capture("lobby-guest")
	main.session.members.pop_back()
	main.session.leader_id = 1
	main._show_lobby()
	# --- the round: countdown, production key events, HUD states
	main.set_motion_speed(1.0)
	main.sound_log.clear()
	main.session.start_round()
	var model: RefCounted = main.model
	check(main.view == "game" and main.play == live and model.has_method("largest_patch"), "Live Wire rounds run the Live Wire model")
	check(on_stage() == "livewire" and not main.live_arena.menu_mode, "The round is played on the hex floor in its round framing")
	await snap("livewire-countdown-slam", 0.10)
	await snap("livewire-countdown", 0.5)
	var own: Dictionary = model.players[0]
	var from_x: float = own.x
	key(KEY_D, true)
	await frames(3)
	check(own._r, "A direction pressed during the countdown is remembered")
	key(KEY_SPACE, true)
	key(KEY_SPACE, false)
	await frames(2)
	check(float(own.cool) == 0.0, "Dash is ignored until GO")
	check(float(own.x) == from_x and int(own.tiles) == 1, "Nothing moves before GO")
	model.countdown = 0.0
	model.phase = "running"
	var moved: bool = await frames_until(func(): return float(own.x) > from_x + 0.9 and int(own.tiles) >= 2)
	check(moved, "Holding D must run right and paint tiles")
	key(KEY_D, false)
	await frames(3)
	check(not own._r, "Key-up must release the direction")
	key(KEY_LEFT, true)
	await frames(3)
	check(own._l, "Arrow keys move too")
	key(KEY_SPACE, true)
	key(KEY_SPACE, false)
	await frames(3)
	check(float(own.cool) > 0.0, "Space must dash")
	check("dash" in main.sound_log, "A dash is heard")
	check(main.play.sent.get("left", false), "The module tracks what the server holds")
	main._toggle_pause()
	await frames(3)
	check(main.paused and not own._l, "Opening the menu lets go of every direction")
	main._toggle_pause()
	await frames(3)
	check(own._l, "A key that is still down counts again when the menu closes")
	main._focus_lost()
	await frames(3)
	check(not own._l, "Losing window focus lets go of every direction")
	check(not main.paused, "An online round is not paused by focus loss")
	key(KEY_LEFT, false)
	key(KEY_TAB, true)
	await frames(2)
	check(main.live_arena.show_identities, "Hold Tab shows names on the hex floor")
	key(KEY_TAB, false)
	await frames(2)
	check(not main.live_arena.show_identities, "Releasing Tab hides them")
	board_is_clear()
	# Mid-game: let the bots paint the floor for a while.
	fast_forward(22.0)
	# Wind the clock back so the stage change at 30 s cannot land in the middle
	# of the staged moments below; the floor keeps its paint.
	model.elapsed = 10.0
	await snap("livewire-game", 1.6)
	check(int(own.best) > 3, "A bot-driven local seat paints the floor too")
	# A line charging somewhere else.
	main.sound_log.clear()
	var here := own_cell()
	var away: int = model.grid.line_of(here, 0) + (4 if model.grid.line_of(here, 0) < 0 else -4)
	add_surge(900, 0, away)
	await snap("livewire-surge", 0.6)
	check(main.play.cue.kind == "surge" and not main.play.on_the_line, "A line elsewhere is announced, not alarmed")
	check("surge_warn" in main.sound_log and "voice:surge" in main.sound_log, "The first surge is heard and called")
	model.surges.clear()
	await frames(4)
	check(main.play.cue.kind == "", "No surge, no call-out")
	# A line charging under the local runner, then firing.
	var patch_before: int = model.largest_patch(0).size()
	var tiles_before := int(own.tiles)
	add_surge(901, 1, model.grid.line_of(own_cell(), 1))
	await snap("livewire-danger", 0.7)
	check(main.play.on_the_line and main.play.cue.kind == "danger", "Standing on a charging line switches the call-out to MOVE!")
	check(main.damage_shade.visible, "And the hazard frame pulses")
	var zapped: bool = await frames_until(func(): return main.hud_feedback.message.begins_with("ZAPPED"))
	check(zapped, "The line fires and zaps whoever stayed on it")
	await snap("livewire-zapped", 0.12)
	# The bots are still playing, so they may have nibbled at the patch first.
	var lost := int(main.hud_feedback.message.trim_prefix("ZAPPED!  −").trim_suffix(" TILES"))
	check(main.hud_feedback.visible and lost >= 1 and lost <= patch_before, "The call-out counts the lost patch (%s, patch was %d)" % [main.hud_feedback.message, patch_before])
	check(int(own.tiles) <= tiles_before - lost, "The largest patch is gone")
	check("zap" in main.sound_log and "voice:zapped" in main.sound_log and "surge_fire" in main.sound_log, "Zap, announcer and beam are heard")
	check(main.sound_log.count("surge_warn") == 1 and main.sound_log.count("surge_fire") == 1, "One warning and one blast per surge")
	await create_timer(1.5).timeout
	check(float(own.stun) == 0.0, "The stun wears off")
	# Close a loop: a ring of the local colour with one gap, and the runner steps into the gap.
	# The bots stand still for this and for the shoves, so the staging is exact.
	for i in range(1, 6):
		model.players[i].bot = false
		for action in ["left", "right", "up", "down"]:
			model.command(i, action, false)
	model.elapsed = 10.0
	main.sound_log.clear()
	var grid: RefCounted = model.grid
	var gap := -1
	for i in grid.count():
		var cell: Vector2i = grid.cells[i]
		var reach: int = maxi(maxi(absi(cell.x), absi(cell.y)), absi(-cell.x - cell.y))
		if reach <= 2:
			model.owners[i] = 1 if reach == 2 else 0
			model.locks[i] = 0.0
			if cell == Vector2i(2, 0): gap = i
	model.owners[gap] = 0
	for i in range(1, 6):
		var parked: Vector2 = grid.centers[grid.index[Vector2i(-6, i)]]
		model.players[i].x = parked.x
		model.players[i].z = parked.y
	var outside: Vector2 = grid.centers[grid.index[Vector2i(5, 0)]]
	own.x = outside.x
	own.z = outside.y
	await frames_until(func(): return main.play.last_tiles == int(own.tiles) and int(own.tiles) >= 11)
	own.x = grid.centers[gap].x
	own.z = grid.centers[gap].y
	var looped: bool = await frames_until(func(): return main.hud_feedback.message.begins_with("LOOP"))
	check(looped, "Stepping into the gap closes the loop")
	await snap("livewire-loop", 0.12)
	check(main.hud_feedback.message == "LOOP!  +8 LOCKED", "The call-out counts the capture (%s)" % main.hud_feedback.message)
	check("loop_lock" in main.sound_log and "voice:locked" in main.sound_log, "The lock-in is heard")
	# Shoves, given and taken, through the model's own collision.
	main.sound_log.clear()
	var rival: Dictionary = model.players[1]
	rival.x = float(own.x) + 0.7
	rival.z = own.z
	own.cool = 0.0
	# Facing away, and both keys land in the same frame: the dash must still go right.
	own.face = -PI / 2.0
	key(KEY_D, true)
	key(KEY_SPACE, true)
	key(KEY_SPACE, false)
	var landed: bool = await frames_until(func(): return main.hud_feedback.message == "DIRECT HIT!")
	key(KEY_D, false)
	check(landed and int(own.shoves) > 0, "Dashing into a rival is a direct hit")
	check("shove" in main.sound_log, "A shove is heard")
	await create_timer(0.8).timeout
	own.shove = 0.35
	own._kx = -1.0
	own._kz = 0.0
	var knocked: bool = await frames_until(func(): return main.hud_feedback.message == "SHOVED!")
	check(knocked, "Being shoved is called out")
	await create_timer(0.8).timeout
	for i in range(1, 6):
		model.players[i].bot = true
	# Overdrive: three lines at once, locks cleared.
	main.sound_log.clear()
	model.elapsed = 69.9
	var over: bool = await frames_until(func(): return model.stage() == 2 and main.hud_feedback.message.begins_with("OVERDRIVE"))
	check(over, "Overdrive is announced")
	here = own_cell()
	for n in 3:
		add_surge(910 + n, n, model.grid.line_of(here, n) + (3 if model.grid.line_of(here, n) < 0 else -3), 1.6 - n * 0.2)
	await snap("livewire-overdrive", 0.5)
	check("voice:overdrive" in main.sound_log, "The announcer calls overdrive")
	check(main.sound_log.count("surge_warn") == 1, "Three lines charging together make one sound, not three")
	check(main.play.cue.word == "SURGE ×3", "The call-out counts the lines (%s)" % main.play.cue.word)
	var fired: bool = await frames_until(func(): return model.surges.is_empty())
	check(fired and main.sound_log.count("surge_fire") <= 2, "Staggered blasts are rate-limited (%d)" % main.sound_log.count("surge_fire"))
	# The last ten seconds and the buzzer.
	model.elapsed = 79.95
	var ten: bool = await frames_until(func(): return "voice:ten_seconds" in main.sound_log)
	check(ten, "Ten seconds left is called")
	await snap("livewire-final", 0.3)
	check(main.play.status.urgent, "The clock turns urgent")
	key(KEY_W, true)
	await frames(3)
	check(own._u, "Still playing in the final seconds")
	model.elapsed = 89.7
	var ended: bool = await frames_until(func(): return model.phase == "finished")
	check(ended and model.elapsed == 90.0, "The round ends at 90 seconds")
	await snap("livewire-timeup", 0.2)
	check(main.view == "game" and main.hud_count.message == "TIME’S UP!", "The buzzer holds on the board")
	check("voice:time_up" in main.sound_log and main.sound_log.count("voice:ten_seconds") == 1, "Time's up is called, ten seconds only once")
	main.set_motion_speed(12.0)
	var shown: bool = await frames_until(func(): return main.view == "results", 900)
	check(shown, "The results follow the buzzer on their own")
	check(main.play.sent.is_empty(), "Nothing is held into the results")
	key(KEY_W, false)
	check(on_stage() == "livewire" and main.live_arena.menu_mode, "The finished floor stays behind the results")
	await capture("livewire-results")
	# --- switching games between rounds, in the same party
	main.session.lobby()
	check(main.view == "lobby" and main.model == null, "Back in the lobby")
	await press("Pick_twisted")
	main.session.start_round()
	check(main.view == "game" and main.play == main.games["twisted"] and main.model.has_method("next_obstacle"), "The next round is Spin Cycle")
	check(on_stage() == "twisted", "Played on the spiral")
	main.model.countdown = 0.0
	main.model.phase = "running"
	key(KEY_SPACE, true)
	await frames(2)
	key(KEY_SPACE, false)
	check(main.model.players[0].jump >= 0.0, "Space is jump again in Spin Cycle")
	main.session.lobby()
	await press("Pick_livewire")
	check(main.preferred_game == "livewire" and on_stage() == "livewire", "The last pick is the one that is remembered")
	main.session.start_round()
	check(main.play == live and on_stage() == "livewire", "And Live Wire again")
	main._leave()
	check(main.view == "menu" and main.model == null and main.session.game == "livewire" and on_stage() == "livewire", "Leaving a party returns to the menu of the remembered game")
	# --- solo: the winner's celebration, replay, pause, and a failed connection
	main.session.solo("PLAYER ONE")
	main.session.start_round()
	model = main.model
	model.countdown = 0.0
	model.phase = "running"
	fast_forward(30.0)
	# The local runner sweeps the right-hand side of the floor just before the buzzer.
	for i in model.grid.count():
		if model.grid.centers[i].x > 1.0: model.owners[i] = 1
	model.elapsed = 89.9
	shown = await frames_until(func(): return main.view == "results", 900)
	check(shown and model.winners() == [0], "A solo round ends on the results by itself")
	check(is_instance_valid(main.live_arena.victory), "The solo winner gets the celebration")
	await capture("livewire-results-solo")
	main.session.start_round()
	await frames(3)
	check(main.view == "game" and not is_instance_valid(main.live_arena.victory), "Replay clears the celebration")
	main._toggle_pause()
	check(main.paused, "Solo pause")
	var frozen: float = main.model.countdown
	await capture("livewire-paused")
	check(main.model.countdown == frozen, "A paused solo round is frozen")
	main._toggle_pause()
	main.session._fail("Connection test: the party is gone.")
	check(main.view == "menu" and main.model == null and on_stage() == "livewire", "A failed connection lands on the menu with the right arena")
	check(main.menu_status.text.begins_with("Connection test"), "And says why")
	main.preferred_game = "twisted"
	main.session.select_game("twisted")
	main._show_menu()
	check(on_stage() == "twisted", "Spin Cycle is back on stage")
	for code in LIVE_KEYS:
		key(code, false)
	await frames(2)
