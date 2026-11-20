extends Node3D
## A tabletop drum machine. Each cell shows its owners, then plays a hit or a rest.

const Model = preload("res://games/gap_band/model.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const Platform = preload("res://scripts/platform.gd")
const SIZE := Vector2(840, 344)
const INK := Color("121820")
const PAPER := Color("f8f3de")
const GOLD := Color("ffd477")
const MINT := Color("93f9d0")
const QUIET := Color("b9bfcd")
const PANEL := Color("313746")
const CONFIRM := Rect2(268, 286, 304, 47)

var camera := Camera3D.new()
var local_mask := 0
var show_identities := false

var _main: Node
var _play: RefCounted
var _state: RefCounted
var _room := Node2D.new()
var _board := Node2D.new()
var _own := -1
var _menu := false
var _inset := 0.0
var _champion := -1
var _fingers: Dictionary = {}
var _groups: Array = []

func _init(main: Node, play: RefCounted) -> void:
	_main = main
	_play = play

func _ready() -> void:
	add_child(camera)
	var canvas := CanvasLayer.new()
	add_child(canvas)
	canvas.add_child(_room)
	canvas.add_child(_board)
	_room.draw.connect(_draw_room)
	_board.draw.connect(_draw_board)
	get_viewport().size_changed.connect(_room.queue_redraw)

func set_menu(menu: bool) -> void:
	_menu = menu
	_champion = -1
	clear_touches()

func set_inset(value: float) -> void:
	_inset = value

func celebrate(slot: int) -> void:
	_champion = slot
	_board.queue_redraw()

func update_visuals(state: RefCounted, _delta: float, own: int = -1) -> void:
	_state = state
	_own = own
	_groups = state.owners()
	var viewport := get_viewport().get_visible_rect().size
	var safe: Vector2 = _main.area
	var zoom := maxf(0.1, minf((safe.x - 20.0) / SIZE.x, (safe.y - 96.0) / SIZE.y))
	var center := Vector2(viewport.x * 0.5, viewport.y * 0.5 + 30.0)
	if _menu:
		center.x = viewport.x * (0.54 + _inset * 0.24)
	_board.position = center - SIZE * zoom * 0.5
	_board.scale = Vector2.ONE * zoom
	_board.queue_redraw()

func _cell(index: int) -> Rect2:
	var width: float = 776.0 / _state.cells
	return Rect2(32.0 + index * width + 3.0, 86.0, width - 6.0, 139.0)

func cell_screen_rect(index: int) -> Rect2:
	return _board.get_global_transform_with_canvas() * _cell(index)

func confirm_screen_rect() -> Rect2:
	return _board.get_global_transform_with_canvas() * CONFIRM

func clear_touches() -> void:
	_fingers.clear()

func _menu_rect() -> Rect2:
	var menu: Control = _main.hud_menu
	if not is_instance_valid(menu) or not menu.is_visible_in_tree():
		return Rect2()
	return (menu.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, menu.size)).grow(12.0)

func _hit(pos: Vector2) -> int:
	if _menu_rect().has_point(pos):
		return -2
	if confirm_screen_rect().has_point(pos):
		return -3
	for cell in _state.cells:
		if cell_screen_rect(cell).has_point(pos):
			return cell
	return -1

func _input(event: InputEvent) -> void:
	if not Platform.handheld or _menu or _main.view != "game" or _main.paused or _state == null or _state != _main.model:
		return
	if event is InputEventScreenDrag and _fingers.has(event.index):
		get_viewport().set_input_as_handled()
	if not event is InputEventScreenTouch:
		return
	if event.pressed and not event.canceled:
		var hit := _hit(event.position)
		if hit != -1:
			_fingers[event.index] = [hit, _state.measure, _state.window()]
			get_viewport().set_input_as_handled()
	elif _fingers.has(event.index):
		var press: Array = _fingers[event.index]
		_fingers.erase(event.index)
		get_viewport().set_input_as_handled()
		if event.canceled or press[0] != _hit(event.position):
			return
		if press[0] == -2:
			_main._toggle_pause()
		elif press[1] == _state.measure and press[2] == _state.window():
			if press[0] == -3:
				_play.confirm_touch()
			else:
				_play.select_cell(press[0])

func _draw_room() -> void:
	var screen := get_viewport().get_visible_rect().size
	_room.draw_rect(Rect2(Vector2.ZERO, screen), Color("403448"))
	for x in range(0, ceili(screen.x) + 80, 64):
		_room.draw_line(Vector2(x, 0), Vector2(x - 80, screen.y), Color("342c3d"), 3.0, true)
		_room.draw_line(Vector2(x + 4, 0), Vector2(x - 76, screen.y), Color("4c4054"), 1.0, true)
	_room.draw_rect(Rect2(0, screen.y * 0.85, screen.x, screen.y * 0.15), Color("302634"))

func _draw_board() -> void:
	if _state == null:
		return
	Kit.plate(_board, Kit.slab(Rect2(3, 3, 834, 335), 12), PANEL, 3, 7, INK)
	_board.draw_rect(Rect2(17, 13, 806, 311), Color("45404f"), false, 2)
	for screw in [Vector2(19, 18), Vector2(821, 18), Vector2(19, 320), Vector2(821, 320)]:
		_board.draw_circle(screw, 4.0, QUIET, true, -1.0, true)
		_board.draw_line(screw - Vector2(2, 2), screw + Vector2(2, 2), INK, 1.7, true)
	_draw_transport()
	for cell in _state.cells:
		_draw_cell(cell)
	_draw_seats()
	_draw_controls()

func _draw_transport() -> void:
	_board.draw_rect(Rect2(32, 21, 776, 55), INK)
	_label("MEASURE  %d / %d" % [_state.measure + 1, Model.MEASURES], Vector2(134, 45), 19, PAPER)
	var window: String = _state.window()
	var left: int = _state.deadline_ticks()
	var title := "GET READY"
	var tint := GOLD
	match window:
		"place", "revise":
			# Display the last host-confirmed clock without extrapolating its deadline.
			title = "%s   %.1f s" % [window.to_upper(), ceili(left / 2.0) / 10.0]
			tint = MINT if left > Model.HZ else GOLD
		"playback":
			var beat: int = _state.beat()
			title = "SEALED  /  COUNT-IN" if beat < 0 else "PLAYBACK  %d / %d" % [beat + 1, _state.cells]
			if _state.phase == "finished":
				title = "FINAL MEASURE"
	_label(title, Vector2(420, 44), 25, tint)
	_label("SOLO +1  •  ACCENT +2", Vector2(694, 45), 17, PAPER)
	var bar := Rect2(236, 64, 368, 5)
	_board.draw_rect(bar, Color("596276"))
	var fraction := 0.0
	match window:
		"place": fraction = float(left) / Model.PLACE_TICKS
		"revise": fraction = float(left) / (Model.SEAL_TICK - Model.PLACE_TICKS)
		"playback": fraction = clampf(float(_state.age() - Model.SEAL_TICK) / (Model.MEASURE_TICKS - Model.SEAL_TICK), 0, 1)
	if fraction > 0.0:
		_board.draw_rect(Rect2(bar.position, bar.size * Vector2(fraction, 1)), tint)

func _draw_cell(index: int) -> void:
	var box := _cell(index)
	var center := box.get_center()
	var owners: Array = _groups[index]
	var open := owners.is_empty()
	var muted := owners.size() > 1
	var accent: bool = index == _state.accent
	var playing: bool = _state.window() == "playback"
	var strike: bool = playing and _state.beat() == index and _state.phase != "finished"
	var pulse: float = 1.0 - _state.beat_progress() if strike else 0.0
	var fill := Color("202b37") if open else Color("2d3d51")
	if muted:
		fill = Color("443846")
	var rim := GOLD if accent else (MINT if open else QUIET)
	if strike:
		fill = fill.lerp(PAPER, pulse * (0.30 if owners.size() == 1 else 0.13))
	_board.draw_rect(box, fill)
	if muted:
		_hatch(box.grow(-5.0))
	_board.draw_rect(box, rim, false, 3.0 if open or accent else 2.0)
	if accent:
		_board.draw_rect(box.grow(-5.0), GOLD, false, 1.5)
	if strike:
		_board.draw_rect(box.grow(-4.0 - pulse * 3.0), PAPER, false, 3.0 + pulse * 2.5)
		var peg := Vector2(center.x, box.position.y - 3.5)
		_board.draw_colored_polygon(PackedVector2Array([peg + Vector2(-8, -4), peg + Vector2(8, -4), peg + Vector2(0, 7)]), PAPER)
	_label("%d  +2" % (index + 1) if accent else str(index + 1), Vector2(center.x, box.position.y + 19), 20, GOLD if accent else PAPER)
	var status := "OPEN" if open else ("MUTED" if muted else "SOLO")
	if playing:
		status = "REST" if open else ("MUTED" if muted else ("HIT +2" if accent else "HIT +1"))
	_label(status, Vector2(center.x, box.end.y - 16), 18, PAPER)
	if muted and (playing or _fixed_mute(owners)):
		_lock(Vector2(box.end.x - 15, box.position.y + 19))
	if strike and owners.size() != 1:
		_board.draw_line(center + Vector2(-17, 0), center + Vector2(17, 0), Color(PAPER, 0.4 + pulse * 0.6), 3.0, true)
	if strike and owners.size() == 1:
		_board.draw_arc(center, 30.0 + 16.0 * _state.beat_progress(), 0, TAU, 40, Color(PAPER, pulse), 3.5, true)
	for i in owners.size():
		var pos := center
		if owners.size() > 1:
			pos += Vector2((i % 3 - 1) * 26.0, -11.0 + 25.0 * floori(i / 3.0))
		elif strike:
			pos.y -= sin(_state.beat_progress() * PI) * 14.0
		var seat: int = owners[i]
		var p: Dictionary = _state.players[seat]
		_token(pos, seat, 15.0 if owners.size() == 1 else 10.0)
		if _state.window() == "revise" and not p.revised:
			_board.draw_arc(pos, 19.0 if owners.size() == 1 else 12.0, 0, TAU, 32, PAPER, 1.6, true)
	_draw_targets(index, box)

func _hatch(box: Rect2) -> void:
	for x in range(0, ceili(box.size.x + box.size.y), 10):
		var start := Vector2(maxf(0, x - box.size.y), minf(x, box.size.y))
		var finish := Vector2(minf(x, box.size.x), maxf(0, x - box.size.x))
		_board.draw_line(box.position + start, box.position + finish, Color("765e78"), 1.5, true)
		_board.draw_line(box.position + Vector2(start.x, box.size.y - start.y),
			box.position + Vector2(finish.x, box.size.y - finish.y), Color("674f67"), 1.2, true)

func _fixed_mute(owners: Array) -> bool:
	var settled := 0
	for seat in owners:
		settled += int(_state.players[seat].revised)
	return settled >= 2

func _lock(pos: Vector2) -> void:
	_board.draw_arc(pos - Vector2(0, 4), 4.5, PI, TAU, 16, PAPER, 1.7, true)
	_board.draw_rect(Rect2(pos - Vector2(6, 4), Vector2(12, 9)), PAPER)
	_board.draw_circle(pos + Vector2(0, 0.5), 1.7, INK, true, -1.0, true)

func _token(pos: Vector2, seat: int, radius: float) -> void:
	var vertices: int = [18, 4, 3, 4, 5, 6][seat]
	var rotation := PI * 0.25 if seat == 1 else 0.0
	var poly := PackedVector2Array()
	for i in vertices:
		poly.append(pos + Vector2.UP.rotated(rotation + i * TAU / vertices) * radius)
	_board.draw_colored_polygon(poly, Kit.colors[seat].lightened(0.22))
	poly.append(poly[0])
	_board.draw_polyline(poly, PAPER, 1.3, true)
	_label(str(seat + 1), pos, 14 if radius <= 10.0 else 19, INK)

func _draw_targets(index: int, box: Rect2) -> void:
	if _menu or _state.phase != "running":
		return
	var order := 0
	for p in _state.players:
		var seat: int = p.slot
		if not _is_local(seat) or not _state.can_confirm(p):
			continue
		var pending: int = _play.pending(seat)
		var cursor: int = pending if pending >= 0 else _play.cursor(seat)
		if cursor != index:
			continue
		var pos := box.position + Vector2(10 + order * 14, 38)
		if pending >= 0:
			_board.draw_arc(pos, 6, 0, TAU, 20, PAPER, 1.4, true)
		else:
			var tri := PackedVector2Array([pos + Vector2(-5, -6), pos + Vector2(5, -6), pos + Vector2(0, 5)])
			_board.draw_colored_polygon(tri, PAPER)
		_label(str(seat + 1), pos + Vector2(0, -1), 9, PAPER if pending >= 0 else INK)
		order += 1

func _is_local(seat: int) -> bool:
	return not _menu and (_own == seat or bool(local_mask & (1 << seat)))

func _draw_seats() -> void:
	var active: Array = _state.players.filter(func(p): return p.active)
	var width := 776.0 / maxf(1.0, active.size())
	for i in active.size():
		var p: Dictionary = active[i]
		var seat: int = p.slot
		var box := Rect2(32 + i * width + 3, 232, width - 6, 47)
		_board.draw_rect(box, Color("5b4e56") if _champion == seat else INK)
		if _is_local(seat) or _champion == seat:
			_board.draw_rect(box, PAPER, false, 1.5)
		_token(box.position + Vector2(14, 14), seat, 9)
		var role := "CPU" if p.bot else "YOU" if _is_local(seat) and not _main.shared_screen else "P%d" % (seat + 1)
		if show_identities and not str(p.name).is_empty():
			role = str(p.name).left(6)
		_label(role, box.position + Vector2(61, 14), 16, PAPER)
		_label(str(p.score), Vector2(box.end.x - 19, box.position.y + 14), 19, GOLD)
		_label(_seat_status(p), Vector2(box.get_center().x, box.end.y - 12), 15, PAPER)

func _seat_status(p: Dictionary) -> String:
	var seat: int = p.slot
	match _state.window():
		"countdown":
			return "READY"
		"playback":
			if p.note < 0:
				return "NO NOTE"
			return "+%d POINTS" % p.last_points if p.last_points == 2 else ("+1 POINT" if p.last_points == 1 else "MUTED  +0")
		"place":
			if p.placed:
				return "CONFIRMED  %d" % (p.note + 1)
		"revise":
			if p.revised:
				return "SLOT %d LOCKED" % (p.note + 1)
	if _is_local(seat) and _play.pending(seat) >= 0:
		return "PENDING %d" % (_play.pending(seat) + 1)
	if p.aim >= 0:
		return "%s → %d" % ["MOVE" if p.note >= 0 else "PLACE", p.aim + 1]
	if _is_local(seat):
		return "%s → %d" % ["MOVE" if p.note >= 0 else "PLACE", _play.cursor(seat) + 1]
	return "MOVE OPEN" if p.note >= 0 else "PLACE OPEN"

func _draw_controls() -> void:
	if _menu:
		_label("SOLO HITS SCORE. SHARED SLOTS PLAY A REST.", CONFIRM.get_center(), 18, PAPER)
		return
	if Platform.handheld:
		var p: Dictionary = _state.players[_own] if _own >= 0 else {}
		var can_act: bool = not p.is_empty() and _state.can_confirm(p) and _play.pending(_own) < 0
		var title := "CONFIRM  %d" % (_play.cursor(_own) + 1) if can_act else "CONFIRM"
		if can_act:
			title = ("MOVE TO  %d" if p.note >= 0 else "PLACE ON  %d") % (_play.cursor(_own) + 1)
		Kit.plate(_board, Kit.slab(CONFIRM, 6), MINT if can_act else INK, 2, 3, PAPER if can_act else QUIET)
		_label(title, CONFIRM.get_center(), 24, INK if can_act else QUIET)
		_label("TAP A SLOT", Vector2(154, CONFIRM.get_center().y), 19, PAPER)
		if not _main.session.is_server():
			_label("HOST CLOCK", Vector2(686, CONFIRM.get_center().y), 17, QUIET)
		return
	var pad: bool = _main.pad_captions()
	var hint := "STICK / D-PAD   •   A TO CONFIRM" if pad else "WASD / ARROWS   •   SPACE TO CONFIRM"
	if _main.shared_screen:
		hint = "MOVE   •   SPACE / A TO CONFIRM"
	_label(hint, CONFIRM.get_center(), 19, PAPER)
	if not _main.session.is_server():
		_label("HOST CLOCK", Vector2(720, CONFIRM.get_center().y), 17, QUIET)

func _label(value: String, point: Vector2, size: int, tint: Color) -> void:
	Kit.text(_board, value, Vector2(point.x, Kit.baseline(point.y, size)), size, tint, 0, 0.5)
