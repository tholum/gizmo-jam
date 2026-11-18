extends Node3D
## Pulse: what the round looks like. Six pillars in the player colours rise
## with each score around a ring that pulses on the beat.
##
## The surface main.gd relies on (every game arena has it):
##   update_visuals(state, delta, own_slot)  state is the model, or whatever
##                    the module's backdrop() returned (null = idle)
##   set_level(level)  "low", "balanced" or "high"
##   show_identities   true while Tab is held
## Optional: set_menu(on), set_inset(fraction), celebrate(slot).
##
## A pack arena is created by its module when staged and freed when not, so
## a library of games costs nothing until one is played. It carries its own
## Environment on its camera: a built-in arena's WorldEnvironment may still be
## in the tree, and the camera's environment overrides it.

const Kit = preload("res://scripts/ui_kit.gd")

var camera: Camera3D
var ring: MeshInstance3D
var pillars: Array = []
var tags: Array = []
var show_identities := false:
	set(value):
		show_identities = value
		for tag in tags: tag.visible = value
var level := "balanced"
var menu_mode := true
var inset := 0.0
var champion := -1
var clock := 0.0

func _ready() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("10183a")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("b9c6ff")
	environment.ambient_light_energy = 0.7
	camera = Camera3D.new()
	camera.environment = environment
	camera.fov = 50.0
	add_child(camera)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 30, 0)
	sun.light_energy = 1.1
	add_child(sun)
	var floor_mesh := CylinderMesh.new()
	floor_mesh.top_radius = 4.6
	floor_mesh.bottom_radius = 4.8
	floor_mesh.height = 0.3
	_mesh(floor_mesh, Vector3(0, -0.15, 0), Color("1c2758"))
	var torus := TorusMesh.new()
	torus.inner_radius = 0.9
	torus.outer_radius = 1.15
	ring = _mesh(torus, Vector3(0, 0.1, 0), Kit.LIME, 1.4)
	for i in 6:
		var angle := PI + (i + 0.5) * PI / 6.0
		var box := BoxMesh.new()
		box.size = Vector3(0.7, 1.0, 0.7)
		var pillar := _mesh(box, Vector3(cos(angle) * 3.2, 0.5, sin(angle) * 3.2 + 1.2), Kit.colors[i], 0.0)
		pillars.append(pillar)
		var tag := Label3D.new()
		tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		tag.font_size = 48
		tag.outline_size = 12
		tag.modulate = Kit.colors[i]
		tag.visible = false
		add_child(tag)
		tags.append(tag)
	_frame_camera()
	camera.make_current()

func _mesh(mesh: Mesh, pos: Vector3, color: Color, glow: float = 0.0) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	if glow > 0.0:
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = glow
	node.material_override = material
	node.position = pos
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node

func set_level(value: String) -> void:
	level = value

func set_menu(on: bool) -> void:
	menu_mode = on
	show_identities = false
	if camera: _frame_camera()

## The menu column's right edge, as a fraction of the screen width; the ring
## moves into the space to its right.
func set_inset(value: float) -> void:
	inset = clampf(value, 0.0, 0.8)
	if camera: _frame_camera()

func _frame_camera() -> void:
	camera.position = Vector3(0, 7.5, 9.5) if menu_mode else Vector3(0, 6.5, 8.0)
	camera.look_at(Vector3(0, 0.6, 0.6))
	camera.h_offset = -inset * 6.0 if menu_mode else 0.0

func celebrate(slot: int) -> void:
	champion = slot

func update_visuals(state: RefCounted, delta: float, own_slot: int = 0) -> void:
	clock += delta
	if state == null or not "players" in state:
		champion = -1
		var idle := 0.5 + 0.5 * sin(clock * TAU / 0.8)
		ring.scale = Vector3.ONE * (1.0 + 0.12 * idle)
		for i in pillars.size():
			pillars[i].scale.y = 1.0 + 0.4 * sin(clock * 2.0 + i)
			pillars[i].position.y = pillars[i].scale.y * 0.5
		return
	var pulse: float = 1.0 - state.beat_phase()
	ring.scale = Vector3.ONE * (1.0 + 0.35 * pulse * pulse)
	for i in mini(pillars.size(), state.players.size()):
		var p: Dictionary = state.players[i]
		var height := 0.4 + minf(float(p.score) * 0.09, 6.0)
		var pillar: MeshInstance3D = pillars[i]
		pillar.scale.y = lerpf(pillar.scale.y, height, minf(1.0, delta * 10.0))
		pillar.position.y = pillar.scale.y * 0.5 + (0.3 * absf(sin(clock * 6.0)) if i == champion else 0.0)
		var flash := float(p.flash)
		var material: StandardMaterial3D = pillar.material_override
		material.albedo_color = Kit.colors[i].lerp(Color.WHITE, maxf(0.0, flash) * 0.6).lerp(Color("ff4d5e"), maxf(0.0, -flash) * 0.6)
		var tag: Label3D = tags[i]
		tag.text = ("YOU" if i == own_slot else str(p.name))
		tag.position = pillar.position + Vector3(0, pillar.scale.y * 0.5 + 0.5, 0)
