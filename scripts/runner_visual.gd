extends Node3D
## One robot runner: the skinned Meshy model tinted in its team colour, its
## animation state, and the lane ring and contact shadow painted on the deck.
##
## The arena feeds it the simulation state every frame through `pose()`.
## Animations advance only from that call, so pausing or stepping the arena
## pauses or steps the robots too.

const Kit = preload("res://scripts/arena_kit.gd")
const Model = preload("res://scripts/round_model.gd")
const SCENE_PATH := "res://assets/meshy/runner.glb"
## Standing height in arena units, antenna included.
const HEIGHT := 1.3
## Triangle budget of the lighter mesh (the full model is about 14,500).
const LITE_TRIANGLES := 4500
## Low's mesh, about 2,100 triangles. The simplifier only offers whole LOD
## steps. At the default merge angle the step below Balanced (about 2,800)
## dents the head; with a wider normal merge angle the head stays a clean box
## down to this step, and only the antenna and ear discs get coarser, which
## at gameplay distance and Low's render scale is a pixel or two. It saves
## about 3 ms a frame over the 4,300 step on llvmpipe. The podium robot,
## which fills the screen, keeps Balanced's mesh on Low.
const LOW_TRIANGLES := 2000
const LOW_MERGE_ANGLE := 60.0
## The silhouette shadow can be rougher still.
const SHADOW_TRIANGLES := 2500
const LOOPS := ["idle", "jog", "run", "duck", "victory"]

static var _scene: PackedScene
static var _quad: QuadMesh
static var _lite_mesh: ArrayMesh
static var _low_mesh: ArrayMesh
static var _shadow_mesh: ArrayMesh

var body: Node3D
var rig: Node3D
var anim: AnimationPlayer
var skeleton: Skeleton3D
var mesh: MeshInstance3D
var lite: MeshInstance3D
var material: ShaderMaterial
var ring: MeshInstance3D
var ring_material: ShaderMaterial
var shadow: MeshInstance3D
var shadow_material: ShaderMaterial
var planar: MeshInstance3D
var color := Color.WHITE
var clip := ""
var hit_time := 0.0
var hit_clip := "hit"
var last_flash := 0.0
var sprinting := false
var slope := 0.0
var shadow_strength := 0.72

static func _shared_quad() -> QuadMesh:
	if _quad == null:
		_quad = QuadMesh.new()
		_quad.size = Vector2.ONE
		_quad.orientation = PlaneMesh.FACE_Y
	return _quad

## A lighter version of a skinned mesh. The simplifier only drops vertices, it
## never moves them or blends their UVs, so the texture cannot smear the way it
## does after an edge-collapse decimation of Meshy's fragmented UV atlas.
static func _simplified(source: ArrayMesh, budget: int, merge_angle: float = 25.0) -> ArrayMesh:
	var arrays := source.surface_get_arrays(0)
	var builder := ImporterMesh.new()
	builder.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays)
	builder.generate_lods(merge_angle, maxf(60.0, merge_angle), [])
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	for level in builder.get_surface_lod_count(0):
		var candidate := builder.get_surface_lod_indices(0, level)
		if candidate.size() / 3 >= budget and candidate.size() < indices.size(): indices = candidate
	# Keep only the vertices the chosen level still uses.
	var remap := {}
	var order := PackedInt32Array()
	var compact := PackedInt32Array()
	for index in indices:
		if not remap.has(index):
			remap[index] = order.size()
			order.append(index)
		compact.append(remap[index])
	var vertex_count: int = arrays[Mesh.ARRAY_VERTEX].size()
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	for channel in Mesh.ARRAY_MAX:
		var data: Variant = arrays[channel]
		if data == null or channel == Mesh.ARRAY_INDEX: continue
		var stride: int = data.size() / vertex_count
		var picked: Variant = data.duplicate()
		picked.resize(order.size() * stride)
		for i in order.size():
			for k in stride:
				picked[i * stride + k] = data[order[i] * stride + k]
		out[channel] = picked
	out[Mesh.ARRAY_INDEX] = compact
	var made := ArrayMesh.new()
	made.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out, [], {}, source.surface_get_format(0) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS)
	made.surface_set_material(0, source.surface_get_material(0))
	return made

func setup(team: Color, deck_slope: float = 0.0) -> void:
	color = team
	slope = deck_slope
	if _scene == null: _scene = load(SCENE_PATH)
	body = Node3D.new()
	body.name = "Body"
	body.rotation.y = PI / 2.0
	add_child(body)
	rig = _scene.instantiate()
	rig.name = "Rig"
	body.add_child(rig)
	anim = rig.find_child("AnimationPlayer", true, false)
	skeleton = rig.find_child("Skeleton3D", true, false)
	# Two meshes share the skeleton: the full model for High, and a lighter
	# one for Balanced (software renderers skin on the CPU) that also casts
	# the silhouette shadow.
	mesh = rig.find_children("*", "MeshInstance3D", true, false)[0]
	if _lite_mesh == null: _lite_mesh = _simplified(mesh.mesh, LITE_TRIANGLES)
	lite = MeshInstance3D.new()
	lite.name = "RunnerLite"
	lite.mesh = _lite_mesh
	lite.skin = mesh.skin
	mesh.get_parent().add_child(lite)
	lite.skeleton = mesh.skeleton
	var source: BaseMaterial3D = mesh.mesh.surface_get_material(0)
	material = Kit.shader_material(Kit.RUNNER_SHADER, {
		"albedo_tex": source.albedo_texture, "mask_tex": source.emission_texture, "team": team})
	for part in [mesh, lite]:
		part.material_override = material
		part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# A skinned mesh is culled by its rest-pose box; poses reach well outside it.
		part.extra_cull_margin = 1.5
	mesh.visible = false
	var bounds := mesh.get_aabb()
	rig.scale = Vector3.ONE * (HEIGHT / maxf(bounds.size.y, 0.001))
	anim.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	for clip_name in LOOPS:
		if anim.has_animation(clip_name):
			anim.get_animation(clip_name).loop_mode = Animation.LOOP_LINEAR
	# Deck markers follow the slope of the spiral at this lane.
	ring_material = Kit.shader_material(Kit.RING_SHADER, {"tint": team})
	ring = _decal(ring_material, 1.02, 0.03)
	shadow_material = Kit.shader_material(Kit.BLOB_SHADER, {"strength": shadow_strength})
	shadow = _decal(shadow_material, 1.0, 0.036)
	play("idle", 0.0)
	anim.advance(0.0)

func set_team_color(tint: Color) -> void:
	color = tint
	material.set_shader_parameter("team", tint)
	ring_material.set_shader_parameter("tint", tint)

func _decal(mat: ShaderMaterial, size: float, lift: float) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = _shared_quad()
	node.material_override = mat
	node.scale = Vector3(size, 1.0, size)
	node.position.y = lift
	node.rotation.z = slope
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node

func play(clip_name: String, blend: float, speed: float = 1.0) -> void:
	if clip == clip_name: return
	if not anim.has_animation(clip_name): return
	clip = clip_name
	anim.play(clip_name, blend, speed)

## state: mode ("run", "idle", "victory", "down"), jump (clock or -1), duck,
## flash, speed (rad/s of the belt), hit_kind ("jump" or "duck"), own (bool).
func pose(delta: float, state: Dictionary) -> void:
	var mode: String = state.get("mode", "run")
	var jump: float = state.get("jump", -1.0)
	var duck: bool = state.get("duck", false)
	var flash: float = state.get("flash", 0.0)
	var speed: float = state.get("speed", 0.68)
	if flash > last_flash + 0.05 and mode == "run":
		hit_time = 0.5
		hit_clip = "hit_low" if state.get("hit_kind", "duck") == "jump" else "hit"
	last_flash = flash
	hit_time = maxf(0.0, hit_time - delta)
	var height := Model.jump_height({"jump": jump})
	anim.speed_scale = 1.0
	if mode == "down":
		play("knockdown", 0.08, 1.35)
	elif mode == "victory":
		play("victory", 0.25)
	elif jump >= 0.0:
		play("jump", 0.07, 0.0)
		var length := anim.get_animation("jump").length
		anim.seek(clampf(jump / Model.JUMP_DURATION, 0.0, 0.985) * length, false)
	elif duck:
		play("duck", 0.09)
	elif hit_time > 0.0:
		play(hit_clip, 0.05, 1.5)
	elif mode == "idle":
		play("idle", 0.2)
	else:
		# Jog while the belt is slow, break into a sprint as the round speeds up.
		if speed > 1.02: sprinting = true
		elif speed < 0.94: sprinting = false
		play("run" if sprinting else "jog", 0.16 if clip in ["jump", "duck"] else 0.28)
		anim.speed_scale = (0.82 + (speed - 1.0) * 0.5) if sprinting else (0.86 + (speed - 0.68) * 0.75)
	anim.advance(delta)
	body.position.y = height
	# Flash white on a hit, in step with the simulation's invulnerability blink.
	var blink := 0.0
	if flash > 0.0: blink = 0.42 if int(flash * 22.0) % 2 == 0 else 0.0
	material.set_shader_parameter("flash", blink)
	# The shadow stays on the deck: smaller and fainter the higher the jump.
	var lift := clampf(height / 0.95, 0.0, 1.0)
	var spread := 1.35 if clip in ["duck", "knockdown"] else 1.0
	shadow.scale = Vector3(0.95 * spread * (1.0 - 0.3 * lift), 1.0, 0.95 * (1.0 - 0.3 * lift))
	shadow_material.set_shader_parameter("strength", shadow_strength * (1.0 - 0.45 * lift))

## Highlights the local player's ring; `pulse` is 0..1.
func set_ring(own: bool, pulse: float) -> void:
	var size := (1.22 + 0.07 * pulse) if own else 1.02
	ring.scale = Vector3(size, 1.0, size)
	ring_material.set_shader_parameter("energy", 1.25 if own else 1.0)
	ring_material.set_shader_parameter("fill", 0.3 if own else 0.14)
	ring_material.set_shader_parameter("inner", 0.6 if own else 0.66)

## `level` is "low", "balanced" or "high". High shows the full mesh and swaps
## the soft blob for a true silhouette: the light mesh drawn again, flattened
## onto the deck by its shader. Balanced and Low skin a lighter mesh.
func set_quality(level: String, blob: float, silhouette: bool = true) -> void:
	var high := level == "high"
	shadow_strength = blob
	mesh.visible = high
	lite.visible = not high
	if level == "low":
		if _low_mesh == null: _low_mesh = _simplified(mesh.mesh, LOW_TRIANGLES, LOW_MERGE_ANGLE)
		lite.mesh = _low_mesh
	else:
		lite.mesh = _lite_mesh
	if high and silhouette and planar == null:
		planar = MeshInstance3D.new()
		planar.name = "PlanarShadow"
		if _shadow_mesh == null: _shadow_mesh = _simplified(mesh.mesh, SHADOW_TRIANGLES)
		planar.mesh = _shadow_mesh
		planar.skin = lite.skin
		planar.material_override = Kit.shader_material(Kit.PLANAR_SHADOW_SHADER)
		planar.material_override.render_priority = -1
		planar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		planar.extra_cull_margin = 4.0
		skeleton.add_child(planar)
		planar.skeleton = lite.skeleton
	if planar: planar.visible = high and silhouette

func set_markers(shown: bool) -> void:
	ring.visible = shown
	shadow.visible = shown
