extends SceneTree
## Lays every screen out at each supported window size and checks the layout.
## Each screen is built once and then the window is resized through the sizes,
## so this also exercises re-layout on a live resize (mid-round included).
##
## Checks, at every size:
##   - buttons and text fields sit inside the visible canvas and do not overlap;
##   - dialogs fit on the canvas;
##   - label text is at least MIN_TEXT_PX on screen;
##   - the six HUD plates are inside the canvas and do not overlap, and the
##     cue, status readout and ESC button do not collide;
##   - Spin Cycle: every runner, both ends of the action line and the incoming
##     rod are in view and clear of the plates;
##   - Live Wire: the whole hex board and its surge emitters are in view and
##     clear of every HUD widget;
##   - on menu screens, the runners (or the board) are clear of the menu column.
##
## Headless (geometry only, used by tests/run_tests.py):
##   godot --headless --path . --script tests/screen_sizes.gd
## With screenshots in test-output/sizes/<W>x<H>/ (needs a display):
##   xvfb-run -a -s "-screen 0 2560x1440x24" godot --path . --audio-driver Dummy \
##       --script tests/screen_sizes.gd -- --capture
## Options: --sizes=1024x576,1920x1080 to pick sizes.

const Arena = preload("res://scripts/arena.gd")
const SIZES := [Vector2i(1024, 576), Vector2i(1024, 768), Vector2i(1280, 720), Vector2i(1366, 768),
	Vector2i(1440, 900), Vector2i(1920, 1080), Vector2i(2560, 1080), Vector2i(2560, 1440)]
## Smallest label text allowed, in screen pixels.
const MIN_TEXT_PX := 11.0
var main: Node
var capture := false
var sizes: Array = SIZES.duplicate()
var failures: Array = []
var checks := 0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--capture": capture = true
		if arg.begins_with("--sizes="):
			sizes.clear()
			for part in arg.trim_prefix("--sizes=").split(",", false):
				var wh := part.split("x")
				sizes.append(Vector2i(int(wh[0]), int(wh[1])))
	call_deferred("run")

func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		failures.append("%s: %s" % [root.size, what])

func settle(frames: int = 3) -> void:
	for i in frames:
		await process_frame
	await create_timer(0.12).timeout
	await process_frame

## Resizes the window through the Window API, which emits size_changed just as
## a window-manager resize does. (A bare DisplayServer.window_set_size() is not
## reported back to the Window under Xvfb, which has no window manager.)
func resize(to: Vector2i) -> void:
	root.size = to
	for i in 30:
		await process_frame
		if root.size == to: break
	check(root.size == to, "window did not reach %s" % to)
	await settle()

func shot(name_value: String) -> void:
	if not capture: return
	await RenderingServer.frame_post_draw
	var folder := "res://test-output/sizes/%dx%d" % [root.size.x, root.size.y]
	DirAccess.make_dir_recursive_absolute(folder)
	root.get_texture().get_image().save_png(folder + "/" + name_value + ".png")

func area() -> Rect2:
	return Rect2(Vector2.ZERO, main.area)

func px_per_unit() -> float:
	return float(root.size.y) / main.area.y

func visible_controls(parent: Node, kinds: Array) -> Array:
	var found: Array = []
	for node in parent.find_children("*", "Control", true, false):
		if not node.is_visible_in_tree(): continue
		for kind in kinds:
			if is_instance_of(node, kind):
				found.append(node)
				break
	return found

## Buttons and fields inside the canvas and clear of each other; text legible.
## An open dialog covers the screen behind it, so each layer is checked alone.
func check_controls(screen_name: String) -> void:
	check_keys(screen_name, visible_controls(main.screen, [Button, LineEdit]))
	check_keys(screen_name, visible_controls(main.overlay, [Button, LineEdit]))
	for label in visible_controls(main.screen, [Label]) + visible_controls(main.overlay, [Label]):
		if label.text.strip_edges().is_empty(): continue
		var size := float(label.get_theme_font_size("font_size"))
		var on_screen: float = size * label.get_global_transform().get_scale().y * px_per_unit()
		check(on_screen >= MIN_TEXT_PX, "%s: '%s' is %.1f px" % [screen_name, label.text.left(24), on_screen])

func check_keys(screen_name: String, keys: Array) -> void:
	var view := area().grow(1.0)
	var rects: Array = []
	for key in keys:
		var r: Rect2 = key.get_global_rect()
		check(view.encloses(r), "%s: %s '%s' %s is outside the canvas %s" % [screen_name, key.get_class(), key.get("text"), r, main.area])
		rects.append(r)
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			# A key drawn on top of another (a card's own buttons) is a child, not a clash.
			if keys[i].is_ancestor_of(keys[j]) or keys[j].is_ancestor_of(keys[i]): continue
			var a: Rect2 = rects[i].grow(-1.0)
			check(not a.intersects(rects[j].grow(-1.0)), "%s: '%s' overlaps '%s'" % [screen_name, keys[i].get("text"), keys[j].get("text")])

func check_modal(screen_name: String) -> void:
	for child in main.overlay.get_children():
		if child is Control and child.has_meta("modal_height"):
			check(area().grow(1.0).encloses(child.get_global_rect()), "%s: dialog %s does not fit %s" % [screen_name, child.get_global_rect(), main.area])

func project(point: Vector3) -> Vector2:
	return main.arena.camera.unproject_position(point)

func plates_top() -> float:
	var top: float = main.area.y
	for plate in main.play.plates:
		top = minf(top, plate.get_global_rect().position.y)
	return top

## Plates inside the canvas and apart; cue, status and menu key apart.
func check_frame(screen_name: String) -> void:
	var view := area().grow(1.0)
	var plates: Array = []
	for plate in main.play.plates:
		var r: Rect2 = plate.get_global_rect()
		check(view.encloses(r), "%s: plate %s outside the canvas" % [screen_name, r])
		plates.append(r)
	for i in plates.size():
		for j in range(i + 1, plates.size()):
			check(not plates[i].intersects(plates[j]), "%s: plates %d and %d overlap" % [screen_name, i, j])
	var cue: Rect2 = main.play.cue.get_global_rect()
	var status: Rect2 = main.play.status.get_global_rect()
	var esc: Rect2 = main.hud_menu.get_global_rect()
	var names: Rect2 = main.hud_names.get_global_rect()
	check(not cue.intersects(status), "%s: cue %s hits status %s" % [screen_name, cue, status])
	check(not cue.intersects(esc) and not cue.intersects(names), "%s: cue hits the ESC button" % screen_name)
	check(not status.intersects(esc), "%s: status hits the ESC button" % screen_name)

## Spin Cycle: runners, action line and incoming rod clear of the plates.
func check_hud(screen_name: String) -> void:
	check_frame(screen_name)
	var floor_y := plates_top()
	var scene := Rect2(Vector2.ZERO, Vector2(main.area.x, floor_y))
	for r in main.arena.runners:
		# A knocked-out runner is carried off down the belt on purpose.
		if not r.visual.visible or r.out >= 0.0: continue
		var feet := project(r.visual.global_position)
		var head := project(r.visual.global_position + Vector3(0, 1.3, 0))
		check(scene.has_point(feet) and scene.has_point(head), "%s: runner at %s..%s is hidden (plates from y %.0f)" % [screen_name, head, feet, floor_y])
	# The action line where rods meet the runners, and a rod on its way in. The
	# camera looks along the ramp, so a rod sweeps in from the bottom-right
	# corner: its tower end is in view from well out (0.75 rad, over a second
	# at the starting speed), and the whole rod is in view and clear of the
	# plates for the last 0.3 rad.
	for radius in [2.74, 7.86]:
		var p := project(Vector3(0, 0.02, radius))
		check(scene.has_point(p), "%s: action line end r=%.2f at %s is hidden" % [screen_name, radius, p])
	for probe in [[0.75, 2.6], [0.3, 2.6], [0.3, 7.9]]:
		var angle: float = probe[0]
		var radius: float = probe[1]
		var p := project(Vector3(sin(angle) * radius, angle / TAU * Arena.PITCH + Arena.ROD_LOW, cos(angle) * radius))
		check(scene.has_point(p), "%s: rod %.1f rad out, end r=%.1f at %s is out of view" % [screen_name, angle, radius, p])

## Points round the rim of the Live Wire board (tile corners) and its surge
## emitters, in world space.
func board_points() -> Array:
	var arena: Node3D = main.live_arena
	var grid: RefCounted = arena._grid
	var points: Array = []
	for i in grid.count():
		if not grid.is_edge(i): continue
		var c: Vector2 = grid.centers[i]
		var rim: Vector2 = c + c.normalized() * float(grid.size)
		points.append(arena.to_global(Vector3(rim.x, 0.0, rim.y)))
	for axis in 3:
		for line in range(-grid.radius, grid.radius + 1):
			for at in grid.line_ends(axis, line, arena.EMITTER_OFFSET):
				points.append(arena.to_global(Vector3(at.x, arena.EMITTER_HEIGHT, at.y)))
	return points

## Live Wire: the whole board in view and under none of the HUD.
func check_board(screen_name: String) -> void:
	check_frame(screen_name)
	var cue: Rect2 = main.play.cue.get_global_rect()
	# The call-out's drawn plate, not its whole box (the hint line is empty).
	var blocked: Array = [main.play.status.get_global_rect(), Rect2(cue.position, Vector2(cue.size.x, cue.size.y * 0.8)), main.hud_menu.get_global_rect()]
	for plate in main.play.plates: blocked.append(plate.get_global_rect())
	var camera: Camera3D = main.live_arena.camera
	var worst := 0
	for point in board_points():
		var p := camera.unproject_position(point)
		var hidden := not area().has_point(p)
		for r in blocked:
			if r.has_point(p): hidden = true
		if hidden: worst += 1
	check(worst == 0, "%s: %d board points are off screen or under the HUD" % [screen_name, worst])

## The board on a menu screen stays right of the column's slanted edge.
func check_menu_board(screen_name: String) -> void:
	var top: float = main.LEFT + main.COL + 150.0
	var bottom: float = main.LEFT + main.COL + 36.0
	var camera: Camera3D = main.live_arena.camera
	var behind := 0
	for point in board_points():
		var p := camera.unproject_position(point)
		var edge: float = top - p.y * (top - bottom) / main.area.y
		if p.x < edge or p.x > main.area.x: behind += 1
	check(behind == 0, "%s: %d board points are behind the menu column or off screen" % [screen_name, behind])

## Runners on a menu screen stay to the right of the column's slanted edge.
func check_menu_scene(screen_name: String) -> void:
	var top: float = main.LEFT + main.COL + 150.0
	var bottom: float = main.LEFT + main.COL + 36.0
	for r in main.arena.runners:
		if not r.visual.visible: continue
		for lift in [0.0, 1.3]:
			var p := project(r.visual.global_position + Vector3(0, lift, 0))
			var edge: float = top - p.y * (top - bottom) / main.area.y + 30.0
			check(p.x > edge and p.x < main.area.x and p.y > 0 and p.y < main.area.y, "%s: runner at %s is behind the menu column (edge %.0f)" % [screen_name, p, edge])

func sweep(screen_name: String, extra: Callable = Callable()) -> void:
	for size in sizes:
		await resize(size)
		check_controls(screen_name)
		check_modal(screen_name)
		if extra.is_valid(): extra.call(screen_name)
		await shot(screen_name)

func run() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.test_mode = true
	main.sound_enabled = false
	main.name_field.text = "PLAYER ONE"
	await create_timer(0.6).timeout
	await sweep("menu", check_menu_scene)
	main._open_join()
	await sweep("join-dialog")
	main._clear_overlay()
	main._rules()
	await sweep("rules")
	main._clear_overlay()
	main.port_field = null
	main.server_port = 19787
	main._host()
	assert(main.view == "lobby")
	await sweep("lobby", check_menu_scene)
	main.session.start_round()
	main.model.countdown = 0.0
	main.model.phase = "running"
	for p in main.model.players: p.bot = true
	await create_timer(0.8).timeout
	await sweep("game", check_hud)
	var hp := [3, 5, 1, 0, 6, 2]
	var score := [41, 38, 44, 12, 40, 31]
	for i in 6:
		main.model.players[i].hp = hp[i]
		main.model.players[i].score = score[i]
		main.model.players[i].out_at = 21.0 if hp[i] == 0 else -1.0
	main.model.players[5].hp = 0
	main.model.players[5].out_at = 72.0
	main.model.elapsed = 72.0
	await create_timer(0.6).timeout
	await sweep("late", check_hud)
	main._toggle_pause()
	await sweep("party")
	main._toggle_pause()
	for p in main.model.players:
		p.hp = 0
		p.out_at = 30.0
	main.model.players[2].hp = 4
	main.model.players[2].out_at = -1.0
	main.model.phase = "finished"
	await create_timer(0.3).timeout
	assert(main.view == "results")
	await sweep("results")
	main.session.lobby()
	main._leave()
	main.session.solo("PLAYER ONE")
	main.session.start_round()
	for p in main.model.players:
		p.hp = 0
		p.out_at = 40.0
	main.model.players[0].hp = 4
	main.model.players[0].out_at = -1.0
	main.model.players[0].score = 37
	main.model.players[0].best_streak = 14
	main.model.elapsed = 58.0
	main.model.phase = "finished"
	main._show_results()
	await sweep("results-solo")
	main._leave()
	await live_wire()
	main.queue_free()
	await process_frame
	for failure in failures:
		print("SIZE_FAIL ", failure)
	if failures.is_empty():
		print("SCREEN_SIZES_PASS %d sizes, %d checks" % [sizes.size(), checks])
		quit()
	else:
		print("SCREEN_SIZES_FAILED %d of %d checks" % [failures.size(), checks])
		quit(1)

## Live Wire: picked on the menu, a party lobby with the game picker, a round
## on the hex floor and its results.
func live_wire() -> void:
	main._select_game("livewire")
	assert(main.session.game == "livewire")
	await create_timer(0.3).timeout
	await sweep("lw-menu", check_menu_board)
	main._rules("livewire")
	await sweep("lw-rules")
	main._clear_overlay()
	main.port_field = null
	main.server_port = 19788
	main._host()
	assert(main.view == "lobby")
	await sweep("lw-lobby", check_menu_board)
	main.session.start_round()
	assert(main.play == main.games["livewire"])
	main.model.countdown = 0.0
	main.model.phase = "running"
	for p in main.model.players: p.bot = true
	await create_timer(1.0).timeout
	await sweep("lw-game", check_board)
	main.model.elapsed = 89.7
	for i in 900:
		await process_frame
		if main.view == "results": break
	assert(main.view == "results")
	await sweep("lw-results")
	main.session.lobby()
	main._leave()
