extends RefCounted
## Pure game-pack logic: reading a .pck's file table without loading it, the
## rule for which paths a pack may carry, the signed catalog and game.json.
## No nodes and no network, so tests can drive all of it.
## Design: docs/specs/game-packs-and-browser-guests.md, sections 4 and 5.

const Core = preload("res://scripts/update_core.gd")
const Registry = preload("res://scripts/game_registry.gd")

const PCK_MAGIC := 0x43504447 # "GDPC"
const PACK_DIR_ENCRYPTED := 1
const PACK_REL_FILEBASE := 2
## Largest pack the game accepts, in bytes.
const MAX_PACK := 64 * 1024 * 1024
## Largest file table a pack may have.
const MAX_FILES := 20000
## Largest signed catalog, in bytes.
const MAX_CATALOG := 1024 * 1024
const CATALOG_SCHEMA := 1
const CATALOG_URL := "https://s3.us-central-1.wasabisys.com/timholum.com/games/gizmo-jam/updates/catalog-stable.json"

# --- Pack file table ----------------------------------------------------------

## {"version", "godot", "flags", "embedded", "files": [{path, offset, size}]}
## or {"error": "..."}. Also reads a pack embedded at the end of an executable.
static func read_pck(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return {"error": "cannot open"}
	var length := f.get_length()
	if length < 64: return {"error": "not a pack"}
	var start := 0
	var embedded := false
	if f.get_32() != PCK_MAGIC:
		# Embedded: [executable][pack][u64 pack size][u32 magic] at the end.
		f.seek_end(-4)
		if f.get_32() != PCK_MAGIC: return {"error": "not a pack"}
		f.seek_end(-12)
		var size := f.get_64()
		if size <= 0 or size > length - 12: return {"error": "bad embedded size"}
		start = length - 12 - size
		f.seek(start)
		if f.get_32() != PCK_MAGIC: return {"error": "bad embedded header"}
		embedded = true
	var version := f.get_32()
	var major := f.get_32()
	var minor := f.get_32()
	var patch := f.get_32()
	var flags := f.get_32()
	var file_base := f.get_64()
	if version < 2 or version > 3: return {"error": "unsupported pack format %d" % version}
	if version == 3:
		var dir_offset := f.get_64()
		if dir_offset <= 0 or start + dir_offset >= length: return {"error": "bad directory offset"}
		f.seek(start + dir_offset)
	else:
		for i in 16: f.get_32()
	if flags & PACK_REL_FILEBASE: file_base += start
	if flags & PACK_DIR_ENCRYPTED: return {"error": "encrypted pack"}
	var count := f.get_32()
	if count > MAX_FILES: return {"error": "too many files"}
	var files: Array = []
	for i in count:
		var name_len := f.get_32()
		if name_len == 0 or name_len > 4096 or f.get_position() + name_len > length: return {"error": "bad path length"}
		var name := f.get_buffer(name_len).get_string_from_utf8()
		var offset := f.get_64()
		var size := f.get_64()
		f.get_buffer(16) # md5
		f.get_32() # flags
		if f.eof_reached(): return {"error": "truncated directory"}
		if not name.begins_with("res://") and not name.begins_with("user://"): name = "res://" + name
		files.append({"path": name, "offset": offset + file_base, "size": size})
	return {"version": version, "godot": "%d.%d.%d" % [major, minor, patch], "flags": flags,
		"embedded": embedded, "files": files}

## Paths of the core game's own pack, as a set; {} when running from source
## (the editor), where there is no core pack to compare against.
static func core_paths() -> Dictionary:
	var candidates: Array = [OS.get_executable_path(), OS.get_executable_path().get_basename() + ".pck"]
	for path in candidates:
		if not FileAccess.file_exists(path): continue
		var info := read_pck(path)
		if info.has("error"): continue
		var paths := {}
		for e in info.files: paths[e.path] = true
		return paths
	return {}

## Spec 5.2 step 5. Every path must be under res://games/<id>/, or a converted
## resource Godot keeps under res://.godot/imported/ or res://.godot/exported/,
## and none may be one the core already has. Returns the offending paths.
static func bad_paths(files: Array, id: String, core: Dictionary) -> Array:
	var bad: Array = []
	var own := "res://games/%s/" % id
	for e in files:
		var p: String = e.path
		var tail := p.trim_prefix("res://")
		if not p.begins_with("res://") or ".." in tail or "//" in tail or "\\" in tail or ":" in tail:
			bad.append(p)
		elif core.has(p):
			bad.append(p)
		elif p.begins_with(own) or p.begins_with("res://.godot/imported/") or p.begins_with("res://.godot/exported/"):
			continue
		else:
			bad.append(p)
	return bad

## The single game id a pack carries (from its res://games/<id>/game.json),
## or "" if it has none or several.
static func pack_game_id(files: Array) -> String:
	var found := ""
	for e in files:
		var p: String = e.path
		if p.begins_with("res://games/") and p.ends_with("/game.json"):
			var id := p.trim_prefix("res://games/").trim_suffix("/game.json")
			if not Registry.valid_id(id) or (not found.is_empty() and found != id): return ""
			found = id
	return found

# --- game.json ------------------------------------------------------------------

## Reads res://games/<id>/game.json (from a loaded pack) as a registry entry
## with `trust` and `sha256` filled in. {"error": "..."} when it is unusable.
static func read_game_json(id: String, trust: String, sha256: String, size: int) -> Dictionary:
	var path := "res://games/%s/game.json" % id
	if not FileAccess.file_exists(path): return {"error": "game.json missing"}
	var text := FileAccess.get_file_as_string(path)
	if text.length() > 16384: return {"error": "game.json too large"}
	var json := JSON.new()
	if json.parse(text) != OK or typeof(json.data) != TYPE_DICTIONARY: return {"error": "game.json is not a JSON object"}
	return game_entry(json.data, id, trust, sha256, size)

## A registry entry from parsed game.json data.
static func game_entry(data: Dictionary, id: String, trust: String, sha256: String, size: int) -> Dictionary:
	if data.get("id") != id: return {"error": "game.json is for another game"}
	var info: Variant = data.get("info")
	var e := {"id": id, "version": data.get("version"), "net": data.get("net"), "core_min": data.get("core_min", 0),
		"actions": data.get("actions"), "input_budget": data.get("input_budget"), "info": info,
		"module": "res://games/%s/module.gd" % id, "trust": trust, "sha256": sha256, "size": size}
	var problem := Registry.validate_entry(e)
	if not problem.is_empty(): return {"error": problem}
	e.net = int(e.net)
	e.core_min = int(e.core_min)
	e.input_budget = int(e.input_budget)
	var clean_info := {}
	for key in ["number", "title", "tags", "blurb", "voice"]:
		clean_info[key] = str(info.get(key, ""))
	e.info = clean_info
	var acts: Array = []
	for a in e.actions: acts.append(str(a))
	e.actions = acts
	return e

# --- Signed catalog -------------------------------------------------------------

## Opens and checks a downloaded catalog envelope. Returns {"ok": true,
## "catalog": {...}} or {"ok": false, "error": "..."}.
static func open_catalog(bytes: PackedByteArray, trusted: Dictionary, channel: String = Core.CHANNEL, allow_http: bool = false) -> Dictionary:
	var opened := Core.open_signed(bytes, trusted, MAX_CATALOG)
	if not opened.ok: return opened
	var checked := validate_catalog(opened.payload, channel, allow_http)
	if checked.ok: checked.key_id = opened.key_id
	return checked

## Checks every field the pack manager relies on and returns a normalised copy.
## Catalog payload:
##   {"schema": 1, "game": "gizmo-jam", "kind": "catalog", "channel": "stable",
##    "serial": 14, "games": {"<id>": {"version", "net", "core_min", "size",
##    "sha256", "url", "info": {number, title, tags, blurb}}},
##    "web": {"build", "size", "sha256", "url"} (optional: the browser build)}
static func validate_catalog(c: Dictionary, channel: String = Core.CHANNEL, allow_http: bool = false) -> Dictionary:
	if not Core._is_int(c.get("schema")) or int(c.schema) != CATALOG_SCHEMA: return Core._fail("unsupported catalog schema")
	if c.get("game") != Core.GAME_ID: return Core._fail("catalog is for another game")
	if c.get("kind") != "catalog": return Core._fail("not a catalog")
	if c.get("channel") != channel: return Core._fail("catalog is for another channel")
	if not Core._is_int(c.get("serial")) or int(c.serial) < 1: return Core._fail("bad serial")
	var raw: Variant = c.get("games")
	if typeof(raw) != TYPE_DICTIONARY: return Core._fail("games missing")
	var games := {}
	for id in raw:
		if not Registry.valid_id(id): return Core._fail("bad game id")
		if Registry.is_builtin(id): return Core._fail("%s is built in" % id)
		var g: Variant = raw[id]
		if typeof(g) != TYPE_DICTIONARY: return Core._fail("bad %s entry" % id)
		if Core.parse_version(g.get("version")).is_empty(): return Core._fail("bad %s version" % id)
		if not Core._is_int(g.get("net")) or int(g.net) < 1: return Core._fail("bad %s net" % id)
		if not Core._is_int(g.get("core_min", 0)) or int(g.get("core_min", 0)) < 0: return Core._fail("bad %s core_min" % id)
		if not Core._is_int(g.get("size")) or int(g.size) < 1 or int(g.size) > MAX_PACK: return Core._fail("bad %s size" % id)
		if not Core.is_sha256(g.get("sha256")): return Core._fail("bad %s sha256" % id)
		if not Core._is_url(g.get("url"), allow_http): return Core._fail("bad %s url" % id)
		var problem := Registry.validate_info(g.get("info"))
		if not problem.is_empty(): return Core._fail("%s: %s" % [id, problem])
		var info: Dictionary = g.info
		games[id] = {"version": str(g.version), "net": int(g.net), "core_min": int(g.get("core_min", 0)),
			"size": int(g.size), "sha256": str(g.sha256).to_lower(), "url": str(g.url),
			"info": {"number": str(info.number), "title": str(info.title), "tags": str(info.tags), "blurb": str(info.blurb)}}
	var web := {}
	if c.has("web"):
		var w: Variant = c.web
		if typeof(w) != TYPE_DICTIONARY: return Core._fail("bad web entry")
		if not Core._is_int(w.get("build")) or int(w.build) < 1: return Core._fail("bad web build")
		if not Core._is_int(w.get("size")) or int(w.size) < 1 or int(w.size) > Core.MAX_DOWNLOAD: return Core._fail("bad web size")
		if not Core.is_sha256(w.get("sha256")): return Core._fail("bad web sha256")
		if not Core._is_url(w.get("url"), allow_http): return Core._fail("bad web url")
		web = {"build": int(w.build), "size": int(w.size), "sha256": str(w.sha256).to_lower(), "url": str(w.url)}
	return {"ok": true, "error": "", "catalog": {"schema": CATALOG_SCHEMA, "game": Core.GAME_ID, "kind": "catalog",
		"channel": channel, "serial": int(c.serial), "games": games, "web": web}}

## The catalog entry that matches what a host is playing (same id and file),
## or {} if this catalog does not vouch for that file.
static func entry_for(catalog: Dictionary, id: String, sha256: String) -> Dictionary:
	var g: Dictionary = catalog.get("games", {}).get(id, {})
	if g.is_empty() or str(g.sha256) != sha256.to_lower(): return {}
	return g

# --- Files ----------------------------------------------------------------------

## Checks a downloaded pack against what it should be. Returns "" or a reason.
## Runs on a worker thread: no nodes, no engine state beyond file access.
static func verify_pack(path: String, id: String, size: int, sha256: String, core: Dictionary) -> String:
	if size > MAX_PACK: return "pack too large"
	if not sha256.is_empty():
		var problem := Core.check_file(path, size, sha256)
		if not problem.is_empty(): return problem
	var info := read_pck(path)
	if info.has("error"): return "not a game pack: " + str(info.error)
	if pack_game_id(info.files) != id: return "pack is not for %s" % id
	var bad := bad_paths(info.files, id, core)
	if not bad.is_empty(): return "pack carries files outside its game: " + ", ".join(bad.slice(0, 3))
	return ""
