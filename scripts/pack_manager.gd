extends Node
## Installed game packs, the signed catalog that vouches for them, and getting
## a game this build lacks when a party picks it.
## Design: docs/specs/game-packs-and-browser-guests.md, sections 4.5 to 6.
##
## Files, under ROOT (user://packs):
##   index.json                     id -> the installed pack (and a pending one)
##   catalog.json                   the newest signed catalog seen
##   games/<id>/<sha256>.pck        installed signed packs
##   received/<sha256>.pck          unsigned packs accepted from a host this run
##   tmp/                           downloads in progress
## Developer packs are dropped into DEV_DIR (user://dev-games).
##
## Trust. A signed pack loads only if a catalog signed with a trusted key lists
## its exact size and SHA-256. An unsigned pack loads only with developer mode
## on: from DEV_DIR at start-up, or from a host after the player agreed to that
## exact file. Every pack is loaded with replace_files off and must keep its
## files inside res://games/<id>/ (PackCore.bad_paths), so it cannot replace
## or add core files. Packs cannot be unloaded: a newer version of a game
## already loaded this run is installed as pending and used after a restart.
##
## Per-game states reported to the party (Session.WAITING_STATES and
## SIT_OUT_STATES): ready, verifying, downloading, asking, needs_update,
## restart, declined, untrusted, failed.

signal status_changed(id: String, state: String, progress: int)
## A game finished loading and is now in the Registry.
signal installed(id: String)
## The host is playing an unsigned game: ask the player (main.gd shows it).
signal consent_needed(id: String, sha256: String, title: String, host_name: String)
## The catalog changed (a newer one was verified).
signal catalog_changed

const Core = preload("res://scripts/update_core.gd")
const PackCore = preload("res://scripts/pack_core.gd")
const Registry = preload("res://scripts/game_registry.gd")
const Keys = preload("res://scripts/update_keys.gd")
const Updater = preload("res://scripts/updater.gd")

const ROOT := "user://packs"
const DEV_DIR := "user://dev-games"
const CONSENT_FILE := "dev-consent.json"
const CATALOG_TIMEOUT := 12.0
const DOWNLOAD_TIMEOUT := 600.0

var root := ROOT
var dev_dir := DEV_DIR
var dev_mode := false
var catalog: Dictionary = {}
var catalog_url := PackCore.CATALOG_URL
var allow_http := false
## Notes from loading, for the developer: "<file>: <reason>".
var problems: Array = []
## Per-game state for the party's current game.
var state := {}
## Tests and debug runs: an extra trusted key {id: pem}.
var extra_keys: Dictionary = {}

var _index: Dictionary = {}
var _target: Dictionary = {}
var _generation := 0
var _http: HTTPRequest
var _download_size := 0
var _last_progress := -1
var _core: Variant = null
var _consent_waiting: Dictionary = {}

func _ready() -> void:
	name = "Packs"
	if OS.is_debug_build():
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--packs-dir="):
				root = arg.trim_prefix("--packs-dir=").path_join("packs")
				dev_dir = arg.trim_prefix("--packs-dir=").path_join("dev-games")
			elif arg.begins_with("--catalog-url="):
				catalog_url = arg.trim_prefix("--catalog-url=")
				allow_http = true
			elif arg.begins_with("--trust-key="):
				# A PEM public key file. Its id is derived as tools/release.py does.
				var pem := FileAccess.get_file_as_string(arg.trim_prefix("--trust-key="))
				if not pem.is_empty(): extra_keys[key_id(pem)] = pem
	set_process(false)

func _exit_tree() -> void:
	_drop_http()

## "gizmojam-" and the first 16 hex digits of the SHA-256 of the DER public
## key: the id tools/release.py gives a signing key.
static func key_id(public_pem: String) -> String:
	var body := ""
	for line in public_pem.split("\n"):
		if not line.begins_with("-----"): body += line.strip_edges()
	var der := Marshalls.base64_to_raw(body)
	return "gizmojam-" + Core.sha256_bytes(der).hex_encode().left(16)

# --- Start-up ---------------------------------------------------------------------

## Loads everything installed: developer packs first (with developer mode on),
## so a game being worked on wins over a published copy of it, then the
## installed signed packs. Call once, before the game modules are built.
func load_all() -> void:
	DirAccess.make_dir_recursive_absolute(root.path_join("games"))
	_remove_tree(root.path_join("tmp"))
	_remove_tree(root.path_join("received"))
	_load_catalog()
	_read_index()
	if dev_mode:
		load_dev_packs()
	_promote_pending()
	for id in _index.keys():
		var rec: Dictionary = _index[id]
		if Registry.has(id):
			if Registry.entry(id).get("trust") == "untrusted":
				problems.append("%s: developer pack used instead of the installed one" % id)
			continue
		var path := _pack_path(id, str(rec.sha256))
		if not FileAccess.file_exists(path) or _file_size(path) != int(rec.size):
			problems.append("%s: installed pack is missing or damaged" % id)
			_index.erase(id)
			continue
		var problem := _load_pack(id, path, "signed", str(rec.sha256), int(rec.size))
		if not problem.is_empty():
			problems.append("%s: %s" % [id, problem])
	_write_index()
	for p in problems: print("[packs] ", p)

func load_dev_packs() -> void:
	DirAccess.make_dir_recursive_absolute(dev_dir)
	var files := DirAccess.get_files_at(dev_dir)
	files.sort()
	for file in files:
		if not file.ends_with(".pck"): continue
		var path := dev_dir.path_join(file)
		var info := PackCore.read_pck(path)
		if info.has("error"):
			problems.append("%s: %s" % [file, info.error])
			continue
		var id := PackCore.pack_game_id(info.files)
		if id.is_empty():
			problems.append("%s: no res://games/<id>/game.json in it" % file)
			continue
		if Registry.has(id):
			problems.append("%s: %s is already loaded" % [file, id])
			continue
		var problem := _load_pack(id, path, "untrusted", Core.sha256_file(path), _file_size(path))
		if not problem.is_empty():
			problems.append("%s: %s" % [file, problem])

## Loads one pack that has passed its trust checks. Returns "" or a reason.
func _load_pack(id: String, path: String, trust: String, sha256: String, size: int) -> String:
	var info := PackCore.read_pck(path)
	if info.has("error"): return str(info.error)
	if PackCore.pack_game_id(info.files) != id: return "pack is not for %s" % id
	var bad := PackCore.bad_paths(info.files, id, core_paths())
	if not bad.is_empty(): return "pack carries files outside its game: " + ", ".join(bad.slice(0, 3))
	if not ProjectSettings.load_resource_pack(path, false): return "Godot could not load the pack"
	var entry := PackCore.read_game_json(id, trust, sha256, size)
	if entry.has("error"): return str(entry.error)
	if int(entry.core_min) > Core.local_build(): return "needs a newer Gizmo Jam (build %d)" % int(entry.core_min)
	entry["file"] = path
	var problem := Registry.register(entry)
	if not problem.is_empty(): return problem
	return ""

func core_paths() -> Dictionary:
	if _core == null: _core = PackCore.core_paths()
	return _core

# --- Catalog ----------------------------------------------------------------------

func trusted_keys() -> Dictionary:
	var keys := Keys.KEYS.duplicate()
	var file := FileAccess.open(Updater.TRUST_PATH, FileAccess.READ)
	if file:
		var saved: Variant = JSON.parse_string(file.get_as_text())
		if typeof(saved) == TYPE_DICTIONARY:
			for id in saved:
				if typeof(saved[id]) == TYPE_STRING and not keys.has(id): keys[id] = saved[id]
	keys.merge(extra_keys)
	return keys

func _load_catalog() -> void:
	var path := root.path_join("catalog.json")
	if not FileAccess.file_exists(path): return
	var opened := PackCore.open_catalog(FileAccess.get_file_as_bytes(path), trusted_keys(), Core.CHANNEL, allow_http)
	if opened.ok: catalog = opened.catalog
	else: problems.append("saved catalog: " + str(opened.error))

## Takes a catalog envelope from anywhere (the download server or a host).
## Keeps it if it verifies and is not older than the one we have. Returns
## "" or why it was refused.
func adopt_catalog(bytes: PackedByteArray) -> String:
	var opened := PackCore.open_catalog(bytes, trusted_keys(), Core.CHANNEL, allow_http)
	if not opened.ok: return str(opened.error)
	var serial := int(opened.catalog.serial)
	if not catalog.is_empty() and serial < int(catalog.serial):
		return "catalog %d is older than %d" % [serial, int(catalog.serial)]
	if not catalog.is_empty() and serial == int(catalog.serial): return ""
	catalog = opened.catalog
	var file := FileAccess.open(root.path_join("catalog.json"), FileAccess.WRITE)
	if file:
		file.store_buffer(bytes)
		file.close()
	catalog_changed.emit()
	return ""

func catalog_file() -> String:
	var path := root.path_join("catalog.json")
	return path if FileAccess.file_exists(path) else ""

## Fetches the published catalog. Quietly does nothing when offline.
func refresh_catalog() -> void:
	var bytes := await _fetch(catalog_url, PackCore.MAX_CATALOG, CATALOG_TIMEOUT)
	if not bytes.is_empty():
		var problem := adopt_catalog(bytes)
		if not problem.is_empty(): print("[packs] catalog from %s refused: %s" % [catalog_url, problem])

# --- Installed packs --------------------------------------------------------------

func _pack_path(id: String, sha256: String) -> String:
	return root.path_join("games").path_join(id).path_join(sha256 + ".pck")

func _read_index() -> void:
	var path := root.path_join("index.json")
	if not FileAccess.file_exists(path): return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY: return
	for id in data:
		var rec: Variant = data[id]
		if Registry.valid_id(id) and typeof(rec) == TYPE_DICTIONARY and Core.is_sha256(rec.get("sha256")):
			_index[id] = rec

func _write_index() -> void:
	var file := FileAccess.open(root.path_join("index.json"), FileAccess.WRITE)
	if file: file.store_string(JSON.stringify(_index, "  "))

## A newer version downloaded last run becomes the installed one.
func _promote_pending() -> void:
	for id in _index.keys():
		var rec: Dictionary = _index[id]
		var pending: Dictionary = rec.get("pending", {})
		if pending.is_empty(): continue
		if FileAccess.file_exists(_pack_path(id, str(pending.sha256))):
			if str(rec.sha256) != str(pending.sha256):
				DirAccess.remove_absolute(_pack_path(id, str(rec.sha256)))
			_index[id] = pending
		else:
			rec.erase("pending")

## Installed signed games: id -> {sha256, size, version, net}.
func installed_packs() -> Dictionary:
	return _index.duplicate(true)

## Removes an installed game. It stays playable until the game restarts.
func remove(id: String) -> void:
	var rec: Dictionary = _index.get(id, {})
	if rec.is_empty(): return
	for sha in [str(rec.sha256), str(rec.get("pending", {}).get("sha256", ""))]:
		if not sha.is_empty(): DirAccess.remove_absolute(_pack_path(id, sha))
	_index.erase(id)
	_write_index()

## What the host's file server hands out: url path -> file.
func servable() -> Dictionary:
	var routes := {}
	for id in Registry.ids():
		var e := Registry.entry(id)
		if e.has("file") and Core.is_sha256(e.get("sha256", "")):
			routes["/packs/%s.pck" % e.sha256] = e.file
	if not catalog_file().is_empty():
		routes["/catalog"] = catalog_file()
	return routes

# --- Getting the party's game -----------------------------------------------------

## The party is playing `id`; the host advertised `host_entry` (net, sha256,
## trust, size, core_min, info). Brings this build to "ready" if it can,
## reporting progress with status_changed. Safe to call on every party
## update: it only starts work when the game or the host's file changes.
## `host_files` is {"ip", "port"} of the host's file server, or {}.
func acquire(id: String, host_entry: Dictionary, host_files: Dictionary, host_name: String) -> void:
	var target := {"id": id, "sha256": str(host_entry.get("sha256", "")), "net": int(host_entry.get("net", 0))}
	if target == _target:
		var current: Dictionary = state.get(id, {})
		if not current.is_empty(): status_changed.emit(id, current.state, current.progress)
		return
	_cancel()
	_target = target
	_generation += 1
	var generation := _generation
	if Registry.compatible(Registry.capabilities(), id, host_entry):
		_report(id, "ready")
		return
	if int(host_entry.get("core_min", 0)) > Core.local_build():
		_report(id, "needs_update")
		return
	if str(host_entry.get("trust", "")) == "untrusted":
		_acquire_untrusted(id, host_entry, host_files, host_name, generation)
		return
	var sha := str(host_entry.get("sha256", ""))
	var entry := PackCore.entry_for(catalog, id, sha)
	if entry.is_empty() and not host_files.is_empty():
		# The host's catalog may be newer than ours.
		_report(id, "verifying")
		var bytes := await _fetch("http://%s:%d/catalog" % [host_files.ip, int(host_files.port)], PackCore.MAX_CATALOG, CATALOG_TIMEOUT)
		if generation != _generation: return
		if not bytes.is_empty(): adopt_catalog(bytes)
		entry = PackCore.entry_for(catalog, id, sha)
	if entry.is_empty():
		_report(id, "verifying")
		await refresh_catalog()
		if generation != _generation: return
		entry = PackCore.entry_for(catalog, id, sha)
	if entry.is_empty():
		_report(id, "failed", 0, "not in the signed catalog")
		return
	if int(entry.core_min) > Core.local_build():
		_report(id, "needs_update")
		return
	var pending: Dictionary = _index.get(id, {}).get("pending", {})
	if Registry.has(id) and str(pending.get("sha256", "")) == sha:
		_report(id, "restart")
		return
	var sources: Array = []
	if not host_files.is_empty():
		sources.append("http://%s:%d/packs/%s.pck" % [host_files.ip, int(host_files.port), sha])
	sources.append(str(entry.url))
	var part := await _download(id, sources, int(entry.size), generation)
	if generation != _generation: return
	if part.is_empty():
		_report(id, "failed", 0, "could not download it")
		return
	_report(id, "verifying")
	var problem := await _verify(part, id, int(entry.size), sha, generation)
	if generation != _generation: return
	if not problem.is_empty():
		DirAccess.remove_absolute(part)
		_report(id, "failed", 0, problem)
		return
	var final_path := _pack_path(id, sha)
	DirAccess.make_dir_recursive_absolute(final_path.get_base_dir())
	DirAccess.rename_absolute(part, final_path)
	var rec := {"sha256": sha, "size": int(entry.size), "version": str(entry.version), "net": int(entry.net)}
	if Registry.has(id):
		# A different version is loaded and cannot be unloaded.
		var current: Dictionary = _index.get(id, {})
		if current.is_empty(): current = rec.duplicate()
		current["pending"] = rec
		_index[id] = current
		_write_index()
		_report(id, "restart")
		return
	_index[id] = rec
	_write_index()
	var load_problem := _load_pack(id, final_path, "signed", sha, int(entry.size))
	if not load_problem.is_empty():
		_report(id, "failed", 0, load_problem)
		return
	installed.emit(id)
	_report(id, "ready")

## Installs a game from the catalog for solo play (the game library).
func install(id: String) -> void:
	var entry: Dictionary = catalog.get("games", {}).get(id, {})
	if entry.is_empty(): return
	acquire(id, {"net": entry.net, "sha256": entry.sha256, "trust": "signed", "size": entry.size, "core_min": entry.core_min}, {}, "")

func _acquire_untrusted(id: String, host_entry: Dictionary, host_files: Dictionary, host_name: String, generation: int) -> void:
	var sha := str(host_entry.get("sha256", ""))
	var size := int(host_entry.get("size", 0))
	if not dev_mode:
		_report(id, "untrusted")
		return
	if not Core.is_sha256(sha) or size < 1 or size > PackCore.MAX_PACK or host_files.is_empty():
		_report(id, "failed", 0, "the host did not offer the file")
		return
	if Registry.has(id):
		# Some other copy of this game is loaded already.
		_report(id, "restart")
		return
	if not _consented(sha):
		_report(id, "asking")
		_consent_waiting = {"sha256": sha, "generation": generation}
		consent_needed.emit(id, sha, str(host_entry.get("info", {}).get("title", id.to_upper())), host_name)
		var agreed: bool = await _consent_answer()
		if generation != _generation: return
		if not agreed:
			_report(id, "declined")
			return
		_remember_consent(sha)
	var part := await _download(id, ["http://%s:%d/packs/%s.pck" % [host_files.ip, int(host_files.port), sha]], size, generation)
	if generation != _generation: return
	if part.is_empty():
		_report(id, "failed", 0, "could not download it from the host")
		return
	_report(id, "verifying")
	var problem := await _verify(part, id, size, sha, generation)
	if generation != _generation: return
	if not problem.is_empty():
		DirAccess.remove_absolute(part)
		_report(id, "failed", 0, problem)
		return
	var final_path := root.path_join("received").path_join(sha + ".pck")
	DirAccess.make_dir_recursive_absolute(final_path.get_base_dir())
	DirAccess.rename_absolute(part, final_path)
	var load_problem := _load_pack(id, final_path, "untrusted", sha, size)
	if not load_problem.is_empty():
		_report(id, "failed", 0, load_problem)
		return
	installed.emit(id)
	_report(id, "ready")

signal _consent_answered(yes: bool)

func _consent_answer() -> bool:
	var yes: bool = await _consent_answered
	return yes

## The player's answer to consent_needed.
func answer_consent(sha256: String, yes: bool) -> void:
	if _consent_waiting.get("sha256", "") != sha256: return
	_consent_waiting = {}
	_consent_answered.emit(yes)

## Which unsigned packs this player agreed to, by SHA-256.
func _consent_path() -> String:
	return root.path_join(CONSENT_FILE)

func _consented(sha256: String) -> bool:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(_consent_path())) if FileAccess.file_exists(_consent_path()) else null
	return typeof(data) == TYPE_DICTIONARY and data.has(sha256)

func _remember_consent(sha256: String) -> void:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(_consent_path())) if FileAccess.file_exists(_consent_path()) else {}
	if typeof(data) != TYPE_DICTIONARY: data = {}
	data[sha256] = Time.get_datetime_string_from_system(true)
	var file := FileAccess.open(_consent_path(), FileAccess.WRITE)
	if file: file.store_string(JSON.stringify(data, "  "))

## Stops whatever acquire() was doing (the party changed game or ended).
func reset() -> void:
	_cancel()
	_target = {}
	state.clear()

func _cancel() -> void:
	_generation += 1
	_drop_http()
	if not _consent_waiting.is_empty():
		_consent_waiting = {}
		_consent_answered.emit(false)

func _report(id: String, value: String, progress: int = 0, reason: String = "") -> void:
	state[id] = {"state": value, "progress": progress, "reason": reason}
	if not reason.is_empty(): print("[packs] %s: %s (%s)" % [id, value, reason])
	status_changed.emit(id, value, progress)

func status(id: String) -> Dictionary:
	return state.get(id, {})

# --- Network and verification -----------------------------------------------------

## Downloads from the first source that works into tmp/. Returns the file
## path, or "" if every source failed.
func _download(id: String, sources: Array, size: int, generation: int) -> String:
	DirAccess.make_dir_recursive_absolute(root.path_join("tmp"))
	var part := root.path_join("tmp").path_join("%s-%d.part" % [id, generation])
	for url in sources:
		_report(id, "downloading", 0)
		_drop_http()
		_http = HTTPRequest.new()
		_http.timeout = DOWNLOAD_TIMEOUT
		_http.body_size_limit = size
		_http.download_file = part
		_http.use_threads = not OS.has_feature("web")
		add_child(_http)
		_download_size = size
		_last_progress = -1
		set_process(true)
		if _http.request(str(url)) != OK:
			_drop_http()
			continue
		var result: Array = await _http.request_completed
		if generation != _generation: return ""
		_drop_http()
		if result[0] == HTTPRequest.RESULT_SUCCESS and result[1] == 200 and _file_size(part) == size:
			return part
		print("[packs] %s: download from %s failed (result %d, HTTP %d)" % [id, url, result[0], result[1]])
		DirAccess.remove_absolute(part)
	return ""

func _process(_delta: float) -> void:
	if not is_instance_valid(_http):
		set_process(false)
		return
	var pct := clampi(int(_http.get_downloaded_bytes() * 100.0 / maxf(1.0, _download_size)), 0, 99)
	if pct != _last_progress:
		_last_progress = pct
		var id := str(_target.get("id", ""))
		state[id] = {"state": "downloading", "progress": pct, "reason": ""}
		status_changed.emit(id, "downloading", pct)

## Fetches a small file into memory; empty on any failure.
func _fetch(url: String, limit: int, timeout: float) -> PackedByteArray:
	var http := HTTPRequest.new()
	http.timeout = timeout
	http.body_size_limit = limit
	add_child(http)
	if http.request(url) != OK:
		http.queue_free()
		return PackedByteArray()
	var result: Array = await http.request_completed
	http.queue_free()
	if result[0] != HTTPRequest.RESULT_SUCCESS or result[1] != 200: return PackedByteArray()
	return result[3]

## Size, hash and file-table checks on a worker thread.
func _verify(path: String, id: String, size: int, sha256: String, generation: int) -> String:
	var core := core_paths()
	var thread := Thread.new()
	thread.start(func(): return PackCore.verify_pack(ProjectSettings.globalize_path(path), id, size, sha256, core))
	while thread.is_alive():
		await get_tree().process_frame
	var problem: String = thread.wait_to_finish()
	if generation != _generation: return "cancelled"
	return problem

func _drop_http() -> void:
	if is_instance_valid(_http):
		_http.cancel_request()
		_http.queue_free()
	_http = null

func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_length() if file else -1

func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path): return
	for file in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file))
	for dir in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(dir))
	DirAccess.remove_absolute(path)
