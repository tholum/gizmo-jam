extends SceneTree
## Low's baked-light shaders against the lit ones they replace, on one frozen
## frame of a Spin Cycle round: same camera, same poses, only the structure and
## deck shaders swapped. Saves both shots and a x4 difference image under
## test-output/low-bake/, and prints `BAKE_DIFF {json}` with the mean and 99th
## percentile per-channel difference (0..255) over the whole frame.
##
##   xvfb-run -a godot --path . --audio-driver Dummy --script tests/low_bake_compare.gd [-- --size=WxH]
##
## Calibration switches (--isolate=...), each saving baked<name>/lit<name>.png:
##   key | ambient   one light term only (the other set to zero, both sides)
##   const[_key|_amb] the baked light values compiled in as constants
##   flat<value>     the deck as an unshaded ALBEDO = vec3(value): shows how
##                   the renderer treats unshaded ALBEDO (as sRGB; see BAKED_LIGHT)
##   hidekey | env0 | rebake   checks that the light node and the Environment do
##                   not reach the unshaded shaders, and that baking late changes nothing

const Kit := preload("res://scripts/arena_kit.gd")
var resolution := Vector2i(1280, 720)
var isolate := ""

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--isolate="): isolate = arg.trim_prefix("--isolate=")
		if arg.begins_with("--size="):
			var parts := arg.trim_prefix("--size=").split("x")
			resolution = Vector2i(int(parts[0]), int(parts[1]))
	run.call_deferred()

func shot() -> Image:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func run() -> void:
	root.size = resolution
	DirAccess.make_dir_recursive_absolute("res://test-output/low-bake")
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.test_mode = true
	main.sound_enabled = false
	main.graphics_level = "low"
	main._apply_graphics()
	main.preferred_game = "twisted"
	main.session.select_game("twisted")
	main.session.solo("PLAYER ONE")
	main.session.start_round()
	main.model.begin(74219, main.model.players.duplicate(true), main.model.round_id)
	await process_frame
	main.model.countdown = 0.0
	main.model.phase = "running"
	for p in main.model.players: p.bot = true
	await create_timer(1.5).timeout
	# Freeze everything that moves.
	main.set_process(false)
	main.set_physics_process(false)
	var arena: Node3D = main.arena
	arena.set_process(false)
	for r in arena.runners:
		if r.visual.anim: r.visual.anim.speed_scale = 0.0
	for p in arena.find_children("*", "CPUParticles3D", true, false):
		p.visible = false
	# Calibration: one light term at a time (--isolate=key|ambient).
	if isolate == "key":
		arena.environment.ambient_light_energy = 0.0
	elif isolate == "rebake":
		pass
	elif isolate.begins_with("flat"):
		var sh := Shader.new()
		sh.code = "shader_type spatial;\nrender_mode unshaded;\nvoid fragment(){ ALBEDO = vec3(%s); }" % isolate.trim_prefix("flat")
		arena.belt_material.shader = sh
	elif isolate.begins_with("const"):
		var kl := "vec3(0.0)" if isolate == "const_amb" else "vec3(1.05, 0.941083, 0.751478)"
		var al := "vec3(0.0)" if isolate == "const_key" else "vec3(0.613282, 0.949894, 0.914936)"
		for mat in [arena.solid_material, arena.belt_material]:
			var code: String = mat.shader.code
			code = code.replace("uniform vec3 key_dir = vec3(0.28, 0.9, 0.36);", "const vec3 key_dir = vec3(0.277514, 0.892008, 0.356803);")
			code = code.replace("uniform vec3 key_light = vec3(1.0);", "const vec3 key_light = " + kl + ";")
			code = code.replace("uniform vec3 ambient_light = vec3(0.6);", "const vec3 ambient_light = " + al + ";")
			var sh := Shader.new()
			sh.code = code
			mat.shader = sh
	elif isolate == "env0":
		arena.environment.ambient_light_energy = 0.0
	elif isolate == "hidekey":
		arena.key_light.visible = false
	elif isolate == "ambient":
		arena.key_light.visible = false
		arena.key_light.light_energy = 0.0
	if isolate != "" and isolate != "env0":
		arena._bake_light([arena.solid_material, arena.belt_material])
	for k in ["key_dir", "key_light", "ambient_light"]:
		print("UNIFORM ", k, " solid=", arena.solid_material.get_shader_parameter(k), " deck=", arena.belt_material.get_shader_parameter(k))
	var baked: Image = await shot()
	if isolate == "hidekey":
		arena.key_light.visible = true
	arena.solid_material.shader = Kit.shader(Kit.SOLID_SHADER)
	arena.belt_material.shader = Kit.shader(Kit.DECK_SHADER)
	var lit: Image = await shot()
	baked.save_png("res://test-output/low-bake/baked%s.png" % isolate)
	lit.save_png("res://test-output/low-bake/lit%s.png" % isolate)
	var diff := Image.create(lit.get_width(), lit.get_height(), false, Image.FORMAT_RGB8)
	var hist := PackedInt32Array()
	hist.resize(256)
	var total := 0.0
	var signed := Vector3.ZERO
	var n := 0
	for y in lit.get_height():
		for x in lit.get_width():
			var a := lit.get_pixel(x, y)
			var b := baked.get_pixel(x, y)
			var d := Vector3(b.r - a.r, b.g - a.g, b.b - a.b) * 255.0
			signed += d
			var m := maxf(absf(d.x), maxf(absf(d.y), absf(d.z)))
			hist[clampi(int(m), 0, 255)] += 1
			total += (absf(d.x) + absf(d.y) + absf(d.z)) / 3.0
			n += 1
			diff.set_pixel(x, y, Color(minf(absf(d.x) * 4.0 / 255.0, 1.0), minf(absf(d.y) * 4.0 / 255.0, 1.0), minf(absf(d.z) * 4.0 / 255.0, 1.0)))
	diff.save_png("res://test-output/low-bake/diff_x4.png")
	var acc := 0
	var p99 := 0
	for i in 256:
		acc += hist[i]
		if acc >= n * 0.99:
			p99 = i
			break
	print("BAKE_DIFF ", JSON.stringify({"mean_abs": snappedf(total / n, 0.01), "p99_max_channel": p99,
		"mean_signed_rgb": [snappedf(signed.x / n, 0.01), snappedf(signed.y / n, 0.01), snappedf(signed.z / n, 0.01)],
		"size": "%dx%d" % [resolution.x, resolution.y], "isolate": isolate}))
	quit()
