extends SceneTree
## Updater logic: versions, manifest validation, signatures, file checks and
## swap plans. Optional `-- --fixtures=<dir>` also checks envelopes signed by
## tools/release.py (openssl) against Godot's verifier.
const Core = preload("res://scripts/update_core.gd")
const Keys = preload("res://scripts/update_keys.gd")

var crypto := Crypto.new()
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, label: String) -> void:
	if not condition:
		failures += 1
		print("FAIL: ", label)

func manifest(build: int = 3, extra: Dictionary = {}) -> Dictionary:
	var m := {"schema": 1, "game": "gizmo-jam", "channel": "stable", "version": "0.2.1", "build": build,
		"released": "2026-11-17", "notes": "New things · fixes", "min_updater_build": 0,
		"download_page": "https://timholum.com/games/gizmo-jam/",
		"platforms": {
			"linux": {"url": "https://example.invalid/GizmoJam-Linux.x86_64", "size": 11, "sha256": "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"},
			"windows": {"url": "https://example.invalid/GizmoJam-Windows.exe", "size": 5, "sha256": "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"}}}
	m.merge(extra, true)
	return m

func envelope(payload: PackedByteArray, key: CryptoKey, id: String) -> PackedByteArray:
	var sig := crypto.sign(HashingContext.HASH_SHA256, Core.sha256_bytes(payload), key)
	return JSON.stringify({"format": "gizmo-signed-manifest/1", "alg": "rsa-pkcs1v15-sha256", "key_id": id,
		"payload": Marshalls.raw_to_base64(payload), "signature": Marshalls.raw_to_base64(sig)}).to_utf8_buffer()

func pem(key: CryptoKey) -> String:
	return key.save_to_string(true)

func run() -> void:
	versions()
	validation()
	signatures()
	files()
	plans()
	fixtures()
	if failures == 0:
		print("UPDATE_TESTS_PASS")
	quit(1 if failures else 0)

func versions() -> void:
	check(Core.compare_versions("0.2.0", "0.1.0") == 1, "0.2.0 > 0.1.0")
	check(Core.compare_versions("0.10.0", "0.9.9") == 1, "numeric, not string, comparison")
	check(Core.compare_versions("1.0.0", "1.0.0") == 0, "equal")
	check(Core.compare_versions("1.0.0-beta.1", "1.0.0") == -1, "prerelease below release")
	check(Core.compare_versions("1.0.0-beta.2", "1.0.0-beta.1") == 1, "prerelease order")
	check(Core.compare_versions("v1.2.3", "1.2.3") == 0, "leading v")
	check(Core.compare_versions("garbage", "0.0.1") == -1, "invalid sorts lowest")
	check(Core.parse_version("1.2").is_empty() and Core.parse_version("01.2.3").is_empty() and Core.parse_version(12).is_empty(), "invalid versions")
	check(Core.local_version() == "0.3.2" and Core.local_build() == 5, "project version is 0.3.2 build 5")
	check(Core.platform_key("Linux") == "linux" and Core.platform_key("Windows") == "windows" and Core.platform_key("macOS") == "macos" and Core.platform_key("Android") == "", "platform keys")

func validation() -> void:
	var ok := Core.validate_manifest(manifest())
	check(ok.ok, "valid manifest: %s" % ok.get("error"))
	check(ok.manifest.build is int and ok.manifest.platforms.linux.size is int, "integers normalised")
	check(not Core.offer(ok.manifest, 2, "linux").is_empty(), "build 3 offered to build 2")
	check(Core.offer(ok.manifest, 3, "linux").is_empty(), "same build not offered")
	check(Core.offer(ok.manifest, 4, "linux").is_empty(), "never offers a downgrade")
	check(Core.offer(ok.manifest, 2, "macos").is_empty(), "missing platform not offered")
	var bad := {
		"wrong game": {"game": "other"}, "wrong channel": {"channel": "beta"}, "future schema": {"schema": 2},
		"string build": {"build": "3"}, "fractional build": {"build": 3.5}, "zero build": {"build": 0},
		"bad version": {"version": "three"}, "notes type": {"notes": 7}, "huge notes": {"notes": "x".repeat(5000)},
		"no platforms": {"platforms": {}}, "platforms type": {"platforms": []},
		"http url": {"platforms": {"linux": {"url": "http://x/y", "size": 1, "sha256": "a".repeat(64)}}},
		"file url": {"platforms": {"linux": {"url": "file:///etc/passwd", "size": 1, "sha256": "a".repeat(64)}}},
		"bad hash": {"platforms": {"linux": {"url": "https://x/y", "size": 1, "sha256": "A".repeat(64)}}},
		"short hash": {"platforms": {"linux": {"url": "https://x/y", "size": 1, "sha256": "abc"}}},
		"negative size": {"platforms": {"linux": {"url": "https://x/y", "size": -1, "sha256": "a".repeat(64)}}},
		"huge size": {"platforms": {"linux": {"url": "https://x/y", "size": 1e12, "sha256": "a".repeat(64)}}},
		"bad next_key": {"next_key": {"id": "k", "public_key": "nope"}},
		"bad page": {"download_page": "javascript:alert(1)"},
	}
	for label in bad:
		check(not Core.validate_manifest(manifest(3, bad[label])).ok, "rejects " + label)
	var local := Core.validate_manifest(manifest(3, {"platforms": {"linux": {"url": "http://127.0.0.1:8000/b", "size": 1, "sha256": "a".repeat(64)}}}), "gizmo-jam", "stable", true)
	check(local.ok, "http allowed only with a test override")

func signatures() -> void:
	var key := crypto.generate_rsa(2048)
	var other := crypto.generate_rsa(2048)
	var trusted := {"test-key": pem(key)}
	var payload := JSON.stringify(manifest()).to_utf8_buffer()
	var good := Core.open_envelope(envelope(payload, key, "test-key"), trusted)
	check(good.ok and good.manifest.version == "0.2.1", "valid signature accepted: %s" % good.get("error"))
	check(good.get("key_id") == "test-key", "reports signing key")
	# Tampered payload: flip the build after signing.
	var env: Dictionary = JSON.parse_string(envelope(payload, key, "test-key").get_string_from_utf8())
	env.payload = Marshalls.raw_to_base64(JSON.stringify(manifest(99)).to_utf8_buffer())
	check(not Core.open_envelope(JSON.stringify(env).to_utf8_buffer(), trusted).ok, "tampered manifest rejected")
	var flipped := payload.duplicate()
	flipped[10] = flipped[10] ^ 1
	env.payload = Marshalls.raw_to_base64(flipped)
	check(not Core.open_envelope(JSON.stringify(env).to_utf8_buffer(), trusted).ok, "one flipped bit rejected")
	check(not Core.open_envelope(envelope(payload, other, "test-key"), trusted).ok, "wrong-key signature rejected")
	check(not Core.open_envelope(envelope(payload, key, "unknown"), trusted).ok, "unknown key id rejected")
	check(not Core.open_envelope(envelope(payload, key, "test-key")).ok, "test key is not trusted by the shipped game")
	# Envelope fields.
	var base: Dictionary = JSON.parse_string(envelope(payload, key, "test-key").get_string_from_utf8())
	for change in [{"format": "x"}, {"alg": "rsa-pss"}, {"signature": ""}, {"signature": "@@@@"}, {"payload": "a"}, {"payload": 5}, {"key_id": 5}]:
		var copy := base.duplicate()
		copy.merge(change, true)
		check(not Core.open_envelope(JSON.stringify(copy).to_utf8_buffer(), trusted).ok, "rejects envelope change %s" % change)
	# Malformed, hostile and oversized input: rejected, and no engine errors.
	var junk: Array = ["", "{", "[]", "null", "\"x\"", "{\"format\":", "{}" , "[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[["]
	for text in junk:
		check(not Core.open_envelope(str(text).to_utf8_buffer(), trusted).ok, "rejects junk %s" % str(text).left(12))
	check(not Core.open_envelope(PackedByteArray([0xff, 0xfe, 0x7b, 0x7d]), trusted).ok, "rejects non-ASCII bytes")
	var big := PackedByteArray()
	big.resize(Core.MAX_ENVELOPE_BYTES + 1)
	big.fill(0x20)
	check(not Core.open_envelope(big, trusted).ok, "rejects oversized manifest")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 200:
		var noise := PackedByteArray()
		noise.resize(rng.randi_range(0, 400))
		for j in noise.size():
			noise[j] = rng.randi_range(0, 255) if i % 2 else rng.randi_range(32, 126)
		check(not Core.open_envelope(noise, trusted).ok, "rejects random bytes %d" % i)
	# Truncations of a valid envelope at every length.
	var whole := envelope(payload, key, "test-key")
	for cut in range(0, whole.size(), 37):
		check(not Core.open_envelope(whole.slice(0, cut), trusted).ok, "rejects truncation at %d" % cut)
	# Signed but semantically bad payloads are still rejected.
	check(not Core.open_envelope(envelope("not json".to_utf8_buffer(), key, "test-key"), trusted).ok, "rejects signed non-JSON")
	check(not Core.open_envelope(envelope(JSON.stringify(manifest(3, {"game": "x"})).to_utf8_buffer(), key, "test-key"), trusted).ok, "rejects signed manifest for another game")
	# Rotation: key 1 announces key 2; a manifest signed by key 2 is trusted once announced.
	var announced := Core.open_envelope(envelope(JSON.stringify(manifest(3, {"next_key": {"id": "test-key-2", "public_key": pem(other)}})).to_utf8_buffer(), key, "test-key"), trusted)
	check(announced.ok and announced.manifest.next_key.id == "test-key-2", "next_key carried in a signed manifest")
	var by_next := envelope(payload, other, "test-key-2")
	check(not Core.open_envelope(by_next, trusted).ok, "next key not trusted before announcement")
	var rotated := trusted.duplicate()
	rotated[announced.manifest.next_key.id] = announced.manifest.next_key.public_key
	check(Core.open_envelope(by_next, rotated).ok, "next key trusted after announcement")
	check(Keys.KEYS.size() >= 1, "release key embedded")
	for id in Keys.KEYS:
		check(id == key_fingerprint(Keys.KEYS[id]), "embedded key id %s matches its fingerprint" % id)
		var k := CryptoKey.new()
		check(k.load_from_string(Keys.KEYS[id], true) == OK and k.is_public_only(), "embedded key %s parses as a public key" % id)

## "gizmojam-" + 16 hex digits of SHA-256 over the DER public key (the PEM body).
func key_fingerprint(public_pem: String) -> String:
	var body := ""
	for line in public_pem.split("\n"):
		if not line.begins_with("-----"): body += line.strip_edges()
	return "gizmojam-" + Core.sha256_bytes(Marshalls.base64_to_raw(body)).hex_encode().left(16)

func files() -> void:
	var dir := OS.get_user_data_dir().path_join("update-test-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("payload.bin")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("hello world")
	f.close()
	var sha := "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
	check(Core.sha256_file(path) == sha, "sha256 of file")
	check(Core.check_file(path, 11, sha) == "", "matching file accepted")
	check(Core.check_file(path, 12, sha).begins_with("size mismatch"), "size mismatch rejected")
	check(Core.check_file(path, 11, "0".repeat(64)) == "SHA-256 mismatch", "hash mismatch rejected")
	check(Core.check_file(dir.path_join("missing"), 11, sha) != "", "missing file rejected")
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(dir)

func plans() -> void:
	var linux := Core.plan_swap("linux", "/home/p/Games/GizmoJam.x86_64")
	check(linux.ok and linux.target == "/home/p/Games/GizmoJam.x86_64" and linux.staging == "/home/p/Games/.GizmoJam.x86_64.update" and linux.backup == "/home/p/Games/GizmoJam.x86_64.old" and linux.dir == "/home/p/Games", "linux plan: %s" % linux)
	var win := Core.plan_swap("windows", "C:\\Games\\Gizmo Jam\\GizmoJam.exe")
	check(win.ok and win.target == "C:/Games/Gizmo Jam/GizmoJam.exe" and win.staging == "C:/Games/Gizmo Jam/GizmoJam.exe.new" and win.backup == "C:/Games/Gizmo Jam/GizmoJam.exe.old" and win.failed == "C:/Games/Gizmo Jam/GizmoJam.exe.failed" and win.dir == "C:/Games/Gizmo Jam", "windows plan: %s" % win)
	var mac := Core.plan_swap("macos", "/Applications/Gizmo Jam.app/Contents/MacOS/Gizmo Jam")
	check(mac.ok and mac.kind == "bundle" and mac.target == "/Applications/Gizmo Jam.app" and mac.staging == "/Applications/.Gizmo Jam.update" and mac.backup == "/Applications/.Gizmo Jam.app.old" and mac.dir == "/Applications", "mac plan: %s" % mac)
	check(not Core.plan_swap("macos", "/usr/local/bin/gizmo").ok, "mac outside a bundle refused")
	check(not Core.plan_swap("macos", "/private/var/folders/x/AppTranslocation/ABC/d/Gizmo Jam.app/Contents/MacOS/Gizmo Jam").ok, "translocated app refused")
	check(not Core.plan_swap("android", "/x/y").ok, "unsupported platform refused")
	var launch := Core.launch_command(mac, PackedStringArray(["--", "--update-channel=test"]))
	check(launch[0] == "/usr/bin/open" and Array(launch[1]) == ["-n", "/Applications/Gizmo Jam.app", "--args", "--", "--update-channel=test"], "mac relaunch uses open -n: %s" % [launch])
	var direct := Core.launch_command(linux, PackedStringArray())
	check(direct[0] == linux.target and direct[1].is_empty(), "linux relaunch runs the binary")
	# Every rename in a plan stays inside one folder, so it is atomic on one filesystem.
	for plan in [linux, win, mac]:
		for k in ["target", "staging", "backup", "failed"]:
			check(str(plan[k]).get_base_dir() == plan.dir, "%s %s stays beside the game" % [plan.platform, k])

func fixtures() -> void:
	var dir := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--fixtures="):
			dir = arg.trim_prefix("--fixtures=")
	if dir.is_empty(): return
	var trusted := {FileAccess.get_file_as_string(dir.path_join("key_id.txt")).strip_edges(): FileAccess.get_file_as_string(dir.path_join("public.pem"))}
	check(trusted.keys()[0] == key_fingerprint(trusted.values()[0]), "release.py key id matches the PEM fingerprint")
	var good := Core.open_envelope(FileAccess.get_file_as_bytes(dir.path_join("good.json")), trusted, "gizmo-jam", "test")
	check(good.ok and good.manifest.build == 7 and good.manifest.notes == "Openssl-signed · ünïcode notes", "release.py envelope verifies in Godot: %s" % good.get("error"))
	check(not Core.open_envelope(FileAccess.get_file_as_bytes(dir.path_join("tampered.json")), trusted, "gizmo-jam", "test").ok, "release.py envelope with edited payload rejected")
	check(not Core.open_envelope(FileAccess.get_file_as_bytes(dir.path_join("good.json")), trusted, "gizmo-jam", "stable").ok, "test-channel manifest rejected on stable")
	print("fixtures checked: ", dir)
