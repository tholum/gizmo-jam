extends Node
## One network server, six seats, and a transferable party leader.
##
## The party plays one minigame at a time. `game` is an id from GAMES; the party
## leader picks it with select_game() between rounds, the server is the only
## peer that changes it for a party, and it reaches everyone with the roster
## (so late joiners get it with their first roster) and again with each launch.
## `game` is already set when round_started fires. Inputs are filtered by
## ACTIONS[game] on the sender and again on the server.
##
## Local seats: a machine that plays solo or hosts can seat more players of its
## own, one per extra gamepad (add_local). They are ordinary members with this
## machine's peer id, their own slot and a "pad" key, listed after the
## machine's own member, so a peer's first member is always the person at its
## keyboard. Their input is routed on the server (send_local_input), so the
## wire format does not change and older clients only see more names.

signal roster_changed
signal round_started(seed_value: int, slots: Array, round_number: int)
signal snapshot_received(data: Dictionary)
signal input_received(slot: int, action: String, pressed: bool)
signal seat_disconnected(slot: int)
signal returned_to_lobby
signal failed(message: String)

## Bump whenever an RPC is added or its arguments change. A mixed-build join
## must still end in "Game versions do not match.", which relies on _register
## and _rejected keeping their arguments and their place in the name-sorted RPC
## list (Godot numbers a node's RPCs by sorted method name): name new RPCs so
## they sort after "_rejected". The engine also logs "rpc node checksum failed"
## on both sides of such a join; that is expected.
const PROTOCOL := 2
const DEFAULT_PORT := 7777
const MAX_PLAYERS := 6
const BOT_NAMES := ["BOLT", "NOVA", "ECHO", "FLUX", "PIXEL", "COMET"]
const GAMES := ["twisted", "livewire"]
## Actions each game accepts from send_input(). Live Wire directions are held,
## so they send a press and a release; dash and jump only matter when pressed.
const ACTIONS := {
	"twisted": ["jump", "duck"],
	"livewire": ["left", "right", "up", "down", "dash"],
}
## Accepted input messages per peer per second; the rest are dropped. Spin
## Cycle has three message kinds (jump, duck down, duck up). Live Wire has nine
## (four directions down/up, dash): mashing all five keys at 12 Hz is 108 a
## second, too close to 120 when a dropped release leaves a direction held.
const INPUT_BUDGET := {"twisted": 120, "livewire": 240}

var mode := "offline"
## Current minigame id. Survives close() and solo() so a menu choice sticks;
## a client's value is replaced by the server's as soon as it joins.
var game := "twisted"
var members: Array = []
var leader_id := 1
var playing := false
var round_number := 0
var local_name := "PLAYER"
var port := DEFAULT_PORT
var election: Dictionary = {}
var election_seconds := 0.0
var notice := ""
var connect_seconds := 0.0
var input_budget: Dictionary = {}
var budget_seconds := 0.0

func _ready() -> void:
	# Every client talks only to the server. Disable automatic peer-to-peer
	# relay announcements, including during simultaneous disconnects.
	if multiplayer is SceneMultiplayer:
		multiplayer.server_relay = false
	multiplayer.peer_disconnected.connect(_peer_left)
	multiplayer.connected_to_server.connect(_connected)
	multiplayer.connection_failed.connect(func(): _fail("Could not connect. Check the address, UDP port, and host firewall."))
	multiplayer.server_disconnected.connect(func(): _fail("The server disconnected. Return to the menu to host or join again."))

func _process(delta: float) -> void:
	if mode == "joining":
		connect_seconds += delta
		if connect_seconds > 10.0:
			_fail("Connection timed out. Check that the server is running and UDP port %d is reachable." % port)
	if mode == "host":
		budget_seconds += delta
		if budget_seconds >= 1.0:
			budget_seconds = 0.0
			input_budget.clear()
		if not election.is_empty():
			election_seconds -= delta
			if election_seconds <= 0.0:
				election.clear()
				notice = "Host vote expired. You can start another vote."
				_broadcast_roster()

func is_server() -> bool:
	return mode == "host" or mode == "offline"

func is_leader() -> bool:
	return mode == "offline" or (mode != "joining" and multiplayer.get_unique_id() == leader_id)

func is_online() -> bool:
	return mode == "host" or mode == "client"

## The seat of the person at this machine's keyboard: the peer's first member.
func my_slot() -> int:
	var id := multiplayer.get_unique_id()
	for m in members:
		if int(m.peer) == id:
			return int(m.slot)
	return 0

## Whether this machine may seat players for extra gamepads: solo or hosting.
func local_seats_allowed() -> bool:
	return mode == "offline" or mode == "host"

## Seats a player for gamepad `pad` on this machine, in the lowest open seat.
## Returns the slot, or -1 (not solo or hosting, a round on, no room, or the
## pad already has a seat).
func add_local(pad: int) -> int:
	if not local_seats_allowed() or playing or members.size() >= MAX_PLAYERS or pad_slot(pad) >= 0:
		return -1
	var used := members.map(func(m): return int(m.slot))
	var slot := 0
	while slot in used:
		slot += 1
	members.append({"peer": multiplayer.get_unique_id(), "name": "PLAYER %d" % (slot + 1), "slot": slot, "pad": pad})
	if mode == "host":
		notice = "Player %d joined on this machine." % (slot + 1)
	_broadcast_roster()
	return slot

## Frees gamepad `pad`'s seat. Mid-round the seat is handed to a bot, exactly
## like a player whose connection dropped.
func remove_local(pad: int) -> void:
	var slot := pad_slot(pad)
	if slot < 0:
		return
	if playing:
		seat_disconnected.emit(slot)
	members = members.filter(func(m): return int(m.get("pad", -1)) != pad)
	_broadcast_roster()

## The seat of gamepad `pad`, or -1.
func pad_slot(pad: int) -> int:
	for m in members:
		if m.has("pad") and int(m.pad) == pad:
			return int(m.slot)
	return -1

## Input from one of this machine's extra seats. Only the server has those.
func send_local_input(slot: int, action: String, pressed: bool) -> void:
	if not playing or not is_server() or action not in ACTIONS[game]:
		return
	for m in members:
		if m.has("pad") and int(m.slot) == slot:
			input_received.emit(slot, action, pressed)
			return

## Machines in the party: members with distinct peers. Extra local seats share
## their machine's vote.
func peer_count() -> int:
	var seen: Array = []
	for m in members:
		if int(m.peer) not in seen:
			seen.append(int(m.peer))
	return seen.size()

func clean_name(value: String) -> String:
	var cleaned := value.strip_edges().replace("\n", " ").replace("\r", " ").replace("\t", " ").left(16)
	return cleaned if not cleaned.is_empty() else "PLAYER"

func solo(player_name: String) -> void:
	close()
	local_name = clean_name(player_name)
	members = [{"peer": 1, "name": local_name, "slot": 0}]
	leader_id = 1

func host_game(player_name: String, server_port: int = DEFAULT_PORT) -> Error:
	close()
	if server_port < 1024 or server_port > 65535:
		return ERR_INVALID_PARAMETER
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(server_port, MAX_PLAYERS - 1, 2)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	mode = "host"
	port = server_port
	local_name = clean_name(player_name)
	members = [{"peer": 1, "name": local_name, "slot": 0}]
	leader_id = 1
	notice = "Lobby open. Players join automatically; empty seats become bots."
	roster_changed.emit()
	return OK

func join_game(player_name: String, address: String, server_port: int = DEFAULT_PORT) -> Error:
	close()
	if address.strip_edges().is_empty() or server_port < 1024 or server_port > 65535:
		return ERR_INVALID_PARAMETER
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address.strip_edges(), server_port, 2)
	if err != OK:
		return err
	local_name = clean_name(player_name)
	port = server_port
	mode = "joining"
	connect_seconds = 0.0
	multiplayer.multiplayer_peer = peer
	return OK

func close() -> void:
	mode = "offline"
	playing = false
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	members = []
	leader_id = 1
	election.clear()
	notice = ""

func _fail(message: String) -> void:
	close()
	failed.emit(message)

func _connected() -> void:
	_register.rpc_id(1, local_name, PROTOCOL)

@rpc("any_peer", "call_remote", "reliable")
func _register(player_name: String, protocol: int) -> void:
	if mode != "host":
		return
	var sender := multiplayer.get_remote_sender_id()
	if protocol != PROTOCOL or playing or members.size() >= MAX_PLAYERS:
		_rejected.rpc_id(sender, "Round in progress or lobby full. Try again after this round." if protocol == PROTOCOL else "Game versions do not match.")
		return
	for m in members:
		if int(m.peer) == sender:
			return
	var used := members.map(func(m): return int(m.slot))
	var slot := 0
	while slot in used:
		slot += 1
	members.append({"peer": sender, "name": clean_name(player_name), "slot": slot})
	notice = "%s joined the party." % clean_name(player_name)
	_broadcast_roster()

@rpc("authority", "call_remote", "reliable")
func _rejected(reason: String) -> void:
	_fail(reason)

func _broadcast_roster() -> void:
	if mode == "host":
		for peer in _connected_members():
			_roster.rpc_id(peer, members, leader_id, election, notice, game)
	roster_changed.emit()

func _connected_members() -> Array:
	var connected: Array = []
	var peers := multiplayer.get_peers()
	for m in members:
		var id: int = m.peer
		if id != 1 and id in peers:
			var enet_peer: ENetPacketPeer = multiplayer.multiplayer_peer.get_peer(id)
			if enet_peer and enet_peer.get_state() == ENetPacketPeer.STATE_CONNECTED:
				connected.append(id)
	return connected

@rpc("authority", "call_remote", "reliable")
func _roster(roster: Array, leader: int, vote: Dictionary, message: String, current_game: String) -> void:
	if mode != "client" and mode != "joining":
		return
	mode = "client"
	if current_game in GAMES:
		game = current_game
	members = roster
	leader_id = leader
	election = vote
	notice = message
	roster_changed.emit()

func slots() -> Array:
	var seats: Array = []
	for i in MAX_PLAYERS:
		seats.append({"peer": 0, "name": BOT_NAMES[i], "bot": true})
	for m in members:
		seats[int(m.slot)] = {"peer": m.peer, "name": m.name, "bot": false}
	return seats

## Leader only, between rounds only. Offline this sets `game` directly and
## emits nothing. Online the server decides: it sets `game` and re-broadcasts
## the roster, so every member (a client leader included) sees the change with
## roster_changed. Returns false when the call was ignored locally.
func select_game(id: String) -> bool:
	if id not in GAMES or playing or not is_leader():
		return false
	if mode == "client":
		_request_game.rpc_id(1, id)
	elif mode == "host":
		_choose_game(multiplayer.get_unique_id(), id)
	else:
		game = id
	return true

@rpc("any_peer", "call_remote", "reliable")
func _request_game(id: String) -> void:
	if mode == "host":
		_choose_game(multiplayer.get_remote_sender_id(), id)

func _choose_game(sender: int, id: String) -> void:
	if sender != leader_id or id not in GAMES or playing or id == game:
		return
	game = id
	_broadcast_roster()

func start_round() -> void:
	if not is_leader():
		return
	if mode == "client":
		_request_start.rpc_id(1)
	else:
		_begin()

@rpc("any_peer", "call_remote", "reliable")
func _request_start() -> void:
	if mode == "host" and multiplayer.get_remote_sender_id() == leader_id:
		_begin()

func _begin() -> void:
	if not is_server():
		return
	round_number += 1
	playing = true
	election.clear()
	var seed_value := randi()
	if mode == "host":
		multiplayer.multiplayer_peer.refuse_new_connections = true
		for peer in _connected_members():
			_launch.rpc_id(peer, seed_value, slots(), round_number, game)
	_launch(seed_value, slots(), round_number, game)

@rpc("authority", "call_remote", "reliable")
func _launch(seed_value: int, seats: Array, number: int, game_id: String) -> void:
	if game_id in GAMES:
		game = game_id
	playing = true
	round_number = number
	election.clear()
	round_started.emit(seed_value, seats, number)

func send_input(action: String, pressed: bool) -> void:
	if not playing or action not in ACTIONS[game]:
		return
	if is_server():
		input_received.emit(my_slot(), action, pressed)
	elif mode == "client":
		_receive_input.rpc_id(1, action, pressed)

@rpc("any_peer", "call_remote", "reliable")
func _receive_input(action: String, pressed: bool) -> void:
	if mode != "host" or not playing or action not in ACTIONS[game]:
		return
	var sender := multiplayer.get_remote_sender_id()
	input_budget[sender] = int(input_budget.get(sender, 0)) + 1
	if int(input_budget[sender]) > int(INPUT_BUDGET[game]):
		return
	for m in members:
		if int(m.peer) == sender:
			input_received.emit(int(m.slot), action, pressed)
			return

func send_snapshot(data: Dictionary) -> void:
	if mode == "host":
		# Keep six-player snapshots below ENet's MTU to avoid fragmentation.
		var packed := var_to_bytes(data).compress(FileAccess.COMPRESSION_DEFLATE)
		for peer in _connected_members():
			_state.rpc_id(peer, packed)

@rpc("authority", "call_remote", "unreliable_ordered", 1)
func _state(packed: PackedByteArray) -> void:
	var bytes := packed.decompress_dynamic(65536, FileAccess.COMPRESSION_DEFLATE)
	if bytes.is_empty(): return
	var data: Variant = bytes_to_var(bytes)
	if not data is Dictionary: return
	if mode == "client" and playing and int(data.get("id", -1)) == round_number:
		snapshot_received.emit(data)

func lobby() -> void:
	if not is_leader():
		return
	if mode == "client":
		_request_lobby.rpc_id(1)
	else:
		_open_lobby()

@rpc("any_peer", "call_remote", "reliable")
func _request_lobby() -> void:
	if mode == "host" and multiplayer.get_remote_sender_id() == leader_id:
		_open_lobby()

func _open_lobby() -> void:
	playing = false
	if mode == "host":
		multiplayer.multiplayer_peer.refuse_new_connections = false
		for peer in _connected_members():
			_lobby.rpc_id(peer)
	_lobby()

@rpc("authority", "call_remote", "reliable")
func _lobby() -> void:
	playing = false
	returned_to_lobby.emit()

func propose_host(candidate: int) -> void:
	if mode == "host":
		_propose(multiplayer.get_unique_id(), candidate)
	elif mode == "client":
		_host_proposal.rpc_id(1, candidate)

@rpc("any_peer", "call_remote", "reliable")
func _host_proposal(candidate: int) -> void:
	if mode == "host":
		_propose(multiplayer.get_remote_sender_id(), candidate)

func _member(id: int) -> bool:
	return members.any(func(m): return int(m.peer) == id)

func _propose(sender: int, candidate: int) -> void:
	if not _member(sender) or not _member(candidate) or candidate == leader_id or not election.is_empty():
		return
	if sender == leader_id:
		leader_id = candidate
		notice = "Host controls handed over."
		_broadcast_roster()
		return
	election = {"candidate": candidate, "yes": [sender], "no": []}
	election_seconds = 25.0
	notice = "Vote to switch host. The current host does not vote."
	_evaluate_vote()
	_broadcast_roster()

func cast_vote(yes: bool) -> void:
	if mode == "host":
		_vote(multiplayer.get_unique_id(), yes)
	elif mode == "client":
		_host_vote.rpc_id(1, yes)

@rpc("any_peer", "call_remote", "reliable")
func _host_vote(yes: bool) -> void:
	if mode == "host":
		_vote(multiplayer.get_remote_sender_id(), yes)

func _vote(sender: int, yes: bool) -> void:
	if election.is_empty() or not _member(sender) or sender == leader_id:
		return
	if sender in election.yes or sender in election.no:
		return
	if yes:
		election.yes.append(sender)
	else:
		election.no.append(sender)
	_evaluate_vote()
	_broadcast_roster()

func votes_needed() -> int:
	return maxi(1, int(floor(float(peer_count() - 1) / 2.0)) + 1)

func _evaluate_vote() -> void:
	if election.is_empty():
		return
	if election.yes.size() >= votes_needed():
		leader_id = int(election.candidate)
		election.clear()
		notice = "Vote passed. The new host can start games for everyone."
	elif election.no.size() > (peer_count() - 1) - votes_needed():
		election.clear()
		notice = "Host vote did not pass."

func _peer_left(id: int) -> void:
	if mode != "host":
		return
	for m in members:
		if int(m.peer) == id:
			seat_disconnected.emit(int(m.slot))
	members = members.filter(func(m): return int(m.peer) != id)
	if id == leader_id:
		leader_id = int(members[0].peer) if not members.is_empty() else 1
		election.clear()
		notice = "The party host left. Host controls transferred automatically."
	if not election.is_empty():
		if int(election.candidate) == id:
			election.clear()
		else:
			election.yes.erase(id)
			election.no.erase(id)
			_evaluate_vote()
	_broadcast_roster()
