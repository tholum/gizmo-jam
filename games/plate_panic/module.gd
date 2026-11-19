extends RefCounted
## Gizmo Jam game pack interface for Plate Panic.

const Arena = preload("res://games/plate_panic/arena.gd")
const Model = preload("res://games/plate_panic/model.gd")
const Sounds = preload("res://games/plate_panic/sounds.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const Pads = preload("res://scripts/gamepads.gd")
const Platform = preload("res://scripts/platform.gd")

const ID := "plate_panic"
const VERSION := "1.0.0"
const NET := 1
const CORE_MIN := 7
const INFO := {
	"number": "07", "title": "PLATE PANIC", "tags": "PHYSICS  ·  SCORE ATTACK",
	"blurb": "Tilt the table. Sink marbles.\nDrop a wedge to redirect a roll.", "voice": "",
}
const ACTIONS := ["up", "down", "left", "right", "wedge"]
const KEYS := {
	KEY_W: Pads.UP, KEY_UP: Pads.UP, KEY_S: Pads.DOWN, KEY_DOWN: Pads.DOWN,
	KEY_A: Pads.LEFT, KEY_LEFT: Pads.LEFT, KEY_D: Pads.RIGHT, KEY_RIGHT: Pads.RIGHT,
}
const DIRECTIONS := {"up": Pads.UP, "down": Pads.DOWN, "left": Pads.LEFT, "right": Pads.RIGHT}
const PLATE_SIZE := Vector2(179, 65)
const CREAM := Color("fff1cf")
const GOLD := Color("ffdf78")
const MINT := Color("a7f4e6")
const DARK := Color("102532")
const BORDER := Color("48707b")

var main: Node
var stage_node: Node3D
var _sounds: Node
var _demo: RefCounted
var _demo_id := 0

var _keys: Dictionary = {}
var _touch := 0
var _sent := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _pad_before := PackedInt32Array([0, 0, 0, 0, 0, 0])

var _timer: Label
var _clock_caption: Label
var _slope: Panel
var _direction: Label
var _tilt := Vector2.ZERO
var _plates: Array[Control] = []
var _names: Array[Label] = []
var _points: Array[Label] = []
var _status: Array[Label] = []
var _scores := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _wedges := PackedInt32Array([-1, -1, -1, -1, -1, -1])
var _deflections := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _pending: Dictionary = {}
var _ten_seconds := false
var _lead := 0

func _init(owner: Node) -> void:
	main = owner

func make_model() -> RefCounted:
	return Model.new()

func arena() -> Node3D:
	return stage_node

func stage(on: bool, menu: bool) -> void:
	if not on:
		if is_instance_valid(stage_node):
			stage_node.queue_free()
		stage_node = null
		_sounds = null
		_demo = null
		return
	if not is_instance_valid(stage_node):
		stage_node = Arena.new()
		stage_node.name = "PlatePanicTable"
		main.add_child(stage_node)
		stage_node.set_level(main.graphics_level)
		_sounds = Sounds.new()
		stage_node.add_child(_sounds)
	stage_node.client_motion = not menu and main.session.mode == "client"
	stage_node.set_menu(menu)
	stage_node.camera.make_current()

func backdrop(delta: float) -> RefCounted:
	if _demo == null or _demo.phase == "finished":
		var seats: Array = []
		for i in Model.SEATS:
			seats.append({"name": "P%d" % (i + 1), "peer": 0, "bot": true})
		_demo_id -= 1
		_demo = Model.new()
		_demo.begin(38192 - _demo_id, seats, _demo_id)
		_demo.step(Model.COUNTDOWN + 2.7)
	else:
		_demo.step(delta)
	return _demo

func round_started() -> void:
	forget_keys()
	for code in KEYS:
		if Input.is_physical_key_pressed(code):
			_keys[code] = true
	_sent.fill(0)
	_sample_pads()
	_scores.fill(0)
	_wedges.fill(-1)
	_deflections.fill(0)
	_pending.clear()
	_tilt = Vector2.ZERO
	_ten_seconds = false
	_lead = 0

func finish_hold() -> float:
	return 1.12

func finished() -> void:
	release()
	main.hud_count.font_size = 98
	main.hud_count.outline_px = 13
	main.hud_count.slam("TIME’S UP!", CREAM)
	_cue("time_up", -5.0)
	main._voice("time_up")

func build_hud() -> void:
	var hud: Control = main.hud_root
	var clock: Panel = main._panel(hud, Rect2(26, 22, 174, 75), DARK, BORDER, 2, 9)
	clock.name = "PlatePanicClock"
	clock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_timer = main._label(clock, "", Rect2(10, 0, 154, 47), 43, CREAM, true, HORIZONTAL_ALIGNMENT_CENTER)
	_clock_caption = main._label(clock, "", Rect2(7, 46, 160, 20), 15, MINT, true, HORIZONTAL_ALIGNMENT_CENTER)

	_slope = main._panel(hud, Rect2(0, 16, 244, 66), DARK, BORDER, 2, 9)
	_slope.name = "PlatePanicSlope"
	_slope.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_slope.draw.connect(_draw_slope)
	_direction = main._label(_slope, "", Rect2(75, 7, 159, 28), 22, CREAM, true)

	main._hud_corner()
	main._hud_feedback(Rect2(420, 85, 600, 58), 35, 8)
	main._hud_count()
	var intro: Control = main._hud_intro()
	var movement := "WASD / ARROWS TO MOVE   ·   SPACE TO PLACE WEDGE"
	if Platform.handheld:
		movement = "DRAG LEFT TO MOVE   ·   TAP RIGHT TO PLACE WEDGE"
	elif main.pad_captions():
		movement = "STICK / D-PAD TO MOVE   ·   A TO PLACE WEDGE"
	main._outlined(main._label(intro, movement, Rect2(320, 103, 800, 28), 21, CREAM, true,
		HORIZONTAL_ALIGNMENT_CENTER), 7)
	main._outlined(main._label(intro, "ROLL MARBLES INTO YOUR NUMBERED POCKET",
		Rect2(320, 134, 800, 23), 17, MINT, true, HORIZONTAL_ALIGNMENT_CENTER), 7)

	_plates.clear()
	_names.clear()
	_points.clear()
	_status.clear()
	for slot in Model.SEATS:
		var plate := Control.new()
		plate.name = "PocketScore%d" % (slot + 1)
		plate.size = PLATE_SIZE
		plate.pivot_offset = Vector2(PLATE_SIZE.x * 0.5, PLATE_SIZE.y)
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hud.add_child(plate)
		plate.draw.connect(_draw_plate.bind(plate, slot))
		_plates.append(plate)
		var caption: Label = main._label(plate, "", Rect2(41, 6, 83, 23), 17, CREAM, true)
		caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_names.append(caption)
		_points.append(main._label(plate, "", Rect2(123, 1, 45, 40), 32, CREAM, true, HORIZONTAL_ALIGNMENT_RIGHT))
		_status.append(main._label(plate, "", Rect2(41, 32, 125, 17), 13, MINT, true))
	main.plate_calls.clear()
	main._layout_hud()

func layout_hud() -> void:
	_slope.position.x = roundf((main.area.x - _slope.size.x) * 0.5)
	var rects: Array = main.plate_rects(main.area, main.plate_focus(), PLATE_SIZE, 20.0)
	main.place_plates(_plates, rects, PLATE_SIZE)

func _draw_slope() -> void:
	var pivot := Vector2(37, 33)
	var strength := _tilt.length()
	_slope.draw_circle(pivot, 23.0, Color("081923"), true, -1.0, true)
	_slope.draw_arc(pivot, 24.0, 0.0, TAU, 40, BORDER, 2.0, true)
	for i in 4:
		var way := Vector2.from_angle(i * PI * 0.5)
		_slope.draw_line(pivot + way * 17.0, pivot + way * 21.0, BORDER, 2.0, true)
	if strength <= 0.02:
		_slope.draw_circle(pivot, 5.0, MINT, true, -1.0, true)
	else:
		var direction := Vector2(_tilt.x, _tilt.y * 0.88).angle()
		var arrow := PackedVector2Array([Vector2(-15, -5), Vector2(3, -5), Vector2(3, -10),
			Vector2(17, 0), Vector2(3, 10), Vector2(3, 5), Vector2(-15, 5)])
		for i in arrow.size():
			arrow[i] = pivot + arrow[i].rotated(direction)
		_slope.draw_colored_polygon(arrow, GOLD)
	for i in 10:
		var x := 76 + i * 15
		_slope.draw_rect(Rect2(x, 42, 11, 9), Color("294753"))
		var filled := clampf(strength * 10.0 - i, 0.0, 1.0)
		if filled > 0.0:
			_slope.draw_rect(Rect2(x, 42, 11 * filled, 9), GOLD)

func _draw_plate(plate: Control, slot: int) -> void:
	var player: Dictionary = main.model.players[slot]
	var local: bool = main.is_local(slot)
	var paint: Color = Kit.colors[slot]
	var scored := int(main.model.tick) - int(player.last_score)
	var flash: float = clampf(1.0 - scored / 42.0, 0.0, 1.0) if int(player.score) > 0 else 0.0
	var fill := DARK.lerp(paint.darkened(0.53), flash * 0.51)
	Kit.plate(plate, Kit.slab(Rect2(0, 0, 168, 64), 10), fill, 2.0, 4.0,
		paint if local else paint.darkened(0.40))
	plate.draw_colored_polygon(Kit.slab(Rect2(9, 9, 24, 43), 6), paint)
	Kit.text(plate, str(slot + 1), Vector2(24, Kit.baseline(30, 23)), 23, DARK, 0, 0.5)
	if local:
		var fraction := clampf(float(int(main.model.tick) - int(player.wedge_tick)) / Model.WEDGE_COOLDOWN, 0.0, 1.0)
		plate.draw_rect(Rect2(41, 54, 119, 4), Color("355461"))
		plate.draw_rect(Rect2(41, 54, 119 * fraction, 4), paint)
	elif player.score > 0 and player.score == _lead:
		plate.draw_rect(Rect2(123, 48, 36, 3), GOLD)

func update_hud() -> void:
	var state: RefCounted = main.model
	var seconds := ceili(state.remaining())
	_timer.text = "%d:%02d" % [floori(seconds / 60.0), seconds % 60]
	_timer.modulate = GOLD if seconds <= 10 else Color.WHITE
	var soonest := -1
	for drop in state.drops:
		var left := maxi(0, int(drop.tick) - int(state.tick))
		soonest = left if soonest < 0 else mini(soonest, left)
	_clock_caption.text = ("DROP IN %.1fs" % (ceilf(float(soonest) / 6.0) / 10.0)) if soonest >= 0 else "TIME LEFT"

	_tilt = state.tilt
	_direction.text = "DOWNSLOPE" if _tilt.length_squared() > 0.0004 else "TABLE LEVEL"
	_slope.queue_redraw()
	_lead = 0
	for player in state.players:
		_lead = maxi(_lead, int(player.score))
	for i in Model.SEATS:
		var player: Dictionary = state.players[i]
		var local: bool = main.is_local(i)
		_names[i].text = "YOU" if local and not main.shared_screen else str(player.name).to_upper()
		_points[i].text = str(player.score)
		_points[i].modulate = GOLD if _lead > 0 and int(player.score) == _lead else Color.WHITE
		var ready := int(state.tick) - int(player.wedge_tick) >= Model.WEDGE_COOLDOWN
		var blocked := false
		if local and ready:
			var site: Vector2 = player.pos + Vector2.from_angle(player.face) * Model.WEDGE_OFFSET
			blocked = not state.wedge_site_open(site)
		_status[i].text = ("WEDGE READY" if ready else "RECHARGING") if local else ("CPU" if player.bot else "PLAYER")
		if blocked:
			_status[i].text = "MOVE TO PLACE"
		elif int(player.score) > 0 and int(state.tick) - int(player.last_score) < 42:
			_status[i].text = "MARBLE IN"
		_status[i].modulate = GOLD if local and (blocked or not ready) else Color.WHITE
		_plates[i].queue_redraw()
	_update_cues(state)

func _update_cues(state: RefCounted) -> void:
	if state.phase != "running":
		return
	if not _ten_seconds and state.remaining() <= 10.0:
		_ten_seconds = true
		_cue("ten_seconds", -9.0)
		main._voice("ten_seconds")

	var pending := {}
	for drop in state.drops:
		pending[drop.id] = true
		if not _pending.has(drop.id):
			_cue("drop_preview", -10.0)
	for marble in state.marbles:
		if _pending.has(marble.id) and not pending.has(marble.id):
			_cue("drop_land", -8.0)
	_pending = pending

	for i in Model.SEATS:
		var player: Dictionary = state.players[i]
		var local: bool = main.is_local(i)
		if int(player.score) > _scores[i]:
			_cue("pocket", -4.0 if local else -13.0, 1.0 + i * 0.042)
		_scores[i] = player.score
		var wedge_tick: int = player.wedge_tick
		if wedge_tick >= 0 and wedge_tick > _wedges[i]:
			_cue("wedge", -6.0 if local else -19.0, 1.0 + i * 0.029)
		_wedges[i] = wedge_tick
		if int(player.deflections) > _deflections[i]:
			_cue("deflect", -5.0 if local else -13.0, 1.0 + i * 0.036)
		_deflections[i] = player.deflections

func _cue(id: String, volume: float, pitch: float = 1.0) -> void:
	if main.test_mode:
		main.sound_log.append(id)
	elif main.sound_enabled and is_instance_valid(_sounds) and DisplayServer.get_name() != "headless":
		_sounds.cue(id, volume, pitch)

func frame(_delta: float) -> void:
	if not main.sound_enabled and is_instance_valid(_sounds):
		_sounds.stop()
	for code in _keys.keys():
		if not Input.is_physical_key_pressed(code):
			_keys.erase(code)
	var own: int = main.session.my_slot()
	var pad: int = main.pads.player_one()
	var live := _input_active()
	_sync_primary(pad)
	if live and pad & ~_pad_before[own] & Pads.A:
		_wedge(own, true)
	_pad_before[own] = pad
	var seats: PackedInt32Array = main.seat_pads
	for i in range(0, seats.size(), 2):
		var slot := seats[i]
		var extra: int = main.pads.mask(seats[i + 1])
		_sync(slot, extra & Pads.DIRS if live else 0, false)
		if live and extra & ~_pad_before[slot] & Pads.A:
			_wedge(slot, false)
		_pad_before[slot] = extra

func key(event: InputEventKey) -> bool:
	var code := event.physical_keycode
	if code == KEY_SPACE:
		if event.pressed and not event.echo:
			_sync_primary(main.pads.player_one())
			_wedge(main.session.my_slot(), true)
		return true
	if not KEYS.has(code):
		return false
	if event.pressed:
		_keys[code] = true
	else:
		_keys.erase(code)
	_sync_primary(main.pads.player_one())
	return true

func touch_layout() -> Dictionary:
	return {"left": "stick", "right": "dash", "left_label": "MOVE", "right_label": "WEDGE"}

func touch(action: String, pressed: bool) -> void:
	if action == "dash":
		if pressed:
			_wedge(main.session.my_slot(), true)
	elif DIRECTIONS.has(action):
		var bit: int = DIRECTIONS[action]
		_touch = _touch | bit if pressed else _touch & ~bit
		_sync_primary(main.pads.player_one())

func _input_active() -> bool:
	return main.model != null and not main.paused and main.model.phase != "finished" and (
		DisplayServer.get_name() == "headless" or main.get_window().has_focus())

func _wedge(slot: int, primary: bool) -> void:
	if not _input_active() or main.model.phase != "running":
		return
	if primary:
		main.session.send_input("wedge", true)
	else:
		main.session.send_local_input(slot, "wedge", true)

func _sync_primary(pad: int) -> void:
	var held := 0
	if _input_active():
		held = _touch | (pad & Pads.DIRS)
		for code in _keys:
			held |= int(KEYS[code])
	_sync(main.session.my_slot(), held, true)

func _sync(slot: int, want: int, primary: bool) -> void:
	var changed := _sent[slot] ^ want
	if changed == 0:
		return
	for action in DIRECTIONS:
		var bit: int = DIRECTIONS[action]
		if changed & bit:
			var held := (want & bit) != 0
			if primary:
				main.session.send_input(action, held)
			else:
				main.session.send_local_input(slot, action, held)
	_sent[slot] = want

func _sample_pads() -> void:
	_pad_before.fill(0)
	_pad_before[main.session.my_slot()] = main.pads.player_one()
	var seats: PackedInt32Array = main.seat_pads
	for i in range(0, seats.size(), 2):
		_pad_before[seats[i]] = main.pads.mask(seats[i + 1])

func release() -> void:
	var own: int = main.session.my_slot()
	for i in Model.SEATS:
		_sync(i, 0, i == own)
	_sample_pads()
	_touch = 0

func forget_keys() -> void:
	_keys.clear()
	_touch = 0

func build_rules() -> void:
	var panel: Panel = main._modal(INFO.title, "Roll marbles into the pocket with your number and colour.", 488)
	var move := "LEFT THUMB" if Platform.handheld else ("STICK / D-PAD" if main.pad_captions() else "WASD / ARROWS")
	var wedge := "RIGHT TAP" if Platform.handheld else ("A" if main.pad_captions() else "SPACE")
	_rule(panel, 127, move, "Everyone’s position tilts the table. The arrow points downhill.")
	_rule(panel, 201, wedge, "Place one wedge in the direction you last moved to redirect a marble.")
	var detail: Label = main._label(panel, "Keep wedges clear of the rim, pockets, and central drop area. Mint rings mark incoming marbles.",
		Rect2(34, 280, 492, 62), 18, Kit.INK)
	main._wrap(detail)
	main._label(panel, "MOST MARBLES IN 90 SECONDS WINS. TIES DRAW.",
		Rect2(33, 345, 493, 29), 18, GOLD, true)
	main._button(panel, "GOT IT", Rect2(36, 407, 480, 55), main._clear_overlay, true, 24).grab_focus()

func _rule(parent: Control, y: float, keycap: String, description: String) -> void:
	var panel: Panel = main._panel(parent, Rect2(32, y, 496, 65), DARK, BORDER, 2, 8)
	main._label(panel, keycap, Rect2(13, 0, 166, 65), 19, GOLD, true)
	var detail: Label = main._label(panel, description, Rect2(175, 4, 300, 57), 17, Kit.INK)
	main._wrap(detail)

func result_summary() -> String:
	return "90-SECOND MARBLE MATCH"

func result_headers(parent: Control, table_w: float) -> void:
	var row_h := 38.0 if main.tight else 46.0
	var right: float = main.LEFT + table_w - row_h * Kit.SLANT
	main._outlined(main._label(parent, "MARBLES", Rect2(right - 112, main.result_header_y, 83, 20), 14,
		Kit.MUTED, true, HORIZONTAL_ALIGNMENT_RIGHT), 5)

func result_tint(slot: int, _champ: bool) -> Color:
	return Kit.colors[slot]

func result_row(tile: Control, slot: int, _champ: bool, body_w: float, row_h: float, mine: bool) -> float:
	main._label(tile, str(main.model.players[slot].score), Rect2(body_w - 85, 0, 52, row_h), 26,
		Kit.OUTLINE, true, HORIZONTAL_ALIGNMENT_RIGHT)
	return 102.0 + (54.0 if mine else 0.0)

func champion_stats(winner: Dictionary) -> String:
	return "%d MARBLE%s" % [winner.score, "" if winner.score == 1 else "S"]

func celebrate(slot: int) -> void:
	if is_instance_valid(stage_node):
		stage_node.celebrate(slot)
