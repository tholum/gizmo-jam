extends Node3D
## The stockyard. Geometry is cosmetic; field marks share the model's exact radii.

const Model = preload("res://games/stampede_sheriff/model.gd")
const Pieces = preload("res://games/stampede_sheriff/pieces.gd")
const Art = preload("res://scripts/arena_kit.gd")
const Kit = preload("res://scripts/ui_kit.gd")

const CREAM := Color("fff3cc")
const GOLD := Color("ffd368")
const ORANGE := Color("ff9255")
const TRIM := Color("404940")
const DARK := Color("252f2a")
const WOOD := Color("825343")
const BRASS := Color("c58b51")
const CLAP_FLASH_TICKS := 19

const GROUND_SHADER := """
shader_type spatial;
render_mode unshaded, shadows_disabled;
varying vec2 at;
uniform bool fine_detail = true;
float random(vec2 p) { return fract(sin(dot(p, vec2(123.7, 247.1))) * 43127.57); }
void vertex() { at = VERTEX.xz; }
void fragment() {
	float r = length(at);
	float radial = atan(at.y, at.x);
	float aa = max(fwidth(r), 0.009);
	float shade = smoothstep(4.0, 10.9, r);
	vec3 clay = mix(vec3(0.69, 0.42, 0.26), vec3(0.54, 0.30, 0.20), shade);
	float ripples = sin(at.x * 1.2 + at.y * 1.8 + sin(at.x * 0.7) * 2.0);
	clay += 0.021 * ripples + 0.014 * sin(radial * 6.0 + r * 1.6) * smoothstep(0.05, 2.5, r);
	float guide = 1.0 - smoothstep(0.033, 0.033 + aa, abs(r - 6.72));
	clay += vec3(0.077, 0.049, 0.020) * guide * smoothstep(0.10, 0.48, cos(radial * 96.0));
	float gear = 1.35 + 0.076 * smoothstep(0.17, 0.24, cos(radial * 12.0));
	float teeth = 1.0 - smoothstep(0.030, 0.030 + aa, abs(r - gear));
	float hub = 1.0 - smoothstep(0.031, 0.031 + aa, abs(r - 0.51));
	float spoke = (1.0 - smoothstep(0.032, 0.032 + aa, abs(sin(radial * 3.0)) * r))
		* smoothstep(0.47, 0.51, r) * (1.0 - smoothstep(1.23, 1.30, r));
	clay = mix(clay, vec3(0.84, 0.58, 0.35), max(teeth, max(hub, spoke)) * 0.36);
	if (fine_detail) {
		float sand = random(floor(at * 38.0)) - 0.5;
		float grit = random(floor(at * 6.5)) - 0.5;
		clay += (sand * 0.095 + grit * 0.047) * (1.0 - smoothstep(0.022, 0.052, aa));
	}
	float border = smoothstep(10.58 - aa, 10.58 + aa, r);
	float edge = 1.0 - smoothstep(0.036, 0.036 + aa, abs(r - 10.58));
	float dot_tick = smoothstep(0.6, 0.96, cos(radial * 96.0));
	clay = mix(clay, vec3(0.32, 0.27, 0.22) + dot_tick * 0.05, border * 0.9);
	clay = mix(clay, vec3(0.99, 0.75, 0.45), edge * 0.73);
	ALBEDO = clay;
}
"""

const OUTSIDE_SHADER := """
shader_type spatial;
render_mode unshaded, shadows_disabled;
varying vec2 at;
void vertex() { at = VERTEX.xz; }
void fragment() {
	float r = length(at);
	vec3 fog = vec3(0.055, 0.135, 0.137);
	vec3 terrain = mix(vec3(0.26, 0.35, 0.31), fog, smoothstep(11.0, 31.0, r));
	float d = sin(at.x * 1.29 + at.y * 1.4 + sin(at.y * 0.45) * 2.1);
	float ridges = smoothstep(0.15, 0.98, d) * 0.048;
	float glow = exp(-pow((r - 12.0) / 4.0, 2.0)) * 0.08;
	ALBEDO = terrain * (0.90 + ridges) + vec3(glow * 0.7, glow, glow * 0.8);
}
"""

const RING_SHADER := """
shader_type spatial;
render_mode unshaded, shadows_disabled, cull_disabled;
uniform vec4 tint : source_color = vec4(1.0);
uniform float radius = 0.7;
uniform float thickness = 0.07;
uniform float fill = 1.0;
uniform float opacity = 1.0;
uniform bool track = false;
uniform float segments = 0.0;
uniform vec3 channel : source_color = vec3(0.09, 0.10, 0.09);
varying vec2 at;
void vertex() { at = VERTEX.xz; }
void fragment() {
	float r = length(at);
	float aa = max(fwidth(r), 0.01);
	float arc = fract(atan(at.x, -at.y) / 6.283185 + 1.0);
	float ring = 1.0 - smoothstep(thickness, thickness + aa, abs(r - radius));
	float line = 1.0 - smoothstep(thickness * 0.53, thickness * 0.53 + aa, abs(r - radius));
	float dark = (track ? ring * 0.89 : 0.0);
	float lit = line * step(arc, fill);
	ALBEDO = mix(channel, tint.rgb, lit);
	float sections = segments > 0.0 ? smoothstep(0.18, 0.26, cos(arc * 6.283185 * segments)) : 1.0;
	ALPHA = max(dark, lit) * opacity * sections;
}
"""

const CONE_SHADER := """
shader_type spatial;
render_mode unshaded, shadows_disabled, cull_disabled;
uniform vec4 tint : source_color = vec4(1.0);
uniform float reach;
uniform float half_angle;
uniform float field_radius;
uniform float pulse = -1.0;
uniform float opacity = 1.0;
varying vec2 at;
varying vec2 world;
void vertex() {
	at = VERTEX.xz;
	world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}
void fragment() {
	float r = length(at);
	float a = abs(atan(at.y, at.x));
	float scale = max(fwidth(r), 0.01);
	float shape = smoothstep(0.39, 0.57, r) * (1.0 - smoothstep(reach - scale, reach + scale, r));
	shape *= 1.0 - smoothstep(half_angle, half_angle + 0.018, a);
	shape *= 1.0 - smoothstep(field_radius - 0.02, field_radius + 0.03, length(world));
	float edge = max(smoothstep(half_angle - 0.035, half_angle - 0.006, a), smoothstep(reach - 0.12, reach - 0.05, r));
	float stripe = 1.0 - smoothstep(0.035, 0.09, abs(fract((r - 0.32) * 1.45) - 0.5));
	float arc = 1.0 - smoothstep(0.065, 0.16, abs(r - mix(0.48, reach + 0.04, pulse)));
	float idle = 0.14 + 0.34 * edge + stripe * 0.24;
	ALPHA = shape * opacity * (pulse < 0.0 ? idle : (0.19 + arc * 0.80) * (1.0 - pulse * 0.51));
	ALBEDO = tint.rgb;
}
"""

var camera: Camera3D
var local_mask := 0
var show_identities := false
var client_motion := false

var _menu := true
var _inset := 0.0
var _level := "balanced"
var _ground: ShaderMaterial
var _solid: Material
var _shadow: Mesh
var _shadow_material: StandardMaterial3D
var _state: RefCounted
var _clock := 0.0
var _champion := -1
var _sheriffs: Array[Dictionary] = []
var _animals: Array[Dictionary] = []
var _pens: Array[Dictionary] = []
var _hatches: Array[Dictionary] = []

func _ready() -> void:
	Kit.setup()
	_setup_camera()
	_setup_materials()
	_build_yard()
	for i in Model.SEATS:
		_build_pen(i)
		_build_sheriff(i)
	for i in Model.HATCHES:
		_build_hatch(i)
	for i in Model.MAX_CRITTERS:
		_build_critter()
	set_level(_level)
	get_viewport().size_changed.connect(_frame_camera)
	_frame_camera()

func set_menu(on: bool) -> void:
	_menu = on
	show_identities = false
	if not on:
		_champion = -1
	_frame_camera()

func set_inset(value: float) -> void:
	_inset = clampf(value, 0.0, 0.80)
	_frame_camera()

func set_level(value: String) -> void:
	_level = value
	if _ground:
		_ground.set_shader_parameter("fine_detail", value != "low")

func celebrate(slot: int) -> void:
	_champion = slot

func _setup_camera() -> void:
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.near = 0.5
	camera.far = 100.0
	var sky := Environment.new()
	sky.background_mode = Environment.BG_COLOR
	sky.background_color = Color("102c2e")
	sky.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	sky.ambient_light_color = Color("d4e7d3")
	sky.ambient_light_energy = 0.66
	camera.environment = sky
	add_child(camera)
	camera.position = Vector3(0, 34, 17.4)
	camera.look_at(Vector3.ZERO)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-56, -29, 0)
	sun.light_color = Color("ffe8bd")
	sun.light_energy = 1.10
	add_child(sun)

func _frame_camera() -> void:
	if camera == null:
		return
	var screen_size := get_viewport().get_visible_rect().size
	var aspect := screen_size.x / maxf(screen_size.y, 1.0)
	var inset := _inset if _menu else 0.0
	camera.size = maxf(25.3 if _menu else 25.0, 22.8 / maxf((1.0 - inset) * aspect, 0.15))
	camera.h_offset = -inset * camera.size * aspect * 0.5
	camera.v_offset = -0.53 if _menu else -0.90

func _setup_materials() -> void:
	_solid = Art.shader_material(Art.SOLID_SHADER, {"bounce": Color("8fbd9a"), "bounce_power": 0.25})
	_ground = Art.shader_material(GROUND_SHADER, {})
	var quad := QuadMesh.new()
	quad.orientation = PlaneMesh.FACE_Y
	quad.size = Vector2.ONE * 2.0
	_shadow = quad
	_shadow_material = StandardMaterial3D.new()
	_shadow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_shadow_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var image := Image.create(48, 48, false, Image.FORMAT_RGBA8)
	for y in 48:
		for x in 48:
			var r := (Vector2(x, y) / 47.0 * 2.0 - Vector2.ONE).length()
			image.set_pixel(x, y, Color(0.16, 0.09, 0.07, 0.58 * (1.0 - smoothstep(0.25, 1.0, r))))
	_shadow_material.albedo_texture = ImageTexture.create_from_image(image)

func _build_yard() -> void:
	_plane(self, 112.0, -0.89, Art.shader_material(OUTSIDE_SHADER, {}))
	var batch := Art.Batch.new()
	var r := Model.FIELD_RADIUS
	batch.arc("floor", 0, r, 0, 0, 0, TAU, 144, Color.WHITE, 0, "t")
	batch.arc("solid", r - 0.015, r + 0.27, -0.66, -0.041, 0, TAU, 144, WOOD, 0, "toe")
	batch.arc("solid", r + 0.15, r + 0.40, -0.81, -0.60, 0, TAU, 144, TRIM, 0, "toe")
	batch.arc("solid", r - 0.045, r + 0.14, -0.15, 0.035, 0, TAU, 144, DARK, 0, "toe")
	var rng := RandomNumberGenerator.new()
	rng.seed = 212061
	for i in 96:
		var angle := TAU * i / 96
		var at := Vector2.from_angle(angle)
		var xf := _outward(at)
		var wood := WOOD.lightened(rng.randf_range(0.015, 0.11))
		Pieces.box(batch, _v(at * (r + 0.13), -0.295), Vector3(0.23, 0.43, 0.69), wood, 0.035, xf)
		if i % 4 == 0:
			Pieces.box(batch, _v(at * (r + 0.28), -0.24), Vector3(0.14, 0.73, 0.16), DARK, 0.036, xf)
			Pieces.box(batch, _v(at * (r + 0.32), -0.083), Vector3(0.069, 0.16, 0.12), BRASS, 0.022, xf)
	# Riveted, six-way survey marks on the clay.
	for i in Model.SEATS:
		var at := Model.pen(i).normalized()
		var xf := _outward(at)
		for f in [1.0, 1.55, 5.52, 6.00]:
			Pieces.box(batch, _v(at * f, 0.006), Vector3(0.055, 0.008, 0.24), WOOD.lightened(0.30), 0, xf)
	# Decorative rock shelves and small silhouettes sit outside the boundary.
	for i in 80:
		var angle := TAU * i / 80.0 + rng.randf_range(-0.06, 0.06)
		var at := Vector2.from_angle(angle) * rng.randf_range(12.45, 30.0)
		var size := rng.randf_range(0.13, 0.75)
		var rock := Color("405b4e").lerp(Color("7b6b4d"), rng.randf())
		for j in 2:
			var rock_at := at + Vector2(rng.randf_range(-0.6, 0.6), rng.randf_range(-0.6, 0.6))
			Pieces.disk(batch, _v(rock_at, -0.89), size, size * rng.randf_range(0.35, 0.78), size * rng.randf_range(0.23, 0.72), rock, 6)
	for i in 12:
		var at := Vector2.from_angle(TAU * (i + 0.30) / 12.0) * rng.randf_range(13.45, 19.0)
		_cactus(batch, at, rng.randf_range(0.75, 1.35), rng.randf_range(-PI, PI))
	for at: Vector2 in [Vector2(-13.65, -3.85), Vector2(13.8, 4.6)]:
		_tank(batch, at)
	for part in batch.commit(self, {"floor": _ground, "solid": _solid}):
		part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _cactus(batch, at: Vector2, size: float, yaw: float) -> void:
	var xf := Transform3D(Basis(Vector3.UP, yaw), _v(at, -0.87))
	var paint := Color("40674e")
	Pieces.disk(batch, xf.origin, 0.22 * size, 0.19 * size, 1.52 * size, paint, 7)
	Pieces.disk(batch, xf * Vector3(0, 1.50 * size, 0), 0.19 * size, 0.05 * size, 0.16 * size, paint, 7)
	for side in [-1.0, 1.0]:
		Pieces.box(batch, xf * (Vector3(0.31 * side, 0.72 + 0.12 * side, 0) * size),
			Vector3(0.42, 0.20, 0.21) * size, paint.lightened(0.08), 0.04, xf.basis)
		Pieces.disk(batch, xf * (Vector3(0.48 * side, 0.72 + 0.12 * side, 0) * size),
			0.14 * size, 0.12 * size, 0.46 * size, paint.lightened(0.08), 7)

func _tank(batch, at: Vector2) -> void:
	for radial in 4:
		var leg := Vector2.from_angle(PI / 4.0 + radial * PI / 2.0) * 0.94
		Pieces.box(batch, _v(at + leg, -0.02), Vector3(0.19, 1.86, 0.19), WOOD.darkened(0.23), 0.034)
	Pieces.disk(batch, _v(at, 0.67), 1.02, 1.05, 0.18, DARK)
	Pieces.disk(batch, _v(at, 0.85), 0.90, 0.94, 1.12, Color("507b71"))
	for height in [0.98, 1.23, 1.80]:
		Pieces.disk(batch, _v(at, height), 0.95, 0.96, 0.062, DARK)
	Pieces.disk(batch, _v(at, 1.95), 1.00, 0.95, 0.10, BRASS)
	Pieces.disk(batch, _v(at, 2.05), 0.96, 0.25, 0.45, TRIM)
	Pieces.disk(batch, _v(at, 2.50), 0.24, 0.24, 0.11, BRASS)

func _build_pen(slot: int) -> void:
	var at := Model.pen(slot)
	var node := Node3D.new()
	node.position = _v(at)
	add_child(node)
	var paint := Kit.colors[slot]
	var batch := Art.Batch.new()
	var r := Model.PEN_RADIUS
	Pieces.disk(batch, Vector3(0, 0.007, 0), r, r, 0.019, paint.darkened(0.63), 48)
	Pieces.disk(batch, Vector3(0, 0.028, 0), r - 0.14, r - 0.14, 0.012, paint.darkened(0.47), 48)
	batch.arc("solid", r - 0.115, r, 0.0, 0.057, 0, TAU, 48, paint.lightened(0.30), 0, "t")
	var a := at.angle()
	for i in 15:
		var phi := a + lerpf(-1.17, 1.17, float(i) / 14.0)
		var out := Vector2.from_angle(phi)
		var xf := _outward(out)
		var point := out * (r + 0.13)
		var height := 0.55 if i % 3 == 0 else 0.36
		Pieces.box(batch, _v(point, height * 0.5), Vector3(0.19, height, 0.26), WOOD.darkened(0.14), 0.033, xf)
		Pieces.box(batch, _v(point, height), Vector3(0.22, 0.10, 0.24), paint, 0.031, xf)
	# Inward-pointing chevrons announce the capture surface.
	var inner := at.normalized() * -1.0
	for k in 2:
		var anchor := inner * (r + 0.32 + k * 0.25)
		var left := _v(anchor + inner.orthogonal() * 0.20, 0.016)
		var tip := _v(anchor - inner * 0.14, 0.016)
		var right := _v(anchor - inner.orthogonal() * 0.20, 0.016)
		batch.tri("solid", left, tip, right, Vector3.UP, paint.darkened(0.22))
	Pieces.finish(batch, node, _solid)
	var rim := _ring(node, r + 0.07, 0.052, paint.lightened(0.53), false, 0.080)
	rim.hide()
	var glyph := Pieces.label(node, str(slot + 1), Vector3(0, 0.18, 0), 0.92, paint.lightened(0.76))
	glyph.no_depth_test = false
	var score := Pieces.label(node, "", _v(at.normalized() * -1.80, 1.08), 0.81, CREAM)
	score.hide()
	_pens.append({"root": node, "ring": rim, "score": score, "total": 0, "gained": 0, "score_tick": Model.NO_TICK})

func _build_hatch(index: int) -> void:
	var node := Node3D.new()
	node.position = _v(Model.hatch(index))
	node.rotation.y = -Model.hatch(index).angle()
	add_child(node)
	var batch := Art.Batch.new()
	Pieces.disk(batch, Vector3(0, 0.015, 0), 0.98, 0.93, 0.083, DARK, 20)
	batch.arc("solid", 0.77, 0.97, 0.06, 0.142, 0, TAU, 32, BRASS, 0, "toe")
	for i in 16:
		var bolt := Vector2.from_angle(TAU * i / 16.0) * 0.87
		Pieces.disk(batch, _v(bolt, 0.142), 0.050, 0.036, 0.032, DARK, 6)
	Pieces.finish(batch, node, _solid)
	var doors: Array[Node3D] = []
	for side in [-1.0, 1.0]:
		var door := Node3D.new()
		var lid := Art.Batch.new()
		Pieces.box(lid, Vector3(0.31 * side, 0.18, 0), Vector3(0.61, 0.19, 1.20), TRIM.lightened(0.13), 0.058)
		for stripe in 3:
			Pieces.box(lid, Vector3((0.16 + stripe * 0.16) * side, 0.278, 0), Vector3(0.053, 0.016, 1.07), WOOD.lightened(0.20), 0.008)
		node.add_child(door)
		Pieces.finish(lid, door, _solid)
		doors.append(door)
	var beacon := _ring(node, 1.19, 0.09, GOLD, true, 0.035)
	beacon.hide()
	var glyph := Pieces.label(node, Model.HATCH_NAMES[index], Vector3(0, 0.32, 0), 0.59, Color("ffe1ab"))
	glyph.no_depth_test = false
	_hatches.append({"doors": doors, "ring": beacon, "label": glyph})

func _build_sheriff(slot: int) -> void:
	var root := Node3D.new()
	root.name = "Sheriff%d" % (slot + 1)
	root.hide()
	add_child(root)
	var rig := Node3D.new()
	root.add_child(rig)
	var look := Pieces.sheriff(rig, Kit.colors[slot], _solid)
	var shadow := _mesh(root, _shadow, _shadow_material, 0.020)
	shadow.scale = Vector3(0.78, 1.0, 0.69)
	var cone := _plane(root, 2.0 * (Model.CLAP_RANGE + 0.09), 0.031, Art.shader_material(CONE_SHADER, {
		"tint": Kit.colors[slot].lightened(0.64), "reach": Model.CLAP_RANGE, "half_angle": Model.CLAP_ANGLE,
		"field_radius": Model.FIELD_RADIUS,
	}))
	var foot_ring := _ring(root, 0.70, 0.13, CREAM, true, 0.052)
	var rival_ring := _ring(root, 0.64, 0.06, Kit.colors[slot].lightened(0.39), false, 0.050)
	foot_ring.material_override.set_shader_parameter("segments", 6.0)
	rival_ring.material_override.set_shader_parameter("opacity", 0.48)
	var tag := Pieces.label(root, str(slot + 1), Vector3(0, 1.63, 0), 0.51, Kit.colors[slot].lightened(0.58))
	_sheriffs.append({"root": root, "rig": rig, "body": look.body, "feet": look.boots, "hands": look.hands, "cone": cone,
		"ring": foot_ring, "rival_ring": rival_ring, "label": tag, "pos": Vector2.ZERO, "face": 0.0, "stride": 0.0})

func _build_critter() -> void:
	var root := Node3D.new()
	root.hide()
	add_child(root)
	var rig := Node3D.new()
	root.add_child(rig)
	var shadow := _mesh(root, _shadow, _shadow_material, 0.021)
	shadow.scale = Vector3(0.65, 1.0, 0.50)
	var rabbit := Pieces.critter(rig, false, _solid)
	var gold := Pieces.critter(rig, true, _solid)
	var recovery := _ring(root, 0.70, 0.076, ORANGE, true, 0.050)
	var tag := Pieces.label(root, "×2", Vector3(0, 1.10, 0), 0.48, GOLD)
	_animals.append({"id": -1, "root": root, "rig": rig, "rabbit": rabbit, "gold": gold, "ring": recovery,
		"label": tag, "pos": Vector2.ZERO, "face": 0.0, "stride": 0.0})

func update_visuals(state: RefCounted, delta: float, own_slot: int = 0) -> void:
	if state == null:
		return
	var fresh := _state != state
	_state = state
	_clock += delta
	var ease := 1.0 if fresh or not client_motion else 1.0 - exp(-29.5 * delta)
	_render_sheriffs(state, delta, own_slot, ease)
	_render_critters(state, ease, fresh)
	_render_yard(state, fresh)

func _render_sheriffs(state: RefCounted, delta: float, own_slot: int, ease: float) -> void:
	for slot in Model.SEATS:
		var p: Dictionary = state.players[slot]
		var visual := _sheriffs[slot]
		var local := not _menu and (slot == own_slot or (local_mask & (1 << slot)) != 0)
		var victory := _champion == slot and _menu
		visual.root.visible = p.active and (_champion < 0 or victory or not _menu)
		if not visual.root.visible:
			continue
		var target: Vector2 = Vector2(0, 1.4) if victory else p.pos
		var before: Vector2 = visual.pos
		visual.pos = before.lerp(target, ease)
		visual.root.position = _v(visual.pos)
		var pace := minf(before.distance_to(visual.pos), 0.4)
		visual.stride += pace * 6.8
		visual.face = lerp_angle(visual.face, PI * 0.5 if victory else p.face, ease)
		visual.rig.rotation.y = -float(visual.face)
		var pulse := float(int(state.tick) - int(p.clap_tick)) / CLAP_FLASH_TICKS
		var firing := pulse >= 0.0 and pulse < 1.0 and not _menu
		var ready := int(state.tick) - int(p.clap_tick) >= Model.CLAP_COOLDOWN
		visual.cone.visible = firing or (local and not _menu and state.phase != "finished")
		if visual.cone.visible:
			visual.cone.rotation.y = -float(p.clap_face if firing else p.face)
			var material: ShaderMaterial = visual.cone.material_override
			material.set_shader_parameter("pulse", pulse if firing else -1.0)
			material.set_shader_parameter("opacity", 1.0 if firing or ready else 0.28)
		visual.ring.visible = local
		visual.rival_ring.visible = not local
		if local:
			visual.ring.rotation.y = -float(p.face)
		var walking := clampf(pace / maxf(delta * Model.PLAYER_SPEED, 0.02), 0.0, 1.0) if delta > 0.0 else 0.0
		var step := sin(float(visual.stride))
		var nod := sin(_clock * 11.0) * 0.09 if victory else absf(step) * walking * 0.07
		visual.body.position.y = nod
		var clap := (1.0 - pulse) ** 2 if firing else 0.0
		for i in 2:
			var side := float(i * 2 - 1)
			var stride := step * walking * side
			var foot: Node3D = visual.feet[i]
			foot.position.x = stride * 0.16
			foot.position.y = maxf(0.0, stride) * 0.095
			var hand: Node3D = visual.hands[i]
			hand.position = Vector3(0.16 + 0.45 * clap - stride * 0.11, 0.63 + nod + 0.15 * clap,
				side * lerpf(0.40, 0.075, clap))
			hand.rotation.y = side * 0.34 * clap
		if victory:
			visual.label.text = str(p.name).to_upper()
		elif show_identities:
			visual.label.text = "%d  %s" % [slot + 1, p.name]
		else:
			visual.label.text = "YOU" if local and local_mask == 0 else str(slot + 1)
		visual.label.visible = not _menu or victory
		visual.label.modulate.a = 1.0 if local or victory else 0.82

func _render_critters(state: RefCounted, ease: float, fresh: bool) -> void:
	var active := {}
	for crit in state.critters:
		active[crit.id] = crit
	var used := {}
	var empty: Array[Dictionary] = []
	for visual in _animals:
		if fresh or not active.has(visual.id):
			visual.id = -1
			visual.root.hide()
			empty.append(visual)
		else:
			used[visual.id] = visual
	for crit in state.critters:
		var existed := used.has(crit.id)
		var visual: Dictionary = used[crit.id] if existed else empty.pop_back()
		var before: Vector2 = visual.pos if existed else crit.pos
		visual.id = crit.id
		visual.pos = before.lerp(crit.pos, ease)
		visual.root.position = _v(visual.pos)
		visual.root.visible = _champion < 0 or not _menu
		visual.face = lerp_angle(visual.face, crit.face, ease) if existed else crit.face
		visual.rig.rotation.y = -float(visual.face)
		var pace := minf(before.distance_to(visual.pos), 0.32)
		visual.stride += pace * 13.2
		var hop := absf(sin(float(visual.stride)))
		var launch := int(crit.launch_tick) - int(state.tick)
		visual.rig.position.y = hop * (0.21 if launch > 0 else 0.087)
		visual.rig.rotation.z = cos(float(visual.stride)) * 0.075
		var gold: bool = int(crit.value) == 2
		visual.rabbit.body.visible = not gold
		visual.gold.body.visible = gold
		var toy: Dictionary = visual.gold if gold else visual.rabbit
		toy.key.rotation.x = _clock * 5.1 + float(crit.id)
		var fraction := Model.heal_fraction(crit, state.tick)
		visual.ring.visible = fraction < 1.0 or launch > 0
		if visual.ring.visible:
			# Only the synchronized clap recovery clock confirms a hit. A
			# protected launch or an animal merely in the cone can't light up.
			var hit_age := int(state.tick) + Model.CLAP_RECOVERY - int(crit.recover_tick)
			var hit := launch <= 0 and hit_age >= 0 and hit_age < CLAP_FLASH_TICKS
			var flare := 1.0 - float(hit_age) / CLAP_FLASH_TICKS if hit else 0.0
			var material: ShaderMaterial = visual.ring.material_override
			material.set_shader_parameter("segments", 4.0 if hit else 0.0)
			material.set_shader_parameter("radius", 0.70 + 0.16 * flare)
			material.set_shader_parameter("thickness", 0.076 + 0.09 * flare)
			material.set_shader_parameter("tint", CREAM if launch > 0 or hit else ORANGE.lerp(GOLD, fraction))
			material.set_shader_parameter("channel", DARK if launch > 0 or hit else Color("a34127"))
			var fill := 1.0 - float(launch) / Model.LAUNCH_TICKS if launch > 0 else fraction
			material.set_shader_parameter("fill", 1.0 if hit else fill)
		visual.label.visible = gold

func _render_yard(state: RefCounted, fresh: bool) -> void:
	var release := int(state.release_tick) - int(state.tick)
	for i in _hatches.size():
		var visual := _hatches[i]
		var queued: bool = state.next_hatch == i
		var since := int(state.tick) - (int(state.release_tick) - Model.RELEASE_INTERVAL)
		var opening: float = sin(PI * clampf(float(since + 7) / 52.0, 0.0, 1.0)) if state.last_hatch == i else 0.0
		visual.doors[0].position.x = -0.53 * opening
		visual.doors[1].position.x = 0.53 * opening
		visual.label.modulate = GOLD if queued else Color("ffe1ab")
		visual.label.visible = opening < 0.53
		visual.ring.visible = queued or opening > 0.03
		if visual.ring.visible:
			var material: ShaderMaterial = visual.ring.material_override
			material.set_shader_parameter("fill", 1.0 - float(release) / Model.HATCH_WARNING if queued else 1.0)
			material.set_shader_parameter("opacity", 0.85 + 0.15 * sin(_clock * 16.0) if queued else opening)
	for i in _pens.size():
		var visual := _pens[i]
		var p: Dictionary = state.players[i]
		visual.root.visible = p.active
		if not p.active:
			continue
		if p.score != visual.total and not fresh:
			visual.gained = int(p.score) - int(visual.total)
			visual.score_tick = p.last_score
		elif fresh:
			visual.gained = 0
		visual.total = p.score
		var age := float(int(state.tick) - int(visual.score_tick)) / 53.0
		var pop: bool = visual.gained > 0 and age < 1.0
		visual.score.visible = pop and not _menu
		visual.ring.visible = pop
		if pop:
			visual.score.text = "+%d" % int(visual.gained)
			visual.score.position.y = 1.08 + age * 0.78
			visual.score.modulate.a = minf(1.0, (1.0 - age) * 4.2)
			visual.ring.material_override.set_shader_parameter("opacity", (1.0 - age) * 0.93)
			visual.ring.material_override.set_shader_parameter("radius", Model.PEN_RADIUS + 0.08 + age * 0.31)

func _ring(parent: Node3D, radius: float, thickness: float, color: Color, track: bool, height: float) -> MeshInstance3D:
	var material := Art.shader_material(RING_SHADER, {"radius": radius, "thickness": thickness, "tint": color, "track": track})
	return _plane(parent, (radius + thickness + 0.38) * 2.0, height, material)

func _plane(parent: Node3D, size: float, height: float, material: Material) -> MeshInstance3D:
	var plane := QuadMesh.new()
	plane.orientation = PlaneMesh.FACE_Y
	plane.size = Vector2.ONE * size
	return _mesh(parent, plane, material, height)

func _mesh(parent: Node3D, shape: Mesh, material: Material, height: float) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.mesh = shape
	mesh.material_override = material
	mesh.position.y = height
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mesh)
	return mesh

static func _v(at: Vector2, height: float = 0.0) -> Vector3:
	return Vector3(at.x, height, at.y)

static func _outward(at: Vector2) -> Basis:
	return Basis(Vector3.UP, -at.angle())
