extends RefCounted
## Gizmo Jam game pack interface for Salvage Line.

const Arena = preload("res://games/salvage_line/arena.gd")
const Model = preload("res://games/salvage_line/model.gd")
const Sounds = preload("res://games/salvage_line/sounds.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const Pads = preload("res://scripts/gamepads.gd")
const Platform = preload("res://scripts/platform.gd")

const ID := "salvage_line"
const INFO := {
	"number": "08", "title": "SALVAGE LINE", "tags": "ACTION  ·  SCORE ATTACK", "voice": "",
	"blurb": "Tow crates to your harbor.\nCut rival lines to steal a haul.",
}
const KEYS := {
	KEY_W: Pads.UP, KEY_UP: Pads.UP,
	KEY_S: Pads.DOWN, KEY_DOWN: Pads.DOWN,
	KEY_A: Pads.LEFT, KEY_LEFT: Pads.LEFT,
	KEY_D: Pads.RIGHT, KEY_RIGHT: Pads.RIGHT,
}
const DIRECTIONS := {"up": Pads.UP, "down": Pads.DOWN, "left": Pads.LEFT, "right": Pads.RIGHT}
const PLATE_SIZE := Vector2(192, 67)
const CREAM := Color("fff3d7")
const GOLD := Color("ffd479")
const LIGHT := Color("a8e7df")
const DARK := Color("102833")

var main: Node
var stage_node: Node3D
var _sounds: Node
var _demo: RefCounted
var _demo_number := 0
var _keys: Dictionary = {}
var _touch := 0
var _sent := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _pad_before := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _timer: Label
var _plates: Array[Control] = []
var _names: Array[Label] = []
var _points: Array[Label] = []
var _status: Array[Label] = []
var _seen: Array[Dictionary] = []
var _ten_seconds := false

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
		stage_node.name = "SalvageBay"
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
		_demo_number -= 1
		_demo = Model.new()
		_demo.begin(8032 - _demo_number, seats, _demo_number)
		_demo.step(Model.COUNTDOWN + 3.0)
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
	_seen.clear()
	_ten_seconds = false

func finish_hold() -> float:
	return 1.25

func finished() -> void:
	release()
	main.hud_count.font_size = 104
	main.hud_count.outline_px = 14
	main.hud_count.slam("TIME’S UP!", CREAM)
	main._voice("time_up")

func callouts() -> Array:
	return ["LINE CUT", "LINE LOST", "BANKED  +1", "HEAVY CARGO  +2", "TIME’S UP!"]

func build_hud() -> void:
	var hud: Control = main.hud_root
	var clock: Panel = main._panel(hud, Rect2(26, 22, 151, 76), DARK, Color("4a8889"), 2, 8)
	clock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_timer = main._label(clock, "", Rect2(7, 0, 137, 51), 43, CREAM, true, HORIZONTAL_ALIGNMENT_CENTER)
	main._label(clock, "MATCH TIME", Rect2(7, 48, 137, 19), 14, LIGHT, true, HORIZONTAL_ALIGNMENT_CENTER)
	main._hud_corner()
	main._hud_feedback(Rect2(450, 94, 540, 57), 34, 8)
	main._hud_count()
	var intro: Control = main._hud_intro()
	var hint := "WASD / ARROWS TO STEER   ·   SPACE TO WINCH"
	if Platform.handheld:
		hint = "DRAG LEFT TO STEER   ·   TAP RIGHT TO WINCH"
	elif main.pad_captions():
		hint = "STICK / D-PAD TO STEER   ·   A TO WINCH"
	main._outlined(main._label(intro, hint, Rect2(320, 28, 800, 37), 22, CREAM, true,
		HORIZONTAL_ALIGNMENT_CENTER), 7)
	main._outlined(main._label(intro, "TOW CRATES TO YOUR NUMBERED HARBOR",
		Rect2(320, 67, 800, 28), 18, LIGHT, true, HORIZONTAL_ALIGNMENT_CENTER), 6)

	_plates.clear()
	_names.clear()
	_points.clear()
	_status.clear()
	for i in Model.SEATS:
		var plate := Control.new()
		plate.size = PLATE_SIZE
		plate.pivot_offset = Vector2(PLATE_SIZE.x * 0.5, PLATE_SIZE.y)
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hud.add_child(plate)
		plate.draw.connect(_draw_plate.bind(plate, i))
		_plates.append(plate)
		var caption: Label = main._label(plate, "", Rect2(45, 5, 86, 25), 17, CREAM, true)
		caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_names.append(caption)
		_points.append(main._label(plate, "", Rect2(132, 11, 42, 42), 29, CREAM, true, HORIZONTAL_ALIGNMENT_RIGHT))
		_status.append(main._label(plate, "", Rect2(45, 31, 94, 24), 15, LIGHT, true))
	main._plate_callouts()
	main._layout_hud()

func layout_hud() -> void:
	var rects: Array = main.plate_rects(main.area, main.plate_focus(), PLATE_SIZE, 13.0)
	main.place_plates(_plates, rects, PLATE_SIZE)
	main.place_plate_calls(rects)

func _draw_plate(plate: Control, slot: int) -> void:
	var tint: Color = Kit.colors[slot]
	Kit.plate(plate, Kit.slab(Rect2(0, 0, 181, PLATE_SIZE.y), 9), DARK, 2, 4, tint if main.is_local(slot) else tint.darkened(0.38))
	plate.draw_colored_polygon(Kit.slab(Rect2(9, 10, 25, 43), 4), tint)
	Kit.text(plate, str(slot + 1), Vector2(23, Kit.baseline(32, 24)), 24, Kit.OUTLINE, 0, 0.5)

func update_hud() -> void:
	var state: RefCounted = main.model
	var seconds := ceili(state.remaining())
	_timer.text = "%d:%02d" % [floori(seconds / 60.0), seconds % 60]
	_timer.modulate = GOLD if seconds <= 10 else Color.WHITE
	if not _ten_seconds and seconds <= 10 and state.phase == "running":
		_ten_seconds = true
		main._voice("ten_seconds")
	var lead := 0
	for p in state.players:
		lead = maxi(lead, int(p.score))
	for i in Model.SEATS:
		var p: Dictionary = state.players[i]
		var local: bool = main.is_local(i)
		_names[i].text = "YOU" if local and not main.shared_screen else str(p.name)
		_points[i].text = str(p.score)
		_points[i].modulate = GOLD if lead > 0 and p.score == lead else Color.WHITE
		var kind: String = state.action_target(i).kind if local else "idle"
		_status[i].text = kind.to_upper() if kind != "idle" else _idle_status(p, local)
		_status[i].modulate = GOLD if kind == "cut" or kind == "deliver" else Color.WHITE
		_plates[i].queue_redraw()
	_update_cues(state)

func _idle_status(player: Dictionary, local: bool) -> String:
	if player.towing >= 0:
		return "TOWING"
	if local:
		return "STEER"
	return "CPU" if player.bot else "PLAYER"

func _action_caption() -> String:
	if main.model != null:
		var kind: String = main.model.action_target(main.session.my_slot()).kind
		if kind != "idle":
			return kind.to_upper()
	return "WINCH"

func _update_cues(state: RefCounted) -> void:
	for i in Model.SEATS:
		var p: Dictionary = state.players[i]
		var current := {"hook": int(p.hook_tick), "cut": int(p.cut_tick), "lost": int(p.lost_tick),
			"bank": int(p.bank_tick), "towing": int(p.towing)}
		if i >= _seen.size():
			_seen.append(current)
			continue
		var prior := _seen[i]
		_seen[i] = current
		var local: bool = main.is_local(i)
		var volume := -4.0 if local else -18.0
		if current.bank > prior.bank:
			var points: int = p.bank_amount
			_cue("bank_heavy" if points > 1 else "bank", volume)
			if local:
				_feedback(i, "HEAVY CARGO  +2" if points == 2 else "BANKED  +1", GOLD, false)
		elif current.lost > prior.lost:
			if local:
				_cue("lost", volume)
				_feedback(i, "LINE LOST", Color("ff9b7b"), true)
		elif current.cut > prior.cut:
			_cue("cut", volume)
			if local:
				_feedback(i, "LINE CUT", GOLD, false)
		elif current.hook > prior.hook:
			_cue("hook", volume)
		elif local and current.towing < 0 and prior.towing >= 0:
			_cue("release", volume)

func _feedback(slot: int, caption: String, tint: Color, bad: bool) -> void:
	if main.shared_screen:
		main.plate_say(slot, caption, tint, bad, 0.85)
	elif bad:
		main.hud_feedback.rattle(caption, tint)
	else:
		main.hud_feedback.pop(caption, tint)
	main.feedback_time = 0.85

func _cue(id: String, volume: float) -> void:
	if main.test_mode:
		main.sound_log.append(id)
	elif main.sound_enabled and is_instance_valid(_sounds) and DisplayServer.get_name() != "headless":
		_sounds.cue(id, volume)

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
		_winch(own, true)
	_pad_before[own] = pad
	var seats: PackedInt32Array = main.seat_pads
	for i in range(0, seats.size(), 2):
		var slot := seats[i]
		var extra: int = main.pads.mask(seats[i + 1])
		_sync(slot, extra & Pads.DIRS if live else 0, false)
		if live and extra & ~_pad_before[slot] & Pads.A:
			_winch(slot, false)
		_pad_before[slot] = extra

func key(event: InputEventKey) -> bool:
	var code := event.physical_keycode
	if code == KEY_SPACE:
		if event.pressed and not event.echo:
			_sync_primary(main.pads.player_one())
			_winch(main.session.my_slot(), true)
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
	# Use the same tap area as the other shared touch layouts.
	return {"left": "stick", "right": "dash", "left_label": "MOVE", "right_label": _action_caption()}

func touch(action: String, pressed: bool) -> void:
	if action == "dash":
		if pressed:
			_sync_primary(main.pads.player_one())
			_winch(main.session.my_slot(), true)
	elif DIRECTIONS.has(action):
		var bit: int = DIRECTIONS[action]
		_touch = _touch | bit if pressed else _touch & ~bit
		_sync_primary(main.pads.player_one())

func _input_active() -> bool:
	return main.model != null and not main.paused and main.model.phase != "finished" and (
		DisplayServer.get_name() == "headless" or main.get_window().has_focus())

func _winch(slot: int, primary: bool) -> void:
	if not _input_active() or main.model.phase != "running":
		return
	if primary:
		main.session.send_input("winch", true)
		main.session.send_input("winch", false)
	else:
		main.session.send_local_input(slot, "winch", true)
		main.session.send_local_input(slot, "winch", false)

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
	_sync(own, 0, true)
	var seats: PackedInt32Array = main.seat_pads
	for i in range(0, seats.size(), 2):
		_sync(seats[i], 0, false)
	_sent.fill(0)
	_sample_pads()
	_touch = 0

func forget_keys() -> void:
	_keys.clear()
	_touch = 0

func build_rules() -> void:
	var panel: Panel = main._modal(INFO.title, "Recover cargo and bring it to your numbered harbor.", 539)
	var move := "LEFT DRAG" if Platform.handheld else ("STICK / D-PAD" if main.pad_captions() else "WASD / ARROWS")
	var winch := "RIGHT TAP" if Platform.handheld else ("A" if main.pad_captions() else "SPACE")
	_rule(panel, 132, move, "Steer your tug. Light crates score 1. Heavy crates slow you and score 2.")
	_rule(panel, 211, winch, "Hook marked cargo. Tap in your harbor to bank it, or at sea to release.")
	var detail: Label = main._label(panel,
		"With an empty winch, tap at a marked rival rope to cut it. The crate drifts before you can hook it. Fresh hooks and your final approach protect the rope.",
		Rect2(33, 302, 494, 88), 18, CREAM)
	main._wrap(detail)
	main._label(panel, "MOST POINTS IN 90 SECONDS WINS. TIES DRAW.",
		Rect2(32, 406, 496, 28), 18, GOLD, true)
	main._button(panel, "GOT IT", Rect2(36, 460, 480, 56), main._clear_overlay, true, 24).grab_focus()

func _rule(parent: Control, y: float, keycap: String, desc: String) -> void:
	var panel: Panel = main._panel(parent, Rect2(32, y, 496, 68), DARK, Color("4a8889"), 2, 8)
	main._label(panel, keycap, Rect2(14, 0, 170, 68), 20, GOLD, true)
	var detail: Label = main._label(panel, desc, Rect2(186, 5, 294, 58), 17, CREAM)
	main._wrap(detail)

func result_summary() -> String:
	return "90-SECOND SALVAGE MATCH"

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
	return "%d POINT%s BANKED" % [winner.score, "" if winner.score == 1 else "S"]

func celebrate(slot: int) -> void:
	if is_instance_valid(stage_node):
		stage_node.celebrate(slot)
