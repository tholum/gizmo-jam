extends SceneTree
## What would each of High's looks cost on this machine? Starts a Low bot round
## (Spin Cycle's bots cannot lose), pins Low's 3D scale (no dynamic resolution),
## then adds one High feature at a time, each timed right after a fresh
## baseline. Also times a few of Low's remaining costs. Prints `QC {json}` per
## variant with delta_ms = variant - baseline.
##
## Arguments (after `--`): --game=twisted|livewire --size=WxH --secs=S --only=a,b

var game := "twisted"
var resolution := Vector2i(1280, 720)
var secs := 2.0
var only: PackedStringArray = []
var main: Node
var held: Array = []

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--game="): game = arg.trim_prefix("--game=")
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
	return {"mean": mean, "p95": frames[int(frames.size() * 0.95)]}

func variant(name_value: String, on: Callable, off: Callable) -> void:
	if not only.is_empty() and name_value not in only and not (only.has("hud") and (name_value.begins_with("cost_hud") or name_value == "cost_scripts_frozen")):
		return
	var a: Dictionary = await sample()
	on.call()
	var b: Dictionary = await sample()
	off.call()
	print("QC ", JSON.stringify({"name": name_value, "base_ms": snappedf(a.mean, 0.1), "ms": snappedf(b.mean, 0.1),
		"delta_ms": snappedf(b.mean - a.mean, 0.1), "p95_ms": snappedf(b.p95, 0.1)}))

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

func geoms(nodes: Array) -> Array:
	var out: Array = []
	for n in nodes:
		if not is_instance_valid(n): continue
		if n is VisualInstance3D: out.append(n)
		out.append_array(n.find_children("*", "VisualInstance3D", true, false))
	return out

func run() -> void:
	root.size = resolution
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.test_mode = true
	main.sound_enabled = false
	main.graphics_level = "low"
	main._apply_graphics()
	main.preferred_game = game
	main.session.select_game(game)
	main.session.solo("PLAYER ONE")
	main.session.start_round()
	main.model.begin(74219, main.model.players.duplicate(true), main.model.round_id)
	await process_frame
	main.model.countdown = 0.0
	main.model.phase = "running"
	for p in main.model.players: p.bot = true
	keep_alive()
	var sview: Node = main.scaled_view
	sview.dynamic = false
	var low_scale: float = sview.ceiling
	sview.set_scale(low_scale)
	await create_timer(1.5).timeout
	var arena: Node3D = main.live_arena if game == "livewire" else main.arena
	print("QC_INFO ", JSON.stringify({"game": game, "size": "%dx%d" % [resolution.x, resolution.y], "scale": sview.scale,
		"adapter": RenderingServer.get_video_adapter_name()}))

	await variant("rt_sv_rgba8", func(): sview.view.transparent_bg = true, func(): sview.view.transparent_bg = false)
	await variant("rt_root_rgba8", func(): root.transparent_bg = true, func(): root.transparent_bg = false)
	await variant("rt_both_rgba8", func(): sview.view.transparent_bg = true; root.transparent_bg = true, func(): sview.view.transparent_bg = false; root.transparent_bg = false)
	await variant("tonemap_linear", func(): arena.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR if "environment" in arena and arena.environment else 0, func(): if "environment" in arena and arena.environment: arena.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC)
	for s in [1.0, 0.8, 0.55]:
		await variant("scale_%s" % str(s), func(): sview.set_scale(s), func(): sview.set_scale(low_scale))
	await variant("add_msaa4", func(): sview.view.msaa_3d = Viewport.MSAA_4X, func(): sview.view.msaa_3d = Viewport.MSAA_DISABLED)
	await variant("add_msaa2", func(): sview.view.msaa_3d = Viewport.MSAA_2X, func(): sview.view.msaa_3d = Viewport.MSAA_DISABLED)
	var visuals: Array = []
	for r in arena.runners: visuals.append(r.visual)
	await variant("add_robot_balanced_mesh", func():
		for v in visuals: v.set_quality("balanced", 0.72), func():
		for v in visuals: v.set_quality("low", 0.72))
	await variant("add_robot_high_mesh_no_silhouette", func():
		for v in visuals: v.set_quality("high", 0.72, false), func():
		for v in visuals: v.set_quality("low", 0.72))
	await variant("add_robot_high_silhouette", func():
		for v in visuals: v.set_quality("high", 0.16, true), func():
		for v in visuals: v.set_quality("low", 0.72))
	if game == "twisted":
		var env: Environment = arena.environment
		await variant("add_fog", func(): env.fog_enabled = true, func(): env.fog_enabled = false)
		await variant("add_fill_lights", func(): held = set_all(arena.fill_lights, "visible", true), func(): restore(arena.fill_lights, "visible", held))
		await variant("add_structure_full", func():
			for n in arena.structure: n.visible = true
			for n in arena.structure_lite: n.visible = false, func():
			for n in arena.structure: n.visible = false
			for n in arena.structure_lite: n.visible = true)
		await variant("add_backdrop_full", func():
			for n in arena.backdrop: n.visible = true
			for n in arena.backdrop_lite: n.visible = false, func():
			for n in arena.backdrop: n.visible = false
			for n in arena.backdrop_lite: n.visible = true)
		await variant("add_high_fx", func(): arena.high_fx.visible = true, func(): arena.high_fx.visible = false)
		await variant("add_hud_shade", func(): arena.hud_shade.visible = true, func(): arena.hud_shade.visible = false)
		var Kit = load("res://scripts/arena_kit.gd")
		await variant("add_deck_lit_full", func(): arena.belt_material.shader = Kit.shader(Kit.DECK_SHADER), func(): arena.belt_material.shader = Kit.shader(Kit.DECK_LOW_SHADER))
		await variant("cost_deck", func(): held = set_all(geoms([arena.find_child("Deck", true, false)]), "layers", 0), func(): restore(geoms([arena.find_child("Deck", true, false)]), "layers", held))
		var dome: Array = []
		for g in arena.find_children("*", "MeshInstance3D", true, false):
			if g.mesh is SphereMesh and g.mesh.radius > 100.0: dome.append(g)
		await variant("cost_dome", func(): held = set_all(dome, "layers", 0), func(): restore(dome, "layers", held))
		await variant("cost_structure_lite", func(): held = set_all(geoms(arena.structure_lite), "layers", 0), func(): restore(geoms(arena.structure_lite), "layers", held))
		await variant("cost_backdrop_lite", func(): held = set_all(geoms(arena.backdrop_lite), "layers", 0), func(): restore(geoms(arena.backdrop_lite), "layers", held))
	await variant("cost_runners", func(): held = set_all(geoms(visuals), "layers", 0), func(): restore(geoms(visuals), "layers", held))
	var cls: Array = main.find_children("*", "CanvasLayer", true, false)
	cls = cls.filter(func(l): return l != sview.layer)
	await variant("cost_2d", func(): held = set_all(cls, "visible", false), func(): restore(cls, "visible", held))
	await variant("cost_3d", func(): sview.view.render_target_update_mode = SubViewport.UPDATE_DISABLED, func(): sview.view.render_target_update_mode = SubViewport.UPDATE_ALWAYS)
	# Each HUD widget, and the scripts' share of the frame.
	var busiest: Control = null
	for c in main.canvas.get_children():
		for cc in c.get_children():
			if cc is Control and cc.visible and (busiest == null or cc.get_child_count() > busiest.get_child_count()): busiest = cc
	if busiest:
		var plates: Array = []
		for c in busiest.get_children():
			if not (c is CanvasItem and c.visible): continue
			var script_name: String = c.get_script().resource_path.get_file() if c.get_script() else c.get_class()
			if script_name.begins_with("hud_plate") or script_name.begins_with("hud_wire_plate"):
				plates.append(c)
				continue
			await variant("cost_hud:" + script_name, func(): c.visible = false, func(): c.visible = true)
		await variant("cost_hud:all_plates(%d)" % plates.size(), func(): held = set_all(plates, "visible", false), func(): restore(plates, "visible", held))
		var kids: Array = busiest.get_children().filter(func(c): return c is CanvasItem and c.visible)
		await variant("cost_hud:all_children(%d)" % kids.size(), func(): held = set_all(kids, "visible", false), func(): restore(kids, "visible", held))
	await variant("cost_hud:main_canvas_layer", func(): main.canvas.visible = false, func(): main.canvas.visible = true)
	var others: Array = main.find_children("*", "CanvasLayer", true, false).filter(func(l): return l != sview.layer and l != main.canvas)
	await variant("cost_hud:other_layers(%d)" % others.size(), func(): held = set_all(others, "visible", false), func(): restore(others, "visible", held))
	await variant("cost_scripts_frozen", func():
		main.set_process(false); main.set_physics_process(false); arena.set_process(false), func():
		main.set_process(true); main.set_physics_process(true); arena.set_process(true))
	print("QC_DONE")
	quit()
