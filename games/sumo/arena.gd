extends Node3D
## Raised sand dohyo with a pale boundary stripe and a recessed steel catch pit.

const Model = preload("res://games/sumo/model.gd")
const Fighter = preload("res://games/sumo/fighter.gd")
const Art = preload("res://scripts/arena_kit.gd")
const UI = preload("res://scripts/ui_kit.gd")

const SIDES := 120
const SAND := """
shader_type spatial;
render_mode unshaded, shadows_disabled;
uniform float edge;
varying vec2 at;
void vertex() { at = VERTEX.xz; }
void fragment() {
	float r = length(at);
	float a = atan(at.y, at.x);
	float aa = max(fwidth(r) * 0.66, 0.005);
	float stripe = smoothstep(edge - 0.14 - aa, edge - 0.14 + aa, r);
	float apron = smoothstep(edge - 0.64 - aa, edge - 0.64 + aa, r);
	float weave = sin(at.y * 122.0 + sin(at.x * 44.0)) * sin(at.x * 99.0) * 0.025;
	weave *= 1.0 - smoothstep(0.025, 0.08, aa);
	float rake = sin(r * 32.0 + sin(a * 16.0) * 0.11) * 0.011;
	vec3 sand = mix(vec3(0.76, 0.60, 0.40), vec3(0.53, 0.39, 0.26), smoothstep(0.8, edge, r));
	sand += rake + weave;
	vec3 clay = mix(vec3(0.53, 0.24, 0.17), vec3(0.73, 0.37, 0.22), smoothstep(edge - 0.61, edge, r));
	clay += weave * 0.6;
	float marks = smoothstep(0.83, 0.96, cos(a * 48.0))
		* smoothstep(edge - 0.45, edge - 0.41, r) * (1.0 - smoothstep(edge - 0.26, edge - 0.24, r));
	clay = mix(clay, vec3(0.97, 0.66, 0.41), marks * 0.78);
	vec3 straw = vec3(1.0, 0.89, 0.64) * (0.96 + 0.04 * cos(a * 240.0));
	ALBEDO = mix(mix(sand, clay, apron), straw, stripe);
}
"""

const PIT := """
shader_type spatial;
render_mode unshaded, shadows_disabled;
uniform bool detail = true;
uniform float clock = 0.0;
varying vec2 at;
void vertex() { at = VERTEX.xz; }
void fragment() {
	float r = length(at);
	float a = atan(at.y, at.x);
	float aa = max(fwidth(r), 0.01);
	vec3 col = mix(vec3(0.043, 0.077, 0.094), vec3(0.084, 0.16, 0.18), smoothstep(5.0, 8.6, r));
	col *= 1.0 - 0.68 * smoothstep(9.0, 17.0, r);
	float halo = exp(-abs(r - 6.4) * 1.35) * (0.8 + 0.2 * cos(a * 9.0 + clock * 2.2));
	col += vec3(0.02, 0.15, 0.16) * halo;
	if (detail) {
		vec2 cell = abs(fract(at * 0.69 + 0.5) - 0.5);
		float seam = 1.0 - smoothstep(0.008, 0.032, min(cell.x, cell.y));
		col *= 1.0 - seam * 0.26;
	}
	float rail = 1.0 - smoothstep(0.045, 0.045 + aa, abs(r - 8.15));
	float stepper = smoothstep(-0.50, -0.21, cos(a * 36.0));
	float inset = (1.0 - smoothstep(0.025, 0.025 + aa, abs(r - 7.91))) * stepper;
	ALBEDO = col + vec3(0.086, 0.23, 0.23) * rail + vec3(0.06, 0.145, 0.14) * inset;
}
"""

var camera: Camera3D
var local_mask := 0
var show_identities := false
var client_motion := false

var _menu := true
var _inset := 0.0
var _clock := 0.0
var _level := "balanced"
var _fighters: Array[Node3D] = []
var _pit: ShaderMaterial
var _state: RefCounted
var _champion := -1
var _finish_age := 0.0

func _ready() -> void:
	UI.setup()
	_build_camera()
	_build_dohyo()
	for i in Model.SEATS:
		var fighter := Fighter.new()
		fighter.name = "Robot%d" % (i + 1)
		add_child(fighter)
		fighter.setup(i)
		_fighters.append(fighter)
	set_level(_level)
	get_viewport().size_changed.connect(_frame_camera)
	_frame_camera()

func set_menu(on: bool) -> void:
	_menu = on
	show_identities = false
	_frame_camera()

func set_inset(value: float) -> void:
	_inset = clampf(value, 0.0, 0.83)
	_frame_camera()

func set_level(value: String) -> void:
	_level = value
	if _pit != null:
		_pit.set_shader_parameter("detail", value != "low")
	for fighter in _fighters:
		fighter.set_level(value)

func celebrate(slot: int) -> void:
	_champion = slot

func _build_camera() -> void:
	var room := Environment.new()
	room.background_mode = Environment.BG_COLOR
	room.background_color = Color("0b151c")
	room.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	room.ambient_light_color = Color("cee9f4")
	room.ambient_light_energy = 0.73
	camera = Camera3D.new()
	camera.environment = room
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.near = 0.5
	camera.far = 80.0
	add_child(camera)
	camera.position = Vector3(0, 31, 20)
	camera.look_at(Vector3.ZERO)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-53, -32, 0)
	key.light_color = Color("ffe1be")
	key.light_energy = 1.36
	add_child(key)

func _frame_camera() -> void:
	if camera == null:
		return
	var screen := get_viewport().get_visible_rect().size
	var aspect := screen.x / maxf(screen.y, 1.0)
	if _menu:
		camera.size = maxf(16.3, 13.4 / maxf((1.0 - _inset) * aspect, 0.12))
		camera.h_offset = -_inset * camera.size * aspect * 0.5
		camera.v_offset = -0.15
	else:
		camera.size = maxf(14.2, 13.0 / maxf(aspect, 0.12))
		camera.h_offset = 0.0
		camera.v_offset = -0.15

func _build_dohyo() -> void:
	var r := Model.RADIUS
	var batch := Art.Batch.new()
	# Cut the playing surface at the collision radius. Below it, a chamfer
	# and a band of oxidised panels give the drop a visible height.
	for i in SIDES:
		var a := i * TAU / SIDES
		var b := (i + 1) * TAU / SIDES
		batch.tri("sand", Vector3.ZERO, _point(r, 0.0, a), _point(r, 0.0, b), Vector3.UP, Color.WHITE)
		_band(batch, "body", r, -0.08, r, 0.0, a, b, Color("d78d50"))
		_band(batch, "body", r - 0.10, -0.20, r, -0.08, a, b, Color("a44636"))
		var steel := Color("253941") if i % 5 < 4 else Color("182930")
		_band(batch, "body", r - 0.10, -0.95, r - 0.10, -0.20, a, b, steel)
		_band(batch, "body", r - 0.05, -1.09, r - 0.10, -0.95, a, b, Color("3b5258"))
		_band(batch, "body", r + 0.19, -1.31, r - 0.05, -1.09, a, b, Color("1d292e"))
		_band(batch, "body", r + 0.22, Fighter.PIT_Y, r + 0.19, -1.31, a, b, Color("15252c"))
		if i % 5 < 3:
			_band(batch, "accent", r - 0.085, -0.48, r - 0.085, -0.43, a, b, Color("e9894b"))

	for i in 24:
		var a := (i + 0.5) * TAU / 24.0
		var pose := Transform3D(Basis(Vector3.UP, PI * 0.5 - a), _point(r - 0.02, -0.78, a))
		batch.box("body", pose, Vector3(0.32, 0.15, 0.11), 0.027, Color("465c62"))

	# The two shikiri lines are parallel to the entry axis.
	for side in [-1.0, 1.0]:
		var pos := Vector3(side * 0.48, 0.004, 0.0)
		batch.box("accent", Transform3D(Basis.IDENTITY, pos), Vector3(0.11, 0.010, 1.48), 0.004, Color("ffdfad"))
	# Cooling slots and arrow-painted barriers surround the recessed catch pit.
	for i in 20:
		var a := i * TAU / 20.0
		var basis := Basis(Vector3.UP, PI * 0.5 - a)
		batch.box("body", Transform3D(basis, _point(9.72, -1.12, a)), Vector3(1.92, 0.88, 0.43), 0.075, Color("21353f"))
		batch.box("accent", Transform3D(basis, _point(9.47, -0.94, a)), Vector3(1.29, 0.07, 0.065), 0.03, Color("3f8180"))
		for side in [-1.0, 1.0]:
			var anchor: Vector3 = _point(9.7, -1.18, a) + basis.x * side * 0.78
			batch.box("body", Transform3D(basis, anchor), Vector3(0.18, 0.94, 0.64), 0.035, Color("3d535a"))
	var accent := StandardMaterial3D.new()
	accent.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	accent.vertex_color_use_as_albedo = true
	for part in batch.commit(self, {"sand": Art.shader_material(SAND, {"edge": r}),
			"body": Art.shader_material(Art.SOLID_SHADER, {"bounce_power": 0.14}), "accent": accent}):
		part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var plane := PlaneMesh.new()
	plane.size = Vector2(140.0, 140.0)
	_pit = Art.shader_material(PIT, {"detail": _level != "low"})
	var floor_mesh := MeshInstance3D.new()
	floor_mesh.mesh = plane
	floor_mesh.material_override = _pit
	floor_mesh.position.y = Fighter.PIT_Y
	floor_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(floor_mesh)

func _band(batch: Art.Batch, key: String, outer_low: float, low: float, outer_high: float,
		high: float, from: float, to: float, paint: Color) -> void:
	batch.quad(key, _point(outer_low, low, from), _point(outer_low, low, to),
		_point(outer_high, high, to), _point(outer_high, high, from), _point(1.0, 0.0, (from + to) * 0.5), paint)

func _point(radius: float, height: float, angle: float) -> Vector3:
	return Vector3(cos(angle) * radius, height, sin(angle) * radius)

func update_visuals(state: RefCounted, delta: float, own_slot: int = 0) -> void:
	_clock += delta
	_pit.set_shader_parameter("clock", _clock)
	var fresh := state != _state
	if fresh:
		_champion = -1
		_finish_age = 0.0
	_state = state
	if state == null:
		return
	if state.phase == "finished":
		_finish_age += delta
	var render_tick: int = state.tick + roundi(_finish_age * Model.HZ)
	for i in _fighters.size():
		var fighter := _fighters[i]
		var victory := i == _champion
		fighter.visible = _champion < 0 or victory
		if not fighter.visible:
			continue
		var p: Dictionary = state.players[i]
		var own := i == own_slot or (local_mask & (1 << i)) != 0
		var tag := ""
		if victory:
			p = {"alive": true, "pos": Vector2.ZERO, "velocity": Vector2.ZERO,
				"face": PI * 0.5, "gait": 0.0, "planted": false,
				"strike_tick": Model.NEVER, "respawn_tick": Model.NEVER,
				"guard_until": 0, "hit_tick": Model.NEVER}
			tag = str(state.players[i].name)
		elif show_identities:
			tag = "%d  %s" % [i + 1, p.name]
		elif own:
			tag = "YOU  %d" % (i + 1) if local_mask == 0 else "P%d" % (i + 1)
		fighter.render(p, render_tick, delta, _clock, fresh, own, tag, victory, client_motion)
