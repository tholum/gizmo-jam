extends Node3D
## The arena projects the authoritative targets and cargo state into the harbor.

const Model = preload("res://games/salvage_line/model.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const WATER = preload("res://games/salvage_line/water.gdshader")
const CREAM := Color("fff0c8")
const INK := Color("0b2530")
const WOOD := Color("745544")
const BRASS := Color("ffcf70")
const SEAFOAM := Color("a1e4de")
const DRIFT := Color("83d4ec")
const WARNING := Color("ff9e65")
const NORMAL := Color("f5d5a0")
const TARGET_COLORS := {"hook": CREAM, "cut": WARNING, "deliver": BRASS, "release": SEAFOAM}

var camera: Camera3D
var client_motion := false
var local_mask := 0
var show_identities := false

var _menu := false
var _inset := 0.0
var _level := "medium"
var _champion := -1
var _water: ShaderMaterial
var _clock := 0.0
var _state: RefCounted
var _boats: Array[Dictionary] = []
var _harbors: Array[Dictionary] = []
var _targets: Array[Dictionary] = []
var _cargo: Dictionary = {}
var _cargo_pool: Array[Dictionary] = []
var _materials: Dictionary = {}

func _ready() -> void:
	Kit.setup()
	_setup_camera()
	_build_bay()
	for slot in Model.SEATS:
		_build_harbor(slot)
		_build_boat(slot)
		_build_target(slot)
	set_level(_level)
	get_viewport().size_changed.connect(_frame_camera)
	_frame_camera()

func set_menu(value: bool) -> void:
	_menu = value
	_champion = -1
	show_identities = false
	_frame_camera()

func set_inset(value: float) -> void:
	_inset = clampf(value, 0.0, 0.80)
	_frame_camera()

func set_level(value: String) -> void:
	_level = value
	if _water != null:
		_water.set_shader_parameter("fine_detail", value != "low")

func celebrate(slot: int) -> void:
	_champion = slot

func _setup_camera() -> void:
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.near = 0.5
	camera.far = 120.0
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("142e3b")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("d5f2ec")
	environment.ambient_light_energy = 0.78
	camera.environment = environment
	add_child(camera)
	camera.position = Vector3(0, 38.0, 19.0)
	camera.look_at(Vector3.ZERO)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-58, -27, 0)
	sun.light_color = Color("ffe6ba")
	sun.light_energy = 1.05
	add_child(sun)

func _frame_camera() -> void:
	if camera == null:
		return
	var screen := get_viewport().get_visible_rect().size
	var aspect := screen.x / maxf(screen.y, 1.0)
	var inset := _inset if _menu else 0.0
	camera.size = maxf(29.7 if _menu else 31.6, (32.8 if _menu else 30.0) / maxf((1.0 - inset) * aspect, 0.15))
	camera.h_offset = -inset * camera.size * aspect * 0.5
	camera.v_offset = -0.30

func _build_bay() -> void:
	_water = ShaderMaterial.new()
	_water.shader = WATER
	var sea := PlaneMesh.new()
	sea.size = Vector2(160.0, 160.0)
	_mesh(self, sea, _water)
	# A faint compass is painted on the harbor chart under the playfield.
	_ring(self, 1.46, 0.022, Color("31818a"), 0.017)
	for i in 4:
		var bearing := _group(self, Vector2.ZERO)
		bearing.rotation.y = i * PI * 0.5
		_box(bearing, Vector3(1.05, 0.005, 0.049), Vector3(0.76, 0.019, 0), Color("388c91"), true)
	for radius in [16.7, 18.7, 21.5]:
		_ring(self, radius, 0.056, Color("244d5f"), 0.012, true)
	_ring(self, Model.FIELD_RADIUS, 0.10, Color("366d77"), 0.020)
	_ring(self, Model.FIELD_RADIUS + 0.28, 0.07, Color("234c59"), 0.019)
	for i in 48:
		var at := Vector2.from_angle(TAU * i / 48.0) * (Model.FIELD_RADIUS + 0.12)
		var tall := i % 4 == 2
		var post := _group(self, at)
		post.rotation.y = -at.angle()
		_box(post, Vector3(0.12, 0.07, 0.35), Vector3(0, 0.018, 0), Color("70b1ad") if tall else Color("467782"), true)
		if tall:
			_cylinder(post, 0.084, 0.28, Vector3(0, 0.15, 0), INK, true)
			_cylinder(post, 0.100, 0.08, Vector3(0, 0.34, 0), SEAFOAM, true)
	var rng := RandomNumberGenerator.new()
	rng.seed = 8014
	for i in 60:
		var at := Vector2.from_angle(rng.randf_range(0, TAU)) * sqrt(rng.randf()) * 21.0
		var mark_color := Color("397c82").lerp(Color("509699"), rng.randf() * 0.65)
		_box(self, Vector3(rng.randf_range(0.21, 0.76), 0.004, 0.028), _v(at, 0.013), mark_color, true)

func _build_harbor(slot: int) -> void:
	var at := Model.harbor_center(slot)
	var tint: Color = Kit.colors[slot]
	var dock := _group(self, at)
	dock.rotation.y = -at.angle()
	_cylinder(dock, Model.DOCK_RADIUS, 0.028, Vector3(0, 0.014, 0), Color("21575f").lerp(tint, 0.23), true, 64)
	_ring(dock, Model.DOCK_RADIUS, 0.075, tint.darkened(0.12), 0.043)
	_ring(dock, Model.DOCK_RADIUS - 0.24, 0.035, tint.darkened(0.34), 0.041)

	# Two lines of buoys trace the protected approach toward the wharf.
	var lanes := _group(dock, Vector2.ZERO)
	for side in [-1.0, 1.0]:
		for i in 5:
			var along := -Model.APPROACH_RADIUS + 0.42 + i * 0.73
			var across := sqrt(maxf(0.0, Model.APPROACH_RADIUS * Model.APPROACH_RADIUS - along * along))
			_cylinder(lanes, 0.088, 0.098, Vector3(along, 0.060, across * side), tint.darkened(0.35), true)
		var pontoon := _group(dock, Vector2(0.2, 1.91 * side))
		for i in 5:
			_box(pontoon, Vector3(0.33, 0.17, 0.37), Vector3(i * 0.35, 0.20, 0), Color("a88a69") if i % 2 else Color("ba9a75"))
		_cylinder(pontoon, 0.12, 0.50, Vector3(0.08, 0.25, 0), INK)
		_cylinder(pontoon, 0.140, 0.10, Vector3(0.08, 0.52, 0), tint, true)

	var wharf := _group(dock, Vector2(2.58, 0))
	_box(wharf, Vector3(1.26, 0.32, 4.08), Vector3(0, 0.17, 0), INK)
	for i in 12:
		_box(wharf, Vector3(1.22, 0.12, 0.31), Vector3(0, 0.36, i * 0.33 - 1.815),
			Color("b59873") if i % 3 else Color("947459"))
	for side in [-1.0, 1.0]:
		_cylinder(wharf, 0.14, 0.69, Vector3(-0.44, 0.45, side * 1.76), WOOD)
		_cylinder(wharf, 0.17, 0.12, Vector3(-0.44, 0.82, side * 1.76), tint, true)
		_box(wharf, Vector3(0.24, 0.21, 0.58), Vector3(-0.55, 0.50, side * 0.94), INK)
	_cylinder(wharf, 0.47, 0.43, Vector3(0.01, 0.67, 0), tint)
	_cylinder(wharf, 0.48, 0.06, Vector3(0.01, 0.90, 0), tint.lightened(0.25), true)
	_label(wharf, str(slot + 1), Vector3(0, 1.15, 0), 38, 0.033, Color.WHITE)
	var flash := _ring(dock, Model.DOCK_RADIUS + 0.16, 0.14, tint.lightened(0.35), 0.056)
	flash.hide()
	_harbors.append({"flash": flash})

func _build_boat(slot: int) -> void:
	var tint: Color = Kit.colors[slot]
	var root := _group(self, Vector2.ZERO)
	var rig := _group(root, Vector2.ZERO)
	var hull := PackedVector2Array([
		Vector2(-0.72, -0.49), Vector2(0.46, -0.49), Vector2(0.93, -0.24),
		Vector2(1.05, 0), Vector2(0.93, 0.24), Vector2(0.46, 0.49), Vector2(-0.72, 0.49), Vector2(-0.88, 0),
	])
	_mesh(rig, _hull_mesh(hull, 0.06, 0.40), _paint(INK))
	_mesh(rig, _hull_mesh(hull, 0.27, 0.49), _paint(tint))
	var deck := PackedVector2Array()
	for point in hull:
		deck.append(point * 0.79)
	_mesh(rig, _hull_mesh(deck, 0.47, 0.52), _paint(Color("cabc9b")))
	_box(rig, Vector3(0.53, 0.41, 0.62), Vector3(0.27, 0.70, 0), CREAM)
	_box(rig, Vector3(0.54, 0.18, 0.635), Vector3(0.28, 0.78, 0), Color("304955"))
	_box(rig, Vector3(0.62, 0.10, 0.71), Vector3(0.27, 0.96, 0), tint.lightened(0.30))
	_cylinder(rig, 0.09, 0.29, Vector3(-0.12, 0.69, 0.25), INK)
	_cylinder(rig, 0.18, 0.16, Vector3(-0.43, 0.60, 0), Color("ba906a"))
	_cylinder(rig, 0.10, 0.11, Vector3(-0.43, 0.71, 0), BRASS)
	for side in [-1.0, 1.0]:
		_box(rig, Vector3(0.41, 0.14, 0.12), Vector3(-0.33, 0.45, side * 0.51), INK)
		_box(rig, Vector3(0.12, 0.085, 0.10), Vector3(0.54, 0.58, side * 0.31), tint.lightened(0.55), true)

	var wake_mesh := QuadMesh.new()
	wake_mesh.size = Vector2(1.7, 2.10)
	var wake_texture := GradientTexture2D.new()
	wake_texture.width = 48
	wake_texture.height = 48
	wake_texture.fill = GradientTexture2D.FILL_RADIAL
	wake_texture.fill_from = Vector2(0.5, 0.5)
	wake_texture.fill_to = Vector2(0, 0.5)
	wake_texture.gradient = Gradient.new()
	wake_texture.gradient.colors = PackedColorArray([Color(SEAFOAM, 0.31), Color(SEAFOAM, 0.0)])
	var wake_material := StandardMaterial3D.new()
	wake_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	wake_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wake_material.albedo_texture = wake_texture
	var wake := _mesh(rig, wake_mesh, wake_material)
	wake.rotation_degrees = Vector3(-90.0, 0, 0)
	wake.position = Vector3(-1.16, 0.058, 0)
	var trails := _group(rig, Vector2.ZERO)
	for side in [-1.0, 1.0]:
		for i in 2:
			var foam := _box(trails, Vector3(0.35 - i * 0.07, 0.008, 0.043),
				Vector3(-1.09 - i * 0.27, 0.06, side * (0.35 + i * 0.09)), Color("74b2af"), true)
			foam.rotation.y = side * 0.39


	var label := _label(root, str(slot + 1), Vector3(0, 1.10, 0), 34, 0.025, Color.WHITE)
	var outline := _ring(root, 1.08, 0.08, tint.lightened(0.24), 0.07)
	_boats.append({"root": root, "rig": rig, "face": 0.0, "label": label, "wake": wake, "trails": trails,
		"outline": outline})

func _build_target(slot: int) -> void:
	var root := _group(self, Vector2.ZERO)
	var target_color: Color = Kit.colors[slot]
	var ring := _ring(root, 1.05, 0.125, target_color.lightened(0.25), 0.095)
	var caption := _label(root, "", Vector3(0, 1.65, 0), 33, 0.027, CREAM)
	_targets.append({"root": root, "ring": ring, "caption": caption})
	root.hide()

func _new_crate(heavy: bool) -> Dictionary:
	for i in _cargo_pool.size():
		if _cargo_pool[i].heavy == heavy:
			return _cargo_pool.pop_at(i)
	var tint := BRASS if heavy else NORMAL
	var size := 1.20 if heavy else 0.96
	var root := _group(self, Vector2.ZERO)
	var body := _group(root, Vector2.ZERO)
	_box(body, Vector3(size, 0.60, size * 0.81), Vector3(0, 0.31, 0), WOOD)
	_box(body, Vector3(size * 0.92, 0.07, size * 0.74), Vector3(0, 0.635, 0), tint.darkened(0.19))
	for side in [-1.0, 1.0]:
		var x: float = side * size * 0.38
		_box(body, Vector3(0.11, 0.10, size * 0.85), Vector3(x, 0.69, 0), tint)
		for z in [-1.0, 1.0]:
			_box(body, Vector3(0.11, 0.61, 0.07), Vector3(x, 0.34, z * size * 0.41), tint.darkened(0.29))
	_box(body, Vector3(size * 0.61, 0.06, 0.13), Vector3(0, 0.665, 0), INK)
	var weight := _label(root, "2" if heavy else "1", Vector3(0, 0.87, 0), 35, 0.023, tint)
	var owner_ring := _ring(root, size * 0.70, 0.077, SEAFOAM, 0.064)
	var drift_ring := _ring(root, size * 0.69, 0.073, DRIFT, 0.063, true)
	var rope_shadow := _box(self, Vector3.ONE, Vector3.ZERO, INK, true)
	var rope := _box(self, Vector3.ONE, Vector3.ZERO, SEAFOAM, true)
	var midpoint := _label(self, "", Vector3.ZERO, 27, 0.023, WARNING)
	return {"heavy": heavy, "root": root, "body": body, "owner_ring": owner_ring, "drift_ring": drift_ring,
		"weight": weight, "rope": rope, "rope_shadow": rope_shadow, "midpoint": midpoint}

func update_visuals(state: RefCounted, delta: float, own_slot: int = 0) -> void:
	if state == null:
		return
	var fresh := _state != state
	if fresh:
		_clear_crates()
	_state = state
	_clock += delta
	var ease := 1.0 if fresh or not client_motion else 1.0 - exp(-30.0 * delta)
	for slot in Model.SEATS:
		_render_boat(slot, state, own_slot, ease)
		_render_harbor(slot, state)
	_render_cargo(state, ease)
	_render_targets(state, own_slot)

func _render_boat(slot: int, state: RefCounted, own_slot: int, ease: float) -> void:
	var visual := _boats[slot]
	var boat: Dictionary = state.players[slot]
	var local := _local(slot, own_slot)
	var winner := slot == _champion and _menu
	var root: Node3D = visual.root
	root.visible = _champion < 0 or winner or not _menu
	var at: Vector2 = Vector2(0, 1.5) if winner else boat.pos
	root.position = root.position.lerp(_v(at), ease)
	root.scale = Vector3.ONE * (2.65 if winner else 1.0)
	visual.face = lerp_angle(visual.face, PI * 0.15 if winner else boat.face, ease)
	visual.rig.rotation.y = -visual.face
	visual.rig.rotation.z = sin(_clock * 5.0 + slot * 0.47) * 0.040
	var velocity: Vector2 = boat.velocity
	visual.wake.visible = velocity.length_squared() > 0.20 or winner
	visual.trails.visible = visual.wake.visible
	visual.outline.visible = local and not _menu
	visual.label.text = ("%d %s" % [slot + 1, boat.name]) if show_identities or winner else str(slot + 1)
	visual.label.modulate = CREAM if local else Color.WHITE

func _render_harbor(slot: int, state: RefCounted) -> void:
	var visual := _harbors[slot]
	var age := int(state.tick) - int(state.players[slot].bank_tick)
	var flashing := not _menu and age >= 0 and age < 11
	visual.flash.visible = flashing
	visual.flash.scale = Vector3.ONE * (1.0 + float(age) * 0.022) if flashing else Vector3.ONE

func _clear_crates() -> void:
	for visual in _cargo.values():
		_free_crate(visual)
	_cargo.clear()

func _free_crate(visual: Dictionary) -> void:
	for part in ["root", "rope", "rope_shadow", "midpoint"]:
		visual[part].hide()
	_cargo_pool.append(visual)

func _render_cargo(state: RefCounted, ease: float) -> void:
	var known: Dictionary = {}
	for crate in state.crates:
		var id: int = crate.id
		known[id] = true
		var visual: Dictionary = _cargo.get(id, {})
		if visual.is_empty():
			visual = _new_crate(crate.heavy)
			_cargo[id] = visual
			visual.root.position = _v(crate.pos)
		var root: Node3D = visual.root
		root.visible = _champion < 0 or not _menu
		root.position = root.position.lerp(_v(crate.pos), ease)
		var owner: int = crate.owner
		var drift: bool = state.tick < crate.drift_until
		var body: Node3D = visual.body
		body.rotation.y = -float(state.players[owner].face) + PI * 0.08 if owner >= 0 else id * 1.2 + sin(_clock * 1.6 + id) * (0.35 if drift else 0.12)
		body.position.y = sin(_clock * 3.0 + id) * (0.070 if drift else 0.025)
		visual.drift_ring.visible = drift
		visual.drift_ring.rotation.y = _clock * 2.5
		visual.owner_ring.visible = owner >= 0
		if owner >= 0:
			visual.owner_ring.material_override = _paint(Kit.colors[owner], true)
		_render_rope(state, crate, visual)
	for id in _cargo.keys():
		if not known.has(id):
			_free_crate(_cargo[id])
			_cargo.erase(id)

func _render_rope(state: RefCounted, crate: Dictionary, visual: Dictionary) -> void:
	var owner: int = crate.owner
	var towing: bool = owner >= 0 and visual.root.visible
	visual.rope.visible = towing
	visual.rope_shadow.visible = towing
	visual.midpoint.visible = towing and not _menu
	if not towing:
		return
	var guarded: bool = state.line_protected(crate)
	var taut: bool = state.line_taut(crate)
	var tint := SEAFOAM if guarded else (BRASS if taut else NORMAL.darkened(0.26))
	var tug: Node3D = _boats[owner].root
	var start := tug.position
	var end: Vector3 = visual.root.position
	_span(visual.rope_shadow, start, end, 0.52, 0.17)
	_span(visual.rope, start, end, 0.55, 0.096 if taut else 0.063)
	visual.rope.material_override = _paint(tint, true)
	visual.midpoint.position = _v(state.rope_midpoint(crate), 0.69)
	visual.midpoint.text = "◆" if guarded else ("×" if taut else "·")
	visual.midpoint.modulate = SEAFOAM if guarded else WARNING

func _span(mesh: MeshInstance3D, start: Vector3, end: Vector3, height: float, width: float) -> void:
	mesh.position = (start + end) * 0.5 + Vector3.UP * height
	var travel := end - start
	mesh.rotation.y = -atan2(travel.z, travel.x)
	mesh.scale = Vector3(maxf(0.02, travel.length()), 0.045, width)

func _render_targets(state: RefCounted, own_slot: int) -> void:
	var used: Dictionary = {}
	for slot in Model.SEATS:
		var visual := _targets[slot]
		visual.root.hide()
		if _menu or not _local(slot, own_slot):
			continue
		var target: Dictionary = state.action_target(slot)
		var kind: String = target.kind
		if kind == "idle":
			continue
		visual.root.show()
		visual.root.position = _v(target.at)
		var tint: Color = TARGET_COLORS[kind]
		var ring_scale := 0.68 if kind == "cut" else (2.0 if kind == "deliver" else 1.0)
		visual.ring.scale = Vector3.ONE * (ring_scale + sin(_clock * 6.1) * 0.10)
		visual.ring.material_override = _paint(Kit.colors[slot].lightened(0.34) if local_mask != 0 else tint, true)
		var index := "%d " % (slot + 1) if local_mask != 0 else ""
		visual.caption.text = index + kind.to_upper()
		visual.caption.modulate = tint
		# Separate captions even when two local players target the same object.
		var count := int(used.get(target.at, 0))
		used[target.at] = count + 1
		visual.caption.position.y = 2.00 + count * 0.85

func _local(slot: int, own_slot: int) -> bool:
	return slot == own_slot or (local_mask & (1 << slot)) != 0

func _group(parent: Node3D, at: Vector2) -> Node3D:
	var node := Node3D.new()
	node.position = _v(at)
	parent.add_child(node)
	return node

func _label(parent: Node3D, caption: String, at: Vector3, points: int, scale: float, tint: Color) -> Label3D:
	var label := Label3D.new()
	label.position = at
	label.text = caption
	label.font = Kit.heavy
	label.font_size = points
	label.pixel_size = scale
	label.outline_size = 12
	label.outline_modulate = INK
	label.modulate = tint
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	parent.add_child(label)
	return label

func _ring(parent: Node3D, radius: float, width: float, tint: Color, height: float, dashed := false) -> MeshInstance3D:
	var strips := SurfaceTool.new()
	strips.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 64:
		if dashed and i % 8 >= 4:
			continue
		var a := Vector2.from_angle(TAU * i / 64.0)
		var b := Vector2.from_angle(TAU * (i + 1) / 64.0)
		for point in [a * (radius - width), b * (radius - width), a * radius,
				b * (radius - width), b * radius, a * radius]:
			strips.add_vertex(_v(point, height))
	return _mesh(parent, strips.commit(), _paint(tint, true))

func _hull_mesh(outline: PackedVector2Array, bottom: float, top: float) -> ArrayMesh:
	var strips := SurfaceTool.new()
	strips.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in outline.size():
		var a := outline[i]
		var b := outline[(i + 1) % outline.size()]
		for point in [_v(a * 0.82, bottom), _v(b, top), _v(a, top),
				_v(a * 0.82, bottom), _v(b * 0.82, bottom), _v(b, top),
				Vector3.UP * top, _v(a, top), _v(b, top)]:
			strips.add_vertex(point)
	strips.generate_normals()
	return strips.commit()

func _paint(tint: Color, unshaded := false) -> StandardMaterial3D:
	var key := Vector2i(tint.to_rgba32(), int(unshaded))
	if not _materials.has(key):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = tint
		mat.roughness = 0.88
		if unshaded:
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_materials[key] = mat
	return _materials[key]

func _mesh(parent: Node3D, shape: Mesh, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = shape
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(node)
	return node

func _box(parent: Node3D, dimensions: Vector3, at: Vector3, tint: Color, unshaded := false) -> MeshInstance3D:
	var shape := BoxMesh.new()
	shape.size = dimensions
	var node := _mesh(parent, shape, _paint(tint, unshaded))
	node.position = at
	return node

func _cylinder(parent: Node3D, radius: float, height: float, at: Vector3, tint: Color, unshaded := false, segments := 12) -> MeshInstance3D:
	var shape := CylinderMesh.new()
	shape.top_radius = radius
	shape.bottom_radius = radius
	shape.height = height
	shape.radial_segments = segments
	var node := _mesh(parent, shape, _paint(tint, unshaded))
	node.position = at
	return node

static func _v(at: Vector2, height := 0.0) -> Vector3:
	return Vector3(at.x, height, at.y)
