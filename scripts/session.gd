extends Node
## One network server, six seats, and a transferable party leader.
##
## The party plays one minigame at a time. `game` is a game id; the party
## leader picks it with select_game() between rounds, the server is the only
## peer that changes it for a party, and it reaches everyone with the roster
## (so late joiners get it with their first roster) and again with each launch.
## `game` is already set when round_started fires. Inputs are filtered by the
## game's actions (scripts/game_registry.gd) on the sender and again on the
## server.
##
## Mixed builds. Every build since 0.2.0 can join every other. After the 0.2.0
## exchange (_register, _roster) newer builds swap capabilities as raw packets
## (scripts/party_wire.gd): their core build and installed games. A member that
## sends none within HELLO_WAIT is a 0.2.0 build and can play the built-in
## games only. The host launches a round only for members who can play the
## chosen game; everyone else sits it out in the lobby. Their seats can stay
## open or be played by bots. The leader may pick any game the host has; members who lack it fetch
## it (main.gd and scripts/pack_manager.gd) and report progress with STATUS.
## A host that advertises color picking keeps explicit picks in its roster
## and assigns everyone a color when the round launches.
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
## Capabilities, member states or the round's line-up changed.
signal party_changed
signal color_pick_rejected(message: String)

const Registry = preload("res://scripts/game_registry.gd")
const Wire = preload("res://scripts/party_wire.gd")
const DualPeer = preload("res://scripts/dual_peer.gd")
const Palette = preload("res://scripts/palette.gd")

## Bump whenever an RPC is added or its arguments change. A mixed-build join
## must still end in "Game versions do not match.", which relies on _register
## and _rejected keeping their arguments and their place in the name-sorted RPC
## list (Godot numbers a node's RPCs by sorted method name): name new RPCs so
## they sort after "_rejected". The engine also logs "rpc node checksum failed"
## on both sides of such a join; that is expected.
## Prefer a party_wire.gd message to a new RPC: those need no bump at all.
const PROTOCOL := 2
const DEFAULT_PORT := 7777
const MAX_PLAYERS := 6
const ALL_BOTS := (1 << MAX_PLAYERS) - 1
const BOT_NAMES := ["BOLT", "NOVA", "ECHO", "FLUX", "PIXEL", "COMET"]
## The games every build since 0.2.0 has. Packs add more (see Registry).
const GAMES := Registry.BUILTIN_IDS
const ACTIONS := Registry.BUILTIN_ACTIONS
const INPUT_BUDGET := Registry.BUILTIN_BUDGET
## Seconds the host waits for a new member's capabilities before treating it
## as a 0.2.0 build.
const HELLO_WAIT := 3.0
## Member states for the current game. The first group can still become ready,
## so the leader's Start waits for them; the second sits the round out.
const WAITING_STATES := ["joining", "missing", "downloading", "verifying", "asking"]
const SIT_OUT_STATES := ["needs_update", "restart", "declined", "failed", "untrusted"]

var mode := "offline"
## Current minigame id. Survives close() and solo() so a menu choice sticks;
## a client's value is replaced by the server's as soon as it joins, even when
## this build does not have that game yet.
var game := "twisted"
var members: Array = []
var leader_id := 1
var playing := false
## -1 uses the default line-up. Explicit choices mark individual open seats.
var bot_slots := -1
var round_number := 0
var local_name := "PLAYER"
var port := DEFAULT_PORT
var election: Dictionary = {}
var election_seconds := 0.0
var notice := ""
var connect_seconds := 0.0
var input_budget: Dictionary = {}
var budget_seconds := 0.0
## Host: peer -> capabilities ({"build", "games": Registry.capabilities()}),
## legacy members get Registry.legacy_capabilities() and "legacy": true.
var caps: Dictionary = {}
## Host: peer -> seconds it has been a member without capabilities.
var hello_clock: Dictionary = {}
## Host: peer -> its last STATUS ({"game", "state", "progress"}).
var states: Dictionary = {}
## Peers in the round being played (host and clients alike).
var round_peers: Array = []
## Host: TCP port of the file server that hands packs to members (0 = none).
var file_port := 0
## Client: the host's HELLO, or {} for a 0.2.0 host (or before it arrives).
var host_info: Dictionary = {}
## Client: the host's last PARTY message.
var party: Dictionary = {}
## Client: what it last reported for the current game.
var local_status: Dictionary = {}
## Host: the WebSocket port browser guests join on (0 = browser guests off).
var web_port := 0
## Client: the address it joined, for fetching packs from the host.
var join_address := ""

func _ready() -> void:
	# Every client talks only to the server. Disable automatic peer-to-peer
	# relay announcements, including during simultaneous disconnects.
	if multiplayer is SceneMultiplayer:
		multiplayer.server_relay = false
		multiplayer.peer_packet.connect(_packet)
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
		if not hello_clock.is_empty():
			var legacy := false
			for peer in hello_clock.keys():
				hello_clock[peer] += delta
				if hello_clock[peer] >= HELLO_WAIT:
					hello_clock.erase(peer)
					caps[peer] = {"build": 0, "legacy": true, "games": Registry.legacy_capabilities()}
					legacy = true
			if legacy: _broadcast_party()

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
	var slot := _claim_open_slot()
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
	if not playing or not is_server() or action not in Registry.actions(game):
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

## Opens a party. With `browser_port` > 0 browsers can join too, over a
## WebSocket on the first free port from browser_port (see dual_peer.gd).
func host_game(player_name: String, server_port: int = DEFAULT_PORT, browser_port: int = 0) -> Error:
	var previous_color: int = _owned_seat(1, 0).get("color", -1) if mode == "offline" else -1
	if server_port < 1024 or server_port > 65535:
		return ERR_INVALID_PARAMETER
	var peer: MultiplayerPeer
	var bound_web_port := 0
	if browser_port > 0:
		var err := ERR_CANT_CREATE
		for p in range(browser_port, browser_port + 10):
			var dual := DualPeer.new()
			err = dual.create(server_port, p, MAX_PLAYERS - 1, 2)
			if err == OK:
				peer = dual
				bound_web_port = p
				break
			dual.close()
			# A busy UDP port will not free up by trying other WebSocket ports.
			var probe := ENetMultiplayerPeer.new()
			if probe.create_server(server_port, 1, 1) != OK:
				return err
			probe.close()
		if peer == null:
			return err
	else:
		var enet := ENetMultiplayerPeer.new()
		var err := enet.create_server(server_port, MAX_PLAYERS - 1, 2)
		if err != OK:
			return err
		peer = enet
	close()
	multiplayer.multiplayer_peer = peer
	mode = "host"
	port = server_port
	web_port = bound_web_port
	local_name = clean_name(player_name)
	members = [{"peer": 1, "name": local_name, "slot": 0}]
	if previous_color >= 0:
		members[0]["color"] = previous_color
	leader_id = 1
	notice = "Lobby open. Share the join address with friends."
	roster_changed.emit()
	return OK

func join_game(player_name: String, address: String, server_port: int = DEFAULT_PORT) -> Error:
	if address.strip_edges().is_empty() or server_port < 1024 or server_port > 65535:
		return ERR_INVALID_PARAMETER
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address.strip_edges(), server_port, 2)
	if err != OK:
		return err
	close()
	local_name = clean_name(player_name)
	port = server_port
	join_address = address.strip_edges()
	mode = "joining"
	connect_seconds = 0.0
	multiplayer.multiplayer_peer = peer
	return OK

## Joins over a WebSocket: what the browser build does. `url` is
## ws://<host>:<port>.
func join_web(player_name: String, url: String) -> Error:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(url)
	if err != OK:
		return err
	close()
	local_name = clean_name(player_name)
	join_address = url.trim_prefix("ws://").get_slice(":", 0)
	mode = "joining"
	connect_seconds = 0.0
	multiplayer.multiplayer_peer = peer
	return OK

## Host: whether a member joined from a browser.
func is_browser(peer: int) -> bool:
	return mode == "host" and multiplayer.multiplayer_peer is DualPeer and multiplayer.multiplayer_peer.is_browser(peer)

func close() -> void:
	mode = "offline"
	playing = false
	bot_slots = -1
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	members = []
	leader_id = 1
	election.clear()
	notice = ""
	caps.clear()
	hello_clock.clear()
	states.clear()
	round_peers.clear()
	host_info.clear()
	party.clear()
	local_status.clear()
	web_port = 0

func _fail(message: String) -> void:
	close()
	failed.emit(message)

func _connected() -> void:
	_register.rpc_id(1, local_name, PROTOCOL)
	# Sent after _register on the same reliable channel, so the host has the
	# member before their capabilities. A 0.2.0 host ignores it.
	send_hello()

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
	var slot := _claim_open_slot()
	members.append({"peer": sender, "name": clean_name(player_name), "slot": slot})
	if not caps.has(sender):
		hello_clock[sender] = 0.0
	notice = "%s joined the party." % clean_name(player_name)
	_broadcast_roster()

@rpc("authority", "call_remote", "reliable")
func _rejected(reason: String) -> void:
	_fail(reason)

func _broadcast_roster() -> void:
	if mode == "host":
		for peer in _connected_members():
			_roster.rpc_id(peer, members, leader_id, election, notice, game)
		_broadcast_party()
	roster_changed.emit()

func _connected_members() -> Array:
	var connected: Array = []
	var peers := multiplayer.get_peers()
	for m in members:
		var id: int = m.peer
		if id != 1 and id in peers:
			var server := multiplayer.multiplayer_peer
			if server is DualPeer:
				if server.is_live(id): connected.append(id)
			else:
				var enet_peer: ENetPacketPeer = server.get_peer(id)
				if enet_peer and enet_peer.get_state() == ENetPacketPeer.STATE_CONNECTED:
					connected.append(id)
	return connected

## Connected members who are in the round being played.
func _round_members() -> Array:
	return _connected_members().filter(func(id): return id in round_peers)

@rpc("authority", "call_remote", "reliable")
func _roster(roster: Array, leader: int, vote: Dictionary, message: String, current_game: String) -> void:
	if mode != "client" and mode != "joining":
		return
	mode = "client"
	# Kept even when this build lacks the game: main fetches it.
	if Registry.valid_id(current_game):
		game = current_game
	members = roster
	leader_id = leader
	election = vote
	notice = message
	roster_changed.emit()

func _human_mask() -> int:
	var mask := 0
	for member in members:
		mask |= 1 << int(member.slot)
	return mask

func _claim_open_slot() -> int:
	var used := _human_mask()
	var reserved := bot_slots if bot_slots >= 0 else 0
	var vacant := ALL_BOTS & ~(used | reserved)
	if vacant == 0: vacant = ALL_BOTS & ~used
	for slot in MAX_PLAYERS:
		if (vacant & (1 << slot)) != 0:
			if bot_slots >= 0: bot_slots &= ~(1 << slot)
			return slot
	return -1

func _bot_mask() -> int:
	if mode == "client": return int(party.get("bot_mask", ALL_BOTS))
	if not Registry.supports_optional_seats(game): return ALL_BOTS
	if bot_slots >= 0: return bot_slots
	# Solo keeps its usual opponents. Multiplayer starts with open seats
	# unless a connected client needs a six-seat round.
	if mode == "offline": return ALL_BOTS if members.size() <= 1 else 0
	for peer in _connected_members():
		if not caps.get(peer, {}).get("optional_seats", false):
			return ALL_BOTS
	return 0

func bot_at(slot: int) -> bool:
	return (_bot_mask() & (1 << slot)) != 0

func can_set_bot(slot: int) -> bool:
	if playing or sitting_out() or not is_leader() or slot < 0 or slot >= MAX_PLAYERS:
		return false
	if (_human_mask() & (1 << slot)) != 0: return false
	if mode == "client":
		return host_info.get("optional_seats", false) == true and party_games().get(game, {}).get("optional_seats", false) == true
	return Registry.supports_optional_seats(game)

func set_bot(slot: int, enabled: bool) -> void:
	if not can_set_bot(slot): return
	if mode == "client":
		_send(1, Wire.SET_BOT, {"slot": slot, "enabled": enabled})
	else:
		_apply_bot(slot, enabled)

func _apply_bot(slot: int, enabled: bool) -> void:
	var mask := _bot_mask() & ~_human_mask()
	bot_slots = (mask | (1 << slot)) if enabled else (mask & ~(1 << slot))
	_broadcast_roster()

## Seats missing from the line-up stay inactive unless that slot has a bot.
func slots(in_round: Array = []) -> Array:
	var seats: Array = []
	var used_colors := {}
	var bots := _bot_mask()
	for i in MAX_PLAYERS:
		var seat := {"peer": 0, "name": BOT_NAMES[i], "bot": true}
		if (bots & (1 << i)) == 0:
			seat.name = ""
			seat["active"] = false
		seats.append(seat)
	for m in members:
		if in_round.is_empty() or int(m.peer) in in_round:
			var slot: int = m.slot
			seats[slot] = {"peer": m.peer, "name": m.name, "bot": false}
			if m.has("color"):
				seats[slot]["color"] = m.color
				used_colors[m.color] = true
	# Keep the usual seat colors wherever they are available before assigning
	# substitutes to seats whose usual color was picked by someone else.
	for slot in MAX_PLAYERS:
		if not seats[slot].has("color") and not used_colors.has(slot):
			seats[slot]["color"] = slot
			used_colors[slot] = true
	for seat in seats:
		if seat.has("color"):
			continue
		for color in Palette.SELECTABLE.size():
			if not used_colors.has(color):
				seat["color"] = color
				used_colors[color] = true
				break
	return seats

func color_picking_supported() -> bool:
	return is_server() or (mode == "client" and host_info.get("color_picking", false) == true)

## Explicit picks only. Unselected players have no reservation.
func color_owners() -> Dictionary:
	var owners := {}
	for member in members:
		if member.has("color"):
			owners[member.color] = member.slot
	return owners

func can_pick_color(slot: int) -> bool:
	if not color_picking_supported() or playing or sitting_out():
		return false
	return not _owned_seat(multiplayer.get_unique_id(), slot).is_empty()

## Clients submit a request. The host's roster confirms any accepted change.
func pick_color(slot: int, color: int) -> bool:
	if not can_pick_color(slot) or color < 0 or color >= Palette.SELECTABLE.size():
		return false
	if mode == "client":
		_send(1, Wire.PICK_COLOR, {"slot": slot, "color": color})
		return true
	var reason := _apply_color_pick(multiplayer.get_unique_id(), slot, color)
	if not reason.is_empty():
		color_pick_rejected.emit(reason)
	return reason.is_empty()

func _owned_seat(peer: int, slot: int) -> Dictionary:
	for member in members:
		if int(member.peer) == peer and int(member.slot) == slot:
			return member
	return {}

func _apply_color_pick(peer: int, slot: int, color: int) -> String:
	if playing:
		return "Colors can be changed between rounds."
	var member := _owned_seat(peer, slot)
	if member.is_empty() or color < 0 or color >= Palette.SELECTABLE.size():
		return "This color pick is unavailable."
	var owner: int = color_owners().get(color, -1)
	if owner == slot:
		return ""
	if owner >= 0:
		return "That color is already taken."
	member["color"] = color
	notice = "%s changed color." % member.name
	_broadcast_roster()
	return ""

## Leader only, between rounds only. Offline this sets `game` directly and
## emits nothing. Online the server decides: it sets `game` and re-broadcasts
## the roster, so every member (a client leader included) sees the change with
## roster_changed. Returns false when the call was ignored locally.
func select_game(id: String) -> bool:
	if playing or not is_leader():
		return false
	if mode == "client":
		if not party_games().has(id):
			return false
		_request_game.rpc_id(1, id)
	elif mode == "host":
		if not Registry.has(id):
			return false
		_choose_game(multiplayer.get_unique_id(), id)
	else:
		if not Registry.has(id):
			return false
		game = id
	return true

@rpc("any_peer", "call_remote", "reliable")
func _request_game(id: String) -> void:
	if mode == "host":
		_choose_game(multiplayer.get_remote_sender_id(), id)

func _choose_game(sender: int, id: String) -> void:
	if sender != leader_id or not Registry.has(id) or playing or id == game:
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
	round_peers = [1]
	if mode == "host":
		multiplayer.multiplayer_peer.refuse_new_connections = true
		for peer in _connected_members():
			if member_state(peer).state == "ready":
				round_peers.append(peer)
		var seats := slots(round_peers)
		if seats.any(func(seat): return not seat.get("active", true)):
			round_peers = round_peers.filter(func(peer): return peer == 1 or caps.get(peer, {}).get("games", {}).get(game, {}).get("optional_seats", false))
			seats = slots(round_peers)
		for peer in round_peers:
			if peer != 1:
				_launch.rpc_id(peer, seed_value, seats, round_number, game)
		_broadcast_party()
		_launch(seed_value, seats, round_number, game)
	else:
		_launch(seed_value, slots(), round_number, game)

@rpc("authority", "call_remote", "reliable")
func _launch(seed_value: int, seats: Array, number: int, game_id: String) -> void:
	# The host only launches members who have the game; anything else is a
	# mistake, and playing a different game would be worse than sitting out.
	if not Registry.has(game_id):
		return
	game = game_id
	playing = true
	round_number = number
	election.clear()
	for slot in seats.size():
		if not seats[slot].has("color"):
			seats[slot]["color"] = slot
	if mode == "client":
		round_peers = []
		for seat in seats:
			if not seat.bot: round_peers.append(int(seat.peer))
	round_started.emit(seed_value, seats, number)

func send_input(action: String, pressed: bool) -> void:
	if not playing or action not in Registry.actions(game):
		return
	if is_server():
		input_received.emit(my_slot(), action, pressed)
	elif mode == "client":
		_receive_input.rpc_id(1, action, pressed)

@rpc("any_peer", "call_remote", "reliable")
func _receive_input(action: String, pressed: bool) -> void:
	if mode != "host" or not playing or action not in Registry.actions(game):
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender not in round_peers:
		return
	input_budget[sender] = int(input_budget.get(sender, 0)) + 1
	if int(input_budget[sender]) > Registry.input_budget(game):
		return
	for m in members:
		if int(m.peer) == sender:
			input_received.emit(int(m.slot), action, pressed)
			return

func send_snapshot(data: Dictionary) -> void:
	if mode == "host":
		# Keep six-player snapshots below ENet's MTU to avoid fragmentation.
		var packed := var_to_bytes(data).compress(FileAccess.COMPRESSION_DEFLATE)
		for peer in _round_members():
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
	round_peers.clear()
	if mode == "host":
		multiplayer.multiplayer_peer.refuse_new_connections = false
		for peer in _connected_members():
			_lobby.rpc_id(peer)
		_broadcast_party()
	_lobby()

@rpc("authority", "call_remote", "reliable")
func _lobby() -> void:
	playing = false
	round_peers.clear()
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
	caps.erase(id)
	hello_clock.erase(id)
	states.erase(id)
	if mode != "host":
		return
	for m in members:
		if int(m.peer) == id and id in round_peers:
			seat_disconnected.emit(int(m.slot))
	round_peers.erase(id)
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

# --- Capabilities, member states and the round line-up (raw packets) ---------

func _send(peer: int, kind: int, payload: Dictionary) -> void:
	if multiplayer is SceneMultiplayer and multiplayer.multiplayer_peer != null and mode != "offline":
		multiplayer.send_bytes(Wire.encode(kind, payload), peer, MultiplayerPeer.TRANSFER_MODE_RELIABLE, 0)

func _hello_payload() -> Dictionary:
	var payload := {"build": int(ProjectSettings.get_setting("application/config/build", 0)),
		"version": str(ProjectSettings.get_setting("application/config/version", "")),
		"games": Registry.capabilities(), "optional_seats": true}
	if mode == "host":
		payload["file_port"] = file_port
		payload["color_picking"] = true
	return payload

## Advertises this build's games: a client to the host, the host to everyone.
## Call again after installing a game.
func send_hello() -> void:
	if mode == "joining" or mode == "client":
		_send(1, Wire.HELLO, _hello_payload())
	elif mode == "host":
		for peer in _connected_members():
			if not caps.get(peer, {}).get("legacy", false):
				_send(peer, Wire.HELLO, _hello_payload())
		_broadcast_party()

func _packet(sender: int, bytes: PackedByteArray) -> void:
	var message := Wire.decode(bytes)
	if message.is_empty(): return
	var data: Dictionary = message.data
	match int(message.kind):
		Wire.HELLO:
			if mode == "host":
				if typeof(data.get("games")) != TYPE_DICTIONARY: return
				caps[sender] = {"build": int(data.get("build", 0)), "legacy": false, "games": _clean_caps(data.games),
					"optional_seats": data.get("optional_seats", false) == true}
				hello_clock.erase(sender)
				_send(sender, Wire.HELLO, _hello_payload())
				_broadcast_party()
			elif sender == 1 and (mode == "client" or mode == "joining"):
				host_info = data
				party_changed.emit()
		Wire.PARTY:
			if sender == 1 and (mode == "client" or mode == "joining"):
				party = data
				party_changed.emit()
		Wire.STATUS:
			if mode == "host" and _member(sender):
				var state := str(data.get("state", ""))
				if not Registry.valid_id(state): return
				states[sender] = {"game": str(data.get("game", "")), "state": state, "progress": clampi(int(data.get("progress", 0)), 0, 100)}
				_broadcast_party()
		Wire.PICK_COLOR:
			if mode == "host" and _member(sender):
				if typeof(data.get("slot")) != TYPE_INT or typeof(data.get("color")) != TYPE_INT:
					return
				var reason := _apply_color_pick(sender, data.slot, data.color)
				if not reason.is_empty():
					_send(sender, Wire.COLOR_REJECTED, {"message": reason})
		Wire.COLOR_REJECTED:
			if sender == 1 and mode == "client" and typeof(data.get("message")) == TYPE_STRING:
				color_pick_rejected.emit(data.message)
		Wire.SET_BOT:
			if mode != "host" or playing or sender != leader_id or not _member(sender) or not Registry.supports_optional_seats(game):
				return
			if typeof(data.get("slot")) != TYPE_INT or typeof(data.get("enabled")) != TYPE_BOOL: return
			var slot: int = data.slot
			if slot >= 0 and slot < MAX_PLAYERS and (_human_mask() & (1 << slot)) == 0:
				_apply_bot(slot, data.enabled)

## Keeps only well-formed capability entries, at most 512 games.
func _clean_caps(raw: Dictionary) -> Dictionary:
	var clean := {}
	for id in raw:
		if clean.size() >= 512: break
		if not Registry.valid_id(id) or typeof(raw[id]) != TYPE_DICTIONARY: continue
		var e: Dictionary = raw[id]
		clean[id] = {"net": int(e.get("net", 0)), "version": str(e.get("version", "")).left(32),
			"sha256": str(e.get("sha256", "")).left(64), "trust": str(e.get("trust", "")).left(16),
			"optional_seats": e.get("optional_seats", false) == true}
	return clean

func _broadcast_party() -> void:
	if mode != "host": return
	var payload := {"games": party_games(), "states": member_states(), "round": playing,
		"round_peers": round_peers.duplicate(), "file_port": file_port, "bot_mask": _bot_mask()}
	for peer in _connected_members():
		if not caps.get(peer, {}).get("legacy", false):
			_send(peer, Wire.PARTY, payload)
	party_changed.emit()

## Client: tells the host where it is with the current game.
func report_status(state: String, progress: int = 0) -> void:
	var status := {"game": game, "state": state, "progress": progress}
	if status == local_status: return
	local_status = status
	if mode == "client":
		_send(1, Wire.STATUS, status)

## The games the party can play: id -> Registry.public_entry(). A client gets
## the host's list; a 0.2.0 host can play the built-in games only.
func party_games() -> Dictionary:
	var list := {}
	if mode == "client" or mode == "joining":
		if typeof(party.get("games")) == TYPE_DICTIONARY:
			for id in party.games:
				if Registry.valid_id(id) and typeof(party.games[id]) == TYPE_DICTIONARY:
					list[id] = party.games[id]
			return list
		for id in GAMES:
			var e := Registry.public_entry(id)
			e.net = Registry.LEGACY_NET
			list[id] = e
		return list
	for id in Registry.ids():
		list[id] = _party_game_entry(id)
	return list

func _party_game_entry(id: String) -> Dictionary:
	var entry := Registry.public_entry(id)
	if id != game: return entry
	var active := _bot_mask()
	for member in members:
		var peer: int = member.peer
		var compatible := Registry.compatible(caps[peer].games, game, entry) if caps.has(peer) else Registry.is_builtin(game)
		if peer == 1 or compatible:
			active |= 1 << int(member.slot)
	if active != ALL_BOTS:
		entry["requires_optional_seats"] = true
	return entry

## Host: where a member is with the current game: {"state", "progress"}.
func member_state(peer: int) -> Dictionary:
	if peer == 1 or mode != "host":
		return {"state": "ready", "progress": 100}
	var host_entry := _party_game_entry(game)
	# Older cores require a full line-up even if the snapshot shape matches.
	if host_entry.get("requires_optional_seats", false) and not caps.get(peer, {}).get("optional_seats", false):
		if not caps.has(peer): return {"state": "joining", "progress": 0}
		return {"state": "needs_update", "progress": 0}
	if not caps.has(peer):
		# Every build since 0.2.0 plays the built-in games at net 1, so they
		# need no capabilities; anything else waits for them.
		if Registry.is_builtin(game): return {"state": "ready", "progress": 100}
		return {"state": "joining", "progress": 0}
	if Registry.compatible(caps[peer].games, game, host_entry):
		return {"state": "ready", "progress": 100}
	if caps[peer].get("legacy", false):
		return {"state": "needs_update", "progress": 0}
	if int(host_entry.get("core_min", 0)) > int(caps[peer].get("build", 0)):
		return {"state": "needs_update", "progress": 0}
	var reported: Dictionary = states.get(peer, {})
	if reported.get("game", "") == game and reported.get("state", "") != "ready":
		return {"state": reported.state, "progress": int(reported.progress)}
	return {"state": "missing", "progress": 0}

## Every member's state for the current game, by peer id. A client reads the
## host's copy.
func member_states() -> Dictionary:
	if mode == "host":
		var all := {}
		for m in members:
			all[int(m.peer)] = member_state(int(m.peer))
		return all
	if mode == "client" and typeof(party.get("states")) == TYPE_DICTIONARY:
		return party.states
	return {}

## {"state", "progress"} for one member, as this peer knows it.
func status_of(peer: int) -> Dictionary:
	var all := member_states()
	if all.has(peer) and typeof(all[peer]) == TYPE_DICTIONARY:
		return all[peer]
	return {"state": "ready", "progress": 100} if mode != "client" or party.is_empty() else {"state": "joining", "progress": 0}

## Members the leader's Start is waiting for.
func waiting_count() -> int:
	var count := 0
	for m in members:
		if str(status_of(int(m.peer)).get("state", "")) in WAITING_STATES:
			count += 1
	return count

## Client: whether the host is running a round this peer is not in.
func sitting_out() -> bool:
	return mode == "client" and not playing and bool(party.get("round", false))

## Client: the file server on the host, {"ip", "port"}, or {} if it has none.
func host_files() -> Dictionary:
	var p := int(party.get("file_port", host_info.get("file_port", 0)))
	if mode != "client" or p <= 0: return {}
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet != null and enet.get_peer(1) != null:
		return {"ip": enet.get_peer(1).get_remote_address(), "port": p}
	if join_address.is_empty(): return {}
	return {"ip": join_address, "port": p}
