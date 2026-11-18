extends RefCounted
## Pure update logic: versions, the signed manifest, file checks and the
## per-platform swap plan. No nodes, no network, so tests can drive all of it.
##
## Signed manifest ("envelope"), the file published at MANIFEST_URL:
##   {"format": "gizmo-signed-manifest/1", "alg": "rsa-pkcs1v15-sha256",
##    "key_id": "gizmojam-…", "payload": "<base64 manifest JSON>",
##    "signature": "<base64 RSA signature of the exact payload bytes>"}
## The signature covers the decoded payload bytes, so no JSON canonicalisation
## is involved and the manifest and its signature are always uploaded together.

const Keys = preload("res://scripts/update_keys.gd")

const GAME_ID := "gizmo-jam"
const CHANNEL := "stable"
const MANIFEST_URL := "https://s3.us-central-1.wasabisys.com/timholum.com/games/gizmo-jam/updates/stable.json"
const DOWNLOAD_PAGE := "https://timholum.com/games/gizmo-jam/"
const ENVELOPE_FORMAT := "gizmo-signed-manifest/1"
const SIGNATURE_ALG := "rsa-pkcs1v15-sha256"
const SCHEMA := 1
const PLATFORMS := ["windows", "linux", "macos"]
const MAX_ENVELOPE_BYTES := 65536
const MAX_NOTES := 4000
const MAX_URL := 1024
## Largest download the game will accept, in bytes.
const MAX_DOWNLOAD := 2147483648

static var _base64: RegEx
static var _hex64: RegEx
static var _semver: RegEx

static func local_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0.0.0"))

static func local_build() -> int:
	return int(ProjectSettings.get_setting("application/config/build", 0))

## "windows", "linux", "macos", or "" where in-place updates are not supported.
static func platform_key(os_name: String = OS.get_name()) -> String:
	match os_name:
		"Windows": return "windows"
		"Linux": return "linux"
		"macOS": return "macos"
	return ""

# --- Versions -----------------------------------------------------------------

## [major, minor, patch, prerelease] for "1.2.3" or "1.2.3-beta.1"; [] if invalid.
static func parse_version(text: Variant) -> Array:
	if typeof(text) != TYPE_STRING or str(text).length() > 32: return []
	if _semver == null:
		_semver = RegEx.create_from_string("^v?(0|[1-9][0-9]{0,5})\\.(0|[1-9][0-9]{0,5})\\.(0|[1-9][0-9]{0,5})(?:-([0-9A-Za-z.-]{1,16}))?$")
	var m := _semver.search(str(text))
	if m == null: return []
	return [int(m.get_string(1)), int(m.get_string(2)), int(m.get_string(3)), m.get_string(4)]

## -1, 0 or 1 like semver: a release outranks its own prereleases. Invalid
## versions sort below every valid one.
static func compare_versions(a: Variant, b: Variant) -> int:
	var va := parse_version(a)
	var vb := parse_version(b)
	if va.is_empty() or vb.is_empty():
		return int(not va.is_empty()) - int(not vb.is_empty())
	for i in 3:
		if va[i] != vb[i]:
			return 1 if va[i] > vb[i] else -1
	var pa: String = va[3]
	var pb: String = vb[3]
	if pa == pb: return 0
	if pa.is_empty(): return 1
	if pb.is_empty(): return -1
	return 1 if pa > pb else -1

# --- Signed manifest ----------------------------------------------------------

## Opens a downloaded envelope. Returns {"ok": true, "manifest": {...}} or
## {"ok": false, "error": "..."}. Never prints engine errors, whatever the input.
static func open_envelope(bytes: PackedByteArray, trusted: Dictionary = Keys.KEYS, game: String = GAME_ID, channel: String = CHANNEL, allow_http: bool = false) -> Dictionary:
	if bytes.is_empty(): return _fail("empty manifest")
	if bytes.size() > MAX_ENVELOPE_BYTES: return _fail("manifest too large")
	for b in bytes:
		if b > 127: return _fail("manifest is not ASCII")
	var envelope: Variant = _parse_json(bytes.get_string_from_ascii())
	if typeof(envelope) != TYPE_DICTIONARY: return _fail("manifest is not a JSON object")
	if envelope.get("format") != ENVELOPE_FORMAT: return _fail("unknown manifest format")
	if envelope.get("alg") != SIGNATURE_ALG: return _fail("unknown signature algorithm")
	var key_id: Variant = envelope.get("key_id")
	if typeof(key_id) != TYPE_STRING or not trusted.has(key_id): return _fail("manifest signed by an unknown key")
	var payload := _base64_bytes(envelope.get("payload"))
	var signature := _base64_bytes(envelope.get("signature"))
	if payload.is_empty() or signature.is_empty(): return _fail("payload or signature is not base64")
	if not verify_signature(payload, signature, str(trusted[key_id])): return _fail("signature does not verify")
	var manifest: Variant = _parse_json(payload.get_string_from_utf8())
	if typeof(manifest) != TYPE_DICTIONARY: return _fail("signed payload is not a JSON object")
	var checked := validate_manifest(manifest, game, channel, allow_http)
	if checked.ok:
		checked.key_id = key_id
	return checked

static func verify_signature(data: PackedByteArray, signature: PackedByteArray, public_pem: String) -> bool:
	if not public_pem.begins_with("-----BEGIN PUBLIC KEY-----"): return false
	var key := CryptoKey.new()
	if key.load_from_string(public_pem, true) != OK: return false
	return Crypto.new().verify(HashingContext.HASH_SHA256, sha256_bytes(data), signature, key)

## Checks every field the updater relies on and returns a normalised copy
## (integers as int, missing optionals filled in).
static func validate_manifest(m: Dictionary, game: String = GAME_ID, channel: String = CHANNEL, allow_http: bool = false) -> Dictionary:
	if not _is_int(m.get("schema")): return _fail("schema missing")
	if int(m.schema) != SCHEMA: return _fail("unsupported manifest schema %d" % int(m.schema))
	if m.get("game") != game: return _fail("manifest is for another game")
	if m.get("channel") != channel: return _fail("manifest is for another channel")
	if parse_version(m.get("version")).is_empty(): return _fail("bad version")
	if not _is_int(m.get("build")) or int(m.build) < 1: return _fail("bad build number")
	var released: Variant = m.get("released", "")
	if typeof(released) != TYPE_STRING or str(released).length() > 32: return _fail("bad release date")
	var notes: Variant = m.get("notes", "")
	if typeof(notes) != TYPE_STRING or str(notes).length() > MAX_NOTES: return _fail("bad release notes")
	var min_build: Variant = m.get("min_updater_build", 0)
	if not _is_int(min_build) or int(min_build) < 0: return _fail("bad min_updater_build")
	var page: Variant = m.get("download_page", DOWNLOAD_PAGE)
	if not _is_url(page, false): return _fail("bad download page")
	var platforms: Variant = m.get("platforms")
	if typeof(platforms) != TYPE_DICTIONARY: return _fail("platforms missing")
	var clean_platforms := {}
	for key in PLATFORMS:
		if not platforms.has(key): continue
		var entry: Variant = platforms[key]
		if typeof(entry) != TYPE_DICTIONARY: return _fail("bad %s entry" % key)
		if not _is_url(entry.get("url"), allow_http): return _fail("bad %s url" % key)
		if not _is_int(entry.get("size")) or int(entry.size) < 1 or int(entry.size) > MAX_DOWNLOAD: return _fail("bad %s size" % key)
		if not is_sha256(entry.get("sha256")): return _fail("bad %s sha256" % key)
		clean_platforms[key] = {"url": str(entry.url), "size": int(entry.size), "sha256": str(entry.sha256)}
	if clean_platforms.is_empty(): return _fail("no platforms")
	var next_key: Variant = m.get("next_key")
	var clean_next := {}
	if next_key != null:
		if typeof(next_key) != TYPE_DICTIONARY: return _fail("bad next_key")
		var id: Variant = next_key.get("id")
		var pem: Variant = next_key.get("public_key")
		if typeof(id) != TYPE_STRING or str(id).length() < 4 or str(id).length() > 64: return _fail("bad next_key id")
		if typeof(pem) != TYPE_STRING or str(pem).length() > 4096 or not str(pem).begins_with("-----BEGIN PUBLIC KEY-----"): return _fail("bad next_key public_key")
		clean_next = {"id": str(id), "public_key": str(pem)}
	return {"ok": true, "error": "", "manifest": {
		"schema": SCHEMA, "game": game, "channel": channel,
		"version": str(m.version), "build": int(m.build), "released": str(released),
		"notes": str(notes), "min_updater_build": int(min_build), "download_page": str(page),
		"platforms": clean_platforms, "next_key": clean_next}}

## The update to offer this build, or {} if there is none for `platform`.
static func offer(manifest: Dictionary, build: int, platform: String) -> Dictionary:
	if int(manifest.get("build", 0)) <= build: return {}
	var entry: Dictionary = manifest.get("platforms", {}).get(platform, {})
	return entry

# --- Files --------------------------------------------------------------------

static func sha256_bytes(data: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return ctx.finish()

## Lowercase hex SHA-256 of a file, or "" if it cannot be read.
static func sha256_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while file.get_position() < file.get_length():
		ctx.update(file.get_buffer(1 << 20))
	return ctx.finish().hex_encode()

## "" when the file matches the signed size and hash, else why it does not.
static func check_file(path: String, size: int, sha256: String) -> String:
	if not FileAccess.file_exists(path): return "download is missing"
	var actual_size := _file_size(path)
	if actual_size != size: return "size mismatch (expected %d bytes, got %d)" % [size, actual_size]
	if sha256_file(path) != sha256.to_lower(): return "SHA-256 mismatch"
	return ""

static func is_sha256(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING: return false
	if _hex64 == null:
		_hex64 = RegEx.create_from_string("^[0-9a-f]{64}$")
	return _hex64.search(str(value)) != null

# --- Swap plans ---------------------------------------------------------------

## Where each file goes when replacing the running game in place. Pure path
## arithmetic: `exe` is OS.get_executable_path(). Returns {"ok": false, "error"}
## when this layout cannot be updated in place.
##   linux:   copy the new binary to `staging` beside the exe, chmod +x, copy the
##            old one to `backup`, then rename `staging` over `target` (atomic).
##   windows: copy to `staging`; rename the running `target` to `backup` (Windows
##            allows renaming a running exe), then `staging` to `target`.
##   macos:   ditto -x -k the zip into `staging`, rename the bundle `target` to
##            `backup`, rename the new .app from `staging` to `target`, `open -n`.
static func plan_swap(platform: String, exe: String) -> Dictionary:
	var path := exe.replace("\\", "/")
	var dir := path.get_base_dir()
	var name := path.get_file()
	if name.is_empty() or dir.is_empty(): return _fail("unknown executable path")
	match platform:
		"linux":
			return {"ok": true, "platform": platform, "kind": "file", "dir": dir, "target": path,
				"staging": dir.path_join("." + name + ".update"), "backup": path + ".old",
				"failed": path + ".failed", "launch": path}
		"windows":
			return {"ok": true, "platform": platform, "kind": "file", "dir": dir, "target": path,
				"staging": path + ".new", "backup": path + ".old", "failed": path + ".failed", "launch": path}
		"macos":
			if not dir.ends_with(".app/Contents/MacOS"):
				return _fail("not running from an .app bundle")
			var bundle := dir.get_base_dir().get_base_dir()
			if "/AppTranslocation/" in bundle:
				return _fail("macOS is running the app from a read-only quarantine copy; move it to Applications first")
			var parent := bundle.get_base_dir()
			var bundle_name := bundle.get_file()
			return {"ok": true, "platform": platform, "kind": "bundle", "dir": parent, "target": bundle,
				"staging": parent.path_join("." + bundle_name.get_basename() + ".update"),
				"backup": parent.path_join("." + bundle_name + ".old"),
				"failed": parent.path_join("." + bundle_name + ".failed"), "launch": bundle}
	return _fail("in-place updates are not supported on this platform")

## Command that starts the installed version: [program, args].
static func launch_command(plan: Dictionary, args: PackedStringArray) -> Array:
	if plan.platform == "macos":
		var open_args := PackedStringArray(["-n", plan.launch])
		if not args.is_empty():
			open_args.append("--args")
			open_args.append_array(args)
		return ["/usr/bin/open", open_args]
	return [plan.launch, args]

# --- Helpers ------------------------------------------------------------------

static func _fail(message: String) -> Dictionary:
	return {"ok": false, "error": message}

static func _parse_json(text: String) -> Variant:
	var json := JSON.new()
	if json.parse(text) != OK: return null
	return json.data

static func _is_int(value: Variant) -> bool:
	if typeof(value) == TYPE_INT: return true
	return typeof(value) == TYPE_FLOAT and is_finite(value) and value == floorf(value) and absf(value) < 9.0e15

static func _is_url(value: Variant, allow_http: bool) -> bool:
	if typeof(value) != TYPE_STRING: return false
	var url := str(value)
	if url.length() > MAX_URL or " " in url or "\n" in url or "\t" in url: return false
	return url.begins_with("https://") or (allow_http and url.begins_with("http://"))

## Decodes strict base64; returns empty bytes for anything else, without the
## engine error Marshalls prints on bad input.
static func _base64_bytes(value: Variant) -> PackedByteArray:
	if typeof(value) != TYPE_STRING: return PackedByteArray()
	var text := str(value)
	if text.is_empty() or text.length() % 4 != 0 or text.length() > MAX_ENVELOPE_BYTES: return PackedByteArray()
	if _base64 == null:
		_base64 = RegEx.create_from_string("^[A-Za-z0-9+/]*={0,2}$")
	if _base64.search(text) == null: return PackedByteArray()
	return Marshalls.base64_to_raw(text)

static func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	return -1 if file == null else file.get_length()
