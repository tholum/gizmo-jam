extends Node3D
## Orthographic carnival cabinet. Play surfaces are drawn in design units so
## forecast and target faces stay crisp on the core's reduced 3D settings.

const M = preload("res://games/knockdown_carnival/model.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const WOOD := Color("813747")
const SHADOW := Color("251525")
const FELT := Color("56384f")
const FELT_SHADE := Color("41283e")
const FRAME := Color("402035")
const GOLD := Color("ffce7e")
const BRASS := Color("c18c5c")
const IVORY := Color("fff0d0")
const RUST := Color("ac4e57")
const STEEL := Color("f7dcc8")
const AREA := Vector2(1120, 592)
const CENTER := Vector2(560, 288)
const RAIL_RADIUS := 335.0
const LAUNCH_RADIUS := 275.0
const INNER_RADIUS := 206.0
const SHELF_RADIUS := 89.0
const SQUASH := 0.68

var owner_ui: Node
var camera := Camera3D.new()
var client_motion := false
var local_mask := 0
var show_identities := false
var _inset := 0.0
var _menu := false
var _state: RefCounted
var _clock := 0.0
var _own := -1
var _sep := 0.0
var _champion := -1
var _layer: CanvasLayer
var _wall: Node2D
var _board: Node2D
var _pieces: Node2D
var _celebration := 0.0
var _cached_view := Rect2()

func _init(main: Node) -> void:
	owner_ui = main

func _ready() -> void:
	add_child(camera)
	_layer = CanvasLayer.new()
	_layer.layer = 0
	add_child(_layer)
	_wall = Node2D.new()
	_wall.draw.connect(_draw_room)
	_layer.add_child(_wall)
	_board = Node2D.new()
	_board.draw.connect(_draw_board)
	_layer.add_child(_board)
	_pieces = Node2D.new()
	_pieces.draw.connect(_draw_round)
	_layer.add_child(_pieces)

func set_menu(menu: bool) -> void:
	_menu = menu
	_champion = -1
	_celebration = 0.0

func set_inset(value: float) -> void:
	_inset = value

func set_level(_value: String) -> void:
	pass

func celebrate(slot: int) -> void:
	_champion = slot
	_celebration = 2.2

func update_visuals(state: RefCounted, delta: float, own: int = -1) -> void:
	if _state != state:
		_clock = 0.0
		_sep = 0.0
	_celebration = maxf(_celebration - delta, 0.0)
	_state = state
	_own = own
	if state != null:
		# A client extrapolates puck positions by at most one snapshot interval.
		# The target face always waits for the confirmed host impact.
		if float(state.tick) != _clock:
			_clock = float(state.tick)
			_sep = 0.0
		else:
			_sep = minf(_sep + delta * M.HZ, 3.0)
	var viewport := get_viewport().get_visible_rect()
	if viewport != _cached_view:
		_cached_view = viewport
		_wall.queue_redraw()
	var safe: Vector2 = owner_ui.area
	var scale_factor := minf((safe.x - 16.0) / AREA.x, (safe.y - 155.0) / AREA.y)
	var middle := Vector2(viewport.size.x * 0.5, safe.y * 0.5 + 12.0)
	if _menu:
		scale_factor = minf((safe.x - 16.0) / AREA.x, (safe.y - 42.0) / AREA.y)
		middle = Vector2(viewport.size.x * (0.55 + _inset * 0.27), safe.y * 0.5 + 32.0)
	for paint in [_board, _pieces]:
		paint.scale = Vector2.ONE * scale_factor
		paint.position = middle - AREA * scale_factor * 0.5
	_pieces.queue_redraw()

static func _angle(slot: int) -> float:
	return deg_to_rad(90.0 + slot * 60.0)

static func _point(radius: float, angle: float) -> Vector2:
	var heading := Vector2.from_angle(angle)
	return CENTER + Vector2(heading.x, heading.y * SQUASH) * radius

static func target_pos(id: int) -> Vector2:
	if M.is_shared(id):
		return _point(SHELF_RADIUS, _angle(id - M.FIRST_SHARED))
	return _point(INNER_RADIUS, _angle(floori(id / 3.0)) + (1 - id % 3) * 0.265)

static func launch_pos(slot: int) -> Vector2:
	return _point(LAUNCH_RADIUS, _angle(slot))

func _route(slot: int, line: int) -> PackedVector2Array:
	var finish := target_pos(_state.destination(slot, line))
	if M.is_bank(line):
		var wall := _point(RAIL_RADIUS, _angle(slot) + (0.48 if line == 0 else -0.48))
		return PackedVector2Array([launch_pos(slot), wall, finish])
	return PackedVector2Array([launch_pos(slot), finish])

func _draw_room() -> void:
	var size := _cached_view.size
	_wall.draw_rect(Rect2(Vector2.ZERO, size), SHADOW)
	var horizon := size.y * 0.68
	var floor_color := Color("36242e")
	_wall.draw_rect(Rect2(0, horizon, size.x, size.y - horizon), floor_color)
	var beam_count := ceili(size.x / 148.0)
	for i in range(-1, beam_count + 1):
		var x := i * 148.0
		_wall.draw_rect(Rect2(x, 0, 70, horizon), Color("2d1f2b"))
		_wall.draw_line(Vector2(x, 0), Vector2(x, horizon), Color("4b2836"), 2.0)
		_wall.draw_line(Vector2(x, horizon), Vector2(x + (x - size.x * 0.5) * 0.72, size.y), FRAME, 2.0)
	for y in [0.09, 0.39, 0.63, 0.68, 0.79, 0.94]:
		_wall.draw_line(Vector2(0, size.y * y), Vector2(size.x, size.y * y), Color("57313c"), 3.0)
	for i in 16:
		var x := (i + 0.5) * size.x / 16
		var y := size.y * 0.15 + (1.0 - pow(absf(i - 7.5) / 7.5, 2.0)) * 33.0
		_wall.draw_line(Vector2(x, size.y * 0.09), Vector2(x, y), Color("784757"), 2.0)
		_wall.draw_circle(Vector2(x, y), 11, Color("4d2c37"), true, -1, true)
		_wall.draw_circle(Vector2(x, y), 5, Color("bf816e"), true, -1, true)

func _ellipse(at: Vector2, radius: float, squash: float = SQUASH) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in 72:
		var heading := Vector2.from_angle(TAU * i / 72.0)
		points.append(at + Vector2(heading.x, heading.y * squash) * radius)
	return points

func _scalloped_case(at: Vector2, radius: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in 144:
		var a := TAU * i / 144.0
		var dir := Vector2.from_angle(a)
		points.append(at + Vector2(dir.x, dir.y * SQUASH) * (radius + cos(a * 12) * 7.0))
	return points

func _draw_board() -> void:
	# Scalloped fairground case, segmented brass bumpers and plum playfield.
	for layer in [
		[Vector2(0, 26), 388.0, Color("17131a")],
		[Vector2(0, 23), 369.0, FRAME],
		[Vector2(0, 15), 367.0, Color("4d2631")],
		[Vector2(0, 5), 365.0, WOOD],
		[Vector2.ZERO, 366.0, BRASS],
		[Vector2.ZERO, 362.0, Color("97474e")],
	]:
		_board.draw_colored_polygon(_scalloped_case(CENTER + Vector2(layer[0]), layer[1]), layer[2])
	for layer in [
		[Vector2.ZERO, 342.0, RUST],
		[Vector2.ZERO, 339.0, GOLD],
		[Vector2.ZERO, 333.0, Color("5d493c")],
		[Vector2.ZERO, 328.0, FELT_SHADE],
		[Vector2.ZERO, 315.0, FELT],
	]:
		_board.draw_colored_polygon(_ellipse(CENTER + Vector2(layer[0]), layer[1]), layer[2])
	for i in 12:
		var angle := TAU * i / 12.0
		var band := PackedVector2Array()
		for j in 9:
			band.append(_point(350, angle - 0.20 + j * 0.05))
		_board.draw_polyline(band, GOLD if i % 2 == 0 else Color("de7e75"), 7.0, true)
		_board.draw_polyline(band, BRASS if i % 2 == 0 else Color("c16f6a"), 2.0, true)
		for socket in [-0.17, 0.17]:
			var pos := _point(350, angle + socket)
			_board.draw_circle(pos, 2.5, FRAME, true, -1, true)
	for radius in [122.0, 165.0, 250.0, 299.0]:
		var ring := _ellipse(CENTER, radius)
		ring.append(ring[0])
		_board.draw_polyline(ring, Color("705169"), 2.0, true)
	for i in 6:
		var base := _angle(i)
		var p := _point(233, base + PI / 6.0)
		_board.draw_colored_polygon(_diamond(p, 9, 5), Color("b57c83"))
		for j in [-1, 1]:
			var wall := _point(RAIL_RADIUS, base + float(j) * 0.48)
			_board.draw_colored_polygon(_diamond(wall, 11, 8), FRAME)
			_board.draw_colored_polygon(_diamond(wall, 7, 4), GOLD.darkened(0.38))
		var lane := PackedVector2Array()
		for step in 15:
			lane.append(_point(INNER_RADIUS + 12, base - 0.34 + step * 0.68 / 14.0))
		_board.draw_polyline(lane, Color("835b79"), 26, true)
		_board.draw_polyline(lane, Color("4c2c48"), 18, true)
		_board.draw_polyline(lane, Color("b88759"), 1.5, true)
	_board.draw_colored_polygon(_ellipse(CENTER + Vector2(0, 9), 115), SHADOW)
	_board.draw_colored_polygon(_ellipse(CENTER, 113), BRASS)
	_board.draw_colored_polygon(_ellipse(CENTER, 107), Color("68414a"))
	_board.draw_colored_polygon(_ellipse(CENTER, 101), Color("49363d"))
	for i in 24:
		var pin := _point(106, i * TAU / 24.0)
		_board.draw_circle(pin, 1.9, GOLD, true, -1, true)
	_text(_board, "RELAY", CENTER + Vector2(0, -5), 25, IVORY)
	_text(_board, "S H E L F", CENTER + Vector2(0, 16), 12, GOLD)
	# Side plates carry the cabinet mark and a pair of art-deco sunbursts.
	for side in [-1, 1]:
		var plate := CENTER + Vector2(side * 456, 0)
		_board.draw_colored_polygon(_diamond(plate, 84, 112), Color("422333"))
		_board.draw_colored_polygon(_diamond(plate, 81, 107), WOOD)
		_board.draw_colored_polygon(_diamond(plate, 67, 95), FRAME)
		for i in 9:
			var angle := -PI + i * PI / 8.0
			var beam := Vector2.from_angle(angle)
			_board.draw_line(plate + Vector2(0, -12) + beam * 18, plate + Vector2(0, -12) + beam * (28 if i % 2 == 0 else 21), BRASS, 2.0, true)
		_board.draw_colored_polygon(_star(plate + Vector2(0, -11), 13, 0.52, 5), GOLD)
		_text(_board, "KNOCKDOWN" if side == -1 else "CARNIVAL", plate + Vector2(0, 19), 14, IVORY)

func _draw_round() -> void:
	if _state == null:
		return
	var tick: int = _state.tick
	for id in range(M.FIRST_SHARED, M.TARGETS):
		var next: int = _state.linked(id)
		if next >= 0:
			var a := target_pos(id)
			var b := target_pos(next)
			var active: bool = _state.available(id, tick) and _state.available(next, tick)
			var tint := GOLD if active else BRASS.darkened(0.48)
			var dir := (b - a).normalized()
			var mid := a.lerp(b, 0.5)
			_pieces.draw_line(a.lerp(b, 0.26), a.lerp(b, 0.73), tint, 2.2, true)
			_pieces.draw_colored_polygon(PackedVector2Array([mid + dir * 7, mid - dir * 5 + dir.orthogonal() * 5,
				mid - dir * 5 - dir.orthogonal() * 5]), tint)
	for slot in M.SEATS:
		var player: Dictionary = _state.players[slot]
		if player.active:
			_draw_routes(player)
	for id in M.TARGETS:
		if (_state.usable(id) if M.is_shared(id) else _state.players[floori(id / 3.0)].active):
			_draw_target(id)
	for slot in M.SEATS:
		if _state.players[slot].active:
			_draw_launcher(slot)
	for puck in _state.pucks:
		_draw_puck(puck)
	if _celebration > 0.0:
		_draw_confetti()

func _focused(slot: int) -> bool:
	return slot == _own if local_mask == 0 else (local_mask & (1 << slot)) != 0

func _draw_routes(player: Dictionary) -> void:
	var slot: int = player.slot
	var focused := _focused(slot)
	var tint := Kit.colors[slot].lerp(IVORY, 0.42)
	for line in M.LINES:
		var selected: bool = player.aim == line
		if not selected and not focused:
			continue
		var route := _route(slot, line)
		var at := maxi(int(_state.tick), int(player.ready)) + M.flight(line) + 1
		var value: int = _state.forecast(slot, line, at)
		var width := 3.2 if focused and selected else (1.6 if selected else 1.0)
		var color := Color(tint if value > 0 else Color("a6b09c"), 0.93 if focused and selected else (0.52 if selected else 0.37))
		for i in (1 if not selected and M.is_bank(line) else route.size() - 1):
			if M.is_bank(line) or value == 0 or not selected:
				_dashed(route[i], route[i + 1], color, width)
			else:
				_pieces.draw_line(route[i], route[i + 1], color, width, true)
		if focused and selected and M.is_bank(line):
			_pieces.draw_colored_polygon(_diamond(route[1], 9, 6), IVORY)

func _draw_target(id: int) -> void:
	var info: Dictionary = _state.targets[id]
	var tick: int = _state.tick
	var shared := M.is_shared(id)
	var pos := target_pos(id)
	var active: bool = _state.available(id, tick)
	var age: int = tick - int(info.down)
	var delay: int = int(info.up) - tick
	var tint := GOLD if shared else STEEL
	var radius := 21.0 if shared else 17.0
	var flip := 1.0
	if not active:
		flip = lerpf(1.0, 0.24, clampf(age / 10.0, 0.0, 1.0)) if age < M.FLIP_TICKS else 0.24
		if delay <= 13:
			flip = lerpf(0.24, 1.0, 1.0 - delay / 13.0)
		tint = tint.darkened(0.52)
	_pieces.draw_colored_polygon(_ellipse(pos + Vector2(0, 4), radius + 4, 0.36), SHADOW)
	_pieces.draw_rect(Rect2(pos - Vector2(radius - 3, -1), Vector2((radius - 3) * 2, 5)), BRASS)
	var y := (radius + 4.0) * flip
	var face_center := pos - Vector2(0, y * 0.73)
	var shape := _target_shape(face_center, radius, y, shared)
	_pieces.draw_colored_polygon(_target_shape(face_center, radius + 2, y + 2, shared), SHADOW)
	_pieces.draw_colored_polygon(shape, tint)
	_pieces.draw_colored_polygon(_target_shape(face_center - Vector2(0, 1), radius * 0.79, y * 0.81, shared),
		(Color("a1474b") if shared else FELT_SHADE) if active else Color("45343b"))
	if active:
		if shared:
			_pieces.draw_colored_polygon(_star(face_center, 10, 0.49, 5), IVORY)
		else:
			_text(_pieces, str(id % 3 + 2), face_center, 17, IVORY)
	elif age >= M.FLIP_TICKS:
		var sweep := 1.0 - clampf(delay / (390.0 if shared else 270.0), 0.0, 1.0)
		_pieces.draw_line(pos + Vector2(-radius, 9), pos + Vector2(radius, 9), SHADOW, 3.0, true)
		_pieces.draw_line(pos + Vector2(-radius, 9), pos + Vector2(lerpf(-radius, radius, sweep), 9), GOLD, 2.0, true)
	if age <= 23 and info.credit != 0:
		_sparks(pos, age / 23.0, id)
	if not active and delay <= 54 and delay > 0:
		_pieces.draw_arc(pos, radius + 7, -PI / 2.0, -PI / 2.0 + TAU * (55 - delay) / 55.0, 26, IVORY, 1.6, true)

func _draw_launcher(slot: int) -> void:
	var player: Dictionary = _state.players[slot]
	var pos := launch_pos(slot)
	var color := Kit.colors[slot]
	var recoil := clampf(1.0 - (int(_state.tick) - int(player.shot_tick)) / 12.0, 0.0, 1.0)
	var aim := _route(slot, player.aim)
	var dir := (aim[1] - pos).normalized()
	var axis := dir.orthogonal()
	var slide := pos - dir * 8.0 * recoil
	var muzzle := slide + dir * 18
	_pieces.draw_colored_polygon(_ellipse(pos + Vector2(0, 5), 26, 0.55), SHADOW)
	_pieces.draw_colored_polygon(_ellipse(pos, 24, 0.58), BRASS)
	_pieces.draw_colored_polygon(_ellipse(pos, 20, 0.58), Color("30383d"))
	_pieces.draw_colored_polygon(PackedVector2Array([slide + axis * 10 - dir * 14, muzzle + axis * 7,
		muzzle - axis * 7, slide - axis * 10 - dir * 14]), color.darkened(0.20))
	_pieces.draw_line(slide - dir * 9, muzzle, IVORY if _focused(slot) else color, 4.0, true)
	_pieces.draw_line(muzzle - axis * 7, muzzle + axis * 7, SHADOW, 3.0, true)
	var badge := _point(304, _angle(slot))
	_text(_pieces, str(slot + 1), badge, 19, IVORY, 4)
	if show_identities:
		var who := str(player.name).to_upper()
		_text(_pieces, who, badge + Vector2(0, -15), Kit.fit(who, 17, 105), IVORY, 5)
	if _focused(slot):
		var at := target_pos(_state.destination(slot, player.aim))
		_pieces.draw_arc(at, 26.0, 0.13, PI - 0.13, 24, IVORY, 2.5, true)
	var line: int = player.shot_line
	if line >= 0:
		var landed: int = player.shot_tick + M.flight(line)
		var age: int = _state.tick - landed
		if age >= 0 and age < 12:
			var id: int = _state.destination(slot, line)
			var record: Dictionary = _state.targets[id]
			if record.down != landed or (int(record.credit) & (1 << slot)) == 0:
				var puff := target_pos(id) + Vector2(0, -5)
				for i in 3:
					var shift := Vector2(i * 8 - 8, -4 - age) * 0.8
					_pieces.draw_circle(puff + shift, 2 + age * 0.4,
						Color(IVORY, (1.0 - age / 12.0) * 0.56), true, -1, true)

func _draw_puck(puck: Dictionary) -> void:
	var route := _route(puck.slot, puck.line)
	var smooth_tick := _clock + (_sep if client_motion else 0.0)
	var progress := clampf((smooth_tick - int(puck.born)) / (int(puck.land) - int(puck.born)), 0.0, 0.998)
	var tint := Kit.colors[puck.slot]
	var pos := _on_path(route, progress)
	var trace := pos
	for i in range(1, 6):
		var earlier := _on_path(route, maxf(0.0, progress - i * 0.045))
		_pieces.draw_line(trace, earlier, Color(tint, 0.8 - i * 0.13), 8.0 - i, true)
		trace = earlier
	if route.size() == 3 and absf(progress - 0.38) < 0.12:
		_sparks(route[1], (progress - 0.26) / 0.24, puck.slot + 8)
	_pieces.draw_circle(pos + Vector2(0, 4), 9, SHADOW, true, -1, true)
	_pieces.draw_circle(pos, 8.5, tint, true, -1, true)
	_pieces.draw_arc(pos, 6.0, PI, TAU, 12, IVORY, 2.0, true)
	_text(_pieces, str(int(puck.slot) + 1), pos, 11, SHADOW, 0)

static func _on_path(route: PackedVector2Array, progress: float) -> Vector2:
	if route.size() == 2:
		return route[0].lerp(route[1], progress)
	if progress <= 0.38:
		return route[0].lerp(route[1], progress / 0.38)
	return route[1].lerp(route[2], (progress - 0.38) / 0.62)

func _sparks(at: Vector2, u: float, id: int) -> void:
	for i in 8:
		var tangent := Vector2.from_angle(i * TAU / 8.0 + id * 0.13)
		var pos := at + Vector2(0, -9) + tangent * (9 + u * (32 + i % 3 * 8))
		_pieces.draw_line(pos, pos + tangent * (4 + 6 * (1 - u)), Color(IVORY if i % 2 == 0 else GOLD, 1 - u), 2.6, true)

func _draw_confetti() -> void:
	for i in 56:
		var a := i * 2.39996
		var u := 2.2 - _celebration
		var vel := 124.0 + (i * 317 % 330)
		var ray := Vector2(cos(a), sin(a) - 0.6)
		var pos := CENTER + ray * vel * u + Vector2(0, 190 * u * u)
		var color := Kit.colors[_champion] if _champion >= 0 and i % 2 == 0 else (GOLD if i % 3 else IVORY)
		_pieces.draw_line(pos, pos + Vector2.from_angle(a + u * (i % 5 + 2)) * 10.0, color, 4.0, true)

func _dashed(a: Vector2, b: Vector2, color: Color, width: float) -> void:
	var length := a.distance_to(b)
	var direction := (b - a).normalized()
	for i in range(0, ceili(length), 11):
		_pieces.draw_line(a + direction * i, a + direction * minf(i + 5.0, length), color, width, true)

static func _target_shape(at: Vector2, wide: float, high: float, shared: bool) -> PackedVector2Array:
	if shared:
		return PackedVector2Array([at + Vector2(0, -high), at + Vector2(wide * 0.9, -high * 0.46),
			at + Vector2(wide, high * 0.25), at + Vector2(wide * 0.52, high * 0.72),
			at + Vector2(-wide * 0.52, high * 0.72), at + Vector2(-wide, high * 0.25),
			at + Vector2(-wide * 0.9, -high * 0.46)])
	return PackedVector2Array([at + Vector2(-wide * 0.62, -high), at + Vector2(wide * 0.62, -high),
		at + Vector2(wide, -high * 0.52), at + Vector2(wide * 0.76, high * 0.72),
		at + Vector2(-wide * 0.76, high * 0.72), at + Vector2(-wide, -high * 0.52)])

static func _diamond(at: Vector2, wide: float, high: float) -> PackedVector2Array:
	return PackedVector2Array([at - Vector2(0, high), at + Vector2(wide, 0), at + Vector2(0, high), at - Vector2(wide, 0)])

static func _star(at: Vector2, radius: float, cut: float, tips: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in tips * 2:
		points.append(at + Vector2.from_angle(-PI / 2 + i * PI / tips) * radius * (1.0 if i % 2 == 0 else cut))
	return points

static func _text(node: Node2D, value: String, at: Vector2, size: int, color: Color, outline: int = 0) -> void:
	Kit.text(node, value, Vector2(at.x, Kit.baseline(at.y, size)), size, color, outline, 0.5)
