extends SceneTree
## Renders the update card in each state on the real menu and lobby, and checks
## its buttons drive the updater. Images go to test-output/update-*.png.
##   xvfb-run -a <godot> --path . --audio-driver Dummy --script tests/update_ui_shots.gd
const Core = preload("res://scripts/update_core.gd")
var main: Node
var updater: Node

func _initialize() -> void:
	call_deferred("run")

func capture(filename: String) -> void:
	await create_timer(0.25).timeout
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://test-output")
	root.get_texture().get_image().save_png("res://test-output/" + filename + ".png")

func card() -> Control:
	return main.screen.find_child("UpdateCard", true, false)

func button(name: String) -> Button:
	var c := card()
	return c.find_child(name, true, false) if c else null

func offer() -> void:
	var m := Core.validate_manifest({"schema": 1, "game": "gizmo-jam", "channel": "stable", "version": "0.3.0", "build": 3,
		"released": "2026-12-04", "min_updater_build": 0,
		"notes": "New minigame: SUMO! Shove rivals off a shrinking hex platform.\n• Six-player online lobbies remember your seat between rounds.\n• Spin Cycle: rods are easier to read at Overdrive speed.\n• Fixed the countdown voice cutting out on some Linux sound servers.",
		"platforms": {"linux": {"url": "https://example.invalid/GizmoJam-Linux.x86_64", "size": 74_211_840, "sha256": "a".repeat(64)}}})
	assert(m.ok, str(m.get("error")))
	updater.manifest = m.manifest
	updater.entry = m.manifest.platforms.linux
	updater.can_apply = true
	updater.block = ""
	updater.dismissed_build = -1
	updater.notes_open = false
	updater.state = "available"
	updater.changed.emit()

func run() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.test_mode = true
	main.sound_enabled = false
	updater = main.updater
	await create_timer(0.6).timeout
	assert(card() == null, "No card without an update")
	assert(main.screen.find_child("VersionTag", true, false) != null, "Menu shows the version")
	offer()
	await process_frame
	assert(card() != null and button("UpdateNow") != null and not button("UpdateNow").disabled)
	await capture("update-available")
	button("Notes").pressed.emit()
	await process_frame
	assert(updater.notes_open)
	await capture("update-notes")
	button("Notes").pressed.emit()
	await process_frame
	# Download progress, driven the way the HTTP download drives it.
	updater.state = "downloading"
	updater.total_bytes = 74_211_840
	updater.done_bytes = 31_457_280
	updater.changed.emit()
	updater.progress.emit(updater.done_bytes, updater.total_bytes)
	await capture("update-downloading")
	updater.state = "verifying"
	updater.changed.emit()
	await capture("update-verifying")
	updater.state = "ready"
	updater.changed.emit()
	await process_frame
	assert(button("InstallNow") != null and not button("InstallNow").disabled)
	await capture("update-ready")
	# A finished download never restarts the game in the middle of a round.
	main.session.solo("PLAYER ONE")
	main.session.start_round()
	assert(main.view == "game" and not updater.install_allowed(), "No installing during a round")
	updater.install_now()
	assert(updater.state == "ready", "install_now waits while a round is running")
	main._leave()
	assert(updater.install_allowed())
	updater.state = "error"
	updater.message = "The download did not match the signed manifest (SHA-256 mismatch). Nothing was changed."
	updater.changed.emit()
	await process_frame
	assert(button("DownloadPage") != null and button("Dismiss") != null)
	await capture("update-error")
	button("Dismiss").pressed.emit()
	await process_frame
	assert(card() == null, "Dismiss hides the card for this version")
	# Later hides it until the next launch, and survives screen rebuilds.
	offer()
	await process_frame
	button("Later").pressed.emit()
	await process_frame
	assert(card() == null)
	main._show_menu()
	await process_frame
	assert(card() == null, "Later keeps it hidden on the menu")
	# The setting hides the card and is shown on the menu.
	offer()
	updater.set_enabled(false)
	await process_frame
	assert(card() == null and not main.check_updates, "Check for updates: Off hides the card")
	await capture("update-setting-off")
	updater.set_enabled(true)
	await process_frame
	assert(main.check_updates)
	# Online lobby: the card shows, but installing (a restart) is blocked.
	main.port_field = null
	main._open_host()
	main.port_field.text = "19779"
	main._host()
	assert(main.view == "lobby")
	offer()
	await process_frame
	assert(button("UpdateNow").disabled, "Never restart into an update while a party is online")
	await capture("update-lobby")
	updater.start_update()
	assert(updater.state == "error", "start_update refuses while online")
	main._leave()
	# Source checkouts only report the update.
	offer()
	updater.can_apply = false
	updater.block = "dev"
	updater.changed.emit()
	await process_frame
	assert(button("UpdateNow") == null)
	await capture("update-dev")
	print("UPDATE_UI_PASS available-notes-progress-ready-noround-error-later-setting-lobby-dev")
	quit()
