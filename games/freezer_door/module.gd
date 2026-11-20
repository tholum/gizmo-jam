extends RefCounted

const Arena = preload("res://games/freezer_door/arena.gd")
const Model = preload("res://games/freezer_door/model.gd")
const Sounds = preload("res://games/freezer_door/sounds.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const Pads = preload("res://scripts/gamepads.gd")
const Platform = preload("res://scripts/platform.gd")

const ID := "freezer_door"
const INFO := {
	"number": "13", "title": "FREEZER DOOR", "tags": "TIMING  ·  SCORE ATTACK", "voice": "",
	"blurb": "Hold a drawer open. Release in the stripe for +2.\nOpen drawers warm their neighbors.",
}
const KEYS := {
	KEY_W: Pads.UP, KEY_UP: Pads.UP,
	KEY_S: Pads.DOWN, KEY_DOWN: Pads.DOWN,
	KEY_A: Pads.LEFT, KEY_LEFT: Pads.LEFT,
	KEY_D: Pads.RIGHT, KEY_RIGHT: Pads.RIGHT,
	KEY_SPACE: Pads.A,
}
const DIRECTIONS := {"up": Pads.UP, "down": Pads.DOWN, "left": Pads.LEFT, "right": Pads.RIGHT}
const ACTIONS := {"up": Pads.UP, "down": Pads.DOWN, "left": Pads.LEFT, "right": Pads.RIGHT, "hold": Pads.A}
const CARD := Vector2(174, 62)

var main: Node
var stage_node: Node3D
var _sounds: Node
var _demo: RefCounted
var _demo_number := 0
var _keys: Dictionary = {}
var _touch := 0
var _hidden_touch := false
var _touch_tint := Color.WHITE
var _sent := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _match: Label
var _wave_panel: Panel
var _wave_label: Label
var _wave_clock: Label
var _hint: Label
var _cards: Array[Control] = []
var _names: Array[Label] = []
var _points: Array[Label] = []
var _roles: Array[Label] = []
var _cue_tick := 0
var _cue_wave := 0
var _ten_seconds := false

func _init(owner: Node) -> void:
	main = owner

func make_model() -> RefCounted:
	return Model.new()

func arena() -> Node3D:
	return stage_node

func stage(on: bool, menu: bool) -> void:
	_set_touch_art(on and not menu)
	if not on:
		if is_instance_valid(stage_node):
			stage_node.queue_free()
		stage_node = null
		_sounds = null
		_demo = null
		return
	if not is_instance_valid(stage_node):
		stage_node = Arena.new(main)
		stage_node.name = "FreezerCabinet"
		main.add_child(stage_node)
		_sounds = Sounds.new()
		stage_node.add_child(_sounds)
	stage_node.set_menu(menu)
	stage_node.camera.make_current()

func _set_touch_art(in_round: bool) -> void:
	var control: Control = main.touch_controls
	if control == null or _hidden_touch == in_round:
		return
	# Keep the shared stick and held action. Its rings would cover the edge
	# thermometers, so this cabinet draws its touch guidance in the bezel.
	_hidden_touch = in_round
	if in_round:
		_touch_tint = control.self_modulate
		control.self_modulate = Color(_touch_tint, 0.0)
	else:
		control.self_modulate = _touch_tint

func backdrop(delta: float) -> RefCounted:
	if _demo == null or _demo.phase == "finished":
		var seats: Array = []
		for slot in Model.SEATS:
			seats.append({"name": "P%d" % (slot + 1), "peer": 0, "bot": true})
		_demo_number -= 1
		_demo = Model.new()
		_demo.begin(1453 - _demo_number, seats, _demo_number)
		_demo.step(Model.COUNTDOWN + 4.35)
	else:
		_demo.step(delta)
	return _demo

func round_started() -> void:
	forget_keys()
	for code in KEYS:
		if Input.is_physical_key_pressed(code):
			_keys[code] = true
	_sent.fill(0)
	_cue_tick = 0
	_cue_wave = 0
	_ten_seconds = false

func finish_hold() -> float:
	return 1.35

func finished() -> void:
	_update_cues(main.model)
	release()
	main.hud_count.font_size = 96
	main.hud_count.outline_px = 12
	main.hud_count.slam("TIME’S UP!", Arena.SNOW)
	_cue("finish", -9.0)
	main._voice("time_up")

func callouts() -> Array:
	return ["TIME’S UP!"]

func build_hud() -> void:
	var hud: Control = main.hud_root
	var clock: Panel = main._panel(hud, Rect2(22, 22, 110, 64), Arena.INK, Arena.BLUE, 2, 8)
	clock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_match = main._label(clock, "1:28", Rect2(0, 0, 110, 44), 36, Arena.SNOW, true, HORIZONTAL_ALIGNMENT_CENTER)
	main._label(clock, "MATCH TIME", Rect2(0, 42, 110, 15), 12, Arena.ICE, true, HORIZONTAL_ALIGNMENT_CENTER)
	_wave_panel = main._panel(hud, Rect2(0, 22, 244, 54), Arena.INK, Arena.BLUE, 2, 8)
	_wave_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wave_label = main._label(_wave_panel, "RESTOCK 1 / 8", Rect2(14, 0, 148, 54), 20, Arena.SNOW, true)
	_wave_clock = main._label(_wave_panel, ":11", Rect2(174, 0, 54, 54), 28, Arena.MINT, true, HORIZONTAL_ALIGNMENT_RIGHT)
	_hint = main._outlined(main._label(hud, "", Rect2(0, 86, 650, 30), 20, Arena.SNOW, true,
		HORIZONTAL_ALIGNMENT_CENTER), 5)
	main._hud_corner()
	main._hud_feedback(Rect2(420, 109, 600, 48), 30, 7)
	main._hud_count()
	var intro: Control = main._hud_intro()
	var controls := "WASD / ARROWS TO MOVE  ·  HOLD SPACE"
	if Platform.handheld:
		controls = "LEFT DRAG TO MOVE  ·  HOLD RIGHT"
	elif main.shared_screen:
		controls = "WASD / STICK TO MOVE  ·  HOLD SPACE / A"
	elif main.pad_captions():
		controls = "STICK / D-PAD TO MOVE  ·  HOLD A"
	main._outlined(main._label(intro, controls, Rect2(410, 103, 620, 28), 19, Arena.ICE, true,
		HORIZONTAL_ALIGNMENT_CENTER), 6)

	_cards.clear()
	_names.clear()
	_points.clear()
	_roles.clear()
	for slot in Model.SEATS:
		var card := Control.new()
		card.name = "FreezerScore%d" % (slot + 1)
		card.size = CARD
		card.pivot_offset = CARD * Vector2(0.5, 1.0)
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.draw.connect(_draw_card.bind(card, slot))
		hud.add_child(card)
		_cards.append(card)
		var name_tag: Label = main._label(card, "", Rect2(39, 5, 87, 25), 17, Arena.SNOW, true)
		name_tag.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_names.append(name_tag)
		_roles.append(main._label(card, "", Rect2(39, 30, 104, 21), 13, Arena.ICE, true))
		_points.append(main._label(card, "", Rect2(121, 0, 41, 53), 30, Arena.SNOW, true, HORIZONTAL_ALIGNMENT_RIGHT))
	main._layout_hud()

func layout_hud() -> void:
	_wave_panel.position.x = roundf((main.area.x - _wave_panel.size.x) * 0.5)
	_hint.position.x = roundf((main.area.x - _hint.size.x) * 0.5)
	var rects: Array = main.plate_rects(main.area, main.plate_focus(), CARD, 16.0)
	main.place_plates(_cards, rects, CARD)

func _draw_card(card: Control, slot: int) -> void:
	var tint: Color = Kit.colors[slot]
	Kit.plate(card, Kit.slab(Rect2(Vector2.ZERO, CARD), 8.0), Arena.INK, 2, 4,
		tint if main.is_local(slot) else tint.darkened(0.27))
	card.draw_circle(Vector2(21, 26), 12, tint, true, -1.0, true)
	card.draw_circle(Vector2(21, 26), 9, Arena.INK, true, -1.0, true)
	Kit.text(card, str(slot + 1), Vector2(21, Kit.baseline(26, 16)), 16, Arena.SNOW, 0, 0.5)

func update_hud() -> void:
	var state: RefCounted = main.model
	var seconds := ceili(state.remaining())
	_match.text = "%d:%02d" % [floori(seconds / 60.0), seconds % 60]
	_match.modulate = Arena.HOT if seconds <= 10 else Color.WHITE
	if seconds <= 10 and not _ten_seconds:
		_ten_seconds = true
		main._voice("ten_seconds")
	var wave_seconds := ceili(state.wave_remaining())
	_wave_label.text = "RESTOCK %d / %d" % [state.wave + 1, Model.WAVES]
	_wave_clock.text = ":%02d" % wave_seconds
	_wave_clock.modulate = Arena.HOT if wave_seconds <= 2 else Arena.MINT
	var own: int = main.session.my_slot()
	_hint.text = "HOLD TO OPEN  ·  RELEASE IN THE STRIPE" if main.shared_screen else _instruction(state, own)
	_hint.modulate = Arena.MINT if _in_band(state, own) and not main.shared_screen else Color.WHITE
	for p in state.players:
		if not p.active:
			continue
		var slot: int = p.slot
		var row: Label = _roles[slot]
		_names[slot].text = "YOU" if main.is_local(slot) and not main.shared_screen else str(p.name)
		_points[slot].text = str(p.score)
		_points[slot].modulate = Arena.MINT if state.tick - int(p.last_tick) < 13 and p.last_tick >= 0 else Color.WHITE
		row.text = "%d / 2 USED" % p.used
		row.modulate = Color.WHITE
		if p.hold >= 0:
			row.text = "HOLDING"
			if _in_band(state, slot):
				row.text = "RELEASE +2"
				row.modulate = Arena.MINT
			elif state.drawers[p.hold].heat > Model.BAND_HIGH:
				row.text = "TOO WARM"
				row.modulate = Arena.HOT
	_update_cues(state)

func _in_band(state: RefCounted, slot: int) -> bool:
	var drawer: int = state.players[slot].hold
	return drawer >= 0 and Model.bonus(state.drawers[drawer].heat)

func _instruction(state: RefCounted, slot: int) -> String:
	if state.phase == "finished":
		return ""
	var p: Dictionary = state.players[slot]
	if not p.active:
		return "HOLD TO OPEN  ·  RELEASE IN THE STRIPE"
	if p.hold >= 0:
		if _in_band(state, slot):
			return "RELEASE NOW  ·  DOUBLE POINTS"
		if state.drawers[p.hold].heat > Model.BAND_HIGH:
			return "TOO WARM  ·  RELEASE FOR ONE POINT"
		return "HOLD  ·  WATCH THE SOLID NEEDLE"
	if p.used >= Model.MAX_CLAIMS:
		return "TWO DRAWERS USED  ·  WAIT FOR RESTOCK"
	if state.can_claim(slot, p.cursor):
		return "HOLD TO OPEN"
	return "MOVE TO A FREE DRAWER"

func _update_cues(state: RefCounted) -> void:
	if state.tick <= _cue_tick:
		return
	if state.wave != _cue_wave:
		_cue_wave = state.wave
		_cue("restock", -11.0)
	var opened := 0
	for p in state.players:
		if not p.active:
			continue
		var local: bool = main.is_local(p.slot)
		if p.grab_tick > _cue_tick and p.hold >= 0 and not (opened & (1 << int(p.hold))):
			opened |= 1 << int(p.hold)
			_cue("drawer_open", -14.0 if local else -25.0)
		if p.last_tick > _cue_tick:
			_cue("double_treat" if p.last_points == 2 else "treat", -10.0 if local else -19.0)
	_cue_tick = state.tick

func _cue(id: String, volume: float) -> void:
	if main.test_mode:
		main.sound_log.append(id)
	elif main.sound_enabled and is_instance_valid(_sounds) and DisplayServer.get_name() != "headless":
		_sounds.cue(id, volume)

func frame(_delta: float) -> void:
	if not main.sound_enabled and is_instance_valid(_sounds):
		_sounds.stop()
	_sync_primary()
	var live := _input_active()
	var seats: PackedInt32Array = main.seat_pads
	for i in range(0, seats.size(), 2):
		var pads: int = main.pads.mask(seats[i + 1])
		_sync(seats[i], pads & (Pads.DIRS | Pads.A) if live else 0, false)

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
	# The core's held touch role emits both edges through touch().
	return {"left": "stick", "right": "duck", "left_label": "MOVE", "right_label": "HOLD"}

func touch(action: String, pressed: bool) -> void:
	var bit: int = Pads.A if action == "duck" else DIRECTIONS.get(action, 0)
	_touch = _touch | bit if pressed else _touch & ~bit
	if is_instance_valid(stage_node):
		stage_node.touch_steering = bool(_touch & Pads.DIRS)
		stage_node.touch_holding = bool(_touch & Pads.A)
	_sync_primary()

func _input_active() -> bool:
	return main.model != null and not main.paused and main.model.phase != "finished" and (
		DisplayServer.get_name() == "headless" or main.get_window().has_focus())

func _sync_primary() -> void:
	var held := 0
	if _input_active():
		held = _touch | (main.pads.player_one() & (Pads.DIRS | Pads.A))
		for code in _keys:
			held |= int(KEYS[code])
	_sync(main.session.my_slot(), held, true)

func _sync(slot: int, want: int, primary: bool) -> void:
	var changed := _sent[slot] ^ want
	if changed == 0:
		return
	for action in ACTIONS:
		var bit: int = ACTIONS[action]
		if changed & bit:
			var held := (want & bit) != 0
			if primary:
				main.session.send_input(action, held)
			else:
				main.session.send_local_input(slot, action, held)
	_sent[slot] = want

func release() -> void:
	_sync(main.session.my_slot(), 0, true)
	var seats: PackedInt32Array = main.seat_pads
	for i in range(0, seats.size(), 2):
		_sync(seats[i], 0, false)
	_sent.fill(0)
	_clear_touch()

func forget_keys() -> void:
	_keys.clear()
	_clear_touch()

func _clear_touch() -> void:
	_touch = 0
	if is_instance_valid(stage_node):
		stage_node.touch_steering = false
		stage_node.touch_holding = false

func build_rules() -> void:
	var panel: Panel = main._modal(INFO.title, "Time your release to catch the treat.", 550)
	var move := "LEFT DRAG" if Platform.handheld else ("STICK / D-PAD" if main.pad_captions() else "WASD / ARROWS")
	var hold := "HOLD RIGHT" if Platform.handheld else ("HOLD A" if main.pad_captions() else "HOLD SPACE")
	_rule(panel, 125, move, "Pick a drawer. Your starting drawer is reserved for the first three seconds.")
	_rule(panel, 203, hold, "Release for 1 point, or 2 when the solid needle is in the striped band.")
	var detail: Label = main._label(panel,
		"Open doors warm their neighbors. The hollow marker shows heat half a second ahead. Same-tick grabs share a drawer and still score separately. Take up to two treats before each of eight restocks.",
		Rect2(32, 291, 496, 135), 19, Arena.SNOW)
	main._wrap(detail)
	main._button(panel, "GOT IT", Rect2(36, 461, 480, 56), main._clear_overlay, true, 24).grab_focus()

func _rule(parent: Control, y: float, keycap: String, description: String) -> void:
	var panel: Panel = main._panel(parent, Rect2(32, y, 496, 69), Arena.INK, Arena.BLUE, 2, 8)
	main._label(panel, keycap, Rect2(14, 0, 155, 69), 18, Arena.MINT, true)
	var detail: Label = main._label(panel, description, Rect2(171, 4, 310, 61), 18, Arena.SNOW)
	main._wrap(detail)

func result_summary() -> String:
	return "EIGHT RESTOCKS  ·  88 SECONDS"

func result_headers(parent: Control, table_w: float) -> void:
	var row_h := 38.0 if main.tight else 46.0
	var right: float = main.LEFT + table_w - row_h * Kit.SLANT
	main._outlined(main._label(parent, "POINTS", Rect2(right - 113, main.result_header_y, 80, 20), 14,
		Kit.MUTED, true, HORIZONTAL_ALIGNMENT_RIGHT), 5)

func result_tint(slot: int, _champ: bool) -> Color:
	return Kit.colors[slot]

func result_row(tile: Control, slot: int, _champ: bool, body_w: float, row_h: float, mine: bool) -> float:
	main._label(tile, str(main.model.players[slot].score), Rect2(body_w - 85, 0, 52, row_h), 26,
		Kit.OUTLINE, true, HORIZONTAL_ALIGNMENT_RIGHT)
	return 115 + (54 if mine else 0)

func champion_stats(winner: Dictionary) -> String:
	return "%d POINTS" % winner.score

func celebrate(slot: int) -> void:
	if is_instance_valid(stage_node):
		stage_node.celebrate(slot)
