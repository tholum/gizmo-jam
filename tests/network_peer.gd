extends SceneTree
## Runs as six real OS processes; tests use the production Session RPCs and the
## production models, driven the way main.gd drives them: the server steps the
## model and sends its snapshots, clients begin() the same model and only ever
## apply_snapshot() to it.
##
## The script every peer follows, and what is checked along the way:
##   lobby    The server (first leader) picks Live Wire once three seats are
##            filled. Seated clients see it change; later clients must get it
##            with their very first roster. Every client then tries to pick
##            Spin Cycle (refused locally; a forged request is refused by
##            the server) and reports the game it sees.
##   round 1  Live Wire on the real model, launched only after all five reports
##            agree. Forged Spin Cycle inputs are dropped. Every peer holds its own
##            direction from the countdown on (the dash-only peer holds none),
##            lets go when it sees 0.6 s of play, and two peers then dash. The
##            server checks that each seat moved the way its own peer steered
##            and no other way, that the seat nobody steered stood still, that
##            only the two dashers dashed, and that every seat's input log is
##            exactly its own peer's. Each client checks the same about its own
##            seat in the model it rebuilt from snapshots. Client 1 wins a host
##            vote, fails to change the game mid-round, and returns everyone to
##            the lobby.
##   lobby    The new leader picks Spin Cycle; everyone follows.
##   round 2  Spin Cycle on the real round model. Forged Live Wire inputs
##            are dropped; six ducks reach the snapshot.
##   lobby    The leader picks Live Wire again.
##   round 3  Live Wire. Client 5 disconnects as soon as play starts. Its seat
##            must become a bot on the server and in every remaining client's
##            snapshots (flag and name), and the bot must start moving it.
## Role "stale" joins with an old protocol number and must be turned away with
## the version message.
const Network = preload("res://scripts/session.gd")
const Model = preload("res://scripts/round_model.gd")
const LiveModel = preload("res://scripts/livewire_model.gd")
const LIVE := ["left", "right", "up", "down", "dash"]
const TWIST := ["jump", "duck"]
const HEADING := {"left": Vector2(-1, 0), "right": Vector2(1, 0), "up": Vector2(0, -1), "down": Vector2(0, 1)}
## Game the party must have agreed on in the lobby before round N + 1.
const LOBBY_GAME := ["livewire", "twisted", "livewire"]
## Live Wire rounds in this test count down from here instead of three seconds.
const SHORT_COUNTDOWN := 0.8
## Seconds of play after which every peer lets go of its direction.
const HOLD := 0.6
## The client that leaves in the middle of round 3.
const QUITTER := 5


## Test-only messages. They travel on the same reliable channel as the Session
## RPCs, so a report sent after a request also arrives after it: that is what
## lets the server say "this request was ignored", not "not yet".
class Probe extends Node:
	signal reported(peer: int, tag: String, value: String)
	signal noticed(tag: String)

	## Client to server.
	@rpc("any_peer", "call_remote", "reliable")
	func report(tag: String, value: String) -> void:
		reported.emit(multiplayer.get_remote_sender_id(), tag, value)

	## Server to clients.
	@rpc("authority", "call_remote", "reliable")
	func notice(tag: String) -> void:
		noticed.emit(tag)


var session: Node
var probe: Probe
var model: RefCounted
var role := "host"
var index := 0
var server_port := 17777
var clock := 0.0
var state_clock := 0.0
var got_snapshot := false
var lobby_count := 0
var finishing := false
var initial_leader := 1
var transferred := false
## Server: inputs accepted this round, seat -> [[action, pressed], ...].
var accepted: Dictionary = {}
## Server: tag -> {peer id: value} from Probe.
var reports: Dictionary = {}
## Server: peers already seated when Live Wire was picked.
var early: Array = []
var picked := false
## Client: game carried by the first roster it ever received.
var first_game := ""
## Client: lobbies (by round_number) in which it saw the agreed game.
var agreed: Dictionary = {}
## Notices received from the server.
var notices: Dictionary = {}
## Where every seat stood when the current Live Wire round was launched.
var start: Array = []
## Round 1: this peer has let go of its direction (and dashed, if it does).
var let_go := false
## Round 1, server: the two whole-board checks.
var steering_checked := false
var settled_at := -1.0
var live_verified := false
## Round 1 / 2, leader: the return to the lobby has been requested.
var returns_sent := 0
var ducks_seen := false
## Round 3: the seat that turned into a bot, and where it stood at that moment.
var bot_seat := -1
var bot_from := Vector2.ZERO
var bot_verified := false

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--role="): role = arg.get_slice("=", 1)
		if arg.begins_with("--index="): index = int(arg.get_slice("=", 1))
		if arg.begins_with("--port="): server_port = int(arg.get_slice("=", 1))
	call_deferred("run")

func run() -> void:
	var main := Node.new()
	main.name = "Main"
	root.add_child(main)
	session = Network.new()
	session.name = "Session"
	main.add_child(session)
	probe = Probe.new()
	probe.name = "Probe"
	main.add_child(probe)
	if role == "stale":
		run_stale()
		return
	probe.reported.connect(reported)
	probe.noticed.connect(func(tag): notices[tag] = true)
	session.failed.connect(func(message): fail(message))
	session.roster_changed.connect(roster)
	session.round_started.connect(launched)
	session.snapshot_received.connect(snapshot)
	session.input_received.connect(input)
	session.seat_disconnected.connect(seat_left)
	session.returned_to_lobby.connect(returned)
	var error: Error
	if role == "host": error = session.host_game("SERVER", server_port)
	else: error = session.join_game("CLIENT%d" % index, "127.0.0.1", server_port)
	if error != OK: fail("Could not create peer: %s" % error)

## An older build: same handshake, previous protocol number.
func run_stale() -> void:
	session.multiplayer.connected_to_server.disconnect(session._connected)
	session.multiplayer.connected_to_server.connect(func():
		session._register.rpc_id(1, "OLD BUILD", Network.PROTOCOL - 1))
	session.roster_changed.connect(func(): fail("A mismatched build was let into the lobby"))
	session.failed.connect(func(message):
		if message == "Game versions do not match.":
			print("STALE_CLIENT_PASS old-protocol-rejected-with-version-message")
			quit(0)
		else:
			fail("Wrong rejection: " + message))
	var error: Error = session.join_game("OLD BUILD", "127.0.0.1", server_port)
	if error != OK: fail("Could not create peer: %s" % error)

## The direction peer `who` (0 = server, 1-5 = clients) holds in round 1, or ""
## for the peer that only dashes. Every seat gets a different job, so a mix-up
## between seats cannot go unnoticed.
static func steer(who: int) -> String:
	var action: String = LIVE[who % LIVE.size()]
	return "" if action == "dash" else action

static func dashes(who: int) -> bool:
	return who == 4 or who == 5

## Everything peer `who` sends in round `number`, in order: the server's log
## for that peer's seat must end up as exactly this.
static func expected(who: int, number: int) -> Array:
	if number == 2:
		return [["duck", true]]
	if number != 1:
		return []
	var plan: Array = []
	if not steer(who).is_empty():
		plan.append([steer(who), true])
		plan.append([steer(who), false])
	if dashes(who):
		plan.append(["dash", true])
	return plan

static func other_game(id: String) -> String:
	return "twisted" if id == "livewire" else "livewire"

## Which peer (0 = server, 1-5 = clients) sits in a roster entry.
static func who_is(member: Dictionary) -> int:
	return 0 if int(member.peer) == 1 else int(str(member.name).trim_prefix("CLIENT"))

func at(slot: int) -> Vector2:
	return Vector2(model.players[slot].x, model.players[slot].z)

func roster() -> void:
	if session.leader_id != initial_leader:
		transferred = true
	if role == "host":
		if not picked and session.round_number == 0 and session.members.size() == 3:
			picked = true
			early = session.members.map(func(m): return int(m.peer))
			expect(not session.select_game("chess") and session.game == "twisted", "Unknown games must be refused")
			expect(session.select_game("livewire") and session.game == "livewire", "The leader must be able to pick Live Wire")
		return
	if first_game.is_empty():
		first_game = session.game
	if not session.election.is_empty():
		var own: int = session.multiplayer.get_unique_id()
		if own != session.leader_id and own not in session.election.yes and own not in session.election.no:
			session.cast_vote(true)
	var lobby_number: int = session.round_number
	if session.playing or session.members.size() != 6 or lobby_number >= LOBBY_GAME.size():
		return
	if session.game != LOBBY_GAME[lobby_number] or agreed.has(lobby_number):
		return
	agreed[lobby_number] = true
	if not session.is_leader():
		var wrong := other_game(session.game)
		expect(not session.select_game(wrong) and session.game != wrong, "Only the leader may pick the game")
		# Forged past the local check; the server must look at who is asking.
		session._request_game.rpc_id(1, wrong)
	probe.report.rpc_id(1, "lobby%d" % lobby_number, "%s/%s" % [session.game, first_game])
	if session.is_leader() and lobby_number >= 1:
		session.start_round()

## Server: a client says which game it sees in the lobby (and saw first).
func reported(peer: int, tag: String, value: String) -> void:
	if role != "host": return
	if not reports.has(tag): reports[tag] = {}
	reports[tag][peer] = value
	if tag != "lobby0" or reports[tag].size() != 5 or session.round_number != 0:
		return
	# Each report was sent after that client's forged request for Spin Cycle.
	expect(session.game == "livewire", "A non-leader changed the game")
	expect(session.members.size() == 6, "Six seats must be filled before the first round")
	for id in reports[tag]:
		var seen: PackedStringArray = str(reports[tag][id]).split("/")
		expect(seen[0] == "livewire", "Peer %d disagrees about the game: %s" % [id, seen[0]])
		if id in early:
			expect(seen[1] == "twisted", "Peer %d was seated before the pick and should have seen it change" % id)
		else:
			expect(seen[1] == "livewire", "Peer %d joined after the pick; its first roster must carry the game" % id)
	print("SIX_PLAYERS_AGREE livewire (%d seated before the pick, %d after)" % [early.size() - 1, 6 - early.size()])
	session.start_round()

func launched(seed_value: int, seats: Array, number: int) -> void:
	if seats.size() != 6 or seats.any(func(p): return p.bot):
		fail("All six humans must launch in the same round")
	var game: String = LOBBY_GAME[number - 1]
	expect(session.game == game, "Launch %d must deliver %s, got %s" % [number, game, session.game])
	if role != "host":
		expect(agreed.has(number - 1), "The lobby roster must deliver the game before the launch")
	expect(not session.select_game(other_game(game)) and session.game == game, "The game cannot change during a round")
	accepted.clear()
	got_snapshot = false
	if game == "twisted":
		model = Model.new()
		model.begin(seed_value, seats, number)
		# Countdown input is normally disabled; the server test bypasses it.
		model.countdown = 0.0
		model.phase = "running"
	else:
		# Every peer builds the same model from the launch; only the server runs it.
		model = LiveModel.new()
		model.begin(seed_value, seats, number)
		if role == "host":
			model.countdown = SHORT_COUNTDOWN
		start = []
		for i in 6:
			start.append(at(i))
			expect(int(model.players[i].tiles) == 1 and not model.players[i].bot, "Seat %d starts as a human on one tile" % i)
	# The other game's actions go first: send_input drops them locally and the
	# server drops forged ones, so nothing of them may reach the server's log.
	for action in (TWIST if game == "livewire" else LIVE):
		session.send_input(action, true)
		if role != "host": session._receive_input.rpc_id(1, action, true)
	if number == 1:
		# Held from the countdown on: the model remembers it and moves at GO.
		if not steer(index).is_empty():
			session.send_input(steer(index), true)
		if role != "host" and index == 1:
			session.propose_host(session.multiplayer.get_unique_id())
	elif number == 2:
		session.send_input("duck", true)

## Server: an input the session accepted, already attributed to a seat.
func input(slot: int, action: String, pressed: bool) -> void:
	if role != "host":
		fail("Clients must never be handed inputs")
	if action not in (LIVE if session.game == "livewire" else TWIST):
		fail("Seat %d: '%s' was accepted during %s" % [slot, action, session.game])
	if not accepted.has(slot): accepted[slot] = []
	accepted[slot].append([action, pressed])
	if model: model.command(slot, action, pressed)

## Server: what main.gd does when a seated peer drops out of a round.
func seat_left(slot: int) -> void:
	if role != "host" or model == null or not session.playing:
		return
	model.take_over(slot)
	if session.round_number == 3 and bot_seat < 0:
		bot_seat = slot
		bot_from = at(slot)

## Server: true once every seat holds exactly its own peer's inputs. Anything
## extra, missing from the front, or filed under another seat fails at once.
func seats_settled() -> bool:
	var settled := true
	for m in session.members:
		var want: Array = expected(who_is(m), session.round_number)
		var got: Array = accepted.get(int(m.slot), [])
		if got.size() > want.size() or got != want.slice(0, got.size()):
			fail("Seat %d (%s) holds %s but its peer sends %s" % [m.slot, m.name, got, want])
		if got.size() < want.size():
			settled = false
	return settled

## Round 1, every peer, from its own copy of the model: let go after HOLD
## seconds of play, having checked that its own seat went where it steered.
func play_live_round() -> void:
	if let_go or model.phase != "running" or model.elapsed < HOLD:
		return
	let_go = true
	var slot: int = session.my_slot()
	var moved: Vector2 = at(slot) - start[slot]
	var heading := steer(index)
	if heading.is_empty():
		expect(moved.length() < 0.05, "Nobody steered seat %d, yet it moved %s" % [slot, moved])
		expect(int(model.players[slot].tiles) == 1, "A seat that stood still owns only its starting tile")
	else:
		var along: float = moved.dot(HEADING[heading])
		var across: float = absf(moved.dot(Vector2(HEADING[heading]).orthogonal()))
		expect(along > 1.5 and across < 0.3, "Seat %d should have run %s, moved %s" % [slot, heading, moved])
		expect(int(model.players[slot].tiles) >= 2, "Running paints tiles")
		session.send_input(heading, false)
	if dashes(index):
		session.send_input("dash", true)
	# The state contract must have survived the trip, not just one position.
	var owned := 0
	for owner in model.owners:
		if owner == slot + 1: owned += 1
	expect(owned == int(model.players[slot].tiles), "The owners grid and the tile count disagree (%d vs %d)" % [owned, model.players[slot].tiles])
	for m in session.members:
		var p: Dictionary = model.players[int(m.slot)]
		expect(str(p.name) == str(m.name) and not p.bot, "Seat %d should be %s, a human" % [m.slot, m.name])

## Round 1, server: the whole board, twice.
func referee_live_round() -> void:
	if model.phase != "running":
		return
	if not steering_checked and model.elapsed >= 0.45:
		# Before anybody has let go: each seat went its own peer's way.
		steering_checked = true
		for m in session.members:
			var slot := int(m.slot)
			var moved: Vector2 = at(slot) - start[slot]
			var heading := steer(who_is(m))
			var p: Dictionary = model.players[slot]
			expect(float(p.cool) == 0.0 and float(p.dash) == 0.0, "Seat %d dashed before anybody asked" % slot)
			if heading.is_empty():
				expect(moved.length() < 0.05, "Seat %d (%s) holds nothing, yet it moved %s" % [slot, m.name, moved])
			else:
				var along: float = moved.dot(HEADING[heading])
				var across: float = absf(moved.dot(Vector2(HEADING[heading]).orthogonal()))
				expect(along > 1.2 and across < 0.3, "Seat %d (%s) should have run %s, moved %s" % [slot, m.name, heading, moved])
	if not seats_settled():
		return
	if settled_at < 0.0:
		settled_at = model.elapsed
	if live_verified or model.elapsed < settled_at + 0.3:
		return
	# Every release and both dashes have landed, each on its own seat.
	live_verified = true
	for m in session.members:
		var p: Dictionary = model.players[int(m.slot)]
		expect(dashes(who_is(m)) == (float(p.cool) > 0.0), "Seat %d (%s): dash cooldown is %s" % [m.slot, m.name, p.cool])
		expect(not (p._l or p._r or p._u or p._d), "Seat %d (%s) is still holding a direction" % [m.slot, m.name])
	print("LIVE_ROUND_VERIFIED six-seats-steered-by-their-own-peers dash-on-two-seats-only inputs-exact")
	probe.notice.rpc("live_ok")
	notices["live_ok"] = true

## Round 3: the seat of the peer that left is a bot, and the bot plays it.
func watch_bot() -> void:
	if bot_verified:
		return
	if bot_seat < 0:
		# Clients learn about it from the snapshot alone.
		for i in 6:
			if model.players[i].bot:
				bot_seat = i
				bot_from = at(i)
		return
	var p: Dictionary = model.players[bot_seat]
	expect(p.bot and str(p.name).ends_with(LiveModel.BOT_SUFFIX), "Seat %d should be labelled as a bot, is '%s'" % [bot_seat, p.name])
	expect(str(p.name).begins_with("CLIENT%d" % QUITTER), "The wrong seat was handed to a bot: %s" % p.name)
	for i in 6:
		if i != bot_seat:
			expect(not model.players[i].bot, "Seat %d was turned into a bot too" % i)
	if model.phase == "running" and at(bot_seat).distance_to(bot_from) > 1.0:
		bot_verified = true

func snapshot(data: Dictionary) -> void:
	if int(data.id) != session.round_number:
		fail("Snapshot from the wrong round")
	got_snapshot = true
	if session.game == "livewire":
		expect(str(data.get("game", "")) == "livewire", "Live Wire rounds must carry Live Wire snapshots")
		model.apply_snapshot(data)
		return
	if data.players.size() != 6:
		fail("Snapshot with the wrong roster")
	if data.players.all(func(p): return p.duck):
		ducks_seen = true

func returned() -> void:
	lobby_count += 1
	model = null
	# The round's game is still set: a leader's forged mid-round request for
	# the other one reached the server before this and was refused.
	var played: String = LOBBY_GAME[lobby_count - 1]
	expect(session.game == played, "A game change requested mid-round must be refused")
	if role == "host":
		expect(not session.select_game(other_game(played)), "The server stopped being the leader and cannot pick")
	elif session.is_leader():
		expect(session.select_game(other_game(played)), "The new leader must be able to pick the game")
		expect(session.game == played, "A client leader waits for the server's answer")

## The leader's side of the script: back to the lobby once a round has shown
## what it had to show.
func lead() -> void:
	if role == "host" or not session.is_leader() or not transferred or not session.playing:
		return
	if session.round_number == 1 and returns_sent == 0 and let_go and notices.has("live_ok"):
		returns_sent = 1
		expect(not session.select_game("twisted") and session.game == "livewire", "The new leader cannot change the game mid-round")
		# Forged past the local check, then the lobby request right behind it.
		session._request_game.rpc_id(1, "twisted")
		session.lobby()
	elif session.round_number == 2 and returns_sent == 1 and ducks_seen:
		returns_sent = 2
		session.lobby()

func _process(delta: float) -> bool:
	clock += delta
	if clock > 20.0 and not finishing:
		fail("Timed out: role=%s members=%d round=%d game=%s playing=%s transferred=%s snapshot=%s let_go=%s live=%s ducks=%s bot=%d/%s accepted=%s reports=%s" % [role, session.members.size(), session.round_number, session.game, session.playing, transferred, got_snapshot, let_go, live_verified, ducks_seen, bot_seat, bot_verified, accepted, reports])
	if finishing and role != "host":
		return false
	if session.playing and model != null:
		if role == "host":
			serve(delta)
		if session.game == "livewire" and (role == "host" or got_snapshot):
			if session.round_number == 1:
				play_live_round()
			elif session.round_number == 3:
				leave_or_watch()
		lead()
	if role == "host" and finishing and session.members.size() == 1:
		# Let every client finish and disconnect before closing the server.
		# Closing on the same one-second timer races clients' own exit timers.
		session.close()
		quit(0)
	return false

## Server: run the round the way main.gd does.
func serve(delta: float) -> void:
	if session.game == "livewire":
		model.step(delta)
		if session.round_number == 1:
			referee_live_round()
	elif session.round_number == 2 and seats_settled() and not ducks_seen:
		ducks_seen = true
		var followed: Dictionary = reports.get("lobby1", {})
		expect(transferred and lobby_count == 1 and followed.size() == 5, "Round 2 must follow one lobby under the new leader")
		for id in followed:
			expect(str(followed[id]).begins_with("twisted/"), "Peer %d did not follow the new leader's pick" % id)
	state_clock += delta
	if state_clock > 0.05:
		state_clock = 0.0
		session.send_snapshot(model.snapshot())

## Round 3: one client walks out, everybody else watches its seat.
func leave_or_watch() -> void:
	if finishing or model.phase != "running":
		return
	if role != "host" and index == QUITTER:
		print("CLIENT_%d_PASS game-sync leader-only-pick per-game-inputs own-seat-steering vote relaunch left-mid-round" % index)
		finishing = true
		session.close()
		quit(0)
		return
	watch_bot()
	if not bot_verified:
		return
	finishing = true
	if role == "host":
		expect(live_verified and ducks_seen and lobby_count == 2, "All three rounds must have been refereed")
		expect(session.members.size() == 5 and seats_settled(), "Five peers remain and nobody sent anything in round 3")
		expect(reports.get("lobby2", {}).size() == 5, "Everyone followed the pick back to Live Wire")
		print("SERVER_PASS six-seats game-sync late-join leader-only-pick per-game-inputs own-seat-steering majority-transfer new-leader-pick-and-start disconnect-becomes-bot")
	else:
		print("CLIENT_%d_PASS game-sync leader-only-pick no-pick-mid-round per-game-inputs own-seat-steering vote relaunch disconnect-becomes-bot" % index)
		quit_later()

func quit_later() -> void:
	await create_timer(1.0).timeout
	session.close()
	quit(0)

func expect(condition: bool, message: String) -> void:
	if not condition: fail(message)

func fail(message: String) -> void:
	push_error(message)
	quit(1)
