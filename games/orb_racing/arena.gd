extends Node3D
## One fixed orthographic view covers every racer. World X and Z project to
## screen right and down. Guests ease towards each authoritative position.

const Model = preload("res://games/orb_racing/model.gd")
const Track = preload("res://games/orb_racing/track.gd")
const Venue = preload("res://games/orb_racing/venue.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const ShellShader = preload("res://games/orb_racing/orb.gdshader")
const AWAY_POINT := Vector2(0, 2.6)
const RING_HEIGHT := 0.053
const BADGE_OFFSETS := [Vector2.ZERO, Vector2(0, 2.68), Vector2(1.5, -1.24),
	Vector2(-1.55, 0), Vector2(1.55, 2.65), Vector2(-1.60, 2.65)]

var camera: Camera3D
var client_motion := false
var local_mask := 0
var show_identities := false
var _track := Track.new()
var _menu := true
var _inset := 0.0
var _show_trails := true
var _last_round := 0
var _champion := -1
var _showcase_time := 0.0

var _racers: Array[Node3D] = []
var _shells: Array[MeshInstance3D] = []
var _rings: Array[MeshInstance3D] = []
var _trails: Array[MeshInstance3D] = []
var _badges: Array[Label3D] = []
var _marks: Array[Node3D] = []
var _gate_labels: Array[Label3D] = []
var _band: ShaderMaterial


func _ready() -> void:
	Kit.setup()
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.far = 170.0
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("122329")
	camera.environment = env
	add_child(camera)
	get_viewport().size_changed.connect(_frame_camera)
	_frame_camera()
	camera.make_current()

	var venue := Venue.new()
	add_child(venue)
	venue.build(_track)
	_build_gates()
	_build_orbs()


func set_menu(value: bool) -> void:
	_menu = value
	_champion = -1
	_showcase_time = 0.0
	show_identities = false
	_frame_camera()


func set_inset(value: float) -> void:
	_inset = clampf(value, 0.0, 0.7)
	_frame_camera()


func set_level(level: String) -> void:
	# Low still uses the same track, shell and gate markers.
	_show_trails = level != "low"


func _frame_camera() -> void:
	var rect := get_viewport().get_visible_rect()
	var aspect := rect.size.x / maxf(1.0, rect.size.y)
	camera.size = maxf(63.0, 98.0 / maxf(0.1, aspect))
	if _menu:
		camera.size *= 1.0 + _inset * 0.52
	camera.rotation_degrees = Vector3(-84, 0, 0)
	camera.position = Vector3(0, 97, 9.75)
	camera.h_offset = -_inset * camera.size * aspect * 0.38 if _menu else 0.0


func _build_gates() -> void:
	var lamp := BoxMesh.new()
	lamp.size = Vector3(0.52, 0.12, 0.8)
	var dash := BoxMesh.new()
	dash.size = Vector3(0.16, 0.03, 1.55)
	var light := _flat(Venue.ICE)
	for i in _track.gates.size():
		var line: Transform2D = _track.gates[i]
		var marker := Node3D.new()
		marker.position = _world(line.origin, 0)
		marker.rotation.y = -line.x.angle()
		add_child(marker)
		_marks.append(marker)
		for side: float in [-1.0, 1.0]:
			_mesh(marker, lamp, light, Vector3(0, 1.19 if i == 0 else 0.94, side * 6.55))
			if i != 0:
				_mesh(marker, dash, light, Vector3(0, 0.079, side * 4.7))
		var tag := _tag("GATE %d" % i, 0.029)
		tag.position = _world(line.origin - line.y * 8.9, 0.55)
		add_child(tag)
		_gate_labels.append(tag)
		marker.hide()
		tag.hide()


func _build_orbs() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = Track.ORB_RADIUS
	sphere.height = Track.ORB_RADIUS * 2.0
	sphere.radial_segments = 24
	sphere.rings = 12
	var ring := TorusMesh.new()
	ring.inner_radius = 0.90
	ring.outer_radius = 1.16
	ring.rings = 24
	ring.ring_segments = 6
	var shadow := PlaneMesh.new()
	shadow.size = Vector2(2.65, 2.65)
	var shade := _plane_material("""
		float radial = length((UV - vec2(0.5)) * 2.0);
		ALBEDO = vec3(0.043, 0.067, 0.085);
		ALPHA = (1.0 - smoothstep(0.23, 0.96, radial)) * 0.71;
	""")
	var trail := PlaneMesh.new()
	trail.size = Vector2(3.6, 1.55)
	_band = _plane_material("""
		float fade = smoothstep(0.0, 0.82, UV.x) * (1.0 - smoothstep(0.84, 1.0, UV.x));
		float beam = 1.0 - smoothstep(0.105, 0.23, abs(abs(UV.y - 0.5) - 0.23));
		ALBEDO = vec3(1.0, 0.79, 0.24);
		ALPHA = fade * beam * strength;
	""")

	for i in Model.SEATS:
		var racer := Node3D.new()
		add_child(racer)
		_racers.append(racer)
		var material := ShaderMaterial.new()
		material.shader = ShellShader
		material.set_shader_parameter("team", Kit.colors[i])
		var shell := _mesh(racer, sphere, material, Vector3(0, Track.ORB_RADIUS, 0))
		shell.rotation = Vector3(0.6, i * 0.68, -0.36 + i * 0.10)
		_shells.append(shell)
		_mesh(racer, shadow, shade, Vector3(0.14, 0.043, 0.24))
		_rings.append(_mesh(racer, ring, _flat(Kit.colors[i].lerp(Color.WHITE, 0.42)),
			Vector3(0, RING_HEIGHT, 0)))
		_trails.append(_mesh(self, trail, _band, Vector3.ZERO))
		var badge := _tag(str(i + 1), 0.022)
		badge.modulate = Kit.colors[i].lerp(Color.WHITE, 0.32)
		add_child(badge)
		_badges.append(badge)


func _tag(value: String, pixels: float) -> Label3D:
	var tag := Label3D.new()
	tag.font = Kit.heavy
	tag.font_size = 56
	tag.outline_size = 19
	tag.outline_modulate = Kit.OUTLINE
	tag.pixel_size = pixels
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.no_depth_test = true
	tag.text = value
	return tag


func _mesh(parent: Node3D, shape: Mesh, material: Material, at: Vector3) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = shape
	node.material_override = material
	node.position = at
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(node)
	return node


func _flat(tint: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = tint
	return material


func _plane_material(fragment: String) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """shader_type spatial;
render_mode unshaded, shadows_disabled, depth_draw_never;
uniform float strength = 0.84;
void fragment() {
""" + fragment + "}"
	var material := ShaderMaterial.new()
	material.shader = shader
	return material


func celebrate(slot: int) -> void:
	_champion = slot
	_showcase_time = 0.0


func update_visuals(state: RefCounted, delta: float, own_slot: int = 0) -> void:
	if state == null or state.players.is_empty():
		return
	var fresh := _last_round != state.get_instance_id()
	_last_round = state.get_instance_id()
	_showcase_time += delta
	var active := 0
	var lap_line := false
	var used: Array[Vector2] = []
	for i in state.players.size():
		var p: Dictionary = state.players[i]
		var here: bool = not _menu and (i == own_slot or local_mask & (1 << i) != 0)
		if here and p.finish < 0.0:
			active |= 1 << int(p.gate)
			lap_line = lap_line or (p.gate == 0 and p.started)
		_show_orb(i, p, float(state.elapsed), delta, fresh, here, used)
	for i in _marks.size():
		var hot := active & (1 << i) != 0
		_marks[i].visible = hot
		_gate_labels[i].visible = hot
	_gate_labels[0].text = "LAP LINE" if lap_line else "START"


func _show_orb(i: int, p: Dictionary, clock: float, dt: float, fresh: bool, here: bool, used: Array[Vector2]) -> void:
	var racer := _racers[i]
	var champion := i == _champion
	var visible_finish: bool = p.finish < 0.0 or clock - float(p.finish) < 1.4
	racer.visible = visible_finish or champion
	_badges[i].visible = racer.visible and not champion
	_trails[i].visible = _show_trails and racer.visible and p.boost > 0.0 and not champion
	if not racer.visible:
		return
	var dest: Vector2 = p.pos
	var movement: Vector2 = p.velocity
	if champion:
		# Showcase behind the results column. It has no bearing on race state.
		var scale_in := smoothstep(0.0, 0.65, _showcase_time)
		racer.scale = Vector3.ONE * lerpf(1.0, 3.5, scale_in)
		racer.position = _world(dest.lerp(AWAY_POINT, scale_in), 0.5 + sin(_showcase_time * 3.0) * 0.3)
		_shells[i].rotate_y(dt * 1.35)
		_rings[i].visible = true
		return
	racer.scale = Vector3.ONE
	var wanted := _world(dest, 0.0)
	var old := racer.position
	racer.position = old.lerp(wanted, 1.0 - exp(-25.0 * dt)) if client_motion and not fresh else wanted
	var drive := racer.position - old
	if not fresh and drive.length_squared() > 0.000001:
		var axis := Vector3.UP.cross(drive).normalized()
		_shells[i].rotate(axis, drive.length() / Track.ORB_RADIUS)
	_rings[i].visible = here
	var mat: ShaderMaterial = _shells[i].material_override
	mat.set_shader_parameter("boost", minf(1.0, float(p.boost) * 6.0))
	if _trails[i].visible and movement != Vector2.ZERO:
		_trails[i].position = racer.position - _world(movement.normalized() * 2.03, -0.07)
		_trails[i].rotation.y = -movement.angle()
	var at := Vector2(racer.position.x, racer.position.z)
	var base := at + Vector2(0, -1.36)
	var badge_at := base
	for offset in BADGE_OFFSETS:
		badge_at = base + offset
		if not used.any(func(other: Vector2) -> bool: return other.distance_squared_to(badge_at) < 1.25):
			break
	used.append(badge_at)
	_badges[i].position = _world(badge_at, 1.0)
	_badges[i].text = ("%d  %s" % [i + 1, p.name]) if show_identities else str(i + 1)


static func _world(pos: Vector2, height: float) -> Vector3:
	return Vector3(pos.x, height, pos.y)
