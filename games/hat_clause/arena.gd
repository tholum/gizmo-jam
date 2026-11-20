extends Node3D
## A fixed hatcheck floor. Numbered tickets and tethers share one board.

const Model = preload("res://games/hat_clause/model.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const Platform = preload("res://scripts/platform.gd")
const SIZE := Vector2(800, 417)
const INK := Color("28243c")
const PAPER := Color("fff3dc")
const SAND := Color("f2c586")
const MINT := Color("82f0c9")
const SALMON := Color("fab39d")
const FLOOR := Color("436d69")
const GARNET := Color("9c3d51")
const CLOSE_TETHER := 48.0
const COLORS := [Color("efb678"), Color("a1e2cd"), Color("fac0bf"), Color("cad2f4"), Color("f7dc76")]

var camera := Camera3D.new()
var local_mask := 0
var show_identities := false

var _main: Node
var _state: RefCounted
var _room := Node2D.new()
var _board := Node2D.new()
var _visual := PackedVector2Array()
var _previous_bell := -1
var _own := -1
var _menu := false
var _inset := 0.0
var _clock := 0.0
var _champion := -1

func _init(main: Node) -> void:
	_main = main
	_visual.resize(Model.SEATS)

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

func set_inset(value: float) -> void:
	_inset = value

func celebrate(slot: int) -> void:
	_champion = slot
	_board.queue_redraw()

func update_visuals(state: RefCounted, delta: float, own: int = -1) -> void:
	var reset: bool = state != _state or state.bell != _previous_bell
	_state = state
	_own = own
	_previous_bell = state.bell
	_clock += delta
	for p in state.players:
		if p.active:
			var point := Vector2(p.pos)
			_visual[p.slot] = point if reset else _visual[p.slot].lerp(point, minf(1.0, delta * 25.0))
	var viewport := get_viewport().get_visible_rect().size
	var safe: Vector2 = _main.area
	var width := safe.x * (0.89 if Platform.handheld and not _menu else 1.0)
	var zoom := maxf(0.1, minf((width - 28.0) / SIZE.x, (safe.y - 175.0) / SIZE.y))
	var center := viewport * 0.5 + Vector2(0, 9)
	if _menu:
		zoom = maxf(0.1, minf((safe.x - 44.0) / SIZE.x, (safe.y - 106.0) / SIZE.y))
		center = viewport * Vector2(0.56 + _inset * 0.26, 0.51)
	_board.position = center - SIZE * zoom * 0.5
	_board.scale = Vector2.ONE * zoom
	_board.queue_redraw()

func _draw_room() -> void:
	var viewport := get_viewport().get_visible_rect().size
	_room.draw_rect(Rect2(Vector2.ZERO, viewport), Color("412d48"))
	for x in range(0, ceili(viewport.x), 74):
		_room.draw_rect(Rect2(x, 0, 27, viewport.y), Color("47334e"))
		_room.draw_line(Vector2(x + 28, 0), Vector2(x + 28, viewport.y), Color("3b2a42"), 3.0)
	_room.draw_rect(Rect2(0, viewport.y * 0.85, viewport.x, viewport.y * 0.15), Color("35253b"))

func _draw_board() -> void:
	if _state == null:
		return
	var age: int = _state.bell_age()
	Kit.plate(_board, Kit.slab(Rect2(14, 7, 772, 394), 12), GARNET, 4, 9, INK)
	_board.draw_rect(Rect2(36, 105, 728, 282), Color("577b70"))
	_board.draw_rect(Rect2(62, 176, 676, 209), FLOOR)
	_board.draw_rect(Rect2(83, 199, 634, 180), Color("86a68d"), false, 3.0)
	for y in range(229, 379, 37):
		for x in range(102, 698, 36):
			_board.draw_circle(Vector2(x + ((y / 37) % 2) * 14, y), 1.6, Color("638e80"))
	_draw_clock(age)
	for p in _state.players:
		if p.active:
			_draw_ticket(p)
	_draw_counter(age)
	if _state.phase != "finished":
		for p in _state.players:
			if p.active and p.target >= 0:
				_draw_tether(p)
	var order: Array = _state.players.filter(func(p): return p.active)
	order.sort_custom(func(p, q): return _visual[p.slot].y < _visual[q.slot].y)
	for p in order:
		_draw_guest(p)
	for p in order:
		_draw_toss(p)
	if _state.phase != "finished":
		for p in order:
			if p.target >= 0 and ((local_mask & (1 << p.slot)) != 0 or _own == p.slot):
				_draw_close_tether(p)
	if (_state.bell > 0 and age < 22) or _state.phase == "finished":
		_draw_payoff()

func _draw_clock(age: int) -> void:
	var part: int = maxi(0, Model.BELL_TICKS - age)
	var full: int = ceili(_state.remaining())
	var seconds := "%d:%02d" % [floori(full / 60.0), full % 60]
	_placard(Rect2(35, 24, 124, 34), "MATCH  " + seconds, INK, SAND, 15)
	_placard(Rect2(262, 20, 276, 45), "BELL  %d / %d     %02d s" % [_state.bell + 1, Model.BELLS,
		ceili(part * Model.STEP)], INK, PAPER, 23)
	_board.draw_rect(Rect2(280, 58, 240, 3), Color("5d4a5d"))
	_board.draw_rect(Rect2(280, 58, float(part), 3), SAND)
	_placard(Rect2(553, 24, 210, 34), "FIRST SWAP +1   •   MATCH +2", INK, SAND, 14)

func _draw_ticket(p: Dictionary) -> void:
	var slot: int = p.slot
	var rect := Rect2(43 + slot * 120, 99, 114, 76)
	var tint: Color = Kit.colors[slot]
	var own: bool = (local_mask & (1 << slot)) != 0 or _own == slot
	var accent: bool = _state.reserve_open() and _state.bell_age() >= Model.CUTOFF_TICK - 24
	var stroke := tint if own else tint.darkened(0.27)
	if accent and _state.bell_age() % 8 < 4 and p.fit_started < 0:
		stroke = PAPER
	Kit.plate(_board, Kit.slab(rect, 4), INK, 2, 4, stroke)
	var seal := rect.position + Vector2(12, 12)
	_board.draw_arc(seal, 7.5, 0.0, TAU, 20, tint, 1.5, true)
	_label(str(slot + 1), seal, 11, PAPER)
	var name := "GUEST"
	if show_identities and not str(p.name).is_empty():
		name = str(p.name)
	elif p.bot:
		name = "CPU"
	elif own:
		name = "P%d" % (slot + 1) if _main.shared_screen else "YOU"
	_label(name.substr(0, 8), rect.position + Vector2(58, 12), 12, PAPER)
	_hat(rect.position + Vector2(31, 38), 0.61, p.hat)
	_hat(rect.position + Vector2(83, 38), 0.61, p.want)
	_label("ON", rect.position + Vector2(31, 53), 9, SAND)
	_label("TICKET", rect.position + Vector2(83, 53), 9, SAND)
	var match_tint := MINT if p.hat == p.want else Color("8f778c")
	_board.draw_line(rect.position + Vector2(54, 24), rect.position + Vector2(54, 50), match_tint, 2.0)
	if p.hat == p.want:
		_board.draw_arc(rect.position + Vector2(83, 35), 18.0, 0, TAU, 28, MINT, 1.5, true)
	_label(_ticket_line(p), rect.position + Vector2(57, 66), 10, MINT if p.hat == p.want else PAPER)

func _ticket_line(p: Dictionary) -> String:
	if _state.phase == "finished":
		return "+2 AT BELL" if p.last_points else "NO MATCH"
	if p.fit_started >= 0:
		return "FITTING" if _state.tick < p.fit_started + Model.FIT_TICKS else "FITTED"
	if p.offer >= 0:
		var q: Dictionary = _state.players[p.offer]
		return ("OFFER → %d" if q.target == p.slot else "WAIT → %d") % (p.offer + 1)
	if _state.can_trade(p, p.target) and _state.players[p.target].offer == p.slot:
		return "ACCEPT ← %d" % (p.target + 1)
	if _state.can_fit(p):
		return "TAP TO FIT"
	if _state.can_trade(p, p.target):
		var q: Dictionary = _state.players[p.target]
		if q.target != p.slot:
			return "%d LOOKS AWAY" % (p.target + 1)
		return ("MATCH FROM %d" if q.hat == p.want else "OFFER → %d") % (p.target + 1)
	if p.hat == p.want:
		return "MATCH READY"
	if p.target >= 0:
		return "SAME AS %d" % (p.target + 1)
	return "FIND A PARTNER"

func _draw_counter(age: int) -> void:
	var open: bool = _state.reserve_open()
	var trim := Rect2(149, 197, 502, 13)
	Kit.plate(_board, Kit.slab(trim, 6), Color("7f4b52"), 2, 3, INK)
	for x in range(156, 637, 21):
		_board.draw_line(Vector2(x, 203), Vector2(x + 11, 203), Color("987065"), 2.5)
	var caption := "FITTING COUNTER"
	var tint := SAND
	if _state.phase == "finished":
		caption = "HATCHECK CLOSED"
	elif age >= Model.CUTOFF_TICK:
		caption = "FITTING CLOSED  •  SWAPS STILL OPEN"
	elif open:
		var seconds := ceili((Model.CUTOFF_TICK - age) * Model.STEP)
		caption = "FITTING OPEN   •   %d s TO CUTOFF" % seconds
		tint = MINT if seconds > 1 else PAPER
	elif _state.phase == "running":
		caption = "FITTING OPENS IN %d s" % ceili((Model.RESERVE_TICK - age) * Model.STEP)
	_placard(Rect2(210, 70, 380, 23), caption, INK, tint, 15)
	for p in _state.players:
		if not p.active:
			continue
		var spot := Vector2(p.spot)
		var color: Color = Kit.colors[p.slot]
		_board.draw_circle(spot, Model.FIT_RANGE, INK, true, -1.0, true)
		_board.draw_arc(spot, Model.FIT_RANGE - 2, 0.0, TAU, 28, color if open else color.darkened(0.5), 2.0, true)
		if p.fit_started >= 0:
			var fraction := clampf(float(_state.tick - p.fit_started) / Model.FIT_TICKS, 0.0, 1.0)
			_board.draw_arc(spot, Model.FIT_RANGE + 4, -PI * 0.5, -PI * 0.5 + TAU * fraction, 32, MINT, 3.0, true)
		else:
			_label(str(p.slot + 1), spot, 17, color if open else SAND)
			if open and p.pos.distance_squared_to(p.spot) > Model.FIT_RANGE * Model.FIT_RANGE:
				_board.draw_line(spot + Vector2(0, 21), spot + Vector2(0, 33), color, 2.0, true)

func _draw_tether(p: Dictionary) -> void:
	var q: Dictionary = _state.players[p.target]
	var source := _visual[p.slot] + Vector2(0, -8)
	var end := _visual[q.slot] + Vector2(0, -8)
	var step := source.direction_to(end)
	if source.distance_to(end) < CLOSE_TETHER:
		return
	var offset := step.orthogonal() * 5.5
	var start := source + step * 22.0 + offset
	var finish := end - step * 23.0 + offset
	if not _state.can_trade(p, q.slot):
		for x in range(0, floori(start.distance_to(finish)), 8):
			_board.draw_circle(start + step * x, 1.8, PAPER, true, -1, true)
		return
	var offered: bool = p.offer == q.slot
	var color: Color = Kit.colors[p.slot]
	if offered:
		color = MINT if q.target == p.slot else color
	else:
		color = color.lightened(0.14) if q.target == p.slot else color.darkened(0.40)
	var width := 4.0 if offered else 1.8
	_board.draw_line(start, finish, INK, width + 3.0, true)
	_board.draw_line(start, finish, color, width, true)
	var arrow := finish - step * 4
	_poly([finish + step * 4, arrow + step.orthogonal() * 5, arrow - step.orthogonal() * 5], color)
	if offered and start.distance_to(finish) >= 45:
		var seal := start.lerp(finish, 0.48)
		_board.draw_circle(seal, 8, INK, true, -1, true)
		_label(str(p.slot + 1), seal, 11, color)

func _draw_close_tether(p: Dictionary) -> void:
	var source := _visual[p.slot]
	var end := _visual[p.target]
	if source.distance_to(end) >= CLOSE_TETHER:
		return
	var side := -1.0 if p.slot % 2 == 0 else 1.0
	var y := clampf(source.y - 14.0 + 17.0 * (p.slot >> 1), 199.0, 352.0)
	var center := Vector2(source.x + side * 42.0, y)
	var equal: bool = not _state.can_trade(p, p.target)
	var seal := "%d · %d" if equal else "%d → %d"
	var color: Color = Kit.colors[p.slot]
	if p.offer >= 0 and _state.players[p.target].target == p.slot:
		color = MINT
	Kit.plate(_board, Kit.slab(Rect2(center - Vector2(20, 8), Vector2(40, 16)), 5), INK, 2, 3, color)
	_label(seal % [p.slot + 1, p.target + 1], center, 11, PAPER)

func _draw_guest(p: Dictionary) -> void:
	var point := _visual[p.slot]
	var tint: Color = Kit.colors[p.slot]
	var walking := point.distance_to(Vector2(p.pos)) > 0.4
	var bob := sin(_clock * 17.0 + p.slot) * 2.0 if walking else 0.0
	var foot := point + Vector2(0, bob)
	var own: bool = (local_mask & (1 << p.slot)) != 0 or _own == p.slot
	_board.draw_circle(point + Vector2(0, 2), 20, INK.darkened(0.2), true, -1.0, true)
	_board.draw_circle(foot, 17, tint.darkened(0.28), true, -1.0, true)
	if own or _champion == p.slot:
		_board.draw_arc(foot, 20.0, 0.0, TAU, 32, PAPER, 2.0, true)
	_board.draw_line(foot + Vector2(-12, 8), foot + Vector2(12, 8), tint, 4.0, true)
	_board.draw_circle(foot + Vector2(0, -12), 13, INK, true, -1.0, true)
	_board.draw_circle(foot + Vector2(0, -12), 10.5, Color("f8d6ab"), true, -1.0, true)
	_board.draw_circle(foot + Vector2(-4, -12), 1.4, INK)
	_board.draw_circle(foot + Vector2(4, -12), 1.4, INK)
	_board.draw_arc(foot + Vector2(0, -10), 3.7, 0.14, PI - 0.14, 10, INK, 1.5, true)
	_hat(foot + Vector2(0, -26), 0.78, p.hat)
	_board.draw_circle(foot + Vector2(0, 4), 9, INK, true, -1.0, true)
	_label(str(p.slot + 1), foot + Vector2(0, 4), 12, PAPER)
	if p.bot:
		_board.draw_circle(foot + Vector2(13, 8), 6, INK)
		_label("C", foot + Vector2(13, 8), 8, PAPER)
	if _state.phase == "finished":
		return
	if p.fit_started >= 0:
		var fitted: bool = _state.tick - int(p.fit_started) >= Model.FIT_TICKS
		_label("FITTED" if fitted else "FITTING", foot + Vector2(0, 27), 11, MINT, 3)
	elif p.offer >= 0:
		_label("→ %d" % (p.offer + 1), foot + Vector2(0, 26), 13, PAPER, 4)
	elif _state.can_trade(p, p.target) and _state.players[p.target].offer == p.slot:
		_label("ACCEPT %d" % (p.target + 1), foot + Vector2(0, 26), 12, MINT, 4)

func _draw_toss(p: Dictionary) -> void:
	if p.trade_tick < 0:
		return
	var age: float = (_state.tick - int(p.trade_tick)) * Model.STEP
	if age >= 0.75:
		return
	var to := _visual[p.slot]
	var from := _visual[p.trade_partner]
	if age < 0.45:
		var t := clampf(age / 0.45, 0.0, 1.0)
		_hat(from.lerp(to, t) + Vector2(0, -32.0 - 44.0 * sin(t * PI)), 0.74, p.hat)
	else:
		var t := (age - 0.45) / 0.30
		for i in 5:
			var ray := Vector2.from_angle(i * TAU / 5.0)
			_board.draw_circle(to + Vector2(0, -22) + ray * (20.0 + 15.0 * t), 2.8 - 1.6 * t, MINT)

func _draw_payoff() -> void:
	var text := "BELL!"
	for p in _state.players:
		if p.active and p.last_points:
			text = "TICKET MATCHES  +2"
			break
	_placard(Rect2(280, 371, 240, 27), text, INK, MINT, 16)

func _hat(center: Vector2, scale: float, pattern: int) -> void:
	var brim := Vector2(20, 5) * scale
	var crown: PackedVector2Array
	match pattern:
		0:
			crown = _relative(center, scale, [Vector2(-12, 0), Vector2(-10, -25), Vector2(10, -25), Vector2(12, 0)])
		1:
			crown = _relative(center, scale, [Vector2(-14, 0), Vector2(-12, -14), Vector2(-6, -20),
				Vector2(6, -20), Vector2(13, -14), Vector2(15, 0)])
		2:
			crown = _relative(center, scale, [Vector2(-15, 0), Vector2(-6, -10), Vector2(2, -27),
				Vector2(9, -12), Vector2(15, 0)])
		3:
			crown = _relative(center, scale, [Vector2(-16, 0), Vector2(-15, -17), Vector2(-6, -12),
				Vector2(0, -21), Vector2(7, -12), Vector2(15, -17), Vector2(16, 0)])
		4:
			crown = _relative(center, scale, [Vector2(-14, 0), Vector2(-12, -16), Vector2(-4, -22),
				Vector2(8, -19), Vector2(16, -12), Vector2(13, 0)])
	Kit.plate(_board, crown, COLORS[pattern], 2.0 * scale, 2.5 * scale, INK)
	_board.draw_rect(Rect2(center - brim * Vector2(1, 0.58), brim * Vector2(2, 1)), COLORS[pattern])
	_board.draw_rect(Rect2(center - brim * Vector2(1, 0.58), brim * Vector2(2, 1)), INK, false, 1.7 * scale)
	match pattern:
		0:
			for x in [-6, 0, 6]:
				_board.draw_line(center + Vector2(x, -18) * scale, center + Vector2(x, -6) * scale, INK, 2.0 * scale, true)
		1:
			for x in [-7, 0, 7]:
				_board.draw_circle(center + Vector2(x, -9 - int(x == 0) * 4) * scale, 2.6 * scale, INK, true, -1.0, true)
		2:
			_poly(_relative(center, scale, [Vector2(0, -16), Vector2(5, -11), Vector2(0, -6), Vector2(-5, -11)]), INK)
		3:
			for x in [-8, 0, 8]:
				_board.draw_line(center + Vector2(x - 2, -6) * scale,
					center + Vector2(x + 2, -11) * scale, INK, 2.0 * scale, true)
		4:
			var at := center + Vector2(1, -11) * scale
			_board.draw_arc(at, 4.8 * scale, 0.0, TAU, 22, INK, 2.0 * scale, true)

func _relative(center: Vector2, scale: float, points: Array) -> PackedVector2Array:
	var vertices := PackedVector2Array()
	for point in points:
		vertices.append(center + point * scale)
	return vertices

func _poly(points: PackedVector2Array, color: Color) -> void:
	_board.draw_colored_polygon(points, color)

func _placard(rect: Rect2, text: String, fill: Color, color: Color, size: int) -> void:
	Kit.plate(_board, Kit.slab(rect, 5), fill, 2, 3, color.darkened(0.36))
	_label(text, rect.get_center(), size, color)

func _label(text: String, at: Vector2, size: int, color: Color, outline: int = 0) -> void:
	Kit.text(_board, text, Vector2(at.x, Kit.baseline(at.y, size)), size, color, outline, 0.5)
