extends SceneTree
## Beacon format, strict validation and soft failure when the port is taken.
## Any push_error here (or engine ERROR output) fails tests/run_tests.py.
const Discovery = preload("res://scripts/discovery.gd")
const Network = preload("res://scripts/session.gd")
var failures := 0

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func bytes(text: String) -> PackedByteArray:
	return text.to_ascii_buffer()

func run() -> void:
	# Round trip, including a name that needs escaping to stay ASCII.
	var packet := Discovery.beacon_bytes("0a1b2c3d", "Zoë 😀", 7777, 3, true, "Spin Cycle")
	check(packet.size() < 200, "Beacons stay small (%d bytes)" % packet.size())
	check(Array(packet).all(func(b): return b >= 0x20 and b <= 0x7e), "Beacons are printable ASCII")
	var beacon := Discovery.parse_beacon(packet)
	check(not beacon.is_empty(), "A real beacon parses")
	check(beacon.get("name") == "Zoë 😀", "Unicode names survive the round trip: %s" % beacon.get("name"))
	check(beacon.get("port") == 7777 and beacon.get("players") == 3 and beacon.get("max") == 6, "Ports and counts survive")
	check(beacon.get("round") == true and beacon.get("compatible") == true and beacon.get("game") == "Spin Cycle", "Round flag, version and game survive")
	var text := packet.get_string_from_ascii()
	for key in ["magic", "v", "id", "name", "port", "players", "max", "round", "game"]:
		check(text.contains("\"%s\"" % key), "Beacon carries %s" % key)
	check(JSON.parse_string(text).size() == 9, "Beacon carries nothing beyond the nine listed fields")

	# Another build: shown, but marked incompatible.
	var old := Discovery.parse_beacon(bytes('{"magic":"GIZMOJAM","v":%d,"name":"OLD"}' % (Network.PROTOCOL + 1)))
	check(old.get("name") == "OLD" and old.get("compatible") == false, "A different protocol is listed as incompatible")

	# Everything else is ignored.
	var good := {"magic": "GIZMOJAM", "v": Network.PROTOCOL, "id": "0a1b2c3d", "name": "X", "port": 7777, "players": 1, "max": 6, "round": false, "game": "Spin Cycle"}
	var bad: Array = [
		PackedByteArray(),
		bytes("x".repeat(600)),
		bytes("{" + " ".repeat(600) + "}"),
		PackedByteArray([0x7b, 0xff, 0xfe, 0x00, 0x7d]),
		bytes("{\"magic\":\"GIZMOJAM\"\n}"),
		bytes("not json"),
		bytes("[1,2,3]"),
		bytes("[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]"),
		bytes("{\"magic\":\"OTHERGAME\",\"v\":1,\"name\":\"X\"}"),
		bytes("{\"magic\":1,\"v\":1,\"name\":\"X\"}"),
		bytes("{\"magic\":\"GIZMOJAM\",\"v\":\"1\",\"name\":\"X\"}"),
		bytes("{\"magic\":\"GIZMOJAM\",\"v\":1.5,\"name\":\"X\"}"),
		bytes("{\"magic\":\"GIZMOJAM\",\"v\":1e999,\"name\":\"X\"}"),
		bytes("{\"magic\":\"GIZMOJAM\",\"v\":2,\"name\":\"\\ud800\"}"),
		bytes("{\"magic\":\"GIZMOJAM\",\"v\":2,\"name\":\"\\udc00x\"}"),
		bytes("{\"magic\":\"GIZMOJAM\",\"v\":2,\"name\":\"\\uZZZZ\"}"),
		bytes("{\"magic\":\"GIZMOJAM\",\"v\":2,\"name\":\"\\u0000ok\"}"),
		bytes("{\"magic\":\"GIZMOJAM\",\"v\":2,\"name\":\"\\U001Bok\"}"),
		bytes("{\"magic\":\"GIZMOJAM\",\"v\":12345678901234567890,\"name\":\"X\"}"),
		# Same version as this build, so it gets the strict shape check.
		bytes("{\"magic\":\"GIZMOJAM\",\"v\":%d,\"name\":\"X\",\"name\":\"Y\",\"a\":{\"b\":[1,2]}}" % Network.PROTOCOL),
	]
	for change in [
		{"port": 80}, {"port": 70000}, {"port": "7777"}, {"port": 7777.5},
		{"players": 7}, {"players": -1}, {"max": 0}, {"max": 99},
		{"round": 1}, {"game": 5}, {"name": 5}, {"id": "not hex!"}, {"id": ""},
		{"extra": "field"}]:
		var shaped := good.duplicate()
		shaped.merge(change, true)
		bad.append(bytes(JSON.stringify(shaped)))
	var missing := good.duplicate()
	missing.erase("port")
	bad.append(bytes(JSON.stringify(missing)))
	for i in bad.size():
		check(Discovery.parse_beacon(bad[i]).is_empty(), "Malformed packet %d must be ignored" % i)
	check(not Discovery.parse_beacon(bytes(JSON.stringify(good))).is_empty(), "The reference beacon is valid")

	# Names are made safe to draw.
	check(Discovery.clean("  " + String.chr(0x202e) + "EVIL" + String.chr(0x200b) + "  ", 16, "P") == "EVIL", "Bidi and zero-width characters are stripped")
	check(Discovery.clean("A".repeat(40), 16, "P").length() == 16, "Names are capped")
	check(Discovery.clean("\t\n", 16, "PARTY") == "PARTY", "Blank names fall back")

	# Directed broadcast guesses skip loopback, link-local and IPv6.
	check(Discovery._directed_broadcast("192.168.1.23") == "192.168.1.255", "/24 directed broadcast")
	check(Discovery._directed_broadcast("127.0.0.1") == "", "Skip loopback")
	check(Discovery._directed_broadcast("169.254.3.4") == "", "Skip link-local")
	check(Discovery._directed_broadcast("fe80::1") == "", "Skip IPv6")

	# A taken discovery port fails softly; a second listener still reports why.
	var squatter := PacketPeerUDP.new()
	check(squatter.bind(0, "0.0.0.0") == OK, "Test socket binds")
	Discovery.port_override = squatter.get_local_port()
	var browser: Node = Discovery.new()
	root.add_child(browser)
	check(browser.browse() == ERR_UNAVAILABLE and browser.status == "busy", "A taken discovery port is reported as busy")
	squatter.close()
	check(browser.browse() == OK and browser.status == "listening", "Browsing starts once the port is free")

	# Loopback: a beacon reaches the listener; the process ignores its own party.
	Discovery.target_override = "127.0.0.1"
	var session: Node = Network.new()
	root.add_child(session)
	check(session.host_game("LOOPBACK", _free_port()) == OK, "Test session hosts")
	var beacon_node: Node = Discovery.new()
	root.add_child(beacon_node)
	check(beacon_node.advertise(session, "Spin Cycle") == OK, "Beacon starts")
	await create_timer(0.3).timeout
	check(browser.parties.is_empty(), "A process does not list the party it is hosting")
	var own := Discovery.own_id
	Discovery.own_id = ""
	await create_timer(1.3).timeout
	check(browser.parties.size() == 1, "A beacon from another process is listed")
	Discovery.own_id = own
	# Closing the session silences the beacon on the next frame.
	session.close()
	await process_frame
	await process_frame
	check(not beacon_node.is_advertising(), "The beacon stops when the session stops hosting")
	# Entries expire after a few seconds of silence.
	await create_timer(Discovery.EXPIRY + 0.6).timeout
	check(browser.parties.is_empty(), "Silent parties expire")
	browser.queue_free()
	beacon_node.queue_free()
	session.queue_free()
	await process_frame
	if failures == 0:
		print("DISCOVERY_UNIT_PASS format-validation-busy-port-own-beacon-expiry")
	quit(1 if failures else 0)

func _free_port() -> int:
	var probe := PacketPeerUDP.new()
	probe.bind(0, "127.0.0.1")
	var value := probe.get_local_port()
	probe.close()
	return value
