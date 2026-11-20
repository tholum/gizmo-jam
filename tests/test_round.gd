extends SceneTree

const Model = preload("res://scripts/round_model.gd")
const Network = preload("res://scripts/session.gd")
var failures := 0

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var slots: Array = []
	for i in 6:
		slots.append({"name": "P%d" % i, "peer": i + 1, "bot": false})
	var game := Model.new()
	game.begin(123, slots)
	check(game.players.size() == 6, "Six players must be created")
	game.command(0, "jump", true)
	check(game.players[0].jump < 0, "No movement before countdown")
	game.step(3.1)
	check(game.phase == "running", "Countdown must start the round")
	game.command(0, "jump", true)
	game.players[0].jump = Model.JUMP_DURATION / 2
	check(Model.clears(game.players[0], "jump"), "A well-timed jump clears low rods")
	check(not Model.clears(game.players[0], "duck"), "Jumping cannot clear overhead rods")
	game.players[0].jump = -1.0
	game.command(0, "duck", true)
	check(Model.clears(game.players[0], "duck"), "Ducking clears overhead rods")
	game.command(0, "jump", true)
	check(game.players[0].jump == 0.0, "Jump must override a held duck")
	check(game.players[0].duck, "The held duck request resumes after landing")
	game.players[0].jump = -1.0
	game.command(0, "duck", false)
	check(not game.players[0].duck, "Duck release must clear state")
	game.command(-1, "jump", true)
	game.command(6, "jump", true)
	# Buffer presses near landing, expire early presses, and never jump from
	# duck release alone. The server uses the same path for remote input.
	game.players[0].jump = Model.JUMP_DURATION - 0.06
	game.command(0, "jump", true)
	game.step(0.07)
	check(game.players[0].jump >= 0.0 and game.players[0].jump < 0.02, "A near-landing press must start the next jump")
	game.players[0].jump = 0.10
	game.players[0].jump_buffer = 0.0
	game.command(0, "jump", true)
	game.step(0.6)
	check(game.players[0].jump < 0, "An early airborne press must not become a delayed jump")
	game.players[0].jump = -1.0
	game.command(0, "duck", true)
	game.command(0, "duck", false)
	game.step(0.01)
	check(game.players[0].jump < 0, "Duck release alone must not jump")
	# Perfect play against five idle runners must win, preserve all lives,
	# and score each shared obstacle exactly once.
	game.begin(42, slots)
	game.step(3.1)
	var seen: Dictionary = {}
	for frame in 120 * 60:
		if game.phase == "finished": break
		var wave: Dictionary = game.next_obstacle()
		var eta: float = (float(wave.at) - game.progress) / game.speed
		if not seen.has(wave.id) and eta <= 0.29:
			game.command(0, "duck", false)
			game.command(0, wave.kind, true)
			seen[wave.id] = true
		game.step(1.0 / 60.0)
	check(game.phase == "finished", "A round must finish with one survivor")
	check(game.players[0].hp == 7, "Perfect input must preserve seven lives")
	check(game.players[0].score == 7, "Seven shared waves should produce seven clears")
	check(game.ranking()[0] == 0, "The survivor must rank first")
	check(game.winners() == [0], "Only the survivor wins")
	check(game.players[1].hp == 0, "Seventh miss must eliminate a player")
	check(game.speed > 0.68, "Speed must increase over time")
	var copy := Model.new()
	copy.begin(4, slots)
	copy.apply_snapshot(game.snapshot())
	check(copy.players == game.players and copy.phase == game.phase, "Snapshots must reproduce authoritative results")
	var old_snapshot: Dictionary = game.snapshot()
	old_snapshot.id = -1
	old_snapshot.phase = "running"
	copy.apply_snapshot(old_snapshot)
	check(copy.phase == "finished", "Stale round snapshots must be ignored")
	game.take_over(0)
	check(game.players[0].bot and game.players[0].peer == 0, "Disconnected seats must become bots")
	game.begin(42, slots)
	game.step(3.1)
	for frame in 60 * 60:
		game.step(1.0 / 60.0)
		if game.phase == "finished": break
	check(game.winners().size() == 6, "Simultaneous equal eliminations must be a draw")
	var solo_slots := slots.duplicate(true)
	for i in range(1, solo_slots.size()):
		solo_slots[i]["active"] = false
	game.begin(42, solo_slots)
	game.step(3.1)
	game.step(0.01)
	check(game.phase == "running" and game.ranking() == [0], "A lone runner starts normally and vacant seats are excluded")
	game.elapsed = Model.SOLO_DURATION
	game.step(0.01)
	check(game.phase == "finished" and game.winners() == [0], "A solo player wins by surviving 90 seconds")
	game.begin(42, solo_slots)
	for frame in 60 * 60:
		game.step(1.0 / 60.0)
		if game.phase == "finished": break
	check(game.phase == "finished" and game.ranking() == [0] and game.winners().is_empty(), "A solo player can lose and still appear in the results")
	# A six-person host vote needs three of the other five people, never the
	# absent incumbent. Votes are unique and only members can nominate.
	var session := Network.new()
	session.name = "Session"
	root.add_child(session)
	for i in 6:
		session.members.append({"peer": i + 1, "slot": i, "name": "P%d" % i})
	session._propose(99, 2)
	check(session.election.is_empty(), "Nonmembers cannot start a vote")
	session._propose(2, 2)
	session._vote(2, true)
	session._vote(1, true)
	check(session.election.yes.size() == 1, "Duplicate votes and incumbent votes must be ignored")
	session._vote(3, true)
	check(session.leader_id == 1, "Two votes cannot control a six-person party")
	session._vote(4, true)
	check(session.leader_id == 2 and session.election.is_empty(), "Three votes transfer host controls without incumbent approval")
	session._propose(2, 5)
	check(session.leader_id == 5, "Current leader may hand off voluntarily")
	session.members = [{"peer": 1, "slot": 0, "name": "A"}, {"peer": 2, "slot": 1, "name": "B"}]
	session.leader_id = 1
	session._propose(2, 2)
	check(session.leader_id == 2, "Two-person parties can recover from an AFK leader")
	# The party plays one game at a time. The leader picks it between rounds,
	# the pick outlives close()/solo(), a launch carries it, and each game only
	# takes its own inputs. Session level only; no Live Wire model involved.
	check(Network.PROTOCOL == 2, "The game-aware RPCs need their own protocol number")
	check(Network.GAMES == ["twisted", "livewire"], "Two games are on the menu")
	for id in Network.GAMES:
		check(Network.ACTIONS.has(id) and int(Network.INPUT_BUDGET.get(id, 0)) >= 120, "Every game needs its actions and an input budget: " + id)
	check(Network.ACTIONS.livewire == ["left", "right", "up", "down", "dash"] and Network.ACTIONS.twisted == ["jump", "duck"], "Each game has its own action list")
	var party := Network.new()
	party.name = "Party"
	root.add_child(party)
	var heard: Array = []
	var launches: Array = []
	var redraws: Array = [0]
	party.input_received.connect(func(slot, action, pressed): heard.append([slot, action, pressed]))
	party.round_started.connect(func(_seed, _seats, number): launches.append([number, party.game]))
	party.roster_changed.connect(func(): redraws[0] += 1)
	check(party.game == "twisted", "Spin Cycle is the default game")
	check(not party.select_game("chess") and party.game == "twisted", "Unknown games are refused")
	check(party.select_game("livewire") and party.game == "livewire", "Offline, a menu pick applies at once")
	party.close()
	check(party.game == "livewire", "The menu pick survives close()")
	party.solo("ANA")
	check(party.game == "livewire", "The menu pick survives solo()")
	party.start_round()
	check(launches == [[1, "livewire"]], "The game is set before round_started fires")
	check(not party.select_game("twisted") and party.game == "livewire", "No pick while a round is playing")
	party._choose_game(1, "twisted")
	check(party.game == "livewire", "The server refuses a pick mid-round as well")
	var every_action := ["jump", "duck", "left", "right", "up", "down", "dash", "fly"]
	for action in every_action:
		party.send_input(action, true)
	party.send_input("left", false)
	party.send_input("duck", false)
	check(heard == [[0, "left", true], [0, "right", true], [0, "up", true], [0, "down", true], [0, "dash", true], [0, "left", false]],
		"Live Wire takes directions (press and release) and dash from the right seat, nothing else: %s" % [heard])
	party.lobby()
	check(party.select_game("twisted") and party.game == "twisted", "Back in the menu the pick can change")
	heard.clear()
	party.start_round()
	for action in every_action:
		party.send_input(action, true)
	check(heard == [[0, "jump", true], [0, "duck", true]], "Spin Cycle takes only jump and duck: %s" % [heard])
	check(launches == [[1, "livewire"], [2, "twisted"]], "Each launch carries the game picked for it")
	party.lobby()
	# The server's side of a request: only the current leader's is honoured.
	party.members = []
	for i in 6:
		party.members.append({"peer": i + 1, "slot": i, "name": "P%d" % i})
	party.leader_id = 2
	redraws[0] = 0
	party._choose_game(3, "livewire")
	party._choose_game(1, "livewire")
	party._choose_game(99, "livewire")
	party._choose_game(2, "chess")
	check(party.game == "twisted" and redraws[0] == 0, "Only the leader's pick of a real game counts")
	party._choose_game(2, "livewire")
	check(party.game == "livewire" and redraws[0] == 1, "The leader's pick is applied and announced to the lobby")
	party._propose(2, 4)
	party._choose_game(2, "twisted")
	check(party.game == "livewire", "A former leader can no longer pick")
	party._choose_game(4, "twisted")
	check(party.game == "twisted", "After a hand-over the new leader picks")
	# What the server sends is what a peer plays: a launch and a roster both
	# overwrite the local value, and a garbled id changes nothing.
	party._launch(7, party.slots(), 9, "livewire")
	check(launches[-1] == [9, "livewire"] and party.playing, "A launch delivers its game before round_started")
	party._launch(7, party.slots(), 10, "chess")
	check(party.game == "livewire", "A launch with an unknown game keeps the current one")
	party.playing = false
	party.mode = "joining"
	party._roster(party.members, 2, {}, "", "twisted")
	check(party.mode == "client" and party.game == "twisted", "A joining client adopts the server's game from its first roster")
	party.mode = "offline"
	party.queue_free()
	print("ROUND_AND_VOTE_TESTS %s" % ("PASS" if failures == 0 else "FAIL: %d" % failures))
	session.queue_free()
	quit(0 if failures == 0 else 1)
