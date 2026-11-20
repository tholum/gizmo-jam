extends Node3D
## A fixed parade map. Float motion and route cues share the host's geometry.

const Model = preload("res://games/bandwagon/model.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const Platform = preload("res://scripts/platform.gd")
const SIZE := Vector2(800, 356)
const INK := Color("342c43")
const PLUM := Color("4b3a52")
const PAPER := Color("fff1d3")
const CREAM := Color("ffe1a1")
const GOLD := Color("ffca6e")
const LEFT := Color("64ead0")
const RIGHT := Color("ffc08a")
const ROAD := Color("6e5370")
const GATE_Y := 74.0
const GATE_SPREAD := 246.0
const ENGINE := Vector2(400, 160)
const NAME_SIZE := 12
const NAME_WIDTH := 44.0
const TRAIN_INSET := 36.0

var camera := Camera3D.new()
var local_mask := 0
var show_identities := false

var _main: Node
var _state: RefCounted
var _room := Node2D.new()
var _board := Node2D.new()
var _floats := Node2D.new()
var _visual_pos := PackedVector2Array()
var _pulls := PackedFloat32Array()
var _last_fork := -1
var _own := -1
var _menu := false
var _inset := 0.0
var _clock := 0.0
var _champion := -1

func _init(main: Node) -> void:
	_main = main
	_visual_pos.resize(Model.SEATS)
	_pulls.resize(Model.SEATS)

func _ready() -> void:
	add_child(camera)
	var canvas := CanvasLayer.new()
	add_child(canvas)
	canvas.add_child(_room)
	canvas.add_child(_board)
	canvas.add_child(_floats)
	_room.draw.connect(_draw_room)
	_board.draw.connect(_draw_board)
	_floats.draw.connect(_draw_floats)
	get_viewport().size_changed.connect(_room.queue_redraw)

func set_menu(menu: bool) -> void:
	_menu = menu
	_champion = -1

func set_inset(value: float) -> void:
	_inset = value

func celebrate(slot: int) -> void:
	_champion = slot

func update_visuals(state: RefCounted, delta: float, own: int = -1) -> void:
	_own = own
	_clock += delta
	var reset: bool = state != _state or _last_fork != state.fork
	_state = state
	_last_fork = state.fork
	for p in state.players:
		if not p.active:
			continue
		var slot: int = p.slot
		var at := Vector2(p.pos)
		_visual_pos[slot] = at if reset else _visual_pos[slot].lerp(at, minf(1.0, delta * 23.0))
		_pulls[slot] = lerpf(_pulls[slot], float(p.pull), minf(1.0, delta * 13.0))

	var viewport := get_viewport().get_visible_rect().size
	var safe: Vector2 = _main.area
	var span := safe.x
	if Platform.handheld and not _menu:
		span *= 0.87
	var zoom := minf((span - 32.0) / SIZE.x, (safe.y - 170.0) / SIZE.y)
	var center := viewport * 0.5 + Vector2(0, 5)
	if _menu:
		zoom = minf((safe.x - 38.0) / SIZE.x, (safe.y - 120.0) / SIZE.y)
		center = viewport * Vector2(0.56 + _inset * 0.26, 0.51)
	for layer in [_board, _floats]:
		layer.position = center - SIZE * zoom * 0.5
		layer.scale = Vector2.ONE * zoom
		layer.queue_redraw()

func _draw_room() -> void:
	var viewport := get_viewport().get_visible_rect().size
	_room.draw_rect(Rect2(Vector2.ZERO, viewport), Color("644b68"))
	_room.draw_rect(Rect2(0, 0, viewport.x, viewport.y * 0.39), Color("59445f"))
	# Paper bunting and scattered foil make a parade backdrop without masking cues.
	for band in 2:
		var y := viewport.y * (0.11 + band * 0.76)
		for x in range(-36, roundi(viewport.x) + 60, 50):
			var index := (x + 36) / 50
			var a := Vector2(x, y + 19.0 * sin(x * 0.012 + band))
			var b := Vector2(x + 50, y + 19.0 * sin((x + 50) * 0.012 + band))
			_room.draw_line(a, b, Color("372c42"), 2.0, true)
			_poly(_room, [a + Vector2(7, 1), a.lerp(b, 0.66), a + Vector2(20, 17)],
				[CREAM, LEFT, RIGHT][index % 3].darkened(0.36))
	for i in 60:
		var spot := Vector2(fposmod(i * 132.73, viewport.x), fposmod(i * 83.49, viewport.y))
		_room.draw_line(spot, spot + Vector2(4 if i % 2 else -4, 7), Color("886e85"), 2.0, true)

func _draw_board() -> void:
	if _state == null:
		return
	Kit.plate(_board, Kit.slab(Rect2(10, 4, 780, 345), 16), CREAM, 4, 8, INK)
	Kit.plate(_board, Kit.slab(Rect2(18, 10, 764, 325), 13), ROAD, 3, 4, INK)
	_board.draw_rect(Rect2(27, 16, 746, 122), PLUM)
	_board.draw_rect(Rect2(27, 252, 746, 74), Color("775c76"))
	for route in [-1, 1]:
		_draw_route(route)
		_draw_booth(route)
	_draw_sign()
	_draw_hitches()
	_caption(_board, _lane_instruction(), Vector2(400, 326), 13, PAPER)

func _lane_instruction() -> String:
	if _state.locked_route:
		return "POINTS BANKED" if _state.fork_age() >= Model.CROSS_TICK else "Riders and points are locked"
	if not _state.booths_open():
		return "BOOTH ENTRY CLOSED  •  RETURN TO YOUR HITCH"
	return "Release to visit a crest booth  •  Hold to latch again"

func _draw_route(route: int) -> void:
	var gate := _gate(route)
	var color := _route_color(route)
	var selected: bool = _state.lead_route() == route
	var sealed: bool = _state.locked_route == route
	var road := PackedVector2Array([ENGINE, Vector2(400 + route * 103, 141), gate + Vector2(0, 29), gate])
	_board.draw_polyline(road, INK, 39.0, true)
	_board.draw_polyline(road, color.darkened(0.64), 33.0, true)
	for i in range(1, road.size()):
		var a := road[i - 1]
		var b := road[i]
		for dash in range(0, int(a.distance_to(b)), 13):
			var heading := (b - a).normalized()
			_board.draw_line(a + heading * dash, a + heading * (dash + 5), PAPER if selected else color.darkened(0.27), 2, true)
	var casing := Rect2(gate.x - 106, 41, 212, 57)
	for side in [-1, 1]:
		var foot := Vector2(gate.x + side * 35.0, 121)
		_board.draw_line(foot - Vector2(0, 25), foot, INK, 10.0, true)
		_board.draw_line(foot - Vector2(0, 25), foot, color, 5.0, true)
	Kit.plate(_board, Kit.slab(casing, 10), color if sealed else INK, 2, 4, color)
	if selected and not sealed:
		_stripes(_board, Rect2(casing.position + Vector2(14, 4), Vector2(185, 7)), color)
	_badge(_board, gate + Vector2(-81, -2), 15, route, color if not sealed else INK, sealed)
	var tally: int = _state.left_pulls if route == -1 else _state.right_pulls
	var direction := "LEFT" if route == -1 else "RIGHT"
	_caption(_board, "%s  %d" % [direction, tally], gate + Vector2(-11, -2), 21, INK if sealed else PAPER)
	if _state.tiebreak == route and not _state.locked_route:
		_caption(_board, "◀  TIE" if route == -1 else "TIE  ▶", gate + Vector2(66, 4), 13, CREAM)
	elif sealed:
		_padlock(_board, gate + Vector2(72, -3), INK)
	_caption(_board, "LOCKED" if sealed else ("LEADING" if selected else ""), gate + Vector2(0, -49), 17, color)

func _draw_sign() -> void:
	var age: int = _state.fork_age()
	var title := "FORK %d / %d" % [_state.fork + 1, Model.FORKS]
	var secs: int = ceili(float(Model.BOOTH_CLOSE_TICK - age) / Model.HZ)
	var subtitle := "BOOTH ENTRY  %ds" % maxi(0, secs)
	if not _state.booths_open():
		subtitle = "LOCK IN  %ds" % ceili(float(Model.LOCK_TICK - age) / Model.HZ)
	if _state.locked_route:
		subtitle = "CROSSED" if age >= Model.CROSS_TICK else "LOCKED"
	Kit.plate(_board, Kit.slab(Rect2(300, 19, 200, 68), 8), INK, 2, 4, GOLD)
	_caption(_board, title, Vector2(400, 37), 19, PAPER)
	_caption(_board, subtitle, Vector2(400, 58), 15, GOLD)
	var span := Model.BOOTH_CLOSE_TICK
	var remaining := maxi(0, span - age)
	if not _state.booths_open():
		span = Model.LOCK_TICK - Model.BOOTH_CLOSE_TICK
		remaining = maxi(0, Model.LOCK_TICK - age)
	_board.draw_rect(Rect2(325, 75, 150, 4), PLUM)
	_board.draw_rect(Rect2(325, 75, 150.0 * remaining / span, 4), GOLD)

func _draw_booth(route: int) -> void:
	var spot := Vector2(Model.BOOTHS[route])
	var tint := _route_color(route) if _state.booths_open() else Color("ae9ea6")
	var reach := Vector2(Model.BOOTH_RANGE)
	var pad := Rect2(spot - reach, reach * 2)
	_board.draw_rect(pad, INK)
	_board.draw_rect(pad, tint, false, 2.0)
	_stripes(_board, Rect2(pad.position.x + 3, pad.end.y - 8, pad.size.x - 6, 5), tint)
	# An outlined awning sits behind the entry box so floats remain visible.
	var sign := Rect2(spot.x - 54, spot.y - 68, 108, 35)
	Kit.plate(_board, Kit.slab(sign, 7), tint, 2, 3, INK)
	_badge(_board, spot + Vector2(-32, -51), 9, route, INK, true)
	_caption(_board, "BOOTH" if _state.booths_open() else "CLOSED", spot + Vector2(12, -51), 15, INK)
	_board.draw_line(spot + Vector2(-29, -32), spot + Vector2(-29, -25), tint, 4)
	_board.draw_line(spot + Vector2(29, -32), spot + Vector2(29, -25), tint, 4)
	for y in [270.0, 302.0]:
		var min_x := minf(spot.x + route * -42, 400)
		var max_x := maxf(spot.x + route * -42, 400)
		for x in range(ceili(min_x), floori(max_x), 15):
			_board.draw_line(Vector2(x, y), Vector2(x + 6, y), Color("99798f"), 2.0)

func _draw_hitches() -> void:
	for p in _state.players:
		if not p.active:
			continue
		var pos := Vector2(p.hitch)
		var tint: Color = Kit.colors[p.slot]
		var reach := Vector2(Model.HITCH_RANGE)
		var socket := Rect2(pos - reach + Vector2(0, 9), Vector2(reach.x * 2, reach.y + 11))
		_board.draw_line(Vector2(pos.x, ENGINE.y + 17), pos, INK, 6.0, true)
		_board.draw_line(Vector2(pos.x, ENGINE.y + 17), pos, tint.darkened(0.21), 2.0, true)
		_board.draw_rect(socket, INK)
		_board.draw_rect(socket, tint, false, 2.0)
		_stripes(_board, Rect2(socket.position + Vector2(4, 4), Vector2(socket.size.x - 8, 6)), tint)
		_caption(_board, str(p.slot + 1), pos + Vector2(0, 1), 19, PAPER)
		if not p.riding:
			_poly(_board, [pos + Vector2(-5, 30), pos + Vector2(0, 23), pos + Vector2(5, 30)], tint)

func _draw_floats() -> void:
	if _state == null:
		return
	var lead: int = _state.lead_route()
	var engine := ENGINE + _travel(lead)
	if not _state.locked_route:
		engine.x += clampf((_state.right_pulls - _state.left_pulls) * 4.0, -13.0, 13.0)
	var bob := sin(_clock * 12.0) * 1.5
	engine.y += bob
	for p in _state.players:
		if p.active and p.riding:
			var finish := _float_position(p, lead)
			_floats.draw_line(engine + Vector2(0, 10), finish, INK, 5.0, true)
			_floats.draw_line(engine + Vector2(0, 10), finish, Kit.colors[p.slot], 2.0, true)
	_draw_engine(engine)
	for riding in [true, false]:
		for p in _state.players:
			if p.active and p.riding == riding:
				_draw_float(p, _float_position(p, lead), lead)

func _float_position(p: Dictionary, lead: int) -> Vector2:
	var pos := _visual_pos[p.slot]
	if p.riding:
		var travel := _travel(lead)
		travel.x *= 1.0 - TRAIN_INSET / GATE_SPREAD
		pos += travel + Vector2(_pulls[p.slot] * 2.0, sin(_clock * 9.0 + p.slot) * 1.5)
	return pos

func _travel(route: int) -> Vector2:
	if not _state.locked_route:
		return Vector2.ZERO
	# Locked at the hitch for nearly a beat before the parade starts forward.
	var t := clampf(float(_state.fork_age() - Model.LOCK_TICK - 9) / (Model.CROSS_TICK - Model.LOCK_TICK - 9), 0.0, 1.0)
	return (Vector2(400 + route * GATE_SPREAD, GATE_Y + 42) - ENGINE) * smoothstep(0.0, 1.0, t)

func _draw_engine(pos: Vector2) -> void:
	var shell := Rect2(pos + Vector2(-45, -18), Vector2(90, 35))
	Kit.plate(_floats, Kit.slab(shell, 9), GOLD, 3, 5, INK)
	for i in [-1, 1]:
		_wheel(pos + Vector2(i * 28, 17), 9, CREAM)
	_floats.draw_rect(Rect2(pos + Vector2(-30, -26), Vector2(60, 12)), LEFT)
	_floats.draw_rect(Rect2(pos + Vector2(-30, -26), Vector2(60, 12)), INK, false, 2)
	_stripes(_floats, Rect2(pos + Vector2(-27, -24), Vector2(55, 7)), INK)
	_floats.draw_circle(pos + Vector2(-59, 0), 7, CREAM, true, -1, true)
	_floats.draw_circle(pos + Vector2(59, 0), 7, CREAM, true, -1, true)
	if _state.locked_route:
		_padlock(_floats, pos, INK)
	else:
		_caption(_floats, "PARADE", pos, 14, INK)

func _draw_float(p: Dictionary, pos: Vector2, lead: int) -> void:
	var tint: Color = Kit.colors[p.slot]
	var locked: bool = _state.locked_route != 0
	var seat_bit := 1 << int(p.slot)
	var points := int(p.riding) + int(p.riding and p.crest == lead)
	if locked:
		points = int(bool(_state.locked_riders & seat_bit)) + int(bool(_state.locked_bonus & seat_bit))
	var own: bool = p.slot == _own or bool(local_mask & seat_bit)
	var shell := Rect2(pos + Vector2(-21, -7), Vector2(42, 24))
	if own or p.slot == _champion:
		_floats.draw_rect(shell.grow(4), PAPER)
	Kit.plate(_floats, Kit.slab(shell, 5), tint, 2, 3, INK)
	for i in [-1, 1]:
		_wheel(pos + Vector2(i * 12, 17), 5, tint.lightened(0.28))
	_floats.draw_circle(pos + Vector2(0, 5), 9, INK, true, -1, true)
	_caption(_floats, str(p.slot + 1), pos + Vector2(0, 5), 14, PAPER)
	# Worn crest is attached to the left flag; lead/locked payout is on the
	# separate right placard with a distinct, always visible +N.
	_floats.draw_line(pos + Vector2(-13, -6), pos + Vector2(-13, -34), INK, 3, true)
	_floats.draw_rect(Rect2(pos + Vector2(-25, -40), Vector2(21, 21)), INK)
	_badge(_floats, pos + Vector2(-13, -30), 7, p.crest, PAPER, true)
	var readout := Rect2(pos + Vector2(-1, -40), Vector2(28, 21))
	var color := _route_color(lead)
	_floats.draw_rect(readout, color if locked else INK)
	_floats.draw_rect(readout, color, false, 1)
	if not locked:
		_stripes(_floats, Rect2(readout.position + Vector2(2, 2), Vector2(23, 4)), color)
	_badge(_floats, readout.position + Vector2(6, 12), 4.5, lead, INK if locked else color, locked)
	_caption(_floats, "+%d" % points, readout.position + Vector2(19, 12), 11, INK if locked else PAPER)
	if p.pull:
		var d: float = p.pull
		var arrow := pos + Vector2(d * 14, 5)
		_poly(_floats, [arrow + Vector2(d * 6, 0), arrow + Vector2(0, -5), arrow + Vector2(0, 5)], INK)
		_poly(_floats, [arrow + Vector2(d * 4, 0), arrow + Vector2(d, -3), arrow + Vector2(d, 3)], PAPER)
	if show_identities:
		_caption(_floats, _fit_name(p.name, p.slot), pos + Vector2(0, -50), NAME_SIZE, PAPER, 3)

static func _fit_name(full_name: String, slot: int) -> String:
	var number := slot + 1
	if full_name == "PLAYER %d" % number or (slot == 0 and full_name == "PLAYER"):
		return "P%d" % number
	if Kit.text_width(full_name, NAME_SIZE) <= NAME_WIDTH:
		return full_name
	var end := full_name.length()
	while end > 0:
		end -= 1
		var shortened := full_name.left(end) + "…"
		if Kit.text_width(shortened, NAME_SIZE) <= NAME_WIDTH:
			return shortened
	return ""

func _wheel(pos: Vector2, radius: float, tint: Color) -> void:
	_floats.draw_circle(pos, radius, INK, true, -1.0, true)
	_floats.draw_circle(pos, radius * 0.45, tint, true, -1.0, true)
	var turn := _clock * 9.0
	_floats.draw_line(pos, pos + Vector2.from_angle(turn) * radius * 0.82, tint, 1.2, true)

func _gate(route: int) -> Vector2:
	return Vector2(400 + route * GATE_SPREAD, GATE_Y)

static func _route_color(route: int) -> Color:
	return LEFT if route == -1 else RIGHT

static func _caption(ci: CanvasItem, label: String, pos: Vector2, size: int, color: Color, outline: int = 0) -> void:
	Kit.text(ci, label, Vector2(pos.x, Kit.baseline(pos.y, size)), size, color, outline, 0.5)

static func _poly(ci: CanvasItem, points: Array, tint: Color) -> void:
	ci.draw_colored_polygon(PackedVector2Array(points), tint)

static func _badge(ci: CanvasItem, pos: Vector2, radius: float, crest: int, tint: Color, filled: bool) -> void:
	if crest == 0:
		ci.draw_circle(pos, radius * 0.70, tint, false, 2.0, true)
		return
	var points := PackedVector2Array()
	var count := 10 if crest == -1 else 4
	for i in count:
		var dist := radius * (0.44 if crest == -1 and i % 2 else 1.0)
		points.append(pos + Vector2.from_angle(-PI * 0.5 + TAU * i / count) * dist)
	if filled:
		ci.draw_colored_polygon(points, tint)
	else:
		points.append(points[0])
		ci.draw_polyline(points, tint, 2.0, true)

static func _padlock(ci: CanvasItem, pos: Vector2, tint: Color) -> void:
	ci.draw_arc(pos - Vector2(0, 3), 5.0, PI, TAU, 12, tint, 2.5, true)
	ci.draw_rect(Rect2(pos + Vector2(-7, -3), Vector2(14, 11)), tint)

static func _stripes(ci: CanvasItem, rect: Rect2, tint: Color) -> void:
	for i in range(5, int(rect.size.x) - 3, 9):
		var p := rect.position + Vector2(i, 0)
		ci.draw_line(p, p + Vector2(-4, rect.size.y), tint, 2.0, true)
