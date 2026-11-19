extends SceneTree
## Store screenshots: runs the real game, with bots in every seat, and saves
## frames of the menu, a Spin Cycle round and a Live Wire round.
##
##   xvfb-run -a -s "-screen 0 1920x1080x24" $G --path . --audio-driver Dummy \
##       --resolution 1920x1080 --script res://tools/store_shots.gd
##
## `-- --handheld` shows the phone version (touch controls, larger UI);
## `--out=<name>` writes to builds/store/<name>/ instead of shots/.
##
## Writes builds/store/shots/*.png (builds/ is not committed). Used by
## tools/store_listing.py.

var OUT := "res://builds/store/shots"
var main: Node

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): OUT = "res://builds/store/" + arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	main.test_mode = true
	await _wait(2.0)
	main._set_graphics("high")
	# Show the menu as the Android app has it: no game library, developer mode
	# or update toggle.
	main.store_app = true
	main.session.select_game("twisted")
	main._show_menu()
	await _wait(0.2)
	var toggle: Node = main.screen.find_child("UpdateToggle", true, false)
	if toggle: toggle.queue_free()
	await _wait(3.0)
	await _shot("1-menu")
	await _round("twisted", [7.0, 9.0], ["2-spin-cycle", "3-spin-cycle"])
	await _round("livewire", [16.0, 22.0], ["4-live-wire", "5-live-wire"])
	quit()

## Plays a solo round of `id` with a bot in every seat, saving a frame after
## each delay.
func _round(id: String, delays: Array, names: Array) -> void:
	main.session.select_game(id)
	main.preferred_game = id
	main.session.solo("PLAYER ONE")
	main.session.start_round()
	await _wait(0.5)
	var model: RefCounted = main.model
	model.countdown = 0.0
	model.phase = "running"
	for slot in range(model.players.size()):
		model.take_over(slot)
	for i in range(delays.size()):
		await _wait(float(delays[i]))
		await _shot(names[i])
		# And the same moment without the HUD, for the feature graphic.
		main.canvas.visible = false
		await _wait(0.05)
		await _shot(names[i] + "-clean")
		main.canvas.visible = true
	# Leave the solo session, as the menu would, so the next game can be picked.
	main._leave()
	await _wait(1.0)

func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout

func _shot(name_value: String) -> void:
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path(OUT + "/" + name_value + ".png")
	root.get_texture().get_image().save_png(path)
	print("[store] ", path)
