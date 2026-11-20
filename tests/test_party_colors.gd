extends SceneTree
## Six independently polled SceneMultiplayer branches connected over loopback ENet.

const Network = preload("res://scripts/session.gd")
const Palette = preload("res://scripts/palette.gd")
const Wire = preload("res://scripts/party_wire.gd")

var sessions: Array[Node] = []
var launches: Dictionary = {}
var rejections: Dictionary = {}
var server: Node
var port := 0
var failed := false

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--port="):
			port = int(argument.get_slice("=", 1))
	call_deferred("run")

func make_session(index: int) -> Node:
	var branch := Node.new()
	branch.name = "Peer%d" % index
	root.add_child(branch)
	set_multiplayer(SceneMultiplayer.new(), branch.get_path())
	var session := Network.new()
	session.name = "Session"
	branch.add_child(session)
	session.failed.connect(func(message): check(false, "Peer %d failed: %s" % [index, message]))
	session.round_started.connect(func(_seed, seats, round_number): launches[Vector2i(index, round_number)] = seats)
	session.color_pick_rejected.connect(func(_message): rejections[index] = int(rejections.get(index, 0)) + 1)
	sessions.append(session)
	return session

func check(condition: bool, message: String) -> void:
	if condition:
		return
	failed = true
	push_error(message)
	quit(1)

func wait_for(condition: Callable, message: String) -> bool:
	var deadline := Time.get_ticks_msec() + 4000
	while not failed:
		if condition.call():
			return not failed
		if Time.get_ticks_msec() >= deadline:
			check(false, message)
			break
		await process_frame
	return false

func send_unchecked_pick(client: Node, slot: int, color: int) -> void:
	var pick := Wire.encode(Wire.PICK_COLOR, {"slot": slot, "color": color})
	client.multiplayer.send_bytes(pick, 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE, 0)

func coherent_rosters(member_count: int) -> bool:
	for session in sessions:
		if session.mode != "offline" and session.members.size() != member_count:
			return false
	return true

func coherent_colors() -> bool:
	for session in sessions:
		if session.mode != "offline" and session.color_owners() != server.color_owners():
			return false
	return true

func verify_seats(seats: Array, humans: int, claims: Dictionary, expected_bots: Array = []) -> void:
	check(seats.size() == Network.MAX_PLAYERS, "The launch keeps six stable slots")
	var used := {}
	var human_count := 0
	var active_bots := []
	for slot in seats.size():
		var seat: Dictionary = seats[slot]
		var color := int(seat.get("color", -1))
		check(color >= 0 and color < 8 and not used.has(color), "Seat %d has an invalid or duplicate color %d" % [slot, color])
		used[color] = true
		var active: bool = seat.get("active", true)
		if active and seat.bot:
			active_bots.append(slot)
		elif active:
			human_count += 1
		else:
			check(seat.bot, "Vacant seat %d identifies itself as a placeholder" % slot)
		if slot in claims.values():
			check(active and not seat.bot and claims.get(color, -1) == slot, "Round seat %d lost its color claim" % slot)
	check(human_count == humans, "Expected %d humans, got %d" % [humans, human_count])
	check(active_bots == expected_bots, "Expected active bots in seats %s, got %s" % [expected_bots, active_bots])

func verify_launch(round_number: int, humans: int, bots: Array = []) -> bool:
	var host_launch: Array = launches.get(Vector2i(0, round_number), [])
	for index in sessions.size():
		if sessions[index].mode != "offline" and not launches.has(Vector2i(index, round_number)):
			return false
	for index in sessions.size():
		if sessions[index].mode != "offline":
			check(launches[Vector2i(index, round_number)] == host_launch, "Peer %d got a different lineup" % index)
	verify_seats(host_launch, humans, server.color_owners(), bots)
	return true

func verify_legacy_colors(seats: Array) -> void:
	Palette.set_round(seats)
	check(Palette.id_for_seat(0) == 7, "The render palette honors a chosen color")
	var legacy_seats := seats.duplicate(true)
	for seat in legacy_seats:
		seat.erase("color")
	Palette.set_round(legacy_seats)
	for slot in legacy_seats.size():
		check(Palette.id_for_seat(slot) == slot, "A launch from an older host uses the default color for seat %d" % slot)

func run() -> void:
	server = make_session(0)
	if server.host_game("HOST", port) != OK:
		check(false, "Could not host on UDP port %d" % port)
		return
	check(server.pick_color(0, 7), "First player can select the eighth color")
	check(not server.pick_color(0, 8), "An out-of-range palette index is rejected")
	verify_seats(server.slots(), 1, {7: 0})
	verify_legacy_colors(server.slots())
	for index in range(1, Network.MAX_PLAYERS):
		var guest := make_session(index)
		if guest.join_game("GUEST %d" % index, "127.0.0.1", port) != OK:
			check(false, "Could not connect guest %d" % index)
			return
		if not await wait_for(func(): return coherent_rosters(index + 1) and guest.color_picking_supported(), "Guest %d never saw a color-enabled lobby" % index):
			return
		check(guest.my_slot() == index, "Sequential guests retain their original seat IDs")
		verify_seats(server.slots(), index + 1, {7: 0})

	var first := sessions[1]
	var second := sessions[2]
	check(not first.pick_color(0, 5), "A guest cannot change the host's color")
	# Bypass the client-side guard and exercise authority on the receiving peer.
	send_unchecked_pick(first, 0, 5)
	if not await wait_for(func(): return rejections.get(1, 0) == 1, "The host did not reject a forged claim for its seat"):
		return
	check(server.color_owners() == {7: 0}, "A forged claim changed the host's color")
	check(first.pick_color(1, 0), "The host's original slot color is available to a guest")
	check(second.pick_color(2, 0), "Two guests can request the same available color before the host replies")
	if not await wait_for(func(): return server.color_owners().has(0) and coherent_colors(), "Peers never agreed on the winning color claim"):
		return
	var winner: int = server.color_owners()[0]
	check(winner in [1, 2], "Only a requesting guest may win the contested color")
	var loser := 2 if winner == 1 else 1
	# A rejection may arrive before or after the roster updates.
	var expected_rejections := 2 if loser == 1 else 1
	if not await wait_for(func(): return rejections.get(loser, 0) == expected_rejections, "The losing guest did not receive rejection of its contested claim"):
		return
	check(sessions[loser].pick_color(loser, 6), "The other guest can select the seventh color")
	for slot in range(3, Network.MAX_PLAYERS):
		check(sessions[slot].pick_color(slot, slot - 2), "Guest %d can claim an unused color" % slot)
	if not await wait_for(func(): return server.color_owners().size() == Network.MAX_PLAYERS and coherent_colors(), "All six unique claims did not replicate"):
		return

	server.start_round()
	if not await wait_for(func(): return verify_launch(1, 6), "All six peers did not receive round one"):
		return
	check(not server.pick_color(0, 4) and not first.pick_color(1, 4), "The launch locks color changes until the lobby")
	var before_mid_round_request := int(rejections.get(1, 0))
	send_unchecked_pick(first, 1, 4)
	if not await wait_for(func(): return rejections.get(1, 0) == before_mid_round_request + 1, "The host accepted a forged change during the round"):
		return
	check(not server.color_owners().has(4), "A forged mid-round request changed a claim")
	server.lobby()
	if not await wait_for(func(): return sessions.all(func(peer): return not peer.playing), "The six peers did not return to the lobby"):
		return
	var departing_color := 3
	sessions[5].close()
	if not await wait_for(func(): return coherent_rosters(5) and not server.color_owners().has(departing_color) and coherent_colors(), "The departing guest's color was not released"):
		return
	check(first.pick_color(1, departing_color), "A remaining guest can claim the released color")
	if not await wait_for(func(): return server.color_owners().get(departing_color) == 1 and coherent_colors(), "The released color could not be reclaimed"):
		return
	server.start_round()
	if not await wait_for(func(): return verify_launch(2, 5), "All remaining peers did not receive the rematch"):
		return
	if not await verify_remote_bots(first):
		return
	if not await verify_smaller_lineups(first):
		return
	for index in range(sessions.size() - 1, -1, -1):
		sessions[index].close()
	if not failed:
		print("PARTY_COLORS_PASS")
		quit(0)

func lobby_has_bot(slot: int, enabled: bool) -> bool:
	for session in sessions:
		if session.mode != "offline" and session.bot_at(slot) != enabled:
			return false
	return true

func verify_remote_bots(leader: Node) -> bool:
	server.lobby()
	if not await wait_for(func(): return sessions.all(func(peer): return not peer.playing), "The sparse rematch did not return to the lobby"):
		return false
	var leader_id: int = leader.multiplayer.get_unique_id()
	server.propose_host(leader_id)
	if not await wait_for(func(): return leader.is_leader() and not server.is_leader(), "The remote guest did not receive host controls"):
		return false
	check(leader.can_set_bot(5) and not leader.can_set_bot(0), "Only vacant seats are configurable")
	check(not server.can_set_bot(5), "The server cannot configure bots after transferring leadership")
	leader.set_bot(5, true)
	if not await wait_for(func(): return lobby_has_bot(5, true), "A bot selected by the remote leader did not replicate"):
		return false
	leader.start_round()
	if not await wait_for(func(): return verify_launch(3, 5, [5]), "All remaining peers did not receive the bot rematch"):
		return false
	check(not leader.can_set_bot(5), "Bots cannot be changed after launch")

	leader.lobby()
	if not await wait_for(func(): return sessions.all(func(peer): return not peer.playing), "The bot rematch did not return to the lobby"):
		return false
	sessions[4].close()
	if not await wait_for(func(): return coherent_rosters(4), "The second departing guest never freed their seat"):
		return false
	leader.set_bot(4, true)
	leader.set_bot(5, false)
	if not await wait_for(func(): return lobby_has_bot(4, true) and lobby_has_bot(5, false), "The remote leader could not move the reserved bot"):
		return false

	var returning := sessions[5]
	check(returning.join_game("GUEST 5", "127.0.0.1", port) == OK, "The fifth guest could not reconnect")
	if not await wait_for(func(): return coherent_rosters(5) and returning.color_picking_supported(), "The fifth guest did not reconnect"):
		return false
	check(returning.my_slot() == 5 and server.bot_at(4), "The new human fills the available vacancy before replacing a bot")

	returning = sessions[4]
	check(returning.join_game("GUEST 4", "127.0.0.1", port) == OK, "The sixth guest could not reconnect")
	if not await wait_for(func(): return coherent_rosters(6) and returning.color_picking_supported(), "The sixth guest did not reconnect"):
		return false
	check(returning.my_slot() == 4 and not server.bot_at(4), "The last human can replace a reserved bot")
	return not failed

func verify_smaller_lineups(leader: Node) -> bool:
	for index in range(3, sessions.size()):
		sessions[index].close()
	if not await wait_for(func(): return coherent_rosters(3) and lobby_has_bot(4, false), "Three humans did not reach the lobby with no reserved bots"):
		return false
	leader.start_round()
	if not await wait_for(func(): return verify_launch(4, 3), "Three humans did not receive the no-bot lineup"):
		return false

	leader.lobby()
	if not await wait_for(func(): return sessions.all(func(peer): return not peer.playing), "The three-human round did not return to the lobby"):
		return false
	sessions[2].close()
	if not await wait_for(func(): return coherent_rosters(2), "Two humans did not reach the lobby"):
		return false
	leader.set_bot(2, true)
	leader.set_bot(5, true)
	if not await wait_for(func(): return lobby_has_bot(2, true) and lobby_has_bot(5, true), "The two selected bots did not replicate"):
		return false
	leader.start_round()
	return await wait_for(func(): return verify_launch(5, 2, [2, 5]), "Two humans did not receive their two selected bots")
