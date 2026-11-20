extends Node3D
## The orthographic table and its render-only bank. All coordinates come from the model.

const Model = preload("res://games/plate_panic/model.gd")
const Art = preload("res://scripts/arena_kit.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const R := Model.FIELD_RADIUS
const PR := Model.POCKET_RADIUS
const MR := Model.MARBLE_RADIUS
const BRASS := Color("e6a363")
const LIGHT := Color("fff0b2")
const DARK := Color("091e25")
const DROP := Color("9effed")
const ARROW := Color("ffdf78")
const BANK := 0.052
const WEDGE_FOOTPRINT := [Vector2(1.20, 0), Vector2(-0.73, 0.59), Vector2(-0.73, -0.59)]

const TABLE_SHADER := """
shader_type spatial;
render_mode unshaded, shadows_disabled;
varying vec2 at;
uniform float radius;
uniform bool detail = true;
float line(float x, float w, float aa) {
	return 1.0 - smoothstep(w, w + aa, abs(x));
}
void vertex() { at = VERTEX.xz; }
void fragment() {
	vec2 p = at / radius;
	float r = length(p);
	float a = atan(p.y, p.x);
	float aa = max(fwidth(r), 0.001);
	vec3 blue = mix(vec3(0.188, 0.436, 0.425), vec3(0.061, 0.233, 0.252),
		smoothstep(0.08, 1.04, r));
	blue += 0.035 * sin(p.x * 2.9 - p.y * 2.4);
	float rules = line(r - 0.81, 0.0012, aa) * 0.20 + line(r - 0.976, 0.0012, aa) * 0.70;
	float ticks = smoothstep(0.85, 0.99, cos(a * 72.0)) * step(0.924, r) * step(r, 0.957);
	float seams = line(sin(a * 3.0) * r, 0.0012, aa) * smoothstep(0.2, 0.38, r);
	float center = line(r - 0.219, 0.0013, aa) * 0.40 + line(r - 0.176, 0.0015, aa) * 0.24;
	if (detail) {
		vec2 grid = abs(fract(p * 12.0 + 0.5) - 0.5);
		blue += 0.028 * (1.0 - smoothstep(0.008, 0.033, min(grid.x, grid.y)));
		float grit = fract(sin(dot(floor(at * 37.0), vec2(127.1, 311.7))) * 43758.5453);
		blue += (grit - 0.5) * 0.053 * (1.0 - smoothstep(0.0016, 0.0033, aa));
	}
	ALBEDO = mix(blue, vec3(0.59, 0.77, 0.69), min(0.65, rules + ticks * 0.37 + seams * 0.20 + center));
}
"""

const FLOOR_SHADER := """
shader_type spatial;
render_mode unshaded, shadows_disabled;
varying vec2 at;
uniform float radius;
void vertex() { at = VERTEX.xz; }
void fragment() {
	vec2 p = at / radius;
	float r = length(p);
	vec3 base = mix(vec3(0.128, 0.214, 0.247), vec3(0.027, 0.062, 0.092), smoothstep(0.7, 3.9, r));
	float contact = 1.0 - smoothstep(0.52, 1.53, length(p - vec2(0.10, 0.17)));
	float wash = 1.0 - smoothstep(0.0, 1.9, length(p + vec2(0.83, 0.86)));
	float lines = smoothstep(0.955, 0.986, cos((p.x - p.y * 0.42) * 33.0));
	float bands = smoothstep(1.16, 1.17, r) * (1.0 - smoothstep(1.58, 1.59, r));
	ALBEDO = base * (1.0 - contact * 0.58) + 0.043 * wash + 0.012 * lines * bands;
}
"""

const POCKET_SHADER := """
shader_type spatial;
render_mode unshaded, shadows_disabled;
varying vec2 at;
uniform vec4 tint : source_color;
uniform float flash = 0.0;
uniform float local = 0.0;
void vertex() { at = UV * 2.0 - 1.0; }
void fragment() {
	float r = length(at);
	if (r > 1.0) { discard; }
	float light = clamp(0.61 - at.x * 0.19 - at.y * 0.42, 0.18, 1.0);
	vec3 pit = mix(vec3(0.005, 0.018, 0.029), tint.rgb, 0.07 + 0.16 * r * r + flash * 0.29);
	vec3 lip = tint.rgb * (0.44 + light * 0.52) + vec3(0.12) * flash;
	float aa = max(0.008, fwidth(r));
	vec3 c = mix(pit, lip, smoothstep(0.73, 0.78, r));
	c = mix(c, vec3(0.027, 0.057, 0.073), smoothstep(0.918, 0.934, r));
	float edge = (1.0 - smoothstep(0.013, 0.013 + aa, abs(r - 0.955))) * (local * 0.85 + flash);
	ALBEDO = mix(c, vec3(1.0, 0.96, 0.76), min(1.0, edge));
}
"""

const MARK_SHADER := """
shader_type spatial;
render_mode unshaded, shadows_disabled, cull_disabled, depth_draw_never;
varying vec2 at;
uniform vec4 tint : source_color;
uniform float fill = 1.0;
uniform float opacity = 1.0;
uniform float style = 0.0;
void vertex() { at = UV * 2.0 - 1.0; }
void fragment() {
	float r = length(at);
	float aa = max(fwidth(r), 0.014);
	float a = fract(atan(at.x, -at.y) / 6.283185 + 1.0);
	float ring = 1.0 - smoothstep(0.057, 0.057 + aa, abs(r - 0.85));
	float track = ring * 0.34;
	float live = ring * step(a, fill);
	float mark = 1.0 - smoothstep(0.022, 0.022 + aa, min(abs(at.x), abs(at.y)));
	mark *= smoothstep(0.15, 0.19, r) * (1.0 - smoothstep(0.36, 0.40, r)) * style;
	ALBEDO = mix(tint.rgb * 0.52, tint.rgb, max(live, mark));
	ALPHA = max(max(track, live), mark) * opacity;
}
"""

const MARBLE_SHADER := """
shader_type spatial;
render_mode unshaded, shadows_disabled;
varying vec3 at;
uniform vec4 swirl : source_color;
uniform bool detail = true;
void vertex() { at = NORMAL; }
void fragment() {
	vec3 n = normalize(NORMAL);
	vec3 p = normalize(at);
	float sky = smoothstep(-0.85, 0.93, n.y + n.x * -0.38);
	vec3 c = mix(vec3(0.19, 0.39, 0.44), vec3(0.90, 0.98, 0.91), sky);
	float curl = sin(9.4 * p.y + 4.5 * p.x * p.z + p.z * 3.1);
	float band = (1.0 - smoothstep(0.13, 0.53, abs(curl))) * 0.68;
	if (detail) {
		band += (1.0 - smoothstep(0.075, 0.26, abs(sin(16.0 * p.y + p.x * 3.3)))) * 0.18;
	}
	c = mix(c, swirl.rgb, band * (0.26 + abs(n.z) * 0.61));
	float spec = max(0.0, dot(n, normalize(vec3(-0.48, 0.48, 0.77))));
	c += vec3(1.0, 0.95, 0.69) * (pow(spec, 13.0) * 0.69 + pow(spec, 56.0) * 0.62);
	ALBEDO = c;
}
"""

var camera: Camera3D
var local_mask := 0
var show_identities := false
var client_motion := false

var _menu := true
var _inset := 0.0
var _level := "balanced"
var _table: Node3D
var _surface: ShaderMaterial
var _gauge: Node3D
var _arrow: Node3D
var _arrow_face: MeshInstance3D
var _state: RefCounted
var _round_id := 0
var _clock := 0.0
var _champion := -1
var _players: Array[Dictionary] = []
var _pockets: Array[Dictionary] = []
var _marbles: Dictionary = {}
var _marble_pool: Array[Dictionary] = []
var _drops: Dictionary = {}
var _drop_pool: Array[Dictionary] = []
var _marble_materials: Array[ShaderMaterial] = []
var _ball: SphereMesh
var _trail: QuadMesh
var _trail_material: StandardMaterial3D
var _shadow: QuadMesh
var _shadow_material: StandardMaterial3D
var _detail: Node3D
var _reflections: Node3D

func _ready() -> void:
	Kit.setup()
	_setup_camera()
	_build_table()
	_setup_marbles()
	for slot in Model.SEATS:
		_build_pocket(slot)
		_build_player(slot)
	set_level(_level)
	get_viewport().size_changed.connect(_frame_camera)
	_frame_camera()

func set_menu(on: bool) -> void:
	_menu = on
	show_identities = false
	if not on:
		_champion = -1
	_frame_camera()

func set_inset(inset: float) -> void:
	_inset = clampf(inset, 0.0, 0.75)
	_frame_camera()

func set_level(level: String) -> void:
	_level = level
	if _surface == null:
		return
	_surface.set_shader_parameter("detail", level != "low")
	_ball.radial_segments = 12 if level == "low" else (24 if level == "balanced" else 36)
	_ball.rings = 6 if level == "low" else (12 if level == "balanced" else 18)
	for material in _marble_materials:
		material.set_shader_parameter("detail", level != "low")
	_detail.visible = level != "low"
	_reflections.visible = level == "high"

func celebrate(slot: int) -> void:
	_champion = slot

func _setup_camera() -> void:
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.near = 0.2
	camera.far = R * 16.0
	add_child(camera)
	camera.position = Vector3(0, 3.65, 1.98) * R
	camera.look_at(Vector3.ZERO)
	var sky := Environment.new()
	sky.background_mode = Environment.BG_COLOR
	sky.background_color = Color("0b1926")
	sky.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	sky.ambient_light_color = Color("d7f0ed")
	sky.ambient_light_energy = 0.72
	camera.environment = sky
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-51, -28, 0)
	sun.light_color = Color("ffead3")
	sun.light_energy = 1.10
	add_child(sun)

func _frame_camera() -> void:
	if camera == null:
		return
	var view := get_viewport().get_visible_rect().size
	var aspect := view.x / maxf(view.y, 1.0)
	var inset := _inset if _menu else 0.0
	camera.size = maxf(2.69 if _menu else 2.62, 2.20 / maxf((1.0 - inset) * aspect, 0.20)) * R
	camera.h_offset = -inset * camera.size * aspect * 0.5
	camera.v_offset = -0.036 * R

func _build_table() -> void:
	var floor_material := Art.shader_material(FLOOR_SHADER, {"radius": R})
	_mesh(self, _quad(R * 29.0), floor_material, Vector3(0, -R * 0.28, 0))
	var metal := _metal(BRASS, 0.47, 0.33)
	var dark := _metal(Color("243d49"), 0.34, 0.44)
	var deep := _metal(Color("132936"), 0.24, 0.43)
	_disk(self, R * 0.83, R * 0.83, R * 0.072, -R * 0.24, deep)
	_disk(self, R * 0.79, R * 0.89, R * 0.073, -R * 0.181, dark)
	_disk(self, R * 0.57, R * 0.70, R * 0.084, -R * 0.108, metal)
	_table = Node3D.new()
	_table.name = "TiltingTable"
	add_child(_table)
	_disk(_table, R * 1.019, R * 0.976, R * 0.109, -R * 0.096, deep)
	_disk(_table, R * 1.035, R * 1.020, R * 0.064, -R * 0.059, dark)
	_disk(_table, R * 1.029, R * 1.035, R * 0.017, -R * 0.035, metal)
	_disk(_table, R * 1.018, R * 1.029, R * 0.046, -R * 0.021, dark)
	_surface = Art.shader_material(TABLE_SHADER, {"radius": R})
	_disk(_table, R, R, 0.025, -0.0125, _surface)
	_rim(R * 1.007, R * 1.024, R * 0.005, metal)
	_rim(R * 0.984, R * 0.987, 0.012, _flat(Color("a1aa83")))

	_detail = Node3D.new()
	_table.add_child(_detail)
	_reflections = Node3D.new()
	_table.add_child(_reflections)
	var fastener := CylinderMesh.new()
	fastener.top_radius = R * 0.0105
	fastener.bottom_radius = R * 0.012
	fastener.height = 0.029
	fastener.radial_segments = 10
	var slot_mesh := BoxMesh.new()
	slot_mesh.size = Vector3(R * 0.013, 0.005, R * 0.003)
	for i in 24:
		var angle := TAU * (i + 0.5) / 24.0
		var bolt := _v(Vector2.from_angle(angle) * R * 1.013, R * 0.006)
		_mesh(_detail, fastener, metal, bolt)
		_mesh(_detail, slot_mesh, deep, bolt + Vector3.UP * 0.016).rotation.y = angle
	_rim(R * 1.025, R * 1.027, R * 0.007, _flat(Color("ffe3b6")), _reflections)
	_build_gauge()

func _build_gauge() -> void:
	_gauge = Node3D.new()
	_gauge.position.y = 0.036
	_table.add_child(_gauge)
	var circle := _marker(_gauge, R * 0.232, Color("8ab8ad"), 0.0)
	circle.material_override.set_shader_parameter("opacity", 0.62)
	var hub := _disk(_gauge, R * 0.039, R * 0.039, 0.016, 0.0, _flat(Color("6d9c90")))
	hub.name = "LevelHub"
	_arrow = Node3D.new()
	_arrow.position.y = 0.030
	_gauge.add_child(_arrow)
	var arrow_points := PackedVector2Array([
		Vector2(-0.165, -0.043), Vector2(0.075, -0.043), Vector2(0.075, -0.091),
		Vector2(0.224, 0.0), Vector2(0.075, 0.091), Vector2(0.075, 0.043), Vector2(-0.165, 0.043),
	])
	var outline := PackedVector2Array()
	for at in arrow_points:
		outline.append(at * 1.13)
	_mesh(_arrow, _flat_shape(outline, R), _flat(DARK), Vector3.ZERO)
	_arrow_face = _mesh(_arrow, _flat_shape(arrow_points, R), _flat(ARROW), Vector3.UP * 0.011)
	var glint := PackedVector2Array([Vector2(-0.149, -0.036), Vector2(0.084, -0.036),
		Vector2(0.084, -0.067), Vector2(0.177, -0.011), Vector2(-0.149, -0.019)])
	_mesh(_arrow, _flat_shape(glint, R), _flat(LIGHT), Vector3.UP * 0.019)

func _build_pocket(slot: int) -> void:
	var paint: Color = Kit.colors[slot]
	var root := Node3D.new()
	root.position = _v(Model.pocket(slot), 0.024)
	_table.add_child(root)
	var cup := Art.shader_material(POCKET_SHADER, {"tint": paint})
	_mesh(root, _quad(PR * 2.0), cup, Vector3.ZERO)
	var number := _label(root, str(slot + 1), 58, PR / 63.0, paint.lightened(0.33))
	number.position.y = 0.095
	var pulse := _marker(root, PR * 1.16, paint, 0.041)
	pulse.hide()
	var points := _label(root, "+1", 60, PR / 58.0, LIGHT)
	points.hide()
	_pockets.append({"root": root, "cup": cup, "number": number, "pulse": pulse, "points": points})

func _build_player(slot: int) -> void:
	var paint: Color = Kit.colors[slot]
	var root := Node3D.new()
	_table.add_child(root)
	var radius := R * 0.047
	var height := R * 0.028
	_mesh(root, _shadow, _shadow_material, Vector3(0.05, 0.018, 0.08)).scale *= radius * 1.7
	_disk(root, radius * 0.99, radius * 0.90, height, height * 0.51, _metal(paint.darkened(0.55), 0.25, 0.41))
	_disk(root, radius * 0.83, radius * 0.99, height * 0.56, height * 1.18, _metal(paint, 0.23, 0.29))
	_disk(root, radius * 0.74, radius * 0.83, height * 0.30, height * 1.55, _flat(paint.lightened(0.12)))
	var label := _label(root, str(slot + 1), 54, radius / 36.0, DARK)
	label.position.y = height * 1.63 + 0.045
	label.outline_size = 0
	var aim := Node3D.new()
	aim.position.y = 0.052
	root.add_child(aim)
	var chevron := PackedVector2Array([Vector2(1.12, -0.35), Vector2(1.69, 0.0), Vector2(1.12, 0.35),
		Vector2(1.27, 0.0)])
	_mesh(aim, _flat_shape(chevron, radius * 1.13), _flat(DARK), Vector3.ZERO)
	_mesh(aim, _flat_shape(chevron, radius), _flat(paint.lightened(0.52)), Vector3.UP * 0.012)
	var ring := _marker(root, radius * 1.58, paint.lightened(0.32), 0.028)
	var names := _label(root, "", 38, radius / 25.0, Kit.INK)
	names.position.y = height + radius * 1.35
	names.outline_size = 12
	names.hide()

	var preview := _build_wedge_preview(paint)
	var wedge := Node3D.new()
	_table.add_child(wedge)
	wedge.hide()
	_build_wedge(wedge, paint)
	var charge := _marker(wedge, R * 0.108, paint.lightened(0.40), 0.032)
	var spark := _marker(wedge, R * 0.118, LIGHT, 0.049)
	spark.hide()
	_players.append({"root": root, "aim": aim, "pos": Vector2.ZERO, "face": 0.0, "names": names, "preview": preview,
		"ring": ring, "wedge": wedge, "charge": charge, "spark": spark, "deflections": 0, "spark_tick": -100})

func _build_wedge_preview(paint: Color) -> Dictionary:
	var root := Node3D.new()
	_table.add_child(root)
	root.hide()
	var footprint := PackedVector2Array(WEDGE_FOOTPRINT)
	var rim := _mesh(root, _flat_shape(footprint, R * 0.077), _flat(DARK), Vector3.ZERO)
	var open := _mesh(root, _flat_shape(footprint, R * 0.064), _flat(paint.lightened(0.48)), Vector3.UP * 0.004)
	var blocked := SurfaceTool.new()
	blocked.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 24:
		var a := Vector2.from_angle(i * TAU / 24.0)
		var b := Vector2.from_angle((i + 1) * TAU / 24.0)
		blocked.add_triangle_fan(PackedVector3Array([_v(a * 0.47), _v(a * 0.62), _v(b * 0.62), _v(b * 0.47)]))
	var slash := Vector2(0.36, 0.36)
	var width := Vector2(0.052, -0.052)
	blocked.add_triangle_fan(PackedVector3Array([_v(-slash + width), _v(slash + width), _v(slash - width), _v(-slash - width)]))
	return {"root": root, "rim": rim, "open": open, "blocked": _mesh(root, blocked.commit(), _flat(LIGHT), Vector3.ZERO)}

func _build_wedge(root: Node3D, paint: Color) -> void:
	var size := R * 0.067
	var head: Vector2 = WEDGE_FOOTPRINT[0]
	var tail: Vector2 = WEDGE_FOOTPRINT[1]
	var tail_other: Vector2 = WEDGE_FOOTPRINT[2]
	var ridge := R * 0.053
	var rim := R * 0.020
	var a := _v(head * size, rim)
	var b := _v(tail * size, rim)
	var c := _v(tail_other * size, rim)
	var peak := Vector3(-0.53 * size, ridge, 0)
	var body := SurfaceTool.new()
	body.begin(Mesh.PRIMITIVE_TRIANGLES)
	body.add_triangle_fan(PackedVector3Array([a, b, peak]))
	body.add_triangle_fan(PackedVector3Array([a, peak, c]))
	body.add_triangle_fan(PackedVector3Array([c, peak, b]))
	body.generate_normals()
	_mesh(root, body.commit(), _metal(paint, 0.29, 0.32), Vector3.ZERO)
	_mesh(root, _flat_shape(PackedVector2Array([head, tail, tail_other]), size * 1.10),
		_flat(DARK), Vector3.UP * 0.025)
	var arrow := PackedVector2Array([Vector2(-0.35, -0.27), Vector2(0.15, -0.27),
		Vector2(0.15, -0.45), Vector2(0.80, 0), Vector2(0.15, 0.45), Vector2(0.15, 0.27), Vector2(-0.35, 0.27)])
	_mesh(root, _flat_shape(arrow, size), _flat(paint.lightened(0.62)), Vector3.UP * (ridge + 0.018))

func _setup_marbles() -> void:
	_ball = SphereMesh.new()
	_ball.radius = MR
	_ball.height = MR * 2.0
	_shadow = _quad(2.0)
	_shadow_material = _gradient_material(Color(0.005, 0.024, 0.033, 0.69))
	_trail = _quad(1.0)
	_trail_material = _gradient_material(Color(0.78, 0.97, 0.86, 0.47))
	for paint in [Color("2e8da4"), Color("507ba8"), Color("ad7e54")]:
		_marble_materials.append(Art.shader_material(MARBLE_SHADER, {"swirl": paint}))

func _new_marble() -> Dictionary:
	var root := Node3D.new()
	_table.add_child(root)
	_mesh(root, _shadow, _shadow_material, Vector3(0.10, 0.016, 0.14)).scale *= MR * 1.52
	var trail := _mesh(root, _trail, _trail_material, Vector3.UP * 0.022)
	var marble := _mesh(root, _ball, _marble_materials[0], Vector3.UP * MR)
	var ripple := _marker(root, MR * 3.1, DROP, 0.039)
	return {"root": root, "marble": marble, "trail": trail, "ripple": ripple, "pos": Vector2.ZERO,
		"spin": Basis.IDENTITY, "born": 0}

func update_visuals(state: RefCounted, delta: float, own_slot: int = -1) -> void:
	if state == null:
		return
	var fresh: bool = _state != state or _round_id != state.round_id
	_state = state
	_round_id = state.round_id
	_clock += delta
	var ease := 1.0 if fresh or not client_motion else 1.0 - exp(-27.0 * delta)
	var slope: Vector2 = state.tilt
	_table.rotation = Vector3(slope.y * BANK, 0.0, -slope.x * BANK)
	_arrow.visible = slope.length_squared() > 0.0004
	if _arrow.visible:
		_arrow.rotation.y = -slope.angle()
		var reach := lerpf(0.75, 1.16, slope.length())
		_arrow.scale = Vector3(reach, 1.0, lerpf(0.78, 1.0, slope.length()))
		_arrow_face.material_override.albedo_color = ARROW.lerp(LIGHT, slope.length() * 0.55)
	_render_players(state, ease, fresh, own_slot)
	_render_drops(state, fresh)
	_render_marbles(state, ease, fresh)

func _render_players(state: RefCounted, ease: float, fresh: bool, own_slot: int) -> void:
	var local_seats := local_mask if local_mask > 0 else (1 << own_slot if own_slot >= 0 else 0)
	for i in Model.SEATS:
		var player: Dictionary = state.players[i]
		var visual := _players[i]
		var pocket := _pockets[i]
		visual.root.visible = player.active
		pocket.root.visible = player.active
		if not player.active:
			visual.wedge.hide()
			visual.preview.root.hide()
			continue
		var local := (local_seats & (1 << i)) != 0 and not _menu
		var age := int(state.tick) - int(player.wedge_tick)
		var scored := float(state.tick - int(player.last_score)) / 46.0
		var score_flash: float = (1.0 - scored) ** 2 if int(player.score) > 0 and scored >= 0.0 and scored < 1.0 else 0.0
		if _menu and i == _champion:
			score_flash = 0.62 + sin(_clock * 4.1) * 0.27
		visual.pos = player.pos if fresh else (visual.pos as Vector2).lerp(player.pos, ease)
		visual.face = lerp_angle(visual.face, player.face, ease)
		visual.root.position = _v(visual.pos)
		visual.aim.rotation.y = -float(visual.face)
		var preview: Dictionary = visual.preview
		var ready: bool = local and state.phase == "running" and age >= Model.WEDGE_COOLDOWN
		preview.root.visible = ready
		visual.aim.visible = not ready
		if ready:
			var site: Vector2 = player.pos + Vector2.from_angle(player.face) * Model.WEDGE_OFFSET
			var open: bool = state.wedge_site_open(site)
			if site.length_squared() > R * R:
				# Keep an off-table rejection visible beside the lip and away from the tag.
				var outward := site.normalized()
				site = outward * (R - 0.55) + outward.orthogonal() * 1.10
			preview.root.position = _v(site, 0.025)
			preview.root.rotation.y = -float(player.face) if open else 0.0
			preview.rim.visible = open
			preview.open.visible = open
			preview.blocked.visible = not open
		visual.ring.visible = local
		visual.ring.material_override.set_shader_parameter("fill", clampf(float(age) / Model.WEDGE_COOLDOWN, 0.0, 1.0))
		visual.names.visible = not _menu and (local or show_identities)
		if visual.names.visible:
			var physical_pos: Vector2 = visual.pos
			var toward_center := -physical_pos.normalized()
			var inset := smoothstep(R * 0.70, R * 0.94, physical_pos.length()) if local else 0.0
			var offset := (toward_center + toward_center.orthogonal() * 1.49) * inset
			visual.names.position.x = offset.x
			visual.names.position.z = offset.y
			if show_identities:
				visual.names.text = str(player.name).to_upper()
			else:
				visual.names.text = "P%d" % (i + 1) if local_mask > 0 else "YOU %d" % (i + 1)

		pocket.cup.set_shader_parameter("flash", score_flash)
		pocket.cup.set_shader_parameter("local", 1.0 if local else 0.0)
		pocket.pulse.visible = score_flash > 0.0
		pocket.points.visible = score_flash > 0.0 and not _menu
		if pocket.pulse.visible:
			pocket.pulse.scale = Vector3.ONE * (1.0 + (1.0 - score_flash) * 0.38)
			pocket.pulse.material_override.set_shader_parameter("opacity", score_flash)
		if pocket.points.visible:
			pocket.points.position.y = PR * (0.96 + scored * 0.72)
			pocket.points.modulate.a = minf(1.0, (1.0 - scored) * 2.5)

		visual.wedge.visible = age >= 0 and age < Model.WEDGE_LIFE
		if fresh:
			visual.spark_tick = -100
		elif player.deflections > visual.deflections:
			visual.spark_tick = state.tick
		visual.deflections = player.deflections
		if visual.wedge.visible:
			visual.wedge.position = _v(player.wedge_pos)
			visual.wedge.rotation.y = -float(player.wedge_face)
			visual.charge.material_override.set_shader_parameter("fill", 1.0 - float(age) / Model.WEDGE_LIFE)
			var spark := 1.0 - float(state.tick - visual.spark_tick) / 22.0
			visual.spark.visible = spark > 0.0
			if visual.spark.visible:
				visual.spark.scale = Vector3.ONE * lerpf(1.9, 0.8, spark)
				visual.spark.position.x = (1.0 - spark) * R * 0.12
				visual.spark.material_override.set_shader_parameter("opacity", spark)

func _render_drops(state: RefCounted, fresh: bool) -> void:
	for id in _drops.keys():
		if fresh or not state.drops.any(func(d): return d.id == id):
			var old: Dictionary = _drops[id]
			old.root.hide()
			_drop_pool.append(old)
			_drops.erase(id)
	for drop in state.drops:
		var left := maxi(0, int(drop.tick) - int(state.tick))
		if not _drops.has(drop.id):
			var visual: Dictionary
			if _drop_pool.is_empty():
				var marker := _marker(_table, MR * 3.5, DROP, 0.043, 1.0)
				visual = {"root": marker, "lead": 1}
			else:
				visual = _drop_pool.pop_back()
			visual.lead = maxi(1, left)
			_drops[drop.id] = visual
		var entry: Dictionary = _drops[drop.id]
		var progress := 1.0 - clampf(float(left) / float(entry.lead), 0.0, 1.0)
		entry.root.show()
		entry.root.position = _v(drop.pos, 0.043)
		entry.root.scale = Vector3.ONE * lerpf(1.28, 0.93, progress)
		entry.root.material_override.set_shader_parameter("fill", maxf(0.11, progress))
		entry.root.material_override.set_shader_parameter("opacity", 0.83 + 0.17 * sin(_clock * lerpf(8.0, 15.0, progress)))

func _render_marbles(state: RefCounted, ease: float, fresh: bool) -> void:
	for id in _marbles.keys():
		if fresh or not state.marbles.any(func(m): return m.id == id):
			var old: Dictionary = _marbles[id]
			old.root.hide()
			_marble_pool.append(old)
			_marbles.erase(id)
	for marble in state.marbles:
		if not _marbles.has(marble.id):
			var visual: Dictionary = _new_marble() if _marble_pool.is_empty() else _marble_pool.pop_back()
			visual.pos = marble.pos
			visual.spin = Basis.IDENTITY
			visual.born = int(state.tick) if not fresh else -100
			visual.marble.material_override = _marble_materials[posmod(int(marble.id), _marble_materials.size())]
			_marbles[marble.id] = visual
		var entry: Dictionary = _marbles[marble.id]
		var before: Vector2 = entry.pos
		var position_now: Vector2 = before.lerp(marble.pos, ease)
		var motion := position_now - before
		var velocity: Vector2 = marble.velocity
		entry.pos = position_now
		entry.root.position = _v(position_now)
		entry.root.show()
		if motion.length_squared() > 0.000001:
			var axis := Vector3(motion.y, 0.0, -motion.x).normalized()
			entry.spin = (Basis(axis, motion.length() / MR) * (entry.spin as Basis)).orthonormalized()
			entry.marble.basis = entry.spin
		var land := clampf(float(int(state.tick) - int(entry.born)) / 24.0, 0.0, 1.0)
		entry.marble.position.y = MR + R * 0.075 * (1.0 - land) ** 3
		entry.ripple.visible = land < 1.0
		if entry.ripple.visible:
			entry.ripple.scale = Vector3.ONE * lerpf(0.54, 1.37, land)
			entry.ripple.material_override.set_shader_parameter("opacity", 1.0 - land)
		var speed := velocity.length()
		entry.trail.visible = speed > 0.13 * R
		if entry.trail.visible:
			var span := minf(MR * 5.1, MR + speed * 0.14)
			entry.trail.position = _v(-velocity.normalized() * span * 0.58, 0.022)
			entry.trail.rotation.y = -velocity.angle()
			entry.trail.scale = Vector3(span, 1.0, MR * (0.92 if _level == "high" else 0.68))

func _marker(parent: Node3D, radius: float, color: Color, height: float, style: float = 0.0) -> MeshInstance3D:
	var material := Art.shader_material(MARK_SHADER, {"tint": color, "style": style})
	return _mesh(parent, _quad(radius * 2.0), material, Vector3.UP * height)

func _rim(inner: float, outer: float, y: float, material: Material, parent: Node3D = null) -> void:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 96:
		var a := Vector2.from_angle(TAU * i / 96.0)
		var b := Vector2.from_angle(TAU * (i + 1) / 96.0)
		tool.add_triangle_fan(PackedVector3Array([_v(a * inner), _v(a * outer), _v(b * outer), _v(b * inner)]))
	tool.generate_normals()
	_mesh(_table if parent == null else parent, tool.commit(), material, Vector3.UP * y)

func _disk(parent: Node3D, top: float, bottom: float, height: float, y: float, material: Material) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top
	mesh.bottom_radius = bottom
	mesh.height = height
	mesh.radial_segments = 96 if top > 2.0 else 24
	mesh.rings = 0
	return _mesh(parent, mesh, material, Vector3.UP * y)

func _mesh(parent: Node3D, mesh: Mesh, material: Material, at: Vector3) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.position = at
	parent.add_child(instance)
	return instance

func _label(parent: Node3D, caption: String, font_size: int, pixel_size: float, tint: Color) -> Label3D:
	var label := Label3D.new()
	label.text = caption
	label.font = Kit.heavy
	label.font_size = font_size
	label.pixel_size = pixel_size
	label.modulate = tint
	label.outline_size = 8
	label.outline_modulate = DARK
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	parent.add_child(label)
	return label

static func _quad(size: float) -> QuadMesh:
	var mesh := QuadMesh.new()
	mesh.orientation = PlaneMesh.FACE_Y
	mesh.size = Vector2.ONE * size
	return mesh

static func _flat(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

static func _metal(color: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = roughness
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

static func _gradient_material(tint: Color) -> StandardMaterial3D:
	var gradient := Gradient.new()
	gradient.colors = PackedColorArray([tint, Color(tint, 0.0)])
	var texture := GradientTexture2D.new()
	texture.width = 32
	texture.height = 32
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	var material := _flat(Color.WHITE)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_texture = texture
	return material

static func _flat_shape(points: PackedVector2Array, size: float) -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in Geometry2D.triangulate_polygon(points):
		tool.add_vertex(_v(points[index] * size))
	return tool.commit()

static func _v(point: Vector2, height: float = 0.0) -> Vector3:
	return Vector3(point.x, height, point.y)
