extends RefCounted
## Clockwork cast, built from a few batched, bevelled surfaces per piece.

const Art = preload("res://scripts/arena_kit.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const INK := Color("23282b")
const STEEL := Color("536e68")
const BRASS := Color("d99045")
const CREAM := Color("fff0ca")

static var _critter_meshes: Dictionary = {}

static func box(batch, center: Vector3, size: Vector3, paint: Color, bevel: float = 0.045, basis: Basis = Basis.IDENTITY) -> void:
	batch.box("solid", Transform3D(basis, center), size, bevel, paint)

static func disk(batch, center: Vector3, bottom: float, top: float, height: float, paint: Color, sides: int = 12) -> void:
	batch.prism("solid", Transform3D(Basis.IDENTITY, center), bottom, top, height, sides, paint)

static func finish(batch, parent: Node3D, material: Material) -> void:
	for part in batch.commit(parent, {"solid": material}):
		part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

static func label(parent: Node3D, caption: String, at: Vector3, width: float, tint: Color) -> Label3D:
	var tag := Label3D.new()
	tag.text = caption
	tag.font = Kit.display
	tag.font_size = 50
	tag.outline_size = 12
	tag.pixel_size = width / 50.0
	tag.modulate = tint
	tag.outline_modulate = Color("24272a")
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.no_depth_test = true
	tag.position = at
	parent.add_child(tag)
	return tag

static func sheriff(parent: Node3D, paint: Color, material: Material) -> Dictionary:
	# In this rig +X is forward. The brim, face, belt and boots stay visible from overhead.
	var body := Node3D.new()
	parent.add_child(body)
	var batch := Art.Batch.new()
	box(batch, Vector3(0, 0.49, 0), Vector3(0.48, 0.54, 0.65), INK, 0.078)
	box(batch, Vector3(0, 0.66, 0), Vector3(0.49, 0.38, 0.69), paint.darkened(0.18), 0.08)
	box(batch, Vector3(0.245, 0.63, 0), Vector3(0.028, 0.16, 0.44), paint.lightened(0.20), 0.012)
	box(batch, Vector3(0.25, 0.52, 0), Vector3(0.064, 0.11, 0.17), BRASS, 0.019)
	box(batch, Vector3(0.045, 0.99, 0), Vector3(0.51, 0.36, 0.54), STEEL, 0.082)
	box(batch, Vector3(0.279, 0.981, 0), Vector3(0.057, 0.15, 0.41), INK, 0.019)
	for side in [-1.0, 1.0]:
		box(batch, Vector3(0.312, 1.0, 0.114 * side), Vector3(0.021, 0.059, 0.069), CREAM, 0.009)
		box(batch, Vector3(-0.015, 0.723, 0.39 * side), Vector3(0.39, 0.20, 0.17), paint, 0.053)
	disk(batch, Vector3(-0.015, 1.14, 0), 0.54, 0.55, 0.087, INK, 14)
	disk(batch, Vector3(-0.045, 1.205, 0), 0.40, 0.338, 0.22, paint.darkened(0.14), 12)
	disk(batch, Vector3(-0.045, 1.220, 0), 0.402, 0.385, 0.067, paint.lightened(0.35), 12)
	box(batch, Vector3(0.18, 1.395, 0), Vector3(0.13, 0.035, 0.13), CREAM, 0.009, Basis(Vector3.UP, PI * 0.25))
	finish(batch, body, material)

	var boots: Array[Node3D] = []
	var hands: Array[Node3D] = []
	for side in [-1.0, 1.0]:
		var foot := Node3D.new()
		foot.position.z = 0.20 * side
		parent.add_child(foot)
		var sole := Art.Batch.new()
		box(sole, Vector3(0.06, 0.11, 0), Vector3(0.49, 0.22, 0.33), INK, 0.054)
		box(sole, Vector3(0.19, 0.17, 0), Vector3(0.24, 0.14, 0.31), paint.darkened(0.13), 0.043)
		finish(sole, foot, material)
		boots.append(foot)
		var hand := Node3D.new()
		parent.add_child(hand)
		var glove := Art.Batch.new()
		box(glove, Vector3(-0.07, 0, 0), Vector3(0.28, 0.18, 0.18), paint.darkened(0.23), 0.04)
		box(glove, Vector3(0.095, 0, 0), Vector3(0.14, 0.165, 0.15), CREAM, 0.042)
		finish(glove, hand, material)
		hands.append(hand)
	return {"body": body, "boots": boots, "hands": hands}

static func critter(parent: Node3D, gold: bool, material: Material) -> Dictionary:
	var rig := Node3D.new()
	parent.add_child(rig)
	var key := Node3D.new()
	key.position = Vector3(-0.435, 0.625, 0)
	rig.add_child(key)
	if _critter_meshes.has(gold):
		_place_mesh(rig, _critter_meshes[gold][0], material)
		_place_mesh(key, _critter_meshes[gold][1], material)
		return {"body": rig, "key": key}

	var batch := Art.Batch.new()
	var coat := Color("ffbf43") if gold else Color("f4e0b6")
	var seam := Color("a5532c") if gold else Color("754e42")
	var belly := Color("c87b35") if gold else Color("ad8061")
	box(batch, Vector3(-0.13, 0.29, 0), Vector3(0.77, 0.46, 0.61), belly, 0.135)
	box(batch, Vector3(-0.16, 0.48, 0), Vector3(0.69, 0.39, 0.59), coat, 0.18)
	box(batch, Vector3(0.275, 0.45, 0), Vector3(0.46, 0.43, 0.47), coat.lightened(0.20), 0.127)
	box(batch, Vector3(0.49, 0.38, 0), Vector3(0.10, 0.13, 0.20), seam, 0.036)
	for side in [-1.0, 1.0]:
		box(batch, Vector3(0.379, 0.513, side * 0.215), Vector3(0.087, 0.080, 0.047), INK, 0.018)
		box(batch, Vector3(0.395, 0.525, side * 0.239), Vector3(0.032, 0.027, 0.015), CREAM, 0.006)
		var rake := Basis(Vector3.FORWARD, -0.83) * Basis(Vector3.RIGHT, side * 0.32)
		box(batch, Vector3(0.10, 0.78, 0.153 * side), Vector3(0.15, 0.53, 0.156), coat.lightened(0.06), 0.055, rake)
		box(batch, Vector3(0.165, 0.811, 0.155 * side), Vector3(0.059, 0.32, 0.092), seam.lightened(0.27), 0.027, rake)
		box(batch, Vector3(-0.22, 0.106, 0.22 * side), Vector3(0.51, 0.16, 0.25), seam, 0.061)
		box(batch, Vector3(0.312, 0.105, 0.155 * side), Vector3(0.29, 0.15, 0.20), coat, 0.043)
	var winding := Art.Batch.new()
	var metal := Color("fff165") if gold else Color("bd582e")
	box(winding, Vector3(-0.19, 0, 0), Vector3(0.39, 0.082, 0.092), metal, 0.023)
	for side in [-1.0, 1.0]:
		box(winding, Vector3(-0.30, 0, 0.11 * side), Vector3(0.23, 0.085, 0.185), metal, 0.038)
	var shell: MeshInstance3D = batch.commit(rig, {"solid": material})[0]
	var handle: MeshInstance3D = winding.commit(key, {"solid": material})[0]
	shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	handle.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_critter_meshes[gold] = [shell.mesh, handle.mesh]
	return {"body": rig, "key": key}

static func _place_mesh(parent: Node3D, geometry: Mesh, material: Material) -> void:
	var mesh := MeshInstance3D.new()
	mesh.mesh = geometry
	mesh.material_override = material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mesh)
