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
const BADGE_PIXEL_SIZE := 0.022
const LOCAL_BADGE_PIXEL_SIZE := 0.029
const BADGE_OFFSETS := [Vector2.ZERO, Vector2(2.8, -0.9), Vector2(-2.8, -0.9),
	Vector2(0, -2.5), Vector2(0, 3.0), Vector2(-2.8, 2.1), Vector2(2.8, 2.1),
	Vector2(0, -4.2), Vector2(0, 4.9), Vector2(-5.6, -2.1), Vector2(5.6, -2.1)]

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
var _badge_slots := PackedInt32Array()
var _badge_offsets := PackedVector2Array()
var _badge_sizes := PackedVector2Array()
var _marks: Array[Node3D] = []
var _gate_labels: Array[Label3D] = []
var _gate_sizes := PackedVector2Array()
var _band: ShaderMaterial
var _badge_links := ImmediateMesh.new()


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
	_gate_sizes.resize(_track.gates.size())
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
		var tag := _tag("", 0.034)
		tag.modulate = Venue.ICE
		tag.position = _world(line.origin - line.y * 6.9, 0.55)
		add_child(tag)
		_gate_labels.append(tag)
		marker.hide()
		tag.hide()


func _build_orbs() -> void:
	_badge_slots.resize(Model.SEATS)
	_badge_offsets.resize(Model.SEATS)
	_badge_sizes.resize(Model.SEATS)
	var link_paint := _flat(Kit.INK)
	link_paint.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	link_paint.no_depth_test = true
	_mesh(self, _badge_links, link_paint, Vector3.ZERO)
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
		_rings.append(_mesh(racer, ring, _flat(Kit.colors[i].lerp(Color.WHITE, 0.65)),
			Vector3(0, RING_HEIGHT, 0)))
		_trails.append(_mesh(self, trail, _band, Vector3.ZERO))
		var badge := _tag("", BADGE_PIXEL_SIZE)
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
	if fresh:
		_badge_slots.fill(0)
		_badge_offsets.fill(Vector2.ZERO)
	_showcase_time += delta
	var locals := 0
	var active := 0
	var lap_line := false
	var start_line := false
	var gate_seats := PackedInt32Array()
	gate_seats.resize(_marks.size())
	for i in state.players.size():
		var p: Dictionary = state.players[i]
		var here: bool = p.active and not _menu and (i == own_slot or local_mask & (1 << i) != 0)
		if here:
			locals |= 1 << i
			if p.finish < 0.0:
				var gate: int = p.gate
				active |= 1 << gate
				gate_seats[gate] |= 1 << i
				lap_line = lap_line or (gate == 0 and p.started)
				start_line = start_line or (gate == 0 and not p.started)
		_show_orb(i, p, float(state.elapsed), delta, fresh, here)
	var used: Array[Rect2] = []
	var split := (active & (active - 1)) != 0
	for i in _marks.size():
		var hot := gate_seats[i] != 0
		var tag := _gate_labels[i]
		_marks[i].visible = hot
		tag.visible = hot
		if not hot:
			continue
		var caption := "GATE %d" % i
		if i == 0:
			caption = "START / LAP LINE" if lap_line and start_line else ("LAP LINE" if lap_line else "START")
		if split:
			var seats := PackedStringArray()
			for slot in _racers.size():
				if (gate_seats[i] & (1 << slot)) != 0:
					seats.append("P%d" % (slot + 1))
			caption = "/".join(seats) + "  " + caption
		if tag.text != caption:
			tag.text = caption
			_gate_sizes[i] = _label_size(tag)
		var center := Vector2(tag.position.x, tag.position.z)
		used.append(Rect2(center - _gate_sizes[i] * 0.5, _gate_sizes[i]).grow(0.08))
	var settle := 1.0 if fresh else 1.0 - exp(-18.0 * delta)
	for local_first: bool in [true, false]:
		for i in _badges.size():
			if _badges[i].visible and ((locals & (1 << i)) != 0) == local_first:
				_place_badge(i, state.players[i], local_first, settle, used)
	_link_badges(locals)


func _show_orb(i: int, p: Dictionary, clock: float, dt: float, fresh: bool, here: bool) -> void:
	var racer := _racers[i]
	var champion := i == _champion
	var visible_finish: bool = p.finish < 0.0 or clock - float(p.finish) < 1.4
	racer.visible = p.active and (visible_finish or champion)
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


func _place_badge(i: int, p: Dictionary, here: bool, settle: float, used: Array[Rect2]) -> void:
	var badge := _badges[i]
	var caption := str(i + 1)
	if show_identities:
		caption = "%d  %s" % [i + 1, p.name]
	elif here:
		caption = "YOU %d" % (i + 1) if local_mask == 0 else "P%d" % (i + 1)
	var pixel_size := LOCAL_BADGE_PIXEL_SIZE if here else BADGE_PIXEL_SIZE
	if badge.text != caption or not is_equal_approx(badge.pixel_size, pixel_size):
		badge.text = caption
		badge.pixel_size = pixel_size
		_badge_sizes[i] = _label_size(badge)
	var priority := 2 if here else 0
	if badge.render_priority != priority:
		badge.render_priority = priority
		badge.outline_render_priority = priority - 1
		badge.modulate = Kit.INK if here else Kit.colors[i].lerp(Color.WHITE, 0.32)
	var racer := _racers[i].position
	var base := Vector2(racer.x, racer.z - 1.36)
	var bounds := Rect2(-_badge_sizes[i] * 0.5, _badge_sizes[i])
	var slot := _badge_slots[i]
	# Keep a displaced tag in place until the center has enough space to stay clear.
	if slot != 0 and _badge_room(bounds.grow(0.34), base, used):
		slot = 0
	if not _badge_room(bounds, base + BADGE_OFFSETS[slot], used):
		for candidate in BADGE_OFFSETS.size():
			if _badge_room(bounds, base + BADGE_OFFSETS[candidate], used):
				slot = candidate
				break
	var target: Vector2 = BADGE_OFFSETS[slot]
	var at := base + target
	if not here and not show_identities and not _badge_room(bounds, at, used):
		badge.hide()
		return
	_badge_slots[i] = slot
	var offset := _badge_offsets[i].lerp(target, settle)
	if not _badge_room(bounds, base + offset, used):
		offset = target
	_badge_offsets[i] = offset
	badge.position = _world(base + offset, 1.0)
	used.append(Rect2(bounds.position + at, bounds.size))
	if not offset.is_equal_approx(target):
		used.append(Rect2(bounds.position + base + offset, bounds.size))


func _badge_room(bounds: Rect2, at: Vector2, used: Array[Rect2]) -> bool:
	bounds.position += at
	for other in used:
		if bounds.intersects(other):
			return false
	return true


func _label_size(label: Label3D) -> Vector2:
	var text_size := label.font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size)
	return (text_size + Vector2.ONE * label.outline_size) * label.pixel_size


## A moved local tag still points to its own orb when six racers overlap.
func _link_badges(locals: int) -> void:
	_badge_links.clear_surfaces()
	var linked := false
	for i in _badges.size():
		if (locals & (1 << i)) == 0 or not _badges[i].visible or _badge_offsets[i].length_squared() < 0.49:
			continue
		var from := _racers[i].position
		from.y = 1.0
		var to := _badges[i].position
		var distance := from.distance_to(to)
		if distance < 1.4:
			continue
		if not linked:
			_badge_links.surface_begin(Mesh.PRIMITIVE_LINES)
			linked = true
		var axis := (to - from) / distance
		_badge_links.surface_add_vertex(from + axis * 0.76)
		_badge_links.surface_add_vertex(to - axis * 0.45)
	if linked:
		_badge_links.surface_end()


static func _world(pos: Vector2, height: float) -> Vector3:
	return Vector3(pos.x, height, pos.y)
