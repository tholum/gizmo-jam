extends Node
## LAN party discovery: a host advertises its party with a small UDP beacon
## about once a second, and the Join Party dialog listens for those beacons.
##
## One node does one job. `advertise()` turns it into a beacon that follows a
## hosting Session and stops by itself as soon as that Session stops hosting.
## `browse()` turns it into a listener that keeps a list of parties it has heard
## from recently. Freeing the node, or `stop()`, closes every socket.
##
## The beacon is one line of 7-bit ASCII JSON with a fixed shape:
##   {"magic":"GIZMOJAM","v":1,"id":"3fa9c2e1","name":"TIM","port":7777,
##    "players":2,"max":6,"round":false,"game":"Spin Cycle"}
## `v` is Session.PROTOCOL, so a mismatched build shows as incompatible. `id` is
## a random number picked each time a party opens; it only lets a listener merge
## copies of one beacon that arrived over several interfaces. Nothing else about
## the computer or the player is sent. Received packets are size-capped, must be
## printable ASCII and parse as plain JSON; nothing is ever decoded to objects.

signal changed

const Session = preload("res://scripts/session.gd")

const PORT := 7778
const MAGIC := "GIZMOJAM"
const MAX_PACKET := 512
const INTERVAL := 1.0
const EXPIRY := 3.5
const MAX_PARTIES := 16
## Packets read per frame. More than this in one frame is a flood, not parties.
const READ_BUDGET := 64
## Linux container and VM bridges never lead to another player's computer.
const SKIP_INTERFACES := ["docker", "br-", "veth"]

## Test-only overrides; 0 and "" mean production behaviour. `port_override`
## moves the discovery port. `target_override` sends beacons to that single
## address (unicast, normally 127.0.0.1) instead of broadcasting, which makes a
## single-machine test deterministic.
static var port_override := 0
static var target_override := ""
## Beacon id of a party this process is hosting, so it never lists itself.
static var own_id := ""

var role := "idle"
var port := PORT
## Browse: "listening", or "busy" when another program holds the discovery port.
var status := "idle"
var parties: Dictionary = {}

var _session: Node
var _game := ""
## Optional: returns the game currently picked for the party, so the beacon
## follows the host switching games in the lobby. Falls back to `_game`.
var game_label := Callable()
var _id := ""
var _clock := 0.0
var _senders: Array = []
var _listener: PacketPeerUDP
var _local_ips: Array = []

func _init() -> void:
	port = port_override if port_override > 0 else PORT

func _exit_tree() -> void:
	stop()

## Starts advertising the party `session` is hosting. Returns OK when at least
## one beacon socket could be opened.
func advertise(session: Node, game_name: String) -> Error:
	stop()
	_session = session
	_game = game_name.left(24)
	_id = "%08x" % (randi() & 0x7fffffff)
	own_id = _id
	for target in _targets():
		var udp := PacketPeerUDP.new()
		udp.set_broadcast_enabled(target.broadcast)
		if udp.bind(0, target.bind) != OK or udp.set_dest_address(target.address, port) != OK:
			udp.close()
			continue
		_senders.append(udp)
	if _senders.is_empty():
		own_id = ""
		return ERR_CANT_CREATE
	role = "beacon"
	_clock = 0.0
	_send()
	return OK

func is_advertising() -> bool:
	return role == "beacon"

## Starts listening for beacons. Returns ERR_UNAVAILABLE, and sets `status` to
## "busy", when another program (often a second copy of the game) already holds
## the discovery port; manual joining still works then.
func browse() -> Error:
	stop()
	_listener = PacketPeerUDP.new()
	var err := _listener.bind(port, "0.0.0.0", 16384)
	if err != OK:
		_listener = null
		status = "busy"
		return ERR_UNAVAILABLE
	_local_ips = Array(IP.get_local_addresses())
	role = "browse"
	status = "listening"
	return OK

func stop() -> void:
	for udp in _senders:
		udp.close()
	_senders.clear()
	if _listener:
		_listener.close()
		_listener = null
	if role == "beacon" and own_id == _id:
		own_id = ""
	parties.clear()
	role = "idle"
	status = "idle"
	_session = null

## Parties heard in the last few seconds: joinable ones first, then by name.
func party_list() -> Array:
	var list := parties.values()
	list.sort_custom(func(a, b):
		if _rank(a) != _rank(b): return _rank(a) < _rank(b)
		return str(a.name) < str(b.name))
	return list

func _rank(p: Dictionary) -> int:
	if not p.compatible: return 3
	if p.round or int(p.players) >= int(p.max): return 1
	return 0

func _process(delta: float) -> void:
	if role == "beacon":
		if not is_instance_valid(_session) or _session.mode != "host":
			stop()
			return
		_clock += delta
		if _clock >= INTERVAL:
			_clock = 0.0
			_send()
	elif role == "browse":
		_receive()
		_expire()

## Where beacons go: 255.255.255.255 from an unbound socket (the system picks
## the main interface and its source address), plus each IPv4 interface's own
## subnet broadcast from a socket bound to that interface, so a computer on both
## Wi-Fi and Ethernet, or behind a VPN, still reaches each LAN.
func _targets() -> Array:
	if not target_override.is_empty():
		return [{"bind": "0.0.0.0", "address": target_override, "broadcast": false}]
	var list: Array = [{"bind": "0.0.0.0", "address": "255.255.255.255", "broadcast": true}]
	for iface in IP.get_local_interfaces():
		var iface_name := str(iface.name)
		if SKIP_INTERFACES.any(func(prefix): return iface_name.begins_with(prefix)):
			continue
		for ip in iface.addresses:
			var directed := _directed_broadcast(str(ip))
			if not directed.is_empty() and list.size() < 17:
				list.append({"bind": str(ip), "address": directed, "broadcast": true})
	return list

## Godot does not report netmasks, so assume the usual home /24 subnet. On a
## wider subnet the limited broadcast above still reaches the local segment.
static func _directed_broadcast(ip: String) -> String:
	if ":" in ip or not ip.is_valid_ip_address():
		return ""
	var parts := ip.split(".")
	if parts.size() != 4 or parts[0] == "127" or (parts[0] == "169" and parts[1] == "254"):
		return ""
	return "%s.%s.%s.255" % [parts[0], parts[1], parts[2]]

func _send() -> void:
	var game_name := str(game_label.call()) if game_label.is_valid() else _game
	var packet := beacon_bytes(_id, _session.local_name, _session.port, _session.members.size(), _session.playing, game_name.left(24))
	for udp in _senders:
		udp.put_packet(packet)

## Builds one beacon. Non-ASCII characters in names are \u-escaped, so every
## beacon on the wire is printable ASCII.
static func beacon_bytes(id: String, host_name: String, game_port: int, players: int, playing: bool, game_name: String) -> PackedByteArray:
	var text := JSON.stringify({
		"magic": MAGIC, "v": Session.PROTOCOL, "id": id, "name": clean(host_name, 16, "PARTY"),
		"port": game_port, "players": players, "max": Session.MAX_PLAYERS,
		"round": playing, "game": clean(game_name, 24, "")})
	var ascii := ""
	for i in text.length():
		var code := text.unicode_at(i)
		if code < 0x7f:
			ascii += text[i]
		elif code > 0xffff:
			code -= 0x10000
			ascii += "\\u%04x\\u%04x" % [0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff)]
		else:
			ascii += "\\u%04x" % code
	return ascii.to_ascii_buffer()

func _receive() -> void:
	var budget := READ_BUDGET
	while _listener and _listener.get_available_packet_count() > 0 and budget > 0:
		budget -= 1
		var packet := _listener.get_packet()
		var ip := _listener.get_packet_ip()
		var beacon := parse_beacon(packet)
		if beacon.is_empty() or ip.is_empty() or (not own_id.is_empty() and beacon.id == own_id):
			continue
		_heard(beacon, ip)

## Validates one packet. Returns {} for anything that is not exactly a beacon.
## A beacon from another game version is kept, marked incompatible, as long as
## its magic, version and name are readable.
static func parse_beacon(packet: PackedByteArray) -> Dictionary:
	if packet.is_empty() or packet.size() > MAX_PACKET or packet[0] != 0x7b:
		return {}
	# Outside strings the fixed shape only has short whole numbers. Rejecting
	# fractions and exponents up front also keeps oddities like 1e999 away
	# from the number parser, which would print a warning for each one.
	var in_string := false
	var escaped := false
	var digits := 0
	for byte in packet:
		if byte < 0x20 or byte > 0x7e:
			return {}
		if in_string:
			if escaped: escaped = false
			elif byte == 0x5c: escaped = true
			elif byte == 0x22: in_string = false
			continue
		if byte == 0x22:
			in_string = true
		elif byte >= 0x30 and byte <= 0x39:
			digits += 1
			if digits > 9: return {}
			continue
		elif digits > 0 and byte in [0x2e, 0x45, 0x65]:
			return {}
		digits = 0
	var text := packet.get_string_from_ascii()
	# Escaped control characters (\u0000-\u001f) are never sent; NUL would
	# also make the string decoder print a warning.
	var lower := text.to_lower()
	if lower.contains("\\u000") or lower.contains("\\u001"):
		return {}
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return {}
	var data: Dictionary = json.data
	var magic: Variant = data.get("magic")
	if data.size() > 12 or not magic is String or magic != MAGIC or not _whole(data.get("v"), 0, 1000000) or not data.get("name") is String:
		return {}
	var id: Variant = data.get("id", "")
	var beacon := {
		"name": clean(str(data.name), 16, "PARTY"),
		"id": str(id).left(16) if id is String else "",
		"compatible": int(data.v) == Session.PROTOCOL,
		"port": 0, "players": 0, "max": Session.MAX_PLAYERS, "round": false, "game": ""}
	if not beacon.compatible:
		return beacon
	# Same version: the full fixed shape, with every field in range.
	if data.size() != 9 or beacon.id.is_empty() or not beacon.id.is_valid_hex_number() \
		or not _whole(data.get("port"), 1024, 65535) or not _whole(data.get("max"), 1, 16) \
		or not _whole(data.get("players"), 0, int(data.get("max", 0))) \
		or not data.get("round") is bool or not data.get("game") is String:
		return {}
	beacon.port = int(data.port)
	beacon.players = int(data.players)
	beacon.max = int(data.max)
	beacon.round = data.round
	beacon.game = clean(str(data.game), 24, "")
	return beacon

static func _whole(value: Variant, low: int, high: int) -> bool:
	if not (value is float or value is int):
		return false
	var number := float(value)
	return is_finite(number) and number == floorf(number) and number >= low and number <= high

## Display-safe text: no control or bidi characters, trimmed, length-capped.
static func clean(value: String, limit: int, fallback: String) -> String:
	var out := ""
	for i in value.length():
		var code := value.unicode_at(i)
		if code < 0x20 or (code >= 0x7f and code < 0xa0) or (code >= 0x200b and code <= 0x200f) \
			or (code >= 0x202a and code <= 0x202e) or (code >= 0x2066 and code <= 0x2069):
			continue
		out += value[i]
	out = out.strip_edges().left(limit)
	return out if not out.is_empty() else fallback

func _heard(beacon: Dictionary, ip: String) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	# Incompatible builds may not send an id; key those by address.
	var key: String = beacon.id if not beacon.id.is_empty() else "@" + ip
	var entry: Dictionary = parties.get(key, {})
	if entry.is_empty():
		if parties.size() >= MAX_PARTIES:
			return
		entry = {"addresses": {}, "ip": ip}
		parties[key] = entry
	var before := _shown(entry)
	entry.addresses[ip] = now
	# Keep the first address that worked unless it has gone quiet.
	if now - float(entry.addresses.get(entry.ip, 0.0)) > EXPIRY:
		entry.ip = ip
	for field in beacon:
		entry[field] = beacon[field]
	entry.key = key
	entry.seen = now
	entry.local = entry.ip in _local_ips
	if _shown(entry) != before:
		changed.emit()

func _shown(entry: Dictionary) -> String:
	return "%s|%s|%s|%s|%s|%s|%s" % [entry.get("name"), entry.get("ip"), entry.get("port"), entry.get("players"), entry.get("round"), entry.get("compatible"), entry.get("game")]

func _expire() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var gone := false
	for key in parties.keys():
		var entry: Dictionary = parties[key]
		for ip in entry.addresses.keys():
			if now - float(entry.addresses[ip]) > EXPIRY:
				entry.addresses.erase(ip)
		if entry.addresses.is_empty():
			parties.erase(key)
			gone = true
		elif not entry.addresses.has(entry.ip):
			entry.ip = entry.addresses.keys()[0]
			entry.local = entry.ip in _local_ips
			gone = true
	if gone:
		changed.emit()
