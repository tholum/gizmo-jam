extends RefCounted

const Arena = preload("res://games/domino_dash/arena.gd")
const Model = preload("res://games/domino_dash/model.gd")
const Sounds = preload("res://games/domino_dash/sounds.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const Pads = preload("res://scripts/gamepads.gd")
const Platform = preload("res://scripts/platform.gd")

const ID := "domino_dash"
const INFO := {
	"number": "12", "title": "DOMINO DASH", "tags": "ACTION  ·  SCORE ATTACK", "voice": "",
	"blurb": "Tip your numbered starter.\nRace rivals to the green bridge diamonds.",
}
const KEYS := {
	KEY_W: Pads.UP, KEY_UP: Pads.UP,
	KEY_S: Pads.DOWN, KEY_DOWN: Pads.DOWN,
	KEY_A: Pads.LEFT, KEY_LEFT: Pads.LEFT,
	KEY_D: Pads.RIGHT, KEY_RIGHT: Pads.RIGHT,
}
const DIRECTIONS := {"up": Pads.UP, "down": Pads.DOWN, "left": Pads.LEFT, "right": Pads.RIGHT}
const CARD := Vector2(172, 50)
const CREAM := Color("fff2d3")
const GOLD := Color("ffcd66")
const GREEN := Color("b9f794")
const DARK := Color("152e32")
const BORDER := Color("54847a")

var main: Node
var stage_node: Node3D
var _sounds: Node
var _demo: RefCounted
var _demo_number := 0
var _keys: Dictionary = {}
var _touch := 0
var _sent := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _pad_before := PackedInt32Array([0, 0, 0, 0, 0, 0])
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
	if not on:
		if is_instance_valid(stage_node):
			stage_node.queue_free()
		stage_node = null
		_sounds = null
		_demo = null
		return
	if not is_instance_valid(stage_node):
		stage_node = Arena.new(main)
		stage_node.name = "DominoBoard"
		main.add_child(stage_node)
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
		_demo.begin(4271 - _demo_number, seats, _demo_number)
		_demo.step(Model.COUNTDOWN + 2.35)
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
	main.hud_count.slam("TIME’S UP!", CREAM)
	_cue("finish", -10.0)
	main._voice("time_up")

func callouts() -> Array:
	return ["TIME’S UP!"]

func build_hud() -> void:
	var hud: Control = main.hud_root
	var clock: Panel = main._panel(hud, Rect2(22, 22, 110, 64), DARK, BORDER, 2, 8)
	clock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_match = main._label(clock, "1:30", Rect2(0, 0, 110, 44), 37, CREAM, true, HORIZONTAL_ALIGNMENT_CENTER)
	main._label(clock, "MATCH TIME", Rect2(0, 42, 110, 15), 12, GOLD, true, HORIZONTAL_ALIGNMENT_CENTER)
	_wave_panel = main._panel(hud, Rect2(0, 16, 190, 49), DARK, BORDER, 2, 8)
	_wave_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wave_label = main._label(_wave_panel, "WAVE 1 / 6", Rect2(13, 0, 103, 49), 19, CREAM, true)
	_wave_clock = main._label(_wave_panel, ":15", Rect2(123, 0, 53, 49), 27, GREEN, true, HORIZONTAL_ALIGNMENT_RIGHT)
	_hint = main._label(hud, "", Rect2(0, 69, 480, 24), 18, CREAM, true, HORIZONTAL_ALIGNMENT_CENTER)
	main._outlined(_hint, 6)
	main._hud_corner()
	main._hud_feedback(Rect2(420, 98, 600, 48), 30, 7)
	main._hud_count()
	var intro: Control = main._hud_intro()
	var controls := "WASD / ARROWS TO MOVE  ·  SPACE TO TIP"
	if Platform.handheld:
		controls = "LEFT DRAG TO MOVE  ·  RIGHT TAP TO TIP"
	elif main.shared_screen:
		controls = "WASD / STICK TO MOVE  ·  SPACE / A TO TIP"
	elif main.pad_captions():
		controls = "STICK / D-PAD TO MOVE  ·  A TO TIP"
	main._outlined(main._label(intro, controls, Rect2(480, 100, 480, 24), 17, GOLD, true,
		HORIZONTAL_ALIGNMENT_CENTER), 6)

	_cards.clear()
	_names.clear()
	_points.clear()
	_roles.clear()
	for slot in Model.SEATS:
		var card := Control.new()
		card.name = "DominoScore%d" % (slot + 1)
		card.size = CARD
		card.pivot_offset = CARD * Vector2(0.5, 1.0)
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.draw.connect(_draw_card.bind(card, slot))
		hud.add_child(card)
		_cards.append(card)
		var caption: Label = main._label(card, "", Rect2(39, 0, 86, CARD.y), 17, CREAM, true)
		caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_names.append(caption)
		var role: Label = main._label(card, "", Rect2(39, 25, 88, 17), 12, GOLD, true)
		role.visible = main.shared_screen and main.is_local(slot)
		_roles.append(role)
		if role.visible:
			caption.size.y = 30
		_points.append(main._label(card, "", Rect2(119, 1, 42, CARD.y), 28, CREAM, true, HORIZONTAL_ALIGNMENT_RIGHT))
	main._layout_hud()

func layout_hud() -> void:
	_wave_panel.position.x = roundf((main.area.x - _wave_panel.size.x) * 0.5)
	_hint.position.x = roundf((main.area.x - _hint.size.x) * 0.5)
	var rects: Array = main.plate_rects(main.area, main.plate_focus(), CARD, 10.0)
	main.place_plates(_cards, rects, CARD)

func _draw_card(card: Control, slot: int) -> void:
	var tint: Color = Kit.colors[slot]
	Kit.plate(card, Kit.slab(Rect2(0, 0, CARD.x, CARD.y), 8.0), DARK, 2, 4,
		tint if main.is_local(slot) else tint.darkened(0.35))
	card.draw_circle(Vector2(20, CARD.y * 0.5), 13, tint)
	Kit.text(card, str(slot + 1), Vector2(20, Kit.baseline(CARD.y * 0.5, 19)), 19, DARK, 0, 0.5)

func update_hud() -> void:
	var state: RefCounted = main.model
	var seconds := ceili(state.remaining())
	_match.text = "%d:%02d" % [floori(seconds / 60.0), seconds % 60]
	_match.modulate = GOLD if seconds <= 10 else Color.WHITE
	if seconds <= 10 and not _ten_seconds:
		_ten_seconds = true
		main._voice("ten_seconds")
	var wave_seconds := ceili(state.wave_remaining())
	_wave_label.text = "WAVE %d / %d" % [state.wave + 1, Model.WAVES]
	_wave_clock.text = ":%02d" % wave_seconds
	_wave_clock.modulate = GOLD if wave_seconds <= 4 else GREEN
	_hint.text = _instruction(state)
	for p in state.players:
		var slot: int = p.slot
		if not p.active:
			continue
		_names[slot].text = "YOU" if main.is_local(slot) and not main.shared_screen else str(p.name)
		if _roles[slot].visible:
			_roles[slot].text = _role(state, slot)
			_roles[slot].modulate = GREEN if _roles[slot].text.begins_with("TIP") else Color.WHITE
		_points[slot].text = str(p.score)
		_points[slot].modulate = GREEN if state.tick - int(p.last_point) < 8 and p.last_point >= 0 else CREAM
	_update_cues(state)

func _role(state: RefCounted, slot: int) -> String:
	if state.phase == "finished":
		return ""
	var target: Dictionary = state.action_target(slot)
	match target.kind:
		"starter":
			return "TIP STARTER"
		"bridge":
			return "TIP BRIDGE"
		"wait":
			return "WAIT FOR GREEN"
	if state.starters[slot].owner < 0:
		return "FIND STARTER"
	for bridge in state.bridges:
		if bridge.owner < 0:
			return "FIND DIAMOND"
	return "NEXT WAVE"

func _instruction(state: RefCounted) -> String:
	if state.phase == "finished":
		return ""
	if main.shared_screen:
		return "TIP YOUR NUMBERED STARTER  ·  THEN CLAIM GREEN DIAMONDS"
	var slot: int = main.session.my_slot()
	if not state.players[slot].active:
		return "TIP YOUR NUMBERED STARTER  ·  THEN CLAIM GREEN DIAMONDS"
	var target: Dictionary = state.action_target(slot)
	match target.kind:
		"starter":
			return "TIP YOUR STARTER"
		"bridge":
			var possible: int = state.possible_falls(Model.BRIDGE_LENGTH)
			return "TIP NOW  ·  +%d BEFORE RELOAD" % possible if possible < Model.BRIDGE_LENGTH else "TIP THE BRIDGE!"
		"wait":
			return "BRIDGE OPENS IN %d" % ceili(float(state.opens_in(target.index)) / Model.HZ) if state.opens_in(target.index) else "WAIT FOR GREEN"
	if state.starters[slot].owner < 0:
		return "WALK TO YOUR NUMBERED STARTER"
	for bridge in state.bridges:
		if bridge.owner < 0:
			return "RACE TO A BRIDGE DIAMOND"
	return "ALL BRIDGES CLAIMED  ·  NEXT WAVE SOON"

func _update_cues(state: RefCounted) -> void:
	if state.tick <= _cue_tick:
		return
	if state.wave != _cue_wave:
		_cue_wave = state.wave
		_cue("reload", -10.0)
	var chains: Array = state.starters + state.bridges
	for index in chains.size():
		var chain: Dictionary = chains[index]
		if chain.owner < 0:
			continue
		var local: bool = main.is_local(chain.owner)
		var starter := index < Model.SEATS
		var length := Model.STARTER_LENGTH if starter else Model.BRIDGE_LENGTH
		var last := mini(state.tick, int(chain.start) + (length - 1) * Model.FALL_TICKS)
		for tick_value in range(chain.start, last + 1, Model.FALL_TICKS):
			if tick_value > _cue_tick:
				var cue := ("starter" if starter else "bridge") if tick_value == int(chain.start) else "fall"
				_cue(cue, -8.0 if local else -20.0)
	_cue_tick = state.tick

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
		_topple(own, true)
	_pad_before[own] = pad
	var seats: PackedInt32Array = main.seat_pads
	for i in range(0, seats.size(), 2):
		var slot := seats[i]
		var extra: int = main.pads.mask(seats[i + 1])
		_sync(slot, extra & Pads.DIRS if live else 0, false)
		if live and extra & ~_pad_before[slot] & Pads.A:
			_topple(slot, false)
		_pad_before[slot] = extra

func key(event: InputEventKey) -> bool:
	var code := event.physical_keycode
	if code == KEY_SPACE:
		if event.pressed and not event.echo:
			_sync_primary(main.pads.player_one())
			_topple(main.session.my_slot(), true)
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
	return {"left": "stick", "right": "dash", "left_label": "MOVE", "right_label": "TIP"}

func touch(action: String, pressed: bool) -> void:
	if action == "dash":
		if pressed:
			_sync_primary(main.pads.player_one())
			_topple(main.session.my_slot(), true)
	elif DIRECTIONS.has(action):
		var bit: int = DIRECTIONS[action]
		_touch = _touch | bit if pressed else _touch & ~bit
		_sync_primary(main.pads.player_one())

func _input_active() -> bool:
	return main.model != null and not main.paused and main.model.phase != "finished" and (
		DisplayServer.get_name() == "headless" or main.get_window().has_focus())

func _topple(slot: int, primary: bool) -> void:
	if not _input_active() or main.model.phase != "running":
		return
	if primary:
		main.session.send_input("topple", true)
		main.session.send_input("topple", false)
	else:
		main.session.send_local_input(slot, "topple", true)
		main.session.send_local_input(slot, "topple", false)

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
	var panel: Panel = main._modal(INFO.title, "Topple your starter, then race to claim the bridges.", 535)
	var move := "LEFT DRAG" if Platform.handheld else ("STICK / D-PAD" if main.pad_captions() else "WASD / ARROWS")
	var press := "RIGHT TAP" if Platform.handheld else ("A" if main.pad_captions() else "SPACE")
	_rule(panel, 126, move, "Walk to your numbered starter, then head to either diamond at a shared bridge.")
	_rule(panel, 206, press, "Tip your starter, then tap on a green diamond before a rival claims that bridge.")
	var detail: Label = main._label(panel,
		"Every fallen domino earns 1 point. The board reloads every 15 seconds for six waves. Most points wins. Ties draw.",
		Rect2(32, 299, 496, 92), 19, CREAM)
	main._wrap(detail)
	main._button(panel, "GOT IT", Rect2(36, 445, 480, 56), main._clear_overlay, true, 24).grab_focus()

func _rule(parent: Control, y: float, keycap: String, description: String) -> void:
	var panel: Panel = main._panel(parent, Rect2(32, y, 496, 69), DARK, BORDER, 2, 8)
	main._label(panel, keycap, Rect2(14, 0, 155, 69), 19, GOLD, true)
	var detail: Label = main._label(panel, description, Rect2(171, 4, 310, 61), 18, CREAM)
	main._wrap(detail)

func result_summary() -> String:
	return "SIX WAVES  ·  90 SECONDS"

func result_headers(parent: Control, table_w: float) -> void:
	var row_h := 38.0 if main.tight else 46.0
	var right: float = main.LEFT + table_w - row_h * Kit.SLANT
	main._outlined(main._label(parent, "DOMINOES", Rect2(right - 113, main.result_header_y, 80, 20), 14,
		Kit.MUTED, true, HORIZONTAL_ALIGNMENT_RIGHT), 5)

func result_tint(slot: int, _champ: bool) -> Color:
	return Kit.colors[slot]

func result_row(tile: Control, slot: int, _champ: bool, body_w: float, row_h: float, mine: bool) -> float:
	main._label(tile, str(main.model.players[slot].score), Rect2(body_w - 85, 0, 52, row_h), 26,
		Kit.OUTLINE, true, HORIZONTAL_ALIGNMENT_RIGHT)
	return 115 + (54 if mine else 0)

func champion_stats(winner: Dictionary) -> String:
	return "%d DOMINOES TOPPLED" % winner.score

func celebrate(slot: int) -> void:
	if is_instance_valid(stage_node):
		stage_node.celebrate(slot)
