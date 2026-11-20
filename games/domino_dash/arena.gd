extends Node3D
## Readable tabletop geometry at both desktop and landscape phone sizes.

const M = preload("res://games/domino_dash/model.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const SIZE := Vector2(1110, 505)
const CENTER := Vector2(555, 244)
const GRID := Vector2(39, 31)
const ROOM := Color("14282c")
const INK := Color("152e32")
const EDGE := Color("29464a")
const WOOD := Color("dca664")
const CREAM := Color("fff2d3")
const GOLD := Color("ffcd66")
const OPEN := Color("b9f794")
const FELT := Color("25716a")
const STEEL := Color("385968")

var camera := Camera3D.new()
var local_mask := 0
var show_identities := false
var client_motion := false
var _main: Node
var _state: RefCounted
var _room: Node2D
var _board: Node2D
var _pieces: Node2D
var _viewport := Vector2.ZERO
var _menu := false
var _inset := 0.0
var _own := -1
var _tick := -1
var _fraction := 0.0
var _finish_fall := 0.0
var _champion := -1
var _celebration := 0.0

func _init(main: Node) -> void:
	_main = main

func _ready() -> void:
	add_child(camera)
	var layer := CanvasLayer.new()
	add_child(layer)
	_room = Node2D.new()
	_room.draw.connect(_draw_room)
	layer.add_child(_room)
	_board = Node2D.new()
	_board.draw.connect(_draw_board)
	layer.add_child(_board)
	_pieces = Node2D.new()
	_pieces.draw.connect(_draw_pieces)
	layer.add_child(_pieces)

func set_level(_level: String) -> void:
	pass

func set_menu(menu: bool) -> void:
	_menu = menu
	_champion = -1

func set_inset(value: float) -> void:
	_inset = value

func celebrate(slot: int) -> void:
	_champion = slot
	_celebration = 2.2

func update_visuals(state: RefCounted, delta: float, own: int = -1) -> void:
	if state != _state or (state != null and state.tick != _tick):
		_tick = state.tick if state != null else -1
		_fraction = 0.0
		_finish_fall = 0.0
	else:
		_fraction = minf(1.0, _fraction + delta * M.HZ)
	if state != null and state.phase == "finished":
		_finish_fall = minf(float(M.FALL_TICKS), _finish_fall + delta * M.HZ)
	_state = state
	_own = own
	_celebration = maxf(0.0, _celebration - delta)
	var viewport := get_viewport().get_visible_rect().size
	if viewport != _viewport:
		_viewport = viewport
		_room.queue_redraw()
	var safe: Vector2 = _main.area
	var scale_factor := minf((safe.x - 24.0) / SIZE.x, (safe.y - 145.0) / SIZE.y)
	var middle := viewport * 0.5 + Vector2(0, 15)
	if _menu:
		scale_factor = minf((safe.x - 24.0) / SIZE.x, (safe.y - 50.0) / SIZE.y)
		middle = Vector2(viewport.x * (0.56 + _inset * 0.24), viewport.y * 0.53)
	for surface in [_board, _pieces]:
		surface.scale = Vector2.ONE * scale_factor
		surface.position = middle - SIZE * scale_factor * 0.5
	_pieces.queue_redraw()

static func point(at: Vector2) -> Vector2:
	return CENTER + at * GRID

func _draw_room() -> void:
	_room.draw_rect(Rect2(Vector2.ZERO, _viewport), ROOM)
	for i in range(-2, ceili(_viewport.x / 160.0) + 5):
		var x := float(i) * 160.0
		_room.draw_line(Vector2(x, 0), Vector2(x - _viewport.y * 0.58, _viewport.y),
			Color("1d3739"), 63.0)
		_room.draw_line(Vector2(x + 47, 0), Vector2(x + 47 - _viewport.y * 0.58, _viewport.y),
			Color("1a3133"), 2.0)
	for y in [0.17, 0.67, 0.91]:
		_room.draw_line(Vector2(0, _viewport.y * y), Vector2(_viewport.x, _viewport.y * y),
			Color("253d3e"), 2.0)

func _draw_board() -> void:
	Kit.plate(_board, Kit.slab(Rect2(13, 13, 1080, 472), 12), WOOD.darkened(0.22), 4, 14, INK)
	Kit.plate(_board, Kit.slab(Rect2(13, 5, 1080, 464), 12), WOOD, 4, 4, INK)
	_board.draw_rect(Rect2(41, 27, 1028, 434), EDGE)
	_board.draw_rect(Rect2(47, 32, 1016, 423), FELT)
	for y in range(40, 455, 8):
		_board.draw_line(Vector2(49, y), Vector2(1061, y), Color(0.04, 0.22, 0.22, 0.14), 1.0)
	_board.draw_rect(Rect2(49, 197, 1012, 96), Color("20514f"))
	_board.draw_rect(Rect2(49, 208, 1012, 74), Color("193f42"))
	for y in [200, 290]:
		_board.draw_line(Vector2(52, y), Vector2(1058, y), Color("78b6a3"), 3.0)
	for x in [68, 1042]:
		for y in [51, 437]:
			var center := Vector2(x, y)
			_board.draw_circle(center + Vector2(0, 2), 9, INK)
			_board.draw_circle(center, 7, WOOD)
			_board.draw_line(center - Vector2(3, 3), center + Vector2(3, 3), INK, 2.0, true)
	for side in 2:
		var adj := -1.0 if side == 0 else 1.0
		var base := point(Vector2(0, 5.72 * -adj))
		for i in 9:
			var x := 83.0 + i * 14.0
			_board.draw_line(Vector2(x, base.y), Vector2(x + 9, base.y + 9 * adj), WOOD, 3.0, true)
			_board.draw_line(Vector2(1110 - x, base.y), Vector2(1101 - x, base.y + 9 * adj), WOOD, 3.0, true)
	for branch in M.BRANCHES:
		var origin := point(Vector2(M.branch_x(branch), 0))
		var tray := Rect2(origin - Vector2(106, 24), Vector2(212, 48))
		Kit.plate(_board, Kit.slab(tray, 7), STEEL, 2, 3, Color("7395a5"))
		for side in 2:
			var diamond := point(M.diamond_pos(branch, side))
			var step := 1.0 if side == 0 else -1.0
			_board.draw_line(diamond, origin + Vector2(0, step * 19), STEEL.lightened(0.19), 11, true)
			_board.draw_line(diamond, origin + Vector2(0, step * 18), INK, 3, true)

func _draw_pieces() -> void:
	if _state == null:
		return
	var targets: Array[Dictionary] = []
	for p in _state.players:
		var local := _is_local(p.slot)
		targets.append(_state.action_target(p.slot) if p.active and local else {})
	for p in _state.players:
		if p.active:
			_draw_starter(p, targets[p.slot])
	for branch in M.BRANCHES:
		_draw_bridge(branch, targets)
	var sorted: Array = _state.players.filter(func(p): return p.active)
	sorted.sort_custom(func(a, b): return a.pos.y < b.pos.y)
	for p in sorted:
		_draw_runner(p)
	for branch in M.BRANCHES:
		_draw_readiness(branch)
	if _champion >= 0 and _celebration > 0.0:
		var tint: Color = Kit.colors[_champion]
		for i in 26:
			var x := 65.0 + posmod(i * 113, 984)
			var y := 35.0 + fposmod((2.2 - _celebration) * (84 + i % 6 * 22) + i * 57, 408)
			_pieces.draw_rect(Rect2(x, y, 8, 5), tint.lerp(GOLD, (i % 5) * 0.2))

func _is_local(slot: int) -> bool:
	return slot == _own or (local_mask & (1 << slot)) != 0

func _draw_starter(player: Dictionary, target: Dictionary) -> void:
	var slot: int = player.slot
	var station: int = player.station
	var color: Color = Kit.colors[slot]
	var chain: Dictionary = _state.starters[slot]
	var first := point(M.starter_pos(station))
	var step := -1.0 if station % 2 == 0 else 1.0
	var last := point(M.domino_pos(station, station % 2, M.STARTER_LENGTH - 1, false))
	var diamond := point(M.diamond_pos(M.station_branch(station), station % 2))
	var frame := first - Vector2(39, 18) + Vector2(0, minf(0, last.y - first.y))
	Kit.plate(_pieces, Kit.slab(Rect2(frame, Vector2(78, absf(last.y - first.y) + 40)), 5),
		color.darkened(0.62), 2, 3, color.darkened(0.11))
	for dash in 3:
		var from := last.lerp(diamond, 0.18 + dash * 0.19)
		var to := last.lerp(diamond, 0.26 + dash * 0.19)
		_pieces.draw_line(from, to, color.lightened(0.14) if chain.owner >= 0 else Color("739b8f"), 4, true)
	_pieces.draw_line(diamond + Vector2(-7, -8 * step), diamond + Vector2(0, -2 * step), color, 3, true)
	_pieces.draw_line(diamond + Vector2(7, -8 * step), diamond + Vector2(0, -2 * step), color, 3, true)
	var badge := first + Vector2(-40, 0)
	_badge(badge, slot, color, 19)
	if chain.owner < 0 and _is_local(slot):
		var ready: bool = target.get("kind") == "starter"
		_ring(first, 27.0, CREAM if ready else color, ready)
	for rank in M.STARTER_LENGTH:
		_domino(M.domino_pos(station, station % 2, rank, false), rank + 1, Vector2(0, step),
			color, _fall(chain, rank))

func _draw_bridge(branch: int, targets: Array[Dictionary]) -> void:
	var chain: Dictionary = _state.bridges[branch]
	var open: bool = _state.aligned(branch)
	var locked: int = _state.opens_in(branch)
	var color: Color = Kit.colors[chain.owner] if chain.owner >= 0 else CREAM
	var root := point(Vector2(M.branch_x(branch), 0))
	for side in 2:
		var at := point(M.diamond_pos(branch, side))
		var glow := false
		for target in targets:
			if target.get("index") == branch and target.get("side") == side and target.get("kind") in ["bridge", "wait"]:
				glow = true
		var panel := color.darkened(0.45) if chain.owner >= 0 else (OPEN if open else (STEEL.lightened(0.15) if locked > 0 else GOLD.darkened(0.22)))
		var diamond := PackedVector2Array([at + Vector2(0, -19), at + Vector2(24, 0), at + Vector2(0, 19),
			at + Vector2(-24, 0)])
		Kit.plate(_pieces, diamond, panel, 3 if not glow else 5, 3, CREAM if glow else INK)
		if chain.owner >= 0:
			if side == chain.side:
				_text(str(chain.owner + 1), at, 22, CREAM)
			else:
				_pieces.draw_line(at - Vector2(6, 0), at + Vector2(6, 0), INK, 3, true)
		elif locked > 0:
			_pieces.draw_rect(Rect2(at - Vector2(6, 3), Vector2(12, 9)), INK)
			_pieces.draw_arc(at - Vector2(0, 3), 4, PI, TAU, 12, INK, 2, true)
		elif open:
			# Tip direction reverses with the approach.
			var dir := 1 if side == 0 else -1
			_pieces.draw_line(at + Vector2(-8 * dir, 0), at + Vector2(7 * dir, 0), INK, 3, true)
			_pieces.draw_line(at + Vector2(1 * dir, -5), at + Vector2(7 * dir, 0), INK, 3, true)
			_pieces.draw_line(at + Vector2(1 * dir, 5), at + Vector2(7 * dir, 0), INK, 3, true)
		else:
			_pieces.draw_arc(at, 8, 0, TAU, 18, INK, 2, true)
			_pieces.draw_line(at, at + Vector2(0, -5), INK, 2, true)
			_pieces.draw_line(at, at + Vector2(4, 1), INK, 2, true)

	var side: int = chain.side
	for rank in M.BRIDGE_LENGTH:
		_domino(M.domino_pos(branch, side, rank, true), rank + 1,
			Vector2.RIGHT if side == 0 else Vector2.LEFT, color, _fall(chain, rank))
	if chain.owner >= 0:
		_badge(root + Vector2(88, 0), chain.owner, color, 14)

func _draw_readiness(branch: int) -> void:
	if _state.bridges[branch].owner >= 0 or _state.phase == "finished":
		return
	var locked: int = _state.opens_in(branch)
	var open: bool = _state.aligned(branch)
	var remaining: int = _state.possible_falls(M.BRIDGE_LENGTH)
	if remaining == 0:
		return
	var caption := "%ds" % ceili(float(locked) / M.HZ) if locked > 0 else (
		("+%d" % remaining if remaining < M.BRIDGE_LENGTH else "OPEN") if open else "WAIT")
	var tint := OPEN if open else (STEEL.lightened(0.23) if locked > 0 else GOLD)
	for side in 2:
		var at := point(M.diamond_pos(branch, side))
		var anchor := at + Vector2(65, 0)
		_pieces.draw_line(at + Vector2(25, 0), anchor - Vector2(27, 0), tint, 2, true)
		var bounds := Rect2(anchor - Vector2(28, 13), Vector2(56, 24))
		Kit.plate(_pieces, Kit.slab(bounds, 4), INK, 2, 2, tint)
		_text(caption, anchor - Vector2(0, 1), 14, tint)
		if locked == 0:
			var alignment: int = _state.alignment(branch)
			var portion := 1.0 - float(alignment) / M.OPEN_TICKS if open else (
				float(alignment - M.OPEN_TICKS) / (M.PERIOD - M.OPEN_TICKS))
			_pieces.draw_line(bounds.position + Vector2(4, 25),
				bounds.position + Vector2(4 + 48 * portion, 25), tint, 3, true)

func _fall(chain: Dictionary, rank: int) -> float:
	if chain.owner < 0 or _tick < chain.start + rank * M.FALL_TICKS:
		return 0.0
	var time := float(_tick - chain.start - rank * M.FALL_TICKS) + _fraction + _finish_fall
	return smoothstep(0.0, M.FALL_TICKS, time)

func _domino(at: Vector2, pips: int, direction: Vector2, color: Color, fall: float) -> void:
	var foot := point(at)
	var lift := lerpf(28.0, 2.0, fall)
	var fall_plane := direction * (21.0 * fall)
	var top := foot + Vector2(0, -lift) + fall_plane
	if absf(top.y - foot.y) < 1.0:
		top.y = foot.y - 1.0
	var width := Vector2(9.0, 0.0) if direction.x == 0.0 else (
		Vector2(9.0 * (1.0 - fall), direction.x * 8.0 * fall))
	var thickness := Vector2(4, -3 if direction.x < 0.0 else 3)
	var face := PackedVector2Array([foot - width, foot + width, top + width, top - width])
	_pieces.draw_circle(foot + Vector2(3, 2), 10, Color(0.03, 0.11, 0.13, 0.4))
	var flank := PackedVector2Array([foot + width, foot + width + thickness, top + width + thickness, top + width])
	_pieces.draw_colored_polygon(flank, color.darkened(0.42))
	_pieces.draw_colored_polygon(face, color.lerp(CREAM, 0.15 * fall))
	_pieces.draw_polyline(PackedVector2Array([face[0], face[1], face[2], face[3], face[0]]), INK, 1.5, true)
	_pieces.draw_line(foot.lerp(top, 0.50) - width * 0.85, foot.lerp(top, 0.50) + width * 0.85, INK, 1.3, true)
	_pieces.draw_circle(foot.lerp(top, 0.25), 1.8, INK)
	for i in pips:
		var offset := Vector2(float(i % 2) - 0.5, floorf(i * 0.5) - 0.5)
		_pieces.draw_circle(foot.lerp(top, 0.76 + offset.y * 0.18) + width * offset.x * 0.83, 1.6, INK)
	if fall > 0.02 and fall < 0.82:
		_pieces.draw_arc(top, 13.0 + 13.0 * fall, 0.1, 3.1, 16, Color(CREAM, (1.0 - fall) * 0.76), 2.0, true)

func _draw_runner(player: Dictionary) -> void:
	var slot: int = player.slot
	var tint: Color = Kit.colors[slot]
	var at: Vector2 = player.pos
	if client_motion and _state.phase == "running":
		at += Vector2(player.vel) * (_fraction * M.STEP)
	var foot := point(at)
	var body := foot - Vector2(0, 15)
	var bob := sin(float(_tick) * 1.5 + slot) * 2.0 if Vector2(player.vel).length_squared() > 0.1 else 0.0
	_pieces.draw_circle(foot + Vector2(3, 4), 15, Color(0.07, 0.16, 0.17, 0.58))
	if _is_local(slot):
		_ring(foot, 22, CREAM, true)
	_pieces.draw_line(foot - Vector2(8, 1 + bob), body - Vector2(6, 0), INK, 7, true)
	_pieces.draw_line(foot + Vector2(8, -1 + bob), body + Vector2(6, 0), INK, 7, true)
	_pieces.draw_line(foot - Vector2(8, 1 + bob), body - Vector2(6, 0), tint.darkened(0.30), 4, true)
	_pieces.draw_line(foot + Vector2(8, -1 + bob), body + Vector2(6, 0), tint.darkened(0.30), 4, true)
	_badge(body - Vector2(0, bob), slot, tint, 16)
	if show_identities:
		_text(str(player.name).to_upper(), body - Vector2(0, 27), 18, CREAM, 4)

func _ring(at: Vector2, radius: float, color: Color, solid: bool) -> void:
	for quadrant in 4:
		var start := float(quadrant) * PI * 0.5
		_pieces.draw_arc(at, radius, start + 0.12, start + 1.39, 12, color, 3.0 if solid else 2.0, true)

func _badge(at: Vector2, slot: int, tint: Color, radius: float) -> void:
	_pieces.draw_circle(at, radius + 2.5, INK)
	_pieces.draw_circle(at, radius, tint)
	_pieces.draw_arc(at, radius - 2, 3.65, 5.49, 14, tint.lightened(0.51), 2.0, true)
	_text(str(slot + 1), at, roundi(radius * 1.3), INK)

func _text(caption: String, center: Vector2, size: int, color: Color, outline: int = 0) -> void:
	Kit.text(_pieces, caption, Vector2(center.x, Kit.baseline(center.y, size)), size, color, outline, 0.5)
