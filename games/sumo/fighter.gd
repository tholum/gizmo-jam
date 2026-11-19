extends Node3D
## A Meshy runner with Sumo's palm pose, directional tell and floor marks.

const Model = preload("res://games/sumo/model.gd")
const Runner = preload("res://scripts/runner_visual.gd")
const Art = preload("res://scripts/arena_kit.gd")
const UI = preload("res://scripts/ui_kit.gd")

const ATTACK := """
shader_type spatial;
render_mode unshaded, shadows_disabled, depth_draw_never;
uniform float charge = 0.0;
uniform float swing = 0.0;
uniform vec4 tint : source_color;
uniform float reach;
uniform float half_angle;
uniform float ring;
varying vec2 at;
varying vec2 world;
void vertex() {
	at = VERTEX.xz;
	world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}
void fragment() {
	float r = length(at);
	float angle = abs(atan(at.x, max(at.y, 0.0001)));
	float aa = max(fwidth(r), 0.012);
	float band = radians(2.2);
	float wedge = (1.0 - smoothstep(half_angle - band, half_angle, angle))
		* smoothstep(0.34, 0.40, r) * (1.0 - smoothstep(reach - aa, reach, r)) * step(0.0, at.y);
	float rim = max(smoothstep(reach - 0.10, reach - 0.04, r), smoothstep(half_angle - band * 2.5, half_angle - band, angle));
	float wave = 1.0 - smoothstep(0.035, 0.115, abs(r - mix(0.42, reach - 0.04, charge)));
	float centre = (1.0 - smoothstep(0.04, 0.085, abs(at.x))) * smoothstep(1.02, 1.22, r);
	float light = max(max(rim, wave), centre) * (0.50 + charge * 0.38);
	ALBEDO = mix(tint.rgb, vec3(1.0, 0.96, 0.82), max(light * 0.72, swing * 0.82));
	ALPHA = wedge * max(mix(0.15 + charge * 0.10, light, max(max(rim, wave), centre)), swing * 0.74);
	ALPHA *= 1.0 - smoothstep(ring + 0.025, ring + 0.08, length(world));
}
"""

const MARKS := """
shader_type spatial;
render_mode unshaded, shadows_disabled, depth_draw_never;
uniform vec4 tint : source_color;
uniform float planted = 0.0;
uniform float guarded = 0.0;
uniform float hit = 0.0;
uniform float clock = 0.0;
varying vec2 at;
void vertex() { at = VERTEX.xz; }
void fragment() {
	float r = length(at);
	float aa = max(fwidth(r) * 1.15, 0.013);
	float a = atan(at.x, at.y);
	float gap = smoothstep(0.37, 0.51, abs(sin(a)));
	float toe = (1.0 - smoothstep(0.045, 0.045 + aa, abs(r - 0.67))) * gap * planted;
	float shield = (1.0 - smoothstep(0.024, 0.024 + aa, abs(r - 0.77)))
		* smoothstep(0.22, 0.45, cos(8.0 * a + clock * 4.0)) * guarded;
	shield = max(shield, (1.0 - smoothstep(0.025, 0.025 + aa, abs(r - 0.58))) * guarded * 0.65);
	float spark = (1.0 - smoothstep(0.036, 0.076, abs(r - mix(1.18, 0.28, hit))))
		* smoothstep(0.52, 0.87, cos(a * 9.0)) * hit;
	ALBEDO = mix(tint.rgb, vec3(1.0, 0.99, 0.87), max(spark, max(shield * 0.72, toe * 0.64)));
	ALPHA = max(max(shield, toe), spark);
}
"""

const OUT := """
shader_type spatial;
render_mode unshaded, shadows_disabled, depth_draw_never;
uniform float age = 0.0;
uniform vec4 tint : source_color;
varying vec2 at;
void vertex() { at = VERTEX.xz; }
void fragment() {
	float r = length(at);
	float a = atan(at.x, at.y);
	float outer = mix(0.28, 1.55, age);
	float wave = 1.0 - smoothstep(0.034, 0.075, abs(r - outer));
	float rays = smoothstep(0.86, 0.98, cos(a * 10.0))
		* smoothstep(outer - 0.18, outer + 0.04, r) * (1.0 - smoothstep(outer + 0.07, outer + 0.27, r));
	ALBEDO = mix(tint.rgb, vec3(1.0, 0.92, 0.72), rays * 0.66 + wave * 0.19);
	ALPHA = max(wave * 0.7, rays) * (1.0 - age);
}
"""

const FALL_SHOW := 0.64
const PIT_Y := -1.57

var robot: Node3D
var _tag: Label3D
var _cone: MeshInstance3D
var _mark: MeshInstance3D
var _burst: MeshInstance3D
var _cone_material: ShaderMaterial
var _mark_material: ShaderMaterial
var _burst_material: ShaderMaterial
var _arms: Array[PackedInt32Array] = []
var _base_rotations: Dictionary = {}
var _slot := 0
var _shown_pos := Vector2.ZERO
var _shown_face := 0.0
var _fall_age := 0.0
var _was_alive := false

func setup(slot: int) -> void:
	_slot = slot
	var team := UI.colors[slot]
	robot = Runner.new()
	add_child(robot)
	robot.setup(team)
	for side in ["Left", "Right"]:
		var indices := PackedInt32Array()
		for joint in ["Arm", "ForeArm", "Hand"]:
			indices.append(robot.skeleton.find_bone(side + joint))
		if not indices.has(-1):
			_arms.append(indices)
	_cone_material = Art.shader_material(ATTACK, {
		"tint": team.lightened(0.40), "reach": Model.SHOVE_RANGE,
		"half_angle": Model.HALF_ANGLE, "ring": Model.RADIUS})
	_mark_material = Art.shader_material(MARKS, {"tint": team.lightened(0.32)})
	_burst_material = Art.shader_material(OUT, {"tint": team.lightened(0.25)})
	_cone = _plane(Vector2(4.0, 4.0), _cone_material)
	_mark = _plane(Vector2(2.7, 2.7), _mark_material)
	_burst = _plane(Vector2(4.0, 4.0), _burst_material)

	_tag = Label3D.new()
	_tag.font = UI.display
	_tag.font_size = 32
	_tag.outline_size = 12
	_tag.pixel_size = 0.010
	_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_tag.modulate = team.lightened(0.35)
	_tag.outline_modulate = UI.OUTLINE
	_tag.no_depth_test = true
	add_child(_tag)

func _plane(size: Vector2, material: ShaderMaterial) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.orientation = PlaneMesh.FACE_Y
	quad.size = size
	var graphic := MeshInstance3D.new()
	graphic.mesh = quad
	graphic.material_override = material
	graphic.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(graphic)
	return graphic

func set_level(level: String) -> void:
	robot.set_quality(level, 0.64, false)

func render(p: Dictionary, tick: int, delta: float, clock: float, fresh: bool,
		local: bool, identity: String, champion: bool, follow: bool) -> void:
	var alive: bool = p.alive
	var at: Vector2 = p.pos
	var sharp := fresh or alive != _was_alive or not follow
	var ease := 1.0 if sharp else 1.0 - exp(-33.0 * delta)
	_shown_pos = _shown_pos.lerp(at, ease)
	var eta := int(p.strike_tick) - tick
	var windup := alive and eta > 0
	var swing := alive and eta <= 0 and eta > -Model.SWING
	# Snap the tell to the committed facing as soon as windup starts.
	var facing_weight := 1.0 if windup or swing else ease
	_shown_face = lerp_angle(_shown_face, p.face, facing_weight)
	var heading := PI * 0.5 - _shown_face
	var age := (tick + Model.RESPAWN - int(p.respawn_tick)) * Model.STEP
	_fall_age = 0.0 if alive else maxf(age, 0.0 if fresh else _fall_age + delta)
	var falling := not alive and _fall_age < FALL_SHOW
	var drift := Vector2.ZERO if alive else (p.velocity as Vector2).limit_length(5.6) * _fall_age * 0.72
	var height := 0.0 if alive else -8.6 * _fall_age * _fall_age
	robot.visible = alive or falling
	robot.position = Vector3(_shown_pos.x + drift.x, height, _shown_pos.y + drift.y)
	robot.rotation.y = heading
	robot.set_markers(alive)
	robot.set_ring(local, 0.0)

	var charge := clampf(1.0 - float(eta) / Model.WINDUP, 0.0, 1.0)
	var strike := 1.0 - clampf(float(-eta) / Model.SWING, 0.0, 1.0)
	var guarded := alive and tick < int(p.guard_until)
	var hit := clampf(1.0 - float(tick - int(p.hit_tick)) / Model.HIT_FLASH, 0.0, 1.0)
	var planted: bool = p.planted and not guarded
	var gait: float = p.gait
	if robot.visible:
		_restore_arms()
		var mode := "run" if gait > 0.48 and not (windup or swing) else "idle"
		if champion and alive:
			mode = "victory"
		elif falling:
			mode = "down"
		robot.pose(delta, {"mode": mode, "speed": 0.46 + gait * 0.15, "flash": hit})
		robot.body.rotation.x = (-0.10 if planted else 0.0) - (0.24 * charge if windup else 0.0)
		robot.body.rotation.x += 0.36 * strike if swing else 1.34 * _fall_age
		robot.body.rotation.z = 1.65 * _fall_age * (1.0 if _slot % 2 == 0 else -1.0)
		if windup or swing:
			_pose_palms(0.42 + charge * 0.58 if windup else strike, swing)
		if guarded:
			robot.material.set_shader_parameter("flash", 0.12 + 0.04 * sin(clock * 15.0))

	_cone.visible = windup or swing
	if _cone.visible:
		_cone.position = Vector3(_shown_pos.x, 0.033, _shown_pos.y)
		_cone.rotation.y = heading
		_cone_material.set_shader_parameter("charge", charge if windup else 1.0)
		_cone_material.set_shader_parameter("swing", strike if swing else 0.0)
	_mark.visible = alive and (planted or guarded or hit > 0.0)
	if _mark.visible:
		_mark.position = Vector3(_shown_pos.x, 0.047, _shown_pos.y)
		_mark.rotation.y = heading
		_mark_material.set_shader_parameter("planted", float(planted))
		_mark_material.set_shader_parameter("guarded", float(guarded))
		_mark_material.set_shader_parameter("hit", hit)
		_mark_material.set_shader_parameter("clock", clock)

	_burst.visible = not alive and _fall_age >= 0.22 and _fall_age < 0.95
	if _burst.visible:
		var point: Vector2 = at + (p.velocity as Vector2).limit_length(5.6) * 0.32
		_burst.position = Vector3(point.x, PIT_Y + 0.025, point.y)
		_burst_material.set_shader_parameter("age", (_fall_age - 0.22) / 0.73)

	_tag.visible = alive
	if alive:
		_tag.text = identity if not identity.is_empty() else str(_slot + 1)
		_tag.position = Vector3(_shown_pos.x, 1.53, _shown_pos.y)
	_was_alive = alive

func _restore_arms() -> void:
	for bone in _base_rotations:
		robot.skeleton.set_bone_pose_rotation(bone, _base_rotations[bone])
	_base_rotations.clear()

func _pose_palms(amount: float, punch: bool) -> void:
	for arm in _arms:
		var side := 1.0 if arm[0] == _arms[0][0] else -1.0
		var shoulder := Vector3(side * 0.19, -0.16, 1.0) if punch else Vector3(side * 0.46, -0.72, 0.46)
		var forearm := Vector3(-side * 0.12, 0.10, 1.0) if punch else Vector3(-side * 0.23, 0.75, 0.66)
		_aim_bone(arm[0], arm[1], shoulder, amount)
		_aim_bone(arm[1], arm[2], forearm, amount)

func _aim_bone(bone: int, child: int, goal: Vector3, amount: float) -> void:
	var skeleton: Skeleton3D = robot.skeleton
	var joint := skeleton.get_bone_global_pose(bone)
	var dir := (skeleton.get_bone_global_pose(child).origin - joint.origin).normalized()
	var turn := Quaternion(dir, goal.normalized())
	_base_rotations[bone] = skeleton.get_bone_pose_rotation(bone)
	joint.basis = Basis(Quaternion.IDENTITY.slerp(turn, amount)) * joint.basis
	skeleton.set_bone_global_pose(bone, joint)
