extends SceneTree
## Regression for menu/replay obstacle identity and idle damage-overlay costs.
var main: Node
func _initialize() -> void: call_deferred("run")
func run() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.test_mode = true
	main.sound_enabled = false
	# Whatever this machine's settings file says, this test is about Spin Cycle.
	main.preferred_game = "twisted"
	main.session.select_game("twisted")
	main._show_menu()
	main.arena.update_visuals(null, 0.0)
	assert(main.arena.rods[0].get_meta("kind") == "jump")
	main.session.solo("TEST")
	main.session.start_round()
	main.model.waves = [{"id":0,"at":1.0,"kind":"duck","done":false}]
	main.arena.update_visuals(main.model, 0.0)
	assert(main.arena.rods[0].get_meta("kind") == "duck", "Menu rod must not override the real first wave")
	# Same IDs, changed kind, also protect against replacement snapshots.
	main.model.waves[0].kind = "jump"
	main.arena.update_visuals(main.model, 0.0)
	assert(main.arena.rods[0].get_meta("kind") == "jump")
	main.session.start_round()
	main.model.waves = [{"id":0,"at":1.0,"kind":"duck","done":false}]
	main.arena.update_visuals(main.model, 0.0)
	assert(main.arena.rods[0].get_meta("kind") == "duck", "Replay must rebuild obstacle art")
	main.model.phase = "countdown"
	main.play.sync_duck(true)
	assert(not main.model.players[0].duck)
	main.model.phase = "running"
	main.model.countdown = 0.0
	main.play.sync_duck(true)
	assert(main.model.players[0].duck, "Held duck must apply at GO without another key press")
	main.play.sync_duck(false)
	assert(not main.model.players[0].duck)
	main.arena.client_motion = true
	main.model.players[0].jump = -1.0
	main.arena.predict_action("jump", true)
	main.arena.update_visuals(main.model, 0.03, 0)
	assert(main.arena.runners[0].body.position.y > 0.0, "Client visual must react before a snapshot")
	assert(main.arena.runners[0].visual.clip == "jump", "A predicted jump must show the jump pose")
	assert(main.model.players[0].jump == -1.0, "Visual prediction must not mutate the server model")
	main.arena.client_motion = false
	assert(main.arena.track.get_child_count() == 1, "Track should use one combined mesh")
	assert(not main.damage_shade.visible, "Idle fullscreen damage shader must be hidden")
	# Balanced stays cheap: no shadow maps, no silhouette shadow pass, no MSAA,
	# no extra atmosphere. High adds them and switches back cleanly.
	main.arena.set_detail(false)
	assert(not main.arena.key_light.shadow_enabled, "Balanced mode should avoid realtime shadow cost")
	assert(root.msaa_3d == Viewport.MSAA_DISABLED, "Balanced mode should not multisample")
	assert(not main.arena.high_fx.visible, "Balanced mode should skip the High-only atmosphere")
	for r in main.arena.runners:
		assert(r.visual.planar == null or not r.visual.planar.visible, "Balanced mode should use blob shadows only")
		assert(r.visual.shadow.visible, "Every runner needs a contact shadow")
		assert(r.visual.lite.visible and not r.visual.mesh.visible, "Balanced mode should skin the light mesh")
	main.arena.set_detail(true)
	assert(root.msaa_3d == Viewport.MSAA_4X and main.arena.high_fx.visible)
	for r in main.arena.runners:
		assert(r.visual.planar != null and r.visual.planar.visible, "High mode draws silhouette shadows")
		assert(r.visual.mesh.visible and not r.visual.lite.visible, "High mode shows the full mesh")
	assert(not main.arena.key_light.shadow_enabled, "Shadow maps over-brighten the Compatibility renderer; High must not use them")
	main.arena.set_detail(false)
	for r in main.arena.runners:
		assert(not r.visual.planar.visible)
	assert(main.arena.level == "balanced" and is_equal_approx(root.scaling_3d_scale, 1.0), "set_detail(false) is Balanced, at full 3D resolution")
	# Low: lower 3D resolution, plainer scenery, two lights fewer, no fog, the
	# lightest robot mesh; still blob shadows and no MSAA. Back to Balanced cleanly.
	var balanced_tris: int = main.arena.runners[0].visual.lite.mesh.surface_get_array_index_len(0) / 3
	main.arena.set_level("low")
	assert(root.scaling_3d_scale < 1.0 and root.msaa_3d == Viewport.MSAA_DISABLED, "Low renders 3D below full resolution, without MSAA")
	assert(not main.arena.environment.fog_enabled and not main.arena.high_fx.visible, "Low has no fog or High atmosphere")
	for light in main.arena.fill_lights: assert(not light.visible, "Low keeps only the key light")
	for node in main.arena.backdrop + main.arena.structure: assert(not node.visible, "Low hides the full scenery")
	for node in main.arena.backdrop_lite + main.arena.structure_lite: assert(node.visible, "Low shows the sparse scenery")
	for r in main.arena.runners:
		assert(r.visual.lite.visible and not r.visual.mesh.visible and r.visual.shadow.visible, "Low skins the light mesh over a blob shadow")
		assert(r.visual.lite.mesh.surface_get_array_index_len(0) / 3 < balanced_tris, "Low's robot mesh is lighter than Balanced's")
	main.arena.set_level("balanced")
	assert(is_equal_approx(root.scaling_3d_scale, 1.0) and main.arena.environment.fog_enabled, "Balanced restores full resolution and fog")
	for node in main.arena.backdrop + main.arena.structure: assert(node.visible)
	for node in main.arena.backdrop_lite + main.arena.structure_lite: assert(not node.visible)
	for r in main.arena.runners:
		assert(r.visual.lite.mesh.surface_get_array_index_len(0) / 3 == balanced_tris, "Balanced gets its own mesh back")
	# Settings: the three levels, the pre-Low boolean, and the first-run default.
	var Main = main.get_script()
	var cfg := ConfigFile.new()
	assert(Main.stored_graphics(cfg, "low") == "low", "No setting keeps the default")
	cfg.set_value("graphics", "detailed", true)
	assert(Main.stored_graphics(cfg, "low") == "high", "An older settings file's detailed=true is High")
	cfg.set_value("graphics", "detailed", false)
	assert(Main.stored_graphics(cfg, "low") == "balanced", "An older settings file's detailed=false is Balanced")
	cfg.set_value("graphics", "level", "low")
	assert(Main.stored_graphics(cfg, "high") == "low", "The level key wins over the old boolean")
	assert(Main.default_graphics("llvmpipe (LLVM 20.1.2, 256 bits)") == "low" and Main.default_graphics("SwiftShader Device") == "low", "Software renderers start on Low")
	assert(Main.default_graphics("NVIDIA GeForce RTX 3060") == "high" and Main.default_graphics("") == "balanced")
	assert(Main.default_graphics("V3D 4.2.14.0") == "low" and Main.default_graphics("V3D 7.1.10.2") == "low" and Main.default_graphics("VC4 V3D 2.1") == "low", "Raspberry Pi GPUs start on Low")
	assert(Main.default_graphics("AMD Radeon Graphics (radeonsi, renoir, LLVM 20.1.2)") == "high", "Only a leading V3D/VC4 name means a Raspberry Pi")
	# The scale rule: legible at 1024x576, not ballooning at 2560x1440.
	assert(is_equal_approx(Main.ui_scale_for(Vector2(1024, 576)), Main.UI_SCALE_MIN) and is_equal_approx(Main.ui_scale_for(Vector2(1440, 900)), 1.0))
	assert(is_equal_approx(Main.ui_scale_for(Vector2(2560, 1440)), Main.UI_SCALE_MAX))
	for asset_name in ["runner"]:
		var art: Node3D = load("res://assets/meshy/" + asset_name + ".glb").instantiate()
		for mesh in art.find_children("*", "MeshInstance3D", true, false):
			assert(mesh.mesh.surface_get_material(0).albedo_texture != null, "Meshy base texture must import successfully")
		art.free()
	# The robot is one skinned mesh tinted per seat; every gameplay pose needs its clip.
	var robot: Node3D = main.arena.runners[0].visual
	assert(robot.skeleton != null and robot.skeleton.get_bone_count() >= 20, "Runner must be a rigged character")
	for clip_name in ["idle", "jog", "run", "jump", "duck", "hit", "hit_low", "victory", "knockdown"]:
		assert(robot.anim.has_animation(clip_name), "Runner is missing the %s clip" % clip_name)
	var tints := {}
	for r in main.arena.runners: tints[r.visual.material.get_shader_parameter("team")] = true
	assert(tints.size() == 6, "Six runners need six distinct team colours")
	assert(robot.material.get_shader_parameter("team").is_equal_approx(main.Kit.colors[0]), "Runner tint must match its HUD plate")
	for p in main.model.players:
		p.hp = 0
		p.out_at = 1.0
	main.model.players[0].hp = 7
	main.model.players[0].out_at = -1.0
	main.model.phase = "finished"
	main._show_results()
	assert(is_instance_valid(main.arena.victory), "Solo winner should have a celebration")
	var hero: Node3D = main.arena.victory.get_child(0)
	assert(hero.has_node("Body") and hero.skeleton != null, "The podium shows the winning robot")
	assert(hero.clip == "victory", "The winner must strike the victory pose")
	main.session.start_round()
	assert(main.arena.victory == null, "Replay must clear the winner presentation")
	print("PRESENTATION_PASS menu-round-kind-change-replay-batching-idle-overlay")
	quit()
