extends Node3D
## The dock mirrors the host's radii. Falls and splashes have local animation
## clocks so they keep moving between snapshots and under the finish call-out.

const Model = preload("res://games/bumper_cars/model.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const CAR_PATH := "res://games/bumper_cars/assets/bumper_car.glb"
## The GLB's hood points along +X. The simulation drives along -Z at heading 0.
const CAR_FRONT_FIX := PI / 2.0
const CAR_DIAMETER := Model.BODY_RADIUS * 2.0
const WATER_Y := -1.55
const WATER_HIT := 0.47
const RING_SINK := 1.45
const SEGMENTS := 96
const MINT := Color("79d8bc")
const CREAM := Color("f2d9a7")
const ORANGE := Color("ff9c58")
const DOCK := [Color("1b3d49"), Color("254954"), Color("1e424f"), Color("254a55"), Color("20404c"), Color("2a5058")]

var camera: Camera3D
var local_mask := 0
var show_identities := false
var client_motion := false
var menu_mode := true
var level := "balanced"

var _inset := 0.0
var _clock := 0.0
var _radius: float = Model.RADII[0]
var _camera_radius := _radius
var _round: RefCounted
var _round_id := -1
var _last_elapsed := -1.0
var _champion := -1
var _rings: Array[Dictionary] = []
var _cars: Array[Dictionary] = []
var _buoys: Array[Node3D] = []
var _water: ShaderMaterial

func _ready() -> void:
	Kit.setup()
	_build_camera()
	_build_water()
	_build_dock()
	_build_buoys()
	_build_cars()
	_frame_camera()
	camera.make_current()

func set_menu(on: bool) -> void:
	menu_mode = on
	show_identities = false
	_frame_camera()

func set_inset(value: float) -> void:
	_inset = clampf(value, 0.0, 0.8)
	_frame_camera()

func set_level(value: String) -> void:
	level = value
	if _water:
		_water.set_shader_parameter("detail", level != "low")

func celebrate(slot: int) -> void:
	_champion = slot

func _build_camera() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("14283b")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("c6e0e3")
	environment.ambient_light_energy = 0.69
	camera = Camera3D.new()
	camera.environment = environment
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.near = 0.5
	camera.far = 95.0
	add_child(camera)
	camera.position = Vector3(0.0, 30.0, 27.5)
	camera.look_at(Vector3.ZERO)
	var sun := DirectionalLight3D.new()
	sun.light_color = Color("ffd9b2")
	sun.light_energy = 1.2
	sun.rotation_degrees = Vector3(-42.0, -38.0, 0.0)
	add_child(sun)

func _frame_camera() -> void:
	if camera == null or not is_inside_tree():
		return
	var screen := get_viewport().get_visible_rect().size
	var aspect := screen.x / maxf(screen.y, 1.0)
	if menu_mode:
		var menu_radius := maxf(_camera_radius, 9.5)
		camera.size = maxf(29.0, (menu_radius + 1.35) * 2.0 / maxf((1.0 - _inset) * aspect, 0.1))
		camera.h_offset = -_inset * camera.size * aspect * 0.5
		return
	var padded := _camera_radius + 2.15
	var room := clampf((screen.y - 250.0) / maxf(screen.y, 1.0), 0.58, 0.8)
	camera.size = maxf(padded * 2.0 / maxf(aspect * 0.94, 0.1), padded * 1.51 / room)
	camera.h_offset = 0.0

func _build_water() -> void:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, cull_disabled;
uniform float clock = 0.0;
uniform float deck_radius = 14.0;
uniform bool detail = true;
varying vec2 water_pos;

void vertex() {
	water_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	vec2 p = water_pos;
	float tide = sin(p.y * 1.6 + sin(p.x * 0.55 - clock * 0.41) * 1.3 + clock * 1.1);
	float chop = sin(p.y * 2.3 - p.x * 0.85 + clock * 0.8);
	float light = smoothstep(0.45, 1.0, tide * 0.7 + chop * 0.3);
	vec3 ink = mix(vec3(0.039, 0.145, 0.210), vec3(0.084, 0.295, 0.323),
		clamp(0.57 - p.y * 0.022, 0.0, 1.0));
	ink += vec3(0.055, 0.103, 0.109) * light;
	if (detail) {
		float flare = exp(-abs(p.x + p.y * 0.39 + 9.0) * 0.24);
		flare *= smoothstep(2.0, 22.0, -p.y) * smoothstep(0.54, 0.95, tide);
		ink += vec3(0.34, 0.18, 0.079) * flare;
		ink += vec3(0.028, 0.063, 0.054) * smoothstep(0.67, 1.0,
			sin(p.y * 4.8 + sin(p.x * 0.73) * 1.7 - clock * 0.66));
	}
	float dock = 1.0 - smoothstep(deck_radius + 0.10, deck_radius + 2.0, length(p - vec2(0.45, 0.68)));
	ALBEDO = ink * (1.0 - 0.42 * dock);
}
"""
	_water = ShaderMaterial.new()
	_water.shader = shader
	_water.set_shader_parameter("detail", level != "low")
	var plane := PlaneMesh.new()
	plane.size = Vector2(190.0, 190.0)
	_mesh(self, plane, Vector3(0.0, WATER_Y, 0.0), _water)

func _build_dock() -> void:
	var painted := _paint(Color.WHITE)
	painted.vertex_color_use_as_albedo = true
	for i in Model.RADII.size():
		var edge: float = Model.RADII[i]
		var inner: float = Model.RADII[i + 1] if i < Model.DROP_TIMES.size() else 0.0
		var panel := Node3D.new()
		panel.name = "DeckRing%d" % i
		add_child(panel)
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		var paint := ORANGE if i == 0 else MINT.lerp(CREAM, float(i) * 0.14)
		for n in SEGMENTS:
			var a := n * TAU / SEGMENTS
			var b := (n + 1) * TAU / SEGMENTS
			@warning_ignore("integer_division")
			var shaded := (n / 8) % 2 != 0
			var floor: Color = DOCK[i].darkened(0.07) if shaded else DOCK[i]
			if inner > 0.0:
				_strip(surface, inner, inner + 0.055, 0.0, a, b, Color("152b37"))
			_strip(surface, inner + (0.055 if inner > 0.0 else 0.0), edge - 0.36, 0.0, a, b, floor)
			_strip(surface, edge - 0.36, edge - 0.29, 0.0, a, b, Color("132e39"))
			_strip(surface, edge - 0.29, edge - 0.12, 0.0, a, b, paint if n % 8 < 6 else paint.darkened(0.38))
			_strip(surface, edge - 0.12, edge, 0.0, a, b, Color("162c37"))
			_wall(surface, edge, a, b, 0.0, -0.27, paint.darkened(0.44))
			_wall(surface, edge, a, b, -0.27, -0.60, Color("132b39") if n % 8 < 7 else paint.darkened(0.62))
			if inner > 0.0 and n % 8 == 0:
				_strip(surface, inner + 0.25, edge - 0.61, 0.012, a, a + 0.018, paint.darkened(0.48))
		_mesh(panel, surface.commit(), Vector3.ZERO, painted)
		var info := {"root": panel, "sink": 0.0}
		if i < Model.DROP_TIMES.size():
			var alert := _paint(Color(1.0, 0.54, 0.21, 0.0), true)
			var flash := _mesh(panel, _annulus(inner + 0.07, edge - 0.03), Vector3(0, 0.026, 0), alert)
			flash.visible = false
			var wash := _paint(Color(0.65, 1.0, 0.88, 0.0), true)
			var wake := _mesh(self, _annulus(edge - 0.10, edge + 0.12), Vector3(0, WATER_Y + 0.014, 0), wash)
			wake.visible = false
			info.merge({"flash": flash, "alert": alert, "wake": wake, "wash": wash})
		_rings.append(info)
	var centre := _floor_text(_rings.back().root, "BUMPER\nCARS", 0.024, CREAM)
	centre.position.z = 0.23
	var beacon := _mesh(_rings.back().root, _annulus(0.93, 1.19), Vector3(0, 0.028, -1.0), _paint(ORANGE, true))
	beacon.scale = Vector3(1.25, 1.0, 0.25)

func _build_buoys() -> void:
	var body := CylinderMesh.new()
	body.top_radius = 0.37
	body.bottom_radius = 0.53
	body.height = 0.63
	body.radial_segments = 12
	var cap := SphereMesh.new()
	cap.radius = 0.22
	cap.height = 0.44
	cap.radial_segments = 12
	cap.rings = 5
	var float_mat := _paint(Color("2f666d"))
	var bead := _paint(ORANGE, true)
	var disc := _annulus(0.51, 0.77, 24)
	var foam := _paint(Color(0.59, 0.92, 0.86, 0.51), true)
	for i in 9:
		var angle := 0.18 + i * TAU / 9.0
		var outer := Vector2.from_angle(angle) * (16.1 + 0.85 * float(i % 3))
		var buoy := Node3D.new()
		add_child(buoy)
		buoy.position = Vector3(outer.x, WATER_Y, outer.y)
		_mesh(buoy, body, Vector3(0, 0.18, 0), float_mat)
		_mesh(buoy, cap, Vector3(0, 0.66, 0), bead)
		_mesh(self, disc, Vector3(outer.x, WATER_Y + 0.015, outer.y), foam)
		_buoys.append(buoy)

func _build_cars() -> void:
	var car_scene: PackedScene
	if ResourceLoader.exists(CAR_PATH):
		car_scene = load(CAR_PATH) as PackedScene
	var disc := _annulus(0.73, 0.99, 40)
	var shadow := _annulus(0.0, 1.02, 40)
	var spray := _annulus(0.75, 1.0, 40)
	var wake := _annulus(1.1, 1.24, 40)
	var shadow_mat := _paint(Color(0.02, 0.07, 0.09, 0.52), true)
	var trail_mesh := BoxMesh.new()
	trail_mesh.size = Vector3(0.13, 0.11, 1.4)
	var droplet := SphereMesh.new()
	droplet.radius = 0.10
	droplet.height = 0.29
	droplet.radial_segments = 6
	droplet.rings = 3
	for i in Model.SEATS:
		var tint: Color = Kit.colors[i]
		var car := Node3D.new()
		car.name = "BumperCar%d" % (i + 1)
		add_child(car)
		var body := Node3D.new()
		car.add_child(body)
		if not _place_model(body, car_scene, tint):
			_build_fallback_car(body, tint)
		var marker := _mesh(self, disc, Vector3.ZERO, _paint(tint, true))
		var car_shadow := _mesh(self, shadow, Vector3.ZERO, shadow_mat)
		var trail := Node3D.new()
		car.add_child(trail)
		var tail := _paint(tint.lerp(Color.WHITE, 0.44), true)
		for x in [-0.51, 0.51]:
			_mesh(trail, trail_mesh, Vector3(x, 0.10, 1.25), tail)
		var number := _tag(str(i + 1), tint, 0.013)
		var tag := _tag("", tint, 0.015)
		var splash_mat := _paint(Color(0.76, 1.0, 0.93, 0.0), true)
		var splash := Node3D.new()
		add_child(splash)
		_mesh(splash, spray, Vector3.ZERO, splash_mat)
		_mesh(splash, wake, Vector3(0, 0.008, 0), splash_mat)
		var foam := MultiMesh.new()
		foam.transform_format = MultiMesh.TRANSFORM_3D
		foam.mesh = droplet
		foam.instance_count = 9
		var drops := MultiMeshInstance3D.new()
		drops.multimesh = foam
		drops.material_override = splash_mat
		drops.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		splash.add_child(drops)
		_cars.append({"car": car, "body": body, "marker": marker, "shadow": car_shadow,
			"tag": tag, "number": number, "trail": trail, "splash": splash, "water": splash_mat,
			"drops": drops, "visual_fall": 0.0, "water_at": Vector2.ZERO})

func _place_model(body: Node3D, car_scene: PackedScene, tint: Color) -> bool:
	if car_scene == null:
		return false
	var asset := car_scene.instantiate() as Node3D
	if asset == null:
		return false
	# Rotate first so the ground plane and scale are measured in gameplay axes.
	var pivot := Node3D.new()
	body.add_child(pivot)
	pivot.add_child(asset)
	asset.rotation.y += CAR_FRONT_FIX
	var inverse := pivot.global_transform.affine_inverse()
	var bounds := AABB()
	for mesh in asset.find_children("*", "MeshInstance3D", true, false):
		var instance: MeshInstance3D = mesh
		if instance.mesh == null:
			continue
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		for surface in instance.mesh.get_surface_count():
			var original := instance.get_active_material(surface) as StandardMaterial3D
			if original != null:
				var painted: StandardMaterial3D = original.duplicate()
				painted.albedo_color *= tint.lerp(Color.WHITE, 0.40)
				instance.set_surface_override_material(surface, painted)
		var box: AABB = inverse * instance.global_transform * instance.get_aabb()
		bounds = bounds.merge(box) if bounds.has_volume() else box
	if not bounds.has_volume():
		pivot.free()
		return false
	var factor := CAR_DIAMETER / maxf(bounds.size.x, bounds.size.z)
	var centre := bounds.get_center()
	pivot.scale = Vector3.ONE * factor
	pivot.position = Vector3(-centre.x, -bounds.position.y + 0.025 / factor, -centre.z) * factor
	return true

func _build_fallback_car(body: Node3D, tint: Color) -> void:
	var base := CylinderMesh.new()
	base.top_radius = 0.76
	base.bottom_radius = 0.83
	base.height = 0.27
	base.radial_segments = 36
	_mesh(body, base, Vector3(0, 0.18, 0), _paint(Color("172631")))
	var trim := TorusMesh.new()
	trim.inner_radius = 0.60
	trim.outer_radius = 0.82
	trim.rings = 14
	trim.ring_segments = 28
	_mesh(body, trim, Vector3(0, 0.28, 0), _paint(tint))
	var hull := SphereMesh.new()
	hull.radius = 0.55
	hull.height = 0.64
	hull.radial_segments = 22
	hull.rings = 9
	_mesh(body, hull, Vector3(0, 0.37, -0.12), _paint(MINT.lerp(tint, 0.38)))
	var chair := BoxMesh.new()
	chair.size = Vector3(0.59, 0.35, 0.26)
	_mesh(body, chair, Vector3(0, 0.50, 0.33), _paint(Color("243341")))
	var lamp := BoxMesh.new()
	lamp.size = Vector3(0.19, 0.11, 0.11)
	for x in [-0.27, 0.27]:
		_mesh(body, lamp, Vector3(x, 0.40, -0.65), _paint(CREAM, true))

func update_visuals(state: RefCounted, delta: float, own_slot: int = 0) -> void:
	_clock += delta
	var elapsed: float = state.elapsed if state != null else 0.0
	var fresh: bool = state != _round or (state != null and _round_id != state.round_id) or elapsed < _last_elapsed
	_last_elapsed = elapsed
	_round = state
	_round_id = state.round_id if state != null else -1
	if fresh:
		_champion = -1
	_radius = state.safe_radius() if state != null else Model.RADII[0]
	var target := maxf(_radius, 6.4)
	_camera_radius = target if fresh else lerpf(_camera_radius, target, 1.0 - exp(-2.9 * delta))
	_frame_camera()
	_water.set_shader_parameter("clock", _clock)
	_water.set_shader_parameter("deck_radius", _radius)
	for i in _buoys.size():
		_buoys[i].position.y = WATER_Y + 0.07 * sin(_clock * 1.48 + i)
		_buoys[i].rotation.z = 0.06 * sin(_clock * 1.19 + i * 2.1)
	_update_rings(state, delta, fresh)
	for i in _cars.size():
		var player: Dictionary = state.players[i] if state != null else _display_car(i)
		_update_car(i, player, delta, fresh, own_slot if state != null else -1)

func _update_rings(state: RefCounted, delta: float, fresh: bool) -> void:
	var ring_level: int = state.ring_level if state != null else 0
	var warning: bool = state != null and state.warning()
	for i in Model.DROP_TIMES.size():
		var ring: Dictionary = _rings[i]
		var age := 0.0
		if i < ring_level:
			var since_drop: float = maxf(0.0, state.elapsed - Model.DROP_TIMES[i])
			age = minf(RING_SINK, since_drop if fresh else maxf(since_drop, float(ring.sink) + delta))
		ring.sink = age
		ring.root.visible = age < RING_SINK
		ring.root.position.y = -age * (1.45 + 4.4 * age)
		ring.root.rotation.x = 0.085 * age * (1.0 if i % 2 == 0 else -1.0)
		ring.root.rotation.z = 0.045 * age
		ring.flash.visible = warning and i == ring_level
		if ring.flash.visible:
			var eta: float = Model.DROP_TIMES[i] - state.elapsed
			var pulse := 0.5 + 0.5 * sin(state.elapsed * (9.5 + 5.0 / maxf(eta + 1.0, 1.0)))
			ring.alert.albedo_color = Color(1.0, 0.58, 0.24, 0.23 + 0.50 * pulse)
		ring.wake.visible = age > 0.47 and age < RING_SINK
		if ring.wake.visible:
			var spread := 1.0 + (age - 0.47) * 0.12
			ring.wake.scale = Vector3(spread, 1, spread)
			ring.wash.albedo_color = Color(0.60, 0.89, 0.83, (1.0 - age / RING_SINK) * 0.69)

func _display_car(slot: int) -> Dictionary:
	var a := float(slot) * TAU / Model.SEATS + 0.28
	return {"pos": Vector2.from_angle(a) * 8.6, "velocity": Vector2.ZERO,
		"heading": a + 2.35, "alive": true, "fall_time": 0.0,
		"boost": 0.0, "name": ""}

func _update_car(slot: int, p: Dictionary, delta: float, fresh: bool, own_slot: int) -> void:
	var v: Dictionary = _cars[slot]
	var car: Node3D = v.car
	var alive: bool = p.alive
	var at: Vector2 = p.pos
	var air := 0.0
	if not alive:
		air = minf(Model.FALL_DURATION, float(p.fall_time) if fresh else maxf(float(p.fall_time), float(v.visual_fall) + delta))
	var pos := Vector3(at.x, 0.0 if alive else WATER_Y * pow(air / WATER_HIT, 2), at.y)
	if client_motion and alive:
		var velocity: Vector2 = p.velocity
		pos += Vector3(velocity.x, 0, velocity.y) * 0.025
	var move := clampf(1.0 - exp(-24.0 * delta), 0.0, 1.0) if client_motion and not fresh else 1.0
	car.position = car.position.lerp(pos, move)
	car.rotation.y = lerp_angle(car.rotation.y, -float(p.heading), move)
	car.visible = alive or air < 0.69
	var winner := alive and slot == _champion
	v.body.rotation.x = -air * 1.05
	v.body.rotation.z = air * (1.25 if slot % 2 == 0 else -1.25)
	v.body.position.y = 0.12 * absf(sin(_clock * 4.6)) if winner else 0.0
	v.shadow.position = Vector3(car.position.x + 0.12, 0.018, car.position.z + 0.13)
	v.marker.position = Vector3(car.position.x, 0.024, car.position.z)
	v.shadow.visible = alive
	v.marker.visible = alive
	v.trail.visible = alive and float(p.boost) > 0.0
	v.trail.scale.z = 0.65 + 0.35 * sin(_clock * 69.0)
	var local := own_slot >= 0 and (slot == own_slot or (local_mask & (1 << slot)) != 0)
	var show_tag := alive and (show_identities or local or winner) and str(p.name) != ""
	v.tag.visible = show_tag
	v.number.visible = alive and not show_tag
	v.tag.position = Vector3(car.position.x, 1.59, car.position.z)
	v.number.position = Vector3(car.position.x, 1.42, car.position.z)
	if show_tag:
		v.tag.text = "YOU" if local and local_mask == 0 and not show_identities else str(p.name).to_upper()
	var water_age := air - WATER_HIT
	if water_age >= 0.0 and (fresh or float(v.visual_fall) < WATER_HIT):
		v.water_at = at
	v.visual_fall = air
	v.splash.visible = not alive and water_age >= 0.0 and water_age < 0.86
	if v.splash.visible:
		var splash_at: Vector2 = v.water_at
		var radius := 0.58 + water_age * 2.6
		v.splash.position = Vector3(splash_at.x, WATER_Y + 0.027, splash_at.y)
		v.splash.scale = Vector3(radius, 1.0, radius)
		v.water.albedo_color = Color(0.75, 1.0, 0.92, 0.83 * (1.0 - water_age / 0.86))
		v.drops.visible = level != "low" and water_age < 0.55
		if v.drops.visible:
			_scatter_drops(v.drops.multimesh, water_age)

func _scatter_drops(foam: MultiMesh, age: float) -> void:
	var spread := 0.24 + age * 1.9
	var shrink := Vector3.ONE * (1.0 - age)
	for i in foam.instance_count:
		var angle := TAU * i / foam.instance_count
		var height := maxf(0.0, age * (5.0 + (i % 3) * 0.74 - age * 11.0))
		var pose := Transform3D(Basis.from_scale(shrink), _point(spread, height, angle))
		foam.set_instance_transform(i, pose)

func _annulus(inner: float, outer: float, segments: int = SEGMENTS) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in segments:
		_strip(surface, inner, outer, 0.0, i * TAU / segments, (i + 1) * TAU / segments, Color.WHITE)
	return surface.commit()

func _strip(surface: SurfaceTool, inner: float, outer: float, y: float, a: float, b: float, color: Color) -> void:
	_quad(surface, _point(inner, y, a), _point(outer, y, a),
		_point(outer, y, b), _point(inner, y, b), Vector3.UP, color)

func _wall(surface: SurfaceTool, radius: float, a: float, b: float, top: float, base: float, color: Color) -> void:
	var normal := _point(1.0, 0.0, (a + b) * 0.5)
	_quad(surface, _point(radius, top, a), _point(radius, base, a),
		_point(radius, base, b), _point(radius, top, b), normal, color)

func _point(radius: float, y: float, angle: float) -> Vector3:
	return Vector3(cos(angle) * radius, y, sin(angle) * radius)

func _quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, normal: Vector3, color: Color) -> void:
	for vertex in [a, b, c, a, c, d]:
		surface.set_normal(normal)
		surface.set_color(color)
		surface.add_vertex(vertex)

func _paint(color: Color, unshaded: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.83
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if unshaded:
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if color.a < 1.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material

func _mesh(parent: Node3D, resource: Mesh, at: Vector3, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = resource
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(node)
	node.position = at
	return node

func _tag(caption: String, color: Color, pixels: float) -> Label3D:
	var label := Label3D.new()
	label.text = caption
	label.font = Kit.heavy
	label.font_size = 43
	label.outline_size = 13
	label.modulate = color
	label.outline_modulate = Color("0c1b29")
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.pixel_size = pixels
	add_child(label)
	return label

func _floor_text(parent: Node3D, caption: String, pixels: float, color: Color) -> Label3D:
	var sign := Label3D.new()
	sign.font = Kit.display
	sign.text = caption
	sign.font_size = 35
	sign.line_spacing = -8
	sign.pixel_size = pixels
	sign.outline_size = 0
	sign.modulate = color
	parent.add_child(sign)
	sign.position.y = 0.018
	sign.rotation.x = -PI / 2.0
	return sign
