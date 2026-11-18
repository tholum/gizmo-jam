extends Node
## The party host's file server: hands members the game packs they lack, the
## signed catalog that vouches for them, and (with browser guests on) the
## browser build. Plain HTTP on the LAN: nothing served is secret, and every
## pack is checked against the signed catalog by whoever downloads it.
##
## Accepting and sending run on worker threads, never the main thread, so a
## transfer cannot stall the host's frame loop (measured: docs/specs, T8).
## Only exact paths registered with serve() are answered; anything else is a
## 404. At most MAX_CONNECTIONS transfers run at once, and while `throttle` is
## set (a round is on) each is held to THROTTLED_RATE.

const DEFAULT_PORT := 7780
const PORT_TRIES := 10
const MAX_CONNECTIONS := 8
const MAX_REQUEST := 8192
const REQUEST_TIMEOUT_MS := 5000
const STALL_TIMEOUT_MS := 15000
const CHUNK := 65536
## Bytes per second per transfer while a round is being played.
const THROTTLED_RATE := 2 * 1024 * 1024

var port := 0
## Set while a round is on: transfers slow down to leave the network to the game.
var throttle := false:
	set(value):
		_mutex.lock()
		throttle = value
		_throttled = value
		_mutex.unlock()

var _server: TCPServer
var _thread: Thread
var _running := false
var _throttled := false
var _mutex := Mutex.new()
## url path -> {"file": absolute path, "type": content type, "gzip": absolute path or ""}
var _routes: Dictionary = {}
var _workers: Array = []
## Tests: requests answered, by path.
var served: Dictionary = {}

func _exit_tree() -> void:
	stop()

## Starts listening on the first free TCP port from `first_port`. Returns the
## port, or 0 if none could be opened.
func start(first_port: int = DEFAULT_PORT) -> int:
	stop()
	for p in range(first_port, first_port + PORT_TRIES):
		var server := TCPServer.new()
		if server.listen(p, "*") == OK:
			_server = server
			port = p
			break
	if _server == null:
		return 0
	_running = true
	_thread = Thread.new()
	_thread.start(_accept_loop)
	return port

func stop() -> void:
	if _thread:
		_running = false
		_thread.wait_to_finish()
		_thread = null
	for worker in _workers:
		worker.wait_to_finish()
	_workers.clear()
	if _server:
		_server.stop()
		_server = null
	port = 0

func is_running() -> bool:
	return _running

## Answers GET `url_path` with the file at `file` (user:// or res:// paths are
## fine). `gzip_file`, if given, is a gzip copy sent to clients that accept it.
func serve(url_path: String, file: String, content_type: String = "application/octet-stream", gzip_file: String = "") -> void:
	_mutex.lock()
	_routes[url_path] = {"file": ProjectSettings.globalize_path(file), "type": content_type,
		"gzip": ProjectSettings.globalize_path(gzip_file) if not gzip_file.is_empty() else ""}
	_mutex.unlock()

func unserve(url_path: String) -> void:
	_mutex.lock()
	_routes.erase(url_path)
	_mutex.unlock()

func unserve_prefix(prefix: String) -> void:
	_mutex.lock()
	for key in _routes.keys():
		if str(key).begins_with(prefix): _routes.erase(key)
	_mutex.unlock()

func _accept_loop() -> void:
	while _running:
		# Reap finished transfers.
		for worker in _workers.duplicate():
			if not worker.is_alive():
				worker.wait_to_finish()
				_workers.erase(worker)
		if _server.is_connection_available():
			var peer := _server.take_connection()
			if _workers.size() >= MAX_CONNECTIONS:
				_respond_status(peer, 503, "Busy")
				peer.disconnect_from_host()
				continue
			var worker := Thread.new()
			_workers.append(worker)
			worker.start(_handle.bind(peer))
		else:
			OS.delay_msec(10)

func _handle(peer: StreamPeerTCP) -> void:
	var request := _read_request(peer)
	if request.is_empty():
		peer.disconnect_from_host()
		return
	_mutex.lock()
	var route: Dictionary = _routes.get(request.path, {})
	if not route.is_empty():
		served[request.path] = int(served.get(request.path, 0)) + 1
	_mutex.unlock()
	if request.method != "GET" and request.method != "HEAD":
		_respond_status(peer, 405, "Method Not Allowed")
	elif route.is_empty():
		_respond_status(peer, 404, "Not Found")
	else:
		var use_gzip: bool = not str(route.gzip).is_empty() and request.gzip and FileAccess.file_exists(route.gzip)
		_send_file(peer, route.gzip if use_gzip else route.file, route.type, use_gzip, request.method == "HEAD")
	peer.disconnect_from_host()

## {"method", "path", "gzip"} or {} for anything that is not a short HTTP request.
func _read_request(peer: StreamPeerTCP) -> Dictionary:
	var buffer := PackedByteArray()
	var deadline := Time.get_ticks_msec() + REQUEST_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline and _running:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED: return {}
		var available := peer.get_available_bytes()
		if available > 0:
			var got: Array = peer.get_partial_data(mini(available, MAX_REQUEST - buffer.size()))
			if got[0] != OK: return {}
			buffer.append_array(got[1])
			var text := buffer.get_string_from_ascii()
			var end := text.find("\r\n\r\n")
			if end >= 0:
				var lines := text.substr(0, end).split("\r\n")
				var parts := lines[0].split(" ")
				if parts.size() != 3 or not parts[2].begins_with("HTTP/1."): return {}
				var gzip := false
				for line in lines.slice(1):
					var lower := line.to_lower()
					if lower.begins_with("accept-encoding:") and "gzip" in lower: gzip = true
				# Query strings are ignored; paths are matched exactly.
				return {"method": parts[0], "path": parts[1].get_slice("?", 0), "gzip": gzip}
			if buffer.size() >= MAX_REQUEST: return {}
		else:
			OS.delay_msec(5)
	return {}

func _respond_status(peer: StreamPeerTCP, code: int, text: String) -> void:
	var body := ("%d %s\n" % [code, text]).to_ascii_buffer()
	var head := "HTTP/1.1 %d %s\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [code, text, body.size()]
	_write(peer, head.to_ascii_buffer())
	_write(peer, body)

func _send_file(peer: StreamPeerTCP, path: String, content_type: String, gzipped: bool, head_only: bool) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_respond_status(peer, 404, "Not Found")
		return
	var size := file.get_length()
	var head := "HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n" % [content_type, size]
	if gzipped: head += "Content-Encoding: gzip\r\nVary: Accept-Encoding\r\n"
	if not _write(peer, (head + "\r\n").to_ascii_buffer()) or head_only: return
	var started := Time.get_ticks_msec()
	var sent := 0
	while sent < size and _running:
		var chunk := file.get_buffer(mini(CHUNK, size - sent))
		if chunk.is_empty() or not _write(peer, chunk): return
		sent += chunk.size()
		_mutex.lock()
		var slow := _throttled
		_mutex.unlock()
		if slow:
			# Hold the average to THROTTLED_RATE since the transfer began.
			var due := int(float(sent) / THROTTLED_RATE * 1000.0)
			var elapsed := Time.get_ticks_msec() - started
			if due > elapsed: OS.delay_msec(mini(due - elapsed, 500))

## Writes all of `data`, giving up if the client stops reading for
## STALL_TIMEOUT_MS or the server stops.
func _write(peer: StreamPeerTCP, data: PackedByteArray) -> bool:
	var offset := 0
	var stalled_since := Time.get_ticks_msec()
	while offset < data.size():
		if not _running: return false
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED: return false
		var result: Array = peer.put_partial_data(data.slice(offset, mini(offset + CHUNK, data.size())))
		if result[0] != OK: return false
		var count: int = result[1]
		if count > 0:
			offset += count
			stalled_since = Time.get_ticks_msec()
		else:
			if Time.get_ticks_msec() - stalled_since > STALL_TIMEOUT_MS: return false
			OS.delay_msec(2)
	return true
