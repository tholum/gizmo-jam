extends RefCounted
## Sumo's game pack interface for the Gizmo Jam session, controls and HUD.

const Arena = preload("res://games/sumo/arena.gd")
const Model = preload("res://games/sumo/model.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const Pads = preload("res://scripts/gamepads.gd")
const Platform = preload("res://scripts/platform.gd")

const ID := "sumo"
const INFO := {
	"number": "04", "title": "SUMO", "tags": "BRAWL  ·  RING-OUT", "voice": "",
	"blurb": "Palm-shove rivals off the dohyo.\nMost ring-outs in 90 seconds wins.",
}
const KEYS := {
	KEY_W: Pads.UP, KEY_UP: Pads.UP,
	KEY_S: Pads.DOWN, KEY_DOWN: Pads.DOWN,
	KEY_A: Pads.LEFT, KEY_LEFT: Pads.LEFT,
	KEY_D: Pads.RIGHT, KEY_RIGHT: Pads.RIGHT,
}
const DIRECTIONS := {"up": Pads.UP, "down": Pads.DOWN, "left": Pads.LEFT, "right": Pads.RIGHT}
const PLATE_SIZE := Vector2(204, 79)
const SAND := Color("ffdfae")
const MINT := Color("a4e5dc")

var main: Node
var stage_node: Node3D
var _demo: RefCounted
var _demo_number := 0

var _keys: Dictionary = {}
var _touch := 0
var _sent := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _pad_before := PackedInt32Array([0, 0, 0, 0, 0, 0])

var _timer: Label
var _feed: Array[Label] = []
var _plates: Array[Control] = []
var _names: Array[Label] = []
var _points: Array[Label] = []
var _stances: Array[Label] = []
var _outs := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _events: Array[Dictionary] = []
var _last_shoves := 0
var _last_hits := 0
var _last_sfx_tick := Model.NEVER
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
			_demo = null
		return
	if not is_instance_valid(stage_node):
		stage_node = Arena.new()
		main.add_child(stage_node)
		stage_node.set_level(main.graphics_level)
	stage_node.client_motion = not menu and main.session.mode == "client"
	stage_node.set_menu(menu)
	stage_node.camera.make_current()

func backdrop(delta: float) -> RefCounted:
	if _demo == null or _demo.phase == "finished":
		var seats: Array = []
		for i in Model.SEATS:
			seats.append({"name": "P%d" % (i + 1), "peer": 0, "bot": true})
		_demo_number -= 1
		_demo = Model.new()
		_demo.begin(7822 - _demo_number, seats, _demo_number)
		_demo.step(Model.COUNTDOWN)
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
	_outs.fill(0)
	_events.clear()
	_last_shoves = 0
	_last_hits = 0
	_last_sfx_tick = Model.NEVER
	_ten_seconds = false
	_lead = 0

func finish_hold() -> float:
	return 1.25

func finished() -> void:
	release()
	main.hud_count.font_size = 104
	main.hud_count.outline_px = 14
	main.hud_count.slam("TIME’S UP!", SAND)
	main._voice("time_up")

func callouts() -> Array:
	return ["RING-OUT  +1", "OFF THE RING", "TIME’S UP!"]

func build_hud() -> void:
	var hud: Control = main.hud_root
	var status: Panel = main._panel(hud, Rect2(26, 22, 185, 87), Color("14212bf5"), Color("bc956c"), 2, 10)
	status.name = "SumoClock"
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_timer = main._label(status, "", Rect2(14, 1, 158, 56), 48, Kit.INK, true)
	main._label(status, "MATCH TIME", Rect2(18, 56, 144, 21), 15, SAND, true)
	_feed.clear()
	for i in 2:
		_feed.append(main._outlined(main._label(hud, "", Rect2(0, 25 + i * 27, 500, 31), 21 if i == 0 else 17,
			Kit.INK, true, HORIZONTAL_ALIGNMENT_CENTER), 7))

	main._hud_corner()
	main._hud_feedback(Rect2(420, 95, 600, 75), 52, 10)
	main._hud_count()
	var intro: Control = main._hud_intro()
	var hint := "WASD / ARROWS TO STEER     ·     SPACE TO SHOVE"
	if Platform.handheld:
		hint = "LEFT THUMB TO STEER     ·     TAP RIGHT TO SHOVE"
	elif main.pad_captions():
		hint = "STICK / D-PAD TO STEER     ·     A TO SHOVE"
	main._outlined(main._label(intro, hint, Rect2(320, 83, 800, 44), 25, Kit.INK, true, HORIZONTAL_ALIGNMENT_CENTER), 8)

	_plates.clear()
	_names.clear()
	_points.clear()
	_stances.clear()
	for i in Model.SEATS:
		var plate := Control.new()
		plate.size = PLATE_SIZE
		plate.pivot_offset = Vector2(PLATE_SIZE.x * 0.5, PLATE_SIZE.y)
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hud.add_child(plate)
		plate.draw.connect(_draw_plate.bind(plate, i))
		_plates.append(plate)
		var caption: Label = main._label(plate, "", Rect2(43, 8, 110, 25), 17, Kit.INK, true)
		caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_names.append(caption)
		_stances.append(main._label(plate, "", Rect2(43, 34, 130, 21), 14, MINT, true))
		_points.append(main._label(plate, "", Rect2(153, 4, 40, 37), 28, SAND, true, HORIZONTAL_ALIGNMENT_RIGHT))
	main._plate_callouts()
	main._layout_hud()

func layout_hud() -> void:
	for label in _feed:
		label.position.x = (main.area.x - label.size.x) * 0.5
	var rects: Array = main.plate_rects(main.area, main.plate_focus(), PLATE_SIZE)
	main.place_plates(_plates, rects, PLATE_SIZE)
	main.place_plate_calls(rects)

func _draw_plate(plate: Control, slot: int) -> void:
	if main.model == null:
		return
	var p: Dictionary = main.model.players[slot]
	var team: Color = Kit.colors[slot]
	var local: bool = main.is_local(slot)
	var tint := team if local else team.darkened(0.32)
	var shape := Kit.slab(Rect2(0, 0, 194, PLATE_SIZE.y), 12)
	Kit.plate(plate, shape, Color("14212b"), 2, 4, tint)
	plate.draw_colored_polygon(Kit.slab(Rect2(8, 9, 23, 45), 6), team)
	Kit.text(plate, str(slot + 1), Vector2(21, Kit.baseline(33, 22)), 22, Kit.OUTLINE, 0, 0.5)
	if _lead > 0 and p.score == _lead:
		plate.draw_rect(Rect2(159, 44, 26, 4), SAND)
	var tick: int = main.model.tick
	var guard: bool = tick < int(p.guard_until)
	var lock_until: int = p.guard_until if guard else p.ready_tick
	var duration := Model.GUARD if guard else Model.COOLDOWN
	var ready := 1.0 - clampf(float(lock_until - tick) / duration, 0.0, 1.0)
	plate.draw_rect(Rect2(43, 62, 139, 6), Color("30414e"))
	if p.alive:
		plate.draw_rect(Rect2(43, 62, 139 * ready, 6), MINT if guard else team)

func update_hud() -> void:
	var model: RefCounted = main.model
	var seconds := ceili(model.remaining())
	_timer.text = "%d:%02d" % [floori(seconds / 60.0), seconds % 60]
	_timer.modulate = SAND if seconds <= 10 else Color.WHITE
	_lead = 0
	for p in model.players:
		_lead = maxi(_lead, p.score)
	for i in Model.SEATS:
		var p: Dictionary = model.players[i]
		var local: bool = main.is_local(i)
		_names[i].text = "%s  %s" % [main._role(i, p, main.session.my_slot()), p.name] if local else str(p.name)
		_points[i].text = str(p.score)
		_points[i].modulate = SAND if _lead > 0 and p.score == _lead else Color.WHITE
		_stances[i].text = _stance(p, model.tick)
		_stances[i].modulate = Color.WHITE if p.alive else Kit.DIM
		_plates[i].queue_redraw()
	_update_cues(model)

func _stance(p: Dictionary, tick: int) -> String:
	if not p.alive:
		return "RETURNING"
	if tick < int(p.guard_until):
		return "PROTECTED"
	if tick < int(p.strike_tick):
		return "WINDUP"
	if p.planted:
		return "PLANTED"
	if tick < int(p.ready_tick):
		return "RECHARGING"
	return "SHOVE READY"

func _update_cues(model: RefCounted) -> void:
	if not _ten_seconds and model.remaining() <= 10.0 and model.phase == "running":
		_ten_seconds = true
		main._voice("ten_seconds")
	var hit: bool = model.hit_count > _last_hits
	var swung: bool = model.strike_count > _last_shoves
	if (hit or swung) and model.tick - _last_sfx_tick >= 10:
		main._sfx("shove" if hit else "dash", 180.0 if hit else 320.0, 1.0 if hit else 1.14)
		_last_sfx_tick = model.tick
	_last_shoves = model.strike_count
	_last_hits = model.hit_count
	var local_points: Array[int] = []
	var local_outs: Array[int] = []
	var fall := false
	for i in Model.SEATS:
		var p: Dictionary = model.players[i]
		if p.outs <= _outs[i]:
			continue
		_outs[i] = p.outs
		fall = true
		var scorer: int = p.last_credit
		var text := "P%d FELL" % (i + 1)
		var color := SAND
		if scorer >= 0:
			text = "P%d SHOVED P%d OUT  +1" % [scorer + 1, i + 1]
			color = Kit.colors[scorer].lightened(0.42)
			if main.is_local(scorer) and scorer not in local_points:
				local_points.append(scorer)
		if main.is_local(i):
			local_outs.append(i)
		_events.push_front({"text": text, "color": color, "until": model.tick + Model.HZ * 2})
	if fall:
		main._sfx("eliminated", 125.0, 1.18)
	if not local_points.is_empty():
		main._sfx("clear", 510.0)
		for slot in local_points:
			_feedback(slot, "RING-OUT  +1", Kit.colors[slot], false)
	for slot in local_outs:
		_feedback(slot, "OFF THE RING", SAND, true)
	_events = _events.slice(0, 2)
	for i in _feed.size():
		var label := _feed[i]
		var show_line: bool = i < _events.size() and model.tick <= int(_events[i].until)
		label.visible = show_line
		if show_line:
			label.text = _events[i].text
			label.modulate = _events[i].color

func _feedback(slot: int, text: String, color: Color, bad: bool) -> void:
	if main.shared_screen:
		main.plate_say(slot, text, color, bad, 1.05)
	else:
		if bad:
			main.hud_feedback.rattle(text, color)
		else:
			main.hud_feedback.pop(text, color)
		main.feedback_time = 1.05

# -------------------------------------------------------------------- Input

func frame(_delta: float) -> void:
	for code in _keys.keys():
		if not Input.is_physical_key_pressed(code):
			_keys.erase(code)
	var own: int = main.session.my_slot()
	var pad: int = main.pads.player_one()
	var live := _input_active()
	_sync_primary(pad)
	if live and pad & ~_pad_before[own] & Pads.A:
		_shove(own, true)
	_pad_before[own] = pad
	var seats: PackedInt32Array = main.seat_pads
	for i in range(0, seats.size(), 2):
		var slot := seats[i]
		var extra: int = main.pads.mask(seats[i + 1])
		_sync(slot, extra & Pads.DIRS if live else 0, false)
		if live and extra & ~_pad_before[slot] & Pads.A:
			_shove(slot, false)
		_pad_before[slot] = extra

func key(event: InputEventKey) -> bool:
	var code := event.physical_keycode
	if code == KEY_SPACE:
		if event.pressed and not event.echo:
			_sync_primary(main.pads.player_one())
			_shove(main.session.my_slot(), true)
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
	# The shared touch widget emits the "dash" pulse for its right-side button.
	return {"left": "stick", "right": "dash", "left_label": "STEER", "right_label": "SHOVE"}

func touch(action: String, pressed: bool) -> void:
	if action == "dash":
		if pressed:
			_shove(main.session.my_slot(), true)
	elif DIRECTIONS.has(action):
		var bit: int = DIRECTIONS[action]
		_touch = _touch | bit if pressed else _touch & ~bit
		_sync_primary(main.pads.player_one())

func _input_active() -> bool:
	return main.model != null and not main.paused and main.model.phase != "finished" and (
		DisplayServer.get_name() == "headless" or main.get_window().has_focus())

func _shove(slot: int, primary: bool) -> void:
	if not _input_active() or main.model.phase != "running":
		return
	if primary:
		main.session.send_input("shove", true)
	else:
		main.session.send_local_input(slot, "shove", true)

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

# -------------------------------------------------------------------- Menus

func build_rules() -> void:
	var panel: Panel = main._modal(INFO.title, "Six robots. One raised dohyo. Stay inside the pale rim.", 530)
	var steer := "LEFT THUMB" if Platform.handheld else ("STICK / D-PAD" if main.pad_captions() else "WASD / ARROWS")
	var shove := "RIGHT TAP" if Platform.handheld else ("A" if main.pad_captions() else "SPACE")
	_rule(panel, 132, steer, "Steer. Let go to plant your feet and take less knockback.")
	_rule(panel, 213, shove, "Shove where you face. Ready again in 1.4s.")
	var scoring: Label = main._label(panel, "The last rival to land a shove within two seconds of a ring-out earns one point. Bumps only crowd. Self-falls give no points. Robots return near center with a brief shield.", Rect2(32, 293, 496, 112), 17, Kit.INK)
	main._wrap(scoring)
	main._label(panel, "MOST POINTS IN 90 SECONDS WINS. TIES DRAW.", Rect2(32, 402, 496, 28), 18, SAND, true)
	main._button(panel, "GOT IT", Rect2(36, 451, 480, 56), main._clear_overlay, true, 24).grab_focus()

func _rule(parent: Control, y: float, keycap: String, desc: String) -> void:
	var panel: Panel = main._panel(parent, Rect2(32, y, 496, 67), Color("142832"), Color("37505a"), 2, 8)
	main._label(panel, keycap, Rect2(14, 0, 173, 67), 20, SAND, true)
	var text: Label = main._label(panel, desc, Rect2(195, 6, 286, 54), 17, Kit.INK)
	main._wrap(text)

func result_summary() -> String:
	return "90-SECOND MATCH"

func result_headers(parent: Control, table_w: float) -> void:
	var row_h := 38.0 if main.tight else 46.0
	var right: float = main.LEFT + table_w - row_h * Kit.SLANT
	main._outlined(main._label(parent, "POINTS", Rect2(right - 99, main.result_header_y, 66, 20), 14,
		Kit.MUTED, true, HORIZONTAL_ALIGNMENT_RIGHT), 5)

func result_tint(slot: int, _champ: bool) -> Color:
	return Kit.colors[slot]

func result_row(tile: Control, slot: int, _champ: bool, body_w: float, row_h: float, mine: bool) -> float:
	main._label(tile, str(main.model.players[slot].score), Rect2(body_w - 85, 0, 52, row_h), 26,
		Kit.OUTLINE, true, HORIZONTAL_ALIGNMENT_RIGHT)
	return 102.0 + (54.0 if mine else 0.0)

func champion_stats(winner: Dictionary) -> String:
	return "%d RING-OUT%s" % [winner.score, "" if winner.score == 1 else "S"]

func celebrate(slot: int) -> void:
	if is_instance_valid(stage_node):
		stage_node.celebrate(slot)
