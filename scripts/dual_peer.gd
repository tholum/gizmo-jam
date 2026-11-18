extends MultiplayerPeerExtension
## The host's side of a party with browser guests: one multiplayer peer that
## is both the ENet server native builds join over UDP and a WebSocket server
## browsers join. Session sees one peer and its RPCs work unchanged; a browser
## guest runs the same build, so the RPC tables match exactly.
##
## Only the host uses this, and only when browser guests are on: a party of
## native builds keeps the plain ENetMultiplayerPeer and pays nothing extra.
## Peer ids come from each server (random 31-bit numbers); a WebSocket id that
## happens to equal an ENet one is turned away.
## Browsers have no unreliable transport, so everything they receive is
## reliable and ordered; on a LAN that costs nothing noticeable.

var enet := ENetMultiplayerPeer.new()
var web := WebSocketMultiplayerPeer.new()
## peer id -> "enet" or "web"
var owners: Dictionary = {}

var _queue: Array = []
var _current: Dictionary = {}
var _target := 0
var _channel := 0
var _mode := MultiplayerPeer.TRANSFER_MODE_RELIABLE
var _refusing := false
var _open := false

## Opens both servers. Returns OK or the first error.
func create(enet_port: int, web_port: int, max_clients: int, channels: int) -> Error:
	var err := enet.create_server(enet_port, max_clients, channels)
	if err != OK: return err
	err = web.create_server(web_port, "*")
	if err != OK:
		enet.close()
		return err
	enet.peer_connected.connect(_joined.bind("enet"))
	enet.peer_disconnected.connect(_left)
	web.peer_connected.connect(_joined.bind("web"))
	web.peer_disconnected.connect(_left)
	_open = true
	return OK

func _joined(id: int, kind: String) -> void:
	if owners.has(id):
		# Two servers chose the same id: keep the first.
		(web if kind == "web" else enet).disconnect_peer(id)
		return
	owners[id] = kind
	peer_connected.emit(id)

func _left(id: int) -> void:
	if owners.erase(id):
		peer_disconnected.emit(id)

## Whether a member is still fully connected (Session._connected_members).
func is_live(id: int) -> bool:
	match owners.get(id, ""):
		"enet":
			var p := enet.get_peer(id)
			return p != null and p.get_state() == ENetPacketPeer.STATE_CONNECTED
		"web":
			var p := web.get_peer(id)
			return p != null and p.get_ready_state() == WebSocketPeer.STATE_OPEN
	return false

func is_browser(id: int) -> bool:
	return owners.get(id, "") == "web"

func _poll() -> void:
	if not _open: return
	for kind in ["enet", "web"]:
		var peer: MultiplayerPeer = enet if kind == "enet" else web
		peer.poll()
		while peer.get_available_packet_count() > 0:
			# The packet's sender, channel and mode describe the next packet,
			# so read them before taking it.
			var from := peer.get_packet_peer()
			var channel := peer.get_packet_channel()
			var mode := peer.get_packet_mode()
			var data := peer.get_packet()
			if owners.get(from, "") == kind:
				_queue.append({"from": from, "channel": channel, "mode": mode, "data": data})

func _get_available_packet_count() -> int:
	return _queue.size()

func _get_packet_script() -> PackedByteArray:
	if _queue.is_empty(): return PackedByteArray()
	_current = _queue.pop_front()
	return _current.data

func _get_packet_peer() -> int:
	return int(_queue[0].from) if not _queue.is_empty() else int(_current.get("from", 0))

func _get_packet_channel() -> int:
	return int(_queue[0].channel) if not _queue.is_empty() else int(_current.get("channel", 0))

func _get_packet_mode() -> MultiplayerPeer.TransferMode:
	return (_queue[0].mode if not _queue.is_empty() else _current.get("mode", MultiplayerPeer.TRANSFER_MODE_RELIABLE)) as MultiplayerPeer.TransferMode

func _put_packet_script(buffer: PackedByteArray) -> Error:
	if _target > 0:
		return _send_to(_target, buffer)
	var result := OK
	for id in owners.keys():
		if _target < 0 and id == -_target: continue
		var err := _send_to(id, buffer)
		if err != OK: result = err
	return result

func _send_to(id: int, buffer: PackedByteArray) -> Error:
	var kind: String = owners.get(id, "")
	if kind.is_empty(): return ERR_DOES_NOT_EXIST
	var peer: MultiplayerPeer = enet if kind == "enet" else web
	peer.transfer_channel = _channel
	peer.transfer_mode = _mode
	peer.set_target_peer(id)
	return peer.put_packet(buffer)

func _set_target_peer(peer: int) -> void:
	_target = peer

func _set_transfer_channel(channel: int) -> void:
	_channel = channel

func _get_transfer_channel() -> int:
	return _channel

func _set_transfer_mode(mode: MultiplayerPeer.TransferMode) -> void:
	_mode = mode

func _get_transfer_mode() -> MultiplayerPeer.TransferMode:
	return _mode

func _get_max_packet_size() -> int:
	return 1 << 16

func _is_server() -> bool:
	return true

func _get_unique_id() -> int:
	return 1

func _is_server_relay_supported() -> bool:
	return false

func _set_refuse_new_connections(enable: bool) -> void:
	_refusing = enable
	enet.refuse_new_connections = enable
	web.refuse_new_connections = enable

func _is_refusing_new_connections() -> bool:
	return _refusing

func _get_connection_status() -> MultiplayerPeer.ConnectionStatus:
	return MultiplayerPeer.CONNECTION_CONNECTED if _open else MultiplayerPeer.CONNECTION_DISCONNECTED

func _disconnect_peer(id: int, force: bool) -> void:
	match owners.get(id, ""):
		"enet": enet.disconnect_peer(id, force)
		"web": web.disconnect_peer(id, force)

func _close() -> void:
	_open = false
	enet.close()
	web.close()
	owners.clear()
	_queue.clear()
