extends SceneTree
## Renders the round HUD widgets in every state they draw (plates, Live Wire
## plates, status, cue, slam) over a busy background, saves one PNG per page
## and prints draw-call counts. Used to prove that a change to how the HUD is
## drawn leaves it looking the same: shoot before, shoot after, then compare
## with tests/hud_batch_compare.py.
##
##   xvfb-run -a godot --path . --audio-driver Dummy --script tests/hud_batch_shots.gd \
##       -- --out=/tmp/hud_after [--sizes=1280x720,1920x1080]
##
## Output: <out>/<W>x<H>/<page>.png, plus lines on stdout:
##   PAGE <WxH> <page> RENDER_TOTAL_DRAW_CALLS_IN_FRAME=<n>
##   WIDGET <WxH> <state> draws=<n>          (that widget alone, background subtracted)

const Kit = preload("res://scripts/ui_kit.gd")
const Plate = preload("res://scripts/hud_plate.gd")
const WirePlate = preload("res://scripts/hud_wire_plate.gd")
const Status = preload("res://scripts/hud_status.gd")
const Cue = preload("res://scripts/hud_cue.gd")
const Slam = preload("res://scripts/hud_slam.gd")

var out_dir := "res://test-output/hud_batch"
var sizes: Array = [Vector2i(1280, 720), Vector2i(1920, 1080)]
var page: Control
var backdrop: TextureRect

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): out_dir = arg.trim_prefix("--out=")
		if arg.begins_with("--sizes="):
			sizes.clear()
			for part in arg.trim_prefix("--sizes=").split(",", false):
				var wh := part.split("x")
				sizes.append(Vector2i(int(wh[0]), int(wh[1])))
	call_deferred("run")

## A coarse, deterministic patchwork, stretched with linear filtering, so the
## translucent shadows and feathered edges blend over varied colours.
func make_backdrop() -> TextureRect:
	var img := Image.create(64, 36, false, Image.FORMAT_RGB8)
	var seed_value := 7
	for y in 36:
		for x in 64:
			seed_value = (seed_value * 1103515245 + 12345) & 0x7fffffff
			var v := float(seed_value % 1000) / 1000.0
			var base := Color(0.03 + 0.25 * float(x) / 64.0, 0.05 + 0.2 * float(y) / 36.0, 0.12 + 0.3 * v)
			if (x / 4 + y / 4) % 5 == 0: base = base.lerp(Color(0.9, 0.85, 0.7), 0.6)
			img.set_pixel(x, y, base)
	var rect := TextureRect.new()
	rect.texture = ImageTexture.create_from_image(img)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	rect.position = Vector2.ZERO
	rect.size = Vector2(1600, 900)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect

func settle() -> void:
	for i in 4:
		await process_frame

func new_page() -> void:
	if page: page.queue_free()
	await process_frame
	page = Control.new()
	page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.size = Vector2(1600, 900)
	root.add_child(page)

func draws_now() -> int:
	await settle()
	await RenderingServer.frame_post_draw
	await process_frame
	return int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))

func shoot(name_value: String) -> void:
	await settle()
	await RenderingServer.frame_post_draw
	var folder := "%s/%dx%d" % [out_dir, root.size.x, root.size.y]
	DirAccess.make_dir_recursive_absolute(folder)
	root.get_texture().get_image().save_png(folder + "/" + name_value + ".png")
	await process_frame
	var calls := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	print("PAGE %dx%d %s RENDER_TOTAL_DRAW_CALLS_IN_FRAME=%d" % [root.size.x, root.size.y, name_value, calls])

# --- widget states -----------------------------------------------------------
# Each state is [name, Callable(parent) -> Control]; the callable builds the
# widget, sets its state directly (no tweens left running) and returns it.

func plate(c: int, p: Dictionary, role: String, own: bool, anim: Dictionary = {}) -> Control:
	var w = Plate.new()
	w.setup(Kit.colors[c % 6], p, role, own)
	for k in anim: w.set(k, anim[k])
	return w

func wire(c: int, p: Dictionary, role: String, own: bool, anim: Dictionary = {}) -> Control:
	var w = WirePlate.new()
	w.setup(Kit.colors[c % 6], p, role, own)
	for k in anim: w.set(k, anim[k])
	return w

func plate_states() -> Array:
	return [
		["plate_own", func(): return plate(0, {"name": "PLAYER ONE", "hp": 7, "score": 0}, "YOU", true)],
		["plate_cpu", func(): return plate(1, {"name": "BOLT", "hp": 7, "score": 12}, "CPU", false)],
		["plate_p2_low", func(): return plate(2, {"name": "GADGET", "hp": 2, "score": 5}, "P2", false)],
		["plate_cpu_3digit", func(): return plate(3, {"name": "SPROCKET", "hp": 4, "score": 123}, "CPU", false)],
		["plate_out", func(): return plate(4, {"name": "WIDGET", "hp": 0, "score": 9}, "CPU", false)],
		["plate_out_own", func(): return plate(0, {"name": "PLAYER ONE", "hp": 0, "score": 31}, "YOU", true)],
		["plate_out_slam", func(): return plate(5, {"name": "COG", "hp": 0, "score": 3}, "P3", false, {"stamp": 0.45, "flash": 0.5, "shake": 0.35, "lost_block": 6})],
		["plate_hit", func(): return plate(1, {"name": "BOLT", "hp": 5, "score": 8}, "CPU", false, {"flash": 0.7, "shake": 0.3, "lost_block": 1})],
		["plate_hit_late", func(): return plate(2, {"name": "GADGET", "hp": 3, "score": 8}, "P2", false, {"flash": 0.25, "shake": 0.8, "lost_block": 3})],
		["plate_pop", func(): return plate(3, {"name": "SPROCKET", "hp": 6, "score": 14}, "CPU", false, {"pop": 0.6})],
		["plate_pop_own", func(): return plate(0, {"name": "PLAYER ONE", "hp": 1, "score": 99}, "YOU", true, {"pop": 1.0})],
		["plate_scaled_small", func():
			var w := plate(4, {"name": "WIDGET", "hp": 7, "score": 2}, "CPU", false)
			w.scale = Vector2(0.75, 0.75)
			return w],
		["plate_own_big", func():
			var w := plate(0, {"name": "PLAYER ONE", "hp": 6, "score": 7}, "YOU", true)
			w.scale = Vector2(1.1, 1.1)
			return w],
		["plate_long_name", func(): return plate(5, {"name": "EXTRAORDINARILY LONG", "hp": 7, "score": 0}, "P6", false)],
	]

func wire_states() -> Array:
	return [
		["wire_own_ready", func(): return wire(0, {"name": "PLAYER ONE", "tiles": 12}, "YOU", true)],
		["wire_cpu_charging", func(): return wire(1, {"name": "BOLT", "tiles": 7}, "CPU", false, {"charge": 0.4})],
		["wire_first", func(): return wire(2, {"name": "GADGET", "tiles": 40}, "CPU", false, {"leading": true, "crown": 1.0})],
		["wire_first_landing", func(): return wire(3, {"name": "SPROCKET", "tiles": 38}, "P2", false, {"leading": true, "crown": 0.5, "charge": 0.75})],
		["wire_zap", func(): return wire(4, {"name": "WIDGET", "tiles": 3}, "CPU", false, {"stunned": true, "stamp": 1.0, "charge": 0.2})],
		["wire_zap_slam", func(): return wire(5, {"name": "COG", "tiles": 5}, "P3", false, {"stunned": true, "stamp": 0.5, "flash": 0.6, "shake": 0.4})],
		["wire_spark", func(): return wire(1, {"name": "BOLT", "tiles": 9}, "CPU", false, {"spark": 0.6})],
		["wire_pop", func(): return wire(2, {"name": "GADGET", "tiles": 123}, "CPU", false, {"pop": 0.8, "charge": 0.1})],
		["wire_own_leading", func(): return wire(0, {"name": "PLAYER ONE", "tiles": 55}, "YOU", true, {"leading": true, "crown": 1.0, "charge": 0.0})],
		["wire_hit_flash", func(): return wire(3, {"name": "SPROCKET", "tiles": 2}, "CPU", false, {"flash": 0.5, "shake": 0.2, "charge": 0.55})],
		["wire_scaled_small", func():
			var w := wire(4, {"name": "WIDGET", "tiles": 17}, "P4", false, {"charge": 0.9})
			w.scale = Vector2(0.75, 0.75)
			return w],
	]

func status(build: Callable) -> Control:
	var w = Status.new()
	build.call(w)
	return w

func spin_players(scores: Array, hps: Array) -> Array:
	var out: Array = []
	for i in 6: out.append({"score": scores[i], "hp": hps[i]})
	return out

func status_states() -> Array:
	return [
		["status_warmup", func(): return status(func(w): w.sync(12.3, 1.0, 0, spin_players([0, 0, 0, 0, 0, 0], [7, 7, 7, 7, 7, 7]), 0))],
		["status_speeding", func(): return status(func(w):
			w.sync(75.0, 1.37, 1, spin_players([12, 9, 3, 12, 0, 6], [7, 0, 4, 2, 0, 5]), 3)), func(w): w.bump = 0.5],
		["status_overdrive_leader", func(): return status(func(w): w.sync(201.0, 2.25, 2, spin_players([30, 22, 18, 5, 2, 29], [3, 0, 1, 0, 0, 2]), 5))],
		["status_wire_hurry", func(): return status(func(w):
			w.show_status("0:07", "SURGE ×3", "OVERDRIVE · NO LOCKS", 2, [40, 12, 33, 8, 25, 40], [true, true, true, true, true, true], [1.0, 0.3, 0.82, 0.2, 0.62, 1.0], 1, true)), func(w): w.tick = 0.6],
		["status_wire_calm", func(): return status(func(w):
			w.show_status("1:42", "SURGE ×1", "WARM-UP", 0, [5, 4, 9, 2, 1, 3], [true, true, true, true, true, true], [0.55, 0.44, 1.0, 0.22, 0.11, 0.33], 2, false))],
	]

func cue(build: Callable) -> Control:
	var w = Cue.new()
	build.call(w)
	w.set_process(false)
	return w

func cue_states() -> Array:
	return [
		["cue_jump", func(): return cue(func(w): w.sync("jump", 1, "1.4s", 0.3, false, "SPACE TO JUMP"))],
		["cue_duck_now", func(): return cue(func(w): w.sync("duck", 2, "0.2s", 0.95, true, ""))],
		["cue_jump_punch", func(): return cue(func(w): w.sync("jump", 3, "0.0s", 1.0, true, "")), func(w):
			w.punch = 0.5
			w.drop = 0.4],
		["cue_surge", func(): return cue(func(w): w.sync("surge", 4, "3", 0.5, false, "", "SURGE ×3"))],
		["cue_danger", func(): return cue(func(w):
			w.sync("danger", 5, "2", 0.7, false, "STEP OFF THE LINE")), func(w):
			w.set_process(false)
			w._alarm = 0.2
			w.queue_redraw()],
		["cue_danger_now", func(): return cue(func(w):
			w.sync("danger", 6, "0", 1.0, true, "")), func(w):
			w.set_process(false)
			w._alarm = 0.65
			w.punch = 0.0],
		["cue_demo_jump", func(): return cue(func(w): w.show_demo("jump", "SPACE"))],
		["cue_demo_duck", func(): return cue(func(w): w.show_demo("duck", "HOLD S"))],
		["cue_demo_move", func(): return cue(func(w): w.show_demo("move", "WASD"))],
		["cue_demo_dash", func(): return cue(func(w): w.show_demo("dash", "SPACE"))],
		["cue_demo_loop", func(): return cue(func(w): w.show_demo("loop", "CLOSE IT"))],
		["cue_tiny_fuse", func(): return cue(func(w): w.sync("duck", 7, "4.9s", 0.0, false, "HOLD S"))],
	]

func slam_states() -> Array:
	return [
		["slam_ring", func():
			var w = Slam.new()
			w.size = Vector2(600, 240)
			w.slam("GO!", Kit.LIME)
			return w],
		["slam_text", func():
			var w = Slam.new()
			w.size = Vector2(600, 240)
			w.pop("+3", Kit.GOLD)
			return w],
	]

## Fixes the animation channels after the tweens have run out, so every run
## captures the same frame.
func freeze(w: Control, entry: Array) -> void:
	var state: String = entry[0]
	if entry.size() > 2:
		entry[2].call(w)
	if w is Slam:
		if state == "slam_ring":
			w.grow = 0.3
			w.ring = 0.4
		else:
			w.grow = 0.1
		w.jitter = 0.0
		w.alpha = 1.0

func build(entry: Array) -> Control:
	var w: Control = entry[1].call()
	return w

## Lays `states` out on a grid of `cell` units starting at `origin`.
func page_of(states: Array, cell: Vector2, cols: int, origin: Vector2 = Vector2(20, 20)) -> Array:
	var built: Array = []
	for i in states.size():
		var w := build(states[i])
		w.position = origin + Vector2(i % cols, i / cols) * cell
		page.add_child(w)
		built.append([w, states[i]])
	await settle()
	for b in built: freeze(b[0], b[1])
	await settle()
	return built

func run() -> void:
	Kit.setup()
	Kit.speed = 1000.0
	for s in sizes:
		root.size = s
		for i in 30:
			await process_frame
			if root.size == s: break
		var label := "%dx%d" % [s.x, s.y]
		# Baseline: just the backdrop.
		await new_page()
		page.add_child(make_backdrop())
		await settle()
		var base := await draws_now()
		print("PAGE %s empty RENDER_TOTAL_DRAW_CALLS_IN_FRAME=%d" % [label, base])
		# Each state alone, for its own draw-call count.
		for group in [plate_states(), wire_states(), status_states(), cue_states(), slam_states()]:
			for entry in group:
				await new_page()
				page.add_child(make_backdrop())
				var w := build(entry)
				w.position = Vector2(400, 300)
				page.add_child(w)
				await settle()
				freeze(w, entry)
				var n := await draws_now()
				print("WIDGET %s %s draws=%d" % [label, entry[0], n - base])
		# Screenshot pages.
		await new_page()
		page.add_child(make_backdrop())
		await page_of(plate_states(), Vector2(262, 165), 6, Vector2(24, 30))
		await shoot("plates")
		await new_page()
		page.add_child(make_backdrop())
		await page_of(wire_states(), Vector2(262, 150), 6, Vector2(24, 40))
		await shoot("wire_plates")
		await new_page()
		page.add_child(make_backdrop())
		await page_of(status_states(), Vector2(380, 230), 4, Vector2(16, 20))
		await page_of(slam_states(), Vector2(640, 260), 2, Vector2(60, 560))
		await shoot("status_slam")
		await new_page()
		page.add_child(make_backdrop())
		var cues := cue_states()
		await page_of(cues.slice(0, 6), Vector2(520, 150), 3, Vector2(20, 30))
		await page_of(cues.slice(6), Vector2(520, 150), 3, Vector2(20, 480))
		await shoot("cues")
		# A realistic row: six plates as the round lays them out.
		await new_page()
		page.add_child(make_backdrop())
		var row: Array = [plate_states()[0], plate_states()[1], plate_states()[2], plate_states()[7], plate_states()[4], plate_states()[9]]
		await page_of(row, Vector2(250, 0), 6, Vector2(40, 740))
		await page_of([status_states()[1]], Vector2.ZERO, 1, Vector2(28, 16))
		await page_of([cue_states()[0]], Vector2.ZERO, 1, Vector2(565, 12))
		await shoot("round_row")
	print("HUD_BATCH_SHOTS_DONE")
	quit()
