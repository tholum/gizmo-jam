extends RefCounted
## Every game this copy of Gizmo Jam can play, built in or loaded from a pack.
##
## An entry (see docs/specs/game-packs-and-browser-guests.md, section 4.2):
##   id            wire id; never changes once shipped
##   version       semver of the game
##   net           two builds play a game together only when id and net match
##   core_min      lowest core build the game runs on
##   actions       inputs Session.send_input() accepts for it
##   input_budget  accepted input messages per peer per second
##   info          menu card: number, title, tags, blurb, voice
##   module        res:// path of the game module (interface: game_spin_cycle.gd)
##   trust         "builtin", "signed" or "untrusted"; set by the loader only
##   sha256        hash of the pack file ("" for built-ins)
##
## The built-in games are the two every build since 0.2.0 has, at net 1. They
## stay inside the core executable so a fresh install plays with no downloads
## and 0.2.0 builds can always play them with us.

const BUILTIN_IDS := ["twisted", "livewire"]
## Actions each built-in game accepts. Live Wire directions are held, so they
## send a press and a release; dash and jump only matter when pressed.
const BUILTIN_ACTIONS := {
	"twisted": ["jump", "duck"],
	"livewire": ["left", "right", "up", "down", "dash"],
}
## Accepted input messages per peer per second; the rest are dropped. Spin
## Cycle has three message kinds (jump, duck down, duck up). Live Wire has nine
## (four directions down/up, dash): mashing all five keys at 12 Hz is 108 a
## second, too close to 120 when a dropped release leaves a direction held.
const BUILTIN_BUDGET := {"twisted": 120, "livewire": 240}
const BUILTIN_MODULES := {
	"twisted": "res://scripts/game_spin_cycle.gd",
	"livewire": "res://scripts/game_livewire.gd",
}
## The net version 0.2.0 builds play the built-in games at.
const LEGACY_NET := 1

const MAX_ACTIONS := 16
const MAX_BUDGET := 600

static var _entries: Dictionary = {}

static func _ensure() -> void:
	if not _entries.is_empty(): return
	for id in BUILTIN_IDS:
		var module: Script = load(BUILTIN_MODULES[id])
		_entries[id] = {
			"id": id, "version": str(ProjectSettings.get_setting("application/config/version", "0.0.0")),
			"net": LEGACY_NET, "core_min": 0, "actions": BUILTIN_ACTIONS[id],
			"input_budget": BUILTIN_BUDGET[id], "info": module.INFO,
			"module": BUILTIN_MODULES[id], "trust": "builtin", "sha256": "", "size": 0}

## Installed game ids in menu order (by card number, then id).
static func ids() -> Array:
	_ensure()
	var list: Array = _entries.keys()
	list.sort_custom(func(a, b): return order_key(_entries[a]) < order_key(_entries[b]))
	return list

static func order_key(entry: Dictionary) -> String:
	return "%s|%s" % [str(entry.get("info", {}).get("number", "99")).lpad(4, "0"), entry.get("id", "")]

static func has(id: String) -> bool:
	_ensure()
	return _entries.has(id)

static func entry(id: String) -> Dictionary:
	_ensure()
	return _entries.get(id, {})

static func actions(id: String) -> Array:
	return entry(id).get("actions", [])

static func input_budget(id: String) -> int:
	return int(entry(id).get("input_budget", 0))

static func is_builtin(id: String) -> bool:
	return id in BUILTIN_IDS

## A new game module instance for `main`, or null if the id is unknown.
static func instantiate(id: String, main: Node) -> RefCounted:
	var e := entry(id)
	if e.is_empty(): return null
	var script: Script = load(e.module)
	if script == null: return null
	return script.new(main)

## Adds a game that a pack provided. Returns "" or a reason it was refused.
## Built-in ids cannot be replaced.
static func register(e: Dictionary) -> String:
	_ensure()
	var problem := validate_entry(e)
	if not problem.is_empty(): return problem
	if is_builtin(e.id): return "%s is built in" % e.id
	if _entries.has(e.id): return "%s is already loaded" % e.id
	_entries[e.id] = e
	return ""

## Tests only: back to the built-in games.
static func reset() -> void:
	_entries.clear()

## What a game.json (or a catalog entry plus its game.json) must hold.
static func validate_entry(e: Dictionary) -> String:
	if not valid_id(e.get("id")): return "bad game id"
	if typeof(e.get("version")) != TYPE_STRING or str(e.version).length() > 32: return "bad version"
	if not _is_int(e.get("net")) or int(e.net) < 1: return "bad net"
	if not _is_int(e.get("core_min")) or int(e.core_min) < 0: return "bad core_min"
	var acts: Variant = e.get("actions")
	if typeof(acts) != TYPE_ARRAY or acts.is_empty() or acts.size() > MAX_ACTIONS: return "bad actions"
	for a in acts:
		if not valid_id(a): return "bad action name"
	if not _is_int(e.get("input_budget")) or int(e.input_budget) < 1 or int(e.input_budget) > MAX_BUDGET: return "bad input_budget"
	var problem := validate_info(e.get("info"))
	if not problem.is_empty(): return problem
	if typeof(e.get("module")) != TYPE_STRING or not str(e.module).begins_with("res://games/%s/" % e.id): return "bad module path"
	if e.get("trust") not in ["signed", "untrusted"]: return "bad trust"
	return ""

static func validate_info(info: Variant) -> String:
	if typeof(info) != TYPE_DICTIONARY: return "info missing"
	for key in ["number", "title", "tags", "blurb"]:
		if typeof(info.get(key)) != TYPE_STRING or str(info[key]).length() > 200: return "bad info.%s" % key
	if typeof(info.get("voice", "")) != TYPE_STRING: return "bad info.voice"
	return ""

## Lowercase letters, digits and underscores, 1 to 24 long.
static func valid_id(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING: return false
	var s := str(value)
	if s.is_empty() or s.length() > 24: return false
	for ch in s:
		if not ((ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_"): return false
	return true

static func _is_int(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or (typeof(v) == TYPE_FLOAT and is_equal_approx(v, roundf(v)) and absf(v) < 9.0e15)

## What this build advertises to a party: id -> {net, version, sha256, trust}.
static func capabilities() -> Dictionary:
	_ensure()
	var caps := {}
	for id in _entries:
		var e: Dictionary = _entries[id]
		caps[id] = {"net": int(e.net), "version": str(e.version), "sha256": str(e.sha256), "trust": str(e.trust)}
	return caps

## The menu card and the facts a guest needs to fetch a game it lacks.
static func public_entry(id: String) -> Dictionary:
	var e := entry(id)
	if e.is_empty(): return {}
	var info: Dictionary = e.info
	return {"net": int(e.net), "version": str(e.version), "sha256": str(e.sha256), "trust": str(e.trust),
		"size": int(e.get("size", 0)), "core_min": int(e.core_min),
		"info": {"number": str(info.number), "title": str(info.title), "tags": str(info.tags), "blurb": str(info.blurb)}}

## Whether a peer that advertised `caps` (see capabilities()) can play the
## game `host_entry` describes: same net, and for an untrusted pack the exact
## same file.
static func compatible(caps: Dictionary, id: String, host_entry: Dictionary) -> bool:
	if not caps.has(id): return false
	var theirs: Dictionary = caps[id]
	if int(theirs.get("net", -1)) != int(host_entry.get("net", -2)): return false
	if str(host_entry.get("trust", "")) == "untrusted" or str(theirs.get("trust", "")) == "untrusted":
		return str(theirs.get("sha256", "")) == str(host_entry.get("sha256", "")) and not str(host_entry.get("sha256", "")).is_empty()
	return true

## What a 0.2.0 build, which sends no capabilities, can play.
static func legacy_capabilities() -> Dictionary:
	var caps := {}
	for id in BUILTIN_IDS:
		caps[id] = {"net": LEGACY_NET, "version": "0.2.0", "sha256": "", "trust": "builtin"}
	return caps
