extends RefCounted
## Gizmo Jam game pack interface for Popcorn Catch.

const Arena = preload("res://games/popcorn_catch/arena.gd")
const M = preload("res://games/popcorn_catch/model.gd")
const Sounds = preload("res://games/popcorn_catch/sounds.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const Pads = preload("res://scripts/gamepads.gd")
const Platform = preload("res://scripts/platform.gd")

const ID := "popcorn_catch"
const VERSION := "1.0.0"
const NET := 1
const CORE_MIN := 10
const INFO := {
	"number": "09", "title": "POPCORN CATCH", "tags": "ARCADE  ·  SCORE ATTACK",
	"blurb": "Chase popping kernels. Bank a bowlful.\nOne catch too many spills your haul.", "voice": "",
}
const ACTIONS := ["up", "down", "left", "right"]
const KEYS := {
	KEY_W: Pads.UP, KEY_UP: Pads.UP, KEY_S: Pads.DOWN, KEY_DOWN: Pads.DOWN,
	KEY_A: Pads.LEFT, KEY_LEFT: Pads.LEFT, KEY_D: Pads.RIGHT, KEY_RIGHT: Pads.RIGHT,
}
const DIRECTIONS := {"up": Pads.UP, "down": Pads.DOWN, "left": Pads.LEFT, "right": Pads.RIGHT}
const PLATE := Vector2(190, 72)
const CREAM := Color("fff0ce")
const GOLD := Color("ffc972")
const INK := Color("20151c")
const DARK := Color("291d27")
const BORDER := Color("b48452")
const MUTED := Color("e3c8a9")

var main: Node
var stage_node: Node3D
var _sounds: Node
var _demo: RefCounted
var _demo_id := 0
var _keys: Dictionary = {}
var _touch := 0
var _sent := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _timer: Label
var _clock_face: Panel
var _message_plate: Panel
var _message: Label
var _plates: Array[Control] = []
var _names: Array[Label] = []
var _points: Array[Label] = []
var _status: Array[Label] = []
var _last_catch := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _last_bank := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _last_burst := M.NO_TICK
var _ten_seconds := false

func _init(owner: Node) -> void:
	main = owner

func make_model() -> RefCounted:
	return M.new()

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
		stage_node.name = "PopcornCabinet"
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
		for slot in M.SEATS:
			seats.append({"name": "P%d" % (slot + 1), "peer": 0, "bot": true, "active": slot % 2 == 0})
		_demo_id -= 1
		_demo = M.new()
		_demo.begin(46803 - _demo_id, seats, _demo_id)
		_demo.step(M.COUNTDOWN + 13.8)
	else:
		_demo.step(delta)
	return _demo

func round_started() -> void:
	forget_keys()
	for code in KEYS:
		if Input.is_physical_key_pressed(code):
			_keys[code] = true
	_sent.fill(0)
	_last_catch.fill(M.NO_TICK)
	_last_bank.fill(M.NO_TICK)
	_last_burst = M.NO_TICK
	_ten_seconds = false

func finish_hold() -> float:
	return 1.2

func finished() -> void:
	release()
	main.hud_count.font_size = 98
	main.hud_count.outline_px = 13
	main.hud_count.slam("TIME’S UP!", CREAM)
	_cue("time_up", -7.0)
	main._voice("time_up")

func build_hud() -> void:
	var hud: Control = main.hud_root
	_clock_face = main._panel(hud, Rect2(25, 22, 145, 68), DARK, BORDER, 2, 10)
	_clock_face.name = "PopcornClock"
	_clock_face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_timer = main._label(_clock_face, "1:30", Rect2(3, -3, 139, 48), 43, CREAM, true, HORIZONTAL_ALIGNMENT_CENTER)
	main._label(_clock_face, "TIME LEFT", Rect2(6, 43, 133, 17), 14, GOLD, true, HORIZONTAL_ALIGNMENT_CENTER)
	_message_plate = main._panel(hud, Rect2(0, 20, 301, 45), DARK, BORDER, 2, 8)
	_message_plate.name = "PopcornInstruction"
	_message_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_message = main._label(_message_plate, "", Rect2(0, 0, 301, 45), 20, CREAM, true, HORIZONTAL_ALIGNMENT_CENTER)
	main._hud_corner()
	main._hud_feedback(Rect2(420, 96, 600, 52), 34, 8)
	main._hud_count()
	var intro: Control = main._hud_intro()
	main._outlined(main._label(intro, _move_hint(), Rect2(320, 101, 800, 26), 23, CREAM, true,
		HORIZONTAL_ALIGNMENT_CENTER), 7)
	main._outlined(main._label(intro, "CATCH AT THE SHADOW   ·   BANK AT ANY SHELF",
		Rect2(320, 135, 800, 27), 19, GOLD, true, HORIZONTAL_ALIGNMENT_CENTER), 7)
	_plates.clear()
	_names.clear()
	_points.clear()
	_status.clear()
	for slot in M.SEATS:
		var card := Control.new()
		card.name = "PopcornScore%d" % (slot + 1)
		card.size = PLATE
		card.pivot_offset = Vector2(PLATE.x * 0.5, PLATE.y)
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hud.add_child(card)
		card.draw.connect(_draw_card.bind(card, slot))
		_plates.append(card)
		var name: Label = main._label(card, "", Rect2(46, 3, 80, 24), 16, CREAM, true)
		name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_names.append(name)
		_points.append(main._label(card, "", Rect2(121, -3, 57, 41), 34, CREAM, true, HORIZONTAL_ALIGNMENT_RIGHT))
		_status.append(main._label(card, "", Rect2(46, 27, 130, 22), 15, GOLD, true))
	main.plate_calls.clear()
	main._layout_hud()

func layout_hud() -> void:
	_message_plate.position.x = roundf((main.area.x - _message_plate.size.x) * 0.5)
	var rects: Array = main.plate_rects(main.area, main.plate_focus(), PLATE, 18.0)
	main.place_plates(_plates, rects, PLATE)

func _draw_card(card: Control, slot: int) -> void:
	var player: Dictionary = main.model.players[slot]
	var tint: Color = Kit.colors[slot]
	var local: bool = main.is_local(slot)
	var flashing := maxf(0.0, 1.0 - (int(main.model.tick) - int(player.last_bank)) / 55.0)
	var fill := DARK.lerp(tint.darkened(0.62), flashing * 0.66)
	var contour := tint if local else tint.darkened(0.27)
	Kit.plate(card, Kit.slab(Rect2(0, 0, PLATE.x - 7, PLATE.y - 5), 7), fill, 2.0, 4.0, contour)
	card.draw_colored_polygon(Kit.slab(Rect2(10, 8, 27, 49), 5), tint)
	Kit.text(card, str(slot + 1), Vector2(25, Kit.baseline(32, 24)), 24, INK, 0, 0.5)
	var loaded: int = player.carry
	for i in M.WOBBLE:
		var pip := Rect2(46 + i * 26, 52, 21, 7)
		card.draw_rect(pip, Color("5b4650"))
		if i < loaded:
			card.draw_rect(pip, CREAM if i < M.BIG_BANK else GOLD)
		if i == M.WOBBLE - 1 and loaded == M.WOBBLE:
			for j in 3:
				var start := pip.position + Vector2(4 + j * 6, 0)
				card.draw_line(start + Vector2(0, pip.size.y), start + Vector2(3, 0), INK, 2.0)

func update_hud() -> void:
	var state: RefCounted = main.model
	var seconds := ceili(state.remaining())
	_timer.text = "%d:%02d" % [floori(seconds / 60.0), seconds % 60]
	_timer.modulate = GOLD if seconds <= 10 else Color.WHITE
	_message_plate.visible = state.phase != "finished"
	var burst: bool = int(state.tick) - int(state.burst_tick) <= 165
	var last_call: bool = seconds <= 2 and state.phase == "running"
	_message.text = "POP BURST  ·  CENTER" if burst else "BANK AT ANY RIM SHELF"
	if last_call:
		_message.text = "LAST CALL  ·  BANK NOW"
	_message.modulate = GOLD if burst or last_call else Color.WHITE
	var lead := 0
	for player in state.players:
		if player.active:
			lead = maxi(lead, player.score)
	for slot in M.SEATS:
		var player: Dictionary = state.players[slot]
		if not player.active:
			continue
		var local: bool = main.is_local(slot)
		_names[slot].text = "YOU" if local and not main.shared_screen else str(player.name).to_upper()
		_points[slot].text = str(player.score)
		_points[slot].modulate = GOLD if player.score == lead and lead > 0 else Color.WHITE
		var text := "%d CARRIED" % player.carry
		if player.carry >= M.WOBBLE:
			text = "BANK NOW"
		elif int(state.tick) - int(player.last_spill) < 52:
			text = "SPILL −%d" % player.spilled
		elif int(state.tick) - int(player.last_bank) < 44:
			text = ("BIG BANK +%d" if player.bank_points >= M.BIG_BANK + M.BANK_BONUS else "BANK +%d") % player.bank_points
		elif player.carry >= M.BIG_BANK:
			text = "BIG BANK READY"
		_status[slot].text = text
		_status[slot].modulate = CREAM if text.ends_with("CARRIED") else GOLD
		_plates[slot].queue_redraw()
	_update_cues(state)

func _update_cues(state: RefCounted) -> void:
	if state.phase != "running":
		return
	if not _ten_seconds and state.remaining() <= 10.0:
		_ten_seconds = true
		_cue("ten_seconds", -10.0)
		main._voice("ten_seconds")
	if state.burst_tick > _last_burst:
		_last_burst = state.burst_tick
		_cue("burst", -9.0)
	var primary_cue := ""
	var other_cue := ""
	for slot in M.SEATS:
		var player: Dictionary = state.players[slot]
		if not player.active:
			continue
		var cue := ""
		if player.last_catch > _last_catch[slot]:
			cue = "spill" if player.last_catch == player.last_spill else ("wobble" if player.carry == M.WOBBLE else "catch")
			_last_catch[slot] = player.last_catch
		if player.last_bank > _last_bank[slot]:
			cue = "big_bank" if player.bank_points >= M.BIG_BANK + M.BANK_BONUS else "bank"
			_last_bank[slot] = player.last_bank
		if not cue.is_empty():
			if main.is_local(slot) or main.shared_screen:
				if primary_cue.is_empty() or Sounds.PRIORITY[cue] > Sounds.PRIORITY[primary_cue]:
					primary_cue = cue
			elif other_cue.is_empty():
				other_cue = cue
	if not primary_cue.is_empty():
		_cue(primary_cue, -6.0)
	elif not other_cue.is_empty():
		_cue(other_cue, -17.0)

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
	_sync_primary()
	var live := _input_active()
	var seats: PackedInt32Array = main.seat_pads
	for i in range(0, seats.size(), 2):
		var held: int = main.pads.mask(seats[i + 1]) & Pads.DIRS if live else 0
		_sync(seats[i], held, false)

func key(event: InputEventKey) -> bool:
	var code := event.physical_keycode
	if not KEYS.has(code):
		return false
	if event.pressed:
		_keys[code] = true
	else:
		_keys.erase(code)
	_sync_primary()
	return true

func touch_layout() -> Dictionary:
	return {"left": "stick", "right": "stick", "left_label": "MOVE", "right_label": "MOVE"}

func touch(action: String, pressed: bool) -> void:
	if DIRECTIONS.has(action):
		var bit: int = DIRECTIONS[action]
		_touch = _touch | bit if pressed else _touch & ~bit
		_sync_primary()

func _input_active() -> bool:
	return main.model != null and not main.paused and main.model.phase != "finished" and (
		DisplayServer.get_name() == "headless" or main.get_window().has_focus())

func _sync_primary() -> void:
	var held := 0
	if _input_active():
		held = _touch | (main.pads.player_one() & Pads.DIRS)
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

func release() -> void:
	var own: int = main.session.my_slot()
	for slot in M.SEATS:
		_sync(slot, 0, slot == own)
	_touch = 0

func forget_keys() -> void:
	_keys.clear()
	_touch = 0

func _move_hint() -> String:
	if Platform.handheld:
		return "DRAG TO MOVE"
	return "STICK / D-PAD TO MOVE" if main.pad_captions() else "WASD / ARROWS TO MOVE"

func build_rules() -> void:
	var panel: Panel = main._modal(INFO.title, "Catch popcorn and bank the most in 90 seconds.", 492)
	_rule(panel, 112, "CATCH", "Move into a growing shadow. The closest bowl at landing gets the kernel. Exact ties rotate between seats.")
	_rule(panel, 188, "BANK", "Enter any rim shelf to bank your bowl. Four or more kernels earn a +2 Big Bank bonus.")
	_rule(panel, 264, "SPILL", "At five kernels your bowl stripes and shakes. The next catch spills half your old load, rounded up.")
	_rule(panel, 340, "MOVE", _move_hint() + ". Unbanked kernels score zero.")
	main._button(panel, "GOT IT", Rect2(36, 416, 480, 53), main._clear_overlay, true, 24).grab_focus()

func _rule(parent: Control, y: float, keycap: String, explanation: String) -> void:
	var row: Panel = main._panel(parent, Rect2(32, y, 496, 67), DARK, BORDER, 2, 8)
	main._label(row, keycap, Rect2(13, 0, 86, 67), 19, GOLD, true)
	var text: Label = main._label(row, explanation, Rect2(102, 1, 376, 64), 17, CREAM)
	main._wrap(text)

func result_summary() -> String:
	return "90-SECOND POPCORN MATCH"

func result_headers(parent: Control, table_w: float) -> void:
	var row_h := 38.0 if main.tight else 46.0
	var right: float = main.LEFT + table_w - row_h * Kit.SLANT
	main._outlined(main._label(parent, "BANKED PTS", Rect2(right - 145, main.result_header_y, 116, 20), 14,
		Kit.MUTED, true, HORIZONTAL_ALIGNMENT_RIGHT), 5)

func result_tint(slot: int, _champ: bool) -> Color:
	return Kit.colors[slot]

func result_row(tile: Control, slot: int, _champ: bool, body_w: float, row_h: float, mine: bool) -> float:
	main._label(tile, str(main.model.players[slot].score), Rect2(body_w - 92, 0, 59, row_h), 26,
		Kit.OUTLINE, true, HORIZONTAL_ALIGNMENT_RIGHT)
	return 107.0 + (54.0 if mine else 0.0)

func champion_stats(winner: Dictionary) -> String:
	return "%d BANKED PTS" % winner.score

func celebrate(slot: int) -> void:
	if is_instance_valid(stage_node):
		stage_node.celebrate(slot)
