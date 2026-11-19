extends RefCounted
## Gizmo Jam's stage, input, HUD and results hooks for the Orb Racing pack.

const Model = preload("res://games/orb_racing/model.gd")
const Track = preload("res://games/orb_racing/track.gd")
const Arena = preload("res://games/orb_racing/arena.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const Pads = preload("res://scripts/gamepads.gd")
const Platform = preload("res://scripts/platform.gd")

const ID := "orb_racing"
const INFO := {
	"number": "05", "title": "ORB RACING", "tags": "DRIVING  ·  RACE",
	"blurb": "Race three laps. Hit the charge strips and boost past the pack.", "voice": "",
}
const KEYS := {
	KEY_W: Pads.UP, KEY_UP: Pads.UP, KEY_S: Pads.DOWN, KEY_DOWN: Pads.DOWN,
	KEY_A: Pads.LEFT, KEY_LEFT: Pads.LEFT, KEY_D: Pads.RIGHT, KEY_RIGHT: Pads.RIGHT,
}
const DIRECTIONS := {"up": Pads.UP, "down": Pads.DOWN, "left": Pads.LEFT, "right": Pads.RIGHT}
const ARROWS := ["→", "↘", "↓", "↙", "←", "↖", "↑", "↗"]
const CARD := Vector2(199, 82)
const PANEL := Color("142730f5")
const BORDER := Color("42646d")
const ICE := Color("a1edf7")
const AMBER := Color("ffd05b")

var main: Node
var stage_node: Node3D
var _demo: RefCounted
var _demo_seed := 8319
var _keys: Dictionary = {}
var _touch := 0
var _sent := 0
var _pad_before := 0
var _seat_sent := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _seat_before := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _last_pick := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _last_spend := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _last_lap := PackedInt32Array([0, 0, 0, 0, 0, 0])

var _clock: Label
var _clock_title: Label
var _route: Panel
var _route_dir: Label
var _route_title: Label
var _route_detail: Label
var _plates: Array[Control] = []
var _names: Array[Label] = []
var _places: Array[Label] = []
var _laps: Array[Label] = []
var _charges: Array[Label] = []
var _cells: Array[ColorRect] = []


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
		for bot_name in Model.BOT_NAMES:
			seats.append({"name": bot_name, "peer": 0, "bot": true})
		_demo = Model.new()
		_demo_seed += 1
		_demo.begin(_demo_seed, seats, -_demo_seed)
		_demo.step(Model.COUNTDOWN + 5.0)
	else:
		_demo.step(delta)
	return _demo


func round_started() -> void:
	forget_keys()
	for code in KEYS:
		if Input.is_physical_key_pressed(code):
			_keys[code] = true
	_sent = 0
	_pad_before = main.pads.player_one()
	_seat_sent.fill(0)
	_seat_before.fill(0)
	for k in range(0, main.seat_pads.size(), 2):
		_seat_before[main.seat_pads[k]] = main.pads.mask(main.seat_pads[k + 1])
	_last_pick.fill(0)
	_last_spend.fill(0)
	_last_lap.fill(0)


func frame(_delta: float) -> void:
	var pad: int = main.pads.player_one()
	for code in _keys.keys():
		if not Input.is_physical_key_pressed(code):
			_keys.erase(code)
	_sync_primary(pad)
	var active := _steering()
	if _racing() and pad & ~_pad_before & Pads.A:
		_pulse()
	_pad_before = pad
	var seats: PackedInt32Array = main.seat_pads
	for k in range(0, seats.size(), 2):
		var slot := seats[k]
		var extra: int = main.pads.mask(seats[k + 1])
		_send_seat(slot, extra & Pads.DIRS if active else 0)
		if _racing() and extra & ~_seat_before[slot] & Pads.A:
			_pulse(slot)
		_seat_before[slot] = extra


func key(event: InputEventKey) -> bool:
	var code := event.physical_keycode
	if code == KEY_SPACE:
		if event.pressed and not event.echo:
			_pulse()
		return true
	if code not in KEYS:
		return false
	if event.pressed:
		_keys[code] = true
	else:
		_keys.erase(code)
	_sync_primary(main.pads.player_one())
	return true


func touch_layout() -> Dictionary:
	return {"left": "stick", "right": "dash", "left_label": "STEER", "right_label": "BOOST"}


func touch(action: String, pressed: bool) -> void:
	if action == "dash" and pressed:
		_pulse()
	elif action in DIRECTIONS:
		var bit: int = DIRECTIONS[action]
		_touch = _touch | bit if pressed else _touch & ~bit
		_sync_primary(main.pads.player_one())


func _steering() -> bool:
	return main.model != null and main.model.phase != "finished" and not main.paused


func _racing() -> bool:
	return _steering() and main.model.phase == "running"


func _pulse(slot: int = -1) -> void:
	if not _racing():
		return
	if slot < 0:
		_sync_primary(main.pads.player_one())
		main.session.send_input("dash", true)
		main.session.send_input("dash", false)
	else:
		main.session.send_local_input(slot, "dash", true)
		main.session.send_local_input(slot, "dash", false)


func _sync_primary(pad: int) -> void:
	var wanted := 0
	if _steering():
		wanted = _touch | (pad & Pads.DIRS)
		for code in _keys:
			wanted |= int(KEYS[code])
	_send_primary(wanted)


func _send_primary(wanted: int) -> void:
	var changed := wanted ^ _sent
	for action in DIRECTIONS:
		var bit: int = DIRECTIONS[action]
		if changed & bit:
			main.session.send_input(action, wanted & bit != 0)
	_sent = wanted


func _send_seat(slot: int, wanted: int) -> void:
	var changed := wanted ^ _seat_sent[slot]
	for action in DIRECTIONS:
		var bit: int = DIRECTIONS[action]
		if changed & bit:
			main.session.send_local_input(slot, action, wanted & bit != 0)
	_seat_sent[slot] = wanted


func release() -> void:
	_send_primary(0)
	for slot in Model.SEATS:
		_send_seat(slot, 0)


func forget_keys() -> void:
	_keys.clear()
	_touch = 0


func build_hud() -> void:
	var hud: Control = main.hud_root
	var clock_panel := _panel(hud, Rect2(24, 20, 178, 83))
	clock_panel.name = "RaceClock"
	_clock = _label(clock_panel, "1:40", Rect2(15, 2, 148, 52), 39, Kit.INK)
	_clock_title = _label(clock_panel, "RACE LIMIT", Rect2(16, 53, 148, 22), 15, ICE)
	_route = _panel(hud, Rect2(0, 20, 332, 76))
	_route.name = "CurrentRoute"
	_route_dir = _label(_route, "", Rect2(9, 9, 61, 57), 40, ICE, HORIZONTAL_ALIGNMENT_CENTER)
	_route_title = _label(_route, "", Rect2(79, 9, 245, 31), 25, Kit.INK)
	_route_detail = _label(_route, "", Rect2(80, 42, 239, 23), 16, ICE)

	main._hud_corner()
	main._hud_feedback(Rect2(420, 108, 600, 66), 42, 9)
	main._hud_count()
	var intro: Control = main._hud_intro()
	var reminder := "%s   ·   %s TO BOOST" % _control_captions()
	main._outlined(main._label(intro, reminder, Rect2(315, 105, 810, 36), 23,
		Kit.INK, true, HORIZONTAL_ALIGNMENT_CENTER), 7)

	_plates.clear()
	_names.clear()
	_places.clear()
	_laps.clear()
	_charges.clear()
	_cells.clear()
	for i in Model.SEATS:
		_build_plate(hud, i)
	main._plate_callouts()
	main._layout_hud()
	update_hud()


func _build_plate(hud: Control, slot: int) -> void:
	var team: Color = Kit.colors[slot]
	var here: bool = main.is_local(slot)
	var plate := _panel(hud, Rect2(Vector2.ZERO, CARD), team if here else BORDER)
	plate.name = "Driver%d" % (slot + 1)
	plate.pivot_offset = Vector2(CARD.x * 0.5, CARD.y)
	var badge := main._panel(plate, Rect2(8, 8, 29, 64), team, team, 1, 5) as Panel
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label(badge, str(slot + 1), Rect2(0, 0, 29, 64), 23, Kit.OUTLINE, HORIZONTAL_ALIGNMENT_CENTER)
	_plates.append(plate)
	_names.append(_label(plate, "", Rect2(45, 6, 96, 25), 17, Kit.INK))
	_names[-1].text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_places.append(_label(plate, "", Rect2(142, 6, 47, 25), 19, team, HORIZONTAL_ALIGNMENT_RIGHT))
	_laps.append(_label(plate, "", Rect2(45, 31, 146, 22), 15, ICE))
	_charges.append(_label(plate, "", Rect2(45, 53, 94, 22), 14, Kit.INK))
	for j in Model.MAX_CHARGES:
		var cell := ColorRect.new()
		cell.position = Vector2(148 + j * 20, 59)
		cell.size = Vector2(16, 10)
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		plate.add_child(cell)
		_cells.append(cell)


func _panel(parent: Control, rect: Rect2, border: Color = BORDER) -> Panel:
	var panel: Panel = main._panel(parent, rect, PANEL, border, 2, 10)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return panel


func _label(parent: Control, value: String, rect: Rect2, height: int, tint: Color,
		align_value: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var label: Label = main._label(parent, value, rect, height, tint, true, align_value)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func layout_hud() -> void:
	_route.position.x = floorf((float(main.area.x) - _route.size.x) * 0.5)
	var rects: Array = main.plate_rects(main.area, main.plate_focus(), CARD, 19.0)
	main.place_plates(_plates, rects, CARD)
	main.place_plate_calls(rects)


func update_hud() -> void:
	var race: RefCounted = main.model
	var own: int = main.session.my_slot()
	var seconds := ceili(race.remaining())
	_clock.text = "%d:%02d" % [seconds / 60, seconds % 60]
	_clock_title.text = "FINISH WINDOW" if race.first_finish >= 0.0 else "RACE LIMIT"
	_clock.modulate = AMBER if race.first_finish >= 0.0 or seconds <= 10 else Color.WHITE
	_update_route(race, own)
	var order: Array = race.ranking()
	for rank in order.size():
		var i: int = order[rank]
		var p: Dictionary = race.players[i]
		var driver := str(p.name)
		if main.is_local(i):
			driver = "%s %s" % [main._role(i, p, own), driver]
		_names[i].text = driver
		_places[i].text = _place(rank + 1)
		if p.finish >= 0.0:
			_laps[i].text = "FIN  " + _time(p.finish)
		elif race.phase == "finished":
			_laps[i].text = "DNF   ·   %d%%" % _percent(p, race.track.length)
		else:
			var route := "G%d" % p.gate if p.gate > 0 else ("LINE" if p.started else "GRID")
			_laps[i].text = "LAP %d/%d  ·  %s" % [p.laps + 1, Model.LAPS, route]
		_charges[i].text = "BOOST %d/%d" % [p.charges, Model.MAX_CHARGES]
		for j in Model.MAX_CHARGES:
			_cells[i * Model.MAX_CHARGES + j].color = AMBER if j < p.charges else BORDER
	_update_cues(race)


func _update_route(race: RefCounted, own: int) -> void:
	var p: Dictionary = race.players[own]
	_route_dir.modulate = Color.WHITE
	if race.phase == "finished":
		_route_dir.text = "•"
		_route_title.text = "RACE COMPLETE"
		_route_detail.text = "%d OF %d FINISHED" % [_finishers(), Model.SEATS]
		return
	if main.shared_screen:
		_route_dir.text = "•"
		_route_title.text = "FOLLOW THE GATES"
		_route_detail.text = "NEXT GATE ON EACH CARD"
		return
	if p.finish >= 0.0:
		_route_dir.text = "•"
		_route_title.text = "FINISHED  " + _time(p.finish)
		_route_detail.text = "%d OF %d FINISHED" % [_finishers(), Model.SEATS]
		return
	var track: RefCounted = race.track
	var arc: float = track.project(p.pos).x
	var missed: bool = race.missed_gate(p, arc)
	var direction: Vector2 = -track.frame(arc - 2.0).x if missed else track.frame(arc + 2.0).x
	_route_dir.text = ARROWS[posmod(roundi(direction.angle() / (TAU / 8.0)), 8)]
	_route_dir.modulate = AMBER if missed else Color.WHITE
	_route_title.text = Track.GATE_NAMES[p.gate]
	if p.gate == 0:
		_route_detail.text = "RETURN TO THE LINE" if missed else ("COMPLETE THE LAP" if p.started else "CROSS THE LINE TO START")
	else:
		_route_detail.text = ("RETURN TO GATE %d" if missed else "GATE %d OF 6") % p.gate


func callouts() -> Array:
	return ["CHARGE +1", "LAP 2 / 3", "FINAL LAP", "FINISHED!"]


func _update_cues(race: RefCounted) -> void:
	var dash := false
	var charge := false
	var lap := false
	for i in Model.SEATS:
		if not main.is_local(i):
			continue
		var p: Dictionary = race.players[i]
		dash = dash or p.spent > _last_spend[i]
		_last_spend[i] = p.spent
		var text := ""
		var tint := ICE
		if p.picked > _last_pick[i]:
			text = "CHARGE +1"
			tint = AMBER
			charge = true
		if p.laps > _last_lap[i]:
			text = ["", "LAP 2 / 3", "FINAL LAP", "FINISHED!"][p.laps]
			tint = ICE
			lap = true
		_last_pick[i] = p.picked
		_last_lap[i] = p.laps
		if text.is_empty() or race.phase != "running":
			continue
		if main.shared_screen:
			main.plate_say(i, text, tint, false, 1.15)
		else:
			main.hud_feedback.pop(text, tint)
			main.feedback_time = 1.15
	if dash: main._sfx("dash")
	if charge: main._sfx("claim")
	if lap: main._sfx("clear")


func finish_hold() -> float:
	return 1.35


func finished() -> void:
	release()
	var no_finisher: bool = main.model.first_finish < 0.0
	main.hud_count.font_size = 92
	main.hud_count.outline_px = 13
	main.hud_count.slam("TIME’S UP!" if no_finisher else "RACE COMPLETE", Kit.INK)
	if no_finisher:
		main._voice("time_up")


func _control_captions() -> Array:
	if Platform.handheld:
		return ["LEFT DRAG", "RIGHT TAP"]
	if main.pad_captions():
		return ["STICK / D-PAD", "A"]
	return ["WASD / ARROWS", "SPACE"]


func build_rules() -> void:
	var panel: Panel = main._modal(INFO.title, "Run three laps through the gates. The first orb across the finish line wins.", 507)
	var controls := _control_captions()
	main._rule_row(panel, 132, "move", controls[0], "Steer in any screen\ndirection. Grass slows\nyou down.", 0.67)
	main._rule_row(panel, 212, "dash", controls[1], "Spend a boost charge.\nDrive over gold strips\nto refill.", 0.67)
	var notes: Label = main._label(panel,
		"Cross the lit gates in order. The race ends 12 seconds after the leader finishes or at 1:40. Unfinished orbs place by distance.",
		Rect2(32, 310, 496, 82), 18, Kit.INK)
	main._wrap(notes)
	main._button(panel, "GOT IT", Rect2(36, 413, 480, 58), main._clear_overlay, true, 24).grab_focus()


func _finishers() -> int:
	var total := 0
	for p in main.model.players:
		total += int(p.finish >= 0.0)
	return total


func result_summary() -> String:
	var count := _finishers()
	return "%d / %d FINISHED   ·   %s" % [count, Model.SEATS,
		"TIME LIMIT" if main.model.elapsed >= Model.ROUND_TIME else "THREE LAPS"]


func result_headers(parent: Control, table_w: float) -> void:
	var row_h := 38.0 if main.tight else 46.0
	var right: float = main.LEFT + table_w - row_h * Kit.SLANT
	var y: float = main.result_header_y
	main._outlined(main._label(parent, "LAPS", Rect2(right - 204, y, 52, 20), 13,
		Kit.MUTED, true, HORIZONTAL_ALIGNMENT_RIGHT), 5)
	main._outlined(main._label(parent, "TIME / DISTANCE", Rect2(right - 139, y, 117, 20), 13,
		Kit.MUTED, true, HORIZONTAL_ALIGNMENT_RIGHT), 5)


func result_tint(slot: int, _champ: bool) -> Color:
	return Kit.colors[slot]


func result_row(tile: Control, slot: int, _champ: bool, body_w: float, row_h: float, mine: bool) -> float:
	var p: Dictionary = main.model.players[slot]
	var value := _time(p.finish) if p.finish >= 0.0 else "DNF · %d%%" % _percent(p, main.model.track.length)
	_label(tile, "%d/%d" % [p.laps, Model.LAPS], Rect2(body_w - 204, 0, 52, row_h), 20,
		Kit.OUTLINE, HORIZONTAL_ALIGNMENT_RIGHT)
	_label(tile, value, Rect2(body_w - 139, 0, 117, row_h), 20, Kit.OUTLINE, HORIZONTAL_ALIGNMENT_RIGHT)
	return 191.0 + (54.0 if mine else 0.0)


func champion_stats(winner: Dictionary) -> String:
	if winner.finish >= 0.0:
		return "%s   ·   %d LAPS" % [_time(winner.finish), Model.LAPS]
	return "%d%% DISTANCE   ·   %d LAPS" % [_percent(winner, main.model.track.length), winner.laps]


func celebrate(slot: int) -> void:
	if is_instance_valid(stage_node):
		stage_node.celebrate(slot)


static func _time(seconds: float) -> String:
	var ms := roundi(seconds * 1000.0)
	return "%d:%02d.%03d" % [ms / 60000, (ms / 1000) % 60, ms % 1000]


static func _percent(p: Dictionary, length: float) -> int:
	return clampi(floori(p.progress * 100.0 / (Model.LAPS * length)), 0, 100)


static func _place(rank: int) -> String:
	return ["1ST", "2ND", "3RD", "4TH", "5TH", "6TH"][rank - 1]
