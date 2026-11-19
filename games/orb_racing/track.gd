extends RefCounted
## The circuit in screen coordinates (+X right, +Y down). The arena maps Y to Z.
## Rounded centerline, distance frames, rail limits, timing lines and charge strips.

const ROAD_HALF := 5.65
const RAIL_HALF := 7.35
const ORB_RADIUS := 0.73
const GRID_BEHIND := 3.5
const GRID_SPACING := 1.74
const CURVE_RADIUS := 11.0
const SAMPLE_SPACING := 1.1
const PAD_HALF_WIDTH := 1.85
const PAD_HALF_LENGTH := 0.9
const GATE_NAMES := ["START / FINISH", "EAST RISE", "NORTH BANK", "CHICANE ENTRY",
	"CHICANE EXIT", "WEST BANK", "HOME TURN"]

const CORNERS := [
	Vector2(0, 17), Vector2(24, 17), Vector2(35, 7), Vector2(35, -8),
	Vector2(25, -18), Vector2(10, -18), Vector2(2, -12), Vector2(-7, -12),
	Vector2(-15, -18), Vector2(-26, -18), Vector2(-36, -9), Vector2(-36, 6),
	Vector2(-24, 17),
]
const GATE_ANCHORS := [Vector2(31, 12), Vector2(35, -5), Vector2(17, -18),
	Vector2(-3, -12), Vector2(-29, -17), Vector2(-36, 4)]
const PAD_ANCHORS := [Vector2(13, 17), Vector2(22, -18), Vector2(-36, -4), Vector2(-15, 17)]
const PAD_OFFSET := 3.3

var points := PackedVector2Array()
var distances := PackedFloat64Array()
var tangents := PackedVector2Array()
var length := 0.0
var gate_distances := PackedFloat64Array([0.0])
var gates: Array[Transform2D] = []
var pads: Array[Transform2D] = []
var pad_distances := PackedFloat64Array()
var pad_offsets := PackedFloat32Array()


func _init() -> void:
	_append(CORNERS[0])
	for i in range(1, CORNERS.size()):
		var corner: Vector2 = CORNERS[i]
		var incoming: Vector2 = (corner - CORNERS[i - 1]).normalized()
		var outgoing: Vector2 = (CORNERS[(i + 1) % CORNERS.size()] - corner).normalized()
		var turn := incoming.angle_to(outgoing)
		var trim := CURVE_RADIUS * tan(absf(turn) * 0.5)
		var start := corner - incoming * trim
		_line_to(start)
		var center := start + _right(incoming) * signf(turn) * CURVE_RADIUS
		var radius := start - center
		var segments := ceili(absf(turn) * CURVE_RADIUS / SAMPLE_SPACING)
		for j in range(1, segments + 1):
			_append(center + radius.rotated(turn * float(j) / segments))
	_line_to(CORNERS[0])

	var last := points.size() - 1
	for i in last:
		var before := (points[i] - points[posmod(i - 1, last)]).normalized()
		var after := (points[i + 1] - points[i]).normalized()
		tangents.append((before + after).normalized())
	tangents.append(tangents[0])
	for anchor in GATE_ANCHORS:
		gate_distances.append(project(anchor).x)
	for distance in gate_distances:
		gates.append(frame(distance))
	for i in PAD_ANCHORS.size():
		var distance := project(PAD_ANCHORS[i]).x
		var offset := PAD_OFFSET if i % 2 == 0 else -PAD_OFFSET
		var strip := frame(distance)
		strip.origin += strip.y * offset
		pads.append(strip)
		pad_distances.append(distance)
		pad_offsets.append(offset)


func _line_to(end: Vector2) -> void:
	var from := points[-1]
	var steps := ceili(from.distance_to(end) / SAMPLE_SPACING)
	for i in range(1, steps + 1):
		_append(from.lerp(end, float(i) / steps))


func _append(point: Vector2) -> void:
	if not points.is_empty():
		length += points[-1].distance_to(point)
	points.append(point)
	distances.append(length)


func frame(distance: float) -> Transform2D:
	var s := fposmod(distance, length)
	var low := 0
	var high := distances.size() - 1
	while high - low > 1:
		var mid := (low + high) >> 1
		if distances[mid] <= s:
			low = mid
		else:
			high = mid
	var t := (s - distances[low]) / (distances[high] - distances[low])
	var forward := tangents[low].lerp(tangents[high], t).normalized()
	return Transform2D(forward, _right(forward), points[low].lerp(points[high], t))


func grid(slot: int, seats: int) -> Vector2:
	var start := frame(-GRID_BEHIND)
	return start.origin + start.y * (slot - (seats - 1) * 0.5) * GRID_SPACING


## Returns (arc distance, signed lateral distance, segment index). A moving
## orb can only advance a fraction of a sample per tick, so search locally.
func project(pos: Vector2, near: int = -1) -> Vector3:
	var count := points.size() - 1
	var first := 0 if near < 0 else near - 10
	var end := count if near < 0 else near + 11
	var best := INF
	var result := Vector3.ZERO
	for index in range(first, end):
		var i := posmod(index, count)
		var span := points[i + 1] - points[i]
		var offset := pos - points[i]
		var along := clampf(offset.dot(span) / span.length_squared(), 0.0, 1.0)
		var radial := offset - span * along
		var error := radial.length_squared()
		if error < best:
			best = error
			var arc := lerpf(distances[i], distances[i + 1], along)
			result = Vector3(arc, sqrt(error) * signf(span.cross(offset)), i)
	return result


func relative_arc(distance: float, reference: float) -> float:
	return fposmod(distance - reference + length * 0.5, length) - length * 0.5


## Fraction of the swept step at a forward timing-line crossing, or -1.
## The interpolated crossing point must be inside the road at that instant.
static func crossing(line: Transform2D, half_width: float, from: Vector2, to: Vector2) -> float:
	var start := from - line.origin
	var end := to - line.origin
	var a := start.dot(line.x)
	var b := end.dot(line.x)
	if a >= 0.0 or b < 0.0:
		return -1.0
	var fraction := -a / (b - a)
	return fraction if absf(start.lerp(end, fraction).dot(line.y)) <= half_width else -1.0


static func _right(forward: Vector2) -> Vector2:
	return Vector2(-forward.y, forward.x)
