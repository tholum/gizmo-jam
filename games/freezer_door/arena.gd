extends Node3D
## The cabinet stays in view. Drawer springs and score pops are cosmetic.

const Model = preload("res://games/freezer_door/model.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const Platform = preload("res://scripts/platform.gd")
const SIZE := Vector2(1152, 538)
const TILE := Vector2(170, 174)
const PITCH := Vector2(181, 192)
const ORIGIN := Vector2(39, 111)
const INK := Color("13293e")
const NAVY := Color("1d3850")
const SHADOW := Color("132639")
const ICE := Color("b8e3e3")
const SNOW := Color("f1fff5")
const AQUA := Color("5cc6cc")
const BLUE := Color("77a7bc")
const MINT := Color("bdf47c")
const HOT := Color("ff987b")
const FLAVORS := [
	Color("ff9a88"), Color("ffd182"), Color("c9ee91"), Color("92e2d3"), Color("aad3fb"), Color("e6b1e9"),
]

var camera := Camera3D.new()
var local_mask := 0
var show_identities := false
var touch_steering := false
var touch_holding := false

var _main: Node
var _state: RefCounted
var _room := Node2D.new()
var _cabinet := Node2D.new()
var _drawers := Node2D.new()
var _motion := PackedFloat32Array()
var _viewport := Vector2.ZERO
var _menu := false
var _inset := 0.0
var _own := -1
var _fraction := 0.0
var _last_tick := -1
var _champion := -1
var _celebration := 0.0

func _init(main: Node) -> void:
	_main = main
	_motion.resize(Model.DRAWERS)

func _ready() -> void:
	add_child(camera)
	var canvas := CanvasLayer.new()
	add_child(canvas)
	canvas.add_child(_room)
	canvas.add_child(_cabinet)
	canvas.add_child(_drawers)
	_room.draw.connect(_draw_room)
	_cabinet.draw.connect(_draw_cabinet)
	_drawers.draw.connect(_draw_board)

func set_menu(menu: bool) -> void:
	_menu = menu
	_champion = -1

func set_inset(value: float) -> void:
	_inset = value

func celebrate(slot: int) -> void:
	_champion = slot
	_celebration = 2.4

func update_visuals(state: RefCounted, delta: float, own: int = -1) -> void:
	if state != _state or state.tick != _last_tick:
		_fraction = 0.0
	else:
		_fraction = minf(1.0, _fraction + delta * Model.HZ)
	if state != _state or (state.tick < _last_tick):
		_motion.fill(0.0)
	_state = state
	_last_tick = state.tick
	_own = own
	_celebration = maxf(0.0, _celebration - delta)
	for drawer in Model.DRAWERS:
		var target := 1.0 if state.drawers[drawer].holders else 0.0
		_motion[drawer] = move_toward(_motion[drawer], target, delta * (9.0 if target > 0.0 else 11.0))

	var viewport := get_viewport().get_visible_rect().size
	if viewport != _viewport:
		_viewport = viewport
		_room.queue_redraw()
	var safe: Vector2 = _main.area
	var span := safe.x * (0.86 if Platform.handheld and not _menu else 1.0)
	var zoom := minf((span - 28.0) / SIZE.x, (safe.y - 182.0) / SIZE.y)
	var middle := viewport * 0.5 + Vector2(0, -1)
	if _menu:
		zoom = minf((safe.x - 46.0) / SIZE.x, (safe.y - 105.0) / SIZE.y)
		middle = Vector2(viewport.x * (0.55 + _inset * 0.30), viewport.y * 0.51)
	for layer in [_cabinet, _drawers]:
		layer.scale = Vector2.ONE * zoom
		layer.position = middle - SIZE * zoom * 0.5
	_drawers.queue_redraw()

func _draw_room() -> void:
	var room := Rect2(Vector2.ZERO, _viewport)
	_room.draw_rect(room, Color("182b42"))
	var halo := _viewport * Vector2(0.5, 0.45)
	for i in range(16, 0, -1):
		var glow := Color("285575").lerp(Color("385e7c"), (16.0 - i) / 16.0)
		_room.draw_circle(halo, _viewport.x * (0.17 + i * 0.035), Color(glow, 0.075), true, -1.0, true)
	for i in range(-2, ceili(_viewport.x / 97.0) + 3):
		var x := float(i) * 97.0
		_room.draw_line(Vector2(x, 0), Vector2(x - 85.0, _viewport.y), Color("2b4359"), 2.0, true)
	var horizon := _viewport.y * 0.78
	_room.draw_rect(Rect2(0, horizon, _viewport.x, _viewport.y - horizon), Color("182b3c"))
	for i in range(-6, 7):
		var top := Vector2(_viewport.x * 0.5 + i * _viewport.x * 0.1, horizon)
		var bottom := Vector2(_viewport.x * 0.5 + i * _viewport.x * 0.2, _viewport.y)
		_room.draw_line(top, bottom, Color("273f51"), 2.0, true)
	for i in 4:
		var y := horizon + pow(float(i) / 4.0, 1.8) * (_viewport.y - horizon)
		_room.draw_line(Vector2(0, y), Vector2(_viewport.x, y), Color("324a5c"), 2.0, true)

func _draw_cabinet() -> void:
	var slab := Rect2(13, 17, 1122, 502)
	Kit.plate(_cabinet, Kit.slab(slab, 21), BLUE, 5, 19, INK)
	Kit.plate(_cabinet, Kit.slab(slab.grow(-8.0), 16), ICE, 3, 4, AQUA)
	_cabinet.draw_rect(Rect2(29, 102, 1094, 372), NAVY)
	_cabinet.draw_rect(Rect2(29, 102, 1094, 372), SNOW, false, 3.0)
	Kit.plate(_cabinet, Kit.slab(Rect2(40, 39, 1072, 48), 10), INK, 3, 4, BLUE)
	for x in [61, 1091]:
		_snowflake(_cabinet, Vector2(x, 63), 10.0, AQUA)
		_snowflake(_cabinet, Vector2(x, 495), 7.0, NAVY)
	for x in range(94, 1058, 16):
		_cabinet.draw_line(Vector2(x, 486), Vector2(x - 4, 504), BLUE, 3.0, true)
	for x in [43, 1109]:
		for y in [107, 473]:
			_cabinet.draw_circle(Vector2(x, y), 3.0, BLUE, true, -1.0, true)

func _draw_board() -> void:
	if _state == null:
		return
	var left := Vector2(95, 63)
	_centre("RELEASE IN STRIPE", left + Vector2(82, 0), 17, SNOW)
	var stripe := Rect2(276, 54, 42, 18)
	_drawers.draw_rect(stripe, MINT)
	_stripes(stripe)
	_centre("+2", Vector2(347, 63), 20, MINT)
	_drawers.draw_line(Vector2(382, 48), Vector2(382, 78), BLUE.darkened(0.3), 2.0)
	_needle(Vector2(410, 63), SNOW)
	Kit.text(_drawers, "HEAT NOW", Vector2(425, Kit.baseline(63, 16)), 16, SNOW)
	_forecast(Vector2(554, 63), AQUA)
	Kit.text(_drawers, "NEXT ½ SEC", Vector2(570, Kit.baseline(63, 16)), 16, ICE)
	_drawers.draw_line(Vector2(700, 48), Vector2(700, 78), BLUE.darkened(0.3), 2.0)
	if _state.reserve_left() > 0:
		Kit.text(_drawers, "STARTERS RESERVED", Vector2(723, Kit.baseline(63, 17)), 17, SNOW)
		var track := Rect2(939, 57, 130, 12)
		_drawers.draw_rect(track, NAVY)
		_drawers.draw_rect(Rect2(track.position, Vector2(track.size.x * _state.reserve_left() / Model.RESERVE_TICKS, track.size.y)), AQUA)
	else:
		Kit.text(_drawers, "FREE DRAWERS OPEN TO ALL", Vector2(723, Kit.baseline(63, 17)), 17, SNOW)

	for drawer in Model.DRAWERS:
		var origin := _origin(drawer)
		if _state.enabled(drawer):
			_draw_drawer(drawer, origin)
		else:
			_draw_shutter(origin)
	_draw_seams()
	_draw_cursors()
	_draw_pops()
	if Platform.handheld and not _menu:
		_touch_guide(Rect2(86, 480, 221, 29), "LEFT DRAG  ·  MOVE", touch_steering)
		_touch_guide(Rect2(845, 480, 221, 29), "RIGHT SIDE  ·  HOLD", touch_holding)
	if _champion >= 0 and _celebration > 0.0:
		for i in 26:
			var x := 65.0 + posmod(i * 113, 1020)
			var y := 35.0 + fposmod((2.4 - _celebration) * (84 + i % 6 * 22) + i * 57, 450)
			var tint: Color = Kit.colors[_champion].lerp(AQUA, float(i % 4) * 0.21)
			_snowflake(_drawers, Vector2(x, y), 4 + i % 4, tint)

func _touch_guide(rect: Rect2, caption: String, pressed: bool) -> void:
	var color := MINT if pressed else ICE
	Kit.plate(_drawers, Kit.slab(rect, 6), INK, 2, 1, AQUA)
	_centre(caption, rect.get_center(), 16, color)

static func _origin(drawer: int) -> Vector2:
	return ORIGIN + Vector2(drawer % Model.COLS, floori(float(drawer) / Model.COLS)) * PITCH

func _draw_shutter(origin: Vector2) -> void:
	var door := Rect2(origin, TILE)
	Kit.plate(_drawers, Kit.slab(door, 8), Color("44657a"), 2, 4, SHADOW)
	_drawers.draw_rect(door.grow(-8), Color("587b8f"), false, 2.0)
	for y in range(25, 161, 13):
		_drawers.draw_line(origin + Vector2(35, y), origin + Vector2(TILE.x - 35, y), NAVY, 5.0, true)
		_drawers.draw_line(origin + Vector2(35, y + 4), origin + Vector2(TILE.x - 35, y + 4), BLUE.darkened(0.3), 2.0, true)

func _draw_drawer(drawer: int, origin: Vector2) -> void:
	var state: Dictionary = _state.drawers[drawer]
	var holders: int = state.holders
	var held := holders != 0
	var spent: bool = state.spent
	var inside := held and Model.bonus(state.heat)
	var first := Rect2(origin, TILE)
	var enamel := ICE if not spent else BLUE
	var frame := MINT if inside else AQUA
	Kit.plate(_drawers, Kit.slab(first, 8), enamel, 2, 4, INK)
	var bay := Rect2(origin + Vector2(10, 48), Vector2(150, 64))
	_drawers.draw_rect(bay, Color("20384d") if held or spent else BLUE, true)
	_drawers.draw_rect(bay, frame.darkened(0.25), false, 2.0)
	var handle := origin + Vector2(0, 14 * _motion[drawer])
	var face := Rect2(handle + Vector2(13, 53), Vector2(144, 53 - 12 * _motion[drawer]))
	var flavor: Color = FLAVORS[drawer % FLAVORS.size()]
	if held:
		_treat(origin + Vector2(86, 63), flavor, _motion[drawer])
	Kit.plate(_drawers, Kit.slab(face, 5), enamel.darkened(0.28) if spent else SNOW.lerp(flavor, 0.31), 2, 4, NAVY)
	if spent:
		_lock(handle + Vector2(23, 78))
	else:
		var bar := Rect2(handle + Vector2(18, 74), Vector2(88, 11))
		_drawers.draw_rect(bar, NAVY)
		_drawers.draw_line(bar.position + Vector2(1, -1), bar.end - Vector2(1, 12), BLUE, 2.0)
		_snowflake(_drawers, handle + Vector2(140, 79), 7.0, INK)

	var title := origin + Vector2(0, 41)
	var owner: int = state.owner
	var reserve: int = _state.reserve_left()
	var number := "%02d" % (drawer + 1)
	Kit.text(_drawers, number, Vector2(title.x + 11, Kit.baseline(title.y, 15)), 15, NAVY)
	if held:
		_centre("HOLDING", title + Vector2(96, 0), 16, INK)
	elif spent:
		_centre("SPENT", title + Vector2(96, 0), 16, NAVY)
	elif reserve > 0 and owner >= 0:
		var tint: Color = Kit.colors[owner]
		var at := title + Vector2(58, 0)
		_drawers.draw_circle(at, 8.5, INK, true, -1, true)
		_drawers.draw_arc(at, 7.5, -PI / 2, -PI / 2 + TAU * reserve / Model.RESERVE_TICKS, 22, tint, 2.1, true)
		_centre("SEAT %d" % (owner + 1), title + Vector2(103, 0), 16, INK)
	else:
		_centre("OPEN", title + Vector2(96, 0), 16, INK)

	_draw_gauge(drawer, origin)
	if inside:
		_drawers.draw_polyline(_loop(first.grow(-2.0)), MINT, 2.0, true)

func _draw_gauge(drawer: int, origin: Vector2) -> void:
	var d: Dictionary = _state.drawers[drawer]
	var box := Rect2(origin + Vector2(9, 116), Vector2(152, 48))
	Kit.plate(_drawers, Kit.slab(box, 5), INK, 2, 1, NAVY)
	var gauge := Rect2(origin + Vector2(20, 142), Vector2(130, 9))
	var floor_x := gauge.position.x + gauge.size.x * float(Model.BAND_LOW) / Model.MAX_HEAT
	var ceil_x := gauge.position.x + gauge.size.x * float(Model.BAND_HIGH) / Model.MAX_HEAT
	_drawers.draw_rect(gauge, BLUE)
	_drawers.draw_rect(Rect2(Vector2(ceil_x, gauge.position.y), Vector2(gauge.end.x - ceil_x, gauge.size.y)), HOT.darkened(0.20))
	var stripe := Rect2(Vector2(floor_x, gauge.position.y), Vector2(ceil_x - floor_x, gauge.size.y))
	_drawers.draw_rect(stripe, MINT)
	_stripes(stripe)
	_drawers.draw_line(Vector2(floor_x, gauge.position.y - 2), Vector2(floor_x, gauge.end.y + 2), SNOW, 1.5, true)
	_drawers.draw_line(Vector2(ceil_x, gauge.position.y - 2), Vector2(ceil_x, gauge.end.y + 2), SNOW, 1.5, true)

	var now_x := gauge.position.x + gauge.size.x * float(d.heat) / Model.MAX_HEAT
	var then_x := gauge.position.x + gauge.size.x * float(_state.forecast(drawer)) / Model.MAX_HEAT
	var forecast_y := gauge.position.y - 14.0
	_drawers.draw_line(Vector2(gauge.position.x, forecast_y), Vector2(gauge.end.x, forecast_y), NAVY.lightened(0.12), 1.0, true)
	_forecast(Vector2(then_x, forecast_y), AQUA if not d.spent else BLUE)
	_needle(Vector2(now_x, gauge.position.y + 5), SNOW if not d.spent else BLUE)

func _stripes(rect: Rect2) -> void:
	for x in range(int(rect.position.x + 5), int(rect.end.x - 3), 8):
		var rise := minf(5.0, rect.size.y)
		var x0 := float(x)
		_drawers.draw_line(Vector2(x0 - 3, rect.end.y - 1), Vector2(x0 + 3, rect.end.y - 1 - rise),
			Color(0.14, 0.31, 0.15, 0.5), 2.0, true)

func _needle(at: Vector2, tint: Color) -> void:
	_drawers.draw_line(at - Vector2(0, 8), at + Vector2(0, 11), INK, 6, true)
	_drawers.draw_line(at - Vector2(0, 8), at + Vector2(0, 11), tint, 3, true)
	_drawers.draw_colored_polygon(PackedVector2Array([at + Vector2(0, -7), at + Vector2(5, -11), at + Vector2(-5, -11)]), tint)

func _forecast(at: Vector2, tint: Color) -> void:
	var mark := PackedVector2Array([at + Vector2(0, -5), at + Vector2(5, 0), at + Vector2(0, 5), at + Vector2(-5, 0), at + Vector2(0, -5)])
	_drawers.draw_colored_polygon(mark, INK)
	_drawers.draw_polyline(mark, tint, 2.0, true)

func _draw_seams() -> void:
	for drawer in Model.DRAWERS:
		if not _state.drawers[drawer].holders:
			continue
		for neighbor in Model.NEIGHBORS[drawer]:
			if not _state.enabled(neighbor) or _state.drawers[neighbor].spent:
				continue
			var from := _origin(drawer) + TILE * 0.5
			var to := _origin(neighbor) + TILE * 0.5
			var axis := from.direction_to(to)
			var cross := axis.orthogonal()
			var seam := (from + to) * 0.5
			# Opposite directions use separate tracks when both doors are open.
			if _state.drawers[neighbor].holders:
				seam += cross * 22.0
			var speed: float = 0.14 + 0.046 * _state.flow(neighbor)
			var advance := fposmod(20.0 + (_state.tick + _fraction) * speed, 7.0) - 3.5
			for i in [-1, 0, 1]:
				var at: Vector2 = seam + cross * i * 11.0 + axis * advance
				var shape := PackedVector2Array([at - axis * 3 - cross * 3, at + axis * 3, at - axis * 3 + cross * 3])
				_drawers.draw_polyline(shape, HOT, 2.5, true)

func _draw_cursors() -> void:
	var by_drawer: Array = []
	for drawer in Model.DRAWERS:
		by_drawer.append([])
	for p in _state.players:
		if p.active:
			by_drawer[p.cursor].append(p)
	for drawer in Model.DRAWERS:
		var list: Array = by_drawer[drawer]
		var count := list.size()
		for i in count:
			var p: Dictionary = list[i]
			var slot: int = p.slot
			var tint: Color = Kit.colors[slot]
			var target := _origin(drawer) + Vector2(TILE.x / 2.0 + (i - (count - 1) * 0.5) * 23.5, 16)
			var local := slot == _own or (local_mask & (1 << slot)) != 0
			_badge(target, slot, tint, p.hold >= 0, local)
		if show_identities and count == 1:
			var p: Dictionary = list[0]
			Kit.text(_drawers, str(p.name), _origin(drawer) + Vector2(TILE.x / 2.0, 112), 17,
				Kit.colors[p.slot].lightened(0.23), 5, 0.5)

func _badge(at: Vector2, slot: int, tint: Color, held: bool, local: bool) -> void:
	if held:
		var badge := PackedVector2Array([at + Vector2(0, -12), at + Vector2(11, -7), at + Vector2(11, 7),
			at + Vector2(0, 12), at + Vector2(-11, 7), at + Vector2(-11, -7)])
		Kit.plate(_drawers, badge, tint, 2, 0, INK)
		_drawers.draw_circle(at, 7.6, INK, true, -1, true)
	else:
		_drawers.draw_circle(at, 10, INK, true, -1.0, true)
		_drawers.draw_circle(at, 8, tint, false, 2.5, true)
	_centre(str(slot + 1), at, 14, SNOW)
	if local:
		_drawers.draw_line(at + Vector2(-5, 13), at + Vector2(5, 13), INK, 2, true)

func _draw_pops() -> void:
	for drawer in Model.DRAWERS:
		var fresh: Array = _state.players.filter(func(p):
			return p.active and p.last_drawer == drawer and _state.tick - p.last_tick <= 15)
		for i in fresh.size():
			var p: Dictionary = fresh[i]
			var age := clampf((_state.tick - p.last_tick + _fraction) / 15.0, 0.0, 1.0)
			var at := _origin(drawer) + Vector2(36 + 49 * (i % 3), 107 - 34 * (i / 3) - 15 * age)
			var tint: Color = Kit.colors[p.slot]
			var ice := Color(MINT if p.last_points == 2 else SNOW, 1.0 - 0.65 * age * age)
			_treat(at + Vector2(15 + 6 * age, -17 - 9 * age), Color(FLAVORS[drawer % FLAVORS.size()], ice.a), 0.83)
			_drawers.draw_circle(at - Vector2(11, 1), 7.5, Color(tint, ice.a), true, -1.0, true)
			_drawers.draw_circle(at - Vector2(11, 1), 5.8, Color(INK, ice.a), true, -1.0, true)
			_centre(str(p.slot + 1), at - Vector2(11, 1), 11, Color(SNOW, ice.a))
			Kit.text(_drawers, "+%d" % p.last_points, Vector2(at.x + 1, Kit.baseline(at.y, 24)),
				24, ice, 4, 0.0, 0.0, null, Color(INK, ice.a))

func _treat(at: Vector2, tint: Color, scale_value: float) -> void:
	var face := Rect2(at - Vector2(12, 15) * scale_value, Vector2(24, 28) * scale_value)
	_drawers.draw_rect(Rect2(at + Vector2(-3, 9) * scale_value, Vector2(6, 11) * scale_value), Color("e7bf96"))
	Kit.plate(_drawers, Kit.slab(face, 4 * scale_value), tint, 2, 1, INK)
	for i in [-1, 1]:
		_drawers.draw_line(at + Vector2(i * 3, -7) * scale_value, at + Vector2(i * 3, 5) * scale_value,
			tint.lightened(0.34), 1.6, true)

func _lock(at: Vector2) -> void:
	_drawers.draw_arc(at - Vector2(0, 3), 5, PI, TAU, 14, INK, 2.5, true)
	_drawers.draw_rect(Rect2(at - Vector2(7, 2), Vector2(14, 10)), INK)
	_drawers.draw_circle(at + Vector2(0, 2), 1.4, SNOW)

static func _snowflake(surface: Node2D, at: Vector2, radius: float, tint: Color) -> void:
	for i in 3:
		var dir := Vector2.from_angle(i * PI / 3)
		surface.draw_line(at - dir * radius, at + dir * radius, tint, 2.0, true)
		for side in [-1, 1]:
			var tip: Vector2 = at + dir * side * radius * 0.72
			var fork := dir.orthogonal() * radius * 0.30
			var back: Vector2 = tip - dir * side * radius * 0.25
			surface.draw_line(tip, back + fork, tint, 1.5, true)
			surface.draw_line(tip, back - fork, tint, 1.5, true)

static func _loop(rect: Rect2) -> PackedVector2Array:
	return PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end,
		Vector2(rect.position.x, rect.end.y), rect.position])

func _centre(words: String, at: Vector2, size: int, tint: Color) -> void:
	Kit.text(_drawers, words, Vector2(at.x, Kit.baseline(at.y, size)), size, tint, 0, 0.5)
