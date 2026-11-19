extends SceneTree
## Where does a frame go? Starts the same bot round as graphics_probe.gd, then
## times the running round with one thing switched off at a time, all in one
## process. Every variant is measured right after a fresh baseline (A/B), so
## the round changing underneath (speed-ups, knockouts) does not skew it, and
## Spin Cycle's bots are made unbeatable so the round never ends mid-run.
## Output: `DIAG {json}` per variant with delta_ms = variant - its baseline.
##
## Arguments (after `--`):
##   --game=twisted|livewire   (default twisted)
##   --level=low|balanced|high (default low)
##   --size=WxH                (default 1280x720)
##   --secs=S                  seconds per measurement (default 2.0)
##   --only=a,b                only these variants
##   --skip-to=name            start at this variant (later ones still run)

var game := "twisted"
var level := "low"
var resolution := Vector2i(1280, 720)
var secs := 2.0
var only: PackedStringArray = []
var sv: SubViewport
var sv_cam: Camera3D
var sv_layer: CanvasLayer
var main: Node
## Saved state for a variant's restore. A member, not a local: lambdas copy
## captured locals, so a local assigned in `on` is never seen by `off`.
var held: Array = []
var active: Node3D
var other: Node3D

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--game="): game = arg.trim_prefix("--game=")
		if arg.begins_with("--level="): level = arg.trim_prefix("--level=")
		if arg.begins_with("--secs="): secs = float(arg.trim_prefix("--secs="))
		if arg.begins_with("--only="): only = arg.trim_prefix("--only=").split(",")
		if arg.begins_with("--size="):
			var parts := arg.trim_prefix("--size=").split("x")
			resolution = Vector2i(int(parts[0]), int(parts[1]))
	run.call_deferred()

func keep_alive() -> void:
	if game == "livewire":
		main.model.elapsed = 20.0
	else:
		for p in main.model.players: p.hp = 1000

func sample() -> Dictionary:
	keep_alive()
	await create_timer(0.4).timeout
	var frames: Array[float] = []
	var deadline := Time.get_ticks_msec() + int(secs * 1000.0)
	while Time.get_ticks_msec() < deadline:
		var before := Time.get_ticks_usec()
		await process_frame
		frames.append((Time.get_ticks_usec() - before) / 1000.0)
	var mean := 0.0
	for f in frames: mean += f
	mean /= frames.size()
	frames.sort()
	return {"mean": mean, "p95": frames[int(frames.size() * 0.95)],
		"draws": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"prims": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)}

func variant(name_value: String, on: Callable, off: Callable) -> void:
	if not only.is_empty() and name_value not in only:
		return
	var a: Dictionary = await sample()
	on.call()
	var b: Dictionary = await sample()
	off.call()
	print("DIAG ", JSON.stringify({"name": name_value, "base_ms": snappedf(a.mean, 0.1), "ms": snappedf(b.mean, 0.1),
		"delta_ms": snappedf(b.mean - a.mean, 0.1), "p95_ms": snappedf(b.p95, 0.1),
		"draws": b.draws, "base_draws": a.draws, "prims": b.prims, "base_prims": a.prims}))

func sv_on(frac: float) -> void:
	var cam: Camera3D = active.camera
	sv = SubViewport.new()
	sv.size = Vector2i(Vector2(root.size) * frac)
	sv.world_3d = root.world_3d
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv_cam = Camera3D.new()
	sv.add_child(sv_cam)
	root.add_child(sv)
	sv_cam.current = true
	sv_layer = CanvasLayer.new()
	sv_layer.layer = -100
	var rect := TextureRect.new()
	rect.texture = sv.get_texture()
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sv_layer.add_child(rect)
	root.add_child(sv_layer)
	root.disable_3d = true
	process_frame.connect(sv_sync)
	sv_sync()

func sv_sync() -> void:
	var cam: Camera3D = active.camera
	sv_cam.global_transform = cam.global_transform
	sv_cam.fov = cam.fov
	sv_cam.near = cam.near
	sv_cam.far = cam.far
	sv_cam.keep_aspect = cam.keep_aspect
	sv_cam.h_offset = cam.h_offset
	sv_cam.v_offset = cam.v_offset
	sv_cam.cull_mask = cam.cull_mask

func sv_off() -> void:
	process_frame.disconnect(sv_sync)
	root.disable_3d = false
	sv.queue_free()
	sv_layer.queue_free()

func layers(node: Node, out: Array) -> void:
	if node is CanvasLayer: out.append(node)
	for c in node.get_children(): layers(c, out)

func set_all(nodes: Array, prop: String, value: Variant) -> Array:
	var old: Array = []
	for n in nodes:
		if is_instance_valid(n):
			old.append(n.get(prop))
			n.set(prop, value)
		else:
			old.append(null)
	return old

func restore(nodes: Array, prop: String, old: Array) -> void:
	for i in nodes.size():
		if is_instance_valid(nodes[i]) and old[i] != null: nodes[i].set(prop, old[i])

## Every VisualInstance3D at or under these nodes. Hiding goes through render
## `layers`, which the game never touches (it does set `visible` every frame).
func geoms(nodes: Array) -> Array:
	var out: Array = []
	for n in nodes:
		if not is_instance_valid(n): continue
		if n is VisualInstance3D: out.append(n)
		out.append_array(n.find_children("*", "VisualInstance3D", true, false))
	return out

func hide3d(name_value: String, nodes: Array) -> void:
	var g := geoms(nodes)
	await variant("%s(%d)" % [name_value, g.size()], func(): held = set_all(g, "layers", 0), func(): restore(g, "layers", held))

func run() -> void:
	root.size = resolution
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.test_mode = true
	main.sound_enabled = false
	main.graphics_level = level
	main._apply_graphics()
	main.preferred_game = game
	main.session.select_game(game)
	main._show_menu()
	await create_timer(0.5).timeout
	main.session.solo("PLAYER ONE")
	main.session.start_round()
	main.model.begin(74219, main.model.players.duplicate(true), main.model.round_id)
	await process_frame
	main.model.countdown = 0.0
	main.model.phase = "running"
	for p in main.model.players: p.bot = true
	keep_alive()
	await create_timer(1.5).timeout
	active = main.live_arena if game == "livewire" else main.arena
	other = main.arena if game == "livewire" else main.live_arena
	print("DIAG_INFO ", JSON.stringify({"game": game, "level": level, "size": "%dx%d" % [resolution.x, resolution.y],
		"scale": root.scaling_3d_scale, "msaa": root.msaa_3d, "adapter": RenderingServer.get_video_adapter_name(),
		"other_visible": other.visible}))

	var cls: Array = []
	layers(root, cls)
	await variant("no_2d", func(): held = set_all(cls, "visible", false), func(): restore(cls, "visible", held))
	var sview: Node = main.scaled_view
	if sview and sview.enabled():
		# Low through scripts/scaled_view.gd: the root draws no 3D itself.
		var base_scale: float = sview.scale
		await variant("no_3d", func(): sview.view.render_target_update_mode = SubViewport.UPDATE_DISABLED; sview.layer.visible = false,
			func(): sview.view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; sview.layer.visible = true)
		for scale in [1.0, 0.5, 0.33]:
			await variant("sv_scale_%s" % str(scale), func(): sview.set_scale(scale), func(): sview.set_scale(base_scale))
		await variant("builtin_scaling_instead", func(): sview.set_scale(1.0), func(): sview.set_scale(base_scale))
	else:
		await variant("no_3d", func(): root.disable_3d = true, func(): root.disable_3d = false)
		var s: float = root.scaling_3d_scale
		for scale in [1.0, 0.5, 0.33]:
			await variant("scale_%s" % str(scale), func(): root.scaling_3d_scale = scale, func(): root.scaling_3d_scale = s)

	var lights: Array = active.find_children("*", "Light3D", true, false)
	await variant("no_lights", func(): held = set_all(lights, "visible", false), func(): restore(lights, "visible", held))
	var envs: Array = active.find_children("*", "WorldEnvironment", true, false)
	var env: Environment = envs[0].environment if not envs.is_empty() else null
	if env:
		var tm := env.tonemap_mode
		await variant("tonemap_linear", func(): env.tonemap_mode = Environment.TONE_MAPPER_LINEAR, func(): env.tonemap_mode = tm)

	var visuals: Array = []
	for r in active.runners: visuals.append(r.visual)
	await hide3d("runners_hidden", visuals)
	var anims: Array = []
	for v in visuals: if v.anim: anims.append(v.anim)
	await variant("runner_anims_paused", func(): held = set_all(anims, "speed_scale", 0.0), func(): restore(anims, "speed_scale", held))
	var extras: Array = []
	for v in visuals:
		for prop in ["ring", "shadow", "planar"]:
			var n: Variant = v.get(prop)
			if n is Node3D: extras.append(n)
	await hide3d("runner_rings_shadows_hidden", extras)
	await hide3d("particles_hidden", active.find_children("*", "CPUParticles3D", true, false))
	# Scenery (not under a runner), grouped by material: each shader's meshes
	# hidden together, and all StandardMaterial3D meshes together.
	var groups := {}
	for g in active.find_children("*", "GeometryInstance3D", true, false):
		if not g.is_visible_in_tree(): continue
		var under_runner := false
		for v in visuals:
			if v.is_ancestor_of(g): under_runner = true
		if under_runner: continue
		var mat: Material = g.material_override
		if mat == null and g is MeshInstance3D and g.mesh and g.mesh.get_surface_count() > 0:
			mat = g.get_active_material(0)
		var key := "standard"
		if mat is ShaderMaterial and mat.shader:
			key = mat.shader.code.get_slice("//", 1).get_slice("\n", 0).strip_edges().left(36)
		elif g is CPUParticles3D: key = "particles"
		elif mat == null: key = "none:" + g.get_class()
		if not groups.has(key): groups[key] = []
		groups[key].append(g)
	var all_scenery: Array = []
	for key in groups: all_scenery.append_array(groups[key])
	await hide3d("all_scenery_hidden", all_scenery)
	for key in groups:
		await hide3d("scenery:" + key, groups[key])
	var cam: Camera3D = active.camera
	var mask := cam.cull_mask
	await variant("empty_3d(cull_mask=0)", func(): cam.cull_mask = 0, func(): cam.cull_mask = mask)
	var s2: float = root.scaling_3d_scale
	await variant("empty_3d_scale_1", func(): cam.cull_mask = 0; root.scaling_3d_scale = 1.0, func(): cam.cull_mask = mask; root.scaling_3d_scale = s2)

	# Round 4: what makes the scaled 3D path cost, and cheaper shading.
	await variant("empty_3d_scale_0.99", func(): cam.cull_mask = 0; root.scaling_3d_scale = 0.99, func(): cam.cull_mask = mask; root.scaling_3d_scale = s2)
	if env:
		var tm2 := env.tonemap_mode
		await variant("empty_3d_scaled_linear", func(): cam.cull_mask = 0; env.tonemap_mode = Environment.TONE_MAPPER_LINEAR, func(): cam.cull_mask = mask; env.tonemap_mode = tm2)
		await variant("empty_3d_scaled_no_env", func(): cam.cull_mask = 0; envs[0].environment = null, func(): cam.cull_mask = mask; envs[0].environment = env)
		await variant("scale_1_linear", func(): root.scaling_3d_scale = 1.0; env.tonemap_mode = Environment.TONE_MAPPER_LINEAR, func(): root.scaling_3d_scale = s2; env.tonemap_mode = tm2)
	var mats := {}
	for g in active.find_children("*", "GeometryInstance3D", true, false):
		var list: Array = []
		if g.material_override: list.append(g.material_override)
		if g is MeshInstance3D and g.mesh:
			for i in g.mesh.get_surface_count():
				var m: Material = g.get_active_material(i)
				if m: list.append(m)
		for m in list: mats[m] = true
	var lit_shaders: Array = []
	var std: Array = []
	for m in mats:
		if m is ShaderMaterial and m.shader and not ("unshaded" in m.shader.code.get_slice("void", 0)):
			lit_shaders.append(m)
		elif m is StandardMaterial3D and m.shading_mode == BaseMaterial3D.SHADING_MODE_PER_PIXEL:
			std.append(m)
	var originals := {}
	for m in lit_shaders: originals[m] = m.shader
	for mode in ["vertex_lighting", "unshaded"]:
		var swapped := {}
		for m in lit_shaders:
			var sh := Shader.new()
			var code: String = originals[m].code
			if code.contains("render_mode "):
				code = code.replace("render_mode ", "render_mode %s, " % mode)
			else:
				code = code.replace("shader_type spatial;", "shader_type spatial;\nrender_mode %s;" % mode)
			sh.code = code
			swapped[m] = sh
		var std_mode := BaseMaterial3D.SHADING_MODE_PER_VERTEX if mode == "vertex_lighting" else BaseMaterial3D.SHADING_MODE_UNSHADED
		await variant("all_%s(%d shaders,%d std)" % [mode, lit_shaders.size(), std.size()],
			func():
				for m in lit_shaders: m.shader = swapped[m]
				for m in std: m.shading_mode = std_mode,
			func():
				for m in lit_shaders: m.shader = originals[m]
				for m in std: m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL)
	for m in lit_shaders:
		if originals[m].code.contains("The conveyor deck"):
			var plain := Shader.new()
			plain.code = "shader_type spatial;\nuniform float belt = 0.0;\nuniform float boost = 0.0;\nvoid fragment(){ ALBEDO = vec3(0.30, 0.33, 0.39); ROUGHNESS = 0.78; SPECULAR = 0.3; }"
			await variant("deck_plain_shader", func(): m.shader = plain, func(): m.shader = originals[m])
	# Round 5: 3D drawn into a SubViewport at a lower size and shown as a
	# texture, instead of the root viewport's built-in 3D scaling.
	for frac in [0.67, 0.5]:
		await variant("subviewport_%s" % str(frac), func(): sv_on(frac), func(): sv_off())
	# Unlit scenery, runners still lit.
	var scenery_lit: Array = []
	for m in lit_shaders:
		if not originals[m].code.contains("RUNNER") and not originals[m].code.contains("runner"):
			scenery_lit.append(m)
	var unlit := {}
	for m in scenery_lit:
		var sh := Shader.new()
		var code: String = originals[m].code
		code = code.replace("render_mode ", "render_mode unshaded, ") if code.contains("render_mode ") else code.replace("shader_type spatial;", "shader_type spatial;\nrender_mode unshaded;")
		sh.code = code
		unlit[m] = sh
	await variant("scenery_unshaded_runners_lit(%d)" % scenery_lit.size(), func():
		for m in scenery_lit: m.shader = unlit[m], func():
		for m in scenery_lit: m.shader = originals[m])
	await hide3d("label3d_hidden", active.find_children("*", "Label3D", true, false))
	# HUD breakdown: children of the busiest top-level Control.
	var busiest: Control = null
	for c in main.canvas.get_children():
		for cc in c.get_children():
			if cc is Control and cc.visible and (busiest == null or cc.get_child_count() > busiest.get_child_count()): busiest = cc
	if busiest:
		for c in busiest.get_children():
			if c is CanvasItem and c.visible:
				var label := "%s(%s,%d,%s)" % [c.name, c.get_class(), c.get_child_count(), c.get_script().resource_path.get_file() if c.get_script() else "-"]
				await variant("hud:" + label, func(): c.visible = false, func(): c.visible = true)
	# 2D: each top-level Control under the main canvas, and the HUD's children.
	var controls: Array = []
	for c in main.canvas.get_children():
		for cc in c.get_children():
			if cc is CanvasItem and cc.visible: controls.append(cc)
	for c in controls:
		await variant("hide_2d:%s(%s,%d)" % [c.name, c.get_class(), c.get_child_count()], func(): c.visible = false, func(): c.visible = true)
	for l in cls:
		if l != main.canvas:
			await variant("hide_layer:%s" % l.name, func(): l.visible = false, func(): l.visible = true)
	print("DIAG_DONE")
	quit()
