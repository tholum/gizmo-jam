extends Node3D
## A fixed proscenium. Tin parts are linked in screen space so the pivot,
## spring, stop and eventual separation remain readable from every seat.

const Model = preload("res://games/wobble_workshop/model.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const Platform = preload("res://scripts/platform.gd")
const SIZE := Vector2(1050, 576)
const INK := Color("1c1923")
const CREAM := Color("fff1d5")
const GOLD := Color("f8c46c")
const PALE := Color("c4aaa1")
const MINT := Color("ade5cb")
const RUST := Color("f09178")
const PANEL := Color("3a2a34")
const SWEEP := Rect2(792, 369, 237, 87)
const PLINTH := Vector2(515, 465)

var camera := Camera3D.new()
var local_mask := 0
var show_identities := false

var _main: Node
var _play: RefCounted
var _state: RefCounted
var _room := Node2D.new()
var _art := Node2D.new()
var _own := -1
var _menu := false
var _inset := 0.0
var _fingers := {}
var _sweep_finger := -1
var _champion := -1
var _rehearsal := -1
var _seen := PackedInt32Array([-1, -1, -1, -1, -1, -1])
var _pulse := PackedFloat32Array([0, 0, 0, 0, 0, 0])
var _joint_wind := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
var _parts: Array[Vector2] = []
var _joint_points: Array[Vector2] = []
var _tilt := 0.0
var _velocity := 0.0
var _clock := 0.0
var _impact := 0.0

func _init(owner: Node, play: RefCounted) -> void:
	_main = owner
	_play = play

func _ready() -> void:
	add_child(camera)
	var canvas := CanvasLayer.new()
	add_child(canvas)
	canvas.add_child(_room)
	canvas.add_child(_art)
	_room.draw.connect(_draw_room)
	_art.draw.connect(_draw_stage)
	get_viewport().size_changed.connect(_room.queue_redraw)

func set_menu(menu: bool) -> void:
	_menu = menu
	_champion = -1
	clear_touches()

func set_inset(value: float) -> void:
	_inset = value

func celebrate(slot: int) -> void:
	_champion = slot
	_art.queue_redraw()

func update_visuals(state: RefCounted, delta: float, own: int = -1) -> void:
	_state = state
	_own = own
	if state.rehearsal != _rehearsal:
		_rehearsal = state.rehearsal
		_seen.fill(-1)
		_pulse.fill(0)
		_joint_wind.fill(0)
		_tilt = 0
		_velocity = 0
		_impact = 0
	for p in state.players:
		var slot: int = p.slot
		if p.stamp > _seen[slot]:
			_seen[slot] = p.stamp
			_pulse[slot] = 1.1
			if p.feedback == 1:
				_velocity += signf(state.torque) * 0.75
			elif p.feedback == 2:
				_velocity -= signf(state.torque) * 0.35
		_pulse[slot] = maxf(0.0, _pulse[slot] - delta)
	for joint in state.joints.size():
		var wind := 1.0 if state.joints[joint].owner >= 0 else 0.0
		for p in state.players:
			if p.holding == joint:
				wind = maxf(wind, state.sweep_progress(p.slot))
		_joint_wind[joint] = move_toward(_joint_wind[joint], wind, delta * (8.0 if wind > _joint_wind[joint] else 12.0))
	var target := clampf(float(state.torque) / 15.0, -0.58, 0.58)
	if state.window() == "bell" and Model.safe(state.torque):
		target = 0
	var dt := minf(delta, 0.035)
	_clock += dt
	_velocity += ((target - _tilt) * 88.0 - _velocity * 6.4) * dt
	_tilt += _velocity * dt
	if absf(_tilt) > 0.61:
		_tilt = clampf(_tilt, -0.61, 0.61)
		_velocity *= -0.38
		_impact = 1.0
	_impact = move_toward(_impact, 0, dt * 3.0)
	var viewport := get_viewport().get_visible_rect().size
	var safe: Vector2 = _main.area
	var zoom := minf((safe.x - 26) / SIZE.x, (safe.y - 118) / SIZE.y)
	var center := Vector2(viewport.x / 2.0, viewport.y / 2.0 + 28.0)
	if _menu:
		zoom *= 0.83
		center.x = viewport.x * (0.68 + _inset * 0.12)
	_art.scale = Vector2.ONE * maxf(0.1, zoom)
	_art.position = center - SIZE * _art.scale * 0.5
	_art.queue_redraw()

func clear_touches() -> void:
	_fingers.clear()
	_sweep_finger = -1

func _card(index: int) -> Rect2:
	var width: float = 1008.0 / _state.joints.size()
	return Rect2(21 + index * width, 482, width - 6, 46)

func joint_screen_rect(index: int) -> Rect2:
	return _art.get_global_transform_with_canvas() * _card(index)

func sweep_screen_rect() -> Rect2:
	return _art.get_global_transform_with_canvas() * SWEEP

func _menu_rect() -> Rect2:
	var button: Control = _main.hud_menu
	if not is_instance_valid(button) or not button.is_visible_in_tree():
		return Rect2()
	return (button.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, button.size)).grow(9)

func _hit(point: Vector2) -> int:
	if _menu_rect().has_point(point):
		return -3
	if sweep_screen_rect().has_point(point):
		return -2
	for joint in _state.joints.size():
		if joint_screen_rect(joint).has_point(point):
			return joint
	var local := _art.get_global_transform_with_canvas().affine_inverse() * point
	var options: Array = _state.options(_own)
	var chosen := -1
	var near := 25.0
	for joint in options:
		if joint < _joint_points.size():
			var distance := local.distance_to(_joint_points[joint])
			if distance < near:
				chosen = joint
				near = distance
	return chosen

func _input(event: InputEvent) -> void:
	if not Platform.handheld or _menu or _main.view != "game" or _main.paused or _state == null or _state != _main.model:
		return
	if event is InputEventScreenDrag and _fingers.has(event.index):
		get_viewport().set_input_as_handled()
	if not event is InputEventScreenTouch:
		return
	if event.pressed and not event.canceled:
		var hit := _hit(event.position)
		if hit == -1 or (hit == -2 and _sweep_finger >= 0):
			return
		_fingers[event.index] = hit
		get_viewport().set_input_as_handled()
		if hit == -2:
			_sweep_finger = event.index
			_play.sweep_touch(true)
		elif hit >= 0:
			_play.select_joint(hit)
	elif _fingers.has(event.index):
		var hit: int = _fingers[event.index]
		_fingers.erase(event.index)
		get_viewport().set_input_as_handled()
		if hit == -2:
			_sweep_finger = -1
			_play.sweep_touch(false, event.canceled)
		elif hit == -3 and not event.canceled and _hit(event.position) == -3:
			_main._toggle_pause()

func _draw_room() -> void:
	var size := get_viewport().get_visible_rect().size
	_room.draw_rect(Rect2(Vector2.ZERO, size), Color("221b29"))
	for i in 36:
		var x := size.x * i / 36.0
		var width := size.x / 36.0 + 2
		var depth: float = absf(i - 17.5) / 17.5
		var cloth := Color("241d29").lerp(Color("553244"), depth)
		_room.draw_rect(Rect2(x, 0, width, size.y), cloth)
		_room.draw_rect(Rect2(x, 0, width * 0.27, size.y), cloth.darkened(0.25))
		_room.draw_rect(Rect2(x + width * 0.27, 0, width * 0.13, size.y), cloth.lightened(0.05))
	_room.draw_rect(Rect2(0, size.y * 0.72, size.x, size.y * 0.28), Color("332329"))
	for i in 8:
		var y := size.y * (0.72 + pow(i / 8.0, 1.5) * 0.28)
		_room.draw_line(Vector2(0, y), Vector2(size.x, y), Color("412b31"), 2)

func _draw_stage() -> void:
	if _state == null:
		return
	Kit.plate(_art, Kit.slab(Rect2(0, 1, SIZE.x, SIZE.y - 3), 10), Color("271f2b"), 4, 8, Color("110d17"))
	_art.draw_rect(Rect2(10, 10, 1030, 554), Color("654248"), false, 1.5)
	_box(Rect2(20, 18, 1010, 52), PANEL, PALE)
	_text("WOBBLE WORKSHOP", Vector2(39, 44), 28, CREAM, 0.0)
	_text("REHEARSAL  %d / %d" % [_state.rehearsal + 1, Model.REHEARSALS], Vector2(548, 45), 22, CREAM)
	var window: String = _state.window()
	var time := "READY"
	if window == "work":
		time = "%.1f s" % (float(_state.deadline_ticks()) / Model.HZ)
	elif window == "bell":
		time = "BELL"
	_text(time, Vector2(1006, 43), 27, GOLD, 1.0)
	var left: float = float(_state.deadline_ticks()) / Model.WORK_TICKS
	_art.draw_rect(Rect2(20, 75, 1010, 5), Color("60414a"))
	_art.draw_rect(Rect2(20, 75, 1010 * left, 5), GOLD)
	_draw_toy()
	_draw_dial()
	if window == "bell":
		_draw_verdict()
	else:
		_draw_instruction()
	_draw_bench()

func _draw_toy() -> void:
	var stopped: bool = absi(_state.torque) >= Model.STOP
	var falling: bool = _state.window() == "bell" and not Model.safe(_state.torque)
	var fall: float = clampf(float(_state.age() - Model.WORK_TICKS) / 19.0, 0.0, 1.0) if falling else 0.0
	var sign_dir := signf(_state.torque)
	var wobble := sin(_clock * 34) * (0.022 + 0.039 * _impact) if stopped and not falling else 0.0
	var turn := _tilt + wobble
	_art.draw_colored_polygon(PackedVector2Array([
		Vector2(421, 184), Vector2(610, 184), Vector2(750, 463), Vector2(285, 463)]), Color("56413d"))
	_art.draw_colored_polygon(PackedVector2Array([
		Vector2(462, 186), Vector2(568, 186), Vector2(670, 462), Vector2(364, 462)]), Color("655047"))
	_art.draw_rect(Rect2(284, 462, 467, 5), Color("987161"))
	_art.draw_rect(Rect2(397, 453, 235, 14), Color("a16750"))
	_art.draw_rect(Rect2(410, 447, 210, 12), GOLD)
	_art.draw_rect(Rect2(427, 451, 176, 6), Color("9e5b4d"))
	for side in [-1, 1]:
		var stop_at := PLINTH + Vector2(side * 69, -19)
		_box(Rect2(stop_at - Vector2(14, 14), Vector2(28, 28)), RUST if stopped and side == sign_dir else PANEL, PALE)
		for stripe in 3:
			_art.draw_line(stop_at + Vector2(-9 + stripe * 7, 7), stop_at + Vector2(-2 + stripe * 7, -7), INK, 3, true)
	var hip := PLINTH + Vector2(0, -79).rotated(turn)
	var chest := hip + Vector2(0, -82).rotated(turn * 1.16)
	var skull := chest + Vector2(0, -62).rotated(turn * 1.03)
	var body_drop := Vector2(sign_dir * 130 * fall, 111 * fall * fall)
	var live_chest := chest + body_drop
	var live_hip := hip + body_drop * 0.77
	var spring_tip := PLINTH.lerp(hip, 1.0 - fall * 0.66)
	_coil(PLINTH - Vector2(0, 11), spring_tip, 19.0)
	if fall < 0.35:
		_rod(hip, chest, 33, Color("985a5b"))
	_parts = [live_chest, live_hip]
	_joint_points.clear()
	for joint in _state.joints:
		_joint_points.append(Vector2.ZERO)
	for side in [-1, 1]:
		var shoulder_wind := _wound(side, 0)
		var elbow_wind := _wound(side, 1)
		var hip_wind := _wound(side, 2)
		var shoulder := live_chest + Vector2(side * 49, 4).rotated(turn)
		var elbow := shoulder + Vector2(side * 54, 35 - shoulder_wind * 32).rotated(turn + side * 0.2)
		var hand := elbow + Vector2(side * 26, 49 - elbow_wind * 17).rotated(turn - side * (0.42 + elbow_wind * 0.82))
		elbow += Vector2(fall * (sign_dir * 16 + side * 43), fall * fall * 52)
		hand += Vector2(fall * (sign_dir * 28 + side * 62), fall * fall * 59)
		for part in [0, 1, 2]:
			_parts.append([shoulder, elbow, live_hip + Vector2(side * 34, 18).rotated(turn)][part])
		_rod(shoulder, elbow, 23, Color("5c8791"))
		if fall < 0.5:
			_rod(elbow, hand, 18, Color("b96855"))
		_hand(hand, turn + side * (0.13 + fall * 1.3), side)
		var leg := live_hip + Vector2(side * 35, 16).rotated(turn)
		var shoe := leg + Vector2(side * (14 + 13 * hip_wind + 30 * fall), 30 - 12 * hip_wind).rotated(turn)
		_rod(leg, shoe, 21, Color("ad8056"))
		_plate(shoe, Vector2(26, 12), turn + side * fall, Color("bd6f5e"))
	var body_turn := turn + sign_dir * 0.83 * fall
	_plate(live_hip, Vector2(39, 21), body_turn, Color("bd775f"))
	_plate(live_chest, Vector2(60, 44), body_turn, Color("bf6b59"))
	_plate(live_chest + Vector2(0, -5).rotated(body_turn), Vector2(39, 23), body_turn, Color("674952"))
	for slat in [-1, 0, 1]:
		var point := live_chest + Vector2(0, slat * 10 - 5).rotated(body_turn)
		_art.draw_line(point + Vector2(-26, 0).rotated(body_turn), point + Vector2(26, 0).rotated(body_turn), GOLD, 2, true)
	var live_skull := skull + Vector2(sign_dir * 153 * fall, 146 * fall * fall)
	_head(live_skull, turn + sign_dir * 2.4 * fall, stopped or falling)
	if falling and fall > 0.14:
		for i in 6:
			var scatter := (i - 2.5) * (18 + fall * 11)
			var loft := -sin(fall * PI) * (27 + i * 4)
			var bolt := PLINTH + Vector2(sign_dir * fall * 119 + scatter, loft - 9 - i % 2 * 8)
			_rod(bolt, bolt + Vector2(8, 0).rotated(i + fall * TAU), 5, CREAM if i % 2 == 0 else GOLD)
	_draw_joints(turn, live_chest, live_hip, fall)

func _wound(side: int, row: int) -> float:
	var first := row * 2
	for joint in range(first, mini(first + 2, _dedicated_count())):
		var data: Dictionary = _state.joints[joint]
		if signi(data.force) == side:
			return _joint_wind[joint]
	return 0.0

func _head(point: Vector2, turn: float, alarmed: bool) -> void:
	var ferrule := point + Vector2(5, -34).rotated(turn)
	var tip := point + Vector2(16, -58).rotated(turn)
	_art.draw_line(ferrule, tip, CREAM, 3, true)
	_art.draw_circle(tip, 6, GOLD, true, -1, true)
	for side in [-1, 1]:
		_art.draw_circle(point + Vector2(side * 42, -2).rotated(turn), 12, Color("92534e"), true, -1, true)
	_plate(point, Vector2(43, 31), turn, Color("6a9695"))
	_plate(point + Vector2(0, -7).rotated(turn), Vector2(33, 14), turn, INK)
	for side in [-1, 1]:
		var eye := point + Vector2(side * 16, -7).rotated(turn)
		if alarmed:
			_art.draw_line(eye + Vector2(-5, -6).rotated(turn), eye + Vector2(5, 4).rotated(turn), GOLD, 3, true)
			_art.draw_line(eye + Vector2(-5, 4).rotated(turn), eye + Vector2(5, -6).rotated(turn), GOLD, 3, true)
		else:
			_art.draw_circle(eye, 5, CREAM, true, -1, true)
	var grin := point + Vector2(0, 15).rotated(turn)
	_art.draw_line(grin + Vector2(-13, 0).rotated(turn), grin + Vector2(13, 0).rotated(turn), INK, 3, true)

func _hand(point: Vector2, angle: float, side: int) -> void:
	_plate(point, Vector2(16, 11), angle, GOLD)
	for offset in [-1, 1]:
		_rod(point + Vector2(offset * 8, 7).rotated(angle),
			point + Vector2(offset * 11 + side * 5, 20).rotated(angle), 7, Color("e6a763"))

func _draw_joints(turn: float, chest: Vector2, hip: Vector2, fall: float) -> void:
	var dedicated := 0
	var shared := 0
	for n in _state.joints.size():
		var joint: Dictionary = _state.joints[n]
		var point: Vector2
		if joint.seat >= 0:
			var side := 1 if joint.force > 0 else -1
			point = _parts[(2 if side < 0 else 5) + dedicated / 2]
			dedicated += 1
		else:
			var point_base := chest if shared < 2 else hip
			var side := -1 if shared % 2 == 0 else 1
			point = point_base + Vector2(side * 27, 17 if shared < 2 else 0).rotated(turn)
			shared += 1
		_joint_points[n] = point
		var owned: int = joint.owner
		var my_choice: bool = n == _selected(_own)
		var fill := Color("70534f") if owned < 0 else Kit.colors[owned].lightened(0.28)
		if fall > 0.05:
			fill = fill.darkened(0.12)
		_art.draw_circle(point, 15, INK, true, -1, true)
		_art.draw_circle(point, 12, fill, true, -1, true)
		_art.draw_arc(point, 14, 0, TAU, 20, CREAM if my_choice else PALE, 3 if my_choice else 1.4, true)
		_text(_joint_name(n), point, 17, INK if owned >= 0 else CREAM)
		if joint.seat < 0 or _joint_wind[n] > 0.01:
			_art.draw_arc(point, 19, turn - PI / 2, turn - PI / 2 + maxf(0.1, _joint_wind[n]) * TAU * 0.88, 28, GOLD, 2.4, true)
		for p in _state.players:
			if p.holding == n and _is_local(p.slot):
				var stripe: bool = _state.in_detent(p.slot)
				var ring := maxf(0.08, _state.sweep_progress(p.slot))
				_art.draw_arc(point, 23, -PI / 2, -PI / 2 + ring * TAU, 28, CREAM, 4 if stripe else 2, true)
				if stripe:
					_box(Rect2(point + Vector2(-24, -39), Vector2(48, 18)), MINT, INK)
					_text("P%d OUT" % (p.slot + 1), point + Vector2(0, -31), 12, INK)
		if owned >= 0 and _pulse[owned] > 0 and _state.players[owned].feedback == 1:
			var up := 1.0 - _pulse[owned] / 1.1
			_art.draw_arc(point, 16 + up * 22, 0, TAU, 28, Color(GOLD, 1.0 - up), 3, true)
			if _state.players[owned].shared == n or _state.players[owned].shared < 0:
				_text("+1", point + Vector2(0, -26 - up * 14), 24, GOLD)

func _rod(a: Vector2, b: Vector2, width: float, color: Color) -> void:
	_art.draw_line(a, b, INK, width + 6, true)
	_art.draw_line(a, b, color, width, true)
	_art.draw_line(a, b, color.lightened(0.28), 3, true)

func _plate(point: Vector2, half_size: Vector2, angle: float, tint: Color) -> void:
	var polygon := PackedVector2Array()
	for vertex in [
		Vector2(-half_size.x + 8, -half_size.y), Vector2(half_size.x - 8, -half_size.y),
		Vector2(half_size.x, -half_size.y + 8), Vector2(half_size.x, half_size.y - 8),
		Vector2(half_size.x - 8, half_size.y), Vector2(-half_size.x + 8, half_size.y),
		Vector2(-half_size.x, half_size.y - 8), Vector2(-half_size.x, -half_size.y + 8),
	]:
		polygon.append(point + vertex.rotated(angle))
	_art.draw_colored_polygon(polygon, tint)
	_art.draw_line(polygon[0], polygon[1], tint.lightened(0.38), 4, true)
	polygon.append(polygon[0])
	_art.draw_polyline(polygon, INK, 3, true)
	for side in [-1, 1]:
		_art.draw_circle(point + Vector2(side * (half_size.x - 6), 0).rotated(angle), 2.5, CREAM, true, -1, true)

func _coil(bottom: Vector2, top: Vector2, radius: float) -> void:
	var side := (top - bottom).normalized().orthogonal()
	var points := PackedVector2Array([bottom])
	for i in range(1, 21):
		var fraction := i / 21.0
		points.append(bottom.lerp(top, fraction) + side * radius * (1.0 if i % 2 == 0 else -1.0))
	points.append(top)
	_art.draw_polyline(points, INK, 11, true)
	_art.draw_polyline(points, GOLD, 5, true)

func _joint_name(index: int) -> String:
	var seat: int = _state.joints[index].seat
	return str(seat + 1) if seat >= 0 else char(65 + index - _dedicated_count())

func _dedicated_count() -> int:
	var count := 0
	for p in _state.players:
		count += int(p.active)
	return count

func _selected(slot: int) -> int:
	if slot < 0:
		return -1
	if _main.model == _state and _is_local(slot):
		return _play.focused(slot)
	return _state.players[slot].focus

func _is_local(slot: int) -> bool:
	return slot == _own or ((local_mask >> slot) & 1) != 0

func _text(value: String, point: Vector2, size: int, tint: Color, align: float = 0.5) -> void:
	Kit.text(_art, value, Vector2(point.x, Kit.baseline(point.y, size)), size, tint, 0, align)

func _box(rect: Rect2, fill: Color, edge: Color = PALE) -> void:
	_art.draw_rect(rect, fill)
	_art.draw_rect(rect, edge, false, 1.5)

func _draw_dial() -> void:
	_box(Rect2(284, 93, 466, 103), Color("332836"), PALE)
	_text("BALANCE", Vector2(312, 112), 20, CREAM, 0.0)
	_text("UPRIGHT", Vector2(517, 112), 20, MINT)
	_text(_force(_state.torque), Vector2(728, 112), 21, CREAM, 1.0)
	var start := Vector2(315, 140)
	var stop := Vector2(719, 140)
	_art.draw_line(start, stop, PALE, 3, true)
	var band := Rect2(_meter(-2), 135, _meter(2) - _meter(-2), 10)
	_art.draw_rect(band, MINT)
	for number in range(-12, 13, 3):
		var x := _meter(number)
		_art.draw_line(Vector2(x, 133), Vector2(x, 146), CREAM, 1.7, true)
	for side in [-1, 1]:
		var x := _meter(side * Model.STOP)
		_art.draw_line(Vector2(x, 125), Vector2(x, 147), RUST, 3, true)
		_art.draw_line(Vector2(x - 4, 126), Vector2(x + 4, 126), RUST, 3, true)
	var needle := Vector2(_meter(_state.torque), 140)
	_poly([needle, needle + Vector2(-8, -17), needle + Vector2(8, -17)], CREAM)
	_art.draw_line(needle, needle + Vector2(0, 10), CREAM, 2, true)
	if _own >= 0 and _state.window() == "work":
		var view: Dictionary = _state.projection(_own, _selected(_own))
		if view.joint >= 0:
			var ghost := Vector2(_meter(view.solo), 166)
			_diamond(ghost, 8, GOLD)
			if view.partner >= 0:
				var pair := Vector2(_meter(view.paired), 181)
				_bracket(pair, 13, MINT)
				_art.draw_dashed_line(Vector2(ghost.x, 178), Vector2(pair.x, 178), MINT, 1.8, 5, true)
	else:
		_text("LEFT STOP", Vector2(319, 171), 17, PALE, 0.0)
		_text("RIGHT STOP", Vector2(715, 171), 17, PALE, 1.0)

func _meter(value: int) -> float:
	return 517.0 + clampi(value, -15, 15) * 13.0

func _force(value: int) -> String:
	return "+%d" % value if value > 0 else str(value)

func _diamond(point: Vector2, radius: float, shade: Color) -> void:
	var border := PackedVector2Array([point + Vector2(0, -radius), point + Vector2(radius, 0),
		point + Vector2(0, radius), point + Vector2(-radius, 0), point + Vector2(0, -radius)])
	_art.draw_polyline(border, shade, 2.6, true)

func _bracket(point: Vector2, radius: float, shade: Color) -> void:
	for side in [-1, 1]:
		var outer := point + Vector2(side * radius, 0)
		var cap := Vector2(-side * 5, 0)
		_art.draw_polyline(PackedVector2Array([outer + cap + Vector2(0, -7), outer + Vector2(0, -7),
			outer + Vector2(0, 7), outer + cap + Vector2(0, 7)]), shade, 2.6, true)

func _draw_instruction() -> void:
	var own: Dictionary = _state.players[_own] if _own >= 0 else {}
	var chosen := _selected(_own)
	var work: bool = _state.window() == "work"
	var status := "UPRIGHT" if Model.safe(_state.torque) else ("AT SPRING STOP" if absi(_state.torque) >= Model.STOP else "LEANING")
	_box(Rect2(20, 93, 246, 103), PANEL, PALE)
	_text("SPRING RIG", Vector2(34, 116), 19, PALE, 0.0)
	_text(status, Vector2(34, 153), 27, MINT if Model.safe(_state.torque) else RUST, 0.0)
	_box(Rect2(20, 218, 246, 238), Color("382b37"), PALE)
	_text("YOUR FORECAST", Vector2(34, 241), 21, CREAM, 0.0)
	if _menu:
		_text("WIND A JOINT", Vector2(34, 281), 21, GOLD, 0.0)
		_text("THEN BALANCE THE TOY", Vector2(34, 314), 18, CREAM, 0.0)
	elif not work:
		_text("WAIT FOR GO" if _state.phase == "countdown" else "REHEARSAL SEALED", Vector2(34, 282), 20, PALE, 0.0)
	elif chosen >= 0 and not own.is_empty() and chosen in _state.options(_own):
		var view: Dictionary = _state.projection(_own, chosen)
		_diamond(Vector2(47, 279), 8, GOLD)
		_text("SOLO  %s" % _force(view.solo), Vector2(69, 279), 22, GOLD, 0.0)
		if view.partner >= 0:
			_bracket(Vector2(48, 316), 12, MINT)
			_text("WITH P%d  %s" % [view.partner + 1, _force(view.paired)], Vector2(69, 315), 21, MINT, 0.0)
			_text("P%d CAN WIND %s" % [view.partner + 1, _joint_name(view.partner_joint)], Vector2(34, 344), 19, CREAM, 0.0)
		elif view.correction == "upright":
			_text("UPRIGHT SOLO", Vector2(34, 315), 20, MINT, 0.0)
		else:
			_text("NO PARTNER SAVE", Vector2(34, 315), 20, RUST, 0.0)
		var alternate: int = _state.alternate(_own, chosen)
		if view.correction != "upright" and alternate >= 0:
			var alternative: Dictionary = _state.projection(_own, alternate)
			var guide := "TRY JOINT %s" % _joint_name(alternate)
			if alternative.correction == "upright":
				guide += " SOLO"
			_text(guide, Vector2(34, 378), 21, MINT, 0.0)
		elif view.correction == "none":
			_text("NO SAFE CORRECTION", Vector2(34, 349), 19, CREAM, 0.0)
		_text(("SHARED " if own.latched else "YOUR JOINT ") + _joint_name(chosen),
			Vector2(34, 422), 21, CREAM, 0.0)
	else:
		_text("ALL YOUR LATCHES SET" if not own.is_empty() and own.shared >= 0 else "NO JOINT AVAILABLE",
			Vector2(34, 279), 19, CREAM, 0.0)
		if not Model.safe(_state.torque):
			_text("YOUR ADJUSTMENTS CLOSED", Vector2(34, 315), 17, RUST, 0.0)
	_draw_sweep(own, work)

func _draw_sweep(own: Dictionary, work: bool) -> void:
	_box(Rect2(773, 93, 256, 259), Color("382b37"), PALE)
	_text("WINDING GAUGE", Vector2(792, 116), 21, CREAM, 0.0)
	var hold: bool = not own.is_empty() and own.holding >= 0 and work
	var detent: bool = hold and _state.in_detent(_own)
	var progress: float = _state.sweep_progress(_own) if hold else 0.0
	var gauge := Rect2(792, 154, 217, 44)
	_box(gauge, INK)
	var striped := Rect2(935, 156, 71, 40)
	_art.draw_rect(striped, MINT)
	for stripe in 9:
		var x: float = stripe * 10.0 - 10.0
		var lower := Vector2(clampf(x, 0, 71), minf(40, (x + 10) * 2.2))
		var upper := Vector2(clampf(x + 18, 0, 71), maxf(0, (x + 18 - 71) * 2.2))
		if lower.x != upper.x:
			_art.draw_line(striped.position + lower, striped.position + upper, Color("586861"), 3, true)
	var cursor := Vector2(798 + progress * 200, 176)
	_art.draw_line(cursor - Vector2(0, 21), cursor + Vector2(0, 21), INK, 8, true)
	_art.draw_line(cursor - Vector2(0, 22), cursor + Vector2(0, 22), CREAM, 4, true)
	var hint := "HOLD TO WIND"
	if not work:
		hint = "STAND BY"
	if hold:
		hint = "RELEASE NOW" if detent else "KEEP HOLDING"
	elif work and not own.is_empty() and _pulse[_own] > 0.0:
		hint = _feedback(own)
	_text(hint, Vector2(901, 234), 24, MINT if detent else CREAM)
	_text("RELEASE IN THE STRIPES", Vector2(901, 274), 17, PALE)
	_text("LATCH  +1", Vector2(901, 316), 22, GOLD)
	var fill := MINT if detent else (Color("51404a") if work else PANEL)
	_box(SWEEP, fill, MINT if detent else CREAM)
	var tint := INK if detent else CREAM
	if Platform.handheld:
		_text("SWEEP", SWEEP.get_center() - Vector2(0, 10), 27, tint)
		_text("HOLD  /  RELEASE", SWEEP.get_center() + Vector2(0, 18), 17, tint)
	else:
		_text("HOLD  /  RELEASE", SWEEP.get_center() - Vector2(0, 12), 20, tint)
		var caption := "SPACE / A" if _main.shared_screen else ("PAD A" if _main.pad_captions() else "SPACE")
		_text(caption, SWEEP.get_center() + Vector2(0, 17), 26, tint)

func _feedback(p: Dictionary) -> String:
	match p.feedback:
		1: return "LATCH  +1"
		2: return "EARLY  ·  RETRY"
		3: return "TAKEN  ·  SWITCH"
		4: return "UNWOUND  ·  RETRY"
	return ""

func _draw_bench() -> void:
	var possible: Array = _state.options(_own)
	for joint in _state.joints.size():
		var data: Dictionary = _state.joints[joint]
		var box := _card(joint)
		var mine: bool = joint == _selected(_own) and joint in possible
		var fill := Color("62504a") if data.owner >= 0 else PANEL
		_box(box, fill, CREAM if mine else (GOLD if joint in possible else PALE))
		if mine:
			_art.draw_rect(box.grow(-3), CREAM, false, 2)
		var name := _joint_name(joint)
		var heading := box.get_center() - Vector2(0, 5)
		if data.owner >= 0:
			_text(name, heading - Vector2(9, 0), 21, CREAM)
			var check_at := heading + Vector2(10, 0)
			_art.draw_polyline(PackedVector2Array([
				check_at + Vector2(-5, 0), check_at + Vector2(-1, 4), check_at + Vector2(6, -5),
			]), MINT, 2.5, true)
		else:
			_text(name + "   " + _force(data.force), heading, 21, CREAM)
		var cursors: Array[int] = []
		for p in _state.players:
			if p.active and joint in _state.options(p.slot) and _selected(p.slot) == joint:
				cursors.append(p.slot)
		var row_y := box.end.y - 9
		for i in cursors.size():
			var slot := cursors[i]
			var at := Vector2(box.get_center().x + (i - (cursors.size() - 1) / 2.0) * 12, row_y)
			_art.draw_circle(at, 5.5, CREAM if _is_local(slot) else PALE, true, -1, true)
			_text(str(slot + 1), at, 10, INK)
		if data.owner >= 0:
			_text("P%d" % (data.owner + 1), Vector2(box.get_center().x, row_y), 13, CREAM)
	var count := maxi(1, _dedicated_count())
	var width := 1008.0 / count
	var order := 0
	for p in _state.players:
		if not p.active:
			continue
		var box := Rect2(21 + order * width, 533, width - 6, 31)
		var local := _is_local(p.slot)
		_box(box, Color("645047") if _champion == p.slot else INK, CREAM if local else PALE)
		var badge := Vector2(box.position.x + 13, box.get_center().y)
		_art.draw_circle(badge, 9, Kit.colors[p.slot].lightened(0.3), true, -1, true)
		_text(str(p.slot + 1), badge, 15, INK)
		var name := str(p.name).left(8) if show_identities and not str(p.name).is_empty() else ("CPU" if p.bot else ("YOU" if p.slot == _own and not _main.shared_screen else "P%d" % (p.slot + 1)))
		_text(name, badge + Vector2(16, 0), 15, CREAM, 0.0)
		var detail := ""
		if _state.window() == "bell" and p.bonus:
			detail = "+1"
		elif local and p.slot != _own and _state.window() == "work":
			if p.holding >= 0:
				detail = "RELEASE" if _state.in_detent(p.slot) else "WINDING"
			elif _pulse[p.slot] > 0.0:
				detail = ["", "LATCH +1", "RETRY", "TAKEN", "UNWOUND"][p.feedback]
			else:
				var view: Dictionary = _state.projection(p.slot, _selected(p.slot))
				if view.joint >= 0:
					detail = "◇%s" % _force(view.solo)
					if view.partner >= 0:
						detail += " P%d·%s[%s]" % [view.partner + 1, _joint_name(view.partner_joint), _force(view.paired)]
					elif view.correction == "none":
						detail += " NO SAVE"
		_text(detail, Vector2(box.end.x - 30, badge.y), 15, MINT, 1.0)
		_text(str(p.score), Vector2(box.end.x - 8, badge.y), 21, GOLD, 1.0)
		order += 1

func _draw_verdict() -> void:
	var upright := Model.safe(_state.torque)
	var box := Rect2(773, 93, 256, 103)
	_box(box, INK, MINT if upright else RUST)
	_text("UPRIGHT" if upright else "TOPPLED", Vector2(901, 123), 27, MINT if upright else RUST)
	_text("CONTRIBUTORS +1" if upright else "LATCH POINTS KEPT", Vector2(901, 160), 19, CREAM)
	if upright:
		for i in 8:
			var angle := i * TAU / 8.0 + _clock
			var point := Vector2(515, 250) + Vector2.from_angle(angle) * 72
			_art.draw_circle(point, 2.5, GOLD, true, -1, true)

func _poly(points: Array, tint: Color) -> void:
	_art.draw_colored_polygon(PackedVector2Array(points), tint)
