extends Node3D
## Static circuit art. Road, kerbs, rails and signs are one vertex-colour mesh.

const Track = preload("res://games/orb_racing/track.gd")
const Kit = preload("res://scripts/ui_kit.gd")

const TURF := Color("183c3a")
const ASPHALT := Color("293746")
const PAINT := Color("bde0e2")
const ICE := Color("7de8ff")
const AMBER := Color("ffd05b")
const INFIELD := Color("152c31")

var vertices := PackedVector3Array()
var colors := PackedColorArray()


func build(track: RefCounted) -> void:
	_rect(Rect2(-180, -120, 360, 240), -0.09, Color("122329"))
	_rect(Rect2(-52, -30, 104, 61), -0.08, Color("203337"))
	_rect(Rect2(-45, -27, 89, 53.5), -0.07, TURF)
	for i in 23:
		_rect(Rect2(-44 + i * 3.9, -27, 1.95, 53.5), -0.06, Color("1b4240"))

	for i in track.points.size() - 1:
		var from := Transform2D(track.tangents[i], Track._right(track.tangents[i]), track.points[i])
		var to := Transform2D(track.tangents[i + 1], Track._right(track.tangents[i + 1]), track.points[i + 1])
		_ribbon(from, to, -Track.RAIL_HALF, Track.RAIL_HALF, -0.04, -0.04, Color("376351"))
		var seam := 0.025 * cos(float(i / 4) * 2.3)
		_ribbon(from, to, -Track.ROAD_HALF, Track.ROAD_HALF, 0.0, 0.0, ASPHALT.lightened(seam))
		for side: float in [-1.0, 1.0]:
			var edge := side * Track.ROAD_HALF
			var rail := side * Track.RAIL_HALF
			_ribbon(from, to, edge, edge + side * 0.4, 0.014, 0.014, Color("aec1be") if (i / 2) % 2 == 0 else Color("4c7377"))
			_ribbon(from, to, edge - side * 0.56, edge - side * 0.47, 0.018, 0.018, Color("789997"))
			_ribbon(from, to, rail, rail, -0.04, 0.39, Color("172732"))
			_ribbon(from, to, rail, rail + side * 0.34, 0.39, 0.39, Color("668f8b") if i % 12 < 10 else Color("d5ede1"))
			_ribbon(from, to, rail + side * 0.34, rail + side * 0.34, 0.39, -0.06, Color("26424a"))

	# Road studs flank the racing lane. Arrows mark the usable route through
	# the chicane as well as the straights.
	for i in ceili(track.length / 2.75):
		var f: Transform2D = track.frame(2.0 + i * 2.75)
		for side: float in [-1.0, 1.0]:
			_tile(f, 0, side * 4.65, 0.24, 0.088, 0.027, Color("65808a"))
	for distance: float in [8, 23, 39, 58, 78, 87, 104, 117, 130, 151, 162, 180]:
		var f: Transform2D = track.frame(distance)
		_arrow(f, 0.06, Color("b1ccd6"))

	for i in track.gates.size():
		var f: Transform2D = track.gates[i]
		if i == 0:
			_finish_line(f)
		else:
			for j in 9:
				_tile(f, 0, (j - 4) * 1.23, 0.19, 0.36, 0.035, Color("80b8cb"))
			for side: float in [-1.0, 1.0]:
				_pylon(f * Vector2(0, side * 6.55), 0.64, 0.87, Color("416a76"), Color("9bd9dc"))
	for f in track.pads:
		_tile(f, 0, 0, Track.PAD_HALF_LENGTH + 0.13, Track.PAD_HALF_WIDTH + 0.13, 0.038, Color("14212c"))
		_tile(f, 0, 0, Track.PAD_HALF_LENGTH, Track.PAD_HALF_WIDTH, 0.041, AMBER)
		for i in 3:
			_bolt(f.translated_local(Vector2(0, (i - 1) * 1.13)))

	for i in 6:
		var box := Transform2D(0.0, track.grid(i, 6))
		var tint := Color("758c9c")
		_tile(box, 0, 0, 1.26, 0.79, 0.021, Color("405464"))
		_tile(box, -1.25, 0, 0.10, 0.78, 0.024, tint)
		_tile(box, 0, -0.78, 1.25, 0.07, 0.024, tint)
		_tile(box, 0, 0.78, 1.25, 0.07, 0.024, tint)
		_text(str(i + 1), box.origin - Vector2(1.8, 0), 0.035, 0.016, PAINT)

	_infield()
	_grandstand(Vector2(-30, -27.2), 26.4, -1.0)
	_grandstand(Vector2(15, 27), 27.0, 1.0)
	_grandstand(Vector2(-44, 0), 12.0, 1.0, PI * 0.5)
	_grandstand(Vector2(43.6, 2.5), 11.0, -1.0, PI * 0.5)
	var data := []
	data.resize(Mesh.ARRAY_MAX)
	data[Mesh.ARRAY_VERTEX] = vertices
	data[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)
	var building := MeshInstance3D.new()
	building.mesh = mesh
	building.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(building)
	vertices.clear()
	colors.clear()


func _finish_line(f: Transform2D) -> void:
	var columns := 16
	var tile := Track.ROAD_HALF * 2.0 / columns
	for row in 2:
		for i in columns:
			var tint := Color("f2f8f4") if (row + i) % 2 == 0 else Color("101b29")
			_tile(f, (row - 0.5) * 0.51, (i + 0.5) * tile - Track.ROAD_HALF, 0.257, tile * 0.501, 0.034, tint)
	for side: float in [-1.0, 1.0]:
		_pylon(f * Vector2(0, side * 6.55), 0.84, 1.12, Color("627780"), Color("defcfa"))
	_text("START / FINISH", f.origin + Vector2(0, 7.95), 0.05, 0.019, PAINT)


func _infield() -> void:
	_rect(Rect2(-26, -3.7, 52, 12.6), -0.032, Color("2d5552"))
	_rect(Rect2(-25.7, -3.4, 51.4, 12), -0.028, INFIELD)
	_rect(Rect2(-24.8, -2.5, 49.6, 0.10), -0.022, Color("48736e"))
	_rect(Rect2(-24.8, 7.55, 49.6, 0.10), -0.022, Color("48736e"))
	for side: float in [-1.0, 1.0]:
		var x := side * 19.7
		var f := Transform2D(0.0, Vector2(x, 2.5))
		for i in 4:
			var tint := Color("28494b") if i < 3 else Color("83c4b5")
			_quad(f * Vector2(i * 0.78 - 2.0, -2.2), f * Vector2(i * 0.78 - 1.52, -2.2),
				f * Vector2(i * 0.78 - 0.14, 2.2), f * Vector2(i * 0.78 - 0.62, 2.2), 0.0, tint)
	_text("ORB RACING", Vector2(0, 2.55), -0.017, 0.090, Color("4f7771"))


func _grandstand(origin: Vector2, width: float, side: float, rotation: float = 0.0) -> void:
	var f := Transform2D(rotation, origin)
	_tile(f, width * 0.5, side * 0.8, width * 0.5, 1.60, -0.045, Color("22404a"))
	_tile(f, width * 0.5, 0, width * 0.5, 0.19, 0.17, Color("547779"))
	var bays := floori(width / 1.08)
	for row in 3:
		for i in bays:
			var pos := f * Vector2((i + 0.55) * width / bays, (0.55 + row * 0.53) * side)
			var seats := Transform2D(rotation, pos)
			var tint := Color("304e59").lerp(Color("82a7a1"), float((i * 11 + row * 7) % 17) / 23.0)
			if (i + 3 * row) % 13 < 2:
				tint = Color("b9a865")
			_tile(seats, 0, 0, 0.46, 0.21, 0.24 + row * 0.17, tint)


func _arrow(f: Transform2D, height: float, tint: Color) -> void:
	var tip := f * Vector2(1.42, 0)
	for side: float in [-1.0, 1.0]:
		_quad(f * Vector2(-0.76, side * 1.36), tip, f * Vector2(0.5, 0),
			f * Vector2(-1.56, side * 1.36), height, tint)


func _bolt(f: Transform2D) -> void:
	var ink := Color("493a31")
	_quad(f * Vector2(0.69, -0.18), f * Vector2(0.20, 0.30), f * Vector2(-0.11, 0.01),
		f * Vector2(0.18, -0.05), 0.052, ink)
	_quad(f * Vector2(-0.69, 0.18), f * Vector2(-0.20, -0.30), f * Vector2(0.11, -0.01),
		f * Vector2(-0.18, 0.05), 0.052, ink)


func _pylon(pos: Vector2, width: float, height: float, base: Color, cap: Color) -> void:
	var a := pos + Vector2(-width * 0.5, -0.31)
	var b := pos + Vector2(width * 0.5, -0.31)
	var c := pos + Vector2(width * 0.5, 0.31)
	var d := pos + Vector2(-width * 0.5, 0.31)
	_quad(a, b, c, d, height, cap)
	for pair in [[a, b], [b, c], [c, d], [d, a]]:
		_face(_ground(pair[0], 0), _ground(pair[1], 0), _ground(pair[1], height), _ground(pair[0], height), base)


func _ribbon(from: Transform2D, to: Transform2D, left: float, right: float, h1: float, h2: float, tint: Color) -> void:
	_face(_ground(from * Vector2(0, left), h1), _ground(to * Vector2(0, left), h1),
		_ground(to * Vector2(0, right), h2), _ground(from * Vector2(0, right), h2), tint)


func _tile(f: Transform2D, x: float, y: float, half_x: float, half_y: float, h: float, tint: Color) -> void:
	_quad(f * Vector2(x - half_x, y - half_y), f * Vector2(x + half_x, y - half_y),
		f * Vector2(x + half_x, y + half_y), f * Vector2(x - half_x, y + half_y), h, tint)


func _rect(rect: Rect2, height: float, tint: Color) -> void:
	_quad(rect.position, Vector2(rect.end.x, rect.position.y), rect.end,
		Vector2(rect.position.x, rect.end.y), height, tint)


func _quad(a: Vector2, b: Vector2, c: Vector2, d: Vector2, h: float, tint: Color) -> void:
	_face(_ground(a, h), _ground(b, h), _ground(c, h), _ground(d, h), tint)


func _face(a: Vector3, b: Vector3, c: Vector3, d: Vector3, tint: Color) -> void:
	vertices.append_array(PackedVector3Array([a, b, c, a, c, d]))
	for i in 6:
		colors.append(tint)


func _text(value: String, pos: Vector2, h: float, pixel: float, tint: Color) -> void:
	var label := Label3D.new()
	label.text = value
	label.font = Kit.display
	label.font_size = 64
	label.outline_size = 0
	label.modulate = tint
	label.pixel_size = pixel
	label.position = _ground(pos, h)
	label.rotation_degrees.x = -90
	add_child(label)


static func _ground(pos: Vector2, h: float) -> Vector3:
	return Vector3(pos.x, h, pos.y)
