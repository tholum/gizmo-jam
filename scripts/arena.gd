extends Node3D
## The reactor arena: a bright teal industrial shaft, the spiral conveyor ramp,
## the sweeping rollers and six toy-robot runners. Everything is built in code
## from chunky flat-shaded pieces (arena_kit.gd); the robots are a rigged Meshy
## model (runner_visual.gd). Visuals follow the simulation, never the reverse.

const Model = preload("res://scripts/round_model.gd")
const Kit = preload("res://scripts/arena_kit.gd")
const RunnerVisual = preload("res://scripts/runner_visual.gd")
## Seat colours. The HUD and the robots both use `team_color()`, the vivid version.
const Palette = preload("res://scripts/palette.gd")
const COLORS := Palette.COLORS
const PITCH := 4.8
const INNER_RADIUS := 3.0
const RUNNER_SPACING := 0.87
const TRACK_INNER := 2.5
const TRACK_OUTER := 8.1
## Draw order of the big static meshes. The renderer sorts opaque meshes by
## distance in bands of camera.far / 16 (here ~19 units, so the whole arena
## shares one band) and then by shader, which can shade the structure under the
## deck, or the sky behind everything, before what covers them. Pushing them
## into later bands draws the deck, runners and rods first and lets the depth
## test skip what they hide. Opaque, so the picture is the same; on a GPU that
## is short of pixel throughput (a Raspberry Pi) it is less work.
const SORT_OFFSETS := {"Structure": -20.0, "Backdrop": -40.0}

## Deck tessellation: steps per turn and rings across (see _build_track()).
const DECK_STEPS := 128.0
const DECK_RINGS := 6
## Low's deck pattern texture: one turn across, the deck's width down.
const DECK_PATTERN_SIZE := Vector2i(4096, 512)
## Rod centre heights above the deck and roller radius. These mirror what the
## simulation treats as a hit: a jump clears the low roller once the runner is
## 0.36 up, and only a ducking runner fits under the high one.
const ROD_LOW := 0.29
const ROD_HIGH := 0.93
const ROD_RADIUS := 0.115
const JUMP_COLOR := Color("ff8a1c")
const DUCK_COLOR := Color("9b6dff")
# Scenery palette: mid greys, teal light and safety yellow. Orange and violet
# are reserved for the two rods.
const STEEL := Color("7d8794")
const STEEL_DARK := Color("4b5462")
const STEEL_DEEP := Color("3b4452")
const STEEL_LIGHT := Color("a9b3bf")
const SAFETY := Color("ffd23c")
const TEAL_LIGHT := Color("4ff3ea")
const LIME := Color("b8ff4f")
const HAZE := Color("56d6d0")
## Graphics levels, cheapest first. Same gameplay and collision on all three.
const LEVELS := ["low", "balanced", "high"]
## Low draws the 3D scene at this fraction of the window and stretches it up;
## the HUD is drawn afterwards at full resolution.
const LOW_RENDER_SCALE := 0.67
## Camera set-ups: orbit angle round the tower, distance and height, look-at
## target, and the vertical field of view on a 16:10 screen. `framed` views
## sit beside the menu column, which covers the left of the screen: they slide
## the picture so the target is centred in the space right of the column.
const KEY_ENERGY := 1.05
## Ambient light energy with all three lights, and on Low on a software
## rasteriser, which drops the two fill lights.
const AMBIENT := 0.78
const SOFTWARE_LOW_AMBIENT := 1.05
const GAME_VIEW := {"az": 0.88, "radius": 10.6, "height": 4.9, "target": Vector3(0.5, 0.35, 5.45), "fov": 34.0, "framed": false}
const MENU_VIEW := {"az": 0.9, "radius": 14.5, "height": 6.6, "target": Vector3(0.3, 0.9, 4.6), "fov": 36.0, "framed": true}
const PODIUM_VIEW := {"az": 0.95, "radius": 12.0, "height": 3.6, "target": Vector3(0.0, 1.9, 5.2), "fov": 34.0, "framed": true}
## Screen shape the views were composed for (1440x900). Narrower screens keep
## its horizontal field of view, so the line of runners never loses its ends.
const REFERENCE_ASPECT := 1.6
## Fraction of the screen width the menu column covers on the 1440x900 design
## (its slanted edge, averaged over the height), and how far past the middle
## of the free space the design pushes the target: 1.104 reproduces it.
const REFERENCE_INSET := 0.476
const MENU_LEAD := 1.104

var camera: Camera3D
var track: Node3D
var runners: Array = []
var rods: Dictionary = {}
var rod_root: Node3D
var decor_time := 0.0
var menu_mode := true
var display_progress := 0.0
var last_progress := -1.0
var impact_line: Node3D
var local_slot := 0
## Several players on this screen (one bit per slot), set by main.gd; 0 when
## there is only own_slot. Every one of them gets the ring and a name tag, and
## the single YOU marker stays hidden.
var local_mask := 0
var key_light: DirectionalLight3D
var environment: Environment
## "low", "balanced" or "high". `detailed` is true only on High.
var level := "balanced"
var detailed := false
var backdrop: Array = []
var structure: Array = []
var structure_lite: Array = []
var backdrop_lite: Array = []
var fill_lights: Array = []
var visual_round := -1
var victory: Node3D
var belt_material: ShaderMaterial
var glass_material: ShaderMaterial
var glow_material: ShaderMaterial
var solid_material: ShaderMaterial
var rod_templates: Dictionary = {}
## Rendering on a software rasteriser: Low keeps its lighter scene there.
var software := false
## Low's deck pattern texture (Kit.DECK_PATTERN_SHADER), and its renderer while
## it is being made.
var _deck_pattern: ImageTexture
var _deck_painter: SubViewport
## Round-start warm-up (see _warm_up()).
var _warm: Node3D
var _warm_frames := 0
var rod_materials: Dictionary = {}
var client_motion := false
var show_identities := false
var predicted_jump := -1.0
var predicted_jump_active := false
var predicted_jump_queued := false
var predicted_duck := false
var predicted_duck_active := false
var display_font: Font
var view: Dictionary = MENU_VIEW
var shake := 0.0
var boost := 0.0
var last_stage := 0
var hud_shade: CanvasLayer
var dust_pool: Array = []
var spark_pool: Array = []
var pool_cursor := {"dust": 0, "spark": 0}
var you_marker: Node3D
var high_fx: Node3D
## Fraction of the screen width covered by the menu column; see set_inset().
var inset := REFERENCE_INSET

## Saturated seat colour, identical to the HUD's `ui_kit.vivid()` of COLORS.
static func team_color(index: int) -> Color:
	return Palette.vivid(Palette.for_seat(index))

func update_player_colors() -> void:
	for i in runners.size():
		var tint := team_color(i)
		runners[i].visual.set_team_color(tint)
		runners[i].tag.modulate = tint

func _ready() -> void:
	software = software_renderer(RenderingServer.get_video_adapter_name())
	display_font = load("res://assets/fonts/Kanit-BlackItalic.ttf") if ResourceLoader.exists("res://assets/fonts/Kanit-BlackItalic.ttf") else load("res://assets/fonts/Display.ttf")
	_build_environment()
	solid_material = Kit.shader_material(Kit.SOLID_SHADER, {"bounce": Color("6fe6de"), "bounce_power": 1.5})
	glow_material = Kit.shader_material(Kit.GLOW_SHADER, {"energy": 1.7})
	var batch := Kit.Batch.new()
	_build_column()
	_build_reactor(batch)
	_build_ramp_structure(batch)
	structure = _commit_static(batch, "Structure")
	# Low's lighter cut of the same frame: about half the triangles.
	var light := Kit.Batch.new()
	_build_reactor(light, true)
	_build_ramp_structure(light, true)
	structure_lite = _commit_static(light, "StructureLite")
	for node in structure_lite: node.visible = false
	# The far gantries are their own meshes so Low can swap in a sparse set.
	var far := Kit.Batch.new()
	_build_backdrop(far)
	backdrop = _commit_static(far, "Backdrop")
	var sparse := Kit.Batch.new()
	_build_backdrop(sparse, true)
	backdrop_lite = _commit_static(sparse, "BackdropLite")
	for node in backdrop_lite: node.visible = false
	_build_track()
	_build_impact_line()
	rod_root = Node3D.new()
	add_child(rod_root)
	# Built now, not when the first rod spawns: building one is a few ms of
	# GDScript geometry, far more on a Raspberry Pi.
	_rod_template("jump")
	_rod_template("duck")
	for i in 6:
		_build_runner(i)
	_build_effects()
	set_menu(true)

func _build_environment() -> void:
	var env := WorldEnvironment.new()
	environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = HAZE
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("c9f4f0")
	environment.ambient_light_energy = AMBIENT
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_white = 1.6
	environment.fog_enabled = true
	environment.fog_light_color = HAZE
	environment.fog_light_energy = 1.0
	environment.fog_mode = Environment.FOG_MODE_DEPTH
	environment.fog_depth_begin = 17.0
	environment.fog_depth_end = 70.0
	environment.fog_depth_curve = 0.8
	environment.fog_density = 0.9
	environment.fog_sky_affect = 0.0
	# Environment glow is left off: in the Compatibility renderer it re-grades
	# the whole frame and washes out the team colours. Lamps are bright unshaded
	# meshes with their own halos instead, which also works on Balanced.
	env.environment = environment
	add_child(env)
	# Soft, warm key from above and to the camera's left. It never casts
	# shadow maps: in the Compatibility renderer a shadowed directional light is
	# added in a second pass that over-brightens and tints the whole scene.
	# Runner shadows are drawn by the runners themselves (see runner_visual.gd).
	var sun := DirectionalLight3D.new()
	sun.basis = Basis.looking_at(Vector3(-0.28, -0.9, -0.36).normalized(), Vector3.UP)
	sun.light_color = Color("fff3dc")
	sun.light_energy = KEY_ENERGY
	sun.directional_shadow_max_distance = 40.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.shadow_enabled = false
	key_light = sun
	add_child(sun)
	# The glowing core is the big teal fill and rim source.
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-8, -118, 0)
	fill.light_color = Color("6ff5e8")
	fill.light_energy = 0.55
	add_child(fill)
	fill_lights.append(fill)
	# Glow rising from the coolant far below keeps the undersides out of black.
	var up := DirectionalLight3D.new()
	up.rotation_degrees = Vector3(78, 20, 0)
	up.light_color = Color("58f0e4")
	up.light_energy = 0.4
	up.light_specular = 0.0
	add_child(up)
	fill_lights.append(up)
	var dome := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 140.0
	sphere.height = 280.0
	sphere.radial_segments = 24
	sphere.rings = 12
	dome.mesh = sphere
	dome.material_override = Kit.shader_material(Kit.SKY_SHADER)
	dome.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Drawn after everything else, so the depth test skips it wherever
	# something covers it (see SORT_OFFSETS).
	dome.sorting_offset = -1000.0
	add_child(dome)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.near = 0.3
	camera.far = 300.0
	add_child(camera)
	camera.current = true
	# Darkens the scene a touch behind the bottom HUD plates during a round.
	hud_shade = CanvasLayer.new()
	hud_shade.layer = 0
	add_child(hud_shade)
	# Two strips, not one full-screen quad: blending nothing over the middle
	# of the picture is wasted fill on software renderers.
	for strip in [[0.0, 0.2, "1.0-UV.y", 0.2], [0.7, 1.0, "UV.y", 0.5]]:
		var shade := ColorRect.new()
		shade.anchor_left = 0.0
		shade.anchor_right = 1.0
		shade.anchor_top = strip[0]
		shade.anchor_bottom = strip[1]
		shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var shade_shader := Shader.new()
		shade_shader.code = "shader_type canvas_item; void fragment(){ COLOR=vec4(0.02,0.07,0.13,smoothstep(0.0,1.0,%s)*%s); }" % [strip[2], str(strip[3])]
		var shade_material := ShaderMaterial.new()
		shade_material.shader = shade_shader
		shade.material = shade_material
		hud_shade.add_child(shade)

func _exit_tree() -> void:
	# Templates are never in the tree, and the shared caches outlive the scene.
	for kind in rod_templates: rod_templates[kind].free()
	rod_templates.clear()
	Kit._shaders.clear()
	RunnerVisual._scene = null
	RunnerVisual._quad = null
	RunnerVisual._lite_mesh = null
	RunnerVisual._low_mesh = null
	RunnerVisual._shadow_mesh = null

## Commits static scenery: one mesh per material, named `<prefix>_<material>`.
func _commit_static(batch: Kit.Batch, prefix: String) -> Array:
	var made: Array = batch.commit(self, {Kit.SOLID: solid_material, Kit.GLOW: glow_material})
	for node in made:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.name = prefix + "_" + str(node.name).trim_prefix("Batch_")
		node.sorting_offset = SORT_OFFSETS.get(prefix.trim_suffix("Lite"), 0.0)
	return made

## Position on the spiral: `y` is height above the deck at that angle.
func _point(radius: float, angle: float, y: float) -> Vector3:
	return Vector3(sin(angle) * radius, angle / TAU * PITCH + y, cos(angle) * radius)

func _build_column() -> void:
	# Glowing coolant column behind faceted glass.
	var core := MeshInstance3D.new()
	var column := CylinderMesh.new()
	column.top_radius = 1.72
	column.bottom_radius = 1.72
	column.height = 40.0
	column.radial_segments = 12
	column.rings = 1
	core.mesh = column
	core.position.y = -1.0
	glass_material = Kit.shader_material(Kit.GLASS_SHADER)
	core.material_override = glass_material
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(core)

## `sparse` is Low's cut: coarser rails and lamps on every other collar.
func _build_reactor(batch: Kit.Batch, sparse: bool = false) -> void:
	# Chunky structural frame: uprights, collars and the helical rails the
	# roller carriages ride on.
	for i in 6:
		var a := TAU * i / 6.0 + TAU / 12.0
		var upright := Transform3D(Basis(Vector3.UP, a), Vector3(sin(a) * 1.95, -1.0, cos(a) * 1.95))
		batch.box(Kit.SOLID, upright, Vector3(0.62, 40.0, 0.42), 0.08, STEEL_LIGHT)
	var level := -16.75
	while level < 19.0:
		batch.prism(Kit.SOLID, Transform3D(Basis.IDENTITY, Vector3(0, level, 0)), 2.26, 2.26, 0.36, 12, STEEL, TAU / 24.0)
		batch.prism(Kit.SOLID, Transform3D(Basis.IDENTITY, Vector3(0, level + 0.36, 0)), 2.26, 1.9, 0.2, 12, STEEL, TAU / 24.0)
		batch.prism(Kit.SOLID, Transform3D(Basis.IDENTITY, Vector3(0, level - 0.2, 0)), 1.9, 2.26, 0.2, 12, STEEL, TAU / 24.0)
		for i in 6:
			if sparse and i % 2 == 1: continue
			var a := TAU * i / 6.0
			var lamp := Transform3D(Basis(Vector3.UP, a), Vector3(sin(a) * 2.27, level + 0.18, cos(a) * 2.27))
			batch.box(Kit.GLOW, lamp, Vector3(0.62, 0.14, 0.06), 0.0, TEAL_LIGHT)
		level += PITCH
	var from := -2.75 * TAU
	var to := 2.1 * TAU
	var steps := int((to - from) / (TAU / (24.0 if sparse else 48.0)))
	for height in [ROD_LOW, ROD_HIGH]:
		batch.arc(Kit.SOLID, 1.84, 2.24, height - 0.12, height + 0.12, from, to, steps, STEEL, PITCH, "to")
		batch.arc(Kit.GLOW, 2.24, 2.25, height - 0.035, height + 0.035, from, to, steps, TEAL_LIGHT, PITCH, "o")

## `sparse` is Low's cut: coarser kerbs, no brackets under the deck, and
## lighter railings.
func _build_ramp_structure(batch: Kit.Batch, sparse: bool = false) -> void:
	var from := -2.75 * TAU
	var to := 2.1 * TAU
	var steps := int((to - from) / (TAU / (32.0 if sparse else 48.0)))
	# Slab under the deck, dark kerbs on both edges.
	batch.arc(Kit.SOLID, TRACK_INNER, TRACK_OUTER, -0.34, -0.03, from, to, steps, STEEL, PITCH, "be")
	batch.arc(Kit.SOLID, TRACK_OUTER, TRACK_OUTER + 0.22, -0.52, 0.1, from, to, steps, STEEL_DEEP, PITCH, "tboie")
	batch.arc(Kit.SOLID, TRACK_INNER - 0.14, TRACK_INNER, -0.52, 0.07, from, to, steps, STEEL_DEEP, PITCH, "tbi")
	# Light strips set into the outer face, and ribs and brackets underneath.
	var segments := int((to - from) / (TAU / 24.0))
	for i in segments:
		var a := from + (i + 0.18) * TAU / 24.0
		batch.arc(Kit.GLOW, TRACK_OUTER + 0.22, TRACK_OUTER + 0.235, -0.3, -0.12, a, a + TAU / 24.0 * 0.64, 3, TEAL_LIGHT, PITCH, "o")
	var brackets := 0 if sparse else int((to - from) / (TAU / 12.0))
	for i in brackets:
		var a := from + (i + 0.5) * TAU / 12.0
		var centre := _point(5.15, a, -0.56)
		var xf := Transform3D(Basis(Vector3.UP, a), centre)
		batch.box(Kit.SOLID, xf, Vector3(0.36, 0.44, 6.1), 0.0, STEEL_DARK)
		batch.box(Kit.GLOW, Transform3D(Basis(Vector3.UP, a), _point(5.6, a, -0.8)), Vector3(0.14, 0.05, 2.6), 0.0, TEAL_LIGHT)
	# Safety railings on the stretches the camera does not look across.
	var turn := -3
	while turn < 3:
		for stretch in [[2.55, 5.25], [-2.5, -0.95]]:
			var a0: float = turn * TAU + stretch[0]
			var a1: float = turn * TAU + stretch[1]
			if a0 < from or a1 > to: continue
			_railing(batch, a0, a1, sparse)
		turn += 1

## Low's railings have half the posts and only the top bar.
func _railing(batch: Kit.Batch, a0: float, a1: float, sparse: bool = false) -> void:
	var radius := TRACK_OUTER + 0.11
	var posts := int(ceil((a1 - a0) / (0.42 if sparse else 0.21)))
	for i in posts + 1:
		var a := lerpf(a0, a1, float(i) / posts)
		batch.box(Kit.SOLID, Transform3D(Basis(Vector3.UP, a), _point(radius, a, 0.5)), Vector3(0.11, 0.82, 0.11), 0.0, SAFETY)
	for height in ([0.9] if sparse else [0.52, 0.9]):
		batch.arc(Kit.SOLID, radius - 0.05, radius + 0.05, height - 0.05, height + 0.05, a0, a1, posts * 2, SAFETY, PITCH, "toi")

## `sparse` is the Low set: the same pillars in the same places, without the
## far ring, the chamfers, the platforms or most of the light slots.
func _build_backdrop(batch: Kit.Batch, sparse: bool = false) -> void:
	# Layered gantries, pillars and platforms that fade into the haze.
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	for layer in [[20.0, 9, 2.0, STEEL], [31.0, 12, 3.0, STEEL_DARK], [46.0, 14, 4.6, STEEL_DARK]]:
		var radius: float = layer[0]
		var count: int = layer[1]
		var width: float = layer[2]
		var tint: Color = layer[3]
		if sparse and radius > 40.0: continue
		for i in count:
			var a := TAU * (i + rng.randf_range(-0.18, 0.18)) / count
			var top := rng.randf_range(4.0, 16.0)
			var pos := Vector3(sin(a) * radius, top - 30.0, cos(a) * radius)
			var facing := Basis(Vector3.UP, a)
			# Only the nearest ring is close enough for its chamfers to show.
			var chamfer := width * 0.08 if radius < 25.0 and not sparse else 0.0
			batch.box(Kit.SOLID, Transform3D(facing, pos), Vector3(width, 60.0, width), chamfer, tint)
			batch.box(Kit.SOLID, Transform3D(facing, Vector3(pos.x, top + 0.4, pos.z)), Vector3(width * 1.4, 0.8, width * 1.4), chamfer * 0.6, tint.lightened(0.08))
			# Light slots facing the shaft.
			var inward := Vector3(sin(a), 0, cos(a)) * (radius - width * 0.51)
			for k in 3:
				var y := top - 3.0 - k * rng.randf_range(4.0, 6.5)
				if sparse and k > 0: continue
				batch.box(Kit.GLOW, Transform3D(facing, Vector3(inward.x, y, inward.z)), Vector3(width * 0.55, 0.32, 0.06), 0.0, TEAL_LIGHT)
			# Gantry beam to the next pillar, and sometimes a railed platform.
			var b := TAU * (i + 1) / count
			var beam_y := top - rng.randf_range(2.0, 9.0)
			# Drawn even when unused, so both sets place every pillar alike.
			var deck_drop := rng.randf_range(3.0, 7.0) if i % 3 == 0 else 0.0
			if sparse: continue
			var p0 := Vector3(sin(a) * radius, beam_y, cos(a) * radius)
			var p1 := Vector3(sin(b) * radius, beam_y, cos(b) * radius)
			var along := (p1 - p0)
			var beam_basis := Basis.looking_at(along.normalized(), Vector3.UP)
			batch.box(Kit.SOLID, Transform3D(beam_basis, (p0 + p1) * 0.5), Vector3(width * 0.5, width * 0.45, along.length()), chamfer, tint.darkened(0.1))
			batch.box(Kit.GLOW, Transform3D(beam_basis, (p0 + p1) * 0.5 + Vector3(0, -width * 0.24, 0)), Vector3(width * 0.2, 0.05, along.length() * 0.5), 0.0, TEAL_LIGHT)
			if i % 3 == 0:
				var reach := radius - width * 0.5 - 1.6
				var deck_y := beam_y - deck_drop
				var deck := Transform3D(facing, Vector3(sin(a) * reach, deck_y, cos(a) * reach))
				batch.box(Kit.SOLID, deck, Vector3(width * 2.2, 0.35, 3.2), chamfer * 0.5, tint.lightened(0.05))
				batch.box(Kit.SOLID, deck.translated_local(Vector3(0, 0.75, -1.5)), Vector3(width * 2.2, 0.12, 0.12), 0.0, SAFETY)
				for side in [-1.0, 1.0]:
					batch.box(Kit.SOLID, deck.translated_local(Vector3(side * width * 1.05, 0.45, -1.5)), Vector3(0.12, 0.7, 0.12), 0.0, SAFETY)
					batch.box(Kit.SOLID, deck.translated_local(Vector3(side * width * 1.05, 0.75, 0)), Vector3(0.12, 0.12, 3.1), 0.0, SAFETY)
				batch.box(Kit.GLOW, deck.translated_local(Vector3(0, -0.1, -1.62)), Vector3(width * 1.6, 0.12, 0.05), 0.0, TEAL_LIGHT)

func _build_track() -> void:
	track = Node3D.new()
	add_child(track)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var from := -2.75 * TAU
	var to := 2.1 * TAU
	# Fine enough that the interpolated UV (angle / TAU, radius) stays within a
	# fraction of a seam's width of the true polar position, so Low's deck
	# shader can read it instead of an atan() and a length() per pixel.
	var steps := int((to - from) / (TAU / DECK_STEPS))
	for i in steps:
		var a := lerpf(from, to, float(i) / steps)
		var b := lerpf(from, to, float(i + 1) / steps)
		for ring in DECK_RINGS:
			var r0 := lerpf(TRACK_INNER, TRACK_OUTER, float(ring) / DECK_RINGS)
			var r1 := lerpf(TRACK_INNER, TRACK_OUTER, float(ring + 1) / DECK_RINGS)
			var corners := [[r0, a], [r1, a], [r1, b], [r0, b]]
			for index in [0, 2, 1, 0, 3, 2]:
				var corner: Array = corners[index]
				surface.set_uv(Vector2(corner[1] / TAU, corner[0]))
				surface.set_normal(Vector3.UP)
				surface.add_vertex(_point(corner[0], corner[1], 0.0))
	belt_material = Kit.shader_material(Kit.DECK_SHADER, {"bounce": Color("38e0d8")})
	var deck := MeshInstance3D.new()
	deck.name = "Deck"
	deck.mesh = surface.commit()
	deck.material_override = belt_material
	deck.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	track.add_child(deck)

func _build_impact_line() -> void:
	impact_line = Node3D.new()
	add_child(impact_line)
	var batch := Kit.Batch.new()
	# A bright bar across all six lanes, where the rollers meet the runners.
	var radii := [2.74, 3.6, 4.5, 5.4, 6.3, 7.1, 7.86]
	for i in radii.size() - 1:
		var r0: float = radii[i]
		var r1: float = radii[i + 1]
		for band in [[0.2, 0.008, Color(0.05, 0.07, 0.11)], [0.11, 0.012, LIME]]:
			var half: float = band[0] * 0.5
			batch.quad(Kit.GLOW, _point(r0, -half / r0, band[1]), _point(r1, -half / r1, band[1]), _point(r1, half / r1, band[1]), _point(r0, half / r0, band[1]), Vector3.UP, band[2])
	# Gate posts on the kerbs at both ends.
	for radius in [TRACK_OUTER + 0.11, TRACK_INNER - 0.04]:
		for side in [-1.0, 1.0]:
			var a: float = side * 0.34 / radius
			var foot := _point(radius, a, 0.1)
			batch.prism(Kit.SOLID, Transform3D(Basis(Vector3.UP, a), foot), 0.13, 0.11, 0.42, 6, STEEL_LIGHT)
			batch.prism(Kit.GLOW, Transform3D(Basis(Vector3.UP, a), foot + Vector3(0, 0.42, 0)), 0.11, 0.07, 0.12, 6, LIME)
	var line_glow := Kit.shader_material(Kit.GLOW_SHADER, {"energy": 1.35})
	for node in batch.commit(impact_line, {Kit.SOLID: solid_material, Kit.GLOW: line_glow}):
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _label(text: String, size: int, tint: Color) -> Label3D:
	var tag := Label3D.new()
	tag.text = text
	tag.font = display_font
	tag.font_size = size
	tag.pixel_size = 0.0052
	tag.outline_size = int(size * 0.34)
	tag.outline_modulate = Color("070b16")
	tag.modulate = tint
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return tag

func _icon(shape: int, tint: Color, size: float) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var node := MeshInstance3D.new()
	node.mesh = quad
	node.material_override = Kit.shader_material(Kit.ICON_SHADER, {"fill": tint, "shape": shape, "size": size})
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.extra_cull_margin = 2.0
	return node

func _lane_radius(index: int) -> float:
	return INNER_RADIUS + index * RUNNER_SPACING

func _build_runner(index: int) -> void:
	var radius := _lane_radius(index)
	var visual: Node3D = RunnerVisual.new()
	# All six share one cross-section of the ramp, side by side from the
	# reactor to the outside rail. They never occupy different spiral turns.
	visual.position = Vector3(0, 0, radius)
	add_child(visual)
	visual.setup(team_color(index), atan(PITCH / (TAU * radius)))
	var tag := _label("%02d" % (index + 1), 44, team_color(index))
	tag.name = "Identity"
	tag.no_depth_test = true
	tag.position = Vector3(0, 1.75, 0)
	visual.add_child(tag)
	runners.append({"root": visual, "body": visual.body, "visual": visual, "tag": tag, "hp": 7, "score": 0,
		"visual_jump": -1.0, "airborne": false, "out": -1.0, "radius": radius})

func _build_effects() -> void:
	you_marker = Node3D.new()
	add_child(you_marker)
	var pointer := _icon(2, Color.WHITE, 0.46)
	pointer.name = "Pointer"
	you_marker.add_child(pointer)
	var you := _label("YOU", 40, Color.WHITE)
	you.name = "Text"
	you.position.y = 0.3
	you.no_depth_test = true
	you_marker.add_child(you)
	var soft := GradientTexture2D.new()
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 1))
	ramp.set_color(1, Color(1, 1, 1, 0))
	soft.gradient = ramp
	soft.fill = GradientTexture2D.FILL_RADIAL
	soft.fill_from = Vector2(0.5, 0.5)
	soft.fill_to = Vector2(0.5, 0.0)
	soft.width = 64
	soft.height = 64
	_build_high_fx(soft)
	for kind in ["dust", "spark"]:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.vertex_color_use_as_albedo = true
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		mat.billboard_keep_scale = true
		mat.albedo_texture = soft
		if kind == "spark": mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE * (0.34 if kind == "dust" else 0.16)
		quad.material = mat
		var fade := Gradient.new()
		fade.set_color(0, Color(1, 1, 1, 0.85))
		fade.set_color(1, Color(1, 1, 1, 0.0))
		var grow := Curve.new()
		grow.add_point(Vector2(0.0, 0.45 if kind == "dust" else 1.0))
		grow.add_point(Vector2(1.0, 1.25 if kind == "dust" else 0.2))
		for i in (8 if kind == "dust" else 6):
			var burst := CPUParticles3D.new()
			burst.mesh = quad
			burst.emitting = false
			burst.one_shot = true
			burst.explosiveness = 0.92
			burst.amount = 9 if kind == "dust" else 18
			burst.lifetime = 0.5 if kind == "dust" else 0.42
			burst.direction = Vector3.UP
			burst.spread = 82.0 if kind == "dust" else 70.0
			burst.initial_velocity_min = 0.7 if kind == "dust" else 2.4
			burst.initial_velocity_max = 1.5 if kind == "dust" else 5.2
			burst.gravity = Vector3(0, -0.6, 0) if kind == "dust" else Vector3(0, -9.0, 0)
			burst.damping_min = 1.6 if kind == "dust" else 0.0
			burst.damping_max = 2.4 if kind == "dust" else 0.0
			burst.scale_amount_curve = grow
			burst.color_ramp = fade
			burst.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
			burst.emission_sphere_radius = 0.16
			burst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(burst)
			(dust_pool if kind == "dust" else spark_pool).append(burst)

## Extras that only High shows: drifting motes in the shaft and a soft veil
## of light round the core, standing in for bloom.
func _build_high_fx(soft: Texture2D) -> void:
	high_fx = Node3D.new()
	high_fx.visible = false
	add_child(high_fx)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.vertex_color_use_as_albedo = true
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.billboard_keep_scale = true
	mat.albedo_texture = soft
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * 0.08
	quad.material = mat
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.2, 0.8, 1.0])
	fade.colors = PackedColorArray([Color(1, 1, 1, 0), Color(1, 1, 1, 0.6), Color(1, 1, 1, 0.6), Color(1, 1, 1, 0)])
	var motes := CPUParticles3D.new()
	motes.mesh = quad
	motes.amount = 70
	motes.lifetime = 7.0
	motes.preprocess = 7.0
	# A ring over the deck: nothing spawns in front of the camera's nose.
	motes.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	motes.emission_ring_axis = Vector3.UP
	motes.emission_ring_radius = 7.6
	motes.emission_ring_inner_radius = 2.7
	motes.emission_ring_height = 8.0
	motes.position = Vector3(0, 2.0, 0)
	motes.direction = Vector3.UP
	motes.spread = 25.0
	motes.gravity = Vector3.ZERO
	motes.initial_velocity_min = 0.2
	motes.initial_velocity_max = 0.55
	motes.scale_amount_min = 0.5
	motes.scale_amount_max = 1.5
	motes.color = Color(0.75, 1.0, 0.96)
	motes.color_ramp = fade
	motes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	high_fx.add_child(motes)
	var veil := MeshInstance3D.new()
	var shell := CylinderMesh.new()
	shell.top_radius = 2.46
	shell.bottom_radius = 2.46
	shell.height = 40.0
	shell.radial_segments = 24
	shell.rings = 1
	shell.cap_top = false
	shell.cap_bottom = false
	veil.mesh = shell
	veil.position.y = -1.0
	veil.material_override = Kit.shader_material(Kit.VEIL_SHADER)
	veil.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	high_fx.add_child(veil)

func _burst(kind: String, at: Vector3, tint: Color) -> void:
	var pool: Array = dust_pool if kind == "dust" else spark_pool
	if pool.is_empty(): return
	var cursor: int = pool_cursor[kind]
	var burst: CPUParticles3D = pool[cursor % pool.size()]
	pool_cursor[kind] = cursor + 1
	burst.position = at
	burst.color = tint
	burst.restart()
	burst.emitting = true

## The menu column's right edge, as a fraction of the screen width. Menu and
## podium views centre the scene in the space to its right.
func set_inset(value: float) -> void:
	inset = clampf(value, 0.0, 0.8)
	_place_camera()

func _place_camera() -> void:
	if not camera: return
	var screen := get_viewport().get_visible_rect().size
	var aspect := screen.x / maxf(screen.y, 1.0)
	var half_h := tan(deg_to_rad(float(view.fov)) * 0.5)
	var half_w_ref := half_h * REFERENCE_ASPECT
	if aspect < REFERENCE_ASPECT:
		half_h = half_w_ref / aspect
	var half_w := half_h * aspect
	var az: float = view.az
	var target: Vector3 = view.target
	var home := Vector3(sin(az) * view.radius, view.height, cos(az) * view.radius)
	var shift := 0.0
	if view.framed:
		# Back off when the space beside the column is narrower than on the
		# design screen, then slide the target to the middle of that space.
		var pull := maxf(1.0, (1.0 - REFERENCE_INSET) * half_w_ref / ((1.0 - inset) * half_w))
		home = target + (home - target) * pull
		shift = inset * MENU_LEAD * home.distance_to(target) * half_w
	var sway := Vector3(sin(decor_time * 0.31) * 0.12, sin(decor_time * 0.43) * 0.07, 0.0)
	var jolt := Vector3(sin(decor_time * 71.0), sin(decor_time * 93.0 + 1.3), 0.0) * shake * 0.11
	camera.position = home
	camera.look_at(target)
	camera.position += camera.basis * (sway + jolt - Vector3(shift, 0, 0))
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.fov = rad_to_deg(2.0 * atan(half_h))

func set_menu(value: bool) -> void:
	show_identities = false
	if is_instance_valid(victory): victory.queue_free()
	victory = null
	menu_mode = value
	display_progress = 0.0
	last_progress = -1.0
	view = MENU_VIEW if value else GAME_VIEW
	shake = 0.0
	boost = 0.0
	last_stage = 0
	if hud_shade: hud_shade.visible = not value and level != "low"
	_place_camera()
	_clear_rods()
	for r in runners:
		_reset_runner(r)
		r.airborne = false
	visual_round = -1

## Puts a runner back on its lane after a knockout carried it away.
func _reset_runner(r: Dictionary) -> void:
	r.out = -1.0
	r.root.position = Vector3(0, 0, r.radius)
	r.root.rotation = Vector3.ZERO
	r.root.scale = Vector3.ONE

## Attract-mode obstacles for the menu: a steady parade of rollers that the
## robots clear on their own.
func _demo_waves(progress_value: float) -> Array:
	var waves: Array = []
	var first := int(floor((progress_value - 1.2 - 0.6) / 1.5))
	for k in range(maxi(first, 0), first + 5):
		waves.append({"id": k, "at": 1.2 + k * 1.5, "kind": "duck" if k % 3 == 1 else "jump"})
	return waves

func update_visuals(model: RefCounted, delta: float, own_slot: int = 0) -> void:
	local_slot = own_slot
	if model and visual_round != model.round_id:
		_clear_rods()
		visual_round = model.round_id
		last_stage = 0
		for i in runners.size():
			runners[i].hp = model.players[i].hp
			runners[i].score = model.players[i].score
			_reset_runner(runners[i])
		_warm_up()
	if _warm_frames > 0:
		_warm_frames -= 1
		if _warm_frames == 0 and is_instance_valid(_warm):
			_warm.queue_free()
			_warm = null
	decor_time += delta
	shake = maxf(0.0, shake - delta * 3.2)
	boost = maxf(0.0, boost - delta * 0.9)
	if predicted_jump >= 0.0:
		predicted_jump += delta
		if predicted_jump >= Model.JUMP_DURATION:
			predicted_jump = 0.0 if predicted_jump_queued else -1.0
			predicted_jump_queued = false
	var demo_speed := 0.5
	var progress_value: float = decor_time * demo_speed
	var belt_speed := demo_speed
	if model:
		# Smooth 20 Hz network snapshots while keeping the collision marker tied
		# to server time. Large corrections (new rounds) snap immediately.
		if absf(display_progress - model.progress) > 0.3 or last_progress < 0:
			display_progress = model.progress
		elif model.phase == "running":
			display_progress += model.speed * delta
			display_progress = lerpf(display_progress, model.progress, minf(delta * 12.0, 1.0))
		last_progress = model.progress
		progress_value = display_progress
		belt_speed = model.speed
		var stage := 0 if model.elapsed < 25 else (1 if model.elapsed < 60 else 2)
		if stage > last_stage and model.phase == "running": boost = 1.0
		last_stage = stage
	var pace := clampf((belt_speed - 0.68) / 1.02, 0.0, 1.0)
	belt_material.set_shader_parameter("belt", fposmod(progress_value, TAU))
	belt_material.set_shader_parameter("boost", boost)
	glass_material.set_shader_parameter("pulse", boost)
	glass_material.set_shader_parameter("flow", 1.0 + pace * 1.6)
	glow_material.set_shader_parameter("energy", 1.7 + boost * 1.6 + sin(decor_time * 2.2) * 0.08)
	var waves: Array = model.waves if model else _demo_waves(progress_value)
	if is_instance_valid(victory): waves = []
	var last_kind := "duck"
	for wave in waves:
		if float(wave.at) <= progress_value: last_kind = wave.kind
	for i in runners.size():
		var r: Dictionary = runners[i]
		var visual: Node3D = r.visual
		var jump_clock := -1.0
		var duck := false
		var hp := 7
		var flash := 0.0
		var mode := "run"
		if model and not model.players.is_empty():
			var p: Dictionary = model.players[i]
			if not p.get("active", true):
				visual.hide()
				continue
			jump_clock = p.jump
			if client_motion:
				if jump_clock >= 0.0:
					r.visual_jump = jump_clock if r.visual_jump < 0 else lerpf(minf(Model.JUMP_DURATION, r.visual_jump + delta), jump_clock, minf(delta * 8.0, 1.0))
				else: r.visual_jump = -1.0
				jump_clock = r.visual_jump
				if i == own_slot:
					if predicted_jump_active:
						jump_clock = predicted_jump
						if predicted_jump < 0.0 and p.jump < 0.0: predicted_jump_active = false
					if predicted_duck_active and p.duck == predicted_duck: predicted_duck_active = false
			duck = (predicted_duck if client_motion and i == own_slot and predicted_duck_active else p.duck) and jump_clock < 0.0
			hp = p.hp
			flash = p.flash
			if model.phase == "countdown": mode = "idle"
			elif model.phase == "finished": mode = "victory" if hp > 0 else "idle"
		else:
			# Attract mode: clear the demo rollers with a little per-lane timing.
			for wave in waves:
				var eta := (float(wave.at) - progress_value) / demo_speed + sin(i * 2.4) * 0.05
				if wave.kind == "jump":
					var clock := Model.JUMP_DURATION * 0.5 - eta
					if clock >= 0.0 and clock < Model.JUMP_DURATION: jump_clock = clock
				elif absf(eta) < 0.42: duck = true
		# A runner that just lost its last coil is bowled over and carried off
		# down the belt before it disappears.
		if hp <= 0 and r.hp > 0 and model and model.phase == "running":
			r.out = 0.0
			_burst("spark", visual.position + Vector3(0, 0.8, 0), team_color(i))
		if hp > 0 and r.out >= 0.0: _reset_runner(r)
		if r.out >= 0.0:
			r.out += delta
			mode = "down"
			jump_clock = -1.0
			duck = false
			var drift: float = maxf(0.0, r.out - 0.25) * belt_speed
			visual.position = _point(r.radius, -drift, 0.0)
			visual.rotation.y = -drift
			visual.scale = Vector3.ONE * clampf((2.3 - r.out) / 0.3, 0.0, 1.0)
			if r.out > 2.3: r.out = 99.0
		visual.visible = (hp > 0 or (r.out >= 0.0 and r.out < 2.3)) and not is_instance_valid(victory)
		visual.set_markers(hp > 0)
		visual.pose(delta, {"mode": mode, "jump": jump_clock, "duck": duck, "flash": flash if hp > 0 else 0.0, "speed": belt_speed, "hit_kind": last_kind})
		# Dust when the feet leave and meet the deck.
		var airborne := jump_clock >= 0.0
		if airborne != r.airborne and visual.visible and delta > 0.0:
			_burst("dust", visual.position + Vector3(0.05, 0.08, 0), Color(0.93, 0.98, 1.0))
		r.airborne = airborne
		var jump := Model.jump_height({"jump": jump_clock})
		var local := i == own_slot or (local_mask >> i) & 1 == 1
		visual.set_ring(local and model != null, 0.5 + 0.5 * sin(decor_time * 5.0))
		r.tag.position.y = 1.62 + jump + (0.3 * (i % 2) if show_identities else 0.0)
		if model and not model.players.is_empty():
			var score: int = model.players[i].score
			if hp < r.hp and model.phase == "running":
				_burst("spark", visual.position + Vector3(0.25, ROD_LOW if last_kind == "jump" else ROD_HIGH, 0), JUMP_COLOR if last_kind == "jump" else DUCK_COLOR)
				if i == own_slot: shake = 1.0
			elif score > r.score and i == own_slot and model.phase == "running":
				_burst("spark", visual.position + Vector3(0, 0.25, 0), team_color(i).lightened(0.3))
			r.hp = hp
			r.score = score
		else:
			r.hp = 7
			r.score = 0
		r.tag.visible = model != null and (show_identities or (local_mask >> i) & 1 == 1) and model.phase != "finished" and hp > 0
		if r.tag.visible:
			var tag_text := "%02d / %s" % [i + 1, model.players[i].name]
			if r.tag.text != tag_text: r.tag.text = tag_text
		if i == own_slot:
			# Hidden near the top of a jump, where it would leave the screen.
			you_marker.visible = model != null and model.phase != "finished" and hp > 0 and not show_identities and local_mask == 0 and not is_instance_valid(victory) and jump < 0.45
			you_marker.position = visual.position + Vector3(0, 1.72 + jump * 0.85 + sin(decor_time * 5.0) * 0.045 - (0.55 if duck else 0.0), 0)
			you_marker.get_node("Pointer").material_override.set_shader_parameter("fill", team_color(i))
			you_marker.get_node("Text").modulate = team_color(i)
	if is_instance_valid(victory):
		victory.get_node("Hero").pose(delta, {"mode": "victory"})
	for kind in rod_materials:
		rod_materials[kind].roller.set_shader_parameter("spin", progress_value * 0.9)
	var visible_ids: Array = []
	for wave in waves:
		var angle := float(wave.at) - progress_value
		if angle < -0.6 or angle > 4.4:
			continue
		var id: int = wave.id
		visible_ids.append(id)
		if rods.has(id) and rods[id].get_meta("kind") != wave.kind:
			rods[id].queue_free()
			rods.erase(id)
		if not rods.has(id):
			rods[id] = _make_rod(wave.kind)
		var group: Node3D = rods[id]
		group.rotation.y = angle
		group.position.y = angle / TAU * PITCH
		var icon: Node3D = group.get_node("Icon")
		icon.position.y = float(icon.get_meta("rest")) + sin(decor_time * 6.0 + id) * 0.05
	for id in rods.keys():
		if id not in visible_ids:
			rods[id].queue_free()
			rods.erase(id)
	_place_camera()

## One roller arm: a collar clamped to the tower's helical rail, the striped
## roller spanning all six lanes, and a carriage riding the outer kerb.
func _rod_template(kind: String) -> Node3D:
	if rod_templates.has(kind): return rod_templates[kind]
	var root := Node3D.new()
	var tint := JUMP_COLOR if kind == "jump" else DUCK_COLOR
	var height := ROD_LOW if kind == "jump" else ROD_HIGH
	var z0 := 2.5
	var z1 := TRACK_OUTER - 0.06
	var roller_material := Kit.shader_material(Kit.ROD_SHADER, {"tint": tint, "half_length": (z1 - z0) * 0.5})
	rod_materials[kind] = {"roller": roller_material}
	var roller := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = ROD_RADIUS
	cylinder.bottom_radius = ROD_RADIUS
	cylinder.height = z1 - z0
	cylinder.radial_segments = 14
	cylinder.rings = 1
	roller.mesh = cylinder
	roller.name = "Roller"
	roller.material_override = roller_material
	roller.rotation.x = PI / 2.0
	roller.position = Vector3(0, height, (z0 + z1) * 0.5)
	root.add_child(roller)
	var batch := Kit.Batch.new()
	# Collar on the tower rail.
	batch.arc(Kit.SOLID, 1.98, 2.56, height - 0.2, height + 0.2, -0.2, 0.2, 4, tint, 0.0)
	for side in [-1.0, 1.0]:
		batch.arc(Kit.SOLID, 1.96, 2.62, height - 0.25, height + 0.25, side * 0.23 - 0.035, side * 0.23 + 0.035, 1, STEEL_LIGHT, 0.0)
		var a: float = side * 0.11
		var bolt := Transform3D(Basis(Vector3.UP, a) * Basis(Vector3.RIGHT, PI / 2.0), Vector3(sin(a) * 2.55, height, cos(a) * 2.55))
		batch.prism(Kit.SOLID, bolt, 0.075, 0.075, 0.06, 6, STEEL_LIGHT)
	# Carriage on the outer kerb with a hexagonal cap and base.
	var kerb := TRACK_OUTER + 0.11
	batch.prism(Kit.SOLID, Transform3D(Basis.IDENTITY, Vector3(0, 0.1, kerb)), 0.3, 0.26, 0.12, 6, tint, TAU / 12.0)
	batch.box(Kit.SOLID, Transform3D(Basis.IDENTITY, Vector3(0, (height + 0.36) * 0.5 + 0.05, kerb)), Vector3(0.32, height + 0.16, 0.3), 0.05, STEEL)
	batch.prism(Kit.SOLID, Transform3D(Basis(Vector3.RIGHT, PI / 2.0), Vector3(0, height, kerb + 0.14)), 0.2, 0.17, 0.12, 6, tint)
	batch.prism(Kit.SOLID, Transform3D(Basis.IDENTITY, Vector3(0, height + 0.24, kerb)), 0.2, 0.16, 0.1, 6, tint, TAU / 12.0)
	batch.commit(root, {Kit.SOLID: solid_material})
	# Contact shadow on the deck.
	var shadow := MeshInstance3D.new()
	var plane := QuadMesh.new()
	plane.orientation = PlaneMesh.FACE_Y
	plane.size = Vector2(0.62 if kind == "jump" else 0.8, z1 - z0 + 0.3)
	shadow.mesh = plane
	shadow.material_override = Kit.shader_material(Kit.BLOB_SHADER, {"strength": 0.5 if kind == "jump" else 0.3})
	shadow.position = Vector3(0.04, 0.03, (z0 + z1) * 0.5)
	shadow.name = "Shadow"
	root.add_child(shadow)
	# One bold arrow above the outer carriage: up means jump, down means duck.
	var icon := _icon(0 if kind == "jump" else 1, tint.lightened(0.12), 0.62)
	icon.name = "Icon"
	icon.position = Vector3(0, height + 0.78, kerb)
	icon.set_meta("rest", icon.position.y)
	root.add_child(icon)
	for node in root.find_children("*", "MeshInstance3D", true, false):
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rod_templates[kind] = root
	return root

## The first rod and the first dust and spark bursts must not hitch: the
## Compatibility renderer compiles a material's shader the first time it draws
## it, ~100-150 ms on a Raspberry Pi 4 right as the first rod arrives. So when a
## round starts (the countdown) one rod of each kind and one burst of each kind
## are drawn for a few frames tucked under the deck below the first runner:
## inside the camera's view, so they are drawn and compiled, but hidden behind
## the deck.
func _warm_up() -> void:
	if not is_inside_tree() or runners.is_empty():
		return
	if is_instance_valid(_warm):
		_warm.queue_free()
	_warm = Node3D.new()
	_warm.name = "WarmUp"
	add_child(_warm)
	var under: Vector3 = runners[0].visual.global_position + Vector3(0.0, -1.1, 0.0)
	_warm.global_position = under
	for kind in ["jump", "duck"]:
		var rod: Node3D = _rod_template(kind).duplicate()
		rod.scale = Vector3.ONE * 0.15
		_warm.add_child(rod)
	for pool in [dust_pool, spark_pool]:
		if not pool.is_empty():
			var burst: CPUParticles3D = pool[0]
			burst.global_position = under
			burst.restart()
			burst.emitting = true
	_warm_frames = 4

func _make_rod(kind: String) -> Node3D:
	var root: Node3D = _rod_template(kind).duplicate()
	root.set_meta("kind", kind)
	root.get_node("Icon").set_meta("rest", ROD_LOW + 0.78 if kind == "jump" else ROD_HIGH + 0.78)
	rod_root.add_child(root)
	return root

func _clear_rods() -> void:
	for id in rods: rods[id].queue_free()
	rods.clear()
	predicted_jump = -1.0
	predicted_jump_active = false
	predicted_jump_queued = false
	predicted_duck_active = false

## Older two-state switch: true is High, false is Balanced.
func set_detail(value: bool) -> void:
	set_level("high" if value else "balanced")

## Applies a graphics level. Each lever below was measured on llvmpipe; the
## ones that made no measurable difference (fog-free dome, simpler deck
## shader, vertex lighting, fewer particles) are left alone. See the README.
func set_level(value: String) -> void:
	level = value if value in LEVELS else "balanced"
	detailed = level == "high"
	var low := level == "low"
	# Low on a real GPU (a Raspberry Pi) keeps High's scenery, lights and fog:
	# measured there, the full structure, the full gantry rings, the motes and
	# the glow veil cost nothing, and the light and fog are baked into the
	# scenery shaders. A software rasteriser keeps Low's lighter cut, where
	# every triangle and blended pixel is CPU time.
	var full_scene := not low or not software
	var viewport := get_viewport()
	viewport.msaa_3d = Viewport.MSAA_4X if detailed else Viewport.MSAA_DISABLED
	# Bilinear is the only 3D scaler the Compatibility renderer has.
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	viewport.scaling_3d_scale = LOW_RENDER_SCALE if low else 1.0
	if high_fx: high_fx.visible = detailed or (low and not software)
	if environment:
		# Low's fog is baked into the scenery shaders instead (~4.6 ms on a Pi).
		environment.fog_enabled = not low
		# Without the fill lights, lift the ambient so undersides stay out of black.
		environment.ambient_light_energy = SOFTWARE_LOW_AMBIENT if low and software else AMBIENT
	for light in fill_lights: light.visible = not (low and software)
	# Low bakes the lights and the fog into the structure, the lamps and the
	# deck (Kit.BAKED_LIGHT): on a Raspberry Pi 4 any lit material costs ~4 ms.
	solid_material.shader = Kit.shader(Kit.SOLID_BAKED_SHADER if low else Kit.SOLID_SHADER)
	# Low's deck reads its moving pattern from a texture rendered once; until
	# that is ready (a frame or two) it keeps the analytic shader.
	if low and _deck_pattern == null:
		_render_deck_pattern()
	belt_material.shader = Kit.shader(Kit.DECK_LOW_SHADER if low and _deck_pattern else Kit.DECK_SHADER)
	glow_material.shader = Kit.shader(Kit.GLOW_BAKED_SHADER if low else Kit.GLOW_SHADER)
	if low:
		_bake_light([solid_material, belt_material, glow_material])
	for node in backdrop: node.visible = full_scene
	for node in backdrop_lite: node.visible = not full_scene
	for node in structure: node.visible = full_scene
	for node in structure_lite: node.visible = not full_scene
	# The shade strips behind the HUD blend half the screen at full resolution:
	# ~3 ms a frame on llvmpipe and on a Pi. On Low, scripts/scaled_view.gd
	# folds them into the pass that stretches the 3D up (wants_picture_shade()).
	if hud_shade: hud_shade.visible = not menu_mode and not low
	for runner in runners:
		# With silhouette shadows the blob only grounds the feet. Low on a GPU
		# (a Raspberry Pi) uses High's full-detail robot, measured no dearer
		# there than Balanced's, over the blob shadow: the silhouette shadows
		# are what cost.
		runner.visual.set_quality("high" if low and not software else level, 0.16 if detailed else 0.72, detailed)

## Renders Kit.DECK_PATTERN_SHADER once into a 4096x512 texture with mipmaps
## for Low's deck (Kit.DECK_LOW_SHADER), then switches the deck to it if Low is
## still the level. Takes a frame; the deck keeps its analytic shader till then.
func _render_deck_pattern() -> void:
	if _deck_painter or not is_inside_tree():
		return
	_deck_painter = SubViewport.new()
	_deck_painter.size = DECK_PATTERN_SIZE
	_deck_painter.disable_3d = true
	_deck_painter.transparent_bg = true
	_deck_painter.render_target_update_mode = SubViewport.UPDATE_ONCE
	var canvas := ColorRect.new()
	canvas.size = Vector2(DECK_PATTERN_SIZE)
	canvas.material = Kit.shader_material(Kit.DECK_PATTERN_SHADER, {"texels": Vector2(DECK_PATTERN_SIZE)})
	_deck_painter.add_child(canvas)
	add_child(_deck_painter)
	await RenderingServer.frame_post_draw
	var image := _deck_painter.get_texture().get_image()
	_deck_painter.queue_free()
	_deck_painter = null
	if image == null or image.is_empty():
		return
	image.convert(Image.FORMAT_RGBA8)
	image.generate_mipmaps()
	_deck_pattern = ImageTexture.create_from_image(image)
	belt_material.set_shader_parameter("pattern", _deck_pattern)
	if level == "low":
		belt_material.shader = Kit.shader(Kit.DECK_LOW_SHADER)
		_bake_light([belt_material])

## Whether scripts/scaled_view.gd should darken the bands behind the HUD, as
## the hud_shade strips do on the other levels.
func wants_picture_shade() -> bool:
	return visible and not menu_mode and level == "low"

## A software rasteriser (llvmpipe, SwiftShader and the like).
static func software_renderer(adapter_name: String) -> bool:
	var adapter := adapter_name.to_lower()
	for name_part in ["llvmpipe", "softpipe", "swiftshader", "lavapipe", "software", "microsoft basic render", "gdi generic"]:
		if name_part in adapter: return true
	return false

## High's lighting and fog as Kit.BAKED_LIGHT wants them: linear, energy in.
## Always High's three lights and ambient, whichever lights are on now, so the
## baked scenery matches High on every machine.
func _bake_light(materials: Array) -> void:
	var lights := [key_light] + fill_lights
	var names := ["key", "fill", "up"]
	var amb := environment.ambient_light_color.srgb_to_linear() * AMBIENT
	var fog := environment.fog_light_color.srgb_to_linear() * environment.fog_light_energy
	for mat: ShaderMaterial in materials:
		for i in names.size():
			var light: DirectionalLight3D = lights[i]
			var c := light.light_color.srgb_to_linear() * light.light_energy
			mat.set_shader_parameter(names[i] + "_dir", light.basis.z.normalized())
			mat.set_shader_parameter(names[i] + "_light", Vector3(c.r, c.g, c.b))
		mat.set_shader_parameter("ambient_light", Vector3(amb.r, amb.g, amb.b))
		mat.set_shader_parameter("fog_color", Vector4(fog.r, fog.g, fog.b, environment.fog_density))
		mat.set_shader_parameter("fog_range", Vector3(environment.fog_depth_begin, environment.fog_depth_end, environment.fog_depth_curve))

func predict_action(action: String, pressed: bool) -> void:
	if not client_motion: return
	if action == "duck":
		predicted_duck = pressed
		predicted_duck_active = true
	elif action == "jump" and pressed:
		if predicted_jump < 0.0:
			predicted_jump = 0.0
			predicted_jump_active = true
		elif predicted_jump >= Model.JUMP_DURATION - Model.JUMP_BUFFER:
			predicted_jump_queued = true

## Winner's podium for the results screen.
func celebrate(slot: int) -> void:
	if slot < 0 or slot >= runners.size(): return
	victory = Node3D.new()
	victory.position = Vector3(0.0, 0.0, 5.2)
	add_child(victory)
	view = PODIUM_VIEW
	var hero: Node3D = RunnerVisual.new()
	hero.name = "Hero"
	victory.add_child(hero)
	hero.setup(team_color(slot))
	hero.set_quality(("balanced" if software else "high") if level == "low" else level, 0.0, false)
	hero.set_markers(false)
	hero.position.y = 0.62
	hero.scale = Vector3.ONE * 2.2
	hero.body.rotation.y = 0.95
	hero.pose(0.0, {"mode": "victory"})
	# Start with the arms already going up, so the first frame is a cheer.
	hero.anim.seek(hero.anim.current_animation_length * 0.3, true)
	var batch := Kit.Batch.new()
	batch.prism(Kit.SOLID, Transform3D(Basis.IDENTITY, Vector3(0, 0.0, 0)), 1.75, 1.6, 0.34, 8, STEEL_DARK, TAU / 16.0)
	batch.prism(Kit.SOLID, Transform3D(Basis.IDENTITY, Vector3(0, 0.34, 0)), 1.42, 1.3, 0.3, 8, team_color(slot), TAU / 16.0)
	batch.prism(Kit.GLOW, Transform3D(Basis.IDENTITY, Vector3(0, 0.3, 0)), 1.66, 1.66, 0.05, 8, team_color(slot), TAU / 16.0)
	batch.commit(victory, {Kit.SOLID: solid_material, Kit.GLOW: glow_material})
