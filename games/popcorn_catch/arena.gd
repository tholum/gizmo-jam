extends Node3D
## Orthographic toy cabinet with reusable bowls, forecast markers and effects.

const M = preload("res://games/popcorn_catch/model.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const Board = preload("res://games/popcorn_catch/board.gdshader")
const Floor = preload("res://games/popcorn_catch/cabinet_floor.gdshader")
const Marker = preload("res://games/popcorn_catch/marker.gdshader")
const Bowl = preload("res://games/popcorn_catch/bowl.gdshader")
const CREAM := Color("fff0be")
const GOLD := Color("ffc967")
const COCOA := Color("20171b")
const R := M.FIELD_RADIUS
const SHELF_GLOW := Color("ffe0a0")
const TARGET_GLOW := Color("fff6db")
const CENTER_GLOW := Color("ffd374")
const SHADOW := Color("071619")

var camera: Camera3D
var local_mask := 0
var show_identities := false
var client_motion := false

var _menu := true
var _inset := 0.0
var _level := "balanced"
var _round_id := 0
var _clock := 0.0
var _visual_tick := 0.0
var _champion := -1
var _state: RefCounted
var _board: ShaderMaterial
var _corn: ArrayMesh
var _corn_paint: StandardMaterial3D
var _shadow_paint: StandardMaterial3D
var _bowls: Array[Dictionary] = []
var _shelves: Array[Dictionary] = []
var _targets: Dictionary = {}
var _target_pool: Array[Dictionary] = []

func _ready() -> void:
	Kit.setup()
	_setup_camera()
	_build_cabinet()
	_build_corn()
	for slot in M.SEATS:
		_build_shelf(slot)
		_build_bowl(slot)
	get_viewport().size_changed.connect(_frame_camera)
	_frame_camera()
	set_level(_level)

func set_menu(on: bool) -> void:
	_menu = on
	show_identities = false
	if not on:
		_champion = -1
	_frame_camera()

func set_inset(value: float) -> void:
	_inset = clampf(value, 0.0, 0.8)
	_frame_camera()

func set_level(value: String) -> void:
	_level = value
	if _board:
		_board.set_shader_parameter("detail", value != "low")

func celebrate(slot: int) -> void:
	_champion = slot

func _setup_camera() -> void:
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.near = 0.5
	camera.far = 120.0
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = SHADOW
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("ffeedc")
	environment.ambient_light_energy = 0.78
	camera.environment = environment
	add_child(camera)
	camera.position = Vector3(0, 39, 19.3)
	camera.look_at(Vector3.ZERO)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-47, 31, 0)
	sun.light_color = Color("fff2dc")
	sun.light_energy = 1.14
	add_child(sun)
	var bounce := DirectionalLight3D.new()
	bounce.rotation_degrees = Vector3(-23, -136, 0)
	bounce.light_color = Color("a2e2e5")
	bounce.light_energy = 0.32
	add_child(bounce)

func _frame_camera() -> void:
	if camera == null:
		return
	var view := get_viewport().get_visible_rect().size
	var aspect := view.x / maxf(1.0, view.y)
	var inset := _inset if _menu else 0.0
	camera.size = maxf(27.65 if _menu else 26.7, 28.1 / maxf((1.0 - inset) * aspect, 0.18))
	camera.h_offset = -inset * camera.size * aspect * 0.5
	camera.v_offset = -0.36 if _menu else -0.10

func _build_cabinet() -> void:
	_mesh(self, _quad(130.0), _shader(Floor), Vector3(0, -2.04, 0))
	var red := _paint(Color("b32b3d"), 0.24, 0.33)
	var lacquer := _paint(Color("e24b48"), 0.15, 0.27)
	var low_red := _paint(Color("77212d"), 0.30, 0.40)
	var gold := _paint(Color("d09446"), 0.46, 0.30)
	var light_gold := _paint(Color("f9c97e"), 0.33, 0.29)
	var enamel := _paint(Color("341d28"), 0.21, 0.42)
	_mesh(self, _profile([
		Vector2(10.7, -1.93), Vector2(11.28, -1.89), Vector2(11.69, -1.69),
		Vector2(11.87, -1.43), Vector2(11.99, -0.85), Vector2(12.03, -0.41),
		Vector2(11.92, -0.27)], 120), red, Vector3.ZERO)
	_mesh(self, _profile([
		Vector2(10.86, -1.98), Vector2(11.32, -1.91), Vector2(11.66, -1.75),
		Vector2(11.80, -1.58)], 120), low_red, Vector3.ZERO)
	_mesh(self, _profile([
		Vector2(11.68, -0.40), Vector2(12.03, -0.40), Vector2(12.16, -0.31),
		Vector2(12.17, -0.16), Vector2(12.10, 0.02), Vector2(12.02, 0.09),
		Vector2(11.77, 0.13), Vector2(11.56, 0.11)], 120), lacquer, Vector3.ZERO)
	_ring(self, 11.40, 11.57, 0.093, enamel, 120)
	_ring(self, 11.54, 11.83, 0.132, gold, 120)
	_ring(self, 11.79, 11.84, 0.139, light_gold, 120)
	_mesh(self, _profile([
		Vector2(11.35, -0.02), Vector2(11.39, 0.060), Vector2(11.45, 0.112),
		Vector2(11.55, 0.132)], 120), gold, Vector3.ZERO)
	_board = _shader(Board)
	_disk(self, R + 0.012, R + 0.012, 0.06, Vector3(0, -0.03, 0), _board, 120)
	_mesh(self, _profile([
		Vector2(11.94, -1.01), Vector2(12.01, -0.88), Vector2(12.015, -0.804)], 120), gold, Vector3.ZERO)
	var bolt := CylinderMesh.new()
	bolt.top_radius = 0.084
	bolt.bottom_radius = 0.106
	bolt.height = 0.042
	bolt.radial_segments = 10
	for i in 36:
		var angle := TAU * (i + 0.5) / 36.0
		_mesh(self, bolt, light_gold, _v(Vector2.from_angle(angle) * 11.95, 0.108))
	_build_sign(gold, enamel)
	for side in [-1.0, 1.0]:
		_build_handle(side, lacquer, low_red, gold, enamel)
	_shadow_paint = _soft_shadow()

func _build_handle(side: float, red: Material, deep_red: Material, brass: Material, enamel: Material) -> void:
	var grip := Node3D.new()
	add_child(grip)
	grip.position = Vector3(side * 12.02, -0.48, 0.0)
	for z in [-1.46, 1.46]:
		_box(grip, Vector3(1.57, 0.41, 0.42), Vector3(side * 0.46, -0.16, z), deep_red)
		_disk(grip, 0.19, 0.22, 0.065, Vector3(side * 0.87, 0.08, z), brass, 16)
	_box(grip, Vector3(0.63, 0.58, 3.42), Vector3(side * 1.08, -0.05, 0.0), red)
	_box(grip, Vector3(0.59, 0.07, 2.45), Vector3(side * 1.08, 0.257, 0.0), enamel)
	for i in 9:
		_box(grip, Vector3(0.53, 0.043, 0.045), Vector3(side * 1.08, 0.316, (i - 4) * 0.25), brass)

func _build_sign(gold: Material, enamel: Material) -> void:
	var plate := Node3D.new()
	add_child(plate)
	plate.position = Vector3(0, 0.16, 11.31)
	# A brass nameplate follows the lip of the cabinet.
	_box(plate, Vector3(7.72, 0.15, 0.84), Vector3.ZERO, gold)
	_box(plate, Vector3(7.41, 0.08, 0.66), Vector3.UP * 0.10, enamel)
	var wordmark := _label(plate, "P O P C O R N   C A T C H", 54, 0.0091, CREAM)
	wordmark.position.y = 0.158
	wordmark.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	wordmark.rotation_degrees.x = -90.0
	wordmark.outline_size = 3
	for side in [-1.0, 1.0]:
		_disk(plate, 0.095, 0.095, 0.035, Vector3(side * 3.48, 0.165, 0), gold, 14)

func _build_corn() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 8
	sphere.rings = 4
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for lobe in [
		[Vector3(0.02, -0.13, 0), Vector3(0.63, 0.60, 0.67)],
		[Vector3(0.42, 0.13, 0.10), Vector3(0.41, 0.43, 0.43)],
		[Vector3(-0.38, 0.04, -0.22), Vector3(0.46, 0.52, 0.42)],
		[Vector3(-0.07, 0.43, 0.15), Vector3(0.50, 0.43, 0.42)],
		[Vector3(0.22, 0.00, -0.36), Vector3(0.40, 0.50, 0.41)],
		[Vector3(-0.21, 0.06, 0.39), Vector3(0.38, 0.39, 0.34)],
	]:
		tool.append_from(sphere, 0, Transform3D(Basis.from_scale(lobe[1]), lobe[0]))
	_corn = tool.commit()
	_corn_paint = _paint(Color("ffe399"), 0.0, 0.68)

func _build_shelf(slot: int) -> void:
	var root := Node3D.new()
	add_child(root)
	var at := M.shelf(slot)
	root.position = _v(at)
	root.rotation.y = -at.angle() - PI * 0.5
	var radius := M.SHELF_RADIUS
	var bronze := _paint(Color("b8773a"), 0.52, 0.33)
	var rim := _paint(Color("ffe09a"), 0.36, 0.28)
	var inner := _paint(Color("3b2830"), 0.21, 0.64)
	_disk(root, radius, radius, 0.048, Vector3.UP * 0.025, bronze)
	_disk(root, radius * 0.86, radius * 0.86, 0.052, Vector3.UP * 0.033, inner)
	_ring(root, radius * 0.87, radius * 0.99, 0.066, rim)
	for i in 7:
		var z := (i - 3) * 0.27
		var w := sqrt((radius * 0.81) ** 2 - z * z) * 2.0
		_box(root, Vector3(w, 0.014, 0.025), Vector3(0, 0.068, z), bronze)
	for x in [-0.32, 0.32]:
		_box(root, Vector3(0.13, 0.085, 0.31), Vector3(x, 0.054, -radius * 0.97), rim)
	var word := _label(root, "BANK", 44, 0.016, SHELF_GLOW)
	word.position = Vector3(0, 0.38, 0.03)
	var pulse := _shader(Marker)
	pulse.set_shader_parameter("settled", true)
	pulse.set_shader_parameter("caught", true)
	pulse.set_shader_parameter("tint", SHELF_GLOW)
	var shimmer := _mesh(root, _quad(radius * 3.25), pulse, Vector3.UP * 0.18)
	shimmer.hide()
	var call := _label(self, "", 76, 0.0114, CREAM)
	call.hide()
	_shelves.append({"shimmer": shimmer, "pulse": pulse, "call": call, "at": at})

func _build_bowl(slot: int) -> void:
	var tint: Color = Kit.colors[slot]
	var root := Node3D.new()
	add_child(root)
	_mesh(root, _quad(2.85), _shadow_paint, Vector3(0.11, 0.018, 0.12))
	var cup := Node3D.new()
	root.add_child(cup)
	var pattern := _shader(Bowl)
	pattern.set_shader_parameter("paint", tint)
	_mesh(cup, _profile([Vector2(0.49, 0.055), Vector2(0.59, 0.11), Vector2(0.78, 0.54),
		Vector2(0.90, 0.83), Vector2(0.94, 0.88)], 40), pattern, Vector3.ZERO)
	var inside := _paint(tint.darkened(0.56), 0.10, 0.51)
	_mesh(cup, _profile([Vector2(0.44, 0.14), Vector2(0.77, 0.76), Vector2(0.88, 0.865)], 40), inside, Vector3.ZERO)
	_disk(cup, 0.46, 0.49, 0.045, Vector3.UP * 0.15, inside)
	_mesh(cup, _profile([Vector2(0.86, 0.86), Vector2(0.94, 0.855), Vector2(0.97, 0.894),
		Vector2(0.957, 0.94), Vector2(0.90, 0.960), Vector2(0.86, 0.930)], 40),
		_paint(tint.lightened(0.42), 0.10, 0.34), Vector3.ZERO)
	var catch_edge := _ring(root, M.CATCH_RADIUS - 0.02, M.CATCH_RADIUS + 0.027, 0.032,
		_paint(tint.lightened(0.51), 0.0, 0.80, true), 36)
	var kernels: Array[MeshInstance3D] = []
	for i in M.WOBBLE:
		var at := Vector2.from_angle(i * TAU / M.WOBBLE) * 0.386
		var corn := _mesh(cup, _corn, _corn_paint, _v(at, 0.41 + 0.10 * (i % 2)))
		corn.rotation.y = i * 1.48
		corn.scale = Vector3.ONE * 0.324
		kernels.append(corn)
	var number := _label(cup, str(slot + 1), 65, 0.0121, CREAM)
	number.position = Vector3(0, 1.19, 0.59)
	number.outline_size = 14
	var name_plate := _label(root, "", 54, 0.010, CREAM)
	name_plate.position = Vector3(0, 0.66, 1.07)
	name_plate.hide()
	var local_marker := _label(root, "▼", 62, 0.0105, CREAM)
	local_marker.position = Vector3(0, 0.92, -0.93)
	local_marker.hide()
	var feedback := _label(root, "", 70, 0.012, CREAM)
	feedback.hide()
	var sparks: Array[MeshInstance3D] = []
	for i in 4:
		var particle := _mesh(root, _corn, _corn_paint, Vector3.ZERO)
		particle.scale = Vector3.ONE * 0.17
		particle.hide()
		sparks.append(particle)
	_bowls.append({"root": root, "cup": cup, "pattern": pattern, "kernels": kernels,
		"tag": name_plate, "local": local_marker, "feedback": feedback, "sparks": sparks,
		"edge": catch_edge, "pos": Vector2.ZERO})

func _new_target() -> Dictionary:
	var root := Node3D.new()
	add_child(root)
	var marker := _shader(Marker)
	var site := _mesh(root, _quad(M.CATCH_RADIUS * 2.0 / 0.68), marker, Vector3.UP * 0.042)
	site.sorting_offset = 0.12
	var corn := _mesh(root, _corn, _corn_paint, Vector3.ZERO)
	var steam := _mesh(root, _quad(1.37), _soft_shadow(Color(1.0, 0.88, 0.57, 0.38)), Vector3.UP * 0.013)
	return {"root": root, "marker": marker, "corn": corn, "steam": steam}

func update_visuals(state: RefCounted, delta: float, own_slot: int = -1) -> void:
	if state == null:
		return
	var fresh: bool = _state != state or _round_id != state.round_id
	_state = state
	_round_id = state.round_id
	_clock += delta
	var ease := 1.0 if fresh or not client_motion else (1.0 - exp(-31.0 * delta))
	if fresh or not client_motion or state.phase != "running":
		_visual_tick = state.tick
	else:
		_visual_tick = clampf(_visual_tick + delta * M.HZ, state.tick - 1.0, state.tick + 3.0)
	var burst_age: float = (state.tick - state.burst_tick) * M.STEP
	var burst := (1.0 - smoothstep(0.45, 2.35, burst_age)) * (0.85 + 0.15 * sin(_clock * 11.0))
	_board.set_shader_parameter("burst", burst)
	_render_targets(state, fresh)
	_render_shelves(state)
	_render_bowls(state, ease, own_slot)

func _render_targets(state: RefCounted, fresh: bool) -> void:
	for id in _targets.keys():
		if fresh or not state.drops.any(func(drop): return drop.id == id):
			var old: Dictionary = _targets[id]
			old.root.hide()
			_target_pool.append(old)
			_targets.erase(id)
	for drop in state.drops:
		if not _targets.has(drop.id):
			_targets[drop.id] = _new_target() if _target_pool.is_empty() else _target_pool.pop_back()
		var visual: Dictionary = _targets[drop.id]
		var landed: bool = state.tick >= drop.land
		var caught: bool = drop.winner >= 0
		var progress := clampf((_visual_tick - float(drop.born)) / float(drop.land - drop.born), 0.0, 1.0)
		var age := clampf((_visual_tick - float(drop.land)) / M.MARK_TIME, 0.0, 1.0)
		var tint := CENTER_GLOW if drop.center else TARGET_GLOW
		if landed:
			tint = Kit.colors[drop.winner].lightened(0.65) if caught else Color("e1c8a6")
		visual.root.position = _v(drop.pos)
		visual.root.show()
		visual.marker.set_shader_parameter("tint", tint)
		visual.marker.set_shader_parameter("progress", progress)
		visual.marker.set_shader_parameter("center_drop", drop.center)
		visual.marker.set_shader_parameter("settled", landed)
		visual.marker.set_shader_parameter("caught", caught)
		visual.marker.set_shader_parameter("pulse", age)
		visual.corn.visible = not landed or (not caught and age < 0.60)
		if not landed:
			var height := 0.50 + 4.4 * (1.0 - progress ** 2.5)
			var bend := sin(PI * progress) * 0.45
			visual.corn.position = Vector3(cos(drop.id * 2.1) * bend, height, sin(drop.id * 2.1) * bend)
			visual.corn.rotation = Vector3(progress * TAU, drop.id + progress * 8.0, progress * 3.2)
			visual.corn.scale = Vector3.ONE * (0.28 + 0.17 * progress)
		elif visual.corn.visible:
			visual.corn.position = Vector3(age, 0.22 + sin(age * PI / 0.6) * 0.53, age * 0.7)
			visual.corn.rotation.z = age * 10.0
			visual.corn.scale = Vector3.ONE * lerpf(0.39, 0.0, age / 0.6)
		visual.steam.visible = not landed and progress < 0.32 and _level != "low"
		if visual.steam.visible:
			visual.steam.scale = Vector3.ONE * lerpf(0.65, 1.7, progress / 0.32)

func _render_shelves(state: RefCounted) -> void:
	for slot in M.SEATS:
		var shelf: Dictionary = _shelves[slot]
		var recent := {}
		for player in state.players:
			if player.active and player.bank_shelf == slot and (recent.is_empty() or player.last_bank > recent.last_bank):
				recent = player
		var age := 1.0 if recent.is_empty() else (float(state.tick - int(recent.last_bank)) / 62.0)
		shelf.shimmer.visible = age < 0.74
		shelf.call.visible = age < 1.0 and not _menu
		if shelf.shimmer.visible:
			shelf.pulse.set_shader_parameter("pulse", age / 0.74)
			shelf.pulse.set_shader_parameter("tint", Kit.colors[recent.slot].lightened(0.63))
		if shelf.call.visible:
			shelf.call.text = ("BIG BANK +%d" if recent.bank_points >= M.BIG_BANK + M.BANK_BONUS else "BANK +%d") % recent.bank_points
			var at: Vector2 = shelf.at
			shelf.call.position = _v(at * (0.85 - 0.06 * age), 0.88 + age * 0.42)
			shelf.call.modulate = Color(CREAM, minf(1.0, (1.0 - age) * 4.0))
			shelf.call.outline_modulate = Color(COCOA, shelf.call.modulate.a)

func _render_bowls(state: RefCounted, ease: float, own_slot: int) -> void:
	for slot in M.SEATS:
		var player: Dictionary = state.players[slot]
		var visual: Dictionary = _bowls[slot]
		visual.root.visible = player.active
		if not player.active:
			continue
		var local: bool = not _menu and ((local_mask & (1 << slot)) != 0 if local_mask else slot == own_slot)
		var wobble: bool = player.carry >= M.WOBBLE
		var caught := int(state.tick) - int(player.last_catch)
		var spilled := int(state.tick) - int(player.last_spill)
		var on_catch := maxf(0.0, 1.0 - caught / 22.0)
		var bump := on_catch * 0.09 * sin(caught * 0.28)
		var shake := sin(_clock * 19.0 + slot) * (0.14 if wobble else 0.0)
		shake += sin(spilled * 1.7) * maxf(0.0, 1.0 - spilled / 20.0) * 0.27
		visual.pos = Vector2(visual.pos).lerp(player.pos, ease)
		visual.root.position = _v(visual.pos)
		visual.edge.visible = local or wobble
		visual.cup.rotation.z = shake
		visual.cup.position.y = bump
		visual.cup.scale = Vector3.ONE * (1.0 + on_catch * 0.045)
		var win_glow := 0.42 + sin(_clock * 5.0) * 0.30 if slot == _champion else 0.0
		visual.pattern.set_shader_parameter("wobble", wobble)
		visual.pattern.set_shader_parameter("flash", maxf(on_catch, win_glow))
		for i in M.WOBBLE:
			visual.kernels[i].visible = i < int(player.carry)
		visual.local.visible = local and not show_identities
		visual.tag.visible = not _menu and show_identities
		if visual.tag.visible:
			visual.tag.text = str(player.name).to_upper()
		var feedback: Label3D = visual.feedback
		var age := spilled if spilled <= 52 else caught
		feedback.visible = not _menu and (spilled <= 52 or caught <= 28 or wobble)
		if feedback.visible:
			var at: Vector2 = visual.pos
			var nudge := -at.normalized() * smoothstep(7.0, 11.0, at.length()) * 0.48
			feedback.position = _v(nudge + Vector2(0, -0.77), 1.1 + minf(1.0, age / 50.0) * 0.34)
			feedback.text = "SPILL −%d" % player.spilled if spilled <= 52 else ("BANK NOW" if wobble else "+1")
			feedback.modulate = GOLD if wobble or spilled <= 52 else CREAM
		var show_sparks := spilled <= 28 or caught <= 16
		for i in visual.sparks.size():
			var particle: MeshInstance3D = visual.sparks[i]
			particle.visible = show_sparks and (i < 2 or _level != "low")
			if particle.visible:
				var scatter := Vector2.from_angle(slot * 0.83 + i * TAU / visual.sparks.size())
				var travel := (float(spilled) / 28.0 if spilled <= 28 else float(caught) / 16.0)
				var arc := sin(PI * travel)
				particle.position = _v(scatter * (0.55 + travel * (1.65 if spilled <= 28 else 0.92)), 0.69 + arc * 0.96)
				particle.rotation = Vector3(travel * 7.0, i, travel * 5.0)
				particle.scale = Vector3.ONE * (0.12 + arc * 0.12)

func _profile(points: Array[Vector2], segments: int) -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for ring in points.size() - 1:
		var lower := points[ring]
		var upper := points[ring + 1]
		var normal := Vector2(upper.y - lower.y, lower.x - upper.x).normalized()
		for i in segments:
			var left := Vector2.from_angle(i * TAU / segments)
			var right := Vector2.from_angle((i + 1) * TAU / segments)
			_vertex(tool, left, lower, normal)
			_vertex(tool, left, upper, normal)
			_vertex(tool, right, upper, normal)
			_vertex(tool, left, lower, normal)
			_vertex(tool, right, upper, normal)
			_vertex(tool, right, lower, normal)
	return tool.commit()

static func _vertex(tool: SurfaceTool, spoke: Vector2, point: Vector2, normal: Vector2) -> void:
	tool.set_normal(_v(spoke * normal.x, normal.y))
	tool.add_vertex(_v(spoke * point.x, point.y))

func _ring(parent: Node3D, inside: float, outside: float, y: float, mat: Material, segments: int = 40) -> MeshInstance3D:
	return _mesh(parent, _profile([Vector2(outside, 0.0), Vector2(inside, 0.0)], segments), mat, Vector3.UP * y)

func _disk(parent: Node3D, top: float, bottom: float, height: float, pos: Vector3, mat: Material,
		segments: int = 40) -> MeshInstance3D:
	var disk := CylinderMesh.new()
	disk.top_radius = top
	disk.bottom_radius = bottom
	disk.height = height
	disk.radial_segments = segments
	disk.rings = 0
	return _mesh(parent, disk, mat, pos)

func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = size
	return _mesh(parent, box, mat, pos)

func _mesh(parent: Node3D, resource: Mesh, mat: Material, pos: Vector3) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.mesh = resource
	mesh.material_override = mat
	mesh.position = pos
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mesh)
	return mesh

func _label(parent: Node3D, caption: String, font_size: int, size: float, tint: Color) -> Label3D:
	var label := Label3D.new()
	label.text = caption
	label.font = Kit.heavy
	label.font_size = font_size
	label.pixel_size = size
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = tint
	label.outline_modulate = COCOA
	label.outline_size = 12
	parent.add_child(label)
	return label

static func _quad(size: float) -> QuadMesh:
	var quad := QuadMesh.new()
	quad.orientation = PlaneMesh.FACE_Y
	quad.size = Vector2.ONE * size
	return quad

static func _shader(shader: Shader) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = shader
	return material

static func _paint(tint: Color, metal: float, rough: float, unshaded: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = tint
	material.metallic = metal
	material.roughness = rough
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if unshaded:
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material

static func _soft_shadow(tint: Color = Color(0.02, 0.05, 0.04, 0.70)) -> StandardMaterial3D:
	var ramp := Gradient.new()
	ramp.colors = PackedColorArray([tint, tint, Color(tint, 0.0)])
	ramp.offsets = PackedFloat32Array([0.0, 0.42, 1.0])
	var texture := GradientTexture2D.new()
	texture.width = 32
	texture.height = 32
	texture.gradient = ramp
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	var material := _paint(Color.WHITE, 0.0, 1.0, true)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_texture = texture
	return material

static func _v(at: Vector2, y: float = 0.0) -> Vector3:
	return Vector3(at.x, y, at.y)
