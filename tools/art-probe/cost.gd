extends SceneTree
## Throwaway: which part of the scene costs frame time on this renderer?
var main: Node
func _initialize() -> void: call_deferred("run")
func measure(label: String) -> void:
	for i in 4: await process_frame
	var start := Time.get_ticks_usec()
	var frames := 24
	for i in frames: await process_frame
	var ms := (Time.get_ticks_usec() - start) / 1000.0 / frames
	print("COST %-28s %6.1f ms  draws=%d prims=%d" % [label, ms, Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)])
func run() -> void:
	root.size = Vector2i(1440, 900)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.test_mode = true
	main.sound_enabled = false
	var high := "--high" in OS.get_cmdline_user_args()
	main.graphics_level = "high" if high else "balanced"
	main.arena.set_detail(high)
	main.session.solo("PLAYER ONE")
	main.session.start_round()
	main.model.countdown = 0.0
	main.model.phase = "running"
	for p in main.model.players: p.bot = true
	await create_timer(1.0).timeout
	var a: Node3D = main.arena
	await measure("all")
	main.canvas.visible = false
	await measure("no HUD")
	a.hud_shade.visible = false
	await measure("+ no hud shade")
	for r in a.runners: r.visual.body.visible = false
	await measure("+ no robots")
	for r in a.runners: r.visual.body.visible = true
	a.track.visible = false
	await measure("no deck (robots back)")
	a.track.visible = true
	var batches: Array = []
	for c in a.get_children():
		if c is MeshInstance3D and str(c.name).begins_with("Batch_"): batches.append(c)
	for b in batches: b.visible = false
	await measure("no static batches")
	for b in batches: b.visible = true
	a.environment.fog_enabled = false
	await measure("no fog")
	a.environment.fog_enabled = true
	var lights: Array = []
	for c in a.get_children():
		if c is DirectionalLight3D and c != a.key_light: lights.append(c)
	for l in lights: l.visible = false
	await measure("one light")
	for l in lights: l.visible = true
	a.rod_root.visible = false
	await measure("no rods")
	a.rod_root.visible = true
	root.size = Vector2i(720, 450)
	await measure("quarter resolution")
	quit()
