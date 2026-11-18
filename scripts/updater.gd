extends Node
## Background update check and in-game self-update.
##
## On launch it fetches the signed manifest once (short timeout, never blocks the
## menu, silent on failure). When a newer build exists for this platform it
## reports it through `changed`; UpdateNotice draws the card. "Update now"
## downloads to user://, checks size and SHA-256 against the signed manifest,
## swaps the files in place (see UpdateCore.plan_swap), starts the new version
## and waits for it to reach the menu. If the new version exits before then, the
## previous one is put back. Manifest format and swap plans: update_core.gd.

const Core = preload("res://scripts/update_core.gd")
const Keys = preload("res://scripts/update_keys.gd")
const Notice = preload("res://scripts/update_notice.gd")

signal changed
signal progress(done: int, total: int)

const STATE_PATH := "user://update_state.json"
const STARTED_PATH := "user://update_started.json"
const TRUST_PATH := "user://update_keys.json"
const DOWNLOAD_DIR := "user://updates"
const CHECK_DELAY := 1.0
const CHECK_TIMEOUT := 8.0
const STALL_TIMEOUT := 30.0
const SUPERVISE_TIMEOUT := 90.0
const BUSY := ["downloading", "verifying", "ready", "installing", "restarting"]

## User setting "Check for updates". Off: no check, no card.
var enabled := true
## idle, checking, available, downloading, verifying, ready, installing,
## restarting, error. "ready": verified, waiting until installing (which
## restarts the game) would not interrupt a round or an online party.
var state := "idle"
var manifest := {}
## This platform's entry from the manifest: url, size, sha256.
var entry := {}
var message := ""
## False when "Update now" cannot work here; `block` says why ("dev" from source).
var can_apply := false
var block := ""
var notes_open := false
var dismissed_build := -1
var done_bytes := 0
var total_bytes := 0
## Test hook (--update-autoclick): the card presses its own Update button.
var autoclick := false
var manifest_url := Core.MANIFEST_URL
var channel := Core.CHANNEL
var overridden := false
var checked := false

var _on_toggle := Callable()
var _install_allowed := Callable()
var _http: HTTPRequest
var _part := ""
var _plan := {}
var _stall_bytes := 0
var _stall_time := 0.0
var _pid := -1
var _launched_at := 0.0
var _supervise_left := 0.0
var _poll := 0.0
var _started_marked := false
var _cleanup_tries := 0

## `on_toggle(bool)` persists the setting; `install_allowed()` is false while a
## party is online, so installing (which restarts the game) never interrupts it.
func setup(check_enabled: bool, on_toggle: Callable = Callable(), install_allowed: Callable = Callable()) -> void:
	enabled = check_enabled
	_on_toggle = on_toggle
	_install_allowed = install_allowed

func _ready() -> void:
	name = "Updater"
	set_process(false)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--update-manifest="):
			manifest_url = arg.trim_prefix("--update-manifest=")
			overridden = true
		elif arg.begins_with("--update-channel="):
			channel = arg.trim_prefix("--update-channel=")
		elif arg == "--update-autoclick":
			autoclick = true
	_log("Gizmo Jam v%s build %d (%s)" % [Core.local_version(), Core.local_build(), "exported" if _exported() else "source"])
	if _exported():
		_recover_on_start()
	# Test runners (a scripted SceneTree) never touch the network on their own.
	var scripted: bool = Engine.get_main_loop().get_script() != null
	if enabled and not scripted and not "--no-update-check" in OS.get_cmdline_user_args():
		get_tree().create_timer(CHECK_DELAY).timeout.connect(check)

## Adds the version tag and, when relevant, the update card to a menu-like
## screen. `where` is "menu", "lobby" or "results". Reaching the menu also
## confirms that a freshly installed version started correctly.
func decorate(parent: Control, where: String) -> void:
	var notice := Notice.new()
	notice.setup(self, where)
	parent.add_child(notice)
	if where == "menu":
		mark_started()

func install_allowed() -> bool:
	return _install_allowed.is_null() or bool(_install_allowed.call())

## True when the card should be on screen.
func showing() -> bool:
	if state in BUSY or state == "error": return true
	return enabled and state == "available" and dismissed_build != int(manifest.get("build", -1))

func set_enabled(on: bool) -> void:
	enabled = on
	if not _on_toggle.is_null():
		_on_toggle.call(on)
	if on and state == "idle" and not checked:
		check()
	changed.emit()

func later() -> void:
	dismissed_build = int(manifest.get("build", -1))
	notes_open = false
	changed.emit()

func toggle_notes() -> void:
	notes_open = not notes_open
	changed.emit()

func dismiss_error() -> void:
	state = "available" if not entry.is_empty() else "idle"
	message = ""
	if state == "available":
		dismissed_build = int(manifest.get("build", -1))
	changed.emit()

func open_download_page() -> void:
	OS.shell_open(str(manifest.get("download_page", Core.DOWNLOAD_PAGE)))

# --- Check ----------------------------------------------------------------------

func check() -> void:
	if state != "idle" or not is_inside_tree(): return
	checked = true
	state = "checking"
	var http := HTTPRequest.new()
	http.timeout = CHECK_TIMEOUT
	http.body_size_limit = Core.MAX_ENVELOPE_BYTES
	http.use_threads = true
	add_child(http)
	http.request_completed.connect(_on_manifest.bind(http))
	var err := http.request(manifest_url, _headers())
	if err != OK:
		http.queue_free()
		_quiet_idle("update check could not start (error %d)" % err)

func _on_manifest(result: int, code: int, _headers_in: PackedStringArray, body: PackedByteArray, http: HTTPRequest) -> void:
	http.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_quiet_idle("update check failed (result %d, HTTP %d)" % [result, code])
		return
	apply_envelope(body)

## Verifies a downloaded envelope and updates the state. Public for tests.
func apply_envelope(body: PackedByteArray) -> bool:
	var opened := Core.open_envelope(body, trusted_keys(), Core.GAME_ID, channel, overridden)
	if not opened.ok:
		_quiet_idle("manifest rejected: " + str(opened.error))
		return false
	manifest = opened.manifest
	_remember_next_key(manifest)
	entry = Core.offer(manifest, Core.local_build(), Core.platform_key())
	if entry.is_empty():
		_quiet_idle("up to date (latest v%s build %d)" % [manifest.version, manifest.build])
		return true
	_evaluate()
	state = "available"
	_log("update available: v%s build %d%s" % [manifest.version, manifest.build, "" if can_apply else " (" + block + ")"])
	changed.emit()
	return true

func _evaluate() -> void:
	can_apply = false
	block = ""
	if not _exported():
		block = "dev"
	elif Core.local_build() < int(manifest.get("min_updater_build", 0)):
		block = "This update has to be installed from the download page."
	else:
		_plan = Core.plan_swap(Core.platform_key(), OS.get_executable_path())
		if not _plan.ok:
			block = "Can't update in place: %s." % _plan.error
		else:
			can_apply = true

## Embedded keys plus any announced by a verified manifest's `next_key`.
func trusted_keys() -> Dictionary:
	var keys := Keys.KEYS.duplicate()
	var saved: Variant = _read_json(TRUST_PATH)
	if typeof(saved) == TYPE_DICTIONARY:
		for id in saved:
			if typeof(saved[id]) == TYPE_STRING and not keys.has(id):
				keys[id] = saved[id]
	return keys

func _remember_next_key(m: Dictionary) -> void:
	var next: Dictionary = m.get("next_key", {})
	if next.is_empty() or Keys.KEYS.has(next.id): return
	var saved: Variant = _read_json(TRUST_PATH)
	var keys: Dictionary = saved if typeof(saved) == TYPE_DICTIONARY else {}
	if keys.get(next.id) == next.public_key: return
	keys[next.id] = next.public_key
	_write_json(TRUST_PATH, keys)
	_log("trusting announced release key " + next.id)

# --- Download and verify -------------------------------------------------------

func start_update() -> void:
	if state != "available": return
	if not can_apply:
		_fail(block if block != "dev" else "Updates install only in the exported game.")
		return
	if not install_allowed():
		_fail("Leave the party first: installing restarts the game.")
		return
	_plan = Core.plan_swap(Core.platform_key(), OS.get_executable_path())
	if not _plan.ok:
		_fail("Can't update in place: %s." % _plan.error)
		return
	if not _dir_writable(_plan.dir):
		_fail("Gizmo Jam can't write to its folder (%s)." % _plan.dir)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DOWNLOAD_DIR))
	_part = ProjectSettings.globalize_path(DOWNLOAD_DIR).path_join("%s-%d.part" % [_plan.platform, int(manifest.build)])
	if FileAccess.file_exists(_part):
		DirAccess.remove_absolute(_part)
	_http = HTTPRequest.new()
	_http.download_file = _part
	_http.body_size_limit = int(entry.size)
	_http.download_chunk_size = 1 << 16
	_http.use_threads = true
	add_child(_http)
	_http.request_completed.connect(_on_download)
	var err := _http.request(str(entry.url), _headers())
	if err != OK:
		_drop_http()
		_fail("The download could not start (error %d)." % err)
		return
	done_bytes = 0
	total_bytes = int(entry.size)
	_stall_bytes = 0
	_stall_time = 0.0
	notes_open = false
	state = "downloading"
	_log("downloading " + str(entry.url))
	set_process(true)
	changed.emit()

func cancel() -> void:
	if state != "downloading": return
	_drop_http()
	_remove(_part)
	state = "available"
	set_process(false)
	_log("download cancelled")
	changed.emit()

func _on_download(result: int, code: int, _headers_in: PackedStringArray, _body: PackedByteArray) -> void:
	_drop_http()
	if state != "downloading": return
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_remove(_part)
		_fail("The download failed (%s). Nothing was changed." % _describe(result, code))
		return
	done_bytes = total_bytes
	progress.emit(done_bytes, total_bytes)
	state = "verifying"
	changed.emit()
	var problem := await _check_async(_part, int(entry.size), str(entry.sha256))
	if problem != "":
		_remove(_part)
		_fail("The download did not match the signed manifest (%s). Nothing was changed." % problem)
		return
	_log("download verified: %d bytes, sha256 %s" % [int(entry.size), entry.sha256])
	if install_allowed():
		install_now()
	else:
		state = "ready"
		_log("ready to install once the round or party is over")
		changed.emit()

## Installs the verified download and restarts into it.
func install_now() -> void:
	if not state in ["verifying", "ready"] or not install_allowed(): return
	state = "installing"
	changed.emit()
	await get_tree().process_frame
	var problem := await _install()
	if problem != "":
		_fail(problem)
		return
	_relaunch()

func _process(delta: float) -> void:
	if state == "downloading" and is_instance_valid(_http):
		done_bytes = _http.get_downloaded_bytes()
		progress.emit(done_bytes, total_bytes)
		if done_bytes != _stall_bytes:
			_stall_bytes = done_bytes
			_stall_time = 0.0
		else:
			_stall_time += delta
			if _stall_time > STALL_TIMEOUT:
				_drop_http()
				_remove(_part)
				_fail("The download stalled. Check your connection and try again.")
	elif state == "restarting":
		_supervise(delta)

## Size first, then SHA-256 in 1 MiB chunks, yielding so the UI keeps drawing.
func _check_async(path: String, size: int, sha256: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return "file is missing"
	if file.get_length() != size:
		return "size %d, expected %d" % [file.get_length(), size]
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var chunks := 0
	while file.get_position() < file.get_length():
		ctx.update(file.get_buffer(1 << 20))
		chunks += 1
		if chunks % 16 == 0:
			await get_tree().process_frame
	file.close()
	if ctx.finish().hex_encode() != sha256.to_lower():
		return "SHA-256 mismatch"
	return ""

# --- Install --------------------------------------------------------------------

## Swaps the verified download into place. Returns "" or a player-facing error.
## The previous version is always kept as `backup` until the new one has run.
func _install() -> String:
	var plan := _plan
	_remove(plan.staging)
	if plan.kind == "bundle":
		# Files are re-checked after copying; the zip is checked again right
		# before it is unpacked, in case it waited in "ready".
		var again := await _check_async(_part, int(entry.size), str(entry.sha256))
		if again != "":
			return _fallback("The download changed after it was verified (%s)." % again)
	if plan.kind == "file":
		if DirAccess.copy_absolute(_part, plan.staging) != OK:
			_remove(plan.staging)
			return _fallback("Could not write the new version next to the game.")
		var staged := await _check_async(plan.staging, int(entry.size), str(entry.sha256))
		if staged != "":
			_remove(plan.staging)
			return _fallback("The copied update was damaged (%s). Nothing was changed." % staged)
		if plan.platform == "linux":
			FileAccess.set_unix_permissions(plan.staging, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER | FileAccess.UNIX_EXECUTE_OWNER | FileAccess.UNIX_READ_GROUP | FileAccess.UNIX_EXECUTE_GROUP | FileAccess.UNIX_READ_OTHER | FileAccess.UNIX_EXECUTE_OTHER)
			_remove(plan.backup)
			if DirAccess.copy_absolute(plan.target, plan.backup) != OK:
				_remove(plan.staging)
				return _fallback("Could not keep a copy of the current version.")
			_save_state("swapped")
			if DirAccess.rename_absolute(plan.staging, plan.target) != OK:
				_remove(plan.staging)
				_clear_state()
				return _fallback("Could not replace the game file.")
		else:
			# Windows: a running exe cannot be overwritten, but it can be renamed.
			if FileAccess.file_exists(plan.backup) and DirAccess.remove_absolute(plan.backup) != OK:
				_remove(plan.staging)
				return _fallback("An older copy of the game (%s) is still in use." % plan.backup.get_file())
			_save_state("swapped")
			if DirAccess.rename_absolute(plan.target, plan.backup) != OK:
				_remove(plan.staging)
				_clear_state()
				return _fallback("Could not move the running game aside.")
			if DirAccess.rename_absolute(plan.staging, plan.target) != OK:
				DirAccess.rename_absolute(plan.backup, plan.target)
				_remove(plan.staging)
				_clear_state()
				return _fallback("Could not put the new version in place.")
	else:
		# macOS: ditto keeps permissions, symlinks and the code signature.
		if DirAccess.make_dir_recursive_absolute(plan.staging) != OK:
			return _fallback("Could not create a staging folder next to the app.")
		var code: int = await _run_async("/usr/bin/ditto", PackedStringArray(["-x", "-k", _part, plan.staging]))
		if code != 0:
			_remove(plan.staging)
			return _fallback("Could not unpack the update (ditto exit %d)." % code)
		var apps := Array(DirAccess.get_directories_at(plan.staging)).filter(func(d): return str(d).ends_with(".app"))
		if apps.size() != 1 or not DirAccess.dir_exists_absolute(plan.staging.path_join(apps[0]).path_join("Contents/MacOS")):
			_remove(plan.staging)
			return _fallback("The update archive did not contain one app bundle.")
		_remove(plan.backup)
		_save_state("swapped")
		if DirAccess.rename_absolute(plan.target, plan.backup) != OK:
			_remove(plan.staging)
			_clear_state()
			return _fallback("Could not move the current app aside.")
		if DirAccess.rename_absolute(plan.staging.path_join(apps[0]), plan.target) != OK:
			DirAccess.rename_absolute(plan.backup, plan.target)
			_remove(plan.staging)
			_clear_state()
			return _fallback("Could not put the new app in place.")
		_remove(plan.staging)
	_remove(_part)
	_log("installed v%s build %d at %s (previous kept at %s)" % [manifest.version, manifest.build, plan.target, plan.backup])
	return ""

func _relaunch() -> void:
	var command := Core.launch_command(_plan, _relaunch_args())
	_launched_at = Time.get_unix_time_from_system()
	_pid = OS.create_process(command[0], command[1])
	if _pid <= 0:
		_roll_back_now("The new version could not be started")
		return
	_log("started v%s (pid %d); waiting for it to reach the menu" % [manifest.version, _pid])
	state = "restarting"
	_supervise_left = SUPERVISE_TIMEOUT
	_poll = 0.0
	set_process(true)
	changed.emit()

## Waits for the new version's "started OK" marker, then quits. If it exits
## first (Linux, Windows: we have its pid), the previous version is restored.
func _supervise(delta: float) -> void:
	_poll -= delta
	_supervise_left -= delta
	if _poll > 0.0: return
	_poll = 0.25
	var marker: Variant = _read_json(STARTED_PATH)
	if typeof(marker) == TYPE_DICTIONARY and int(marker.get("build", -1)) == int(manifest.build) and float(marker.get("time", 0.0)) >= _launched_at - 1.0 and (_plan.platform == "macos" or int(marker.get("pid", -1)) == _pid):
		_log("v%s reached its menu; closing v%s" % [manifest.version, Core.local_version()])
		set_process(false)
		get_tree().quit()
		return
	if _plan.platform != "macos" and not OS.is_process_running(_pid):
		_roll_back_now("v%s closed before it reached the menu" % manifest.version)
	elif _supervise_left <= 0.0:
		# Still starting (or hung). Leave it: it confirms or rolls back on its own.
		_log("no confirmation after %ds; leaving the new version to finish starting" % int(SUPERVISE_TIMEOUT))
		set_process(false)
		get_tree().quit()

func _roll_back_now(reason: String) -> void:
	set_process(false)
	var restored := _restore(_plan)
	if restored:
		_remove(_plan.failed)
	_clear_state()
	_log("%s; %s" % [reason, "previous version restored" if restored else "could not restore the previous version"])
	if restored:
		_fail("%s, so v%s was put back. Try again later or use the download page." % [reason, Core.local_version()])
	else:
		_fail("%s. Your previous version is kept at %s." % [reason, _plan.backup])

## Puts `backup` back at `target`. The new files move to `failed` (Windows,
## macOS) or are replaced atomically (Linux).
func _restore(plan: Dictionary) -> bool:
	if not (FileAccess.file_exists(plan.backup) or DirAccess.dir_exists_absolute(plan.backup)): return false
	if plan.platform == "linux":
		return DirAccess.rename_absolute(plan.backup, plan.target) == OK
	_remove(plan.failed)
	if (FileAccess.file_exists(plan.target) or DirAccess.dir_exists_absolute(plan.target)) and DirAccess.rename_absolute(plan.target, plan.failed) != OK:
		return false
	if DirAccess.rename_absolute(plan.backup, plan.target) != OK:
		DirAccess.rename_absolute(plan.failed, plan.target)
		return false
	return true

# --- Start-up recovery ---------------------------------------------------------

## Runs in every exported start. Uses only build numbers from the state file;
## paths always come from this executable's own swap plan.
func _recover_on_start() -> void:
	var st: Variant = _read_json(STATE_PATH)
	if typeof(st) != TYPE_DICTIONARY: return
	var plan := Core.plan_swap(Core.platform_key(), OS.get_executable_path())
	if not plan.ok or st.get("platform") != plan.platform:
		_clear_state()
		return
	var me := Core.local_build()
	match str(st.get("phase", "")):
		"swapped":
			if int(st.get("to_build", -1)) != me: return
			if int(st.get("attempts", 0)) >= 1:
				# This version started before and never reached its menu.
				_log("v%s did not reach the menu last time; restoring v%s" % [Core.local_version(), st.get("from_version", "?")])
				if _restore(plan):
					st.phase = "rolled_back"
					_write_json(STATE_PATH, st)
					var command := Core.launch_command(plan, _relaunch_args())
					OS.create_process(command[0], command[1])
					get_tree().quit.call_deferred()
					return
				_log("could not restore; previous version is kept at " + plan.backup)
			st.attempts = int(st.get("attempts", 0)) + 1
			_write_json(STATE_PATH, st)
		"ok":
			_plan = plan
			_cleanup()
		"rolled_back":
			if int(st.get("from_build", -1)) == me:
				state = "error"
				message = "v%s did not start, so v%s was put back. Try again later or use the download page." % [st.get("to_version", "?"), Core.local_version()]
				_log("update failed: " + message)
				_remove(plan.failed)
				_clear_state()

## Writes the "started OK" marker. Called when the menu is shown.
func mark_started() -> void:
	if _started_marked or not _exported(): return
	_started_marked = true
	_write_json(STARTED_PATH, {"version": Core.local_version(), "build": Core.local_build(), "pid": OS.get_process_id(), "time": Time.get_unix_time_from_system()})
	var st: Variant = _read_json(STATE_PATH)
	if typeof(st) == TYPE_DICTIONARY and st.get("phase") == "swapped" and int(st.get("to_build", -1)) == Core.local_build():
		st.phase = "ok"
		_write_json(STATE_PATH, st)
		_log("update to v%s confirmed" % Core.local_version())
		_plan = Core.plan_swap(Core.platform_key(), OS.get_executable_path())
		if _plan.ok:
			# The old process may still be closing (Windows keeps its exe locked).
			get_tree().create_timer(2.0).timeout.connect(_cleanup)

## Removes the kept previous version once the new one is confirmed. Retries a
## few times; anything left is retried on the next start.
func _cleanup() -> void:
	if _plan.is_empty() or not _plan.ok: return
	_remove(_plan.backup)
	_remove(_plan.failed)
	_remove(_plan.staging)
	var downloads := ProjectSettings.globalize_path(DOWNLOAD_DIR)
	if DirAccess.dir_exists_absolute(downloads):
		for file in DirAccess.get_files_at(downloads):
			_remove(downloads.path_join(file))
	if FileAccess.file_exists(_plan.backup) or DirAccess.dir_exists_absolute(_plan.backup):
		_cleanup_tries += 1
		if _cleanup_tries < 10 and is_inside_tree():
			get_tree().create_timer(3.0).timeout.connect(_cleanup)
		return
	_log("removed previous version")
	_clear_state()

# --- Helpers ----------------------------------------------------------------------

func _exported() -> bool:
	return OS.has_feature("template") and not OS.has_feature("editor")

func _headers() -> PackedStringArray:
	return PackedStringArray(["Cache-Control: no-cache", "User-Agent: GizmoJam/%s" % Core.local_version()])

## Arguments for the relaunched version. Godot does not report the engine
## options it consumed, so keep the two that change how the game runs.
func _relaunch_args() -> PackedStringArray:
	var args := OS.get_cmdline_args()
	var user := OS.get_cmdline_user_args()
	var kept := PackedStringArray()
	if DisplayServer.get_name() == "headless":
		kept.append("--headless")
	if AudioServer.get_driver_name() == "Dummy":
		kept.append_array(["--audio-driver", "Dummy"])
	for arg in args:
		if not arg in user and arg != "--" and arg != "++":
			kept.append(arg)
	var extra := PackedStringArray()
	for arg in user:
		if arg != "--update-autoclick":
			extra.append(arg)
	if not extra.is_empty():
		kept.append("--")
		kept.append_array(extra)
	return kept

func _save_state(phase: String) -> void:
	_write_json(STATE_PATH, {"phase": phase, "platform": _plan.platform,
		"from_build": Core.local_build(), "from_version": Core.local_version(),
		"to_build": int(manifest.build), "to_version": str(manifest.version),
		"attempts": 0, "time": Time.get_unix_time_from_system()})

func _clear_state() -> void:
	_remove(ProjectSettings.globalize_path(STATE_PATH))

func _fail(text: String) -> void:
	state = "error"
	message = text
	set_process(false)
	_log("update failed: " + text)
	changed.emit()

## Same as an error, but used where the download page is the way forward.
func _fallback(text: String) -> String:
	return text + " Use the download page instead."

func _quiet_idle(text: String) -> void:
	state = "idle"
	_log(text)
	changed.emit()

func _drop_http() -> void:
	if is_instance_valid(_http):
		_http.cancel_request()
		_http.queue_free()
	_http = null

func _describe(result: int, code: int) -> String:
	if result == HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED: return "larger than the signed size"
	if result == HTTPRequest.RESULT_SUCCESS: return "HTTP %d" % code
	return "network error %d" % result

func _dir_writable(dir: String) -> bool:
	var probe := dir.path_join(".gizmojam-write-test-%d" % OS.get_process_id())
	var file := FileAccess.open(probe, FileAccess.WRITE)
	if file == null: return false
	file.close()
	DirAccess.remove_absolute(probe)
	return true

## Deletes a file, or a folder tree (only the updater's own hidden staging,
## backup and failed folders reach this).
func _remove(path: String) -> void:
	if path.is_empty(): return
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	elif DirAccess.dir_exists_absolute(path) and path.get_file().begins_with(".") and OS.get_name() != "Windows":
		OS.execute("/bin/rm", PackedStringArray(["-rf", path]))

func _run_async(program: String, args: PackedStringArray) -> int:
	var thread := Thread.new()
	thread.start(func(): return OS.execute(program, args))
	while thread.is_alive():
		await get_tree().process_frame
	return int(thread.wait_to_finish())

func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path): return null
	var text := FileAccess.get_file_as_string(path)
	if text.length() > 1 << 16: return null
	var json := JSON.new()
	if json.parse(text) != OK: return null
	return json.data

func _write_json(path: String, data: Variant) -> void:
	var tmp := path + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null: return
	file.store_string(JSON.stringify(data, "  "))
	file.close()
	DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(path))

func _log(text: String) -> void:
	print("[update] ", text)
