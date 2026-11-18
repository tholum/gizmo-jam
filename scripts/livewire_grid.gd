extends RefCounted
## Hex board shared by the Live Wire simulation and its renderer.
##
## Pointy-top hexes in axial coordinates (q, r), laid out on the XZ plane:
## a board position is Vector2(x, z). Cells are stored in a fixed order (by r,
## then q), so a cell index means the same thing on the server and on clients.
##
## A "line" is a straight row of cells, which is what a surge fires along:
##   axis 0: r is constant      (runs left-right)
##   axis 1: q is constant      (runs down-right)
##   axis 2: s = -q-r constant  (runs up-right)
## Line numbers run from -radius to +radius on every axis.

const SQRT3 := 1.7320508075688772
const DIRS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)]

var radius: int
## Centre-to-corner distance of one hex, in world units.
var size: float
var cells: Array[Vector2i] = []
var centers := PackedVector2Array()
## Vector2i(q, r) -> cell index.
var index: Dictionary = {}
## Per cell: indices of the adjacent cells that exist (3 to 6 of them).
var neighbors: Array[PackedInt32Array] = []

func _init(board_radius: int = 7, hex_size: float = 0.9) -> void:
	radius = board_radius
	size = hex_size
	for r in range(-radius, radius + 1):
		for q in range(maxi(-radius, -r - radius), mini(radius, -r + radius) + 1):
			var cell := Vector2i(q, r)
			index[cell] = cells.size()
			cells.append(cell)
			centers.append(center_of(cell))
	for cell in cells:
		var near := PackedInt32Array()
		for dir in DIRS:
			if index.has(cell + dir):
				near.append(index[cell + dir])
		neighbors.append(near)

func count() -> int:
	return cells.size()

func center_of(cell: Vector2i) -> Vector2:
	return Vector2(size * SQRT3 * (cell.x + cell.y / 2.0), size * 1.5 * cell.y)

## Index of the cell under a board position, or -1 when it is off the board.
func cell_at(pos: Vector2) -> int:
	var qf := (SQRT3 / 3.0 * pos.x - pos.y / 3.0) / size
	var rf := (2.0 / 3.0 * pos.y) / size
	var sf := -qf - rf
	var q := roundi(qf)
	var r := roundi(rf)
	var s := roundi(sf)
	var dq := absf(q - qf)
	var dr := absf(r - rf)
	var ds := absf(s - sf)
	if dq > dr and dq > ds:
		q = -r - s
	elif dr > ds:
		r = -q - s
	return int(index.get(Vector2i(q, r), -1))

func inside(pos: Vector2) -> bool:
	return cell_at(pos) >= 0

## True for cells on the outer ring of the board.
func is_edge(i: int) -> bool:
	return neighbors[i].size() < 6

## Which line of the given axis a cell sits on.
func line_of(i: int, axis: int) -> int:
	var cell := cells[i]
	if axis == 0:
		return cell.y
	if axis == 1:
		return cell.x
	return -cell.x - cell.y

## The cells of one line, ordered from one end of the board to the other.
func line_cells(axis: int, line: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	for i in cells.size():
		if line_of(i, axis) == line:
			result.append(i)
	return result

## Board positions of the two ends of a line, pushed `extend` world units past
## the outermost cell centres (for beam emitters standing off the board).
func line_ends(axis: int, line: int, extend: float = 0.0) -> PackedVector2Array:
	var members := line_cells(axis, line)
	if members.is_empty():
		return PackedVector2Array()
	var a := centers[members[0]]
	var b := centers[members[members.size() - 1]]
	var dir := (b - a).normalized() if members.size() > 1 else Vector2.RIGHT
	return PackedVector2Array([a - dir * extend, b + dir * extend])

## Distance from the board centre to the centre of a corner cell.
func extent() -> float:
	return size * SQRT3 * radius
