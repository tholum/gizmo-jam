extends SceneTree
## Game packs without a network: the registry, party messages, the signed
## catalog, the file-table reader and path rule, and the example game.
## tests/run_tests.py builds builds/packs/example-*.pck before this runs.

const Registry = preload("res://scripts/game_registry.gd")
const Wire = preload("res://scripts/party_wire.gd")
const PackCore = preload("res://scripts/pack_core.gd")
const Core = preload("res://scripts/update_core.gd")
const PackManager = preload("res://scripts/pack_manager.gd")

var failures := 0
var checks := 0
var tmp := ""

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		print("FAIL: ", message)

func _initialize() -> void:
	tmp = OS.get_cache_dir().path_join("gizmojam-test-packs-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(tmp)
	registry()
	wire()
	catalog()
	paths()
	example_pack()
	await manager()
	web_build()
	_cleanup(tmp)
	if failures == 0:
		print("PACK_TESTS PASS (%d checks)" % checks)
		quit(0)
	else:
		print("PACK_TESTS FAILED: %d of %d" % [failures, checks])
		quit(1)

func registry() -> void:
	Registry.reset()
	check(Registry.ids() == ["twisted", "livewire"], "Two built-in games, in card order: %s" % [Registry.ids()])
	check(Registry.actions("livewire") == ["left", "right", "up", "down", "dash"], "Live Wire actions")
	check(Registry.entry("twisted").trust == "builtin" and int(Registry.entry("twisted").net) == 1, "Built-ins are net 1")
	var good := {"id": "sumo", "version": "1.0.0", "net": 1, "core_min": 3, "actions": ["push"], "input_budget": 60,
		"info": {"number": "03", "title": "SUMO", "tags": "", "blurb": ""}, "module": "res://games/sumo/module.gd", "trust": "signed", "sha256": "", "size": 1}
	check(Registry.validate_entry(good).is_empty(), "A good entry validates")
	for bad in [{"id": "Sumo"}, {"module": "res://scripts/main.gd"}, {"trust": "builtin"}, {"actions": []}, {"input_budget": 100000}, {"net": 0}]:
		var e := good.duplicate(true)
		e.merge(bad, true)
		check(not Registry.validate_entry(e).is_empty(), "Refused: %s" % bad)
	var twin := good.duplicate(true)
	twin.id = "twisted"
	twin.module = "res://games/twisted/module.gd"
	check(not Registry.register(twin).is_empty(), "A pack cannot replace a built-in game")
	check(Registry.valid_id("live_wire2") and not Registry.valid_id("../x") and not Registry.valid_id(""), "Game ids")
	# Who can play what.
	var host_entry := {"net": 2, "sha256": "a".repeat(64), "trust": "signed"}
	check(Registry.compatible({"sumo": {"net": 2, "sha256": "b".repeat(64), "trust": "signed"}}, "sumo", host_entry), "Same net, any signed version, plays together")
	host_entry["requires_optional_seats"] = true
	check(not Registry.compatible({"sumo": {"net": 2, "trust": "signed"}}, "sumo", host_entry), "A sparse round requires an updated pack")
	check(Registry.compatible({"sumo": {"net": 2, "trust": "signed", "optional_seats": true}}, "sumo", host_entry), "An updated pack supports a sparse round")
	check(not Registry.compatible({"sumo": {"net": 1}}, "sumo", host_entry), "Another net does not")
	check(not Registry.compatible({}, "sumo", host_entry), "Nor a build without the game")
	var dev := {"net": 1, "sha256": "c".repeat(64), "trust": "untrusted"}
	check(not Registry.compatible({"sumo": {"net": 1, "sha256": "d".repeat(64), "trust": "untrusted"}}, "sumo", dev), "Unsigned packs must be the exact same file")
	check(Registry.compatible({"sumo": {"net": 1, "sha256": "c".repeat(64), "trust": "untrusted"}}, "sumo", dev), "and then they play")
	check(Registry.compatible(Registry.legacy_capabilities(), "livewire", Registry.public_entry("livewire")), "0.2.0 plays the built-in games")

func wire() -> void:
	var bytes := Wire.encode(Wire.HELLO, {"build": 3, "games": {"x": {"net": 1}}})
	var back := Wire.decode(bytes)
	check(back.kind == Wire.HELLO and back.data.build == 3, "Party messages round-trip")
	check(Wire.decode(PackedByteArray([1, 2, 3, 4, 5])).is_empty(), "Foreign packets are ignored")
	check(Wire.decode(PackedByteArray([0x47, 0x4A, 1, 1])).is_empty(), "Empty ones too")

## A throwaway RSA key and an envelope signed with it, as tools/release.py makes.
func signed_envelope(payload: Dictionary, key: CryptoKey) -> PackedByteArray:
	var body := JSON.stringify(payload).to_utf8_buffer()
	var signature := Crypto.new().sign(HashingContext.HASH_SHA256, Core.sha256_bytes(body), key)
	var public := key.save_to_string(true)
	var envelope := {"format": Core.ENVELOPE_FORMAT, "alg": Core.SIGNATURE_ALG, "key_id": PackManager.key_id(public),
		"payload": Marshalls.raw_to_base64(body), "signature": Marshalls.raw_to_base64(signature)}
	return JSON.stringify(envelope).to_ascii_buffer()

func catalog_payload(serial: int) -> Dictionary:
	return {"schema": 1, "game": "gizmo-jam", "kind": "catalog", "channel": "stable", "serial": serial,
		"games": {"sumo": {"version": "1.0.0", "net": 1, "core_min": 3, "size": 1234, "sha256": "ab".repeat(32),
			"url": "https://example.com/sumo.pck", "info": {"number": "03", "title": "SUMO", "tags": "PUSH", "blurb": "Shove."}}}}

var key: CryptoKey
var trusted := {}

func catalog() -> void:
	key = Crypto.new().generate_rsa(2048)
	trusted = {PackManager.key_id(key.save_to_string(true)): key.save_to_string(true)}
	var opened := PackCore.open_catalog(signed_envelope(catalog_payload(1), key), trusted)
	check(opened.ok, "A signed catalog opens: %s" % opened.get("error", ""))
	check(PackCore.entry_for(opened.catalog, "sumo", "AB".repeat(32)).size == 1234, "It vouches for an exact file")
	check(PackCore.entry_for(opened.catalog, "sumo", "cd".repeat(32)).is_empty(), "and no other")
	check(PackCore.entry_for(opened.catalog, "sumo", "", 1).size == 1234, "A bundled host can match a signed catalog pack on net")
	check(PackCore.entry_for(opened.catalog, "sumo", "", 1, true).is_empty(), "A sparse round never fetches a pack without its capability")
	var sparse := catalog_payload(2)
	sparse.games.sumo["optional_seats"] = true
	var sparse_catalog := PackCore.open_catalog(signed_envelope(sparse, key), trusted)
	check(PackCore.entry_for(sparse_catalog.catalog, "sumo", "", 1, true).size == 1234, "The signed catalog carries the optional-seat capability")
	check(PackCore.entry_for(opened.catalog, "sumo", "", 2).is_empty(), "A bundled host still needs a matching net")
	check(PackCore.entry_for(opened.catalog, "sumo", "cd".repeat(32), 1).is_empty(), "A host with a pack must still match the exact file")
	check(not PackCore.open_catalog(signed_envelope(catalog_payload(1), key), {}).ok, "An unknown key is refused")
	var other := Crypto.new().generate_rsa(2048)
	var forged: Dictionary = JSON.parse_string(signed_envelope(catalog_payload(1), other).get_string_from_ascii())
	forged.key_id = trusted.keys()[0]
	check(not PackCore.open_catalog(JSON.stringify(forged).to_ascii_buffer(), trusted).ok, "A forged signature is refused")
	var tampered: Dictionary = JSON.parse_string(signed_envelope(catalog_payload(1), key).get_string_from_ascii())
	var payload := catalog_payload(1)
	payload.games.sumo.sha256 = "ee".repeat(32)
	tampered.payload = Marshalls.raw_to_base64(JSON.stringify(payload).to_utf8_buffer())
	check(not PackCore.open_catalog(JSON.stringify(tampered).to_ascii_buffer(), trusted).ok, "A changed payload is refused")
	for change in [{"kind": "manifest"}, {"channel": "beta"}, {"serial": 0}, {"game": "other"}]:
		var p := catalog_payload(1)
		p.merge(change, true)
		check(not PackCore.open_catalog(signed_envelope(p, key), trusted).ok, "Refused: %s" % change)
	var builtin := catalog_payload(1)
	builtin.games["twisted"] = builtin.games.sumo
	check(not PackCore.open_catalog(signed_envelope(builtin, key), trusted).ok, "A catalog may not replace a built-in game")
	var http := catalog_payload(1)
	http.games.sumo.url = "http://example.com/sumo.pck"
	check(not PackCore.open_catalog(signed_envelope(http, key), trusted).ok, "Pack downloads must be https")

func paths() -> void:
	var own := [{"path": "res://games/sumo/module.gd.remap"}, {"path": "res://games/sumo/game.json"},
		{"path": "res://.godot/imported/x.ctex"}, {"path": "res://.godot/exported/1/export-a-stage.scn"}]
	check(PackCore.bad_paths(own, "sumo", {}).is_empty(), "A game's own files are fine")
	check(PackCore.pack_game_id(own) == "sumo", "The pack's game is found from game.json")
	var core := {"res://.godot/imported/x.ctex": true}
	check(PackCore.bad_paths(own, "sumo", core) == ["res://.godot/imported/x.ctex"], "A converted file the core has is refused")
	for bad in ["res://scripts/ui_kit.gd", "res://project.binary", "res://games/other/module.gd", "res://games/sumo/../../scripts/x.gd", "user://x", "res://.godot/uid_cache.bin"]:
		check(PackCore.bad_paths([{"path": bad}], "sumo", {}) == [bad], "Refused path " + bad)
	check(PackCore.pack_game_id(own + [{"path": "res://games/other/game.json"}]).is_empty(), "A pack carries exactly one game")
	# A real file with a core script hidden in it.
	var evil := tmp.path_join("evil.pck")
	var source := tmp.path_join("piece")
	var f := FileAccess.open(source, FileAccess.WRITE)
	f.store_string("{}")
	f.close()
	var packer := PCKPacker.new()
	packer.pck_start(evil)
	packer.add_file("res://games/evil/game.json", source)
	packer.add_file("res://scripts/ui_kit.gd", source)
	packer.flush()
	var info := PackCore.read_pck(evil)
	check(not info.has("error") and info.files.size() == 2, "The reader lists a pack: %s" % info)
	var problem := PackCore.verify_pack(evil, "evil", 0, "", {})
	check("ui_kit.gd" in problem, "verify_pack refuses it: " + problem)
	check(PackCore.read_pck(source).has("error"), "Not every file is a pack")

func example_pack() -> void:
	var found := ""
	for file in DirAccess.get_files_at("res://builds/packs"):
		if file.begins_with("example-") and file.ends_with(".pck"): found = "res://builds/packs/" + file
	check(not found.is_empty(), "The example pack was built")
	if found.is_empty(): return
	var path := ProjectSettings.globalize_path(found)
	var size := FileAccess.get_file_as_bytes(path).size()
	var sha := Core.sha256_file(path)
	check(PackCore.verify_pack(path, "example", size, sha, {}).is_empty(), "The example pack passes the game's checks")
	check(PackCore.verify_pack(path, "example", size, "00".repeat(32), {}) != "", "but not with another hash")
	check(PackCore.verify_pack(path, "sumo", size, sha, {}) != "", "nor as another game")
	var files: Array = PackCore.read_pck(path).files.map(func(e): return e.path)
	check("res://project.binary" not in files and "res://.godot/global_script_class_cache.cfg" not in files, "Project-wide files were stripped: %s" % [files])
	check(ProjectSettings.load_resource_pack(path, false), "Godot loads it")
	var entry := PackCore.read_game_json("example", "signed", sha, size)
	check(not entry.has("error"), "Its game.json reads: %s" % entry.get("error", ""))
	check(Registry.register(entry).is_empty(), "It joins the registry")
	check(Registry.ids() == ["twisted", "livewire", "example"], "after the built-in games: %s" % [Registry.ids()])
	var owner := Node.new()
	var module: RefCounted = Registry.instantiate("example", owner)
	check(module != null and module.ID == "example", "Its module loads")
	for method in ["make_model", "arena", "stage", "backdrop", "round_started", "build_hud", "update_hud", "layout_hud", "frame", "key", "release", "forget_keys", "build_rules", "result_summary", "result_headers", "result_tint", "result_row", "champion_stats", "celebrate", "finish_hold", "finished"]:
		check(module.has_method(method), "The module has " + method)
	# Its model plays a whole round of bots, and a client copy follows it.
	var model: RefCounted = module.make_model()
	var seats: Array = []
	for i in 6: seats.append({"peer": 0, "name": "BOT%d" % i, "bot": true})
	model.begin(42, seats, 1)
	var copy: RefCounted = module.make_model()
	copy.begin(42, seats, 1)
	var largest := 0
	for i in 2200:
		model.step(1.0 / 60.0)
		if i % 3 == 0:
			var snap: Dictionary = model.snapshot()
			largest = maxi(largest, var_to_bytes(snap).compress(FileAccess.COMPRESSION_DEFLATE).size())
			copy.apply_snapshot(snap)
	check(model.phase == "finished", "The round finishes")
	check(model.ranking().size() == 6 and not model.winners().is_empty(), "with a ranking")
	var scored := 0
	for p in model.players: scored += int(p.score)
	check(scored > 20, "Bots score: %d" % scored)
	check(copy.players[0].score == model.players[0].score and copy.phase == "finished", "Snapshots carry the round")
	check(largest < 400, "Snapshots stay small: %d bytes" % largest)
	owner.free()

func manager() -> void:
	var packs: Node = PackManager.new()
	root.add_child(packs)
	packs.root = tmp.path_join("mgr")
	packs.extra_keys = trusted
	DirAccess.make_dir_recursive_absolute(packs.root)
	check(packs.adopt_catalog(signed_envelope(catalog_payload(5), key)).is_empty(), "The manager keeps a verified catalog")
	check(int(packs.catalog.serial) == 5, "serial 5")
	check(not packs.adopt_catalog(signed_envelope(catalog_payload(4), key)).is_empty(), "and refuses an older one")
	check(int(packs.catalog.serial) == 5, "keeping serial 5")
	check(packs.adopt_catalog(signed_envelope(catalog_payload(6), key)).is_empty() and int(packs.catalog.serial) == 6, "but takes a newer one")
	var other: Node = PackManager.new()
	root.add_child(other)
	other.root = packs.root
	other.extra_keys = trusted
	other.load_all()
	check(int(other.catalog.get("serial", 0)) == 6, "The saved catalog is read back at start-up")
	# The party picks a game this build cannot get.
	var states: Array = []
	other.status_changed.connect(func(_id, state, _p): states.append(state))
	other.acquire("sumo", {"net": 1, "sha256": "ab".repeat(32), "trust": "signed", "core_min": 99}, {}, "")
	check(states == ["needs_update"], "A game for a newer core needs an update: %s" % [states])
	states.clear()
	other.acquire("ghost", {"net": 1, "sha256": "ab".repeat(32), "trust": "untrusted", "size": 10}, {"ip": "127.0.0.1", "port": 9}, "HOST")
	check(states == ["untrusted"], "Unsigned games are refused without developer mode: %s" % [states])
	packs.queue_free()
	other.queue_free()
	await process_frame

## The host's copy of the browser build: checked against the catalog, then
## unpacked with gzip copies of the big files; anything with a path refused.
func web_build() -> void:
	var zip_path := tmp.path_join("web.zip")
	var zip := ZIPPacker.new()
	zip.open(zip_path)
	var wasm := PackedByteArray()
	wasm.resize(50000)
	for i in wasm.size(): wasm[i] = i % 7
	for entry in [["index.html", "<!doctype html>".to_utf8_buffer()], ["index.wasm", wasm]]:
		zip.start_file(entry[0])
		zip.write_file(entry[1])
		zip.close_file()
	zip.close()
	var bytes := FileAccess.get_file_as_bytes(zip_path)
	var sha := Core.sha256_bytes(bytes).hex_encode()
	var dir := tmp.path_join("web")
	check(PackManager._unpack_web(zip_path, bytes.size(), "00".repeat(32), dir) != "", "A browser build with the wrong hash is refused")
	check(PackManager._unpack_web(zip_path, bytes.size(), sha, dir).is_empty(), "The browser build unpacks")
	check(FileAccess.file_exists(dir.path_join("index.html")) and FileAccess.file_exists(dir.path_join("index.wasm.gz")), "with a gzip copy of the wasm")
	var gz := FileAccess.get_file_as_bytes(dir.path_join("index.wasm.gz"))
	check(gz.size() > 2 and gz[0] == 0x1f and gz[1] == 0x8b, "that is real gzip")
	check(gz.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP) == wasm, "and decompresses to the original")
	var evil_path := tmp.path_join("evil.zip")
	zip = ZIPPacker.new()
	zip.open(evil_path)
	zip.start_file("../escape.html")
	zip.write_file("x".to_utf8_buffer())
	zip.close_file()
	zip.close()
	var evil := FileAccess.get_file_as_bytes(evil_path)
	check("unexpected" in PackManager._unpack_web(evil_path, evil.size(), Core.sha256_bytes(evil).hex_encode(), tmp.path_join("web2")), "A browser build with paths is refused")

func _cleanup(path: String) -> void:
	for file in DirAccess.get_files_at(path): DirAccess.remove_absolute(path.path_join(file))
	for dir in DirAccess.get_directories_at(path): _cleanup(path.path_join(dir))
	DirAccess.remove_absolute(path)
